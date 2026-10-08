; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; bs_2k - test for 2K cartridges: the 2K image appears twice in the 4K
; cartridge window, at $F000 and again at $F800. Written from that
; convention, not from the core.
;
; The program runs from the upper copy and compares a 256-byte table through
; both copies, and checks the lower copy holds this very program.
;
; Result screen (testlib.h): green/red; no stripes.

	processor 6502
	include "testlib.h"

	ORG 0
	RORG $F800

Start	CLEARSTART
	lda #PASS
	sta STATUS
	ldx #0
.cmp	lda Table,x		; upper copy
	cmp Table - $800,x	; lower copy
	bne .fail
	txa
	eor #$C3
	cmp Table,x		; and the table is what was assembled
	bne .fail
	inx
	bne .cmp
	lda Start - $800	; the program itself, through the lower copy
	cmp #$78		; SEI, the first byte of CLEARSTART
	beq .done
.fail	lda #FAIL
	sta STATUS
.done	SHOWRESULTS

	ALIGN 256
Table
N	SET 0
	REPEAT 256
	.byte N ^ $C3
N	SET N + 1
	REPEND

	ORG $7FC
	RORG $FFFC
	.word Start
	.word Start
