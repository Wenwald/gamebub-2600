# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# Our 2600-only core (hdl/atari2600_core.sv).
#   make                                   build
#   make run ROM=sim/roms/x/y.a26          run 60 frames into sim/out/core/<rom name>/
# ROM may be absolute or relative to the repo root.
#
# VARIANT selects how MARIA is built:
#   stub      maria_2600 (default, what the FPGA build uses)
#   full      the real upstream maria
#   lockstep  both, stopping on the first cycle they differ
VARIANT ?= stub
# TRACE=1 builds with signal tracing, for tb_core --ss-vcd (a separate
# binary; slower).
TRACE ?=

ROOT := $(abspath ../..)
DEF_stub     :=
DEF_full     := -DMARIA_FULL
DEF_lockstep := -DMARIA_LOCKSTEP
OBJ  := $(ROOT)/sim/out/obj_core_$(VARIANT)$(if $(TRACE),_trace)
TRACE_FLAGS := $(if $(TRACE),--trace --trace-max-array 256 --trace-max-width 1024 -CFLAGS -DSS_TRACE)
BIN  := $(OBJ)/Vatari2600_core
OUTV := $(if $(filter stub,$(VARIANT)),core,core_$(VARIANT))
# hdl/core.f is the synthesis source list (shared with the FPGA build);
# maria_full.f adds the sim-only real MARIA.
FLISTS := $(ROOT)/hdl/core.f maria_full.f
SRCS := $(addprefix $(ROOT)/,$(shell grep -hv '^//' $(FLISTS)))
OURS := $(filter $(ROOT)/hdl/%,$(SRCS))

# Upstream sources come from build/upstream: the vendored files (over the
# full upstream rtl/ in ref/, for MARIA and the init files) with
# patches/*.patch applied. Re-prepared whenever a patch or vendored file
# changes. ref/ comes from scripts/fetch_upstream.sh.
UPSTREAM := $(ROOT)/build/upstream
PREP     := $(UPSTREAM)/.prepared-sim
VENDORED := $(wildcard $(ROOT)/third_party/atari7800_mister/PROVENANCE $(ROOT)/third_party/atari7800_mister/rtl/*.* $(ROOT)/third_party/atari7800_mister/rtl/*/*.*)

ROM    ?= sim/roms/jamesor/test-01.a26
ROMABS := $(if $(filter /%,$(ROM)),$(ROM),$(ROOT)/$(ROM))
FRAMES ?= 60
ARGS   ?=
# Cartridge ROM address bits. 19 = 512K, the largest image any supported
# scheme uses (3E/3F); the FPGA build uses 16 = 64K (hdl/gamebub).
ROM_AW ?= 19

all: $(BIN)

$(PREP): $(wildcard $(ROOT)/patches/*.patch) $(ROOT)/scripts/prepare_rtl.py $(VENDORED)
	python3 $(ROOT)/scripts/prepare_rtl.py --sim

$(BIN): $(PREP) $(OURS) tb_core.cpp $(FLISTS) ../common/media.h
	mkdir -p $(OBJ)
	cd $(ROOT) && verilator --cc --exe --build -j 0 -O3 --top-module atari2600_core \
		-GROM_ADDR_WIDTH=$(ROM_AW) \
		-DNO_ARM_MAPPER $(DEF_$(VARIANT)) -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
		-Wno-MULTIDRIVEN -LDFLAGS -lz $(TRACE_FLAGS) \
		--Mdir $(OBJ) -o Vatari2600_core $(SRCS) $(abspath tb_core.cpp)

# Upstream init files ($readmemh "rtl/palettes/...", "rtl/ooo.hex") are
# relative to the upstream root, so run from there.
run: $(BIN)
	cd $(UPSTREAM) && $(BIN) $(ROMABS) \
		--frames $(FRAMES) --dump-every 10 $(ARGS) \
		--out $(ROOT)/sim/out/$(OUTV)/$(basename $(notdir $(ROM)))

clean:
	rm -rf $(OBJ)

.PHONY: all run clean
