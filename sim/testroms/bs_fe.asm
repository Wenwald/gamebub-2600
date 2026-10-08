; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; bs_fe - bankswitch test for Activision FE (8K, two 4K banks).
;
; There is no hotspot. The cartridge watches for an access to $01FE and
; takes the bank from bit 5 of the byte on the bus in the cycle after it:
; set (an address in $Fxxx) picks bank 0, clear ($Dxxx) picks bank 1. With
; the stack pointer at $FF, JSR pushes the return address low byte to $01FE
; and then fetches the target's high byte, and RTS pulls from $01FE then
; $01FF, the return address's high byte - so calls and returns carry the
; bank with them. Bank 0 is assembled at $F000 and bank 1 at $D000.
; Written from that convention, not from the core.
;
; Checks, each a bit in ERRORS:
;   1  bank 0 is in place when the test starts
;   2  JSR into $Dxxx runs bank 1 (it reads its own ID)
;   4  RTS back to $Fxxx is in bank 0 again
;   8  a second round trip behaves the same
;
; Both banks start with the same stub at $x100, which reaches bank 0's test
; through a JSR to $F2xx, so the console can power up in either bank.
;
; Result screen (testlib.h): green/red; stripes 0-3 are the IDs read at the
; four checks (hue = bank: expect 0, 1, 0, 1).

	processor 6502
	include "testlib.h"

; ---- bank 0, at $F000 --------------------------------------------------
	ORG $0000
	RORG $F000
	.byte $A0
	ds $FF, $FF

Stub0	sei			; $F100: the same bytes as Stub1
	ldx #$FF
	txs
	jsr Test		; target high byte $F2: bank 0

	ORG $0200
	RORG $F200
Test	CLEARSTART		; also resets the stack to $FF

	lda $FE00
	sta RESULT + 0		; 1: bank 0 at the start
	jsr InBank1		; 2: runs in bank 1, stores RESULT + 1
	lda $FE00
	sta RESULT + 2		; 4: back in bank 0
	jsr InBank1		; 8: again
	lda $FE00
	sta RESULT + 4
	lda RESULT + 3		; second bank 1 result
	sta TEMP

	lda #PASS
	sta STATUS
	lda RESULT + 0
	ora RESULT + 2
	ora RESULT + 4
	bne .fail		; bank 0 reads must all be 0
	lda RESULT + 1
	cmp #1
	bne .fail
	lda TEMP
	cmp #1
	beq .stripes
.fail	lda #FAIL
	sta STATUS
.stripes
	lda RESULT + 0
	BANKHUE
	sta BAND + 0
	lda RESULT + 1
	BANKHUE
	sta BAND + 1
	lda RESULT + 2
	BANKHUE
	sta BAND + 2
	lda RESULT + 3
	BANKHUE
	sta BAND + 3

	SHOWRESULTS

	ORG $0E00
	RORG $FE00
	.byte 0

	ORG $0FFC
	RORG $FFFC
	.word $F100
	.word $F100

; ---- bank 1, at $D000 --------------------------------------------------
	ORG $1000
	RORG $D000
	.byte $A1
	ds $FF, $FF

Stub1	sei			; $D100, run as $F100 after a power-up here
	ldx #$FF
	txs
	jsr $F200		; target high byte $F2: bank 0

	ORG $1300
	RORG $D300
InBank1	lda $DE00		; this bank's ID
	ldx RESULT + 1		; first call fills RESULT + 1, second RESULT + 3
	beq .first
	sta RESULT + 3
	rts
.first	sta RESULT + 1
	rts

	ORG $1E00
	RORG $DE00
	.byte 1

	ORG $1FFC
	RORG $DFFC
	.word $F100
	.word $F100
