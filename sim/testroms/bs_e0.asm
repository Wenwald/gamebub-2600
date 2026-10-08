; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; bs_e0 - bankswitch test for Parker Brothers E0 (8K).
;
; The 8K image is eight 1K slices. The 4K cartridge window is four 1K
; segments: $F000, $F400 and $F800 are switchable, $FC00 always holds slice 7.
; Accessing $1FE0+n selects slice n for segment 0, $1FE8+n for segment 1 and
; $1FF0+n for segment 2. Written from that convention, not from the core.
;
; Slice n holds the byte n at its first address. The program lives in slice 7
; and selects every slice into every switchable segment (24 checks) with
; absolute stores, as the original games do, reading the marker back each
; time.
;
; Result screen (testlib.h): green/red overall, and stripes 0-7 showing the
; slice that answered in segment 0 when slice n was selected (hue = slice).
;
; Build: dasm bs_e0.asm -f3 -obs_e0.a26

	processor 6502
	include "testlib.h"

; Slices 0-6: marker byte, rest blank.
SLICE	SET 0
	REPEAT 7
	ORG SLICE * $400
	.byte SLICE
	ds $3FF, $FF
SLICE	SET SLICE + 1
	REPEND

; Slice 7: the fixed segment at $FC00.
	ORG $1C00
	RORG $FC00
	.byte 7

Start	CLEARSTART

N	SET 0
	REPEAT 24
	sta $1FE0 + N			; slice N%8 into segment N/8
	lda $F000 + [N / 8] * $400	; that segment's marker
	sta RESULT + N
N	SET N + 1
	REPEND

	; Check all 24: RESULT+n must equal n%8.
	lda #PASS
	sta STATUS
	ldx #23
.check	txa
	and #7
	cmp RESULT,x
	beq .ok
	lda #FAIL
	sta STATUS
.ok	dex
	bpl .check

	; Stripes: segment 0 results.
	ldx #7
.band	lda RESULT,x
	BANKHUE
	sta BAND,x
	dex
	bpl .band

	SHOWRESULTS

	ORG $1FFC
	RORG $FFFC
	.word Start
	.word Start
