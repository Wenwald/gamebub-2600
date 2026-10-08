// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// Harness for hdl/atari2600_core.sv. Streams the cartridge image in through
// the load port with the core in reset (as the Game Bub loader will), then
// runs it and captures video and audio the same way tb_console does, so the
// per-frame lines of the two can be compared directly.
//
//   tb_core rom.a26 [--frames N] [--out DIR] [--dump-every K] [--mapper M]
//                   [--sc] [--reset-every R] [--paddle A[,B]] [--paddle-btn a|b|ab]
//
// --mapper M forces bankswitch scheme M (the bss_type number); --sc adds
// Superchip RAM to it.
//
// --reset-every R presses the console's power-on reset (the core's reset
// input) for 64 clocks at the start of every R-th frame after the first, as
// the multicart schemes need. Each frame line ends with the colour of the
// pixel at (80, 32): the test ROMs' status band.
//
// --paddle A[,B] connects paddles to the left port (paddle_en) at positions
// A and B (0..255, default B = 0); --paddle-btn holds paddle A's and/or B's
// button (pa_in bit 7 / bit 6) for the whole run.

#include <fstream>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "../common/media.h"
#include "Vatari2600_core.h"
#include "verilated.h"

int main(int argc, char **argv) {
	std::string rom_path, out = "sim/out/core";
	int frames = 60, dump_every = 0, mapper = 0, reset_every = 0;
	bool sc = false, paddle_en = false;
	int paddle_a = 0, paddle_b = 0;
	std::string paddle_btn;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() { return i + 1 < argc ? argv[++i] : (char *)""; };
		if (a == "--frames") frames = std::atoi(next());
		else if (a == "--out") out = next();
		else if (a == "--dump-every") dump_every = std::atoi(next());
		else if (a == "--mapper") mapper = std::atoi(next());
		else if (a == "--reset-every") reset_every = std::atoi(next());
		else if (a == "--sc") sc = true;
		else if (a == "--paddle") {
			paddle_en = true;
			const std::string v = next();
			paddle_a = std::atoi(v.c_str());
			const size_t comma = v.find(',');
			if (comma != std::string::npos) paddle_b = std::atoi(v.c_str() + comma + 1);
		} else if (a == "--paddle-btn") paddle_btn = next();
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
	auto *c = new Vatari2600_core{ctx};

	c->mapper_override = mapper;
	c->sc_override = sc;
	c->pa_in = 0xFF;
	if (paddle_btn.find('a') != std::string::npos) c->pa_in &= ~0x80;
	if (paddle_btn.find('b') != std::string::npos) c->pa_in &= ~0x40;
	c->fire_n = 0x3;
	c->paddle = 0;
	c->paddle_en = paddle_en;
	c->paddle_pos_a = paddle_a;
	c->paddle_pos_b = paddle_b;
	c->sw_reset_n = 1;
	c->sw_select_n = 1;
	c->sw_color = 1;
	c->sw_diff_left = 1;
	c->sw_diff_right = 1;
	c->reset = 1;

	uint64_t tick = 0;
	auto step = [&]() {
		c->clk_sys = 0;
		c->eval();
		c->clk_sys = 1;
		c->eval();
		tick++;
	};

	// Load: start pulse, one byte per clock, end pulse, all under reset.
	for (int i = 0; i < 8; i++) step();
	c->load_start = 1; step(); c->load_start = 0;
	for (size_t a = 0; a < rom.size(); a++) {
		c->load_valid = 1;
		c->load_addr = uint32_t(a);
		c->load_data = rom[a];
		step();
	}
	c->load_valid = 0;
	step();
	c->load_end = 1; step(); c->load_end = 0;
	for (int i = 0; i < 8; i++) step();
	// The core's clock dividers run freely through the load. Finish it on a
	// whole 12-clock CPU cycle so the run that follows lines up with
	// tb_console's (no load) clock for clock, and audio sampled at fixed
	// ticks compares byte for byte.
	while (tick % 12) step();
	std::printf("loaded %zu bytes, mapper %d%s\n", rom.size(), c->mapper,
	            c->mapper_sc ? " +SC" : "");
	const uint64_t load_ticks = tick;

	const uint64_t ticks_per_frame = 228ULL * 262 * 4;
	const uint64_t max_ticks = ticks_per_frame * uint64_t(frames + 4) * 2;

	// NTSC palette, to check the core's raw colour output against its RGB:
	// entry 2*color must equal {red, green, blue} on every pixel. The path is
	// relative to the upstream root, like the core's own $readmemh.
	std::vector<uint32_t> palette;
	{
		std::ifstream pf("rtl/palettes/NWARM.hex");
		std::string hex;
		while (pf >> hex) palette.push_back(uint32_t(std::stoul(hex, nullptr, 16)));
		if (palette.size() != 256) {
			std::fprintf(stderr, "rtl/palettes/NWARM.hex: %zu entries, want 256\n", palette.size());
			return 1;
		}
	}
	uint64_t color_checked = 0, color_bad = 0;

	std::vector<uint8_t> line, frame;
	int width = 0, height = 0, frame_no = 0;
	bool prev_vblank = true, prev_hblank = true;
	std::vector<int16_t> audio;
	uint64_t run = 0, reset_until = 64;  // same initial reset as tb_console
	int reset_frame = -1;

	while (frame_no < frames && run < max_ticks) {
		if (reset_every && frame_no > 0 && frame_no % reset_every == 0 &&
		    frame_no != reset_frame) {
			reset_frame = frame_no;
			reset_until = run + 64;
			c->reset = 1;
		}
		if (run == reset_until) c->reset = 0;
		step();
		run++;

		if (run % media::kAudioDivider == 0)
			audio.push_back(int16_t(c->audio_l & 0x7FFF));  // TIA mix: 0 = silence, max 0x7FFF

		if (!c->ce_pix) continue;
		const bool hb = c->hblank, vb = c->vblank;
		{
			const uint32_t rgb = (uint32_t(c->red) << 16) | (c->green << 8) | c->blue;
			color_checked++;
			if (palette[c->color * 2] != rgb && color_bad++ < 5)
				std::printf("colour mismatch at tick %llu: color %02x -> %06x, rgb %06x\n",
				            static_cast<unsigned long long>(run), c->color,
				            palette[c->color * 2], rgb);
		}
		if (!hb && !vb) {
			line.push_back(c->red);
			line.push_back(c->green);
			line.push_back(c->blue);
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
			unsigned px = 0;
			if (width > 80 && height > 32) {
				const size_t o = (size_t(32) * width + 80) * 3;
				px = (frame[o] << 16) | (frame[o + 1] << 8) | frame[o + 2];
			}
			std::printf("frame %4d  %3dx%-3d  sum %llu  px %06x\n", frame_no, width, height,
			            static_cast<unsigned long long>(sum), px);
			frame.clear();
			frame_no++;
		}
		prev_hblank = hb;
		prev_vblank = vb;
	}

	std::printf("colour check: %llu pixels, %llu mismatches\n",
	            static_cast<unsigned long long>(color_checked),
	            static_cast<unsigned long long>(color_bad));
	media::write_wav(out + "/audio.wav", audio);
	std::printf("%d frames, %llu ticks (+%llu load), %zu audio samples -> %s\n", frame_no,
	            static_cast<unsigned long long>(run), static_cast<unsigned long long>(load_ticks),
	            audio.size(), out.c_str());
	c->final();
	delete c;
	delete ctx;
	return frame_no == frames && color_bad == 0 ? 0 : 1;
}
