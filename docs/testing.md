<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) 2026 Mark Schlosser -->

# Testing

Everything runs in simulation (Verilator): the RTL is clocked cycle by
cycle in C++ harnesses that load a ROM, run it for N frames, and write
each frame as a PNG plus the audio as a WAV.

## Harnesses (`sim/`)

| Harness | Runs | Role |
|---|---|---|
| `console/` | Upstream's console, unmodified | The reference |
| `core/` | Our 2600 core (`hdl/atari2600_core.sv`) | Must match the reference |
| `gamebub/` | The Game Bub wrapper around the core, plus a model of the firmware (load commands, host handshake) and the framework (framebuffer write rules, video filter) | Must show the core's picture |
| `cpu/` | The 6502 alone, on Klaus Dormann's functional test | CPU correctness |
| `detect/` | Our cartridge detector and upstream's, side by side, on the same images | Lists every image where they pick a different scheme |

## Test ROMs that check themselves

Our ROMs (`sim/testroms/*.asm`) each exercise one thing: a bank-switching
scheme, a multicart, a tone, the paddles. Then they paint a status band:
**green** if every check passed, **red** otherwise. A crash leaves the band
blank, which also fails. The harness reads one pixel of the last frame,
so there are no golden images to maintain. Variants of the same source
carry their expected results as assembler symbols.

## How frames are compared

1. **Core vs. upstream:** the same ROM through `console/` and `core/` gives
   byte-identical PNGs and WAVs, and the same per-frame size and pixel
   sum. The core harness ends its ROM load on a whole CPU cycle so both
   runs line up clock for clock. (Run by hand: `make -C sim/console run`
   and `make -C sim/core run`, then `cmp` the outputs.)
2. **Every pixel's colour:** the core harness checks each output pixel's
   RGB against the palette entry for its TIA colour; the Game Bub harness
   does the same for every pixel leaving the video filter.
3. **Game Bub vs. core:** on five third-party ROMs, each framebuffer row
   must equal the core's row with every pixel doubled. The harness finds
   the one vertical offset where the rows line up and needs at least 180
   matching rows.
4. **Framebuffer bounds:** every write outside 320×240 is counted and
   fails the run.
5. **Load timing:** a ROM sent with gaps between words must produce the
   same frames as one sent back to back.
6. **Audio:** the tone ROM's frequency is measured from the WAV
   (872.2 Hz ± 1).
7. **Pause (core):** a ROM run with the core paused for 40,001 of every
   100,003 clocks gives the same frames and audio as a run without pauses,
   and no pixel comes out after the first few clocks of a pause.
8. **Menu (Game Bub):** `switches.asm` shows the console switches and a
   frame counter. With the menu open no frame is drawn; after each setting
   or Reset exactly three are, the last showing the change, and the counter
   never skips a frame.

A build variant (`make -C sim/core run VARIANT=lockstep ROM=...`) runs our MARIA
replacement in lockstep with upstream's real MARIA and stops at the first
clock where any used output differs.

## Checks that can fail

New checks are proven by breaking what they check and watching them fail:
for example three framebuffer writes per pixel, a handshake answered one
cycle early, the wrong video-filter latency, a swapped paddle direction.
The paddle checks also include runs that must *not* turn green.

## Commands

```sh
make -C sim test          # core suite
make -C sim test-gamebub  # same checks on the Game Bub wrapper, plus 3-5 and 8
make -C sim test-cpu      # 6502 functional test
python3 sim/suite.py --gamebub paddle   # one group only
make -C sim/detect run    # our detector vs. upstream's
python3 sim/detect/diff.py --dir DIR    # ... also over your own dumps in DIR
```

Needs Verilator 5.052+, DASM, the fetched test ROMs
(`scripts/fetch_test_roms.sh`, see [test-roms.md](test-roms.md)) and the
full upstream checkout in `ref/` (`scripts/fetch_upstream.sh`: the
reference console, the real MARIA and upstream's init files; the core
itself builds from the vendored `third_party/atari7800_mister/`).
