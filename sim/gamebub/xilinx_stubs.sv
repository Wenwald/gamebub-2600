// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// Simulation stand-ins for the Xilinx primitives the Game Bub wrapper uses.
// The testbench runs everything from one clock, so the MMCM passes its input
// straight through to every output and reports lock at once. Never part of
// the FPGA build (Vivado supplies the real primitives).

module MMCME2_BASE #(
	parameter string BANDWIDTH          = "OPTIMIZED",
	parameter real   CLKIN1_PERIOD      = 0.0,
	parameter int    DIVCLK_DIVIDE      = 1,
	parameter real   CLKFBOUT_MULT_F    = 5.0,
	parameter real   CLKFBOUT_PHASE     = 0.0,
	parameter real   CLKOUT0_DIVIDE_F   = 1.0,
	parameter int    CLKOUT1_DIVIDE     = 1,
	parameter int    CLKOUT2_DIVIDE     = 1,
	parameter real   CLKOUT0_PHASE      = 0.0,
	parameter real   CLKOUT1_PHASE      = 0.0,
	parameter real   CLKOUT2_PHASE      = 0.0,
	parameter real   CLKOUT0_DUTY_CYCLE = 0.5,
	parameter real   CLKOUT1_DUTY_CYCLE = 0.5,
	parameter real   CLKOUT2_DUTY_CYCLE = 0.5,
	parameter string STARTUP_WAIT       = "FALSE"
) (
	output logic CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B,
	output logic CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6,
	output logic CLKFBOUT, CLKFBOUTB,
	output logic LOCKED,
	input  logic CLKIN1, CLKFBIN, PWRDWN, RST
);
	assign {CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKOUT6, CLKFBOUT} = {8{CLKIN1}};
	assign {CLKOUT0B, CLKOUT1B, CLKOUT2B, CLKOUT3B, CLKFBOUTB} = {5{~CLKIN1}};
	assign LOCKED = 1'b1;
endmodule
