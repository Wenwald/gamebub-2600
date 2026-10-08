#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# Fetch and build the licence-vetted test ROMs into sim/roms/ (gitignored).
#
# Rules (see docs/test-roms.md):
#   - GitHub repositories only. No other hosts, no release assets, no web
#     downloads.
#   - Every source is pinned to a full 40-character commit SHA, verified after
#     checkout.
#   - Every source is listed in docs/test-roms.md with its vetted licence.
#     Add or change a source here and in that table together.
#   - Output goes to sim/roms/ only. Nothing here is ever committed.
#
# Usage:
#   scripts/fetch_test_roms.sh            fetch and build everything
#   scripts/fetch_test_roms.sh --list     print the plan, touch nothing
#   scripts/fetch_test_roms.sh NAME...    fetch and build only these sources
#
# Needs: git, and dasm for the sources built from assembly
# (`brew install dasm`).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/sim/roms"
SRC="$OUT/.src"

# name | GitHub repo URL | pinned commit | licence (as vetted in docs/test-roms.md)
SOURCES=(
	"jamesor|https://github.com/jamesor/atari-2600-examples|5ec2713541d50c95cd2d5daab021e2676c457aff|Apache-2.0"
	"videotest|https://github.com/DrVector-000/A2600-Video-Test|962b50340fec7306d1ee6d5108529f452b764368|MIT"
	"testbr|https://github.com/giacomeli/AtariTestCartridgeBR|047141498bd194e8b4e80f7c14182724e421981e|MIT"
	"klaus6502|https://github.com/Klaus2m5/6502_65C02_functional_tests|7954e2dbb49c469ea286070bf46cdd71aeb29e4b|GPL-3.0-or-later"
)

die() { echo "error: $*" >&2; exit 1; }

# Per-source build step. Runs inside the pinned checkout; $1 is the output dir.
build_jamesor() {
	# Binaries and reference screenshots are committed in the pinned repo.
	# The sources emit three vector words from `org $FFFC`, so each image runs
	# 2 bytes past $FFFF (4098 bytes). The first 4K is the real cartridge.
	local dst=$1 n
	for n in 01 02 03 04; do
		head -c 4096 "bin/test-$n.bin" >"$dst/test-$n.a26"
		cp "snaps/test-$n.png" "$dst/test-$n.ref.png"
	done
}

build_videotest() {
	# Source only. Single 4K image; includes resolve from the repo root.
	local dst=$1
	dasm VideoTest.asm -f3 -v0 -o"$dst/videotest.a26" -l"$dst/videotest.lst"
	cp Images/VideoTest\ Page\ *.png "$dst/"
}

build_testbr() {
	# Same dasm invocation as the repo's Makefile, but with the system dasm
	# instead of the Makefile's bundled tools/dasm.
	local dst=$1
	dasm src/main.asm -f3 -v0 -Iinclude -Isrc -o"$dst/testbr.a26" -l"$dst/testbr.lst"
	cp docs/screenshots/*.png "$dst/"
}

build_klaus6502() {
	# Flat 64K CPU test image (not a cartridge), committed prebuilt. The
	# decimal test has no prebuilt binary and needs the bundled as65 (a DOS
	# tool), so it is left out for now.
	local dst=$1
	cp bin_files/6502_functional_test.bin bin_files/6502_functional_test.lst "$dst/"
}

list() {
	local entry name url sha lic
	for entry in "${SOURCES[@]}"; do
		IFS='|' read -r name url sha lic <<<"$entry"
		printf '%-10s %-17s %s @ %s\n' "$name" "$lic" "$url" "${sha:0:12}"
	done
}

fetch_one() {
	local name=$1 url=$2 sha=$3 lic=$4
	local repo="$SRC/$name" dst="$OUT/$name"

	[[ $url =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
		die "$name: not a GitHub repository URL: $url"
	[[ $sha =~ ^[0-9a-f]{40}$ ]] || die "$name: commit is not a full SHA: $sha"

	echo "== $name ($lic) $url @ ${sha:0:12}"
	if [[ ! -d $repo/.git ]]; then
		git init -q "$repo"
		git -C "$repo" remote add origin "$url"
	fi
	[[ $(git -C "$repo" remote get-url origin) == "$url" ]] ||
		die "$name: existing checkout points at a different remote"
	git -C "$repo" fetch -q --depth 1 origin "$sha"
	git -C "$repo" -c advice.detachedHead=false checkout -q --force FETCH_HEAD
	[[ $(git -C "$repo" rev-parse HEAD) == "$sha" ]] ||
		die "$name: checked-out commit does not match the pin"

	rm -rf "$dst"
	mkdir -p "$dst"
	(cd "$repo" && "build_$name" "$dst")

	# Keep the licence with what it covers.
	local f
	for f in LICENSE LICENSE.txt license.txt COPYING; do
		[[ -f $repo/$f ]] && cp "$repo/$f" "$dst/"
	done
	printf '%s\n%s\n%s\n' "$url" "$sha" "$lic" >"$dst/SOURCE"
}

main() {
	if [[ ${1:-} == --list ]]; then
		list
		return
	fi

	command -v git >/dev/null || die "git not found"
	command -v dasm >/dev/null || die "dasm not found (brew install dasm)"

	# A plain string, not an array: macOS bash 3.2 treats an empty array as
	# unset under `set -u`.
	local want=" $* " entry name url sha lic ran=0
	mkdir -p "$SRC"
	for entry in "${SOURCES[@]}"; do
		IFS='|' read -r name url sha lic <<<"$entry"
		if [[ $want != "  " && $want != *" $name "* ]]; then
			continue
		fi
		fetch_one "$name" "$url" "$sha" "$lic"
		ran=$((ran + 1))
	done
	((ran)) || die "no matching sources (try --list)"
	echo "done: $ran source(s) in ${OUT#"$ROOT"/}/"
}

main "$@"
