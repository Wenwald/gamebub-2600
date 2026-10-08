; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; tone.a26 - TIA audio test ROM (4K, no bankswitching, NTSC).
;
; Plays a fixed sequence, one phase after another, with a background colour
; per phase so captured frames show where it is:
;
;   phase  frames  colour  sound
;   0      120     blue    channel 0 pure tone: AUDC0=4, AUDF0=17, AUDV0=8
;                          (3579545 / 114 / 18 / 2 = 872.2 Hz)
;   1      128     green   same tone, AUDF0 sweeps 0..31 (4 frames per step)
;   2       64     red     same tone, AUDV0 fades 15..0 (4 frames per step)
;   3       60     yellow  channel 0 off, channel 1 noise: AUDC1=8, AUDF1=4, AUDV1=6
;   4      hold    black   silence
;
; Build: dasm tone.asm -f3 -otone.a26

	processor 6502

; TIA write registers
VSYNC	= $00
VBLANK	= $01
WSYNC	= $02
COLUBK	= $09
AUDC0	= $15
AUDC1	= $16
AUDF0	= $17
AUDF1	= $18
AUDV0	= $19
AUDV1	= $1A

; RAM
tick	= $80		; frames into the current phase
phase	= $81

TONE_F	= 17
TONE_V	= 8

	seg code
	org $F000

Start	sei
	cld
	ldx #0
	txa
.clear	sta $00,x	; TIA registers and RAM
	inx
	bne .clear
	dex		; X = $FF
	txs

Frame	lda #2		; 3 lines of VSYNC
	sta VSYNC
	sta WSYNC
	sta WSYNC
	sta WSYNC
	lda #0
	sta VSYNC

	lda #2		; 37 lines of VBLANK, sound update in the first
	sta VBLANK
	jsr Sound
	ldx #37
.vb	sta WSYNC
	dex
	bne .vb

	lda #0		; 192 visible lines of background colour
	sta VBLANK
	ldx phase
	lda Colours,x
	sta COLUBK
	ldx #192
.vis	sta WSYNC
	dex
	bne .vis

	lda #2		; 30 lines of overscan
	sta VBLANK
	ldx #30
.os	sta WSYNC
	dex
	bne .os
	jmp Frame

; Advance the frame counter, then set the TIA audio registers for the phase.
; Each register is written once, with its final value: the TIA samples the
; audio registers about twice per scanline, so a default written and then
; overwritten a few cycles later is audible as a click every frame.
Sound	ldx phase
	cpx #4
	beq .apply	; last phase holds forever
	inc tick
	lda tick
	cmp Lengths,x
	bne .apply
	lda #0
	sta tick
	inc phase

.apply	lda tick
	lsr
	lsr
	tay		; Y = tick / 4
	ldx phase
	beq .tone
	dex
	beq .sweep
	dex
	beq .fade
	dex
	beq .noise
	lda #0		; 4: silence
	sta AUDV0
	sta AUDV1
	rts

.tone	lda #TONE_F	; 0: steady tone
	bne .ch0	; always taken (TONE_F != 0)
.sweep	tya		; 1: AUDF0 = tick / 4
.ch0	sta AUDF0
	lda #TONE_V
.vol0	sta AUDV0
	lda #4
	sta AUDC0
	lda #0
	sta AUDV1
	rts

.fade	lda #TONE_F	; 2: AUDV0 = 15 - tick / 4
	sta AUDF0
	tya
	eor #$0F
	bpl .vol0	; always taken (0..15)

.noise	lda #0		; 3: channel 0 off, channel 1 noise
	sta AUDV0
	lda #8
	sta AUDC1
	lda #4
	sta AUDF1
	lda #6
	sta AUDV1
	rts

Lengths	.byte 120, 128, 64, 60
Colours	.byte $86, $C6, $46, $1E, $00

	org $FFFC
	.word Start	; RESET
	.word Start	; IRQ/BRK
