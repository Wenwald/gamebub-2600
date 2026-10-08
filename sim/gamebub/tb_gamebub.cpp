// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// Harness for hdl/gamebub/atari2600_gamebub.sv, the Game Bub wrapper. It
// plays the parts of the Game Bub firmware and framework the wrapper talks
// to, following the framework's source (the framework submodule):
//
//   - host: memory accesses with the SPI receiver's exact handshake (enable
//     held, done ignored in the first cycle, next access straight after),
//     host commands (request held until done/error), the ROM file written as
//     little-endian words to 0x3000_0000 between FileWriteStart/End(0);
//   - framework framebuffer: the same write rules as HandheldTop (one pixel
//     per dataEnable cycle, next row on rising hblank, x/y reset during
//     vblank, buffer swap on rising vblank), with bounds checks;
//   - display: scans each completed buffer through the wrapper's video
//     filter, as the display side does, and checks every filtered pixel
//     against upstream's NTSC palette.
//
// The start-up order follows the firmware (elipsitz/gamebub, branch
// v1.1-beta, firmware/handheld/src/core/mod.rs finish_loading_inner, read
// 2026-10-06): poll GetStatus until Setup; per file FileWriteStart(id), the
// data, FileWriteEnd(id, size, 0); then the settings; SetupComplete; poll
// until CoreHalt; CoreRun; NotifyFocus(1). Command words go to
// 0xF000_0000 + 4 * i.
//
//   tb_gamebub rom.a26 [--frames N] [--out DIR] [--dump-every K] [--mapper M]
//                      [--sc] [--reset-every R] [--word-gap G] [--px-y Y]
//                      [--paddle] [--hold BUTTONS]
//
// --mapper/--sc set the bankswitch settings; --reset-every R uses the Reset
// setting at the start of every R-th frame. --word-gap G idles G cycles
// between ROM words (default 0: back to back, the harder case). Each frame
// line ends with the colour at framebuffer (160, Y), default Y = 56: the
// test ROMs' status band. --paddle sets the Controller setting to Paddle.
// --hold holds Game Bub buttons (comma-separated: up, down, left, right, a,
// b, x, y, l, r, start, select) from CoreRun to the end of the run.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

#include "../common/media.h"
#include "Vatari2600_gamebub.h"
#include "verilated.h"

namespace {

constexpr int kWidth = 320, kHeight = 240;
constexpr int kFilterLatency = 2;

constexpr uint16_t kCmdGetStatus = 0x0000, kCmdCoreRun = 0x0100, kCmdSetupComplete = 0x0102,
                   kCmdNotifyFocus = 0x0200, kCmdFileWriteStart = 0x0300,
                   kCmdFileWriteEnd = 0x0301;
constexpr uint32_t kStatusSetup = 2, kStatusHalt = 3, kStatusRun = 4;

struct Sim {
	Vatari2600_gamebub *c;
	uint64_t tick = 0;
	std::vector<uint32_t> palette;

	// Framework framebuffer model (HandheldTop).
	std::vector<uint8_t> fb[2] = {std::vector<uint8_t>(kWidth * kHeight),
	                              std::vector<uint8_t>(kWidth * kHeight)};
	int fb_x = 0, fb_y = 0, write_index = 0, last_complete = 0;
	bool prev_vblank = true, prev_hblank = true;
	uint64_t bounds_errors = 0;
	int rows_this_frame = 0, max_x_this_frame = 0;

	// Display scan through the video filter.
	bool scanning = false;
	int scan_buffer = 0;
	int scan_pos = 0;                  // next pixel fed to the filter
	std::vector<uint8_t> display;      // RGB, filled kFilterLatency cycles later
	std::vector<uint8_t> scan_colors;  // stored colours, to check the palette
	uint64_t filter_checked = 0, filter_bad = 0;
	int completed = 0;                 // frames scanned out
	std::vector<int> frame_rows, frame_max_x;
	std::vector<std::vector<uint8_t>> pending;  // completed displayed frames

	bool record_audio = false;
	std::vector<int16_t> audio;

	explicit Sim(Vatari2600_gamebub *core) : c(core), display(kWidth * kHeight * 3) {}

