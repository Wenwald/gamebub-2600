; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; bs_e7 - bankswitch test for M-Network E7 (16K: eight 2K slices, plus 2K
; of RAM). Written from the published convention, not from the core:
;
;   $F000-$F7FF  slice 0-6, selected by accessing $FFE0-$FFE6; or, after
;                $FFE7, 1K of RAM: written at $F000-$F3FF, read at $F400-$F7FF
;   $F800-$F9FF  one of four 256-byte RAM banks, selected by $FFE8-$FFEB:
;                written at $F800-$F8FF, read at $F900-$F9FF
;   $FA00-$FFFF  always the last 1.5K of slice 7
;
; Slice n holds the byte n at its first address. The program lives in the
; fixed area. Checks, each a bit in ERRORS:
;   1  each of slices 0-6 appears in the low window when selected
;   2  the 1K RAM holds a full pattern
;   4  selecting a ROM slice hides the 1K RAM, and selecting it again finds
;      the pattern still there
;   8  the four 256-byte banks are independent
;
; Result screen (testlib.h): green/red; stripes 0-6 are the slices that
; answered (hue = slice), stripe 7 is black.

	processor 6502
	include "testlib.h"

; Slices 0-6: marker, rest blank.
S	SET 0
	REPEAT 7
	ORG S * $800
	.byte S
	ds $7FF, $FF
S	SET S + 1
	REPEND

; Slice 7: its first 512 bytes sit under the 256-byte RAM banks and are never
; seen; the fixed area starts at $FA00.
	ORG $3800
	.byte 7
	ds $1FF, $FF
	RORG $FA00

Start	CLEARSTART

	; 1: slices. Absolute loads, as M-Network games use.
	lda $FFE0
	lda $F000
	sta RESULT + 0
	lda $FFE1
	lda $F000
	sta RESULT + 1
	lda $FFE2
	lda $F000
	sta RESULT + 2
	lda $FFE3
	lda $F000
	sta RESULT + 3
	lda $FFE4
	lda $F000
	sta RESULT + 4
	lda $FFE5
	lda $F000
	sta RESULT + 5
	lda $FFE6
	lda $F000
	sta RESULT + 6
	ldx #6
.s1	txa
	cmp RESULT,x
	beq .s1ok
	lda #1
	ora ERRORS
	sta ERRORS
.s1ok	dex
	bpl .s1

	; 2: the 1K RAM, all four pages.
	lda $FFE7
	ldy #0
.w2	tya
	sta $F000,y
	eor #$FF
	sta $F100,y
	tya
	eor #$3C
	sta $F200,y
	eor #$FF
	sta $F300,y
	iny
	bne .w2
	jsr Check1K
	beq .ok2
	lda #2
	ora ERRORS
	sta ERRORS
.ok2

	; 4: a ROM slice hides it; selecting the RAM again finds it intact.
	lda $FFE3
	lda $F000
	cmp #3
	bne .bad4
	lda $FFE7
	jsr Check1K
	beq .ok4
.bad4	lda #4
	ora ERRORS
	sta ERRORS
.ok4

	; 8: the four 256-byte banks, each written with its own pattern, then
	; all read back.
	lda $FFE8
	ldx #$00
	jsr Fill256
	lda $FFE9
	ldx #$11
	jsr Fill256
	lda $FFEA
	ldx #$22
	jsr Fill256
	lda $FFEB
	ldx #$33
	jsr Fill256
	lda $FFE8
	ldx #$00
	jsr Check256
	lda $FFE9
	ldx #$11
	jsr Check256
	lda $FFEA
	ldx #$22
	jsr Check256
	lda $FFEB
	ldx #$33
	jsr Check256

	lda #PASS
	ldx ERRORS
	beq .verdict
	lda #FAIL
.verdict
	sta STATUS
	ldx #6
.st	lda RESULT,x
	BANKHUE
	sta BAND,x
	dex
	bpl .st

	SHOWRESULTS

; Z set if the 1K RAM holds the pattern written in check 2.
Check1K	SUBROUTINE
	ldy #0
.rd	tya
	cmp $F400,y
	bne .done
	eor #$FF
	cmp $F500,y
	bne .done
	tya
	eor #$3C
	cmp $F600,y
	bne .done
	eor #$FF
	cmp $F700,y
	bne .done
	iny
	bne .rd
.done	rts

; Fill the selected 256-byte bank with index XOR X.
Fill256	SUBROUTINE
	stx TEMP
	ldy #0
.wr	tya
	eor TEMP
	sta $F800,y
	iny
	bne .wr
	rts

; Check the selected 256-byte bank against index XOR X; error bit 8.
Check256 SUBROUTINE
	stx TEMP
	ldy #0
.rd	tya
	eor TEMP
	cmp $F900,y
	bne .bad
	iny
	bne .rd
	rts
.bad	lda #8
	ora ERRORS
	sta ERRORS
	rts

	ORG $3FFC
	RORG $FFFC
	.word Start
	.word Start
