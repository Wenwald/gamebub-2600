# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# Reference build: the unmodified upstream console in 2600 mode, from the
# full upstream checkout in ref/ (scripts/fetch_upstream.sh).
#   make                         build
#   make run ROM=sim/roms/x/y.a26          run 60 frames into sim/out/console/<rom name>/
# ROM may be absolute or relative to the repo root.

ROOT := $(abspath ../..)
OBJ  := $(ROOT)/sim/out/obj_console
BIN  := $(OBJ)/VAtari7800
SRCS := $(addprefix $(ROOT)/,$(shell grep -v '^//' upstream.f))
REF  := $(ROOT)/ref/Atari7800_MiSTer

ROM    ?= sim/roms/jamesor/test-01.a26
ROMABS := $(if $(filter /%,$(ROM)),$(ROM),$(ROOT)/$(ROM))
FRAMES ?= 60

all: $(BIN)

$(BIN): $(SRCS) tb_console.cpp upstream.f ../common/media.h
	mkdir -p $(OBJ)
	cd $(ROOT) && verilator --cc --exe --build -j 0 -O3 --top-module Atari7800 \
		-DNO_ARM_MAPPER -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
		-Wno-MULTIDRIVEN -LDFLAGS -lz \
		--Mdir $(OBJ) -o VAtari7800 $(SRCS) $(abspath tb_console.cpp)

# Upstream init files ($readmemh "rtl/palettes/...", "rtl/ooo.hex") are
# relative to the upstream repo root, so run from there.
run: $(BIN)
	cd $(REF) && $(BIN) $(ROMABS) \
		--frames $(FRAMES) --dump-every 10 \
		--out $(ROOT)/sim/out/console/$(basename $(notdir $(ROM)))

$(REF)/%:
	@echo "missing $@: run scripts/fetch_upstream.sh"; exit 1

clean:
	rm -rf $(OBJ)

.PHONY: all run clean
