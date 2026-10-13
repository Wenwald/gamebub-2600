// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// Derived from rtl/top.sv of Atari7800_MiSTer:
//   Copyright (c) 2019-2026 Jamie Blanks, MIT License (see
//   third_party/atari7800_mister/LICENSE).
//
// Atari 2600 console only: the 2600 path of the upstream 7800 core with the
// 7800 cartridge, sound chips, BIOS, 7800 RAM, composite output and ARM
// mappers removed. Everything that remains is wired exactly as upstream wires
// it in 2600 mode (tia_mode = 1, bypass_bios = 1, cpu_driver = 1), so its
// behaviour can be checked against the unmodified reference build.
//
// MARIA is replaced by maria_2600, which keeps the only things the real chip
// does in 2600 mode: the master clock enables, the reset-time CPU phases and
// the chip selects (in 2600 mode it never draws, takes the bus or touches
// the 7800 RAM; hdl/maria_2600.sv lists what it keeps). Build with MARIA_FULL
// for the real chip, or MARIA_LOCKSTEP to check the two against each other.
//
// The cartridge ROM is an internal block RAM, written through the load_*
// port while the core is held in reset. detect2600 watches the same stream
// and picks the bankswitch scheme when the load ends.
//
// Paddles: with paddle_en, the left port's two paddles are emulated by
// upstream's paddle_timer (rtl/paddles.sv), wired as upstream's Atari7800.sv
// wires a paddle port: paddle A drives I0, paddle B drives I1, timed from
// the TIA's dump control and calibrated on the game's own INPT reads. The
// paddle buttons are the caller's: A on pa_in[7], B on pa_in[6], as on the
// real port.
//
// Pause: while pause is high the console stands still. As in upstream's
// pause, MARIA's clock divider stops, so the CPU, TIA, RIOT and cartridge
// get no more clock enables; the paddle timers stop too. Upstream also
// blocks cartridge RAM writes; with the bus frozen they could only repeat
// the byte already written, so this core leaves them be. Pixels already in
// the video pipeline still come out, then the outputs hold. Unlike upstream,
// video_mux keeps its normal path (no pixels are made up while paused).
// Reset overrides pause.

