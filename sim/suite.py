#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# Self-checking test suite for hdl/atari2600_core.sv. Runs our own test ROMs
# (sim/testroms) on the core and checks what they report.
#
# With --gamebub the same checks run on the Game Bub wrapper
# (hdl/gamebub/atari2600_gamebub.sv, sim/gamebub): the ROM goes in through
# the host file window and the status band is read from the framework's
# framebuffer. Images larger than the wrapper's 64K ROM must be rejected at
# load. Extra Game Bub checks: framebuffer equals the core's picture (frame
# sums) on third-party ROMs, and ROM words sent with gaps load the same.
#
# Each bankswitch ROM is checked twice, and the two are reported separately:
#   mapping    the mapper is forced; the ROM's status band must be green
#              (anything else, including a blank screen from a crash, fails)
#   detection  auto-detection must pick the expected mapper (and Superchip)
#
# Paddle checks (PADDLE_CORE / PADDLE_GAMEBUB) run paddle.asm variants with
# positions, buttons or the Paddle setting and held d-pad buttons; `paddle`
# as a name selects them all.
#
# Pause checks (core only, `pause` selects them): each ROM in PAUSE runs once
# plainly and once with the core's pause input raised for PAUSE_EVERY[1] of
# every PAUSE_EVERY[0] clocks (about 150 pauses, landing on every clock
# phase). Frame lines and audio must be identical, and no pixel may come out
# after the first few clocks of a pause (so a pause that does nothing fails).
#
# Menu check (Game Bub only, `menu`): switches.asm shows the console switches
# and a frame counter; the harness opens the menu (--menu), changes Left
# Difficulty and TV Type, uses Reset, then closes it; later Resets with the
# menu closed at once. Not one frame runs while the menu is open; Reset shows
# a black frame and the game restarts from it; the changes show after the
# menu closes, and not one frame runs unseen (the counter never skips).
#
# Usage: python3 sim/suite.py [--gamebub] [name ...]
#        (or make -C sim test / make -C sim test-gamebub)

import concurrent.futures
import os
import struct
import subprocess
import sys
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
UPSTREAM = os.path.join(ROOT, 'build', 'upstream')     # patched copy
BIN = os.path.join(ROOT, 'sim', 'out', 'obj_core_stub', 'Vatari2600_core')
CORE_BIN = BIN
GAMEBUB_BIN = os.path.join(ROOT, 'sim', 'out', 'obj_gamebub', 'Vatari2600_gamebub')
ROMS = os.path.join(ROOT, 'sim', 'roms', 'synthetic')
OUT = os.path.join(ROOT, 'sim', 'out', 'suite')
GAMEBUB = False
GAMEBUB_ROM_MAX = 65536  # hdl/gamebub/atari2600_gamebub.sv ROM_ADDR_WIDTH = 16

# Mapper numbers: the bss_type enum in hdl/detect2600.sv.
M = dict(F8=1, F6=2, FE=3, E0=4, F3F=5, F4=6, P2=7, FA=8, CV=9, K2=10, UA=11,
         E7=12, F0=13, M32=14, F3E=16, SB=17, WD=18, EF=19, JANE=20, CTY=22,
         FA2=25, X0840=26, FC=27, DF=28, MC2K=29, MC4K=30, MC8K=31)

# ROM -> (mapper, Superchip expected from detection)
BANKSWITCH = {
    # Mapper 0 (plain 4K) cannot be forced - 0 means "use detection" - so
    # this one's mapping check runs on detection too.
    'bs_4ksc': (0, True),
    'bs_f8': (M['F8'], False), 'bs_f6': (M['F6'], False), 'bs_f4': (M['F4'], False),
    'bs_f8sc': (M['F8'], True), 'bs_f6sc': (M['F6'], True), 'bs_f4sc': (M['F4'], True),
    'bs_e0': (M['E0'], False), 'bs_3f': (M['F3F'], False),
    'bs_fa': (M['FA'], False), 'bs_fa2': (M['FA2'], False),
    'bs_ef': (M['EF'], False), 'bs_efsc': (M['EF'], True),
    'bs_df': (M['DF'], False), 'bs_dfsc': (M['DF'], True),
    'bs_bf': (M['DF'], False), 'bs_bfsc': (M['DF'], True),
    'bs_sb128': (M['SB'], False), 'bs_sb256': (M['SB'], False),
    'bs_ua': (M['UA'], False), 'bs_0840': (M['X0840'], False),
    'bs_jane': (M['JANE'], False), 'bs_cty': (M['CTY'], False),
    'bs_f0': (M['F0'], False), 'bs_2k': (M['K2'], False), 'bs_cv': (M['CV'], False),
    'bs_e7': (M['E7'], False), 'bs_3e': (M['F3E'], False), 'bs_fe': (M['FE'], False),
    'bs_wd': (M['WD'], False), 'bs_fc': (M['FC'], False), 'bs_p2': (M['P2'], False),
}

