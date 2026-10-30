// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// Game Bub wrapper for atari2600_core. Bound by
// chisel/src/atari2600/HandheldAtari2600.scala to the framework's io bundle;
// the port names are the framework's flattened interface names and must match
// the template it prints at build time.
//
// Host protocol (framework HostV0, from the framework's source):
//   - Memory: the host holds host_mem_enable for each 32-bit access, ignores
//     host_mem_done in the access's first cycle, completes it on the first
//     later cycle with done high, and may start the next access in the very
//     next cycle (enable never drops). mem_busy mirrors the host's own busy
//     flag so each access is performed exactly once.
//   - Commands: host_commandHost_request is held until done/error; opcode in
//     the register at 0xF000_0000, argument at 0xF000_0004.
//
// Pause: while the menu has focus (NotifyFocus(0)) the console is frozen.
// Settings take effect when the game resumes and reads its switches. Reset
// from the menu restarts the console, still frozen, and blanks the screen
// behind the menu (see "Console").
//
// Save state: one slot in block RAM, which is also file id 1 (files.json:
// "<rom>.state" next to the ROM, read in after the ROM and written back by
// the firmware when the core exits). Save State copies the console into it,
// Load State copies it back if it was saved from this ROM with this
// bankswitch scheme, and shows a black frame like Reset (see "Save state").
//
// Core memory map (32-bit registers):
//   0x0000_0000  r   status: [0] ROM loaded, [1] load error, [13:8] mapper,
//                    [14] Superchip, [16] the slot holds a state this ROM can
//                    load, [17] the slot holds a state at all, [18] the last
//                    Load State was refused
//   0x0000_1000  rw  left difficulty  (1 = A, 0 = B)
//   0x0000_1004  rw  right difficulty (1 = A, 0 = B)
//   0x0000_1008  rw  TV type (1 = colour, 0 = B&W)
//   0x0000_100C  rw  bankswitch override (bss_type; 0 = auto-detect)
//   0x0000_1010  rw  Superchip with a forced scheme (1 = on)
//   0x0000_1014  rw  controller (0 = joystick, 1 = paddle)
//   0x0000_2000  w   any write: console reset (power cycle; multicarts move on);
//                    unfocused, also a black frame
//   0x0000_2004  w   any write: Save State
//   0x0000_2008  w   any write: Load State
//   0x3000_0000  w   ROM file (file id 0), little-endian words, byte offset =
//                    address bits [27:0]
//   0x4000_0000  rw  save-state slot (file id 1), little-endian words,
//                    SLOT_BYTES long (layout under "Save state")
//   0xF000_0000  rw  host command opcode / result
//   0xF000_0004  rw  host command argument

