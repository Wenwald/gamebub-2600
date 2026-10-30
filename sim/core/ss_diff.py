#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# Save-state completeness check. tb_core --ss-swap-at T,K --ss-vcd DIR (a
# TRACE=1 build) dumps every signal, paused and settled: DIR/a.vcd of the
# core that saves a state at T, just before it does; DIR/b.vcd of a second
# core that ran elsewhere in the game and then loaded that state; DIR/c.vcd
# of the first core after its own save. If every register is part of the
# state, all three are the same machine and every signal agrees. A register
# left off the chain keeps the second core's own value in b, and may be
# knocked about while the chain shifts in c; the signals it drives are
# listed here. (Comparing b with c alone would miss a register that the
# shifting sets to the same value in both, a reset value say.)
#
#   ss_diff.py DIR    exit 0 if b and c both agree with a, 1 otherwise

import sys

# video_mux's stand-in pixel clocks count every clock, whatever the state or
# the save does with it, so the operation's own clocks move them. They time
# only video_mux's own pause mode, which atari2600_core ties off.
# video_mux's blend frame store (ram0) is not part of a state either: only
# blend reads it, and atari2600_core ties blend off. Between pixels its read
# (frame_data) is also what the palette is looked up with (yuv_index), so the
# palette reads and the colour wires follow it too; the RGB registers latch a
# palette read only on a pixel, from the TIA's colour. The registers only
# blend uses (frame_ptr, old_color, old_vblank) and last_color (unused) are
# left off the chain (patches/savestate.patch).
PALETTES = ('nwarm', 'ncool', 'nhot', 'pwarm', 'pcool', 'phot', 'custom')
IGNORE = ('.mux.pix_ce_paused', '.mux.pix_ce_paused_maria', '.mux.pix_ce_paused_tia[1:0]',
          '.mux.frame_data[7:0]', '.mux.yuv_index[7:0]', '.mux.out_color[23:0]',
          '.mux.blend_color[23:0]', '.mux.frame_ptr[15:0]', '.mux.old_color[23:0]',
          '.mux.old_vblank', '.mux.last_color[15:0]') + \
    tuple('.mux.%s_color[23:0]' % p for p in PALETTES)
IGNORE_IN = ('.mux.ram0.',) + tuple('.mux.%s.' % p for p in PALETTES)


def read_vcd(path):
    """{signal name: value} for a VCD holding a single dump."""
    names = {}   # id code -> [names]
    scope = []
    values = {}
    with open(path) as f:
        it = iter(f.read().split())
    for tok in it:
        if tok == '$scope':
            next(it)
            scope.append(next(it))
            next(it)  # $end
        elif tok == '$upscope':
            scope.pop()
            next(it)
        elif tok == '$var':
            next(it)              # type
            next(it)              # width
            code = next(it)
            ref = next(it)
            t = next(it)
            while t != '$end':    # optional [msb:lsb]
                ref += t
                t = next(it)
            names.setdefault(code, []).append('.'.join(scope + [ref]))
        elif tok.startswith('#') or tok in ('$dumpvars', '$end', '$enddefinitions'):
            continue
        elif tok[0] in 'bBrR':
            values[next(it)] = tok[1:]
        elif tok[0] in '01xzXZ' and len(tok) > 1:
            values[tok[1:]] = tok[0]
    return {n: values.get(code) for code, ns in names.items() for n in ns}


def main(argv):
    if len(argv) != 1:
        print('usage: ss_diff.py DIR')
        return 2
    a = read_vcd(argv[0] + '/a.vcd')
    rc = 0
    for other, what in (('b', 'loaded'), ('c', 'saving core afterwards')):
        b = read_vcd(argv[0] + '/%s.vcd' % other)
        if set(a) != set(b):
            print('%s: the dumps hold different signals' % what)
            return 1
        bad = sorted(n for n in a if a[n] != b[n] and not n.endswith(IGNORE) and
                     not any(i in n for i in IGNORE_IN))
        for n in bad[:30]:
            print('%s differs: %s  %s / %s' % (what, n, a[n], b[n]))
        if len(bad) > 30:
            print('... and %d more' % (len(bad) - 30))
        print('%s: %d of %d signals agree' % (what, len(a) - len(bad), len(a)))
        rc |= 1 if bad else 0
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
