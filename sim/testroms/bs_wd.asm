; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; bs_wd - bankswitch test for Wickstead Design WD (8K: eight 1K slices, and
; 64 bytes of RAM). Written from the published description of the scheme
; (the same layout table appears in Stella's CartWD), not from the core:
;
;   Accessing $30-$3F picks one of eight layouts (the low three address
;   bits); it takes effect a few bus cycles later. Each layout puts these
;   slices in the four 1K segments $F000/$F400/$F800/$FC00:
;     0: 0 0 1 3   1: 0 1 2 3   2: 4 5 6 7   3: 7 4 2 3
;     4: 0 0 6 7   5: 0 1 7 6   6: 2 3 4 5   7: 6 0 5 1
;   RAM: read at $F000-$F03F, written at $F040-$F07F.
;
; Every slice holds the same program at the same offset (so execution
; carries on whatever lands in the top segment) and its own number at
; offset $80. Each layout is selected the way WD games do it - LDA from the
; hotspot, then JMP while the switch settles - and the four markers are read.
; Checks, each a bit in ERRORS: 1 = a layout, 2 = the RAM.
;
; Result screen (testlib.h): green/red; stripes are layout 2's four
; segments and then layout 6's (hue = slice: expect 4,5,6,7,2,3,4,5).

	processor 6502
	include "testlib.h"

	MAC SLICE	; {1} = slice number
	SUBROUTINE
	ORG {1} * $400
	RORG $FC00
	ds $80, $FF		; under the RAM when in segment 0
	.byte {1}		; $FC80: the marker
	ds $7F, $FF

	; $FD00
.start	CLEARSTART

	; 2: the RAM.
	ldx #63
.wr	txa
	eor #$A5
	sta $F040,x
	dex
	bpl .wr
	ldx #63
.rd	txa
	eor #$A5
	cmp $F000,x
	beq .rdok
	lda #2
	ora ERRORS
	sta ERRORS
.rdok	dex
	bpl .rd

	; 1: every layout.
C	SET 0
	REPEAT 8
	lda $38 + C		; the hotspot (as games do: LDA $3x : JMP)
	jmp * + 3		; to the next instruction, while it settles
	nop
	nop
	ldx #C * 4
	jsr .grab
C	SET C + 1
	REPEND

	ldx #31
.chk	lda RESULT,x
	cmp .layout,x
	beq .chkok
	lda #1
	ora ERRORS
	sta ERRORS
.chkok	dex
	bpl .chk

	lda #PASS
	ldx ERRORS
	beq .verdict
	lda #FAIL
.verdict
	sta STATUS
	ldx #7
.st	lda RESULT + 8,x	; layouts 2 and 6 are RESULT+8..11 and +24..27
	cpx #4
	bcc .hue
	lda RESULT + 20,x
.hue	BANKHUE
	sta BAND,x
	dex
	bpl .st

	SHOWRESULTS

; Read the four segment markers into RESULT+X .. RESULT+X+3.
.grab	lda $F080
	sta RESULT,x
	lda $F480
	sta RESULT + 1,x
	lda $F880
	sta RESULT + 2,x
	lda $FC80
	sta RESULT + 3,x
	rts

.layout	.byte 0,0,1,3, 0,1,2,3, 4,5,6,7, 7,4,2,3
	.byte 0,0,6,7, 0,1,7,6, 2,3,4,5, 6,0,5,1

	ORG {1} * $400 + $3FC
	RORG $FFFC
	.word .start
	.word .start
	ENDM

S	SET 0
	REPEAT 8
	SLICE S
S	SET S + 1
	REPEND
