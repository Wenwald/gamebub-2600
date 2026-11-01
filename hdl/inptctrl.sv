// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// inptctrl: the Atari 7800 INPTCTRL register. Written from the
// hardware description in the Atari 7800 Software Guide,
// section "INPTCTRL REGISTER ($01)"; no other implementation was consulted.
//
// The register is write-only and mapped at $0000-$001F, on top of the TIA,
// so it shares the TIA's chip select. Four bits:
//   bit 0  Lock     1 = further writes are ignored until power cycle
//   bit 1  MARIA    1 = MARIA and system RAM on
//   bit 2  EXT      0 = BIOS at $8000-$FFFF, 1 = BIOS off / cartridge on
//   bit 3  TIA-EN   1 = TIA video (and no 2-button joystick mode)
// HALT to the 6502 is blocked after power-up until the register has been
// written twice (the data does not matter); write_count counts those writes.
//
// The lock itself is applied outside: the core drives write_n with
// RW | lock, so a locked register sees no further write strobes.
//
// In this 2600 core the 7800 BIOS never runs. With bypass_bios set the
// register starts in the state the BIOS leaves behind: in 2600 mode
// (tia_mode) locked with TIA video on and MARIA off, otherwise MARIA on and
// unlocked; the BIOS is switched off and both writes counted either way.
//
// Save state: the eight bits {ss_so, lock, maria_en, ext, tia_en, configured,
// write_count} form one stretch of the core's ss_si/ss_so chain. The order is
// part of the save-file format.

module inptctrl (
	input  logic       clk,           // system clock
	input  logic       pclk0,         // CPU phase-2 clock enable
	input  logic [3:0] data,          // CPU write data, bits 3..0
	input  logic       cs,            // chip select (shared with the TIA)
	input  logic       write_n,       // write strobe, active low (RW | lock)
	input  logic       reset,         // synchronous reset, active high
	input  logic       bypass_bios,   // start in the post-BIOS state
	input  logic       tia_mode,      // 1 = 2600 mode
	input  logic       ss_en,         // save-state shift enable
	input  logic       ss_si,         // save-state chain in
	output logic       lock,          // bit 0
	output logic       maria_en,      // bit 1
	output logic       ext,           // bit 2 (EXT, 1 = cartridge on)
	output logic       tia_en,        // bit 3
	output logic [1:0] write_count,   // register writes so far, max 2
	output logic       ss_so          // save-state chain out
);

	// Power-up values (FPGA register init).
	/* verilator lint_off PROCASSINIT */
	logic       lock_r       = 1'b0;
	logic       maria_r      = 1'b0;
	logic       ext_r        = 1'b0;
	logic       tia_r        = 1'b0;
	logic       configured   = 1'b0;   // set by the bypass or a CPU write
	logic [1:0] writes_r     = 2'd0;
	logic       ss_so_r      = 1'b0;
	/* verilator lint_on PROCASSINIT */

	always_ff @(posedge clk) begin
		if (reset) begin
			{tia_r, ext_r, maria_r, lock_r} <= 4'd0;
			configured <= 1'b0;
			writes_r   <= 2'd0;
		end else if (bypass_bios && !configured) begin
			// What the BIOS would have left.
			lock_r     <= tia_mode;
			maria_r    <= !tia_mode;
			ext_r      <= 1'b1;
			tia_r      <= tia_mode;
			configured <= 1'b1;
			writes_r   <= 2'd2;
		end else if (!write_n && cs && pclk0) begin
			// CPU write.
			configured <= 1'b1;
			{tia_r, ext_r, maria_r, lock_r} <= data[3:0];
			if (writes_r < 2'd2)
				writes_r <= writes_r + 2'd1;
		end

		// Save-state chain; last, so it overrides everything above.
		if (ss_en)
			{ss_so_r, lock_r, maria_r, ext_r, tia_r, configured, writes_r[1], writes_r[0]} <=
				{lock_r, maria_r, ext_r, tia_r, configured, writes_r[1], writes_r[0], ss_si};
	end

	always_comb begin
		lock        = lock_r;
		maria_en    = maria_r;
		ext         = ext_r;
		tia_en      = tia_r;
		write_count = writes_r;
		ss_so       = ss_so_r;
	end

endmodule