	void scan_cycle() {
		// Collect the filter output for the pixel fed kFilterLatency cycles ago.
		if (scanning) {
			const int out = scan_pos - kFilterLatency;
			if (out >= 0 && out < kWidth * kHeight) {
				const uint32_t rgb = (uint32_t(c->videoFilter_dataOut_r) << 16) |
				                     (c->videoFilter_dataOut_g << 8) | c->videoFilter_dataOut_b;
				display[out * 3] = uint8_t(rgb >> 16);
				display[out * 3 + 1] = uint8_t(rgb >> 8);
				display[out * 3 + 2] = uint8_t(rgb);
				filter_checked++;
				const uint32_t want = palette[scan_colors[out] * 2];
				if (want != rgb && filter_bad++ < 5)
					std::printf("filter mismatch: colour %02x -> %06x, want %06x\n", scan_colors[out],
					            rgb, want);
			}
			if (out == kWidth * kHeight - 1) {
				scanning = false;
				pending.push_back(display);
			}
		}
		if (scanning && scan_pos < kWidth * kHeight) {
			const uint8_t v = fb[scan_buffer][scan_pos];
			scan_colors[scan_pos] = v;
			c->videoFilter_dataIn_r = v >> 4;
			c->videoFilter_dataIn_g = (v >> 2) & 3;
			c->videoFilter_dataIn_b = v & 3;
		}
		if (scanning) scan_pos++;
	}

	void framebuffer_cycle() {
		const bool de = c->video_dataEnable, vb = c->video_vblank, hb = c->video_hblank;
		if (de) {
			if (fb_x >= kWidth || fb_y >= kHeight) {
				if (bounds_errors++ < 5)
					std::printf("framebuffer write out of bounds at (%d, %d)\n", fb_x, fb_y);
			} else {
				fb[write_index][fb_y * kWidth + fb_x] =
				    uint8_t((c->video_data_r << 4) | (c->video_data_g << 2) | c->video_data_b);
				if (fb_x + 1 > max_x_this_frame) max_x_this_frame = fb_x + 1;
				if (fb_y + 1 > rows_this_frame) rows_this_frame = fb_y + 1;
			}
		}
		const bool vblank_edge = vb && !prev_vblank, hblank_edge = hb && !prev_hblank;
		if (vblank_edge) {
			last_complete = write_index;
			write_index ^= 1;
			frame_rows.push_back(rows_this_frame);
			frame_max_x.push_back(max_x_this_frame);
			rows_this_frame = max_x_this_frame = 0;
			// Show the finished buffer.
			scanning = true;
			scan_buffer = last_complete;
			scan_pos = 0;
		}
		if (vb) {
			fb_x = fb_y = 0;
		} else if (hb) {
			if (hblank_edge) {
				fb_x = 0;
				fb_y++;
			}
		} else if (de) {
			fb_x++;
		}
		prev_vblank = vb;
		prev_hblank = hb;
	}

	// One system clock. Outputs are sampled before the edge, as the
	// framework's registers see them.
	void step() {
		c->clock = 0;
		c->clocks_clockIn50M = 0;
		c->videoFilter_clock = 0;
		c->eval();
		scan_cycle();
		c->eval();
		framebuffer_cycle();
		c->clock = 1;
		c->clocks_clockIn50M = 1;
		c->videoFilter_clock = 1;
		c->eval();
		tick++;
		if (record_audio && tick % media::kAudioDivider == 0) audio.push_back(int16_t(c->audio_left));
	}

	// ---- Host memory accesses (SpiReceiverFifo system side) ----
	bool host_busy = false;

	uint32_t access(uint32_t address, bool write, uint32_t data) {
		c->host_mem_enable = 1;
		c->host_mem_write = write;
		c->host_mem_address = address;
		c->host_mem_dataWrite = data;
		for (int guard = 0; guard < 1000; guard++) {
			c->clock = 0;
			c->eval();
			const bool complete = host_busy && c->host_mem_done;
			const uint32_t read = c->host_mem_dataRead;
			if (!host_busy) host_busy = true;
			else if (complete) host_busy = false;
			step();
			if (complete) return read;
		}
		std::printf("host access to %08x never completed\n", address);
		std::exit(1);
	}
	void idle(int cycles = 1) {
		c->host_mem_enable = 0;
		c->host_mem_write = 0;
		for (int i = 0; i < cycles; i++) step();
	}
	void write(uint32_t address, uint32_t data) { access(address, true, data); }
	uint32_t read(uint32_t address) { return access(address, false, 0); }

