; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; bs_mc - multicart test: GAMES games of GSIZE bytes each, packed back to
; back. Every console reset (power cycle) moves to the next game. Built as:
;
;   GSIZE 2048  2K games, mirrored in the 4K window (MC2K; with 32 games,
;               the Atari 32-in-1 "32" scheme)
;   GSIZE 4096  4K games (MC4K)
;   GSIZE 8192  8K games, each two F8 banks (MC8K)
;
; Written from that convention, not from the core. A game cannot know which
; reset it is on, so each game simply fills the status band with its own
; colour, hue (game & 7) - the same colours the bankswitch tests' stripes
; use - and the suite checks the sequence across resets. 8K games also check
; their own F8 switching and show red if it fails.

	processor 6502
	include "testlib.h"

	IF GSIZE == 2048
WINDOW	= $F800
	ELSE
WINDOW	= $F000
	ENDIF

	MAC GAME	; {1} = game number, {2} = bank within the game
	SUBROUTINE
	ORG {1} * GSIZE + {2} * $1000
	RORG WINDOW
	.byte {1}, {2}
	ds $FE, $FF

.start	CLEARSTART
	IF GSIZE == 8192
	lda $FFF9		; F8 inside the game: bank 1 then 0
	lda WINDOW + 1
	sta RESULT + 1
	lda $FFF8
	lda WINDOW + 1
	sta RESULT + 0
	ENDIF
	lda #[[[{1} & 7] << 4] | $0A]
	IF GSIZE == 8192
	ldx RESULT + 0
	bne .bad
	ldx RESULT + 1
	cpx #1
	beq .good
.bad	lda #FAIL
.good
	ENDIF
	sta STATUS
	SHOWRESULTS

	ORG [{1} * GSIZE] + [{2} * $1000] + [[$FFFC - WINDOW] & $FFF]
	RORG $FFFC
	.word .start
	.word .start
	ENDM

G	SET 0
	REPEAT GAMES
	GAME G, 0
	IF GSIZE == 8192
	GAME G, 1
	ENDIF
G	SET G + 1
	REPEND
