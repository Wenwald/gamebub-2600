; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; bs_fc - bankswitch test for FC, the Amiga Power Play Arcade scheme (here
; 16K: four 4K banks). Written from the published convention, not from the
; core: the next bank is written in two parts - its low two bits to $FFF8,
; the rest to $FFF9 - and an access to $FFFC then switches to it.
;
; Every bank holds the same program and its own number at ID ($FE00). Each
; bank is selected the way the Power Play software does it (STA $FFF8,
; STY $FFF9, LDA $FFFC) and its ID read back.
;
; Result screen (testlib.h): green/red; stripes 0-3 are the banks that
; answered (hue = bank).

	processor 6502
	include "testlib.h"

BANKS	= 4
START	= $F100
ID	= $FE00

	MAC BANKCODE	; {1} = bank number
	SUBROUTINE
	ORG {1}*$1000
	RORG $F000
	.byte {1} + $A0
	ds START - $F001, $FF

	CLEARSTART
N	SET BANKS - 1
	REPEAT BANKS
	lda #N & 3
	sta $FFF8
	ldy #N >> 2
	sty $FFF9
	lda $FFFC
	lda ID
	sta RESULT + N
N	SET N - 1
	REPEND

	lda #PASS
	sta STATUS
	ldx #BANKS - 1
.ev	txa
	cmp RESULT,x
	beq .ok
	lda #FAIL
	sta STATUS
.ok	dex
	bpl .ev
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

	ORG {1}*$1000 + $E00
	RORG ID
	.byte {1}

	ORG {1}*$1000 + $FFC
	RORG $FFFC
	.word START
	.word START
	ENDM

BANK	SET 0
	REPEAT BANKS
	BANKCODE BANK
BANK	SET BANK + 1
	REPEND
