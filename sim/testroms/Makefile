# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# Our own test ROMs. Sources are committed; binaries go to the gitignored
# sim/roms/synthetic/ and are rebuilt on demand.

ROOT := $(abspath ../..)
OUT  := $(ROOT)/sim/roms/synthetic

# Single-build sources: name.asm -> name.a26
PLAIN := tone switches savestate bs_e0 bs_3f bs_f0 bs_2k bs_cv bs_e7 bs_3e bs_fe bs_wd bs_fc bs_p2

# bs_fx.asm variants: bs_<name>.a26 built with these symbols (see bs_fx.asm).
FX_4ksc  := BANKS=1  HOT=0xFFF8 RAM=128 SC4K=1
FX_f8    := BANKS=2  HOT=0xFFF8
FX_f6    := BANKS=4  HOT=0xFFF6
FX_f4    := BANKS=8  HOT=0xFFF4
FX_f8sc  := BANKS=2  HOT=0xFFF8 RAM=128
FX_f6sc  := BANKS=4  HOT=0xFFF6 RAM=128
FX_f4sc  := BANKS=8  HOT=0xFFF4 RAM=128
FX_fa    := BANKS=3  HOT=0xFFF8 RAM=256
FX_fa2   := BANKS=7  HOT=0xFFF5 RAM=256
FX_ef    := BANKS=16 HOT=0xFFE0
FX_efsc  := BANKS=16 HOT=0xFFE0 RAM=128
FX_df    := BANKS=32 HOT=0xFFC0 TAIL=1
FX_dfsc  := BANKS=32 HOT=0xFFC0 TAIL=1 RAM=128
FX_bf    := BANKS=64 HOT=0xFF80 TAIL=1
FX_bfsc  := BANKS=64 HOT=0xFF80 TAIL=1 RAM=128
FX_sb128 := BANKS=32 HOT=0x0800
FX_sb256 := BANKS=64 HOT=0x0800
FX_ua    := BANKS=2  HOT=0x0220 STRIDE=0x20
FX_0840  := BANKS=2  HOT=0x0800 STRIDE=0x40
FX_jane  := BANKS=4  JANE=1
FX_cty   := BANKS=8  FIRST=1 HOT=0xFFF5 RAM=64
FX := $(patsubst FX_%,%,$(filter FX_%,$(.VARIABLES)))

# bs_mc.asm variants (multicarts): bs_<name>.a26
MC_mc2k  := GAMES=8  GSIZE=2048
MC_mc4k  := GAMES=8  GSIZE=4096
MC_mc8k  := GAMES=8  GSIZE=8192
MC_32in1 := GAMES=32 GSIZE=2048
MC := $(patsubst MC_%,%,$(filter MC_%,$(.VARIABLES)))

# paddle.asm variants: pdl_<name>.a26, each the expected result of one run
# (A/B counts as lines, SWCHA & $F0; see paddle.asm and sim/suite.py).
# Core runs (positions set directly, count ~ 3/4 of the position):
PD_off   := ALO=192 AHI=192 BLO=192 BHI=192 SW=0xF0
PD_lo    := ALO=0   AHI=4   BLO=186 BHI=192 SW=0xF0
PD_hi    := ALO=186 AHI=192 BLO=0   BHI=4   SW=0xF0
PD_mid   := ALO=92  AHI=100 BLO=44  BHI=52  SW=0xF0
PD_btna  := ALO=92  AHI=100 BLO=44  BHI=52  SW=0x70
PD_btnb  := ALO=92  AHI=100 BLO=44  BHI=52  SW=0xB0
# Game Bub runs (paddle A on the d-pad from the centre, B at 0):
PD_gbmid   := ALO=92  AHI=100 BLO=0   BHI=4   SW=0xF0
PD_gbright := ALO=0   AHI=4   BLO=0   BHI=4   SW=0xF0 MEAS=45
PD_gbleft  := ALO=186 AHI=192 BLO=0   BHI=4   SW=0xF0 MEAS=45
PD_gbspeed := ALO=40  AHI=52  BLO=0   BHI=4   SW=0xF0 MEAS=20
PD_gbfire  := ALO=92  AHI=100 BLO=0   BHI=4   SW=0x70
PD_gbjoy   := ALO=192 AHI=192 BLO=192 BHI=192 SW=0x70
PD := $(patsubst PD_%,%,$(filter PD_%,$(.VARIABLES)))

ROMS := $(PLAIN:%=$(OUT)/%.a26) $(FX:%=$(OUT)/bs_%.a26) $(MC:%=$(OUT)/bs_%.a26) \
        $(PD:%=$(OUT)/pdl_%.a26) $(OUT)/ss_sc.a26

all: $(ROMS)

$(OUT)/%.a26: %.asm testlib.h
	mkdir -p $(OUT)
	dasm $< -f3 -v0 -o$@ -l$(OUT)/$*.lst

# dasm takes $hex, which make and the shell would mangle, so 0x values are
# passed as decimal.
defines = $(foreach kv,$(1),-D$(word 1,$(subst =, ,$(kv)))=$(shell printf '%d' $(word 2,$(subst =, ,$(kv)))))

$(FX:%=$(OUT)/bs_%.a26): $(OUT)/bs_%.a26: bs_fx.asm testlib.h Makefile
	mkdir -p $(OUT)
	dasm $< -f3 -v0 $(call defines,$(FX_$*)) -o$@ -l$(OUT)/bs_$*.lst

$(MC:%=$(OUT)/bs_%.a26): $(OUT)/bs_%.a26: bs_mc.asm testlib.h Makefile
	mkdir -p $(OUT)
	dasm $< -f3 -v0 $(call defines,$(MC_$*)) -o$@ -l$(OUT)/bs_$*.lst

$(PD:%=$(OUT)/pdl_%.a26): $(OUT)/pdl_%.a26: paddle.asm testlib.h Makefile
	mkdir -p $(OUT)
	dasm $< -f3 -v0 $(call defines,$(PD_$*)) -o$@ -l$(OUT)/pdl_$*.lst

# savestate.asm with its counter in Superchip RAM.
$(OUT)/ss_sc.a26: savestate.asm testlib.h Makefile
	mkdir -p $(OUT)
	dasm $< -f3 -v0 -DSC=1 -o$@ -l$(OUT)/ss_sc.lst

list:
	@echo $(sort $(PLAIN) $(FX:%=bs_%) $(MC:%=bs_%) $(PD:%=pdl_%) ss_sc)

clean:
	rm -rf $(OUT)

.PHONY: all list clean
