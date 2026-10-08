// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// Clocks for the Game Bub core, from the board's 50 MHz input. Keep the VCO
// and dividers in step with chisel/src/atari2600/HandheldAtari2600.scala,
// which reports the resulting frequencies to the framework.
//
//   VCO      50 MHz / 5 * 60.125   = 601.25 MHz
//   system   VCO / 42               = 14.315 MHz (2600 NTSC master clock, 0.02% slow)
//   display  VCO / DISPLAY_DIVIDER   (framework range; 23 -> 26.14 MHz on rev4)
//   SPI      VCO / 3.25             = 185.0 MHz (framework requires > 160 MHz)
//
// SPI was VCO / 3 = 200.4 MHz at first, but the framework's SPI receiver
// then missed timing by 0.105 ns (Vivado 2026.1, first build). The
// firmware writes at <= 40 MHz and reads at <= 16 MHz over SPI, and the
// receiver needs 4x / 10x that (SpiReceiverFifo.scala), so 185 MHz keeps
// 4.6x / 11.6x. A fractional divider only exists on CLKOUT0, so SPI is
// CLKOUT0 and the system clock CLKOUT2.

`default_nettype none

module atari2600_mmcm #(
	parameter int DISPLAY_DIVIDER = 23
) (
	input  wire logic clk_in_50mhz,
	output wire logic clk_sys,
	output wire logic clk_display,
	output wire logic clk_spi,
	output wire logic locked
);

	logic clk_fb;

	MMCME2_BASE #(
		.BANDWIDTH          ("OPTIMIZED"),
		.CLKIN1_PERIOD      (20.000),
		.DIVCLK_DIVIDE      (5),
		.CLKFBOUT_MULT_F    (60.125),
		.CLKOUT0_DIVIDE_F   (3.250),
		.CLKOUT1_DIVIDE     (DISPLAY_DIVIDER),
		.CLKOUT2_DIVIDE     (42),
		.CLKOUT0_PHASE      (0.0),
		.CLKOUT1_PHASE      (0.0),
		.CLKOUT2_PHASE      (0.0),
		.CLKFBOUT_PHASE     (0.0),
		.CLKOUT0_DUTY_CYCLE (0.5),
		.CLKOUT1_DUTY_CYCLE (0.5),
		.CLKOUT2_DUTY_CYCLE (0.5),
		.STARTUP_WAIT       ("FALSE")
	) mmcm_inst (
		.CLKOUT0   (clk_spi),
		.CLKOUT0B  (),
		.CLKOUT1   (clk_display),
		.CLKOUT1B  (),
		.CLKOUT2   (clk_sys),
		.CLKOUT2B  (),
		.CLKOUT3   (),
		.CLKOUT3B  (),
		.CLKOUT4   (),
		.CLKOUT5   (),
		.CLKOUT6   (),
		.CLKFBOUT  (clk_fb),
		.CLKFBOUTB (),
		.CLKFBIN   (clk_fb),
		.LOCKED    (locked),
		.CLKIN1    (clk_in_50mhz),
		.PWRDWN    (1'b0),
		.RST       (1'b0)
	);

endmodule

`default_nettype wire
