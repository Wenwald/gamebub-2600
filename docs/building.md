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
make bitstream package
```

- `make bitstream` builds the bitstream (a few minutes).
- `make package` puts the SD-card folder in `build/package/cores/Wenwald.2600/`.
- `make clean` deletes generated files (keeping `build/release/`);
  `make clean-release` deletes only `build/release/`; `make distclean`
  does both and also deletes the downloaded test inputs.

Install as described in the [README](../README.md): copy the
`Wenwald.2600` folder to `/cores/` on the SD card.

## Releasing (maintainer)

`main` takes changes only through pull requests, squash-merged. Between
releases `version` in `core/Wenwald.2600/core.json` is `X.Y.Z-dev`. Work
on branches named like `dev-X.Y.Z` (not `vX.Y.Z`, which is the tag's name).

To release:

1. Open a PR whose last change sets `version` to `X.Y.Z`, and squash-merge
   it ("Release vX.Y.Z"). That squash commit on `main` is the release
   commit.
2. On `main` at that commit: `git tag vX.Y.Z`, then
   `make bitstream package release`, then `git push origin refs/tags/vX.Y.Z`
   and publish the zip in `build/release/` as GitHub release
   `vX.Y.Z`.
3. Start the next cycle: a new branch whose first commit sets the next
   `X.Y.Z-dev`.

Tag and build only after the merge: squashing makes a new commit, so a
tag or bitstream from the branch would not match `main`. `make release`
refuses anything else (a `-dev` version, uncommitted changes, a missing
tag, or a bitstream built from another commit). It zips the package with
a player README (cut from this repo's README: install, controls,
compatibility, credits, licence), `LICENSE`, `NOTICE` and `SOURCE.txt`
into `build/release/`.

## Tests (optional)

`make test` runs the simulation suites. It needs Verilator 5.052 or
newer, DASM, the test ROMs, which `scripts/fetch_test_roms.sh` fetches
(see [test-roms.md](test-roms.md)), and the full upstream checkout, which
`scripts/fetch_upstream.sh` fetches into `ref/`.

---

<sub>Built and tested by the author on Debian 13 with Vivado 2026.1
(BASIC licence). Debian is not officially supported by Vivado; it also
needs `libtinfo5` from Debian 12.</sub>
