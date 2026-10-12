// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// Differential test top: our detector (hdl/detect2600.sv) and upstream's
// (old_detect2600, renamed at build time from ref/, see Makefile) watch the
// same load stream. tb_detect.cpp reads both results after load_end.

module detect_diff (
	input  logic        clk,
	input  logic        load_start,
	input  logic [24:0] load_addr,
	input  logic        load_valid,
	input  logic        load_end,
	input  logic  [7:0] data,
	output logic  [5:0] new_bs,
	output logic        new_sc,
	output logic  [2:0] new_rev,
	output logic  [5:0] old_bs,
	output logic        old_sc,
	output logic  [2:0] old_rev
);
	// As hdl/atari2600_core.sv computes it.
	logic [31:0] cart_size = 32'd4096;
	always_ff @(posedge clk)
		if (load_valid) cart_size <= {7'd0, load_addr} + 32'd1;

	detect2600 new_det (
		.clk(clk), .load_start(load_start), .load_addr(load_addr),
		.load_valid(load_valid), .load_end(load_end), .cart_size(cart_size),
		.data(data), .force_bs(new_bs), .sc(new_sc), .mapper_revision(new_rev),
		.cdf_ldx(), .cdf_ldy(), .cdf_fetch_offset_enable(), .cdf_fetch_offset(),
		.cdfj_entry(), .cdfj_stack(), .arm_audio_size_addr()
	);

	old_detect2600 old_det (
		.clk(clk), .load_start(load_start), .load_addr(load_addr),
		.load_valid(load_valid), .load_end(load_end), .cart_size(cart_size),
		.data(data), .force_bs(old_bs), .sc(old_sc), .mapper_revision(old_rev),
		.cdf_ldx(), .cdf_ldy(), .cdf_fetch_offset_enable(), .cdf_fetch_offset(),
		.cdfj_entry(), .cdfj_stack(), .arm_audio_size_addr()
	);
endmodule
