; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Mark Schlosser
;
; bs_fx - bankswitch test for the schemes where the whole 4K cartridge window
; is one switchable 4K bank, selected by touching a hotspot address. Built
; many ways from this one source (see the Makefile):
;
;   BANKS   number of 4K banks in the image
;   FIRST   first bank a hotspot can select (default 0; CTY's bank 0 is the
;           Harmony driver, which the 6507 never sees)
;   HOT     hotspot of bank FIRST; bank n is at HOT + (n - FIRST) * STRIDE
;   STRIDE  hotspot spacing (default 1)
;   JANE    1 = JANE's hotspots instead: $FFF0, $FFF1, $FFF8, $FFF9,
;           touched from small `LDA hotspot : RTS` subroutines at SELS, the
;           way the scheme's game switches banks
;   TAIL    1 = DF/BF: name the scheme in bytes $FFF8-$FFFB of every bank
;           ("DFDF", "DFSC", "BFBF" or "BFSC"), as DF/BF images do
;   SC4K    1 = a 4K Superchip image: "SC" at $FFFA, as such images carry
;   RAM     cartridge RAM, shared by every bank (default 0):
;             128  Superchip      write $F000-$F07F, read $F080-$F0FF
;             256  CBS RAM+ / FA2 write $F000-$F0FF, read $F100-$F1FF
;              64  CTY            write $F004-$F03F, read $F044-$F07F
;                                 (the low four of each port are registers)
;
; Written from the published descriptions of these schemes, not from the
; core's mapper code. Every bank holds the same program, so execution carries
; on at the next instruction whatever bank a hotspot selects, and the console
; can power up in any bank. Each bank stores its own number at ID ($FE00).
; Hotspots are touched with absolute loads, as the original games do (some
; detection signatures look for exactly that).
;
; At boot the program selects each bank in turn (highest first) and reads ID
; back; with RAM it also fills the RAM, switches to bank FIRST and reads it
; back. Result screen (testlib.h): green/red overall; stripe n is the hue of
; the bank that answered when bank n was selected (hue = bank number), so a
; correct ROM shows hues 0,1,2... in order. Stripes past the 8th are only in
; the overall verdict; stripes for banks that cannot be selected are black.

	processor 6502
	include "testlib.h"

	IFNCONST FIRST
FIRST	= 0
	ENDIF
	IFNCONST STRIDE
STRIDE	= 1
	ENDIF
	IFNCONST JANE
JANE	= 0
	ENDIF
	IFNCONST RAM
RAM	= 0
	ENDIF
	IFNCONST TAIL
TAIL	= 0
	ENDIF
	IFNCONST SC4K
SC4K	= 0
	ENDIF
SELS	= $FD00		; JANE bank-select subroutines, 4 bytes each

	IF RAM == 128
RAMRD	= $80
RAMLO	= 0
	ENDIF
	IF RAM == 256
RAMRD	= $100
RAMLO	= 0
	ENDIF
	IF RAM == 64
RAMRD	= $40
RAMLO	= 4
	ENDIF

	IF RAM == 256
START	= $F200
	ELSE
START	= $F100
	ENDIF
ID	= $FE00

	MAC BANKCODE	; {1} = bank number
	SUBROUTINE
	ORG {1}*$1000
	RORG $F000

	; The RAM window. Blank when the scheme has RAM (a blank Superchip
	; window is how detection recognises one); otherwise made non-blank.
	IF RAM
	ds START - $F000, 0
	ELSE
	.byte {1} + $A0
	ds START - $F001, $FF
	ENDIF

	CLEARSTART

	; Select each bank, read its ID back.
N	SET BANKS - 1
	REPEAT BANKS - FIRST
	IF JANE
	jsr SELS + N * 4
	ELSE
	lda HOT + [N - FIRST] * STRIDE
	ENDIF
	lda ID
	sta RESULT + N
N	SET N - 1
	REPEND

	IF RAM
	; Fill the RAM through the write port, switch to bank FIRST, read it
	; back through the read port.
	ldx #RAM - 1
.wr	txa
	eor #$5A
	sta $F000,x
	dex
	cpx #[RAMLO - 1] & $FF
	bne .wr
	IF JANE
	lda $FFF0
	ELSE
	lda HOT
	ENDIF
	ldx #RAM - 1
.rd	txa
	eor #$5A
	cmp $F000 + RAMRD,x
	beq .rdok
	inc ERRORS
.rdok	dex
	cpx #[RAMLO - 1] & $FF
	bne .rd
	ENDIF

	; Verdict over every selectable bank, and the RAM.
	lda #PASS
	sta STATUS
	ldx #BANKS - 1
.ev	txa
	cmp RESULT,x
	beq .evok
	lda #FAIL
	sta STATUS
.evok	dex
	cpx #[FIRST - 1] & $FF
	bne .ev
	lda ERRORS
	beq .stripes
	lda #FAIL
	sta STATUS

	; Stripes for banks 0-7.
.stripes
	ldx #7
.st	lda #0
	cpx #BANKS
	bcs .setb
	cpx #FIRST
	bcc .setb
	lda RESULT,x
	BANKHUE
.setb	sta BAND,x
	dex
	bpl .st

	SHOWRESULTS

	IF JANE
	ORG {1}*$1000 + [SELS - $F000]
	RORG SELS
	lda $FFF0
	rts
	lda $FFF1
	rts
	lda $FFF8
	rts
	lda $FFF9
	rts
	ENDIF

	ORG {1}*$1000 + $E00
	RORG ID
	.byte {1}

	IF SC4K
	ORG {1}*$1000 + $FFA
	RORG $FFFA
	.byte "SC"
	ENDIF

	IF TAIL
	ORG {1}*$1000 + $FF8
	RORG $FFF8
	IF BANKS == 32
	.byte "DF"
	ELSE
	.byte "BF"
	ENDIF
	IF RAM == 128
	.byte "SC"
	ELSE
	IF BANKS == 32
	.byte "DF"
	ELSE
	.byte "BF"
	ENDIF
	ENDIF
	ENDIF

	ORG {1}*$1000 + $FFC
	RORG $FFFC
	.word START	; RESET
	.word START	; IRQ/BRK
	ENDM

BANK	SET 0
	REPEAT BANKS
	BANKCODE BANK
BANK	SET BANK + 1
	REPEND
