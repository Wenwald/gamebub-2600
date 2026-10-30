// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// Derived from rtl/Maria/maria.sv and rtl/Maria/control.sv of
// Atari7800_MiSTer: Copyright (c) 2021-2026 Jamie Blanks, MIT License (see
// third_party/atari7800_mister/LICENSE).
//
// What MARIA still does in a 2600 (MEN low, the only state this core uses):
//   - divides the master clock: mclk0/mclk1 at clk_sys/2, and the TIA's clock
//     enable after a short start-up delay;
//   - generates the slow (/6 of mclk) CPU phase pair, which the core uses
//     only until the TIA takes over the CPU clock after reset;
//   - decodes the 2600 memory map into the TIA and RIOT chip selects.
// Everything else (DMA, line RAM, video timing, NMI, HALT, WSYNC/READY, the
// register file and bus driving) is idle with MEN low and is left out. The
// clock process below is maria.sv's, with maria_en = 0 folded in. ce low
// stops every clock, as in maria.sv (upstream's pause).
//
// sim/core checks this cycle by cycle against the real maria module
// (MARIA_LOCKSTEP build).

module maria_2600 (
	input  logic        clk_sys,
	input  logic        ce,
	input  logic [15:0] AB_in,

	output logic        mclk0,
	output logic        mclk1,
	output logic        tia_clk_x2,
	output logic        pclk0,
	output logic        pclk1,

	output logic        cs_riot,
	output logic        cs_tia,

	// Save-state chain: while ss_en, every register shifts one place.
	input  logic        ss_en,
	input  logic        ss_si,
	output logic        ss_so
);

	logic       clk_toggle = 1'b0;
	logic       pclk_toggle = 1'b0;
	logic [2:0] clock_div = 3'd2;
	logic       slow_clk_latch = 1'b0;
	logic [3:0] tia_enable_count = 4'd2;

	// MEN low always selects the slow CPU clock (control.sv sel_slow_clock).
	localparam logic sel_slow_clock = 1'b1;

	initial begin
		mclk0 = 1'b0;
		mclk1 = 1'b0;
		pclk0 = 1'b0;
		pclk1 = 1'b0;
	end

	assign tia_clk_x2 = ~|tia_enable_count && mclk0;

	always_ff @(posedge clk_sys) begin
		mclk1 <= 1'b0;
		mclk0 <= 1'b0;
		pclk0 <= 1'b0;
		pclk1 <= 1'b0;

		if (ce) begin
			if (mclk1 && |tia_enable_count)
				tia_enable_count <= tia_enable_count - 1'd1;

			if (pclk0)
				slow_clk_latch <= sel_slow_clock;

			mclk0 <= clk_toggle;
			mclk1 <= ~clk_toggle;
			clk_toggle <= ~clk_toggle;

			if (mclk1) begin
				if (clock_div != 3'd0)
					clock_div <= clock_div - 1'd1;
				else begin
					pclk_toggle <= ~pclk_toggle;
					pclk1 <= pclk_toggle;
					pclk0 <= ~pclk_toggle;
					clock_div <= (~pclk_toggle ? sel_slow_clock : slow_clk_latch) ? 3'd2 : 3'd1;
				end
			end
		end

		if (ss_en) {ss_so, mclk0, mclk1, pclk0, pclk1, clk_toggle, pclk_toggle, clock_div,
			slow_clk_latch, tia_enable_count} <=
			{mclk0, mclk1, pclk0, pclk1, clk_toggle, pclk_toggle, clock_div,
			slow_clk_latch, tia_enable_count, ss_si};
	end

	// 2600 memory map (control.sv, MEN low): A12 low selects the console;
	// A7 picks the RIOT (high) or the TIA (low).
	assign cs_riot = ~AB_in[12] &  AB_in[7];
	assign cs_tia  = ~AB_in[12] & ~AB_in[7];

endmodule
