; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; bs_cv - test for CommaVid CV: a 2K ROM at $F800-$FFFF and 1K of RAM below
; it, read at $F000-$F3FF and written at $F400-$F7FF. Written from that
; convention, not from the core.
;
; The program fills all 1K through the write port (STA $F400,Y, as CommaVid
; games do) with a pattern that differs per page, then reads it all back.
;
; Result screen (testlib.h): green/red; no stripes.

	processor 6502
	include "testlib.h"

	ORG 0
	RORG $F800

Start	CLEARSTART

	ldy #0
.wr	tya
	sta $F400,y
	eor #$FF
	sta $F500,y
	tya
	eor #$55
	sta $F600,y
	eor #$FF
	sta $F700,y
	iny
	bne .wr

	lda #PASS
	sta STATUS
	ldy #0
.rd	tya
	cmp $F000,y
	bne .fail
	eor #$FF
	cmp $F100,y
	bne .fail
	tya
	eor #$55
	cmp $F200,y
	bne .fail
	eor #$FF
	cmp $F300,y
	bne .fail
	iny
	bne .rd
	beq .done
.fail	lda #FAIL
	sta STATUS
.done	SHOWRESULTS

	ORG $7FC
	RORG $FFFC
	.word Start
	.word Start
