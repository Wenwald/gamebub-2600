; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; savestate.a26 - a picture that is different in every frame (4K, NTSC), for
; the save-state checks (sim/suite.py --gamebub, `savestate`).
;
; A 16-bit frame counter, counted once per frame from 0 at power-on, is drawn
; over all 192 lines: high byte as PF1, low byte as PF2 (playfield bits),
; with the background hue from the low byte. So no two frames in 65536 look
; alike, and a loaded state either carries on with the very frame after the
; saved one or shows it plainly. The frame is timed with the RIOT timer
; (TIM64T / INTIM), as games time theirs.
;
; With SC=1 (ss_sc.a26) the counter lives in Superchip RAM (write $F000,
; read $F080) instead of RIOT RAM, and $F000-$F0FF is left blank, as 4K
; Superchip images are, so detection picks Superchip RAM.
;
; Build: dasm savestate.asm -f3 -osavestate.a26 [-DSC=1]

	processor 6502
	include "testlib.h"

	IFNCONST SC
SC	= 0
	ENDIF

COLUPF	= $08
CTRLPF	= $0A
PF1	= $0E
PF2	= $0F
INTIM	= $0284
TIM64T	= $0296

	IF SC
CNTW	= $F000		; counter, low byte first: write port
CNTR	= $F080		; read port
	ELSE
CNTW	= TEMP
CNTR	= TEMP
	ENDIF

	seg code
	org $F000
	IF SC
	ds 256, 0	; the RAM window, blank
	ENDIF

Start	CLEARSTART
	lda #0
	sta CNTW
	sta CNTW+1
	sta CTRLPF
	lda #$0E
	sta COLUPF

Frame	lda #2
	sta VBLANK
	sta VSYNC
	sta WSYNC
	sta WSYNC
	sta WSYNC
	lda #0
	sta VSYNC
	lda #43		; 37 lines of vertical blank
	sta TIM64T

	clc		; count the frame
	lda CNTR
	adc #1
	sta CNTW
	lda CNTR+1
	adc #0
	sta CNTW+1

	lda CNTR+1
	sta PF1
	lda CNTR
	sta PF2
	and #$F0
	ora #$04
	sta COLUBK

.vb	lda INTIM
	bne .vb
	sta WSYNC
	lda #0
	sta VBLANK
	ldx #192
.vis	sta WSYNC
	dex
	bne .vis
	lda #2
	sta VBLANK
	lda #35		; 30 lines of overscan
	sta TIM64T
.os	lda INTIM
	bne .os
	sta WSYNC
	jmp Frame

	IF SC
	org $FFFA
	.byte "SC"	; as 4K Superchip images carry
	ELSE
	org $FFFC
	ENDIF
	.word Start	; RESET
	.word Start	; IRQ/BRK