# Multicarts: ROM -> (mapper, games). Each reset must advance to the next
# game, whose status band is its stripe colour, hue (game & 7).
MULTICART = {
    'bs_mc2k': (M['MC2K'], 8), 'bs_mc4k': (M['MC4K'], 8),
    'bs_mc8k': (M['MC8K'], 8), 'bs_32in1': (M['M32'], 32),
}
# The stripe colours for hues 0-7 at luminance $A in the core's palette.
HUES = [0xb7b7b7, 0xcdbe22, 0xe8b247, 0xf8a77f, 0xfb9fbb, 0xf09cf2, 0xd99fff, 0xbaa7ff]
# Schemes that are not auto-detected (docs/detection-spec.md 3.22). Their
# mapping is still tested (forced).
NO_DETECTION = {
    'bs_cty': 'CTY is selected from the menu only',
    'bs_mc2k': 'MC multicarts are selected from the menu only',
    'bs_mc4k': 'MC multicarts are selected from the menu only',
    'bs_mc8k': 'MC multicarts are selected from the menu only',
}
# Known gaps in detection, reported but not counted as failures.
# Each one is a real limitation of auto-detection: the settings menu needs
# a manual override for these.
# Known mapping issues, reported but not counted as failures until fixed.
KNOWN_ISSUES = {}
KNOWN_GAPS = {
    'bs_32in1': 'a 64K 32-in-1 is the same size as F0 and has no signature',
}
# Paddles (sim/testroms/paddle.asm). Each ROM variant holds the expected
# counts and buttons; the run gives the inputs: name -> (ROM, harness args,
# frames the ROM measures for, whether the status must be green). The
# red ones are negative checks: the same ROM with an input that must not
# satisfy it, so a check that cannot fail shows up here.
PADDLE_CORE = {
    'pdl_off': ('pdl_off', (), 30, True),
    'pdl_lo': ('pdl_lo', ('--paddle', '0,255'), 30, True),
    'pdl_hi': ('pdl_hi', ('--paddle', '255,0'), 30, True),
    'pdl_mid': ('pdl_mid', ('--paddle', '128,64'), 30, True),
    'pdl_btna': ('pdl_btna', ('--paddle', '128,64', '--paddle-btn', 'a'), 30, True),
    'pdl_btnb': ('pdl_btnb', ('--paddle', '128,64', '--paddle-btn', 'b'), 30, True),
    'pdl_mid-': ('pdl_mid', ('--paddle', '160,64'), 30, False),
    'pdl_mid-off': ('pdl_mid', (), 30, False),
    'pdl_btna-': ('pdl_btna', ('--paddle', '128,64', '--paddle-btn', 'b'), 30, False),
}
PADDLE_GAMEBUB = {
    'pdl_gbmid': ('pdl_gbmid', ('--paddle',), 30, True),
    'pdl_gbright': ('pdl_gbright', ('--paddle', '--hold', 'right'), 45, True),
    'pdl_gbleft': ('pdl_gbleft', ('--paddle', '--hold', 'left'), 45, True),
    'pdl_gbspeed': ('pdl_gbspeed', ('--paddle', '--hold', 'right'), 20, True),
    'pdl_gbfire-a': ('pdl_gbfire', ('--paddle', '--hold', 'a'), 30, True),
    'pdl_gbfire-b': ('pdl_gbfire', ('--paddle', '--hold', 'b'), 30, True),
    'pdl_gbfire-x': ('pdl_gbfire', ('--paddle', '--hold', 'x'), 30, True),
    'pdl_gbfire-y': ('pdl_gbfire', ('--paddle', '--hold', 'y'), 30, True),
    'pdl_gbjoy': ('pdl_gbjoy', ('--hold', 'right'), 30, True),
    'pdl_gbmid-joy': ('pdl_gbmid', (), 30, False),
    'pdl_gbmid-up': ('pdl_gbmid', ('--paddle', '--hold', 'up,down'), 30, True),
    'pdl_gbright-': ('pdl_gbright', ('--paddle', '--hold', 'right,a'), 45, False),
    'pdl_gbspeed-': ('pdl_gbspeed', ('--paddle', '--hold', 'left'), 20, False),
}

