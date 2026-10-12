// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// detect2600: cartridge bank-switching scheme detector. Clean-room design,
// written only from docs/detection-spec.md (section numbers below refer to
// it); no emulator source was consulted.
//
// How it works
// ------------
// The image streams past once (spec 1). Every byte is looked at together
// with the two bytes before it, as a possible 6502 instruction: a 3-byte
// absolute instruction (opcode, low, high) or a 2-byte zero-page one
// (spec 2.2). Matches against each scheme's hotspots or RAM ports bump
// saturating counters; a few bitmaps, blank-window trackers and the last
// bytes (reset vector) are kept too. One clock after load_end the decision
// below is taken from those counters and the image size and registered;
// the outputs then hold until the next load. load_start clears everything.
//
// Opcode classes (spec 2.2 table): "plain absolute" = LDA/LDX/LDY/BIT/CMP/
// STA/STX/STY absolute (AD AE AC 2C CD 8D 8E 8C). Hotspots count only plain
// absolute forms (indexed forms reach A+index: weaker, spec 2.2). RAM ports
// (CV, Superchip) also count indexed forms: stores 8D 8E 8C 9D 99, reads
// AD AE AC 2C CD BD B9 BE BC DD D9. Addresses are taken modulo $2000.
//
// Background counters. Code or data can contain an instruction-shaped byte
// triple by chance. Each weak rule therefore compares its evidence with a
// "background" count: the same pattern aimed at nearby addresses that
// neither the scheme nor its rival default would ever touch, so in a real
// image the background is ~0, while in random-looking data (graphics,
// compressed tables) it is as large or larger than the chance evidence.
// Tuned with a software model of these rules: all test ROMs detect as
// expected; 2K-64K slices of real 6502 code (Klaus Dormann's functional
// tests) and 4K 2600 test programs concatenated to 8K/16K all get the size
// defaults; uniformly random images (the worst case) get the default in
// about 97-100% of cases per size.
//
// Rules (H = plain-absolute hits; distinct = different hotspots hit)
// ------------------------------------------------------------------
//  Unique sizes first (4.1 step 1):
//   <= 2,048    CV if >= 2 stores into $1400-$17FF, >= 1 read of
//               $1000-$13FF, and those stores > 2x the stores into its own
//               ROM $1800-$1FFF (background) (3.11); else 2K (3.1).
//   4,096       4K (BANK00) (3.1).
//   8,195       WD, mapper_revision[0] = 1 (3.15).
//   10,240      P2 (3.22).          12,288     FA, sc = 0 (3.8).
//   24,576 / 28,672                 FA2 (3.19).
//   29,696      FA2 if, past the first 1,024 bytes, H($1FF5-$1FFB) >= 2 and
//               every bank's 512-byte RAM window (offset 1,024 + 4K*n) is
//               one repeated value; else DPCP (3.19, 3.22).
//  8K, in this order (4.1 step 2):
//   WD    >= 2 zero-page reads (A5 A6 A4 24 C5) of $30-$3F each directly
//         followed by JMP (4C) (3.15).
//   UA    H($0220) + H($0240) >= 2 and > H($1FF8/9). Exact low 13 bits only,
//         not the $126F-mask mirrors: counting all mirrors makes chance
//         hits ~30x likelier. Swapped (mapper_revision[0] = 1) when image
//         bank 0 uses $0220 / bank 1 uses $0240 more than the reverse;
//         ties are normal (3.12).
//   0840  H($0800) + H($0840) >= 2 and > H($1FF8/9); exact addresses only,
//         for the same reason (3.17).
//   3E/3F (see below).
//   E0    distinct($1FE0-$1FF7) >= 4 covering >= 2 of the 3 segment
//         groups, H > H($1FF8/9) and H > 2x H($1FC0-$1FDF) (3.7).
//   FC    see 16K.
//   FE    JSR/JMP (20/4C) targets: cF = high byte $F0-$FF, cD = $D0-$DF,
//         both >= 2, neither more than 4x the other, image bank 0 has at
//         least as many $Fx as $Dx targets, cF + cD > 2x the targets
//         elsewhere (background), and H($1FF8/9) < 2 (3.6).
//   else F8.
//  16K: FC; JANE (both $1FF0 and $1FF1 hit, 3.21); E7 (distinct
//   ($1FE0-$1FEB) >= 3 with at least one of $1FE4-$1FEB, none of
//   $1FEC-$1FEF, H > H($1FF6-$1FF9) and > 2x H($1FC0-$1FDF), 3.13); EF;
//   3E/3F; else F6.
//   FC = a store to $1FF8/$1FF9 followed within 16 bytes by an access to
//   $1FFC (3.20). Also applied at 8K and 32K (3.20 allows 4K-32K).
//  32K: FC; EF; 3E/3F; else F4.     64K: EF; 3E/3F; else F0.
//   EF = distinct($1FE0-$1FEF) >= 3, no hotspot for a bank the image does
//   not have (16K: only $1FE0-$1FE3, 32K: $1FE0-$1FE7), H > the default
//   scheme's hits (F6: $1FF6-9, F4: $1FF4-B, F0: $1FF0) and > 2x
//   H($1FC0-$1FDF) (3.16). Applied at 16K/32K/64K.
//  128K / 256K: DF/BF (H($1FC0-$1FDF) at 128K, H($1F80-$1FBF) at 256K)
//   >= 4, > SB hits and > the next-lower range ($1F80-$1FBF resp.
//   $1F00-$1F7F); SB (H with A12=0, A11..A8 = 1000, low byte < $40) >= 4,
//   > DF/BF hits and > the same with low byte >= $40 (3.18, 3.22); 3E/3F;
//   else the size default.
//  Other sizes: 3E/3F if a multiple of 2K and >= 8K, else the size default.
//  3E/3F (3.9, 3.10): zero-page stores (85/86/84) to $3F >= 1, stores to
//   $3E+$3F >= 2 with at least one in the image's last 2K, the reset vector
//   ($1FFC/D, last bytes of the image) points into the fixed $x800-$xFFF
//   half, and those stores outnumber both the whole-bank hotspot hits
//   ($1FF0, $1FF4-$1FFB) and the zero-page stores to the unused TIA
//   addresses $2D-$3D (background). 3E if any $3E store, else 3F (4.1
//   step 3). The image size must be a multiple of 2K.
//  Size defaults (4.1 step 4): <= 2K 2K; up to 4K BANK00; up to 8K F8; up
//   to 16K F6; up to 32K F4; above 32K F0 (sizes over 64K have no larger
//   default, so they take the closest smaller one, F0).
//  Superchip (3.5, 4.1 step 5): in every 4K bank the first 256 bytes are
//   one repeated value, and the code has >= 1 store into $1000-$107F and
//   >= 1 read of $1080-$10FF. Reported only with F8, F6, F4, 4K, EF, DF/BF,
//   UA and JANE.
//
// Unused outputs: mapper_revision[2:1] and all ARM outputs are 0 (spec 1).

