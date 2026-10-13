; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; switches.a26 - shows the console switches and a frame counter (4K, NTSC),
; for the pause-behind-the-menu checks (sim/suite.py --gamebub, `menu`).
;
; Every frame reads SWCHB during VBLANK, counts the frame and draws one
; colour over all 192 lines:
;
;   hue (bits 7-4)        SWCHB bit 7 (right difficulty), bit 6 (left
;                         difficulty), bit 3 (TV type: 1 = colour), bit 0
;                         (Game Reset, active low)
;   luminance (bits 3-1)  frame counter mod 8, starting from 0 at power-on
;                         (the first drawn frame shows 1)
;
; So one pixel per frame tells what the game read and whether it has run
; exactly one frame since the last one shown.
;
; Build: dasm switches.asm -f3 -oswitches.a26

	processor 6502
	include "testlib.h"

SWCHB	= $0282
SWBCNT	= $0283

COUNT	= TEMP		; frames drawn
SHOWN	= TEMP+1	; colour of this frame

	seg code
	org $F000

Start	CLEARSTART
	lda #0
	sta SWBCNT	; port B all inputs

Frame	lda #2
	sta VBLANK
	sta VSYNC
	sta WSYNC
	sta WSYNC
	sta WSYNC
	lda #0
	sta VSYNC

	inc COUNT
	lda SWCHB	; hue = {b7, b6, b3, b0}
	and #$C0
	sta SHOWN
	lda SWCHB
	and #$08
	asl
	asl
	ora SHOWN
	sta SHOWN
	lda SWCHB
	and #$01
	asl
	asl
	asl
	asl
	ora SHOWN
	sta SHOWN
	lda COUNT	; luminance = COUNT mod 8
	and #$07
	asl
	ora SHOWN
	sta SHOWN

	ldx #37
.vb	sta WSYNC
	dex
	bne .vb
	lda #0
	sta VBLANK
	lda SHOWN
	sta COLUBK
	ldx #192
.vis	sta WSYNC
	dex
	bne .vis
	lda #2
	sta VBLANK
	ldx #30
.os	sta WSYNC
	dex
	bne .os
	jmp Frame

	org $FFFC
	.word Start	; RESET
	.word Start	; IRQ/BRK
