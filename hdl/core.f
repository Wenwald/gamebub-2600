// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// Synthesis sources for hdl/atari2600_core.sv, in compile order. Paths are
// relative to the repo root. Upstream files come from build/upstream (the
// patched copy made by scripts/prepare_rtl.py). top.sv supplies M6502C,
// ctrl_reg and cpu_phase_controller (its Atari7800 module is never
// elaborated). mapper_fa2.sv is the non-ARM FA2 scheme. paddles.sv supplies
// paddle_timer (its other modules are never elaborated).
//
// This list is the single source of truth: sim/core compiles it, and
// prepare_rtl.py concatenates these files, in this order and followed by
// hdl/gamebub.f, into rtl/atari2600_all.sv for the Game Bub (Vivado) build
// and sim/gamebub. Sim-only sources live in sim/core/maria_full.f.
build/upstream/rtl/6502/mos6502_pkg.sv
build/upstream/rtl/detect2600.sv
build/upstream/rtl/6502/mos6502_alu.sv
build/upstream/rtl/6502/mos6502_decode.sv
build/upstream/rtl/6502/mos6502_dp.sv
build/upstream/rtl/6502/mos6502_ctl.sv
build/upstream/rtl/6502/mos6502.sv
build/upstream/rtl/6502/sally.sv
build/upstream/rtl/TIA.sv
build/upstream/rtl/paddles.sv
build/upstream/rtl/RIOT/M6532.sv
build/upstream/rtl/video_mux.sv
build/upstream/rtl/bram.v
build/upstream/rtl/cache_ram.v
build/upstream/rtl/mapper_fa2.sv
build/upstream/rtl/cart2600.sv
build/upstream/rtl/banks2600.sv
build/upstream/rtl/top.sv
hdl/maria_2600.sv
hdl/atari2600_core.sv
