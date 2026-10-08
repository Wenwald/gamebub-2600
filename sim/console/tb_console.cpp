// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// Reference harness: the unmodified upstream console (top.sv, module
// Atari7800, real MARIA) tied into 2600 mode, running a cartridge image from
// a 1-cycle synchronous ROM model (what the FPGA build will use in place of
// MiSTer's SDRAM).
//
//   tb_console rom.a26 [--frames N] [--out DIR] [--dump-every K] [--mapper M]
//
// Writes DIR/frame_NNNN.png for every K-th frame (and always the last one),
// DIR/audio.wav (mono, 16-bit), and prints a per-frame summary line.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "../common/media.h"
#include "VAtari7800.h"
#include "verilated.h"

int main(int argc, char **argv) {
	std::string rom_path, out = "sim/out/console";
	int frames = 60, dump_every = 0, mapper = 0;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() { return i + 1 < argc ? argv[++i] : (char *)""; };
		if (a == "--frames") frames = std::atoi(next());
		else if (a == "--out") out = next();
		else if (a == "--dump-every") dump_every = std::atoi(next());
		else if (a == "--mapper") mapper = std::atoi(next());
		else if (a[0] != '+') rom_path = a;
	}
	if (rom_path.empty()) {
		std::fprintf(stderr, "usage: %s rom.a26 [--frames N] [--out DIR] [--dump-every K] [--mapper M]\n", argv[0]);
		return 2;
	}

	std::vector<uint8_t> rom;
	{
		FILE *f = std::fopen(rom_path.c_str(), "rb");
		if (!f) { std::fprintf(stderr, "cannot open %s\n", rom_path.c_str()); return 2; }
		uint8_t b[4096];
		size_t n;
		while ((n = std::fread(b, 1, sizeof b, f)) > 0) rom.insert(rom.end(), b, b + n);
		std::fclose(f);
	}
	std::string mk = "mkdir -p '" + out + "'";
	if (std::system(mk.c_str()) != 0) return 2;

	auto *ctx = new VerilatedContext;
	ctx->commandArgs(argc, argv);
	auto *c = new VAtari7800{ctx};

	// 2600 mode, no BIOS, TIA drives the CPU clock (see extraction notes §7).
	c->tia_mode = 1;
	c->bypass_bios = 1;
	c->cpu_driver = 1;
	c->cart_present = 1;
	c->PAL = 0;
	c->show_border = 1;
	c->show_overscan = 0;
	c->force_bs = mapper;
	c->cart_size = uint32_t(rom.size());
	// Controllers idle (active low), console switches up, colour mode.
	c->PAin = 0xFF;
	c->ilatch = 0x3;
	c->idump = 0;
	c->reset = 1;
	c->arm_reset = 1;

	const uint64_t ticks_per_frame = 228ULL * 262 * 4;  // NTSC, nominal
	const uint64_t max_ticks = ticks_per_frame * uint64_t(frames + 4) * 2;
	uint8_t rom_q = 0;

	// Frame capture state, driven by the video_mux outputs on ce_pix.
	std::vector<uint8_t> line, frame;
	int width = 0, height = 0, frame_no = 0;
	bool prev_vblank = true, prev_hblank = true;
	std::vector<int16_t> audio;
	uint64_t tick = 0;

	while (frame_no < frames && tick < max_ticks) {
		if (tick == 64) { c->reset = 0; c->arm_reset = 0; }
		// Console switches up: PB0 reset, PB1 select, PB3 colour, PB6/7
		// difficulty. PB2/4/5 are unconnected and read back what RIOT drives.
		c->PBin = (c->PBout & 0x34) | 0xCB;

		// Synchronous ROM: the address before this edge is what the block RAM
		// latches; its data is visible after the edge.
		const uint32_t mask = rom.size() ? uint32_t(rom.size() - 1) : 0;
		const uint8_t q_next = rom.empty() ? 0xFF : rom[c->cart_addr_out & mask];
		c->clk_sys = 0; c->clk_arm = 0;
		c->eval();
		c->clk_sys = 1; c->clk_arm = 1;
		c->eval();
		rom_q = q_next;
		c->cart_out = rom_q;
		tick++;

		if (tick % media::kAudioDivider == 0)
			audio.push_back(int16_t(c->AUDIO_L & 0x7FFF));  // TIA mix: 0 = silence, max 0x7FFF

		if (!c->ce_pix) continue;
		const bool hb = c->HBlank, vb = c->VBlank;
		if (!hb && !vb) {
			line.push_back(c->RED);
			line.push_back(c->GREEN);
			line.push_back(c->BLUE);
		}
		if (hb && !prev_hblank && !line.empty()) {
			width = int(line.size() / 3);
			frame.insert(frame.end(), line.begin(), line.end());
			line.clear();
		}
		if (vb && !prev_vblank) {
			height = width ? int(frame.size() / 3 / width) : 0;
			const bool last = frame_no == frames - 1;
			if (width && height && (last || (dump_every && frame_no % dump_every == 0))) {
				char name[64];
				std::snprintf(name, sizeof name, "/frame_%04d.png", frame_no);
				media::write_png(out + name, width, height, frame);
			}
			uint64_t sum = 0;
			for (uint8_t b : frame) sum += b;
			std::printf("frame %4d  %3dx%-3d  sum %llu\n", frame_no, width, height,
			            static_cast<unsigned long long>(sum));
			frame.clear();
			frame_no++;
		}
		prev_hblank = hb;
		prev_vblank = vb;
	}

	media::write_wav(out + "/audio.wav", audio);
	std::printf("%d frames, %llu ticks, %zu audio samples -> %s\n", frame_no,
	            static_cast<unsigned long long>(tick), audio.size(), out.c_str());
	c->final();
	delete c;
	delete ctx;
	return frame_no == frames ? 0 : 1;
}
