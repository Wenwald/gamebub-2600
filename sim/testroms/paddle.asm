; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; paddle.a26 - left-port paddle test ROM (4K, NTSC). Built in variants by
; the Makefile; the symbols are the expected results:
;
;   ALO, AHI   paddle A (INPT0): lines read uncharged, inclusive range
;   BLO, BHI   paddle B (INPT1): same
;   SW         expected SWCHA & $F0 (paddle A button = bit 7, B = bit 6;
;              $F0 = neither pressed)
;   MEAS       frames to run before checking (default 30)
;
; Each frame dumps the pots (VBLANK bit 7) through VSYNC and VBLANK, then
; releases them at the first visible line and reads INPT0 and INPT1 once per
; line for 192 lines, counting the lines on which each still reads 0
; (uncharged). A paddle charges in a time that grows with its position, so
; the count is the game-visible paddle value, 0..192, the way paddle games
; measure it. The emulation (upstream's paddle_timer) calibrates itself on
; these reads during the first frames.
;
; After MEAS frames the last frame's counts are checked, together with the
; buttons (SWCHA) and the joystick fire (INPT4 bit 7 must read 1: released,
; since nothing drives it in paddle mode), and the result screen is shown:
; green if everything matched. Bands 0-3 hold the raw values for diagnosis
; (count A, count B, SWCHA, INPT4) as colour bytes.
;
; Build: dasm paddle.asm -f3 -DALO=0 -DAHI=8 ... -opaddle.a26

	processor 6502
	include "testlib.h"

INPT0	= $08
INPT1	= $09
INPT4	= $0C
SWCHA	= $0280
SWACNT	= $0281

	IFNCONST MEAS
MEAS	= 30
	ENDIF

FRAMES	= TEMP		; frames left
CNTA	= TEMP+1
CNTB	= TEMP+2
SAWSW	= TEMP+3
SAWF	= TEMP+4

	seg code
	org $F000

Start	CLEARSTART
	lda #0
	sta SWACNT	; port A all inputs
	lda #MEAS
	sta FRAMES

Frame	lda #$82	; dump the pots, blank
	sta VBLANK
	lda #2
	sta VSYNC
	sta WSYNC
	sta WSYNC
	sta WSYNC
	lda #0
	sta VSYNC
	ldx #37
.vb	sta WSYNC
	dex
	bne .vb

	lda #0
	sta CNTA
	sta CNTB
	sta WSYNC
	sta VBLANK	; release the pots: they start charging
	ldx #192
.line	bit INPT0
	bmi .a_done
	inc CNTA
.a_done	bit INPT1
	bmi .b_done
	inc CNTB
.b_done	sta WSYNC
	dex
	bne .line

	lda SWCHA
	and #$F0
	sta SAWSW
	lda INPT4
	sta SAWF

	lda #$82	; overscan, pots dumped again
	sta VBLANK
	ldx #29
.os	sta WSYNC
	dex
	bne .os

	dec FRAMES
	beq Check
	jmp Frame

Check	lda CNTA
	sta BAND
	lda CNTB
	sta BAND+1
	lda SAWSW
	sta BAND+2
	lda SAWF
	sta BAND+3
	lda #PASS
	sta STATUS
	lda CNTA
	cmp #ALO
	bcc .fail
	cmp #AHI+1
	bcs .fail
	lda CNTB
	cmp #BLO
	bcc .fail
	cmp #BHI+1
	bcs .fail
	lda SAWSW
	cmp #SW
	bne .fail
	bit SAWF
	bmi .show
.fail	lda #FAIL
	sta STATUS
.show	SHOWRESULTS

	org $FFFC
	.word Start	; RESET
	.word Start	; IRQ/BRK
