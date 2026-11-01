// SPDX-License-Identifier: MIT
// Copyright (c) 2019-2026 Jamie Blanks

// module Atari7800 removed by gamebub-2600 (scripts/vendor_upstream.py): not used here

// Accept one complete, source-caused two-phase stream. During a handoff the old
// source runs through a matching target edge, then the target supplies the
// opposite phase. This lets TIA remain externally clocked until the boundary.
module cpu_phase_controller
(
	input  logic clk_sys,
	input  logic request_tia,
	input  logic maria_phi1,
	input  logic maria_phi2,
	input  logic tia_phi1,
	input  logic tia_phi2,
	output logic phi1,
	output logic phi2,
	output logic active_tia,
	output logic edge_source_tia,
	output logic source_stable,
	output logic phase_valid
);

	typedef enum logic [1:0] {
		PRIME,
		RUN,
		WAIT_TARGET_SAME,
		TAKE_TARGET_OPPOSITE
	} phase_state_t;

	phase_state_t state = PRIME;
	logic target_tia = 1'b0;
	logic last_phase2 = 1'b1;
	initial begin
		active_tia = 1'b0;
		phase_valid = 1'b0;
	end

	wire active_phi1 = active_tia ? tia_phi1 : maria_phi1;
	wire active_phi2 = active_tia ? tia_phi2 : maria_phi2;
	wire requested_phi1 = request_tia ? tia_phi1 : maria_phi1;
	wire target_phi1 = target_tia ? tia_phi1 : maria_phi1;
	wire target_phi2 = target_tia ? tia_phi2 : maria_phi2;
	wire target_same = last_phase2 ? target_phi2 : target_phi1;
	wire target_matches_edge = (phi1 && target_phi1) ||
		(phi2 && target_phi2);

	assign source_stable = state == RUN;

	always_comb begin
		phi1 = 1'b0;
		phi2 = 1'b0;
		edge_source_tia = active_tia;

		case (state)
			PRIME: begin
				// Establish a known low/phase-1 level before any phase 2.
				edge_source_tia = request_tia;
				phi1 = requested_phi1;
			end
			RUN: begin
				phi1 = last_phase2 && active_phi1;
				phi2 = !last_phase2 && active_phi2;
			end
			WAIT_TARGET_SAME: begin
				phi1 = last_phase2 && active_phi1;
				phi2 = !last_phase2 && active_phi2;
			end
			TAKE_TARGET_OPPOSITE: begin
				edge_source_tia = target_tia;
				if (request_tia == target_tia) begin
					phi1 = last_phase2 && target_phi1;
					phi2 = !last_phase2 && target_phi2;
				end
			end
			default: begin
			end
		endcase
	end

	always_ff @(posedge clk_sys) begin
		if (phi1) begin
			last_phase2 <= 1'b0;
			phase_valid <= 1'b1;
		end else if (phi2) begin
			last_phase2 <= 1'b1;
			phase_valid <= 1'b1;
		end

		case (state)
			PRIME: begin
				if (phi1) begin
					active_tia <= request_tia;
					state <= RUN;
				end
			end
			RUN: begin
				if (request_tia != active_tia) begin
					target_tia <= request_tia;
					state <= WAIT_TARGET_SAME;
				end
			end
			WAIT_TARGET_SAME: begin
				if (request_tia == active_tia)
					state <= RUN;
				else if (request_tia != target_tia)
					target_tia <= request_tia;
				else if (target_same || target_matches_edge)
					state <= TAKE_TARGET_OPPOSITE;
			end
			TAKE_TARGET_OPPOSITE: begin
				if (request_tia == active_tia)
					state <= RUN;
				else if (request_tia != target_tia) begin
					target_tia <= request_tia;
					state <= WAIT_TARGET_SAME;
				end else if (phi1 || phi2) begin
					active_tia <= target_tia;
					state <= RUN;
				end
			end
		endcase
	end

endmodule

// module ctrl_reg removed by gamebub-2600 (scripts/vendor_upstream.py): not used here

module M6502C
(
	input         pclk1,     // start of phase 1, from MARIA or TIA
	input         pclk0,     // start of phase 2, from MARIA or TIA
	output        phi1_ce,   // pin 3:  the paired phase 1, for the rest of the system
	output        phi2_ce,   // pin 39: the paired phase 2, for the rest of the system
	input         clk_sys,   // MARIA Clock
	input         reset,     // reset signal
	input  [7:0]  DB_IN,     // data in,
	input         IRQ_n,     // interrupt request
	input         NMI_n,     // non-maskable interrupt request
	input         RDY,       // Ready signal. Pauses CPU when RDY=0
	input         halt_n,    // halt!
	output [15:0] AB,        // address bus
	output [7:0]  DB_OUT,    // data_out,
	output        DB_OE,     // 1 while the CPU is driving D7:D0
	output        RD,        // read enable
	output        AB_OE,     // 0 while halted: A0-A15 released
	output        RW_OE,     // 0 while halted: R/W released
	output logic  is_halted  // This is used to indicate that sally has released the bus
);

	// The source controller removes MARIA restart and source-handoff hazards.
	// Keep this local pairing gate as the CPU pin invariant: an unexpected
	// duplicate phase must never advance SALLY or any returned system phase.
	logic in_phase2 = 1'b0;
	wire  phi1_en = pclk1 & ~in_phase2;
	wire  phi2_en = pclk0 &  in_phase2;

	always_ff @(posedge clk_sys) begin
		if      (phi1_en) in_phase2 <= 1'b1;
		else if (phi2_en) in_phase2 <= 1'b0;
	end

	// SALLY pin 39 is the system clock - TIA, RIOT, both cartridge slots and
	// MARIA pin 6 all run off it, not off MARIA's own divider. So the rest of
	// the core gets the same paired phases the CPU acted on, and a dropped
	// pulse is dropped for everyone. Taken before the halt gate: the pins keep
	// running while MARIA owns the bus.
	assign phi1_ce = phi1_en;
	assign phi2_ce = phi2_en;

	// SALLY carries the halt handshake itself: the two phase-2 flip-flops that
	// release the bus, and the stall into the core's own RDY. The wrapper is
	// only a name and a pin adapter.
	sally cpu (
		.clk_sys  (clk_sys),
		.phi1_en  (phi1_en),
		.phi2_en  (phi2_en),

		.res_n    (~reset),
		.rdy      (RDY),
		.irq_n    (IRQ_n),
		.nmi_n    (NMI_n),
		.so_n     (1'b1),
		.data_in  (RD ? DB_IN : DB_OUT),
		.data_out (DB_OUT),
		.data_oe  (DB_OE),
		.addr_out (AB),
		.rw_n     (RD),
		.sync     (),
		.phi1_out (),
		.phi2_out (),

		.halt_n   (halt_n),
		.addr_oe  (AB_OE),
		.rw_oe    (RW_OE),
		.is_halted(is_halted),
		.jammed   (),

		.dbg_a (), .dbg_x (), .dbg_y (), .dbg_s (),
		.dbg_p (), .dbg_ir(), .dbg_pc()
	);

endmodule: M6502C
