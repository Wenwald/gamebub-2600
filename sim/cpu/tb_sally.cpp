// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// Runs Klaus Dormann's 6502 functional test on SALLY (the 6502 used by the
// 2600 path) with a flat 64K memory model.
//
//   tb_sally <6502_functional_test.bin> [success_addr=0x3469] [max_cycles]
//
// The test image is loaded into memory as-is, then the reset vector is
// pointed at the test's entry ($0400). Pass = an opcode fetch at the success
// trap. Fail = any other `jmp *` trap (two consecutive opcode fetches at the
// same address), a jammed CPU, or running out of cycles.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "Vsally.h"
#include "verilated.h"

// clk_sys ticks per CPU cycle. The 2600 uses 12; anything >= 4 exercises the
// same enable-driven logic and is faster.
static constexpr int kTicksPerCycle = 4;

int main(int argc, char **argv) {
	if (argc < 2) {
		std::fprintf(stderr, "usage: %s image.bin [success_addr] [max_cycles]\n", argv[0]);
		return 2;
	}
	const uint16_t success = argc > 2 ? std::strtoul(argv[2], nullptr, 0) : 0x3469;
	const uint64_t max_cycles = argc > 3 ? std::strtoull(argv[3], nullptr, 0) : 100'000'000ULL;

	std::vector<uint8_t> mem(0x10000, 0);
	FILE *f = std::fopen(argv[1], "rb");
	if (!f || std::fread(mem.data(), 1, mem.size(), f) != mem.size()) {
		std::fprintf(stderr, "cannot read a 64K image from %s\n", argv[1]);
		return 2;
	}
	std::fclose(f);
	mem[0xFFFC] = 0x00;  // reset vector -> start ($0400)
	mem[0xFFFD] = 0x04;

	auto *ctx = new VerilatedContext;
	ctx->commandArgs(argc, argv);
	auto *cpu = new Vsally{ctx};

	cpu->rdy = 1;
	cpu->irq_n = 1;
	cpu->nmi_n = 1;
	cpu->so_n = 1;
	cpu->halt_n = 1;
	cpu->res_n = 0;

	uint64_t tick = 0, cycles = 0;
	int last_fetch = -1;
	auto step = [&]() {
		const int phase = tick % kTicksPerCycle;
		cpu->phi1_en = phase == 0;
		cpu->phi2_en = phase == kTicksPerCycle / 2;
		// The bus as it stands before this edge: reads are answered
		// combinationally; a write lands at the end of its cycle.
		if (cpu->phi1_en && !cpu->rw_n && cpu->res_n)
			mem[cpu->addr_out] = cpu->data_out;
		cpu->data_in = mem[cpu->addr_out];
		cpu->clk_sys = 0;
		cpu->eval();
		cpu->clk_sys = 1;
		cpu->eval();
		tick++;
	};

	// Hold reset for a few CPU cycles so the core sees it on real enables.
	for (int i = 0; i < 8 * kTicksPerCycle; i++) step();
	cpu->res_n = 1;

	int rc = 1;
	const char *why = "ran out of cycles";
	uint16_t at = 0;
	while (cycles < max_cycles) {
		// Sample at the start of each CPU cycle, just after phase 1 begins.
		for (int i = 0; i < kTicksPerCycle; i++) step();
		cycles++;
		if (cpu->jammed) { why = "CPU jammed"; at = cpu->addr_out; break; }
		if (!cpu->sync) continue;
		const uint16_t pc = cpu->addr_out;
		if (pc == success) { rc = 0; why = "reached success trap"; at = pc; break; }
		if (pc == last_fetch) { why = "trapped (jmp *)"; at = pc; break; }
		last_fetch = pc;
	}

	std::printf("%s: %s at $%04X after %llu cycles\n", rc ? "FAIL" : "PASS", why, at,
	            static_cast<unsigned long long>(cycles));
	cpu->final();
	delete cpu;
	delete ctx;
	return rc;
}
