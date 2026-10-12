# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# Differential detector test: hdl/detect2600.sv against upstream's detector.
#   make                 build
#   make run             run diff.py (test ROMs + synthetic images)
#
# Upstream's detector is NOT part of this repository. It is taken from the
# full upstream checkout in ref/ (scripts/fetch_upstream.sh) at build time
# and renamed (module, enum and its members get an old_/OLD_ prefix) so both
# can be compiled together. Nobody needs to read it: it is a black box here.

ROOT := $(abspath ../..)
OBJ  := $(ROOT)/sim/out/obj_detect
BIN  := $(OBJ)/Vdetect_diff
OLD_SRC := $(ROOT)/ref/Atari7800_MiSTer/rtl/detect2600.sv
OLD  := $(OBJ)/old_detect2600.sv
NEW  ?= $(ROOT)/hdl/detect2600.sv

all: $(BIN)

# Rebuild when NEW names a different file (e.g. a sabotaged copy).
STAMP := $(OBJ)/new-src
$(shell mkdir -p $(OBJ); [ "$$(cat $(STAMP) 2>/dev/null)" = "$(NEW)" ] || echo "$(NEW)" > $(STAMP))

$(OLD): $(OLD_SRC)
	@test -f $(OLD_SRC) || { echo "run scripts/fetch_upstream.sh"; exit 1; }
	mkdir -p $(OBJ)
	sed -e 's/\bdetect2600\b/old_detect2600/g' -e 's/\bmatch_bytes\b/old_match_bytes/g' \
	    -e 's/\bbss_type\b/old_bss_type/g' -e 's/\bBANK\([0-9A-Z]\)/OLD_BANK\1/g' \
	    $(OLD_SRC) > $@

$(BIN): $(OLD) $(NEW) $(STAMP) detect_diff.sv tb_detect.cpp
	verilator --cc --exe --build -j 0 -O2 --top-module detect_diff \
		-Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
		--Mdir $(OBJ) -o Vdetect_diff $(NEW) $(OLD) detect_diff.sv $(abspath tb_detect.cpp)

run: $(BIN)
	python3 diff.py

clean:
	rm -rf $(OBJ)

.PHONY: all run clean
