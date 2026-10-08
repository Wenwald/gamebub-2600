#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# Fetch the full upstream Atari7800_MiSTer at the commit pinned in
# third_party/atari7800_mister/PROVENANCE into ref/Atari7800_MiSTer
# (gitignored). Simulation only: the reference console (sim/console), the
# full MARIA variant and upstream's $readmemh init files come from here. The
# bitstream is built from the vendored files alone; this checkout is never
# distributed (it also holds files we must not ship, e.g. rtl/ar.hex).
#
# Usage: scripts/fetch_upstream.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROV="$ROOT/third_party/atari7800_mister/PROVENANCE"
DST="$ROOT/ref/Atari7800_MiSTer"

die() { echo "error: $*" >&2; exit 1; }

URL="$(awk '$1 == "url" { print $2 }' "$PROV")"
COMMIT="$(awk '$1 == "commit" { print $2 }' "$PROV")"
[[ ${#COMMIT} -eq 40 ]] || die "no 40-character commit in $PROV"

if [[ -d "$DST/.git" ]] && [[ "$(git -C "$DST" rev-parse HEAD)" == "$COMMIT" ]]; then
	echo "ref/Atari7800_MiSTer already at ${COMMIT:0:12}"
else
	rm -rf "$DST"
	mkdir -p "$DST"
	git -C "$DST" init -q
	git -C "$DST" fetch -q --depth 1 "$URL" "$COMMIT"
	git -C "$DST" checkout -q FETCH_HEAD
	[[ "$(git -C "$DST" rev-parse HEAD)" == "$COMMIT" ]] || die "checkout is not at $COMMIT"
	echo "fetched $URL ${COMMIT:0:12} into ref/Atari7800_MiSTer"
fi

python3 "$ROOT/scripts/vendor_upstream.py" check "$DST"