typedef enum bit[5:0] {
	BANK00, BANKF8, BANKF6, BANKFE, BANKE0,   BANK3F,   BANKF4,  BANKP2,
	BANKFA, BANKCV, BANK2K, BANKUA, BANKE7,   BANKF0,   BANK32,  BANKAR,
	BANK3E, BANKSB, BANKWD, BANKEF, BANKJANE, BANKDPCP, BANKCTY, BANKCDF,
	BANKBUS, BANKFA2, BANK0840, BANKFC, BANKDF, BANKMC2K, BANKMC4K, BANKMC8K,
	BANKELF, BANKEND
} bss_type;

module detect2600 (
	input             clk,          // 14.318 MHz system clock
	input             load_start,   // one-clock pulse before the first byte
	input      [24:0] load_addr,    // byte address in the image
	input             load_valid,   // one clock per byte
	input             load_end,     // one-clock pulse after the last byte
	input      [31:0] cart_size,    // last load_addr + 1 (final by load_end)
	input       [7:0] data,         // the byte, valid with load_valid
	output reg  [5:0] force_bs,     // detected scheme (bss_type code)
	output reg        sc,           // Superchip RAM present
	output reg  [2:0] mapper_revision,
	output reg        cdf_ldx, cdf_ldy, cdf_fetch_offset_enable,
	output reg  [7:0] cdf_fetch_offset,
	output reg [31:0] cdfj_entry, cdfj_stack,
	output reg [15:0] arm_audio_size_addr
);

	typedef logic [15:0] cnt_t;

	function automatic cnt_t inc(input cnt_t v, input logic en);
		return (en && v != 16'hFFFF) ? v + 16'd1 : v;
	endfunction

	function automatic logic [4:0] popcount(input logic [23:0] v);
		logic [4:0] n;
		n = 5'd0;
		for (int i = 0; i < 24; i++)
			n = n + {4'd0, v[i]};
		return n;
	endfunction

	// a > 2 * b, without overflow
	function automatic logic gt2(input cnt_t a, input cnt_t b);
		return {1'b0, a} > {b, 1'b0};
	endfunction

	//////////////////////////////////////////////////////////////////////
	// Evidence gathered while the image streams past
	//////////////////////////////////////////////////////////////////////

	logic [7:0] b1, b2;         // the previous two bytes (b1 = newest)
	logic [1:0] rv;              // bits 4:3 of the byte before b2

	cnt_t c_f8, c_f6, c_hs, c_f0;           // $1FF8-9, $1FF6-9, $1FF4-B, $1FF0
	cnt_t c_e0, c_ef, c_e7;                 // $1FE0-F7, $1FE0-EF, $1FE0-EB
	cnt_t c_df, c_bf, c_lo;                 // $1FC0-DF, $1F80-BF, $1F00-7F
	logic [23:0] bm;                        // which of $1FE0-$1FF7 were hit
	cnt_t c_fc, c_fa2;
	logic [4:0] fc_win;
	cnt_t c_ua00, c_ua01, c_ua10, c_ua11;   // [bank][0=$0220, 1=$0240]
	cnt_t c_x08, c_sb, c_sbbg;
	cnt_t c_cvw, c_cvr, c_cvbg;
	cnt_t c_scw, c_scr;
	cnt_t c_3f, c_3e, c_3l, c_zpbg;         // c_3l: $3E/$3F stores in this 2K
	cnt_t c_wd;
	cnt_t c_fe0f, c_fe0d, c_fe1f, c_fe1d, c_febg;
	logic       sc_blank, fa_blank;
	logic [7:0] sc_ref, fa_ref;

	// The current byte as the last byte of an instruction.
	logic [4:0] hi;
	logic       op_plain, op_store, op_read, op_zpst, op_zprd, op_jump;
	logic       h1f, h_ua, h_08, cart_lo;
	logic [4:0] bmi;

	always_comb begin
		hi = data[4:0];         // high byte modulo $20 (13-bit address)
		op_plain = b2 == 8'hAD || b2 == 8'hAE || b2 == 8'hAC || b2 == 8'h2C ||
		           b2 == 8'hCD || b2 == 8'h8D || b2 == 8'h8E || b2 == 8'h8C;
		op_store = b2 == 8'h8D || b2 == 8'h8E || b2 == 8'h8C || b2 == 8'h9D ||
		           b2 == 8'h99;
		op_read  = b2 == 8'hAD || b2 == 8'hAE || b2 == 8'hAC || b2 == 8'h2C ||
		           b2 == 8'hCD || b2 == 8'hBD || b2 == 8'hB9 || b2 == 8'hBE ||
		           b2 == 8'hBC || b2 == 8'hDD || b2 == 8'hD9;
		op_jump  = b2 == 8'h20 || b2 == 8'h4C;
		// two-byte forms: opcode in b1, operand in data (or b2/b1 + data)
		op_zpst  = b1 == 8'h85 || b1 == 8'h86 || b1 == 8'h84;
		op_zprd  = b2 == 8'hA5 || b2 == 8'hA6 || b2 == 8'hA4 || b2 == 8'h24 ||
		           b2 == 8'hC5;
		h1f      = op_plain && hi == 5'h1F;              // $1Fxx
		h_ua     = op_plain && hi == 5'h02;              // $02xx
		h_08     = op_plain && hi == 5'h08;              // $08xx
		cart_lo  = b1 < 8'h80;
		bmi      = b1[4:0];                              // $1FE0 + bmi
	end

	logic fin;     // the clock after load_end: take the decision

	always_ff @(posedge clk) begin
		fin <= load_end;
		if (load_start) begin
			{b1, b2, rv} <= '0;
			{c_f8, c_f6, c_hs, c_f0, c_e0, c_ef, c_e7, c_df, c_bf, c_lo} <= '0;
			bm <= '0;
			{c_fc, c_fa2, fc_win} <= '0;
			{c_ua00, c_ua01, c_ua10, c_ua11, c_x08, c_sb, c_sbbg} <= '0;
			{c_cvw, c_cvr, c_cvbg, c_scw, c_scr} <= '0;
			{c_3f, c_3e, c_3l, c_zpbg, c_wd} <= '0;
			{c_fe0f, c_fe0d, c_fe1f, c_fe1d, c_febg} <= '0;
			{sc_blank, fa_blank} <= 2'b11;
			{sc_ref, fa_ref} <= '0;
		end else if (load_valid) begin
			rv <= b2[4:3];
			b2 <= b1;
			b1 <= data;

			// Hotspots on the last cartridge page.
			c_f8 <= inc(c_f8, h1f && (b1 == 8'hF8 || b1 == 8'hF9));
			c_f6 <= inc(c_f6, h1f && b1 >= 8'hF6 && b1 <= 8'hF9);
			c_hs <= inc(c_hs, h1f && b1 >= 8'hF4 && b1 <= 8'hFB);
			c_f0 <= inc(c_f0, h1f && b1 == 8'hF0);
			c_e0 <= inc(c_e0, h1f && b1 >= 8'hE0 && b1 <= 8'hF7);
			c_ef <= inc(c_ef, h1f && b1 >= 8'hE0 && b1 <= 8'hEF);
			c_e7 <= inc(c_e7, h1f && b1 >= 8'hE0 && b1 <= 8'hEB);
			c_df <= inc(c_df, h1f && b1 >= 8'hC0 && b1 <= 8'hDF);
			c_bf <= inc(c_bf, h1f && b1 >= 8'h80 && b1 <= 8'hBF);
			c_lo <= inc(c_lo, h1f && cart_lo);
			if (h1f && b1 >= 8'hE0 && b1 <= 8'hF7)
				bm[bmi] <= 1'b1;

			// FC: store to $1FF8/9, then $1FFC within 16 bytes.
			c_fc <= inc(c_fc, h1f && b1 == 8'hFC && fc_win != 5'd0);
			if (h1f && op_store && (b1 == 8'hF8 || b1 == 8'hF9))
				fc_win <= 5'd16;
			else if (fc_win != 5'd0)
				fc_win <= fc_win - 5'd1;

			// FA2 hotspots past the 1K Harmony header.
			c_fa2 <= inc(c_fa2, h1f && b1 >= 8'hF5 && b1 <= 8'hFB &&
			             |load_addr[24:10]);

			// Hotspots below $1000.
			c_ua00 <= inc(c_ua00, h_ua && b1 == 8'h20 && !load_addr[12]);
			c_ua01 <= inc(c_ua01, h_ua && b1 == 8'h40 && !load_addr[12]);
			c_ua10 <= inc(c_ua10, h_ua && b1 == 8'h20 &&  load_addr[12]);
			c_ua11 <= inc(c_ua11, h_ua && b1 == 8'h40 &&  load_addr[12]);
			c_x08  <= inc(c_x08,  h_08 && (b1 == 8'h00 || b1 == 8'h40));
			c_sb   <= inc(c_sb,   h_08 && b1 <  8'h40);
			c_sbbg <= inc(c_sbbg, h_08 && b1 >= 8'h40);

			// Cartridge RAM ports.
			c_cvw  <= inc(c_cvw,  op_store && hi >= 5'h14 && hi <= 5'h17);
			c_cvr  <= inc(c_cvr,  op_read  && hi >= 5'h10 && hi <= 5'h13);
			c_cvbg <= inc(c_cvbg, op_store && hi >= 5'h18);
			c_scw  <= inc(c_scw,  op_store && hi == 5'h10 && b1 <  8'h80);
			c_scr  <= inc(c_scr,  op_read  && hi == 5'h10 && b1 >= 8'h80);

			// 3E/3F zero-page stores, WD zero-page reads + JMP.
			c_3f   <= inc(c_3f, op_zpst && data == 8'h3F);
			c_3e   <= inc(c_3e, op_zpst && data == 8'h3E);
			c_3l   <= inc(load_addr[10:0] == 11'd0 ? 16'd0 : c_3l,
			              op_zpst && (data == 8'h3E || data == 8'h3F));
			c_zpbg <= inc(c_zpbg, op_zpst && data >= 8'h2D && data <= 8'h3D);
			c_wd   <= inc(c_wd, op_zprd && b1 >= 8'h30 && b1 <= 8'h3F &&
			              data == 8'h4C);

			// FE: JSR/JMP target ranges per 4K image bank.
			c_fe0f <= inc(c_fe0f, op_jump && data >= 8'hF0 && !load_addr[12]);
			c_fe0d <= inc(c_fe0d, op_jump && data[7:4] == 4'hD && !load_addr[12]);
			c_fe1f <= inc(c_fe1f, op_jump && data >= 8'hF0 &&  load_addr[12]);
			c_fe1d <= inc(c_fe1d, op_jump && data[7:4] == 4'hD &&  load_addr[12]);
			c_febg <= inc(c_febg, op_jump && data < 8'hD0 || op_jump && data[7:4] == 4'hE);

			// Blank windows: Superchip (first 256 bytes of each 4K bank) and
			// FA2 Harmony (512 bytes at offset 1K of each 4K step).
			if (load_addr[11:8] == 4'd0) begin
				if (load_addr[7:0] == 8'd0) sc_ref <= data;
				else if (data != sc_ref) sc_blank <= 1'b0;
			end
			if (load_addr[11:9] == 3'b010) begin
				if (load_addr[8:0] == 9'd0) fa_ref <= data;
				else if (data != fa_ref) fa_blank <= 1'b0;
			end
		end
	end

	//////////////////////////////////////////////////////////////////////
	// Decision
	//////////////////////////////////////////////////////////////////////

	bss_type    nbs;
	logic       nrev, sc_ev, scheme_sc;
	logic       x3, is_e0, is_e7, is_jane, is_fc, is_fe, is_ua, is_cv;
	logic       ef16, ef32, ef64;
	logic [4:0] n_ef, n_e7, n_e0;
	logic [16:0] ua_tot, fe_f, fe_d, x3_tot, hs_tot;
	cnt_t       c_dfx, c_dfbg;

	always_comb begin
		sc_ev  = sc_blank && c_scw != 0 && c_scr != 0;

		x3_tot = {1'b0, c_3f} + {1'b0, c_3e};
		hs_tot = {1'b0, c_hs} + {1'b0, c_f0};
		// rv is from the reset vector's high byte ($1FFD) once the load is done.
		x3 = c_3f != 0 && x3_tot >= 17'd2 && c_3l != 0 && rv == 2'b11 &&
		     x3_tot > hs_tot && x3_tot > {1'b0, c_zpbg} &&
		     cart_size[10:0] == 11'd0;

		n_e0 = popcount(bm[23:0]);
		n_ef = popcount({8'd0, bm[15:0]});
		n_e7 = popcount({12'd0, bm[11:0]});
		is_e0 = n_e0 >= 5'd4 &&
		        ((|bm[7:0] && |bm[15:8]) || (|bm[7:0] && |bm[23:16]) ||
		         (|bm[15:8] && |bm[23:16])) &&
		        c_e0 > c_f8 && gt2(c_e0, c_df);
		is_e7 = n_e7 >= 5'd3 && |bm[11:4] && bm[15:12] == 4'd0 &&
		        c_e7 > c_f6 && gt2(c_e7, c_df);
		ef16  = n_ef >= 5'd3 && bm[15:4] == 12'd0 && c_ef > c_f6 && gt2(c_ef, c_df);
		ef32  = n_ef >= 5'd3 && bm[15:8] == 8'd0  && c_ef > c_hs && gt2(c_ef, c_df);
		ef64  = n_ef >= 5'd3 &&                      c_ef > c_f0 && gt2(c_ef, c_df);
		is_jane = bm[16] && bm[17];
		is_fc = c_fc != 0;

		ua_tot = {1'b0, c_ua00} + {1'b0, c_ua01} + {1'b0, c_ua10} + {1'b0, c_ua11};
		is_ua  = ua_tot >= 17'd2 && ua_tot > {1'b0, c_f8};

		fe_f = {1'b0, c_fe0f} + {1'b0, c_fe1f};
		fe_d = {1'b0, c_fe0d} + {1'b0, c_fe1d};
		is_fe = c_f8 < 16'd2 && fe_f >= 17'd2 && fe_d >= 17'd2 &&
		        {fe_d, 2'b00} >= {2'b00, fe_f} && {fe_f, 2'b00} >= {2'b00, fe_d} &&
		        c_fe0f >= c_fe0d && (fe_f + fe_d) > {c_febg, 1'b0};

		is_cv = c_cvw >= 16'd2 && c_cvr != 0 && gt2(c_cvw, c_cvbg);

		// DF at 128K, BF at 256K, each against the next-lower page range.
		c_dfx  = cart_size == 32'd131072 ? c_df : c_bf;
		c_dfbg = cart_size == 32'd131072 ? c_bf : c_lo;

		nrev = 1'b0;
		if (cart_size <= 32'd2048)
			nbs = is_cv ? BANKCV : BANK2K;
		else if (cart_size == 32'd4096)
			nbs = BANK00;
		else if (cart_size == 32'd8195) begin
			nbs = BANKWD;
			nrev = 1'b1;
		end else if (cart_size == 32'd10240)
			nbs = BANKP2;
		else if (cart_size == 32'd12288)
			nbs = BANKFA;
		else if (cart_size == 32'd24576 || cart_size == 32'd28672)
			nbs = BANKFA2;
		else if (cart_size == 32'd29696)
			nbs = (c_fa2 >= 16'd2 && fa_blank) ? BANKFA2 : BANKDPCP;
		else if (cart_size == 32'd8192) begin
			if (c_wd >= 16'd2)
				nbs = BANKWD;
			else if (is_ua) begin
				nbs = BANKUA;
				nrev = {1'b0, c_ua00} + {1'b0, c_ua11} > {1'b0, c_ua01} + {1'b0, c_ua10};
			end else if (c_x08 >= 16'd2 && c_x08 > c_f8)
				nbs = BANK0840;
			else if (x3)
				nbs = c_3e != 0 ? BANK3E : BANK3F;
			else if (is_e0)
				nbs = BANKE0;
			else if (is_fc)
				nbs = BANKFC;
			else if (is_fe)
				nbs = BANKFE;
			else
				nbs = BANKF8;
		end else if (cart_size == 32'd16384) begin
			if (is_fc)        nbs = BANKFC;
			else if (is_jane) nbs = BANKJANE;
			else if (is_e7)   nbs = BANKE7;
			else if (ef16)    nbs = BANKEF;
			else if (x3)      nbs = c_3e != 0 ? BANK3E : BANK3F;
			else              nbs = BANKF6;
		end else if (cart_size == 32'd32768) begin
			if (is_fc)        nbs = BANKFC;
			else if (ef32)    nbs = BANKEF;
			else if (x3)      nbs = c_3e != 0 ? BANK3E : BANK3F;
			else              nbs = BANKF4;
		end else if (cart_size == 32'd65536) begin
			if (ef64)         nbs = BANKEF;
			else if (x3)      nbs = c_3e != 0 ? BANK3E : BANK3F;
			else              nbs = BANKF0;
		end else if (cart_size == 32'd131072 || cart_size == 32'd262144) begin
			if (c_dfx >= 16'd4 && c_dfx > c_sb && c_dfx > c_dfbg)
				nbs = BANKDF;
			else if (c_sb >= 16'd4 && c_sb > c_dfx && c_sb > c_sbbg)
				nbs = BANKSB;
			else if (x3)
				nbs = c_3e != 0 ? BANK3E : BANK3F;
			else
				nbs = BANKF0;
		end else if (x3 && cart_size > 32'd8192)
			nbs = c_3e != 0 ? BANK3E : BANK3F;
		else if (cart_size < 32'd4096)
			nbs = BANK00;
		else if (cart_size < 32'd8192)
			nbs = BANKF8;
		else if (cart_size < 32'd16384)
			nbs = BANKF6;
		else if (cart_size < 32'd32768)
			nbs = BANKF4;
		else
			nbs = BANKF0;

		scheme_sc = nbs == BANKF8 || nbs == BANKF6 || nbs == BANKF4 ||
		            nbs == BANK00 || nbs == BANKEF || nbs == BANKDF ||
		            nbs == BANKUA || nbs == BANKJANE;
	end

	// The decision, held until the next one. Power-up value (FPGA register
	// init) is plain 4K; there is no reset, the next load overwrites it.
	/* verilator lint_off PROCASSINIT */
	bss_type bs_r  = BANK00;
	logic    sc_r  = 1'b0;
	logic    rev_r = 1'b0;
	/* verilator lint_on PROCASSINIT */

	always_ff @(posedge clk) begin
		if (fin) begin
			bs_r  <= nbs;
			sc_r  <= sc_ev && scheme_sc;
			rev_r <= nrev;
		end
	end

	always_comb begin
		force_bs        = bs_r;
		sc              = sc_r;
		mapper_revision = {2'b00, rev_r};
	end

	always_ff @(posedge clk) begin
		// ARM-only outputs: never used by this core.
		cdf_ldx                 <= 1'b0;
		cdf_ldy                 <= 1'b0;
		cdf_fetch_offset_enable <= 1'b0;
		cdf_fetch_offset        <= 8'd0;
		cdfj_entry              <= 32'd0;
		cdfj_stack              <= 32'd0;
		arm_audio_size_addr     <= 16'd0;
	end

endmodule
