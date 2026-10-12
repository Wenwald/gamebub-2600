# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# Atari 2600 core for Game Bub. See docs/building.md.
#
#   make prepare       patch upstream RTL, generate the palette and rtl/
#   make check-chisel  run Chisel and check the wrapper's ports against the
#                      framework template (no Vivado; needs firtool)
#   make bitstream     full build: prepare, check, Chisel + Vivado (Linux,
#                      Vivado 2026.1 on PATH)
#   make package       SD card folder: build/package/cores/Wenwald.2600/
#   make release       release zip (package + player README, NOTICE, LICENSE,
#                      SOURCE.txt); only on a tagged X.Y.Z release commit
#                      (see below)
#   make test          simulation suites (core and Game Bub wrapper)
#   make clean         delete generated files (rtl/, build/ except
#                      build/release/, out/, sim/out/, built test ROMs)
#   make clean-release delete build/release/ only (release zips)
#   make distclean     also build/release/ and the downloads (sim/roms/,
#                      ref/Atari7800_MiSTer); fetch again with
#                      scripts/fetch_test_roms.sh and scripts/fetch_upstream.sh

TARGET    := gamebub_rev4
CORECLASS := atari2600.HandheldAtari2600
BUILDNAME := $(CORECLASS)-$(TARGET)
BIT       := build/$(BUILDNAME)/$(BUILDNAME).bit
COREID    := Wenwald.2600
COREDIR   := core/$(COREID)
PKG       := build/package/cores/$(COREID)
# The version, from core.json (the only place it lives). Between releases it
# is X.Y.Z-dev; the release commit changes only that to X.Y.Z, gets the tag
# vX.Y.Z, and the release is built from it (make release checks all that).
VERSION   := $(shell python3 -c "import json; print(json.load(open('$(COREDIR)/core.json'))['metadata']['version'])")
RELEASE   := build/release/$(COREID)-v$(VERSION).zip

prepare:
	python3 scripts/prepare_rtl.py

check-chisel: prepare
	python3 scripts/check_ports.py

bitstream: check-chisel
	@command -v vivado >/dev/null || { echo "vivado not on PATH (source Vivado's settings64.sh)"; exit 1; }
	./framework/mill -i root.buildCore --target $(TARGET)
	@ls -l $(BIT)

package:
	@echo "$(VERSION)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-dev)?$$' && [ $$(printf %s "$(VERSION)" | wc -c) -le 16 ] || { echo "core.json version must be X.Y.Z or X.Y.Z-dev, at most 16 characters (firmware limit), got '$(VERSION)'"; exit 1; }
	@test -f $(BIT) || { echo "no bitstream: run make bitstream first"; exit 1; }
	rm -rf build/package
	mkdir -p $(PKG)
	cp $(COREDIR)/core.json $(COREDIR)/files.json $(COREDIR)/settings.json $(PKG)/
	cp $(BIT) $(PKG)/2600_rev4.bit
	@echo "copy $(PKG) to /cores/$(COREID) on the SD card"
	@ls -l $(PKG)

# The zip mirrors the SD card: cores/<id>/... plus the licence documents
# (LICENSE = MIT; third-party notices and the framework source location in
# NOTICE).
release: package
	python3 scripts/release_source.py check-release $(VERSION) $(BIT)
	rm -rf build/release
	mkdir -p build/release/stage
	cp -r build/package/cores build/release/stage/
	python3 scripts/release_readme.py README.md build/release/stage/README.md
	cp NOTICE LICENSE build/release/stage/
	python3 scripts/release_source.py source-txt build/release/stage/SOURCE.txt $(VERSION)
	cd build/release/stage && python3 -m zipfile -c ../$(notdir $(RELEASE)) cores README.md NOTICE LICENSE SOURCE.txt
	rm -rf build/release/stage
	@cd build/release && sha256sum $(notdir $(RELEASE))

test:
	$(MAKE) -C sim test
	$(MAKE) -C sim test-gamebub

# Keeps build/release/ (published zips); distclean removes it too.
clean:
	rm -rf rtl out sim/out sim/roms/synthetic
	@if [ -d build ]; then find build -mindepth 1 -maxdepth 1 ! -name release -exec rm -rf {} +; fi

clean-release:
	rm -rf build/release

distclean: clean clean-release
	rm -rf build sim/roms ref/Atari7800_MiSTer

.PHONY: prepare check-chisel bitstream package release test clean clean-release distclean