# rom, extra args: CPU/TIA/RIOT, audio, cartridge RAM schemes, a multicart
# with console resets, paddle timers, third-party ROMs.
PAUSE = [
    ('tone', ()),
    ('bs_f8sc', ('--mapper', '1', '--sc')),
    ('bs_e7', ('--mapper', '12')),
    ('bs_fa', ('--mapper', '8')),
    ('bs_cv', ('--mapper', '9')),
    ('bs_3e', ('--mapper', '16')),
    ('bs_mc4k', ('--mapper', '30', '--reset-every', '3')),
    ('pdl_mid', ('--paddle', '128,64')),
    ('pdl_btna', ('--paddle', '128,64', '--paddle-btn', 'a')),
    ('../jamesor/test-01', ()),
    ('../testbr/testbr', ()),
    ('../videotest/videotest', ()),
]
PAUSE_EVERY = '100003,40001'
PAUSE_FRAMES = 40

GREEN = 0x329411
OUT_OF_ORDER = 0xd5d5d5  # the unsupported-cartridge screen's background    # NTSC $C6 in the core's palette


def run(rom, frames, extra=()):
    r = subprocess.run([BIN, os.path.join(ROMS, rom + '.a26'), '--frames', str(frames),
                        '--out', os.path.join(OUT, rom), *extra],
                       cwd=UPSTREAM, capture_output=True, text=True)
    lines = r.stdout.splitlines()
    loaded = next((l for l in lines if l.startswith('loaded')), '')
    px = [int(l.rsplit('px ', 1)[1], 16) for l in lines if l.startswith('frame ') and ' px ' in l]
    return r.returncode, loaded.split(', ', 1)[-1], px


def too_big(rom):
    return GAMEBUB and os.path.getsize(os.path.join(ROMS, rom + '.a26')) > GAMEBUB_ROM_MAX


def check_rejected(rom):
    # The wrapper must refuse the image (FileWriteEnd error), not run it.
    rc, _, _ = run(rom, 3)
    size = os.path.getsize(os.path.join(ROMS, rom + '.a26')) // 1024
    if rc != 3:
        return (False, '%dK image not rejected' % size), (True, 'n/a: too big')
    return (True, '%dK rejected (v1 64K)' % size), (True, 'n/a: too big')


def check_bankswitch(rom, mapper, sc):
    if too_big(rom):
        return check_rejected(rom)
    rc, _, px = run(rom, 10, ('--mapper', str(mapper)) + (('--sc',) if sc else ()))
    if rc or not px:
        mapping = (False, 'simulation failed')
    elif px[-1] != GREEN:
        mapping = (False, 'status %06x, not green' % px[-1])
    else:
        mapping = (True, 'green')
    if rom in NO_DETECTION:
        return mapping, (True, 'n/a: ' + NO_DETECTION[rom])
    rc, got, _ = run(rom, 3)
    want = 'mapper %d%s' % (mapper, ' +SC' if sc else '')
    detection = (got == want, got if got == want else 'got %s, want %s' % (got, want))
    return mapping, detection


