; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; bs_f0 - bankswitch test for F0 (64K, sixteen 4K banks).
;
; There is no way to pick a bank directly: every access to $1FF0 moves to the
; next bank, wrapping after the last. Written from that convention, not from
; the core.
;
; Every bank holds the same program and its own number at ID ($FE00). The
; program notes the bank it started in, steps through all sixteen, and checks
; each step landed on the next bank and that sixteen steps come back round.
;
; Result screen (testlib.h): green/red; stripes 0-7 are the banks reached by
; the first eight steps (hue = bank).

	processor 6502
	include "testlib.h"

START	= $F100
ID	= $FE00

	MAC BANKCODE	; {1} = bank number
	SUBROUTINE
	ORG {1}*$1000
	RORG $F000
	.byte {1} + $A0		; not a Superchip image
	ds START - $F001, $FF

	CLEARSTART
	lda ID
	sta TEMP		; the bank we started in
	ldx #0
.step	lda $FFF0
	lda ID
	sta RESULT,x
	inx
	cpx #16
	bne .step

	lda #PASS
	sta STATUS
	ldy TEMP
	ldx #0
.chk	iny
	tya
	and #15
	cmp RESULT,x
	beq .ok
	lda #FAIL
	sta STATUS
.ok	inx
	cpx #16
	bne .chk

	ldx #7
.st	lda RESULT,x
	BANKHUE
	sta BAND,x
	dex
	bpl .st

	SHOWRESULTS

	ORG {1}*$1000 + $E00
	RORG ID
	.byte {1}

	ORG {1}*$1000 + $FFC
	RORG $FFFC
	.word START
	.word START
	ENDM

BANK	SET 0
	REPEAT 16
	BANKCODE BANK
BANK	SET BANK + 1
	REPEND
