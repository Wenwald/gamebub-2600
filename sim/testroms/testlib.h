; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; Shared by the test ROMs: register names, RAM layout and the result screen.
;
; Result screen (NTSC, 192 visible lines):
;   lines   0-63   STATUS colour: green ($C6) = every check passed,
;                  red ($46) = at least one failed
;   lines  64-191  8 stripes of 16 lines, colours from BAND[0..7]
;
; Tests set STATUS and BAND, then invoke SHOWRESULTS, which never returns.

VSYNC	= $00
VBLANK	= $01
WSYNC	= $02
COLUBK	= $09

RESULT	= $80		; up to 64 bytes of raw results
BAND	= $C0		; 8 stripe colours
STATUS	= $C8
ERRORS	= $C9
TEMP	= $CA		; scratch for the tests

PASS	= $C6
FAIL	= $46

; Clear the TIA and RAM, set up the stack. Uses A, X.
	MAC CLEARSTART
	sei
	cld
	ldx #0
	txa
.clear	sta $00,x
	inx
	bne .clear
	dex
	txs
	ENDM

; Stripe colour for a bank number in A: hue = bank, luminance 10 (brighter
; than PASS/FAIL, so a stripe can never be mistaken for the status colour).
	MAC BANKHUE
	asl
	asl
	asl
	asl
	ora #$0A
	ENDM

; The result screen, forever.
	MAC SHOWRESULTS
.frame	lda #2
	sta VSYNC
	sta WSYNC
	sta WSYNC
	sta WSYNC
	lda #0
	sta VSYNC
	lda #2
	sta VBLANK
	ldx #37
.vb	sta WSYNC
	dex
	bne .vb
	lda #0
	sta VBLANK
	lda STATUS
	sta COLUBK
	ldx #64
.top	sta WSYNC
	dex
	bne .top
	ldy #0
.bands	lda BAND,y
	sta COLUBK
	ldx #16
.bl	sta WSYNC
	dex
	bne .bl
	iny
	cpy #8
	bne .bands
	lda #2
	sta VBLANK
	ldx #30
.os	sta WSYNC
	dex
	bne .os
	jmp .frame
	ENDM
