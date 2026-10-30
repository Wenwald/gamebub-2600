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
//                   [--pause-every P,L] [--ss-measure] [--ss-save-at T[,T...]]
//                   [--ss-swap-at T,K] [--ss-vcd DIR]
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
//
// --pause-every P,L raises the core's pause input for L clocks out of every
// P (never during reset). Paused clocks don't count as console time: audio
// is sampled and resets are timed on running clocks only, while pixels are
// taken whenever ce_pix is high. A correct pause therefore gives the same
// frame lines and audio as a run without it. To show the core really
// stopped, it also counts pixels that come out later than PAUSE_DRAIN clocks
// into a pause (the video pipeline's last pixels may come out before that).
//
// Save states (the protocol is in hdl/atari2600_core.sv). --ss-measure
// prints the length of the register chain, found by flushing it with zeros
// and timing a single 1 through it, and exits. --ss-save-at saves a state at
// each running clock T and carries on, which must change nothing.
// --ss-swap-at T,K saves at T, then loads that state into a second core that
// loaded the same ROM and ran K clocks of its own, and carries on with the
// second core; with every register on the chain the output is that of a
// plain run. --ss-vcd DIR (needs a TRACE=1 build) writes every signal, all
// paused and settled: DIR/a.vcd of the first core just before it saves,
// DIR/b.vcd of the second just after it loaded, DIR/c.vcd of the first just
// after its save; sim/core/ss_diff.py compares them. Every swap also
// compares the memories, read straight from the RAM arrays, of those three
// moments ("ss memory: ...").

#include <algorithm>
#include <fstream>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "../common/media.h"
#include "Vatari2600_core.h"
#include "Vatari2600_core___024root.h"
#include "verilated.h"
#ifdef SS_TRACE
#include "verilated_vcd_c.h"
#endif

using Core = Vatari2600_core;

// The save-state memory of atari2600_core (MEM_BYTES in
// hdl/atari2600_savestate.sv).
constexpr int kStateMem = 0x8200;
constexpr int kSettle = 16;
constexpr int kChainMax = 1 << 16;

struct State {
	std::vector<uint8_t> chain;  // one bit per entry, in shift-out order
	std::vector<uint8_t> mem;
};

static void tick_core(Core *c) {
	c->clk_sys = 0;
	c->eval();
	c->clk_sys = 1;
	c->eval();
}

// Step 2 of the protocol (the caller pauses and settles before and after,
// through its normal video capture: the pipeline's last pixels come out
// while the console comes to a stop). Saving
// rotates the chain once round (ss_so back into ss_si) and reads memory;
// loading writes memory and shifts the saved bits in. While the chain is
// part-shifted the registers hold any mix of bits, so the RTL's own checks
// (unique case and the like) are off until it settles again.
static void ss_save(Core *c, int chain_bits, State &st) {
	c->contextp()->assertOn(false);
	c->ss_hold = 1;
	st.mem.assign(kStateMem, 0);
	for (int a = 0; a < kStateMem; a++) {
		c->ss_mem_addr = a;
		tick_core(c);  // the read data of the clock that took the address
		st.mem[a] = c->ss_mem_rdata;
	}
	st.chain.assign(chain_bits, 0);
	c->ss_en = 1;
	for (int i = 0; i < chain_bits; i++) {
		st.chain[i] = c->ss_so;
		c->ss_si = c->ss_so;
		tick_core(c);
	}
	c->ss_en = 0;
	c->ss_si = 0;
	c->ss_hold = 0;
	c->ss_mem_addr = 0;
	c->ss_mem_wdata = 0;
	tick_core(c);
	c->contextp()->assertOn(true);
}

