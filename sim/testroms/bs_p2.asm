; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; bs_p2 - test for P2, the DPC chip (8K of program in two F8
; banks, plus 2K of display data the 6507 can only reach through the DPC).
; Written from the published description of the DPC, not from the core:
;
;   $FFF8 / $FFF9 select program bank 0 / 1, as F8.
;   Eight data fetchers, n = 0-7. Writes: $F040+n top, $F048+n bottom,
;   $F050+n counter low, $F058+n counter high (low 3 bits). Reads:
;   $F008+n returns display data byte (2047 - counter), then the counter
;   counts down; $F038+n returns the fetcher's flag, which goes to $FF when
;   the counter's low byte equals top and to $00 when it equals bottom.
;
; Display data byte j is (j & $FF) here, so a fetcher starting at counter c
; reads (2047 - c) & $FF, then one more each read.
;
; Checks, each a bit in ERRORS:
;   1  both program banks select (each reads its own ID)
;   2  fetcher 0 streams display data from counter $123: $DC, $DD, $DE
;   4  fetcher 1's flag is $FF once its counter has passed top
;   8  fetcher 1 streams its own data: fetcher 0 reads in between do not
;      move it
;
; Result screen (testlib.h): green/red; stripes 0-1 are the program banks
; that answered (hue = bank).

	processor 6502
	include "testlib.h"

START	= $F100
ID	= $FE00

	MAC BANKCODE	; {1} = bank number
	SUBROUTINE
	ORG {1}*$1000
	RORG $F000
	ds START - $F000, $FF	; DPC registers live at $F000-$F07F

	CLEARSTART

	; 1: program banks.
	lda $FFF9
	lda ID
	sta RESULT + 1
	lda $FFF8
	lda ID
	sta RESULT + 0
	cmp #0
	bne .bad1
	lda RESULT + 1
	cmp #1
	beq .ok1
.bad1	lda #1
	sta ERRORS

.ok1	; 2: fetcher 0 from $123.
	lda #$23
	sta $F050
	lda #$01
	sta $F058
	; 4/8: fetcher 1 from $022, top $20, bottom $10.
	lda #$20
	sta $F041
	lda #$10
	sta $F049
	lda #$22
	sta $F051
	lda #$00
	sta $F059

	lda $F008		; fetcher 0: $DC
	sta RESULT + 8
	lda $F009		; fetcher 1, counter $22: (2047 - $22) & $FF = $DD
	sta RESULT + 12
	lda $F008		; $DD
	sta RESULT + 9
	lda $F009		; counter $21: $DE
	sta RESULT + 13
	lda $F008		; $DE
	sta RESULT + 10
	lda $F009		; counter $20 = top: $DF, and the flag goes up
	sta RESULT + 14
	lda $F039		; fetcher 1's flag
	sta RESULT + 16

	ldx #2
.c2	txa
	clc
	adc #$DC
	cmp RESULT + 8,x
	beq .c2ok
	lda #2
	ora ERRORS
	sta ERRORS
.c2ok	dex
	bpl .c2

	lda RESULT + 16
	cmp #$FF
	beq .c4ok
	lda #4
	ora ERRORS
	sta ERRORS
.c4ok
	ldx #2
.c8	txa
	clc
	adc #$DD
	cmp RESULT + 12,x
	beq .c8ok
	lda #8
	ora ERRORS
	sta ERRORS
.c8ok	dex
	bpl .c8

	lda #PASS
	ldx ERRORS
	beq .verdict
	lda #FAIL
.verdict
	sta STATUS
	lda RESULT + 0
	BANKHUE
	sta BAND + 0
	lda RESULT + 1
	BANKHUE
	sta BAND + 1

	SHOWRESULTS

	ORG {1}*$1000 + $E00
	RORG ID
	.byte {1}

	ORG {1}*$1000 + $FFC
	RORG $FFFC
	.word START
	.word START
	ENDM

	BANKCODE 0
	BANKCODE 1

; 2K of display data.
	ORG $2000
J	SET 0
	REPEAT 2048
	.byte J & $FF
J	SET J + 1
	REPEND