`default_nettype none

module atari2600_gamebub
	import atari2600_savestate::*;
#(
	parameter int DISPLAY_DIVIDER = 23,
	parameter int ROM_ADDR_WIDTH  = 16,   // 64 KB cartridge ROM in block RAM
	parameter int V_START         = 16    // first kept line, counted from VSYNC
) (
	input  wire logic        clock,
	input  wire logic        reset,
	input  wire logic        clocks_clockIn50M,
	output logic        clocks_clockOutSystem,
	output logic        clocks_clockOutDisplay,
	output logic        clocks_clockOutSpi,
	output logic        clocks_locked,
	output logic [2:0]  video_data_r,
	output logic [1:0]  video_data_g,
	output logic [1:0]  video_data_b,
	output logic        video_dataEnable,
	output logic        video_vblank,
	output logic        video_hblank,
	input  wire logic        videoFilter_clock,
	input  wire logic        videoFilter_reset,
	input  wire logic [2:0]  videoFilter_dataIn_r,
	input  wire logic [1:0]  videoFilter_dataIn_g,
	input  wire logic [1:0]  videoFilter_dataIn_b,
	output logic [7:0]  videoFilter_dataOut_r,
	output logic [7:0]  videoFilter_dataOut_g,
	output logic [7:0]  videoFilter_dataOut_b,
	output logic [15:0] audio_left,
	output logic [15:0] audio_right,
	input  wire logic        host_mem_enable,
	input  wire logic        host_mem_write,
	output logic        host_mem_done,
	input  wire logic [31:0] host_mem_address,
	output logic [31:0] host_mem_dataRead,
	input  wire logic [31:0] host_mem_dataWrite,
	input  wire logic        host_commandHost_request,
	output logic        host_commandHost_busy,
	output logic        host_commandHost_done,
	output logic        host_commandHost_error,
	output logic        host_commandCore_request,
	input  wire logic        host_commandCore_busy,
	input  wire logic        host_commandCore_done,
	input  wire logic        host_commandCore_error,
	input  wire logic        input_buttons_a,
	input  wire logic        input_buttons_b,
	input  wire logic        input_buttons_x,
	input  wire logic        input_buttons_y,
	input  wire logic        input_buttons_up,
	input  wire logic        input_buttons_down,
	input  wire logic        input_buttons_left,
	input  wire logic        input_buttons_right,
	input  wire logic        input_buttons_l,
	input  wire logic        input_buttons_r,
	input  wire logic        input_buttons_start,
	input  wire logic        input_buttons_select
);

	// =========================================================================
	// Clocks. `clock` is clocks_clockOutSystem, fed back by the framework.
	// =========================================================================
	atari2600_mmcm #(.DISPLAY_DIVIDER(DISPLAY_DIVIDER)) mmcm (
		.clk_in_50mhz (clocks_clockIn50M),
		.clk_sys      (clocks_clockOutSystem),
		.clk_display  (clocks_clockOutDisplay),
		.clk_spi      (clocks_clockOutSpi),
		.locked       (clocks_locked)
	);

	// =========================================================================
	// Host interface
	// =========================================================================
	localparam logic [15:0] CMD_GET_STATUS       = 16'h0000;
	localparam logic [15:0] CMD_CORE_RUN         = 16'h0100;
	localparam logic [15:0] CMD_CORE_HALT        = 16'h0101;
	localparam logic [15:0] CMD_SETUP_COMPLETE   = 16'h0102;
	localparam logic [15:0] CMD_NOTIFY_FOCUS     = 16'h0200;
	localparam logic [15:0] CMD_FILE_WRITE_START = 16'h0300;
	localparam logic [15:0] CMD_FILE_WRITE_END   = 16'h0301;
	localparam logic [15:0] CMD_FILE_READ_START  = 16'h0302;
	localparam logic [15:0] CMD_FILE_READ_END    = 16'h0303;

	localparam logic [31:0] STATUS_SETUP     = 32'd2;
	localparam logic [31:0] STATUS_CORE_HALT = 32'd3;
	localparam logic [31:0] STATUS_CORE_RUN  = 32'd4;

	localparam logic [31:0] FILE_ROM   = 32'd0;
	localparam logic [31:0] FILE_STATE = 32'd1;

	// The save-state slot's layout (see "Save state").
	localparam int SLOT_CHAIN  = 'h040;
	localparam int SLOT_MEM    = 'h400;
	localparam int SLOT_BYTES  = SLOT_MEM + MEM_BYTES;
	localparam int SLOT_WORDS  = SLOT_BYTES / 4;
	localparam int SLOT_AW     = $clog2(SLOT_WORDS);

	typedef enum logic [1:0] {
		CMD_IDLE,
		CMD_DONE,
		CMD_ERROR
	} cmd_state_t;

	cmd_state_t  cmd_state;
	logic [31:0] cmd_reg0, cmd_reg1;

	logic core_setup;          // SetupComplete received
	logic core_halt;           // CoreHalt (initial) / CoreRun
	logic core_focus;          // NotifyFocus
	logic rom_loading;         // between FileWriteStart(0) and FileWriteEnd(0)
	logic rom_loaded;          // a ROM was loaded without error
	logic load_error;          // a byte fell outside the ROM, or nothing arrived
	logic load_any;            // at least one byte arrived in this load
	logic load_start, load_end;

	// Settings
	logic       set_diff_left, set_diff_right, set_color, set_sc, set_paddle;
	logic [5:0] set_mapper;
	logic       reset_request;  // console reset action (one cycle)
	logic       save_request, load_request;  // Save / Load State actions (one cycle)

	// The ROM as loaded, for the save-state header: size and CRC-32.
	logic [31:0] rom_bytes, rom_crc;

	// Save-state slot (see "Save state"): its block RAM's host port, and
	// what the slot holds.
	logic        state_loading;     // between FileWriteStart(1) and FileWriteEnd(1)
	logic        state_file_start;  // FileWriteStart(1) (one cycle)
	logic        state_file_end;    // FileWriteEnd(1): check the header (one cycle)
	logic [15:0] state_words;       // words of the file so far (a whole slot or nothing)
	logic        state_ok;          // a state this ROM can load
	logic        state_present;     // a state at all (it is saved back to the card)
	logic        state_refused;     // the last Load State found nothing to load
	logic        state_window, state_read;
	logic [31:0] slot_q_a;
	logic [31:0] mem_rdata_reg;

	// Memory access mirror and the ROM byte writer.
	logic        mem_busy;
	logic        mem_start;
	logic        rom_window;
	logic        rom_writing;   // bytes of the current word still going out
	logic  [1:0] rom_byte;
	logic [31:0] rom_word;
	logic [27:0] rom_base;

	assign mem_start  = host_mem_enable && !mem_busy;
	assign rom_window = host_mem_address[31:28] == 4'h3;
	assign state_window = host_mem_address[31:28] == 4'h4;
	wire [SLOT_AW-1:0] slot_addr_a = host_mem_address[SLOT_AW+1:2];
	wire               slot_we_a   = mem_start && host_mem_write && state_window && state_loading;
	assign host_mem_done = mem_busy && !rom_writing;
	// Slot reads come straight from its block RAM, valid from the cycle
	// after the access starts (the one with done) for as long as it is held.
	assign host_mem_dataRead = state_read ? slot_q_a : mem_rdata_reg;

	logic        core_load_valid;
	logic [24:0] core_load_addr;
	logic  [7:0] core_load_data;
	logic  [5:0] core_mapper;
	logic        core_mapper_sc;

	wire  [27:0] rom_byte_addr = rom_base + 28'(rom_byte);
	wire         rom_byte_fits = rom_byte_addr < 28'(1 << ROM_ADDR_WIDTH);

	assign core_load_valid = rom_writing && rom_byte_fits;
	assign core_load_addr  = rom_byte_addr[24:0];
	assign core_load_data  = rom_word[8 * rom_byte +: 8];

	// CRC-32 (IEEE 802.3, reflected, as zlib's crc32) of one more byte.
	function automatic logic [31:0] crc32_byte(input logic [31:0] crc, input logic [7:0] b);
		logic [31:0] c;
		c = crc ^ {24'd0, b};
		for (int i = 0; i < 8; i++)
			c = c[0] ? (c >> 1) ^ 32'hEDB8_8320 : c >> 1;
		return c;
	endfunction

	assign host_commandHost_busy  = 1'b0;
	assign host_commandHost_done  = cmd_state == CMD_DONE;
	assign host_commandHost_error = cmd_state == CMD_ERROR;
	assign host_commandCore_request = 1'b0;

	always_ff @(posedge clock) begin
		load_start    <= 1'b0;
		load_end      <= 1'b0;
		reset_request <= 1'b0;
		save_request  <= 1'b0;
		load_request  <= 1'b0;
		state_file_start <= 1'b0;
		state_file_end   <= 1'b0;

		if (reset) begin
			mem_busy          <= 1'b0;
			mem_rdata_reg     <= 32'd0;
			state_read        <= 1'b0;
			state_loading     <= 1'b0;
			rom_writing       <= 1'b0;
			cmd_state         <= CMD_IDLE;
			cmd_reg0          <= 32'd0;
			cmd_reg1          <= 32'd0;
			core_setup        <= 1'b0;
			core_halt         <= 1'b1;
			core_focus        <= 1'b0;
			rom_loading       <= 1'b0;
			rom_loaded        <= 1'b0;
			load_error        <= 1'b0;
			load_any          <= 1'b0;
			set_diff_left     <= 1'b0;
			set_diff_right    <= 1'b0;
			set_color         <= 1'b1;
			set_mapper        <= 6'd0;
			set_sc            <= 1'b0;
			set_paddle        <= 1'b0;
		end else begin
			// ---- Memory accesses ----
			if (host_mem_enable) begin
				if (!mem_busy)
					mem_busy <= 1'b1;
				else if (host_mem_done)
					mem_busy <= 1'b0;
			end

			if (mem_start && host_mem_write) begin
				if (rom_window) begin
					// Words outside a ROM transfer are ignored.
					if (rom_loading) begin
						rom_writing <= 1'b1;
						rom_byte    <= 2'd0;
						rom_word    <= host_mem_dataWrite;
						rom_base    <= host_mem_address[27:0];
					end
				end else begin
					case (host_mem_address)
						32'h0000_1000: set_diff_left  <= host_mem_dataWrite[0];
						32'h0000_1004: set_diff_right <= host_mem_dataWrite[0];
						32'h0000_1008: set_color      <= host_mem_dataWrite[0];
						32'h0000_100C: set_mapper     <= host_mem_dataWrite[5:0];
						32'h0000_1010: set_sc         <= host_mem_dataWrite[0];
						32'h0000_1014: set_paddle     <= host_mem_dataWrite[0];
						32'h0000_2000: reset_request  <= 1'b1;
						32'h0000_2004: save_request   <= 1'b1;
						32'h0000_2008: load_request   <= 1'b1;
						32'hF000_0000: cmd_reg0       <= host_mem_dataWrite;
						32'hF000_0004: cmd_reg1       <= host_mem_dataWrite;
						default: ;   // the slot window is written below ("Save state")
					endcase
				end
			end else if (mem_start) begin
				case (host_mem_address)
					32'h0000_0000: mem_rdata_reg <= {13'd0, state_refused, state_present, state_ok,
					                                 1'b0, core_mapper_sc, core_mapper,
					                                 6'd0, load_error, rom_loaded};
					32'h0000_1000: mem_rdata_reg <= {31'd0, set_diff_left};
					32'h0000_1004: mem_rdata_reg <= {31'd0, set_diff_right};
					32'h0000_1008: mem_rdata_reg <= {31'd0, set_color};
					32'h0000_100C: mem_rdata_reg <= {26'd0, set_mapper};
					32'h0000_1010: mem_rdata_reg <= {31'd0, set_sc};
					32'h0000_1014: mem_rdata_reg <= {31'd0, set_paddle};
					32'hF000_0000: mem_rdata_reg <= cmd_reg0;
					32'hF000_0004: mem_rdata_reg <= cmd_reg1;
					default:       mem_rdata_reg <= 32'd0;
				endcase
			end
			if (mem_start)
				state_read <= !host_mem_write && state_window;
			if (slot_we_a && state_words != 16'hFFFF)
				state_words <= state_words + 16'd1;

			// ---- ROM bytes: one per cycle, then the access completes ----
			if (load_start) begin
				rom_bytes <= 32'd0;
				rom_crc   <= 32'hFFFF_FFFF;
			end
			if (rom_writing) begin
				rom_bytes <= rom_bytes + 32'd1;
				rom_crc   <= crc32_byte(rom_crc, core_load_data);
				load_any <= 1'b1;
				if (!rom_byte_fits)
					load_error <= 1'b1;
				if (rom_byte == 2'd3)
					rom_writing <= 1'b0;
				rom_byte <= rom_byte + 2'd1;
			end

			// ---- Host commands ----
			if (host_commandHost_request) begin
				if (cmd_state == CMD_IDLE) begin
					cmd_state <= CMD_DONE;
					cmd_reg0  <= 32'd0;
					cmd_reg1  <= 32'd0;
					case (cmd_reg0[15:0])
						CMD_GET_STATUS:
							cmd_reg0 <= !core_setup ? STATUS_SETUP
							          : core_halt   ? STATUS_CORE_HALT : STATUS_CORE_RUN;
						CMD_SETUP_COMPLETE: core_setup <= 1'b1;
						CMD_CORE_RUN:       core_halt  <= 1'b0;
						CMD_CORE_HALT:      core_halt  <= 1'b1;
						CMD_NOTIFY_FOCUS:   core_focus <= cmd_reg1[0];
						CMD_FILE_WRITE_START:
							if (cmd_reg1 == FILE_ROM) begin
								rom_loading <= 1'b1;
								rom_loaded  <= 1'b0;
								load_error  <= 1'b0;
								load_any    <= 1'b0;
								load_start  <= 1'b1;
							end else if (cmd_reg1 == FILE_STATE) begin
								state_loading    <= 1'b1;
								state_file_start <= 1'b1;
								state_words      <= 16'd0;
							end
						CMD_FILE_WRITE_END:
							if (cmd_reg1 == FILE_ROM) begin
								// The host waits for each word's done, so the
								// byte writer is idle here.
								rom_loading <= 1'b0;
								load_end    <= 1'b1;
								rom_loaded  <= load_any && !load_error;
								if (!load_any || load_error)
									cmd_state <= CMD_ERROR;
							end else if (cmd_reg1 == FILE_STATE) begin
								// Any size, none included: the header says
								// whether it holds a state.
								state_loading  <= 1'b0;
								state_file_end <= 1'b1;
							end
						// The size to save back: the whole slot if it holds
						// a state, else nothing (an empty file).
						CMD_FILE_READ_START:
							if (cmd_reg1 == FILE_STATE)
								cmd_reg0 <= state_present ? 32'(SLOT_BYTES) : 32'd0;
						CMD_FILE_READ_END: ;
						default: cmd_state <= CMD_ERROR;
					endcase
				end
			end else begin
				cmd_state <= CMD_IDLE;
			end
		end
	end

	// =========================================================================
	// Console
	// =========================================================================
	// Held in reset while halted or loading, and for a while after a reset
	// request (the core counts a power cycle on each rising edge of reset
	// after a load).
	logic [7:0] reset_stretch;
	always_ff @(posedge clock) begin
		if (reset || reset_request)
			reset_stretch <= 8'hFF;
		else if (reset_stretch != 8'd0)
			reset_stretch <= reset_stretch - 8'd1;
	end
	wire core_reset = reset || core_halt || rom_loading || reset_stretch != 8'd0;

	// Pause behind the menu: frozen while unfocused, mid-frame if need be
	// (the framework keeps showing the last whole frame).
	//
	// Reset from the menu also sends one black 320x240 frame (colour 0) in
	// the framework's protocol: vblank high for a cycle (this swaps in what
	// the frozen game had drawn of its frame, for the ~5 ms until the black
	// one is done), 240 rows of 320 writes each ended by one cycle of
	// hblank, then vblank high again, which shows it. The core stays frozen
	// until it is done, even if the menu closes first, and the line counter
	// (see "Video") restarts, so the game's first frame is a whole one.
	localparam int BLACK_W = 320, BLACK_H = 240;

	logic       black_busy;
	logic       black_first;   // the opening vblank cycle
	logic [8:0] black_x;       // BLACK_W = the row's hblank cycle
	logic [7:0] black_y;

	logic        ss_busy, ss_loaded;  // a save-state operation runs / a load just ended (see "Save state")
	logic [15:0] ss_paddle_pos;       // paddle A's position, from the loaded state
	logic        ss_hold, ss_en, ss_si, ss_so;   // the core's save-state port
	logic [15:0] ss_mem_addr;
	logic        ss_mem_we;
	logic  [7:0] ss_mem_wdata, ss_mem_rdata;

	wire black_begin = (reset_request && !core_focus) || ss_loaded;

	always_ff @(posedge clock) begin
		if (reset) begin
			black_busy <= 1'b0;
		end else if (black_begin) begin
			black_busy  <= 1'b1;
			black_first <= 1'b1;
			black_x     <= 9'd0;
			black_y     <= 8'd0;
		end else if (black_busy) begin
			black_first <= 1'b0;
			if (!black_first) begin
				if (black_x != 9'(BLACK_W)) begin
					black_x <= black_x + 9'd1;
				end else begin
					black_x <= 9'd0;
					black_y <= black_y + 8'd1;
					if (black_y == 8'(BLACK_H - 1))
						black_busy <= 1'b0;
				end
			end
		end
	end

	wire core_pause = !core_focus || black_busy || ss_busy;

	// Paddle on the d-pad. Paddle A's position (upstream's 0..255 "kohms";
	// the game reads roughly 3/4 of it as its line count) moves while Left
	// or Right is held: Right lowers it, as upstream's analog stick and
	// mouse mappings do (stick right -> low value). The speed ramps up the
	// longer the button is held, from a slow start for fine aiming to a
	// fast sweep, in 8.8 fixed point, one step per PADDLE_TICK clocks
	// (2^14 / 14.318 MHz = 1.14 ms):
	//   start PADDLE_VMIN/256 per step  = full range in ~3.1 s
	//   top   PADDLE_VMAX/256 per step  = full range in ~0.6 s
	//   ramp  +1 every 4 steps          = start to top in ~0.48 s
	// The position starts centred on each new ROM and keeps its value
	// across console resets, like a real knob. The framework passes buttons
	// only while the core has focus, so the menu never moves it.
	localparam int         PADDLE_TICK_BITS = 14;
	localparam logic [7:0] PADDLE_VMIN      = 8'd24;
	localparam logic [7:0] PADDLE_VMAX      = 8'd128;

	logic [PADDLE_TICK_BITS-1:0] paddle_tick;
	logic [15:0] paddle_pos;    // 8.8, [15:8] = position
	logic  [7:0] paddle_vel;
	logic  [1:0] paddle_ramp;

	wire paddle_up   = input_buttons_left && !input_buttons_right;   // higher value
	wire paddle_down = input_buttons_right && !input_buttons_left;   // lower value
	wire paddle_fire = input_buttons_a | input_buttons_b | input_buttons_x | input_buttons_y;

	always_ff @(posedge clock) begin
		paddle_tick <= paddle_tick + 1'd1;
		if (reset || load_start) begin
			paddle_tick <= '0;
			paddle_pos  <= 16'h8000;
			paddle_vel  <= PADDLE_VMIN;
			paddle_ramp <= 2'd0;
		end else if (ss_loaded) begin
			// The knob goes back where it was when the state was saved.
			paddle_pos  <= ss_paddle_pos;
			paddle_vel  <= PADDLE_VMIN;
			paddle_ramp <= 2'd0;
		end else if (paddle_tick == '1) begin
			if (paddle_up || paddle_down) begin
				if (paddle_up)
					paddle_pos <= 17'(paddle_pos) + 17'(paddle_vel) > 17'hFFFF ? 16'hFFFF
					            : paddle_pos + 16'(paddle_vel);
				else
					paddle_pos <= paddle_pos < 16'(paddle_vel) ? 16'h0000
					            : paddle_pos - 16'(paddle_vel);
				paddle_ramp <= paddle_ramp + 2'd1;
				if (paddle_ramp == 2'd3 && paddle_vel < PADDLE_VMAX)
					paddle_vel <= paddle_vel + 8'd1;
			end else begin
				paddle_vel  <= PADDLE_VMIN;
				paddle_ramp <= 2'd0;
			end
		end
	end

	logic        core_hsync, core_vsync, core_hblank, core_vblank, core_ce_pix;
	logic  [6:0] core_color;
	logic [15:0] core_audio_l, core_audio_r;

	atari2600_core #(.ROM_ADDR_WIDTH(ROM_ADDR_WIDTH)) core (
		.clk_sys         (clock),
		.reset           (core_reset),
		.pause           (core_pause),
		.load_start      (load_start),
		.load_valid      (core_load_valid),
		.load_addr       (core_load_addr),
		.load_data       (core_load_data),
		.load_end        (load_end),
		.mapper_override (set_mapper),
		.sc_override     (set_sc),
		.mapper          (core_mapper),
		.mapper_sc       (core_mapper_sc),
		// Joystick: d-pad, fire on any face button. Paddle: d-pad moves
		// paddle A (above), any face button is its button (PA7, the
		// joystick's Right line); paddle B sits at 0, as upstream leaves an
		// unassigned paddle. Player 2 idle.
		.pa_in           (set_paddle ? {~paddle_fire, 7'b111_1111}
		                             : {~input_buttons_right, ~input_buttons_left,
		                                ~input_buttons_down, ~input_buttons_up, 4'b1111}),
		.fire_n          ({1'b1, set_paddle || !paddle_fire}),
		.paddle          (4'b0000),
		.paddle_en       (set_paddle),
		.paddle_pos_a    (paddle_pos[15:8]),
		.paddle_pos_b    (8'd0),
		.sw_reset_n      (~input_buttons_start),
		.sw_select_n     (~input_buttons_select),
		.sw_color        (set_color),
		.sw_diff_left    (set_diff_left),
		.sw_diff_right   (set_diff_right),
		.red             (),
		.green           (),
		.blue            (),
		.color           (core_color),
		.hsync           (core_hsync),
		.vsync           (core_vsync),
		.hblank          (core_hblank),
		.vblank          (core_vblank),
		.ce_pix          (core_ce_pix),
		.tia_pal         (),
		.audio_l         (core_audio_l),
		.audio_r         (core_audio_r),
		.ss_hold         (ss_hold),
		.ss_en           (ss_en),
		.ss_si           (ss_si),
		.ss_so           (ss_so),
		.ss_mem_addr     (ss_mem_addr),
		.ss_mem_we       (ss_mem_we),
		.ss_mem_wdata    (ss_mem_wdata),
		.ss_mem_rdata    (ss_mem_rdata)
	);

	// TIA mix: unsigned 0 (silence) .. 0x7FFF, so it is also a valid
	// non-negative signed sample and silence is 0. Held while a save-state
	// operation has the console's outputs scrambled.
	logic [15:0] audio_l_q, audio_r_q;
	always_ff @(posedge clock)
		if (!ss_hold) {audio_l_q, audio_r_q} <= {core_audio_l, core_audio_r};
	assign audio_left  = ss_hold ? audio_l_q : core_audio_l;
	assign audio_right = ss_hold ? audio_r_q : core_audio_r;

	// =========================================================================
	// Save state
	// =========================================================================
	// One slot, SLOT_BYTES of block RAM, in this layout (little-endian
	// words):
	//   0x000  header: 0 magic "ATSS", 1 {console 1 = 2600, format 1},
	//          2 CHAIN_BITS, 3 MEM_BYTES, 4 ROM size, 5 ROM CRC-32,
	//          6 {Superchip, bankswitch scheme} as status bits [14:8],
	//          7 paddle A's position (8.8)
	//   0x040  the register chain, bit i at byte i / 8, bit i % 8
	//   0x400  the console's memory (MEM_BYTES, as ss_mem_addr maps it)
	// A state is loadable when header words 0-6 match this ROM, scheme and
	// core; the slot is saved back to the card whenever word 0 is right.
	//
	// The sequence follows hdl/atari2600_core.sv: the console paused (and the
	// framework still shown its last whole frame), SETTLE clocks, the
	// operation, SETTLE clocks. A load ends with the black frame of Reset
	// (see "Console"), whose line counter restart makes the game's next
	// frame the first one drawn. A Load State is first checked against the
	// header, and refused (status bit 18) if nothing loadable is there.
	localparam logic [31:0] SS_MAGIC  = 32'h5353_5441;   // "ATSS"
	localparam logic [31:0] SS_FORMAT = 32'h0000_0101;   // console 1, format 1

	// The chain area holds 8 * (SLOT_MEM - SLOT_CHAIN) = 7680 bits; CHAIN_BITS
	// is 3365.

	// The slot: port A the host's (whole words), port B the sequencer's.
	// ram_decomp "power": Vivado's default split of a depth just over 8K
	// takes 16 RAMB36; split by width it takes 9 (and keeps byte writes).
	(* ram_decomp = "power" *) logic [31:0] slot [SLOT_WORDS];
	logic [SLOT_AW-1:0] slot_addr_b;
	logic  [3:0]        slot_we_b;
	logic [31:0]        slot_wdata_b, slot_q_b;

	always_ff @(posedge clock) begin
		if (slot_we_a)
			slot[slot_addr_a] <= host_mem_dataWrite;
		slot_q_a <= slot[slot_addr_a];
	end
	always_ff @(posedge clock) begin
		for (int i = 0; i < 4; i++)
			if (slot_we_b[i])
				slot[slot_addr_b][8 * i +: 8] <= slot_wdata_b[8 * i +: 8];
		slot_q_b <= slot[slot_addr_b];
	end

	// Header word n as this ROM and core would write it.
	function automatic logic [31:0] header(input int n);
		case (n)
			0: return SS_MAGIC;
			1: return SS_FORMAT;
			2: return 32'(CHAIN_BITS);
			3: return 32'(MEM_BYTES);
			4: return rom_bytes;
			5: return ~rom_crc;
			6: return {24'd0, core_mapper_sc, 1'b0, core_mapper};
			default: return {16'd0, paddle_pos};
		endcase
	endfunction

	typedef enum logic [2:0] {
		SS_IDLE,
		SS_CHECK,   // read header words 0-7, compare 0-6
		SS_PRE,     // SETTLE paused clocks
		SS_MEM,     // memory, one byte a clock
		SS_CPREP,   // first chain byte on its way (load)
		SS_CHAIN,   // the chain, one bit a clock
		SS_HEADER,  // header words (save)
		SS_POST     // SETTLE paused clocks
	} ss_state_t;

	ss_state_t   ss_state;
	logic        ss_save;       // this operation saves (else loads)
	logic        ss_check_only; // a check after the file came in
	logic [15:0] ss_i;          // clock within the phase
	logic        ss_match_magic, ss_match;
	logic  [7:0] ss_acc;        // chain bits of the byte being saved

	assign ss_busy = ss_state != SS_IDLE && !ss_check_only;
	assign ss_hold = ss_state == SS_MEM || ss_state == SS_CPREP || ss_state == SS_CHAIN;
	assign ss_en   = ss_state == SS_CHAIN;

	// Byte b of the slot as port B reads it (the word of the clock before).
	function automatic logic [7:0] slot_byte(input logic [31:0] w, input logic [1:0] b);
		return w[8 * b +: 8];
	endfunction

	wire [15:0] ss_mem_prev   = ss_i - 16'd1;              // the byte port B read or the core gave last clock
	wire [15:0] ss_chain_byte = 16'(SLOT_CHAIN) + (ss_i >> 3);
	wire [15:0] ss_next_byte  = 16'(SLOT_CHAIN) + ((ss_i + 16'd1) >> 3);
	wire  [7:0] ss_acc_now    = ss_acc | (8'(ss_so) << ss_i[2:0]);
	wire        ss_chain_last = ss_i == 16'(CHAIN_BITS - 1);

	always_comb begin
		slot_addr_b  = '0;
		slot_we_b    = 4'd0;
		slot_wdata_b = 32'd0;
		ss_mem_addr  = 16'd0;
		ss_mem_we    = 1'b0;
		ss_mem_wdata = 8'd0;
		ss_si        = 1'b0;
		case (ss_state)
			SS_CHECK: slot_addr_b = SLOT_AW'(ss_i);
			SS_MEM: begin
				if (ss_save) begin
					// Core memory at ss_i; last clock's byte into the slot.
					ss_mem_addr = ss_i;
					if (ss_i != 16'd0) begin
						slot_addr_b  = SLOT_AW'((16'(SLOT_MEM) + ss_mem_prev) >> 2);
						slot_we_b    = 4'd1 << ss_mem_prev[1:0];
						slot_wdata_b = {4{ss_mem_rdata}};
					end
				end else begin
					// Slot byte ss_i on its way; last clock's into the core.
					if (ss_i != 16'(MEM_BYTES))
						slot_addr_b = SLOT_AW'((16'(SLOT_MEM) + ss_i) >> 2);
					if (ss_i != 16'd0) begin
						ss_mem_addr  = ss_mem_prev;
						ss_mem_we    = 1'b1;
						ss_mem_wdata = slot_byte(slot_q_b, ss_mem_prev[1:0]);
					end
				end
			end
			SS_CPREP: slot_addr_b = SLOT_AW'(SLOT_CHAIN >> 2);
			SS_CHAIN: begin
				if (ss_save) begin
					// Round the chain once; each bit into its byte.
					ss_si = ss_so;
					if (ss_i[2:0] == 3'd7 || ss_chain_last) begin
						slot_addr_b  = SLOT_AW'(ss_chain_byte >> 2);
						slot_we_b    = 4'd1 << ss_chain_byte[1:0];
						slot_wdata_b = {4{ss_acc_now}};
					end
				end else begin
					// The byte of bit ss_i came in this clock; ask for the
					// next clock's.
					slot_addr_b = SLOT_AW'(ss_next_byte >> 2);
					ss_si = slot_byte(slot_q_b, ss_chain_byte[1:0])[ss_i[2:0]];
				end
			end
			SS_HEADER: begin
				slot_addr_b  = SLOT_AW'(ss_i);
				slot_we_b    = 4'hF;
				slot_wdata_b = header(int'(ss_i));
			end
			default: ;
		endcase
	end

	always_ff @(posedge clock) begin
		ss_loaded <= 1'b0;
		if (reset) begin
			ss_state      <= SS_IDLE;
			ss_check_only <= 1'b0;
			state_ok      <= 1'b0;
			state_present <= 1'b0;
			state_refused <= 1'b0;
		end else begin
			ss_i <= ss_i + 16'd1;
			case (ss_state)
				SS_IDLE: begin
					ss_i           <= 16'd0;
					ss_match_magic <= 1'b1;
					ss_match       <= 1'b1;
					ss_check_only  <= 1'b0;
					if (state_file_end) begin
						ss_state      <= SS_CHECK;
						ss_check_only <= 1'b1;
					end else if (rom_loaded && !core_reset && !state_loading) begin
						if (save_request) begin
							ss_save  <= 1'b1;
							ss_state <= SS_PRE;
						end else if (load_request) begin
							ss_save  <= 1'b0;
							ss_state <= SS_CHECK;
						end
					end
				end
				SS_CHECK: begin
					// Word ss_i - 1 came in this clock.
					if (ss_i != 16'd0) begin
						if (ss_i == 16'd1 && slot_q_b != header(0))
							ss_match_magic <= 1'b0;
						if (ss_i <= 16'd7 && slot_q_b != header(int'(ss_mem_prev)))
							ss_match <= 1'b0;
						if (ss_i == 16'd8)
							ss_paddle_pos <= slot_q_b[15:0];
					end
					if (ss_i == 16'd8) begin
						ss_i <= 16'd0;
						if (ss_check_only) begin
							// A file holds a state only if it fills the slot.
							state_present <= ss_match_magic && state_words == 16'(SLOT_WORDS);
							state_ok      <= ss_match && state_words == 16'(SLOT_WORDS);
							ss_state      <= SS_IDLE;
						end else begin
							// state_present: a whole slot came in, or was saved.
							state_refused <= !(ss_match && state_present);
							ss_state      <= ss_match && state_present ? SS_PRE : SS_IDLE;
						end
					end
				end
				SS_PRE:
					if (ss_i == 16'(SETTLE - 1)) begin
						ss_i     <= 16'd0;
						ss_state <= SS_MEM;
					end
				SS_MEM:
					if (ss_i == 16'(MEM_BYTES)) begin
						ss_i     <= 16'd0;
						ss_acc   <= 8'd0;
						ss_state <= ss_save ? SS_CHAIN : SS_CPREP;
					end
				SS_CPREP: begin
					ss_i     <= 16'd0;
					ss_state <= SS_CHAIN;
				end
				SS_CHAIN: begin
					ss_acc <= ss_i[2:0] == 3'd7 ? 8'd0 : ss_acc_now;
					if (ss_chain_last) begin
						ss_i     <= 16'd0;
						ss_state <= ss_save ? SS_HEADER : SS_POST;
					end
				end
				SS_HEADER:
					if (ss_i == 16'd7) begin
						ss_i     <= 16'd0;
						ss_state <= SS_POST;
					end
				SS_POST:
					if (ss_i == 16'(SETTLE - 1)) begin
						ss_state <= SS_IDLE;
						if (ss_save) begin
							state_ok      <= 1'b1;
							state_present <= 1'b1;
							state_refused <= 1'b0;
						end else begin
							ss_loaded <= 1'b1;
						end
					end
				default: ss_state <= SS_IDLE;
			endcase
			// A new ROM or a new file: nothing known about the slot until
			// the file's header is checked.
			if (load_start || state_file_start) begin
				state_ok      <= 1'b0;
				state_present <= 1'b0;
				state_refused <= 1'b0;
			end
		end
	end

	// =========================================================================
	// Video: crop to 240 lines x 160 pixels, each pixel written twice.
	// =========================================================================
	// The framework writes one framebuffer pixel per cycle of dataEnable at
	// (x, y), moves to the next row on each rising edge of hblank, resets
	// x/y while vblank is high and swaps buffers on its rising edge. Its x/y
	// counters are not bounds-checked, so never emit more than 320 pixels per
	// row or 240 rows.
	//
	// Lines are counted from the rising edge of VSYNC, each ending at the
	// rising edge of the core's hblank (the TIA's undelayed horizontal gap;
	// HMOVE blanking shows as black pixels, so every line has 160 pixels).
	// vblank changes at the start of a line's pixels (falling hblank), never
	// together with a rising hblank, so the first kept line lands on row 0.
	localparam int V_LINES = 240;

	logic [8:0] line;          // lines since VSYNC (saturates)
	logic [7:0] pixel;         // pixels so far in this line (saturates at 160)
	logic       prev_vsync, prev_hblank;
	logic       fb_vblank, fb_hblank;
	logic [1:0] de_count;      // framebuffer writes left for the current pixel
	logic [6:0] de_color;

	wire in_window = line >= 9'(V_START) && line < 9'(V_START + V_LINES);

	always_ff @(posedge clock) begin
		if (de_count != 2'd0)
			de_count <= de_count - 2'd1;

		if (reset || black_begin) begin
			line        <= 9'h1FF;
			pixel       <= 8'd0;
			prev_vsync  <= 1'b0;
			prev_hblank <= 1'b1;
			fb_vblank   <= 1'b1;
			fb_hblank   <= 1'b1;
			de_count    <= 2'd0;
		end else if (core_ce_pix && !ss_hold) begin   // see "Save state"
			prev_vsync  <= core_vsync;
			prev_hblank <= core_hblank;
			fb_hblank   <= core_hblank;

			if (core_vsync && !prev_vsync)
				line <= 9'd0;
			else if (core_hblank && !prev_hblank && line != 9'h1FF)
				line <= line + 9'd1;

			if (core_hblank) begin
				pixel <= 8'd0;
			end else begin
				if (prev_hblank)
					fb_vblank <= !in_window;
				if (pixel != 8'd160) begin
					pixel <= pixel + 8'd1;
					// in_window as of this line; fb_vblank may update this
					// same cycle on the first pixel.
					if (in_window) begin
						de_count <= 2'd2;
						de_color <= core_color;
					end
				end
			end
		end
	end

	// The black frame (see "Console") takes over while it runs.
	assign video_dataEnable = black_busy ? !black_first && black_x != 9'(BLACK_W)
	                                     : de_count != 2'd0;
	assign video_vblank     = black_busy ? black_first : fb_vblank;
	assign video_hblank     = black_busy ? black_first || black_x == 9'(BLACK_W) : fb_hblank;
	assign {video_data_r, video_data_g, video_data_b} = black_busy ? 7'd0 : de_color;

	// =========================================================================
	// Video filter (display clock): stored TIA colour -> NTSC RGB. Latency 2.
	// =========================================================================
	logic [6:0]  filter_color;
	logic [23:0] filter_rgb;
	always_ff @(posedge videoFilter_clock) begin
		filter_color <= {videoFilter_dataIn_r, videoFilter_dataIn_g, videoFilter_dataIn_b};
		filter_rgb   <= atari2600_palette::ntsc(filter_color);
	end
	assign {videoFilter_dataOut_r, videoFilter_dataOut_g, videoFilter_dataOut_b} = filter_rgb;

endmodule

`default_nettype wire