static void ss_load(Core *c, const State &st) {
	c->contextp()->assertOn(false);
	c->ss_hold = 1;
	c->ss_mem_we = 1;
	for (int a = 0; a < kStateMem; a++) {
		c->ss_mem_addr = a;
		c->ss_mem_wdata = st.mem[a];
		tick_core(c);
	}
	c->ss_mem_we = 0;
	c->ss_en = 1;
	for (uint8_t b : st.chain) {
		c->ss_si = b;
		tick_core(c);
	}
	c->ss_en = 0;
	c->ss_si = 0;
	c->ss_hold = 0;
	c->ss_mem_addr = 0;
	c->ss_mem_wdata = 0;
	tick_core(c);
	c->contextp()->assertOn(true);
}

// The save-state memory read straight out of the model's RAM arrays, laid
// out as ss_mem_addr maps it (the gaps read 0xFF, as the port does): a
// reference that does not go through the port.
static std::vector<uint8_t> mem_direct(Core *c) {
	auto *r = c->rootp;
	std::vector<uint8_t> m(kStateMem, 0xFF);
	for (int i = 0; i < 0x8000; i++)
		m[i] = r->atari2600_core__DOT__cart_ram__DOT__u_ram__DOT__mem_q[i];
	for (int i = 0; i < 0x80; i++)
		m[0x8000 + i] = r->atari2600_core__DOT__riot_inst__DOT__riot_ram__DOT__mem_q[i];
	for (int i = 0; i < 0x100; i++)
		m[0x8100 + i] = r->atari2600_core__DOT__cart2600__DOT__mapper_FA2__DOT__working_ram__DOT__u_ram__DOT__mem_q[i];
	return m;
}

static int mem_diff(const std::vector<uint8_t> &a, const std::vector<uint8_t> &b) {
	int n = 0;
	for (size_t i = 0; i < a.size(); i++) n += a[i] != b[i];
	return n;
}

// Chain length: flush with zeros, then count the clocks a single 1 takes
// from ss_si to ss_so. Destroys the state.
static int ss_measure(Core *c) {
	c->contextp()->assertOn(false);
	c->ss_hold = 1;
	c->ss_en = 1;
	c->ss_si = 0;
	for (int i = 0; i < kChainMax; i++) tick_core(c);
	if (c->ss_so) return -1;
	c->ss_si = 1;
	tick_core(c);
	c->ss_si = 0;
	for (int n = 1; n <= kChainMax; n++) {
		if (c->ss_so) return n;
		tick_core(c);
	}
	return -1;
}

