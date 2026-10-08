# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# SALLY (6502) unit test against Klaus Dormann's functional test.
#   make            build
#   make test       build and run (needs scripts/fetch_test_roms.sh klaus6502)

ROOT    := $(abspath ../..)
CPU_RTL := $(ROOT)/third_party/atari7800_mister/rtl/6502
OBJ     := $(ROOT)/sim/out/obj_sally
IMAGE   := $(ROOT)/sim/roms/klaus6502/6502_functional_test.bin

# Package first; sally is the top.
SRCS := $(CPU_RTL)/mos6502_pkg.sv \
        $(CPU_RTL)/mos6502_alu.sv \
        $(CPU_RTL)/mos6502_decode.sv \
        $(CPU_RTL)/mos6502_dp.sv \
        $(CPU_RTL)/mos6502_ctl.sv \
        $(CPU_RTL)/mos6502.sv \
        $(CPU_RTL)/sally.sv

BIN := $(OBJ)/Vsally

all: $(BIN)

$(BIN): $(SRCS) tb_sally.cpp
	mkdir -p $(OBJ)
	verilator --cc --exe --build -j 0 -O3 --top-module sally \
		-Wno-fatal -Wno-lint -Wno-style \
		--Mdir $(OBJ) -o Vsally $(SRCS) $(abspath tb_sally.cpp)

test: $(BIN)
	$(BIN) $(IMAGE)

clean:
	rm -rf $(OBJ)

.PHONY: all test clean
