<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) 2026 Mark Schlosser -->

# Test ROMs

The simulation suites use our own test ROMs (assembly in `sim/testroms/`,
built with DASM) and a few third-party ones fetched by
`scripts/fetch_test_roms.sh` into the gitignored `sim/roms/`.

Rules:
- No ROM, BIOS or game data is ever committed; for our own test ROMs only
  the `.asm` source is.
- No commercial ROMs, ever.
- Third-party test ROMs come only from GitHub repositories, after reading
  every README, LICENSE, COPYING and NOTICE in the directories used plus
  the file headers, pinned to a full 40-character commit SHA that the
  script verifies after checkout.
- A new source means updating this table and the script together.

| Source | Commit | Licence | Use |
|---|---|---|---|
| [jamesor/atari-2600-examples](https://github.com/jamesor/atari-2600-examples) | `5ec2713` | Apache-2.0 | 4K TIA basics (4098-byte images truncated to 4096) |
| [DrVector-000/A2600-Video-Test](https://github.com/DrVector-000/A2600-Video-Test) | `962b503` | MIT | 4K video test, built with DASM (PAL) |
| [giacomeli/AtariTestCartridgeBR](https://github.com/giacomeli/AtariTestCartridgeBR) | `0471414` | MIT | 4K diagnostic built from source (7 s splash) |
| [Klaus2m5/6502_65C02_functional_tests](https://github.com/Klaus2m5/6502_65C02_functional_tests) | `7954e2d` | GPL-3.0-or-later (fetched for testing only, never distributed with this project) | 6502 CPU functional test |
| Ours: `sim/testroms/*.asm` | — | MIT | tone, bank-switching schemes (`bs_*`), multicarts, paddles (`pdl_*`) |

Not usable: the ROMs under stella-emu/stella `test/roms/profile/` (not
covered by Stella's open-source licence).