module atari2600_core #(
	parameter int ROM_ADDR_WIDTH = 16   // 64 KB
) (
	input  logic        clk_sys,        // 14.318182 MHz (NTSC)
	input  logic        reset,          // hold high while loading
	input  logic        pause,          // freeze the console (see above)

	// ROM load stream (one byte per load_valid).
	input  logic        load_start,     // pulse before the first byte
	input  logic        load_valid,
	input  logic [24:0] load_addr,
	input  logic  [7:0] load_data,
	input  logic        load_end,       // pulse after the last byte

	// Bankswitch selection. mapper_override 0 = use detection (scheme and
	// Superchip); otherwise that scheme, with Superchip RAM if sc_override.
	input  logic  [5:0] mapper_override,
	input  logic        sc_override,
	output logic  [5:0] mapper,         // scheme in use
	output logic        mapper_sc,      // Superchip RAM in use

	// Controllers and console switches, as the RIOT and TIA pins see them.
	input  logic  [7:0] pa_in,          // {P0 R,L,D,U, P1 R,L,D,U}, active low
	input  logic  [1:0] fire_n,         // {P1, P0} fire, active low
	input  logic  [3:0] paddle,         // TIA I0-I3 dump inputs (I0/I1 unless paddle_en)
	input  logic        paddle_en,      // left port: paddles instead of paddle[1:0]
	input  logic  [7:0] paddle_pos_a,   // paddle A (I0) position, 0..255 (upstream's kohms)
	input  logic  [7:0] paddle_pos_b,   // paddle B (I1) position
	input  logic        sw_reset_n,     // Game Reset, active low
	input  logic        sw_select_n,    // Game Select, active low
	input  logic        sw_color,       // 1 = colour, 0 = B&W
	input  logic        sw_diff_left,   // PB6
	input  logic        sw_diff_right,  // PB7

	// Video, one pixel per ce_pix.
	output logic  [7:0] red,
	output logic  [7:0] green,
	output logic  [7:0] blue,
	output logic  [6:0] color,          // raw TIA colour {chroma, luma} of this pixel
	output logic        hsync,
	output logic        vsync,
	output logic        hblank,
	output logic        vblank,
	output logic        ce_pix,
	output logic        tia_pal,        // TIA's own PAL autodetect

	// Audio: unsigned, 0 = silence, 0x7FFF = both channels at full volume.
	output logic [15:0] audio_l,
	output logic [15:0] audio_r
);

	// Fixed 2600-mode configuration. Upstream inputs, kept as names so the
	// logic below reads like top.sv.
	localparam logic tia_mode    = 1'b1;
	localparam logic bypass_bios = 1'b1;
	localparam logic cpu_driver  = 1'b1;
	localparam logic PAL         = 1'b0;

	/////////////
	// Signals //
	/////////////

	logic           NMI_n;
	logic           maria_RDY;
	logic           halt_n;
	logic           maria_drive_AB;
	logic [15:0]    maria_AB_out;
	logic           tia_RDY;
	logic           tia_RDY_seen_high;
	logic [3:0]     audv0, audv1;
	logic           RDY;
	logic [15:0]    cpu_AB;
	logic           cpu_halt_n;
	logic           maria_en;
	logic           lock_ctrl;
	logic           bios_en_b;
	logic [1:0]     ctrl_writes;
	logic           tia_en;
	logic [7:0]     read_DB;
	logic [7:0]     write_DB;
	logic           bus_stuff_valid;
	logic [7:0]     bus_stuff_data;
	wire  [7:0]     physical_write_DB = tia_en && bus_stuff_valid ?
		(write_DB & bus_stuff_data) : write_DB;
	logic [7:0]     tia_DB_out, riot_DB_out, maria_DB_out, cart_DB_out;
	logic [7:0]     tia_DB_oe, riot_DB_oe, maria_DB_oe, cart_DB_oe;
	logic           cpu_DB_oe, cpu_AB_oe, cpu_RW_oe;
	logic           mclk0, mclk1;
	logic           cs_ram0, cs_ram1, cs_tia, cs_riot, cs_maria;
	logic [7:0]     open_bus;
	logic           cpu_rwn;
	logic [15:0]    last_address;
	logic           pclk1, pclk0, pclk1_m, pclk0_m, pclk1_t, pclk0_t;
	logic           pclk1_raw, pclk0_raw;
	logic           phase_source_tia;
	logic           phase_edge_source_tia;
	logic           phase_source_stable;
	logic           phase_valid;
	logic           reset_hold = 1'b1;
	logic [1:0]     reset_phase_wait = 2'd0;
	logic           tia_clk_x2;
	logic [15:0]    AB;
	logic           RW;

	wire tia_clock_after_reset = cpu_driver && bypass_bios && tia_mode;
	wire effective_reset = reset | reset_hold;
	wire phase_source_request_tia = cpu_driver && !effective_reset &&
		ctrl_writes == 2'd2 && tia_en;
	wire first_phase_is_phi1 = bypass_bios && tia_mode &&
		!tia_clock_after_reset;

	// Reset release lands on the phase before the first one the CPU acts on
	// (top.sv:232-254).
	always_ff @(posedge clk_sys) begin
		if (reset) begin
			reset_hold <= 1'b1;
			reset_phase_wait <= 2'd0;
		end
		else if (reset_hold && phase_source_stable && phase_valid &&
			!phase_source_tia) begin
			if (first_phase_is_phi1) begin
				if (reset_phase_wait == 2'd1)
					reset_hold <= 1'b0;
				else if (reset_phase_wait != 2'd0)
					reset_phase_wait <= reset_phase_wait - 1'd1;
				else if (pclk0)
					reset_phase_wait <= 2'd3;
			end else if (pclk1) begin
				reset_hold <= 1'b0;
			end
		end
	end

	// SHB and the CPU phase can collapse onto one clk_sys tick in 2600 mode
	// (top.sv:256-265).
	always_ff @(posedge clk_sys) begin
		if (effective_reset)
			tia_RDY_seen_high <= 1'b1;
		else if (!tia_RDY)
			tia_RDY_seen_high <= 1'b0;
		else if (pclk1)
			tia_RDY_seen_high <= 1'b1;
	end

	assign RDY = maria_RDY && tia_RDY && (~tia_en || tia_RDY_seen_high);
	assign cpu_halt_n = (ctrl_writes == 2'd2) ? halt_n : 1'b1;

	wire [7:0] DB = cpu_DB_oe ? physical_write_DB : read_DB;

	always_ff @(posedge clk_sys) begin
		open_bus <= DB;
		last_address <= AB;
	end

	wire cs_cart = ~|{cs_ram0, cs_ram1, cs_tia, cs_riot, cs_maria};

	// Bus resolution (top.sv:328-359), without the 7800 RAMs and BIOS.
	always_comb begin
		case ({cpu_AB_oe, maria_drive_AB})
			2'b00 : AB = last_address;
			2'b01 : AB = maria_AB_out;
			2'b10 : AB = cpu_AB;
			2'b11 : AB = cpu_AB & maria_AB_out;
		endcase
		RW = cpu_RW_oe ? cpu_rwn : 1'b1;

		read_DB = open_bus;
		if (RW) begin
			if (cs_tia)   read_DB = (tia_DB_out   & tia_DB_oe)   | (open_bus & ~tia_DB_oe);
			if (cs_riot)  read_DB = (riot_DB_out  & riot_DB_oe)  | (open_bus & ~riot_DB_oe);
			if (cs_maria) read_DB = (maria_DB_out & maria_DB_oe) | (open_bus & ~maria_DB_oe);
			if (cs_cart)  read_DB = (cart_DB_out  & cart_DB_oe)  | (open_bus & ~cart_DB_oe);
		end
	end

	cpu_phase_controller phase_controller
	(
		.clk_sys        (clk_sys),
		.request_tia    (phase_source_request_tia),
		.maria_phi1     (pclk1_m),
		.maria_phi2     (pclk0_m),
		.tia_phi1       (pclk1_t),
		.tia_phi2       (pclk0_t),
		.phi1           (pclk1_raw),
		.phi2           (pclk0_raw),
		.active_tia     (phase_source_tia),
		.edge_source_tia(phase_edge_source_tia),
		.source_stable  (phase_source_stable),
		.phase_valid    (phase_valid)
	);

	// MARIA. With MEN low it only divides the clocks and decodes the chip
	// selects, so by default the core uses maria_2600, which does exactly
	// that. MARIA_FULL builds with the real chip instead; MARIA_LOCKSTEP runs
	// both and stops the simulation on the first cycle where any output this
	// core uses differs.
`ifdef MARIA_FULL
	maria maria_inst(
`else
	assign maria_drive_AB = 1'b0;
	assign maria_AB_out   = 16'd0;
	assign maria_DB_out   = 8'd0;
	assign maria_DB_oe    = 8'd0;
	assign cs_ram0        = 1'b0;
	assign cs_ram1        = 1'b0;
	assign cs_maria       = 1'b0;
	assign NMI_n          = 1'b1;
	assign halt_n         = 1'b1;
	assign maria_RDY      = 1'b1;

	maria_2600 maria_inst
	(
		.clk_sys    (clk_sys),
		.ce         (~pause || effective_reset),
		.AB_in      (AB),
		.mclk0      (mclk0),
		.mclk1      (mclk1),
		.tia_clk_x2 (tia_clk_x2),
		.pclk0      (pclk0_m),
		.pclk1      (pclk1_m),
		.cs_riot    (cs_riot),
		.cs_tia     (cs_tia)
	);
`endif
`ifdef MARIA_LOCKSTEP
	logic        r_mclk0, r_mclk1, r_tia_clk_x2, r_pclk0, r_pclk1;
	logic        r_cs_ram0, r_cs_ram1, r_cs_riot, r_cs_tia, r_cs_maria;
	logic        r_NMI_n, r_halt_n, r_ready, r_drive_AB;
	logic  [7:0] r_DB_oe;

	maria maria_ref(
`endif
`ifdef MARIA_FULL
		.ce             (~pause || effective_reset),
		.mclk0          (mclk0),
		.mclk1          (mclk1),
		.tia_clk_x2     (tia_clk_x2),
		.AB_in          (AB),
		.AB_out         (maria_AB_out),
		.drive_AB       (maria_drive_AB),
		.hide_border    (1'b0),
		.bypass_bios    (bypass_bios),
		.PAL            (PAL),
		.d_in           (DB),
		.DB_out         (maria_DB_out),
		.DB_out_oe      (maria_DB_oe),
		.reset          (effective_reset),
		.clk_sys        (clk_sys),
		.pclk0          (pclk0_m),
		.pclk1          (pclk1_m),
		.pclk2          (pclk0),
		.RW             (RW),
		.maria_en       (maria_en),
		.YC             (),
		.cs_ram0        (cs_ram0),
		.cs_ram1        (cs_ram1),
		.cs_riot        (cs_riot),
		.cs_tia         (cs_tia),
		.cs_maria       (cs_maria),
		.NMI_n          (NMI_n),
		.halt_n         (halt_n),
		.ready          (maria_RDY),
		.vsync          (),
		.vblank         (),
		.vblank_ex      (),
		.hsync          (),
		.hblank         ()
	);
`elsif MARIA_LOCKSTEP
		.ce             (~pause || effective_reset),
		.mclk0          (r_mclk0),
		.mclk1          (r_mclk1),
		.tia_clk_x2     (r_tia_clk_x2),
		.AB_in          (AB),
		.AB_out         (),
		.drive_AB       (r_drive_AB),
		.hide_border    (1'b0),
		.bypass_bios    (bypass_bios),
		.PAL            (PAL),
		.d_in           (DB),
		.DB_out         (),
		.DB_out_oe      (r_DB_oe),
		.reset          (effective_reset),
		.clk_sys        (clk_sys),
		.pclk0          (r_pclk0),
		.pclk1          (r_pclk1),
		.pclk2          (pclk0),
		.RW             (RW),
		.maria_en       (maria_en),
		.YC             (),
		.cs_ram0        (r_cs_ram0),
		.cs_ram1        (r_cs_ram1),
		.cs_riot        (r_cs_riot),
		.cs_tia         (r_cs_tia),
		.cs_maria       (r_cs_maria),
		.NMI_n          (r_NMI_n),
		.halt_n         (r_halt_n),
		.ready          (r_ready),
		.vsync          (),
		.vblank         (),
		.vblank_ex      (),
		.hsync          (),
		.hblank         ()
	);

	// READY powers up undefined in the real chip and is set by the first
	// reset edge, so start comparing one clock in.
	logic [63:0] lockstep_cycle = 64'd0;
	always_ff @(posedge clk_sys) begin
		lockstep_cycle <= lockstep_cycle + 64'd1;
		if (lockstep_cycle != 64'd0 && (
			r_mclk0 != mclk0 || r_mclk1 != mclk1 || r_tia_clk_x2 != tia_clk_x2 ||
			r_pclk0 != pclk0_m || r_pclk1 != pclk1_m ||
			r_cs_ram0 != cs_ram0 || r_cs_ram1 != cs_ram1 || r_cs_riot != cs_riot ||
			r_cs_tia != cs_tia || r_cs_maria != cs_maria ||
			r_NMI_n != NMI_n || r_halt_n != halt_n || r_ready != maria_RDY ||
			r_drive_AB != maria_drive_AB || r_DB_oe != maria_DB_oe)) begin
			$display("MARIA_LOCKSTEP mismatch at clk_sys cycle %0d", lockstep_cycle);
			$display("  ref: mclk %b%b x2 %b pclk %b%b cs r0 %b r1 %b riot %b tia %b maria %b nmi %b halt %b rdy %b drv %b oe %h",
				r_mclk0, r_mclk1, r_tia_clk_x2, r_pclk0, r_pclk1, r_cs_ram0, r_cs_ram1,
				r_cs_riot, r_cs_tia, r_cs_maria, r_NMI_n, r_halt_n, r_ready, r_drive_AB, r_DB_oe);
			$display("  dut: mclk %b%b x2 %b pclk %b%b cs r0 %b r1 %b riot %b tia %b maria %b nmi %b halt %b rdy %b drv %b oe %h",
				mclk0, mclk1, tia_clk_x2, pclk0_m, pclk1_m, cs_ram0, cs_ram1,
				cs_riot, cs_tia, cs_maria, NMI_n, halt_n, maria_RDY, maria_drive_AB, maria_DB_oe);
			$fatal(1, "MARIA stub diverged from the real chip");
		end
	end
`endif

	logic tia_vblank, tia_vsync, tia_hblank, tia_hsync;
	logic [3:0] tia_i, tia_i_out, tia_paddle_read;
	logic [1:0] paddle_wire;
	logic [3:0] tia_chroma;
	logic [2:0] tia_luma;
	logic tia_pix_ce;
	logic cart_ce_2600;

	TIA tia_inst
	(
		.clk            (clk_sys),
		.ce             (tia_clk_x2),
		.is_7800        (~(phase_source_tia || phase_edge_source_tia)),
		.phi0           (),
		.phi1           (),
		.phi0_gen       (pclk0_t),
		.phi1_gen       (pclk1_t),
		.phi2           (pclk0),
		.RW_n           (RW),
		.rdy            (tia_RDY),
		.addr           ({(AB[5] & tia_en), AB[4:0]}),
		.d_in           (physical_write_DB),
		.d_out          (tia_DB_out),
		.d_out_oe       (tia_DB_oe),
		.i              (tia_i),
		.i_out          (tia_i_out),
		.i4             (fire_n[0]),
		.i5             (fire_n[1]),
		.aud0           (audv0),
		.aud1           (audv1),
		.col            (tia_chroma),
		.lum            (tia_luma),
		.BLK_n          (),
		.sync           (),
		.cs0_n          (~cs_tia),
		.cs2_n          (~cs_tia),
		.rst            (effective_reset),
		.video_ce       (tia_pix_ce),
		.vblank         (tia_vblank),
		.hblank         (),
		.hgap           (tia_hblank),
		.vsync          (tia_vsync),
		.hsync          (tia_hsync),
		.row            (),
		.column         (),
		.phi1_in        (pclk1),
		.cart_ce        (cart_ce_2600),
		.decomb         (1'b0),
		.is_pal         (tia_pal),
		.stabilize      (1'b0),
		.is_f1          (),
		.paddle_read    (tia_paddle_read)
	);

	// Paddles (upstream Atari7800.sv: paddle_timer per paddle, cleared while
	// the TIA dumps the pots, i.e. VBLANK bit 7; i_out is ~VBLANK[7]).
	logic [33:0] paddle_diff_a, paddle_diff_b;
	paddle_timer paddle_a (clk_sys, ~pause, reset || ~paddle_en, {2'b00, paddle_pos_a},
	                       ~tia_i_out[0], tia_paddle_read[0], paddle_wire[0], paddle_diff_a);
	paddle_timer paddle_b (clk_sys, ~pause, reset || ~paddle_en, {2'b00, paddle_pos_b},
	                       ~tia_i_out[0], tia_paddle_read[1], paddle_wire[1], paddle_diff_b);
	assign tia_i = {paddle[3:2], paddle_en ? paddle_wire : paddle[1:0]};

	// Palette lookup to RGB. The MARIA inputs are unused with is_maria = 0.
	video_mux mux
	(
		.clk_sys        (clk_sys),
		.maria_luma     (4'd0),
		.maria_chroma   (4'd0),
		.maria_hblank   (1'b0),
		.maria_vblank   (1'b0),
		.maria_hsync    (1'b0),
		.maria_vsync    (1'b0),
		.maria_pix_ce   (1'b0),
		.tia_luma       (tia_luma),
		.tia_chroma     (tia_chroma),
		.tia_hblank     (tia_hblank),
		.tia_vblank     (tia_vblank),
		.tia_hsync      (tia_hsync),
		.tia_vsync      (tia_vsync),
		.tia_pix_ce     (tia_pix_ce),
		.pause          (1'b0),
		.is_maria       (1'b0),
		.pal_temp       (2'd0),
		.pal_load       (1'b0),
		.pal_data       (8'd0),
		.pal_addr       (10'd0),
		.pal_wr         (1'b0),
		.is_PAL         (PAL),
		.hblank         (hblank),
		.vblank         (vblank),
		.hsync          (hsync),
		.vsync          (vsync),
		.red            (red),
		.green          (green),
		.blue           (blue),
		.pix_ce         (ce_pix),
		.blend          (1'b0)
	);

	// Raw TIA colour, timed like red/green/blue: video_mux addresses its
	// palette RAM with {chroma, luma, 0} on the TIA pixel strobe and latches
	// the RGB one clock later (when it raises its delayed strobe), so do the
	// same here. NTSC palette entry 2*color is the RGB above (checked per
	// pixel by sim/core/tb_core.cpp).
	logic [6:0] tia_color_q;
	logic       tia_pix_ce_q;
	always_ff @(posedge clk_sys) begin
		tia_pix_ce_q <= tia_pix_ce;
		if (tia_pix_ce)
			tia_color_q <= {tia_chroma, tia_luma};
		if (tia_pix_ce_q)
			color <= tia_color_q;
	end

	// TIA audio through the non-linear mixing table (top.sv:578-594). Mono:
	// both channels carry audv0 + audv1, as upstream does with stereo off.
	logic [15:0] audio_lut[32];
	assign audio_lut = '{
		16'h0000, 16'h0842, 16'h0FFF, 16'h1745, 16'h1E1D, 16'h2492, 16'h2AAA, 16'h306E,
		16'h35E4, 16'h3B13, 16'h3FFF, 16'h44AE, 16'h4924, 16'h4D64, 16'h5173, 16'h5554,
		16'h590A, 16'h5C97, 16'h5FFF, 16'h6343, 16'h6665, 16'h6968, 16'h6C4D, 16'h6F17,
		16'h71C6, 16'h745C, 16'h76DA, 16'h7942, 16'h7B95, 16'h7DD3, 16'h7FFF, 16'hFFFF
	};
	wire [4:0] aud_index = audv0 + audv1;
	assign audio_l = audio_lut[aud_index];
	assign audio_r = audio_lut[aud_index];

	// RIOT. Port B carries the console switches; PB2/4/5 are unconnected and
	// read back what the RIOT drives.
	logic [7:0] PAout, PBout;
	wire  [7:0] PBin = {sw_diff_right, sw_diff_left, PBout[5:4], sw_color,
		PBout[2], sw_select_n, sw_reset_n};

	M6532 riot_inst
	(
		.clk          (clk_sys),
		.ce           (pclk0),
		.res_n        (~effective_reset),
		.ram_init     (effective_reset),
		.ram_init_7800(~tia_mode),
		.addr         (AB[6:0]),
		.RW_n         (RW),
		.d_in         (physical_write_DB),
		.d_out        (riot_DB_out),
		.RS_n         (AB[9]),
		.IRQ_n        (),
		.IRQ_n_oe     (),
		.CS1          (AB[7]),
		.CS2_n        (~cs_riot),
		.PA_in        (pa_in),
		.PA_out       (PAout),
		.PB_in        (PBin),
		.PB_out       (PBout),
		.oe           (riot_DB_oe),
		.PA_read      ()
	);

	M6502C cpu_inst
	(
		.pclk1        (pclk1_raw),
		.pclk0        (pclk0_raw),
		.phi1_ce      (pclk1),
		.phi2_ce      (pclk0),
		.clk_sys      (clk_sys),
		.reset        (effective_reset),
		.AB           (cpu_AB),
		.DB_IN        (read_DB),
		.DB_OUT       (write_DB),
		.DB_OE        (cpu_DB_oe),
		.AB_OE        (cpu_AB_oe),
		.RW_OE        (cpu_RW_oe),
		.RD           (cpu_rwn),
		.IRQ_n        (1'b1),
		.NMI_n        (NMI_n),
		.RDY          (RDY),
		.halt_n       (cpu_halt_n),
		.is_halted    ()
	);

	ctrl_reg ctrl
	(
		.clk          (clk_sys),
		.pclk0        (pclk0),
		.d_in         (write_DB[3:0]),
		.cs           (cs_tia),
		.latch_b      (RW | lock_ctrl),
		.rst          (effective_reset),
		.lock_out     (lock_ctrl),
		.bypass_bios  (bypass_bios),
		.maria_en_out (maria_en),
		.bios_en_out  (bios_en_b),
		.tia_en_out   (tia_en),
		.writes       (ctrl_writes),
		.tia_mode     (tia_mode)
	);

	//////////////////////
	// Cartridge        //
	//////////////////////

	// ROM image size, as MiSTer's a78_cart_extent computes it for a 2600 file:
	// the last load address plus one.
	logic [31:0] cart_size = 32'd4096;
	always_ff @(posedge clk_sys)
		if (load_valid) cart_size <= {7'd0, load_addr} + 32'd1;

	logic  [5:0] detected_bs;
	logic  [2:0] mapper_revision;
	logic        detected_sc;

	detect2600 detect
	(
		.clk                    (clk_sys),
		.load_start             (load_start),
		.load_addr              (load_addr),
		.load_valid             (load_valid),
		.load_end               (load_end),
		.cart_size              (cart_size),
		.data                   (load_data),
		.force_bs               (detected_bs),
		.sc                     (detected_sc),
		.mapper_revision        (mapper_revision),
		.cdf_ldx                (),
		.cdf_ldy                (),
		.cdf_fetch_offset_enable(),
		.cdf_fetch_offset       (),
		.cdfj_entry             (),
		.cdfj_stack             (),
		.arm_audio_size_addr    ()
	);

	assign mapper = |mapper_override ? mapper_override : detected_bs;
	assign mapper_sc = |mapper_override ? sc_override : detected_sc;

	// Cartridge ROM. Written by the load stream, read by cart2600.
	logic [18:0] rom_a;
	logic  [7:0] rom_q;

	spram #(.addr_width(ROM_ADDR_WIDTH), .mem_name("ROM")) rom
	(
		.clock   (clk_sys),
		.address (load_valid ? load_addr[ROM_ADDR_WIDTH-1:0] : rom_a[ROM_ADDR_WIDTH-1:0]),
		.data    (load_data),
		.wren    (load_valid),
		.cs      (1'b1),
		.q       (rom_q)
	);

	// Cartridge RAM (Superchip, E7, CV, FA, 3E, AR ...). 32 KB covers every
	// non-ARM scheme.
	logic [17:0] cartram_addr;
	logic        cartram_wr, cartram_rd;
	logic  [7:0] cartram_wrdata, cartram_q;

	spram #(.addr_width(15), .mem_name("CRAM")) cart_ram
	(
		.clock   (clk_sys),
		.address (cartram_addr[14:0]),
		.data    (cartram_wrdata),
		.wren    (cartram_wr),
		.cs      (1'b1),
		.q       (cartram_q)
	);

	// What the 2600 slot sees on the data lines (top.sv:1012-1015).
	wire [7:0] cart_din = RW ? read_DB : write_DB;

	cart2600 cart2600
	(
		.pal            (PAL),
		.ddr_timeout    (1'b0),
		.d_out          (cart_DB_out),
		.d_in           (cart_din),
		.a_in           ({AB[12] & bios_en_b, AB[11:0]}),
		.rw             (RW),
		.reset          (effective_reset),
		.clk            (clk_sys),
		.ce             (cart_ce_2600),
		.phi1           (pclk1),
		.phi2           (pclk0),
		.arm_driver_run (lock_ctrl && tia_en),
		.sc             (mapper_sc),
		.mapper         (mapper),
		.mapper_revision(mapper_revision),
		.cdf_ldx        (1'b0),
		.cdf_ldy        (1'b0),
		.cdf_fetch_offset_enable(1'b0),
		.cdf_fetch_offset(8'd0),
		.cdfj_entry     (32'd0),
		.cdfj_stack     (32'd0),
		.arm_audio_size_addr(16'd0),
		.rom_do         (rom_q),
		.rom_size       (cart_size),
		.rom_a          (rom_a),
		.rom_read       (),
		.cartram_addr   (cartram_addr),
		.cartram_wr     (cartram_wr),
		.cartram_rd     (cartram_rd),
		.cartram_wrdata (cartram_wrdata),
		.cartram_data   (cartram_q),
		.clk_arm        (clk_sys),
		.reset_arm      (1'b1),
		.cartram_word_data(32'd0),
		.load_start     (load_start),
		.load_addr      (load_addr),
		.load_valid     (load_valid),
		.load_data      (load_data),
		.load_end       (load_end),
		.load_wait      (),
		.mapper_ram_size(16'd8192),
		.mapper_init_busy(),
		.arm_ram_en     (),
		.arm_ram_write  (),
		.arm_ram_addr   (),
		.arm_ram_wdata  (),
		.arm_ram_wstrb  (),
		.arm_ram_accepted(1'b0),
		.arm_ram_rdata  (32'd0),
		.ddr_addr       (),
		.ddr_din        (),
		.ddr_be         (),
		.ddr_len        (),
		.ddr_req        (),
		.ddr_rnw        (),
		.ddr_ack        (1'b0),
		.ddr_dout       (64'd0),
		.ddr_rvalid     (1'b0),
		.halt_req       (),
		.cpu_halted     (1'b1),
		.mem_ce         (1'b1),
		.mem_req        (1'b0),
		.mem_ready      (),
		.mem_abort      (),
		.mem_addr       (32'd0),
		.mem_write      (1'b0),
		.mem_wdata      (32'd0),
		.mem_rdata      (),
		.mem_size       (2'd0),
		.mem_wstrb      (4'd0),
		.mem_fetch      (1'b0),
		.state_req      (),
		.state_write    (),
		.state_index    (),
		.state_wdata    (),
		.state_rdata    (32'd0),
		.state_ready    (1'b0),
		.state_commit   (),
		.arm_call_busy  (),
		.arm_dma_busy   (),
		.fa2_nvram_request(),
		.fa2_nvram_write(),
		.fa2_nvram_addr (),
		.fa2_nvram_wdata(),
		.fa2_nvram_rdata(8'd0),
		.fa2_nvram_ready(1'b0),
		.fa2_nvram_dirty(),
		.bus_stuff_valid(bus_stuff_valid),
		.bus_stuff_data (bus_stuff_data),
		.oe             (cart_DB_oe),
		.tape_audio     (),
		.tape_in        (2'd0),
		.fix_sc_cs      (1'b0)
	);

endmodule
