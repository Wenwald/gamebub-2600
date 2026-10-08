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
#   make release       release zip (package + README, NOTICE, LICENSE, COPYING.GPL-2.0)
#   make test          simulation suites (core and Game Bub wrapper)

TARGET    := gamebub_rev4
CORECLASS := atari2600.HandheldAtari2600
BUILDNAME := $(CORECLASS)-$(TARGET)
BIT       := build/$(BUILDNAME)/$(BUILDNAME).bit
COREID    := Wenwald.2600
COREDIR   := core/$(COREID)
PKG       := build/package/cores/$(COREID)
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
	@test -f $(BIT) || { echo "no bitstream: run make bitstream first"; exit 1; }
	rm -rf build/package
	mkdir -p $(PKG)
	cp $(COREDIR)/core.json $(COREDIR)/files.json $(COREDIR)/settings.json $(PKG)/
	cp $(BIT) $(PKG)/2600_rev4.bit
	@echo "copy $(PKG) to /cores/$(COREID) on the SD card"
	@ls -l $(PKG)

# The zip mirrors the SD card: cores/<id>/... plus the licence documents
# (LICENSE = MIT for our sources; COPYING.GPL-2.0 covers the bitstream as a
# whole, see NOTICE).
release: package
	rm -rf build/release
	mkdir -p build/release/stage
	cp -r build/package/cores build/release/stage/
	cp README.md NOTICE LICENSE COPYING.GPL-2.0 build/release/stage/
	cd build/release/stage && python3 -m zipfile -c ../$(notdir $(RELEASE)) cores README.md NOTICE LICENSE COPYING.GPL-2.0
	rm -rf build/release/stage
	@cd build/release && sha256sum $(notdir $(RELEASE))

test:
	$(MAKE) -C sim test
	$(MAKE) -C sim test-gamebub

.PHONY: prepare check-chisel bitstream package release test
