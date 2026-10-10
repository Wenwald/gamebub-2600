# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# The Game Bub wrapper (hdl/gamebub/atari2600_gamebub.sv) around the core,
# driven by a testbench that plays the firmware and the framework.
#   make                                   build
#   make run ROM=sim/roms/x/y.a26          run 60 frames into sim/out/gamebub/<rom name>/
# ROM may be absolute or relative to the repo root. ARGS passes extra options
# (--mapper M --sc --reset-every R --word-gap G --px-y Y --paddle --hold B,...).

ROOT := $(abspath ../..)
OBJ  := $(ROOT)/sim/out/obj_gamebub
BIN  := $(OBJ)/Vatari2600_gamebub
# Exactly the FPGA build's source: rtl/atari2600_all.sv (hdl/core.f +
# hdl/gamebub.f concatenated by prepare_rtl.py, with its own
# `define NO_ARM_MAPPER), plus the simulation stand-in for the MMCM.
FLISTS := $(ROOT)/hdl/core.f $(ROOT)/hdl/gamebub.f
RTLALL := $(ROOT)/rtl/atari2600_all.sv
OURS := $(filter $(ROOT)/hdl/%,$(addprefix $(ROOT)/,$(shell grep -hv '^//' $(FLISTS))))

UPSTREAM := $(ROOT)/build/upstream
# --sim: the run needs upstream's init files from ref/ (see sim/core/Makefile).
PREP     := $(UPSTREAM)/.prepared-sim
VENDORED := $(wildcard $(ROOT)/third_party/atari7800_mister/PROVENANCE $(ROOT)/third_party/atari7800_mister/rtl/*.* $(ROOT)/third_party/atari7800_mister/rtl/*/*.*)

ROM    ?= sim/roms/jamesor/test-01.a26
ROMABS := $(if $(filter /%,$(ROM)),$(ROM),$(ROOT)/$(ROM))
FRAMES ?= 60
ARGS   ?=

all: $(BIN)

$(PREP): $(wildcard $(ROOT)/patches/*.patch) $(ROOT)/scripts/prepare_rtl.py $(OURS) $(FLISTS) $(VENDORED)
	python3 $(ROOT)/scripts/prepare_rtl.py --sim

$(BIN): $(PREP) xilinx_stubs.sv tb_gamebub.cpp ../common/media.h
	mkdir -p $(OBJ)
	cd $(ROOT) && verilator --cc --exe --build -j 0 -O3 --top-module atari2600_gamebub \
		-Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
		-Wno-MULTIDRIVEN -LDFLAGS -lz \
		--Mdir $(OBJ) -o Vatari2600_gamebub $(RTLALL) $(abspath xilinx_stubs.sv) $(abspath tb_gamebub.cpp)

# Upstream init files are relative to the upstream root, so run from there.
run: $(BIN)
	cd $(UPSTREAM) && $(BIN) $(ROMABS) \
		--frames $(FRAMES) --dump-every 10 $(ARGS) \
		--out $(ROOT)/sim/out/gamebub/$(basename $(notdir $(ROM)))

clean:
	rm -rf $(OBJ)

.PHONY: all run clean
