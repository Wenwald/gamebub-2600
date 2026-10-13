<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) 2026 Mark Schlosser -->

# Atari 2600 core for Game Bub

An Atari 2600 core for the FPGA [Game Bub](https://gamebub.net/) handheld, built
from the 2600 mode of Kitrinx's (Jamie Blanks')
[Atari7800_MiSTer](https://github.com/MiSTer-devel/Atari7800_MiSTer) core
and the [Game Bub framework](https://github.com/gamebub/framework).

By Wenwald (Mark Schlosser).

> **Unofficial port.** Not affiliated with or endorsed by Kitrinx, the
> MiSTer project or Game Bub. Please report problems
> [here](https://github.com/Wenwald/gamebub-2600/issues), not upstream.

## Status

For the Game Bub rev 4. Current version: see
[Releases](https://github.com/Wenwald/gamebub-2600/releases).

- **Emulation:** upstream's. In simulation, picture and sound are
  byte-identical to the unmodified Atari7800_MiSTer on every test ROM
  compared; a self-checking suite covers each supported bank-switching
  scheme ([docs/testing.md](docs/testing.md)).
- **On the device:** played with several real games, with both joystick and
  paddle.

## Install

1. Game Bub firmware **1.1.0-beta2 or later** is required for SD-card
   cores. When switching firmware, delete `system/*.bit.hs` from the SD
   card.
2. Download the latest `Wenwald.2600-v*.zip` from this repository's
   [Releases page](https://github.com/Wenwald/gamebub-2600/releases) and
   copy its `cores/Wenwald.2600/` folder to `/cores/` on the SD card. Keep
   the folder name exactly as it is.
3. Put your own ROMs (`.a26` or `.bin`) anywhere on the card, then choose
   **Atari 2600** and a ROM.

No ROMs or BIOS files are included or provided.

> **Notice.** Only use your own homebrew ROMs or ROMs you have rights to use.

## Controls

| Game Bub | Atari 2600 |
|---|---|
| D-pad | Joystick |
| A / B / X / Y | Fire |
| Start | Game Reset switch |
| Select | Game Select switch |

With **Controller: Paddle** in the menu, the d-pad turns the left port's
first paddle instead: Left/Right move it (slowly at first, faster the
longer you hold), and A/B/X/Y is the paddle's button. The paddle starts
centered for each ROM.

**Menu:** Reset (power cycle; multicarts advance to the next game), Left
and Right Difficulty (A/B), TV Type (Colour/B&W), Bankswitch override,
Superchip (with a forced scheme), and Controller (Joystick/Paddle).
Overrides apply after a Reset.

The game pauses while the menu is open. After you change a setting or use
Reset, it runs for a few frames (about 1/20 s) so the change shows behind
the menu, then pauses again.

## Compatibility

Works:
- NTSC games up to 64 KB using the joystick or one paddle: 2K/4K and the common
  bank-switching schemes (F8, F6, F4, FA, E0, FE, 3F, 3E, E7, F0, UA, CV,
  P2, EF, WD, FC, 0840, JANE, CTY, FA2 without saves, 32-in-1, MC
  multicarts),
  with or without Superchip RAM.
- Scheme auto-detection. Schemes it cannot detect (32-in-1,
  MC 2K/4K/8K, CTY, some FE and 3F images) can be forced in the menu.

Not supported in this version:
- **Player 2.** The Game Bub's controls drive only the first controller
  port, so two-player games can be played by one player only, and the
  second joystick or paddle never moves.
- Driving, keypad and other controllers.
- PAL and SECAM ROMs (NTSC only).
- ROMs larger than 64 KB (e.g. DF, BF, SB and large 3E/3F images); they
  are refused with an error.
- ARM-based cartridges (DPC+, CDF, BUS: many modern homebrews). They show
  a blank screen instead of upstream's "Out of Order" message.
- Supercharger (AR) games.
- 7800 games: this port contains only the 2600 side of Atari7800_MiSTer.

## What's next

Ideas, roughly in order; no promises or dates:
- ROMs larger than 64 KB, loaded into the Game Bub's external memory.
- PAL and SECAM ROMs, with a choice of palette.
- Saves for the cartridge types that have them (FA2, CTY).
- Supercharger games, once the provenance of upstream's BIOS image is clear.
- A second player, if the Game Bub's controls allow it.
- Eventually, 7800 games.

## Building

See [docs/building.md](docs/building.md). In short: Linux, Vivado 2026.1
(free BASIC licence), then `make bitstream && make package`. Releases follow
the steps in its "Releasing" section.

How it fits together:
- `hdl/atari2600_core.sv`: the upstream 2600 path (CPU, TIA, RIOT,
  cartridge mapping) with a small replacement for the 7800's MARIA chip,
  which in 2600 mode only supplies clocks.
- `hdl/detect2600.sv`: our cartridge detector, written from
  [docs/detection-spec.md](docs/detection-spec.md).
- `hdl/gamebub/`: the Game Bub wrapper (ROM loading, video, audio, inputs,
  menu settings) and the clock generator.
- `third_party/atari7800_mister/`: the upstream files the core is built
  from, unmodified except one data table the core never uses, zeroed
  (`PROVENANCE` names the upstream commit, checksums and the redaction).
- `patches/atari7800_mister.patch`: our changes to upstream, applied at
  build time to a copy; the vendored files stay untouched.
- `sim/`: Verilator test benches and a self-checking test suite, using our
  own test ROMs plus licence-vetted third-party ones fetched by
  `scripts/fetch_test_roms.sh`.

How it is tested: [docs/testing.md](docs/testing.md). Test ROM sources and
their licences: [docs/test-roms.md](docs/test-roms.md).

## Credits

By Wenwald (Mark Schlosser): the 2600-only core, cartridge detection, the
Game Bub wrapper and the test suite. Built on the emulation (CPU, TIA, RIOT,
cartridge mappers) by Kitrinx (Jamie Blanks), from Atari7800_MiSTer. Game
Bub and its framework by Eli Lipsitz.

Developed with the help of Claude (Anthropic).

Atari and Atari 2600 are trademarks of Atari Interactive, Inc. Game Bub and
other names are trademarks of their owners. They are used here only to say
what this core is compatible with; this project is not affiliated with or
endorsed by any of them.

## Licence

MIT (see [LICENSE](LICENSE)), for this project's source files and the
released bitstream. The bitstream also contains third-party components
under their own licences (MIT, CERN-OHL-W-2.0, ISC and others); see
[NOTICE](NOTICE) for all of them, including where to get the Game Bub
framework's source. Releases name the exact commits they are built from in
the zip's `SOURCE.txt`. Releases up to v1.0.1 are GPL-2.0.
