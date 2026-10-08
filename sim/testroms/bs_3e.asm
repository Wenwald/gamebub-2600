; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; bs_3e - bankswitch test for 3E (Tigervision 3F plus RAM). Here 8K of ROM
; (four 2K banks) and four 1K RAM banks. Written from the published
; convention, not from the core:
;
;   $F000-$F7FF  the ROM bank last written to $3F, or the 1K RAM bank last
;                written to $3E: read at $F000-$F3FF, written at $F400-$F7FF
;   $F800-$FFFF  always the last ROM bank
;
; ROM bank n holds the byte n at its first address. Checks, each a bit in
; ERRORS:
;   1  each ROM bank appears when selected
;   2  each RAM bank holds its own pattern (all four written, then read)
;   4  selecting a ROM bank again replaces the RAM
;
; Result screen (testlib.h): green/red; stripes 0-3 are the ROM banks that
; answered (hue = bank).

	processor 6502
	include "testlib.h"

BANKS	= 4

B	SET 0
	REPEAT BANKS - 1
	ORG B * $800
	.byte B
	ds $7FF, $FF
B	SET B + 1
	REPEND

	ORG [BANKS - 1] * $800
	RORG $F800
	.byte BANKS - 1

Start	CLEARSTART

	; 1: ROM banks.
	ldx #BANKS - 1
.rom	txa
	sta $3F
	lda $F000
	sta RESULT,x
	dex
	bpl .rom
	ldx #BANKS - 1
.c1	txa
	cmp RESULT,x
	beq .c1ok
	lda #1
	ora ERRORS
	sta ERRORS
.c1ok	dex
	bpl .c1

	; 2: RAM banks 0-3, 256 bytes each (index XOR bank * $11).
	ldx #3
.wbank	txa
	sta $3E
	stx TEMP		; TEMP = bank * $11
	asl
	asl
	asl
	asl
	ora TEMP
	sta TEMP
	ldy #0
.w	tya
	eor TEMP
	sta $F400,y
	iny
	bne .w
	dex
	bpl .wbank

	ldx #3
.rbank	txa
	sta $3E
	stx TEMP
	asl
	asl
	asl
	asl
	ora TEMP
	sta TEMP
	ldy #0
.r	tya
	eor TEMP
	cmp $F000,y
	bne .bad2
	iny
	bne .r
	beq .next
.bad2	lda #2
	ora ERRORS
	sta ERRORS
.next	dex
	bpl .rbank

	; 4: back to ROM bank 1.
	lda #1
	sta $3F
	lda $F000
	cmp #1
	beq .ok4
	lda #4
	ora ERRORS
	sta ERRORS
.ok4

	lda #PASS
	ldx ERRORS
	beq .verdict
	lda #FAIL
.verdict
	sta STATUS
	ldx #7
.st	lda #0
	cpx #BANKS
	bcs .setb
	lda RESULT,x
	BANKHUE
.setb	sta BAND,x
	dex
	bpl .st

	SHOWRESULTS

	ORG [BANKS - 1] * $800 + $7FC
	RORG $FFFC
	.word Start
	.word Start