def check_multicart(rom, mapper, games):
    if too_big(rom):
        return check_rejected(rom)
    every = 3
    rc, _, px = run(rom, every * (games + 1), ('--mapper', str(mapper), '--reset-every', str(every)))
    if rc or len(px) < every * (games + 1):
        mapping = (False, 'simulation failed')
    else:
        seq = [px[every * k + every - 1] for k in range(games + 1)]
        idx = [HUES.index(c) if c in HUES else None for c in seq]
        if None in idx:
            mapping = (False, 'unexpected colour %06x' % seq[idx.index(None)])
        else:
            steps = all(idx[k + 1] == (idx[k] + 1) % 8 for k in range(games))
            shown = ' '.join(map(str, idx[:9])) + (' ...' if games > 8 else '')
            if not steps:
                mapping = (False, 'sequence %s' % idx)
            elif idx[0] != 0:
                mapping = (False, 'first game is %d, not 0 (games %s)' % (idx[0], shown))
            else:
                mapping = (True, '%d resets, games %s' % (games, shown))
    if rom in NO_DETECTION:
        return mapping, (True, 'n/a: ' + NO_DETECTION[rom])
    rc, got, _ = run(rom, 3)
    want = 'mapper %d' % mapper
    return mapping, (got == want, got if got == want else 'got %s, want %s' % (got, want))


def check_arm_unsupported():
    # ARM schemes are left out (NO_ARM_MAPPER). A blank image of DPC+'s size
    # is detected as DPC+ and must show the grey "Out of Order" screen.
    path = os.path.join(OUT, 'arm_dpcp_blank.a26')
    os.makedirs(OUT, exist_ok=True)
    with open(path, 'wb') as f:
        f.write(bytes(29696))
    r = subprocess.run([BIN, path, '--frames', '10', '--out', os.path.join(OUT, 'arm')],
                       cwd=UPSTREAM, capture_output=True, text=True)
    lines = r.stdout.splitlines()
    got = next((l for l in lines if l.startswith('loaded')), '').split(', ', 1)[-1]
    px = [int(l.rsplit('px ', 1)[1], 16) for l in lines if l.startswith('frame ') and ' px ' in l]
    if got != 'mapper 21':
        return False, 'detected %s, expected DPC+ (mapper 21)' % got
    if not px or px[-1] != OUT_OF_ORDER:
        return False, 'not the Out of Order screen'
    return True, 'DPC+ image shows Out of Order'


