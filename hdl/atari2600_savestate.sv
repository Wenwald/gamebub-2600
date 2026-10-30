// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// Shape of a save state of hdl/atari2600_core.sv (its header describes the
// protocol): CHAIN_BITS register bits on the ss_si/ss_so chain and MEM_BYTES
// of memory behind ss_mem_*. sim/core checks CHAIN_BITS against the chain
// itself (tb_core --ss-measure) on every suite run.

package atari2600_savestate;

	localparam int CHAIN_BITS = 3365;   // tb_core --ss-measure (the suite checks it)

	// Memory, by ss_mem_addr.
	localparam logic [15:0] MEM_CRAM  = 16'h0000;  // 32 KB cartridge RAM
	localparam logic [15:0] MEM_RIOT  = 16'h8000;  // 128 bytes RIOT RAM
	localparam logic [15:0] MEM_FA2   = 16'h8100;  // 256 bytes FA2 work RAM
	localparam int          MEM_BYTES = 'h8200;

	// Clocks to wait with pause high before and after an operation.
	localparam int SETTLE = 16;

endpackage
