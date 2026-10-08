<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) 2026 Mark Schlosser -->

# Building the core

## Requirements

- Linux (x86-64) with Vivado 2026.1 and its free licence.
- `git`, `make`, `patch`, Python 3.12 or newer, internet access on the
  first build (the framework fetches its own Java, Chisel tools and
  Python packages).

## Build

```sh
git clone --recurse-submodules https://github.com/Wenwald/gamebub-2600
cd gamebub-2600
source <Vivado install dir>/2026.1/Vivado/settings64.sh
make bitstream package release
```

- `make bitstream` builds the bitstream (a few minutes).
- `make package` puts the SD-card folder in `build/package/cores/Wenwald.2600/`.
- `make release` zips it with the licence files into `build/release/`.

Install as described in the [README](../README.md): copy the
`Wenwald.2600` folder to `/cores/` on the SD card.

## Tests (optional)

`make test` runs the simulation suites. It needs Verilator 5.052 or
newer, DASM, and the test ROMs, which `scripts/fetch_test_roms.sh` fetches
(see [test-roms.md](test-roms.md)).

---

<sub>Built and tested by the author on Debian 13 with Vivado 2026.1
(BASIC licence). Debian is not officially supported by Vivado; it also
needs `libtinfo5` from Debian 12.</sub>