def check_tone():
    rc, _, _ = run('tone', 400)
    if rc:
        return False, 'simulation failed'
    d = open(os.path.join(OUT, 'tone', 'audio.wav'), 'rb').read()
    rate = struct.unpack('<I', d[24:28])[0]
    s = struct.unpack('<%dh' % ((len(d) - 44) // 2), d[44:])
    per_frame = len(s) / 400.0
    tone = s[int(10 * per_frame):int(110 * per_frame)]
    lo = min(tone)
    rises = [i for i in range(1, len(tone)) if tone[i] > tone[i - 1] and tone[i - 1] == lo]
    if len(rises) < 3:
        return False, 'no tone found'
    hz = (len(rises) - 1) / ((rises[-1] - rises[0]) / rate)
    if abs(hz - 872.2) > 1.0:
        return False, 'tone is %.1f Hz, expected 872.2' % hz
    if any(s[int(390 * per_frame):]):
        return False, 'not silent at the end'
    return True, '%.1f Hz, silent at end' % hz


def check_paddle(rom, args, meas, want_green):
    # The result screen appears after `meas` frames; the Game Bub run shows
    # one extra frame first.
    rc, _, px = run(rom, meas + 4, args)
    if rc or not px:
        return False, 'simulation failed'
    green = px[-1] == GREEN
    shown = ' '.join(args) or 'no paddle'
    if green != want_green:
        return False, '%s: status %06x, expected %s' % (shown, px[-1], 'green' if want_green else 'not green')
    return True, '%s: %s' % (shown, 'green' if green else 'not green, as it must')


def check_pause(rom, extra):
    def go(tag, more=()):
        out = os.path.join(OUT, 'pause', os.path.basename(rom) + tag)
        r = subprocess.run([BIN, os.path.join(ROMS, rom + '.a26'), '--frames', str(PAUSE_FRAMES),
                            '--out', out, *extra, *more],
                           cwd=UPSTREAM, capture_output=True, text=True)
        lines = r.stdout.splitlines()
        frames = [l for l in lines if l.startswith('frame ')]
        info = next((l for l in lines if l.startswith('paused ')), '')
        wav = open(os.path.join(out, 'audio.wav'), 'rb').read() if not r.returncode else b''
        return r.returncode, frames, info, wav
    rc1, f1, _, w1 = go('')
    rc2, f2, info, w2 = go('_paused', ('--pause-every', PAUSE_EVERY))
    if rc1 or rc2 or len(f1) != PAUSE_FRAMES:
        return False, 'simulation failed'
    late = int(info.split(', ')[-1].split()[0]) if info else -1
    if late != 0:
        return False, 'core kept running while paused (%s)' % info
    if f1 != f2:
        n = next(i for i, (a, b) in enumerate(zip(f1 + [''], f2 + [''])) if a != b)
        return False, 'frame %d differs after pauses' % n
    if w1 != w2:
        return False, 'audio differs after pauses'
    return True, '%d frames and audio identical; %s' % (PAUSE_FRAMES, info)


def check_menu():
    pal = [int(x, 16) for x in open(os.path.join(UPSTREAM, 'rtl', 'palettes', 'NWARM.hex')).read().split()]
    colour = {pal[b]: b for b in range(0, 256, 2)}   # RGB -> TIA colour byte
    out = os.path.join(OUT, 'menu')
    r = subprocess.run([BIN, os.path.join(ROMS, 'switches.a26'), '--frames', '30', '--out', out,
                        '--menu', '6'], cwd=UPSTREAM, capture_output=True, text=True)
    if r.returncode:
        return False, 'simulation failed'
    frames, steps = [], {}   # frames: (switches hue, counter, rows written, sum)
    for l in r.stdout.splitlines():
        if l.startswith('frame '):
            b = colour.get(int(l.rsplit('px ', 1)[1], 16), 0)
            rows = int(l.split(' written')[0].rsplit('x', 1)[1])
            frames.append((b >> 4, (b >> 1) & 7, rows, int(l.split(' sum ')[1].split()[0])))
        elif l.startswith('menu ') and ' swaps ' in l:
            a, z = l.split(' swaps ')[1].split()
            steps[l.split()[1].rstrip(':')] = (int(a), int(z))
    if sorted(steps) != ['closed', 'difficulty', 'open', 'reset', 'reset-close', 'tv']:
        return False, 'menu steps missing: %s' % steps
    for step in ('open', 'difficulty', 'tv'):
        a, z = steps[step]
        if z != a:
            return False, '%s: ran %d frames with the menu open' % (step, z - a)
    # Reset: black, and before it the frozen game's part-drawn frame when it
    # stopped mid-frame (the first Reset: the harness opens the menu once a
    # frame is shown, by then well into the next) but not when it stopped in
    # its vertical blank (the second).
    black = lambda f: f[2] == 240 and f[3] == 0
    special = set()
    for step, partial in (('reset', True), ('reset-close', False)):
        a, z = steps[step]
        k = a + 1 if partial else a
        if z <= k or not black(frames[k]):
            return False, '%s: no black frame (frames %s)' % (step, frames[a:z])
        if partial and frames[a][2] >= 240:
            return False, '%s: frame %d has %d rows, expected the part-drawn frame' % (
                step, a, frames[a][2])
        if frames[k + 1][1] != 1:
            return False, '%s: no restart after the black frame (counter %d)' % (step, frames[k + 1][1])
        special |= set(range(a, k + 1))
    if steps['closed'][0] != steps['reset'][1]:
        return False, 'frames ran before the menu closed'
    shown = [k for k in range(1, len(frames)) if k not in special]
    if any(frames[k][2] != 240 for k in shown):
        return False, 'part-drawn frame outside a Reset'
    if any(frames[k][0] != 0xF for k in shown if k < steps['open'][0]):
        return False, 'switches wrong before the menu'
    if any(frames[k][0] != 0x9 for k in shown if k >= steps['closed'][0]):
        return False, 'settings not applied after the menu (or lost after Reset)'
    for prev, k in zip(shown, shown[1:]):
        want = 1 if prev + 1 != k else (frames[prev][1] + 1) % 8
        if frames[k][1] != want:
            return False, 'frame %d: counter %d after %d (frames run unseen or lost)' % (
                k, frames[k][1], frames[prev][1])
    return True, 'frozen in the menu; settings applied on closing; Reset black (part-drawn ' \
                 'frame first when mid-frame); %d frames, none skipped' % len(frames)


def frame_sums(binary, rom_path, frames, out, extra=()):
    r = subprocess.run([binary, rom_path, '--frames', str(frames), '--out', out, *extra],
                       cwd=UPSTREAM, capture_output=True, text=True)
    sums = [int(l.split(' sum ', 1)[1].split()[0]) for l in r.stdout.splitlines()
            if l.startswith('frame ') and ' sum ' in l]
    return r.returncode, sums


def read_png(path):
    # The harnesses' own PNGs: 8-bit RGB, one IDAT, filter 0 on every row.
    d = open(path, 'rb').read()
    w, h = struct.unpack('>II', d[16:24])
    pos, idat = 8, b''
    while pos < len(d):
        n = struct.unpack('>I', d[pos:pos + 4])[0]
        if d[pos + 4:pos + 8] == b'IDAT':
            idat += d[pos + 8:pos + 8 + n]
        pos += 12 + n
    raw = zlib.decompress(idat)
    return [raw[y * (3 * w + 1) + 1:(y + 1) * (3 * w + 1)] for y in range(h)]


def doubled(row):
    return b''.join(row[i:i + 3] * 2 for i in range(0, len(row), 3))


# Third-party ROMs (sim/roms, fetched): the Game Bub framebuffer must hold the
# core harness's picture row for row, each pixel twice. The core harness
# keeps the lines where the game's VBLANK is off; the wrapper keeps 240
# lines from VSYNC, so the two are compared at the one vertical offset
# where they line up, and every overlapping row must match exactly.
EQUIVALENCE = ['jamesor/test-01.a26', 'jamesor/test-02.a26', 'jamesor/test-03.a26',
               'testbr/testbr.a26', 'videotest/videotest.a26']


def check_equivalence(rom):
    path = os.path.join(ROOT, 'sim', 'roms', rom)
    if not os.path.exists(path):
        return False, 'missing %s (run scripts/fetch_test_roms.sh)' % rom
    name = os.path.splitext(os.path.basename(rom))[0]
    frames = 30
    core_out = os.path.join(OUT, 'eq_core', name)
    gb_out = os.path.join(OUT, 'eq_gamebub', name)
    rc1, _ = frame_sums(CORE_BIN, path, frames, core_out)
    # The Game Bub run shows one extra frame first (the framebuffer before
    # the core's first frame), so its frame N is the core's frame N - 1.
    rc2, _ = frame_sums(GAMEBUB_BIN, path, frames + 1, gb_out)
    if rc1 or rc2:
        return False, 'simulation failed'
    core = read_png(os.path.join(core_out, 'frame_%04d.png' % (frames - 1)))
    gb = read_png(os.path.join(gb_out, 'frame_%04d.png' % frames))
    want = [doubled(r) for r in core]
    best = None
    for d in range(-len(want) + 1, len(gb)):
        pairs = [(r, r + d) for r in range(len(want)) if 0 <= r + d < len(gb)]
        if pairs and all(want[r] == gb[g] for r, g in pairs):
            if best is None or len(pairs) > best[1]:
                best = (d, len(pairs))
    if best is None or best[1] < 180:
        return False, 'no offset where the rows match (best %s)' % (best,)
    d, n = best
    return True, '%d of %d core rows match at offset %+d' % (n, len(want), d)


def check_word_gap():
    # Same ROM sent with idle cycles between words: identical frames.
    path = os.path.join(ROMS, 'bs_f6sc.a26')
    extra = ('--mapper', str(M['F6']), '--sc')
    rc1, a = frame_sums(GAMEBUB_BIN, path, 8, os.path.join(OUT, 'gap0'), extra)
    rc2, b = frame_sums(GAMEBUB_BIN, path, 8, os.path.join(OUT, 'gap7'), extra + ('--word-gap', '7'))
    if rc1 or rc2 or not a:
        return False, 'simulation failed'
    if a != b:
        return False, 'frames differ with gaps between words'
    return True, 'back-to-back and gapped loads give identical frames'


def main(argv):
    global GAMEBUB, BIN, OUT
    if '--gamebub' in argv:
        argv = [a for a in argv if a != '--gamebub']
        GAMEBUB, BIN, OUT = True, GAMEBUB_BIN, os.path.join(ROOT, 'sim', 'out', 'suite_gamebub')
    only = set(argv)
    targets = [['make', '-s', '-C', os.path.join(ROOT, 'sim', 'testroms')],
               ['make', '-s', '-C', os.path.join(ROOT, 'sim', 'core'), 'VARIANT=stub']]
    if GAMEBUB:
        targets.append(['make', '-s', '-C', os.path.join(ROOT, 'sim', 'gamebub')])
    for target in targets:
        if subprocess.run(target, stdout=subprocess.DEVNULL).returncode:
            print('build failed:', ' '.join(target))
            return 1
    failed = total = 0
    print('%-10s %-22s %s' % ('rom', 'mapping (forced)', 'detection (auto)'))
    checks = [(rom, check_bankswitch, exp) for rom, exp in BANKSWITCH.items()]
    checks += [(rom, check_multicart, exp) for rom, exp in MULTICART.items()]
    gaps, issues = [], []
    for rom, fn, exp in checks:
        if only and rom not in only:
            continue
        (mok, minfo), (dok, dinfo) = fn(rom, *exp)
        if not mok and rom in KNOWN_ISSUES:
            issues.append(rom)
            mok, minfo = True, 'ISSUE %s (%s)' % (minfo, KNOWN_ISSUES[rom])
        if not dok and rom in KNOWN_GAPS:
            gaps.append(rom)
            dok, dinfo = True, 'GAP %s (%s)' % (dinfo, KNOWN_GAPS[rom])
        print('%-10s %-22s %s' % (rom, ('PASS ' if mok else 'FAIL ') + minfo,
                                  ('PASS ' if dok else 'FAIL ') + dinfo))
        total += 2
        failed += (not mok) + (not dok)
    if not only or 'arm' in only:
        ok, info = check_arm_unsupported()
        print('%-10s %s' % ('arm', ('PASS ' if ok else 'FAIL ') + info))
        total += 1
        failed += not ok
    for name, (rom, args, meas, want) in (PADDLE_GAMEBUB if GAMEBUB else PADDLE_CORE).items():
        if only and name not in only and 'paddle' not in only:
            continue
        ok, info = check_paddle(rom, args, meas, want)
        print('%-10s %s' % (name, ('PASS ' if ok else 'FAIL ') + info))
        total += 1
        failed += not ok
    if not GAMEBUB and (not only or 'pause' in only):
        with concurrent.futures.ThreadPoolExecutor(os.cpu_count() or 4) as pool:
            results = list(pool.map(lambda p: check_pause(*p), PAUSE))
        for (rom, _), (ok, info) in zip(PAUSE, results):
            print('%-10s %s' % ('pause', ('PASS ' if ok else 'FAIL ') + os.path.basename(rom) + ': ' + info))
            total += 1
            failed += not ok
    if not only or 'tone' in only:
        ok, info = check_tone()
        print('%-10s %s' % ('tone', ('PASS ' if ok else 'FAIL ') + info))
        total += 1
        failed += not ok
    if GAMEBUB:
        for rom in EQUIVALENCE:
            if only and 'eq' not in only:
                continue
            ok, info = check_equivalence(rom)
            print('%-10s %s' % ('eq', ('PASS ' if ok else 'FAIL ') + rom + ': ' + info))
            total += 1
            failed += not ok
        if not only or 'menu' in only:
            ok, info = check_menu()
            print('%-10s %s' % ('menu', ('PASS ' if ok else 'FAIL ') + info))
            total += 1
            failed += not ok
        if not only or 'gap' in only:
            ok, info = check_word_gap()
            print('%-10s %s' % ('gap', ('PASS ' if ok else 'FAIL ') + info))
            total += 1
            failed += not ok
    notes = []
    if issues:
        notes.append('%d known mapping issue(s)' % len(issues))
    if gaps:
        notes.append('%d known detection gap(s)' % len(gaps))
    print('%d/%d checks passed%s' % (total - failed, total,
                                     ', ' + ', '.join(notes) if notes else ''))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