int main(int argc, char **argv) {
	std::string rom_path, out = "sim/out/core";
	int frames = 60, dump_every = 0, mapper = 0, reset_every = 0;
	bool sc = false, paddle_en = false;
	int paddle_a = 0, paddle_b = 0;
	uint64_t pause_period = 0, pause_len = 0;
	std::string paddle_btn;
	bool ss_measure_only = false;
	std::vector<uint64_t> ss_save_at;
	uint64_t ss_swap_at = 0, ss_swap_k = 0;
	std::string ss_vcd;
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
		else if (a == "--pause-every") {
			const std::string v = next();
			pause_period = std::strtoull(v.c_str(), nullptr, 10);
			const size_t comma = v.find(',');
			if (comma != std::string::npos) pause_len = std::strtoull(v.c_str() + comma + 1, nullptr, 10);
			if (pause_len >= pause_period) {
				std::fprintf(stderr, "--pause-every P,L needs L < P\n");
				return 2;
			}
		}
		else if (a == "--ss-measure") ss_measure_only = true;
		else if (a == "--ss-save-at") {
			const std::string v = next();
			for (size_t p = 0; p < v.size();) {
				ss_save_at.push_back(std::strtoull(v.c_str() + p, nullptr, 10));
				const size_t comma = v.find(',', p);
				p = comma == std::string::npos ? v.size() : comma + 1;
			}
		} else if (a == "--ss-swap-at") {
			const std::string v = next();
			ss_swap_at = std::strtoull(v.c_str(), nullptr, 10);
			const size_t comma = v.find(',');
			if (comma != std::string::npos) ss_swap_k = std::strtoull(v.c_str() + comma + 1, nullptr, 10);
		} else if (a == "--ss-vcd") ss_vcd = next();
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

#ifndef SS_TRACE
	if (!ss_vcd.empty()) {
		std::fprintf(stderr, "--ss-vcd needs a TRACE=1 build\n");
		return 2;
	}
#endif
	// Each core has a context of its own (a trace takes one model per
	// context); free_core deletes both.
	auto free_core = [](Core *&c) {
		VerilatedContext *x = c->contextp();
		c->final();
		delete c;
		delete x;
		c = nullptr;
	};

	// A core with the inputs set and the ROM loaded. Returns the clocks the
	// load took.
	auto make_core = [&](Core *&c) {
		auto *ctx = new VerilatedContext;
		ctx->commandArgs(argc, argv);
		if (!ss_vcd.empty()) ctx->traceEverOn(true);
		c = new Core{ctx};
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
		c->pause = 0;

		uint64_t t = 0;
		auto st = [&]() { tick_core(c); t++; };
		// Load: start pulse, one byte per clock, end pulse, all under reset.
		for (int i = 0; i < 8; i++) st();
		c->load_start = 1; st(); c->load_start = 0;
		for (size_t a = 0; a < rom.size(); a++) {
			c->load_valid = 1;
			c->load_addr = uint32_t(a);
			c->load_data = rom[a];
			st();
		}
		c->load_valid = 0;
		st();
		c->load_end = 1; st(); c->load_end = 0;
		for (int i = 0; i < 8; i++) st();
		// The core's clock dividers run freely through the load. Finish it on a
		// whole 12-clock CPU cycle so the run that follows lines up with
		// tb_console's (no load) clock for clock, and audio sampled at fixed
		// ticks compares byte for byte.
		while (t % 12) st();
		return t;
	};

	Core *c = nullptr;
	uint64_t tick = make_core(c);
	auto step = [&]() {
		tick_core(c);
		tick++;
	};
	std::printf("loaded %zu bytes, mapper %d%s\n", rom.size(), c->mapper,
	            c->mapper_sc ? " +SC" : "");
	const uint64_t load_ticks = tick;

	if (ss_measure_only) {
		const int n = ss_measure(c);
		std::printf("ss chain %d bits\n", n);
		free_core(c);
		return n > 0 ? 0 : 1;
	}
	int chain_bits = 0;
	if (!ss_save_at.empty() || ss_swap_at) {
		// The chain length, from a throwaway core (measuring destroys a state).
		Core *m = nullptr;
		make_core(m);
		chain_bits = ss_measure(m);
		free_core(m);
		if (chain_bits <= 0) {
			std::fprintf(stderr, "save-state chain does not come through\n");
			return 1;
		}
	}
#ifdef SS_TRACE
	auto dump = [&](Core *x, const std::string &name) {
		auto *tfp = new VerilatedVcdC;
		x->trace(tfp, 99);
		tfp->open((ss_vcd + "/" + name).c_str());
		tfp->dump(0);
		tfp->close();
		delete tfp;
	};
#endif
	State ss_ref;  // the state saved by the last operation
	std::vector<uint8_t> ss_mem_ref;  // memory, read directly, before it
	int ss_mem_bad_saved = 0;
	int ss_ops = 0, ss_pre = 0, ss_post = 0;
	bool ss_op_now = false;
	uint64_t ss_done_run = ~0ULL;
	Core *ss_old = nullptr;

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
	uint64_t wall = 0, paused_ticks = 0;  // all clocks / clocks with pause high
	constexpr uint64_t PAUSE_DRAIN = 8;
	uint64_t pause_age = 0, pause_late = 0, pause_last = 0;  // into this pause; late pixels; latest pixel

	while (frame_no < frames && run < max_ticks) {
		if (reset_every && frame_no > 0 && frame_no % reset_every == 0 &&
		    frame_no != reset_frame) {
			reset_frame = frame_no;
			reset_until = run + 64;
			c->reset = 1;
		}
		if (run == reset_until) c->reset = 0;
		// Save-state operations: SETTLE paused clocks, the operation itself
		// (its clocks are not console time and their video is not taken, as
		// the Game Bub wrapper ignores it), SETTLE more paused clocks.
		if (ss_op_now) {
			ss_op_now = false;
#ifdef SS_TRACE
			if (!ss_vcd.empty() && ss_swap_at && run == ss_swap_at) dump(c, "a.vcd");
#endif
			ss_mem_ref = mem_direct(c);
			State &st = ss_ref;
			ss_save(c, chain_bits, st);
			ss_mem_bad_saved = mem_diff(st.mem, ss_mem_ref);
			ss_ops++;
			if (ss_swap_at && run == ss_swap_at) {
				// A second core, somewhere else in the same game.
				Core *b = nullptr;
				make_core(b);
				b->reset = 1;
				for (uint64_t i = 0; i < ss_swap_k; i++) {
					if (i == 64) b->reset = 0;
					tick_core(b);
				}
				b->reset = 0;
				b->pause = 1;
				for (int i = 0; i < kSettle; i++) tick_core(b);
				ss_load(b, st);
				b->paddle_pos_a = c->paddle_pos_a;
				b->paddle_pos_b = c->paddle_pos_b;
				b->pa_in = c->pa_in;
				ss_old = c;  // settles alongside, for --ss-vcd
				c = b;
			}
			ss_post = kSettle;
		}
		if (!ss_pre && !ss_post && !c->reset && run > 0 && run != ss_done_run &&
		    ((ss_swap_at && run == ss_swap_at) ||
		     std::find(ss_save_at.begin(), ss_save_at.end(), run) != ss_save_at.end())) {
			ss_done_run = run;
			ss_pre = kSettle;
		}
		c->pause = ss_pre || ss_post ||
			(pause_period && !c->reset && wall % pause_period >= pause_period - pause_len);
		const bool paused = c->pause;
		step();
		wall++;
		if (ss_pre && --ss_pre == 0) ss_op_now = true;
		if (ss_old) tick_core(ss_old);
		if (ss_post && --ss_post == 0 && ss_old) {
#ifdef SS_TRACE
			if (!ss_vcd.empty()) {
				dump(c, "b.vcd");
				dump(ss_old, "c.vcd");
			}
#endif
			// The memories (too big to trace) against the first core's own
			// before it saved: what the port saved, the second core's after
			// the load, the first core's after its save.
			std::printf("ss memory: %d saved, %d loaded, %d after saving, of %d bytes differ\n",
			            ss_mem_bad_saved, mem_diff(mem_direct(c), ss_mem_ref),
			            mem_diff(mem_direct(ss_old), ss_mem_ref), kStateMem);
			free_core(ss_old);
		}
		if (paused) {
			paused_ticks++;
			pause_age++;
			if (c->ce_pix) {
				if (pause_age > pause_last) pause_last = pause_age;
				if (pause_age > PAUSE_DRAIN) pause_late++;
			}
		} else {
			pause_age = 0;
			run++;
			if (run % media::kAudioDivider == 0)
				audio.push_back(int16_t(c->audio_l & 0x7FFF));  // TIA mix: 0 = silence, max 0x7FFF
		}

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
	if (chain_bits)
		std::printf("save states: %d (chain %d bits), last pixel %llu clocks into a pause, %llu late pixels\n",
		            ss_ops, chain_bits, static_cast<unsigned long long>(pause_last),
		            static_cast<unsigned long long>(pause_late));
	if (pause_period)
		std::printf("paused %llu of %llu clocks, last pixel %llu clocks in, %llu late pixels\n",
		            static_cast<unsigned long long>(paused_ticks), static_cast<unsigned long long>(wall),
		            static_cast<unsigned long long>(pause_last), static_cast<unsigned long long>(pause_late));
	media::write_wav(out + "/audio.wav", audio);
	std::printf("%d frames, %llu ticks (+%llu load), %zu audio samples -> %s\n", frame_no,
	            static_cast<unsigned long long>(run), static_cast<unsigned long long>(load_ticks),
	            audio.size(), out.c_str());
	free_core(c);
	return frame_no == frames && color_bad == 0 ? 0 : 1;
}