	// ---- Host commands ----
	// Returns {error, result register}.
	std::pair<bool, uint32_t> command(uint16_t opcode, std::vector<uint32_t> args = {}) {
		write(0xF0000000, opcode);
		for (size_t i = 0; i < args.size(); i++) write(0xF0000004 + 4 * uint32_t(i), args[i]);
		idle();
		c->host_commandHost_request = 1;
		bool error = false;
		for (int guard = 0;; guard++) {
			step();
			if (c->host_commandHost_done || c->host_commandHost_error) {
				error = c->host_commandHost_error;
				break;
			}
			if (guard > 1000) {
				std::printf("command %04x never finished\n", opcode);
				std::exit(1);
			}
		}
		c->host_commandHost_request = 0;
		for (int guard = 0; c->host_commandHost_done || c->host_commandHost_error; guard++) {
			step();
			if (guard > 1000) { std::printf("command %04x never released\n", opcode); std::exit(1); }
		}
		const uint32_t result = read(0xF0000000);
		idle();
		return {error, result};
	}
};

}  // namespace

int main(int argc, char **argv) {
	std::string rom_path, out = "sim/out/gamebub";
	int frames = 60, dump_every = 0, mapper = 0, reset_every = 0, word_gap = 0, px_y = 56;
	bool sc = false, paddle = false;
	std::string hold;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() { return i + 1 < argc ? argv[++i] : (char *)""; };
		if (a == "--frames") frames = std::atoi(next());
		else if (a == "--out") out = next();
		else if (a == "--dump-every") dump_every = std::atoi(next());
		else if (a == "--mapper") mapper = std::atoi(next());
		else if (a == "--reset-every") reset_every = std::atoi(next());
		else if (a == "--word-gap") word_gap = std::atoi(next());
		else if (a == "--px-y") px_y = std::atoi(next());
		else if (a == "--sc") sc = true;
		else if (a == "--paddle") paddle = true;
		else if (a == "--hold") hold = next();
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
	auto *core = new Vatari2600_gamebub{ctx};
	Sim s(core);

	// Upstream's NTSC palette (entry 2 * colour), relative to the upstream
	// root like the core's own $readmemh: the reference for the filter.
	{
		std::ifstream pf("rtl/palettes/NWARM.hex");
		std::string hex;
		while (pf >> hex) s.palette.push_back(uint32_t(std::stoul(hex, nullptr, 16)));
		if (s.palette.size() != 256) {
			std::fprintf(stderr, "rtl/palettes/NWARM.hex: %zu entries, want 256\n", s.palette.size());
			return 1;
		}
	}
	s.scan_colors.resize(kWidth * kHeight);

	int failures = 0;
	auto expect = [&](bool ok, const char *what) {
		if (!ok) {
			std::printf("FAIL: %s\n", what);
			failures++;
		}
	};

	// Power on: framework reset, then the firmware's setup sequence.
	core->reset = 1;
	s.idle(8);
	core->reset = 0;
	s.idle(8);

	auto r = s.command(kCmdGetStatus);
	expect(!r.first && r.second == kStatusSetup, "status before setup is Setup");

	r = s.command(kCmdFileWriteStart, {0});
	expect(!r.first, "FileWriteStart(ROM)");
	const uint64_t load_from = s.tick;
	for (size_t a = 0; a < rom.size(); a += 4) {
		uint32_t word = 0;
		for (size_t k = 0; k < 4 && a + k < rom.size(); k++) word |= uint32_t(rom[a + k]) << (8 * k);
		s.write(0x30000000 + uint32_t(a), word);
		if (word_gap) s.idle(word_gap);
	}
	s.idle();
	const uint64_t load_ticks = s.tick - load_from;
	r = s.command(kCmdFileWriteEnd, {0, uint32_t(rom.size()), 0});
	const bool load_failed = r.first;

	// Settings (the core harness uses difficulty A on both sides).
	s.write(0x00001000, 1);
	s.write(0x00001004, 1);
	s.write(0x00001008, 1);
	s.write(0x0000100C, uint32_t(mapper));
	s.write(0x00001010, sc ? 1 : 0);
	s.write(0x00001014, paddle ? 1 : 0);
	s.idle();

	const uint32_t status = s.read(0x00000000);
	s.idle();
	std::printf("loaded %zu bytes, mapper %u%s\n", rom.size(), (status >> 8) & 0x3F,
	            (status >> 14) & 1 ? " +SC" : "");
	std::printf("load: %llu cycles, %s, status %08x\n", static_cast<unsigned long long>(load_ticks),
	            load_failed ? "error" : "done", status);
	if (load_failed) {
		std::printf("ROM rejected\n");
		return 3;
	}

	r = s.command(kCmdSetupComplete);
	expect(!r.first, "SetupComplete");
	r = s.command(kCmdGetStatus);
	expect(!r.first && r.second == kStatusHalt, "status after setup is CoreHalt");
	r = s.command(kCmdCoreRun);
	expect(!r.first, "CoreRun");
	r = s.command(kCmdNotifyFocus, {1});
	expect(!r.first, "NotifyFocus(1)");

	for (size_t pos = 0; pos < hold.size();) {
		size_t end = hold.find(',', pos);
		if (end == std::string::npos) end = hold.size();
		const std::string b = hold.substr(pos, end - pos);
		pos = end + 1;
		if (b == "up") core->input_buttons_up = 1;
		else if (b == "down") core->input_buttons_down = 1;
		else if (b == "left") core->input_buttons_left = 1;
		else if (b == "right") core->input_buttons_right = 1;
		else if (b == "a") core->input_buttons_a = 1;
		else if (b == "b") core->input_buttons_b = 1;
		else if (b == "x") core->input_buttons_x = 1;
		else if (b == "y") core->input_buttons_y = 1;
		else if (b == "l") core->input_buttons_l = 1;
		else if (b == "r") core->input_buttons_r = 1;
		else if (b == "start") core->input_buttons_start = 1;
		else if (b == "select") core->input_buttons_select = 1;
		else { std::fprintf(stderr, "unknown button %s\n", b.c_str()); return 2; }
	}
	r = s.command(kCmdGetStatus);
	expect(!r.first && r.second == kStatusRun, "status after CoreRun is CoreRun");
	r = s.command(0x7777);
	expect(r.first, "unknown command is an error");

	const uint64_t ticks_per_frame = 228ULL * 262 * 4;
	const uint64_t max_ticks = s.tick + ticks_per_frame * uint64_t(frames + 4) * 2;
	s.record_audio = true;
	int frame_no = 0, reset_frame = -1;
	size_t shown = 0;
	while (frame_no < frames && s.tick < max_ticks) {
		if (reset_every && frame_no > 0 && frame_no % reset_every == 0 && frame_no != reset_frame) {
			reset_frame = frame_no;
			s.write(0x00002000, 1);
			s.idle();
		} else {
			s.idle();
		}

		while (shown < s.pending.size() && frame_no < frames) {
			const std::vector<uint8_t> &img = s.pending[shown];
			const int rows = s.frame_rows[shown], width = s.frame_max_x[shown];
			shown++;
			const bool last = frame_no == frames - 1;
			if (last || (dump_every && frame_no % dump_every == 0)) {
				char name[64];
				std::snprintf(name, sizeof name, "/frame_%04d.png", frame_no);
				media::write_png(out + name, kWidth, kHeight, img);
			}
			uint64_t sum = 0;
			for (uint8_t b : img) sum += b;
			const size_t o = (size_t(px_y) * kWidth + 160) * 3;
			const unsigned px = (img[o] << 16) | (img[o + 1] << 8) | img[o + 2];
			std::printf("frame %4d  %dx%d written  sum %llu  px %06x\n", frame_no, width, rows,
			            static_cast<unsigned long long>(sum), px);
			frame_no++;
		}
	}

	std::printf("filter check: %llu pixels, %llu mismatches\n",
	            static_cast<unsigned long long>(s.filter_checked),
	            static_cast<unsigned long long>(s.filter_bad));
	std::printf("bounds check: %llu framebuffer writes out of range\n", static_cast<unsigned long long>(s.bounds_errors));
	media::write_wav(out + "/audio.wav", s.audio);
	std::printf("%d frames, %llu ticks, %zu audio samples -> %s\n", frame_no,
	            static_cast<unsigned long long>(s.tick), s.audio.size(), out.c_str());
	core->final();
	delete core;
	delete ctx;
	const bool ok = frame_no == frames && failures == 0 && s.filter_bad == 0 && s.bounds_errors == 0;
	return ok ? 0 : 1;
}
