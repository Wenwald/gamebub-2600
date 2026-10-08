; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; bs_3f - bankswitch test for Tigervision 3F (8K here: four 2K banks).
;
; The 4K cartridge window is two 2K halves: $F000-$F7FF shows the bank last
; written to address $3F (a TIA address, so the cartridge snoops the write),
; and $F800-$FFFF always shows the last bank. Written from that convention,
; not from the core.
;
; Bank n holds the byte n at its first address. The program lives in the
; last bank and selects each bank with STA $3F, reading the marker back.
;
; Result screen (testlib.h): green/red overall, stripes 0-3 showing the bank
; that answered when bank n was selected (hue = bank).
;
; Build: dasm bs_3f.asm -f3 -obs_3f.a26

	processor 6502
	include "testlib.h"

BANKS	= 4

; Banks 0-2: marker byte, rest blank.
B	SET 0
	REPEAT BANKS - 1
	ORG B * $800
	.byte B
	ds $7FF, $FF
B	SET B + 1
	REPEND

; Last bank: fixed at $F800.
	ORG [BANKS - 1] * $800
	RORG $F800
	.byte BANKS - 1

Start	CLEARSTART		; note: this also writes 0 to $3F

	ldx #BANKS - 1
.sel	txa
	sta $3F			; as the original games do
	lda $F000
	sta RESULT,x
	dex
	bpl .sel
	lda #0			; back to bank 0. Detection also needs this: it
	sta $3F			; only calls an image 3F with two or more STA $3F

	lda #PASS
	sta STATUS
	ldx #7
.check	lda #0
	cpx #BANKS
	bcs .setb
	txa
	cmp RESULT,x
	beq .ok
	lda #FAIL
	sta STATUS
.ok	lda RESULT,x
	BANKHUE
.setb	sta BAND,x
	dex
	bpl .check

	SHOWRESULTS

	ORG [BANKS - 1] * $800 + $7FC
	RORG $FFFC
	.word Start
	.word Start
