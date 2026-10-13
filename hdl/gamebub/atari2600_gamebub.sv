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
// The switches are bits the game reads itself, so after each settings write
// or Reset the console runs on for a few frames (see "Console") to read them
// and redraw behind the menu, then freezes again.
//
// Core memory map (32-bit registers):
//   0x0000_0000  r   status: [0] ROM loaded, [1] load error, [13:8] mapper,
//                    [14] Superchip
//   0x0000_1000  rw  left difficulty  (1 = A, 0 = B)
//   0x0000_1004  rw  right difficulty (1 = A, 0 = B)
//   0x0000_1008  rw  TV type (1 = colour, 0 = B&W)
//   0x0000_100C  rw  bankswitch override (bss_type; 0 = auto-detect)
//   0x0000_1010  rw  Superchip with a forced scheme (1 = on)
//   0x0000_1014  rw  controller (0 = joystick, 1 = paddle)
//   0x0000_2000  w   any write: console reset (power cycle; multicarts move on)
//   0x3000_0000  w   ROM file (file id 0), little-endian words, byte offset =
//                    address bits [27:0]
//   0xF000_0000  rw  host command opcode / result
//   0xF000_0004  rw  host command argument

`default_nettype none

module atari2600_gamebub #(
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

	localparam logic [31:0] FILE_ROM = 32'd0;

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
	assign host_mem_done = mem_busy && !rom_writing;

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

	assign host_commandHost_busy  = 1'b0;
	assign host_commandHost_done  = cmd_state == CMD_DONE;
	assign host_commandHost_error = cmd_state == CMD_ERROR;
	assign host_commandCore_request = 1'b0;

	always_ff @(posedge clock) begin
		load_start    <= 1'b0;
		load_end      <= 1'b0;
		reset_request <= 1'b0;

		if (reset) begin
			mem_busy          <= 1'b0;
			host_mem_dataRead <= 32'd0;
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
						32'hF000_0000: cmd_reg0       <= host_mem_dataWrite;
						32'hF000_0004: cmd_reg1       <= host_mem_dataWrite;
						default: ;
					endcase
				end
			end else if (mem_start) begin
				case (host_mem_address)
					32'h0000_0000: host_mem_dataRead <= {17'd0, core_mapper_sc, core_mapper,
					                                     6'd0, load_error, rom_loaded};
					32'h0000_1000: host_mem_dataRead <= {31'd0, set_diff_left};
					32'h0000_1004: host_mem_dataRead <= {31'd0, set_diff_right};
					32'h0000_1008: host_mem_dataRead <= {31'd0, set_color};
					32'h0000_100C: host_mem_dataRead <= {26'd0, set_mapper};
					32'h0000_1010: host_mem_dataRead <= {31'd0, set_sc};
					32'h0000_1014: host_mem_dataRead <= {31'd0, set_paddle};
					32'hF000_0000: host_mem_dataRead <= cmd_reg0;
					32'hF000_0004: host_mem_dataRead <= cmd_reg1;
					default:       host_mem_dataRead <= 32'd0;
				endcase
			end

			// ---- ROM bytes: one per cycle, then the access completes ----
			if (rom_writing) begin
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
							end
						CMD_FILE_READ_START, CMD_FILE_READ_END: ;
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

	// Pause behind the menu. Unfocused, the core runs only after a write to
	// a setting (0x1xxx) or the Reset action (0x2000): until the framework
	// has swapped framebuffers MENU_RUN_FRAMES times (rising edges of
	// video_vblank; the frame drawn after the game has read the new switch
	// is then on screen), or at most 2^MENU_RUN_BITS clocks (0.29 s) for a
	// game that never finishes a frame. Then it freezes again, mid-frame if
	// need be: the framework keeps showing the last whole frame.
	localparam logic [1:0] MENU_RUN_FRAMES = 2'd3;
	localparam int         MENU_RUN_BITS   = 22;

	logic [1:0]               menu_run_frames;   // swaps still to run
	logic [MENU_RUN_BITS-1:0] menu_run_clocks;   // clocks still allowed
	logic                     menu_prev_vblank;

	wire settings_write = mem_start && host_mem_write &&
	                      (host_mem_address[31:12] == 20'h00001 ||
	                       host_mem_address == 32'h0000_2000);

	always_ff @(posedge clock) begin
		menu_prev_vblank <= video_vblank;
		if (reset || core_focus) begin
			menu_run_frames <= 2'd0;
			menu_run_clocks <= '0;
		end else if (settings_write) begin
			menu_run_frames <= MENU_RUN_FRAMES;
			menu_run_clocks <= '1;
		end else if (menu_run_frames != 2'd0) begin
			if (menu_run_clocks == '0)
				menu_run_frames <= 2'd0;
			else if (video_vblank && !menu_prev_vblank)
				menu_run_frames <= menu_run_frames - 2'd1;
			menu_run_clocks <= menu_run_clocks - 1'd1;
		end
	end

	wire core_pause = !core_focus && menu_run_frames == 2'd0;

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
		.audio_r         (core_audio_r)
	);

	// TIA mix: unsigned 0 (silence) .. 0x7FFF, so it is also a valid
	// non-negative signed sample and silence is 0.
	assign audio_left  = core_audio_l;
	assign audio_right = core_audio_r;

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

		if (reset) begin
			line        <= 9'h1FF;
			pixel       <= 8'd0;
			prev_vsync  <= 1'b0;
			prev_hblank <= 1'b1;
			fb_vblank   <= 1'b1;
			fb_hblank   <= 1'b1;
			de_count    <= 2'd0;
		end else if (core_ce_pix) begin
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

	assign video_dataEnable = de_count != 2'd0;
	assign video_vblank     = fb_vblank;
	assign video_hblank     = fb_hblank;
	assign {video_data_r, video_data_g, video_data_b} = de_color;

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
