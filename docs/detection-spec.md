<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) 2026 Mark Schlosser -->

# Cartridge scheme detection: specification

This is the specification for `hdl/detect2600.sv`, the module that picks a
cartridge's bank-switching scheme from its ROM image. The detector is written
**only from this document**.
The document describes how each cartridge's hardware behaves and what a ROM
image for it contains. It does not describe how any emulator decides.

Every fact carries a source tag; the sources are listed at the end. Facts
tagged **[R]** are reasoning from the facts above them (6502 behaviour,
address decoding), written for this document.

## 1. Interface

The module replaces upstream's detector in place, so its name, ports and
scheme codes are fixed by the code around it [U-cart, GB-core].

```
module detect2600 (
    input             clk,          // 14.318 MHz system clock
    input             load_start,   // one-clock pulse before the first byte
    input      [24:0] load_addr,    // byte address in the image
    input             load_valid,   // one clock per byte
    input             load_end,     // one-clock pulse after the last byte
    input      [31:0] cart_size,    // last load_addr + 1 (final by load_end)
    input       [7:0] data,         // the byte, valid with load_valid
    output reg  [5:0] force_bs,     // detected scheme (bss_type code)
    output reg        sc,           // Superchip RAM present
    output reg  [2:0] mapper_revision,
    output reg        cdf_ldx, cdf_ldy, cdf_fetch_offset_enable,
    output reg  [7:0] cdf_fetch_offset,
    output reg [31:0] cdfj_entry, cdfj_stack,
    output reg [15:0] arm_audio_size_addr
);
```

- **Byte stream.** The image arrives once, in address order from 0, one byte
  per `load_valid`. Bytes may come on consecutive clocks or with any gap
  between them. The detector sees each byte once and cannot read the image
  again afterwards: everything it needs must be gathered while the bytes
  stream past [GB-core].
- **Timing.** `force_bs`, `sc` and `mapper_revision` must hold their final
  values from the clock after `load_end` until the next `load_start`. The
  console is held in reset during and after the load, so a few clocks of
  extra latency after `load_end` are harmless, but the design must not need
  more than 16 [GB-core].
- **Sizes.** Images are 1 byte to 64 KB on the Game Bub (larger ones are
  refused before they run) and up to 512 KB in the core simulation [GB-core].
- **Scheme codes.** The file declares this enum before the module, with
  exactly these names in this order (the names are used by `cart2600.sv`
  and `banks2600.sv`; the numbers by the menu and the test suite)
  [U-cart, GB-core]:

  ```
  typedef enum bit[5:0] {
      BANK00, BANKF8, BANKF6, BANKFE, BANKE0,   BANK3F,   BANKF4,  BANKP2,
      BANKFA, BANKCV, BANK2K, BANKUA, BANKE7,   BANKF0,   BANK32,  BANKAR,
      BANK3E, BANKSB, BANKWD, BANKEF, BANKJANE, BANKDPCP, BANKCTY, BANKCDF,
      BANKBUS, BANKFA2, BANK0840, BANKFC, BANKDF, BANKMC2K, BANKMC4K, BANKMC8K,
      BANKELF, BANKEND
  } bss_type;
  ```

  `BANK00` is a plain 4K cartridge. `BANKDF` covers both DF and BF (the image
  size tells the mapper which) [U-banks].
- **`mapper_revision`.** Only bit 0 is used by the non-ARM schemes: it
  selects the swapped image layouts of UA and WD (sections 3.12 and 3.15).
  Bits 2:1 and all `cdf_*`, `cdfj_*` and `arm_audio_size_addr` outputs are
  driven to 0: they belong to ARM schemes, which this core does not run
  [U-cart, GB-core].
- **`sc`** is only meaningful with the schemes that have a Superchip
  variant (section 3.5); it is 0 otherwise.

## 2. Background facts

### 2.1 How a cartridge sees an access

- The cartridge port has 13 address lines, A0-A12. A12 high selects the
  cartridge (`$1000-$1FFF`); with A12 low the access goes to the TIA, RIOT
  RAM or RIOT I/O. A cartridge can still watch every address on the bus,
  which is how schemes like 3F, UA and 0840 switch on addresses below
  `$1000` [H12, H97].
- The CPU's three top address lines are not connected, so a program may
  refer to `$1FF8` as `$1FF8`, `$3FF8`, ..., `$FFF8`; most programs use
  `$Fxxx` or `$Dxxx` [H12 FE, R].
- Hotspots react to **any** access, read or write, unless a section says
  otherwise. Programs usually touch them with `LDA`, `BIT` or a store [H12 F8].
- Cartridge RAM has separate write and read address ranges because the
  port has no read/write line [H97].

### 2.2 6502 instruction encodings

Standard MOS 6502 encodings [6502]. An *absolute* instruction is three
bytes: opcode, address low byte, address high byte. A *zero-page*
instruction is two bytes: opcode, address (`$00-$FF`).

| Instruction | Absolute | Zero page | Absolute,X | Absolute,Y |
|---|---|---|---|---|
| LDA | `AD` | `A5` | `BD` | `B9` |
| LDX | `AE` | `A6` | - | `BE` |
| LDY | `AC` | `A4` | `BC` | - |
| BIT | `2C` | `24` | - | - |
| CMP | `CD` | `C5` | `DD` | `D9` |
| STA | `8D` | `85` | `9D` | `99` |
| STX | `8E` | `86` | - | - |
| STY | `8C` | `84` | - | - |
| JMP | `4C` | - | - | - |
| JSR | `20` | - | - | - |
| RTS | `60` (one byte) | | | |

**[R]** An *access to address A* in the image means an absolute
instruction (any row above, absolute or indexed column) whose 16-bit
operand, taken modulo `$2000`, equals A. For addresses below `$100` the
zero-page form counts too. An indexed form reaches A plus the index
register, so it is weaker evidence for A itself.

### 2.3 How images are laid out

- A ROM image stores the cartridge's banks in order: bank 0 first, the last
  bank last [H12, U-banks].
- **[R]** At power-on the CPU reads its reset vector at `$1FFC-$1FFD`. In
  schemes with a fixed top area (E0, 3F, 3E, E7, P2's program banks aside)
  that area is the end of the image, so the image's last bytes hold the
  reset vector. In whole-4K schemes (F8, F6, F4, FA, EF, ...) the bank at
  power-on is not guaranteed, so programs usually place a small start-up
  stub and vectors in every bank [H12 F8, R].
- **[R]** Bytes a program never reads (unused space, or a RAM window that
  hides the ROM under it) are usually filled with one repeated value by the
  assembler or EPROM programmer.

## 3. Schemes

Each entry gives: sizes, hotspots, evidence in the image, conflicts, and
the fallback. Sizes are exact byte counts.

### 3.1 2K (`BANK2K`) and 4K (`BANK00`)

- **Sizes.** 2K: 2,048 bytes; it appears twice in the 4K window. 4K: 4,096
  bytes. Neither switches banks [H12, H97, T-2k].
- **Evidence.** The size alone.
- **Conflicts.** CV is also a 2K image (3.11). A 4K image may carry a
  Superchip (3.5).
- **Fallback.** Any image of 2,048 bytes or less: `BANK2K`. Exactly 4,096
  bytes: `BANK00`.

### 3.2 F8 (`BANKF8`)

- **Sizes.** 8,192 bytes: two 4K banks [H12, H97].
- **Hotspots.** Any access to `$1FF8` selects bank 0, `$1FF9` bank 1 [H12].
- **Evidence.** Accesses to `$1FF8`/`$1FF9` in the code [H12, R].
- **Conflicts.** Every other 8K scheme: FE, E0, 3F, 3E, UA, 0840 and WD
  (sections below). F8 is the common 8K scheme [H97], so it is the 8K
  fallback.
- **Fallback.** 8K images with no evidence for another 8K scheme: `BANKF8`.

### 3.3 F6 (`BANKF6`)

- **Sizes.** 16,384 bytes: four 4K banks [H12, H97].
- **Hotspots.** `$1FF6-$1FF9` select banks 0-3 [H12, H97].
- **Conflicts.** Other 16K schemes: E7, FC, JANE, 3F/3E (multiples of 2K),
  EF (16K form), MC2K multicart (manual only).
- **Fallback.** 16K images with no evidence for another 16K scheme:
  `BANKF6`.

### 3.4 F4 (`BANKF4`)

- **Sizes.** 32,768 bytes: eight 4K banks [H12, H97].
- **Hotspots.** `$1FF4-$1FFB` select banks 0-7 [H12, H97].
- **Conflicts.** Other 32K schemes: FA2 (32K Harmony form, 3.19), FC, EF,
  3F/3E, CTY and MC4K (manual only).
- **Fallback.** 32K images with no evidence for another 32K scheme:
  `BANKF4`.

### 3.5 Superchip RAM (`sc`)

- **What it is.** A 128-byte RAM in the first 256 bytes of the cartridge
  window: written at `$1000-$107F`, read at `$1080-$10FF`. It is added to
  F8, F6 and F4 cartridges ("F8+SC", "F4+SC") [H97], and the mappers here
  also accept it with 4K, EF, DF/BF, UA and JANE images [U-banks, T-fx].
- **Evidence.** **[R]** Reads of `$1000-$10FF` return RAM, never the ROM
  below it, so in every 4K bank of the image the first 256 bytes are never
  executed or read as data: they are filled with one repeated value. The
  program's code writes into `$1000-$107F` (stores, absolute or indexed)
  and reads from `$1080-$10FF`. Our Superchip test images follow this
  layout and fill those bytes with one value in every bank [T-fx].
- **Conflicts.** A game without the chip may also leave the start of its
  banks unused, so the blank window alone is weak evidence; requiring it in
  **every** bank, and/or code accesses to the two ports, makes it stronger
  **[R]**. FA and FA2 have a 256-byte RAM in the first 512 bytes (3.8,
  3.19): for those schemes the RAM is part of the scheme and `sc` stays 0.
  CTY's RAM is likewise part of the scheme.
- **Fallback.** `sc` = 0.

### 3.6 FE (`BANKFE`)

- **Sizes.** 8,192 bytes: two 4K banks [H12, H97].
- **Hotspots.** None in ROM. The cartridge watches stack accesses at
  `$01FE`/`$01FF` during `JSR` and `RTS` and takes the new bank from data
  bit 5 of the fetched return/target high byte: code for one bank lives at
  `$Fxxx`, for the other at `$Dxxx` [H12, H97, T-fe].
- **Evidence.** **[R]** The two banks are assembled for different address
  ranges: bank 0's absolute `JSR`/`JMP` targets inside its own bank have
  high bytes `$F0-$FF`, bank 1's `$D0-$DF`, and `JSR`s cross from one range
  to the other. The reset vector at the end of the image points into the
  last bank's own range. No F8 hotspot accesses are needed.
- **Conflicts.** All 8K schemes. Ordinary 8K games are assembled for one
  range in both banks [R], so the split is specific. Our README lists "some
  FE images" as needing the menu override: FE detection may miss.
- **Fallback.** Not detected: F8 (the menu can force FE).

### 3.7 E0 (`BANKE0`)

- **Sizes.** 8,192 bytes: eight 1K slices [H12, H97].
- **Hotspots.** `$1FE0-$1FE7` select the slice at `$1000-$13FF`,
  `$1FE8-$1FEF` at `$1400-$17FF`, `$1FF0-$1FF7` at `$1800-$1BFF`;
  `$1C00-$1FFF` always holds the last slice [H12; H97 gives the third range
  as `$1FF0-$1FF8`, H12's `$1FF7` is consistent with the slice count].
  Programs switch with absolute accesses [T-e0].
- **Evidence.** Accesses to `$1FE0-$1FF7`, typically several different
  ones, often from the fixed last slice. **[R]** F8 programs touch only
  `$1FF8`/`$1FF9`, so accesses in `$1FE0-$1FF7` distinguish E0; but
  `$1FF6`/`$1FF7` overlap F6/F4 hotspots, which are not 8K schemes.
- **Conflicts.** Other 8K schemes; E7 uses `$1FE0-$1FE7` too but is 16K.
- **Fallback.** F8.

### 3.8 FA (`BANKFA`)

- **Sizes.** 12,288 bytes: three 4K banks [H12, H97].
- **Hotspots.** `$1FF8-$1FFA` select banks 0-2. 256 bytes of RAM: written
  at `$1000-$10FF`, read at `$1100-$11FF` [H12, H97].
- **Evidence.** The 12K size is unique among the schemes here [H97].
- **Fallback.** Every 12,288-byte image: `BANKFA`, `sc` = 0.

### 3.9 3F (`BANK3F`)

- **Sizes.** 8K originally; homebrew images up to 512K, any multiple of 2K
  [H12, H97].
- **Hotspots.** A **write** to `$0000-$003F` selects the 2K bank shown at
  `$1000-$17FF`; `$1800-$1FFF` always shows the last 2K of the image.
  Programs write to `$3F`, which has no TIA register [H12, H97, T-3f].
- **Evidence.** **[R]** Stores to zero-page `$3F` (`STA $3F` = `85 3F`,
  also `86 3F` / `84 3F`) are otherwise pointless, since `$3F` is no TIA
  register; a program writes its bank number there. A single such byte pair
  can occur by chance in data, so more than one occurrence, or one in the
  fixed last 2K, is stronger evidence. The reset vector sits at the end of
  the image (fixed bank).
- **Conflicts.** Any size that is a multiple of 2K. 3E also writes `$3F`
  and is told apart by its writes to `$3E` (3.10). Our README lists "some
  3F images" as needing the override: 3F detection may miss.
- **Fallback.** The size's default scheme.

### 3.10 3E (`BANK3E`)

- **Sizes.** Like 3F: multiples of 2K up to 512K of ROM, plus up to 256K
  of RAM [H12].
- **Hotspots.** Writing to `$3F` selects a 2K ROM bank as in 3F; writing to
  `$3E` selects a 1K RAM bank into `$1000-$17FF` (read `$1000-$13FF`,
  write `$1400-$17FF`). `$1800-$1FFF` is the last 2K of ROM [H12, T-3e].
- **Evidence.** **[R]** Zero-page stores to `$3E` (`85 3E`, `86 3E`,
  `84 3E`) as well as `$3F`. `$3E` is also no TIA register.
- **Conflicts.** 3F: the presence of `$3E` writes decides 3E over 3F.
- **Fallback.** The size's default scheme.

### 3.11 CV (`BANKCV`)

- **Sizes.** 2,048 bytes of ROM at `$1800-$1FFF`; 1K of RAM below it, read
  at `$1000-$13FF`, written at `$1400-$17FF` [H12, T-cv].
- **Evidence.** **[R]** Writes into `$1400-$17FF` (stores, absolute or
  indexed, e.g. `STA $F400,Y`) and reads from `$1000-$13FF` [T-cv]. A plain
  2K game has no reason to write to cartridge space.
- **Conflicts.** 2K (3.1): CV wins when the evidence is there.
- **Fallback.** `BANK2K`.

### 3.12 UA (`BANKUA`)

- **Sizes.** 8,192 bytes: two 4K banks [H12].
- **Hotspots.** An access to `$0220` selects bank 0, `$0240` bank 1 [H12].
  The mapper compares only address bits 0-3, 5, 6, 9 and 12 (mask `$126F`),
  so mirrors that differ in bits 4, 7, 8, 10 or 11 also switch [U-banks]. **[R]** These are RIOT
  addresses, so the access is usually a read (`LDA $0220` / `BIT $0240` or
  similar absolute forms).
- **Swapped layout.** Some dumps store the two banks the other way round:
  bank 1's contents first. The mapper handles them with
  `mapper_revision[0]` = 1, which makes `$0220` select image bank 1 and
  `$0240` image bank 0 [U-banks]. **[R]** In a normal image, code in image
  bank 0 switches away with `$0240` and code in image bank 1 with `$0220`;
  in a swapped image it is the reverse.
- **Evidence.** Absolute accesses to `$0220`/`$0240` (or their mirrors).
- **Conflicts.** Other 8K schemes; 0840 also uses addresses below `$1000`
  but in `$0800-$0FFF` (3.17).
- **Fallback.** F8.

### 3.13 E7 (`BANKE7`)

- **Sizes.** 16,384 bytes: eight 2K slices [H12, H97]. **[R]** Smaller
  images of the same layout (8K, 12K) cannot be ruled out but are not known
  from the sources.
- **Hotspots.** `$1FE0-$1FE6` select slice 0-6 at `$1000-$17FF`; `$1FE7`
  puts 1K of RAM there instead (write `$1000-$13FF`, read `$1400-$17FF`).
  `$1800-$19FF` is a 256-byte RAM bank (write `$1800-$18FF`, read
  `$1900-$19FF`), one of four, chosen by `$1FE8-$1FEB` [H12; H97 gives
  `$1FF8-$1FFB` for the RAM bank select, H12 corrects it to `$1FE8-$1FEB`,
  and our test ROM passes with `$1FE8-$1FEB`, T-e7]. `$1A00-$1FFF` is fixed
  to the last 1.5K of the image.
- **Evidence.** Accesses to `$1FE0-$1FEB` in a 16K image; the reset vector
  at the end of the image.
- **Conflicts.** F6 and other 16K schemes. E0 uses the same address range
  but is 8K. EF (3.16) uses `$1FE0-$1FEF` too: **[R]** EF never needs
  `$1FE8-$1FEB` as RAM selects and has whole 4K banks, while E7 code lives
  in the fixed top 1.5K and RAM is read at `$1900-$19FF` / `$1400-$17FF`.
- **Fallback.** F6.

### 3.14 F0 (`BANKF0`)

- **Sizes.** 65,536 bytes: sixteen 4K banks [H12, H97].
- **Hotspots.** Each access to `$1FF0` moves to the next bank, wrapping
  [H12, H97, T-f0].
- **Evidence.** Accesses to `$1FF0`.
- **Conflicts.** EF (64K form, 3.16), 3F/3E 64K, the 32-in-1 multicart and
  MC8K (manual only). A 64K 32-in-1 has the same size and no evidence of its
  own (3.22).
- **Fallback.** 64K images with no evidence for another 64K scheme:
  `BANKF0`.

### 3.15 WD (`BANKWD`)

- **Sizes.** 8,192 bytes: eight 1K slices, plus 64 bytes of RAM (read
  `$1000-$103F`, write `$1040-$107F`) [U-banks, T-wd].
- **Hotspots.** An access to `$0030-$003F` picks one of eight preset slice
  layouts (address bits 0-2) for the four 1K segments; it takes effect a
  few bus cycles later, so programs follow it with a `JMP` [U-banks, T-wd].
- **Swapped layout.** An 8,195-byte dump stores 1K slices 2 and 3 swapped;
  the mapper corrects it with `mapper_revision[0]` = 1 [U-banks, U-cart].
- **Evidence.** **[R]** Accesses to zero page `$30-$3F` that are reads
  (`LDA`/`BIT`/... zero page `$30-$3F`, `A5 3x`, `24 3x`): those TIA
  addresses are write registers or unused, so a read there is pointless on a
  plain cartridge. Each is typically followed by a `JMP` (`4C`) [T-wd].
  The size 8,195 is unique to the swapped WD dump.
- **Conflicts.** 3F/3E write to `$3E`/`$3F` (stores, not reads). Other 8K
  schemes.
- **Fallback.** 8,195 bytes: `BANKWD` with `mapper_revision[0]` = 1. 8K: F8.

### 3.16 EF (`BANKEF`)

- **Sizes.** Up to 64K: sixteen 4K banks [H12]. Our test images are 64K
  [T-fx].
- **Hotspots.** `$1FE0-$1FEF` select banks 0-15 [H12]. May carry a
  Superchip (3.5) [U-banks, T-fx].
- **Evidence.** Accesses to `$1FE0-$1FEF` in an image of whole 4K banks.
- **Conflicts.** F0 at 64K (F0 uses only `$1FF0`); E0/E7 at 8K/16K.
- **Fallback.** The size's default scheme.

### 3.17 0840 (`BANK0840`)

- **Sizes.** 8,192 bytes: two 4K banks [H12].
- **Hotspots.** An access with A12 = 0 and A11 = 1 (`$0800-$0FFF` and
  mirrors) selects bank A6: `$0800` bank 0, `$0840` bank 1 [H12, U-banks].
- **Evidence.** Absolute accesses to `$0800`/`$0840` (or other addresses in
  `$0800-$0FFF` and their mirrors). **[R]** Nothing else lives in
  `$0800-$0FFF` on the 2600 (TIA and RIOT are in `$0000-$07FF`), so an
  access there is deliberate.
- **Conflicts.** Other 8K schemes.
- **Fallback.** F8.

### 3.18 SB (`BANKSB`)

- **Sizes.** Up to 256K of 4K banks; our test images are 128K and 256K
  [H12, T-fx]. Larger than the Game Bub's 64K, so core simulation only.
- **Hotspots.** Like 0840 but the bank number is the low address bits: an
  access to `$0800+n` (A12 = 0, A11 = 1) selects bank n [H12, U-banks].
- **Evidence.** Accesses to `$0800-$08FF`-style addresses (and mirrors)
  with varying low bits.
- **Conflicts.** DF/BF at 128K/256K; 3F/3E at those sizes.
- **Fallback.** The size's default scheme.

### 3.19 FA2 (`BANKFA2`)

- **Sizes.** Seven 4K banks at hotspots `$1FF5-$1FFB`; 256 bytes of RAM
  written at `$1000-$10FF` and read at `$1100-$11FF`; `$1FF4` runs a flash
  save/load operation instead of switching [U-fa2, T-fx]. Images come as
  24,576 bytes (six banks; the seventh reads as zeros), 28,672 bytes, or a
  Harmony image of 29,696 bytes or more whose first 1,024 bytes are not
  part of the banks (bank 0 starts at offset 1,024) [U-fa2].
- **Evidence.** **[R]** The size (24K and 28K are not used by the other
  schemes here); accesses to `$1FF5-$1FFB`; a RAM window (first 512 bytes
  of each bank) filled with one value. For a 29,696-byte image, the banks
  start at offset 1,024.
- **Conflicts.** At 32K: F4 (3.4), CTY (manual only). At 29,696 bytes:
  ARM images (3.22).
- **Fallback.** 24,576 and 28,672 bytes: `BANKFA2`.

### 3.20 FC (`BANKFC`)

- **Sizes.** Up to eight 4K banks: 4K-32K [U-banks]; our test image is 16K
  [T-fc].
- **Hotspots.** A write to `$1FF8` gives the low two bits of the next bank,
  a write to `$1FF9` the rest; an access to `$1FFC` then switches. Programs
  do `STA $1FF8`, `STY $1FF9` (or another store), then read `$1FFC`
  [U-banks, T-fc].
- **Evidence.** **[R]** Stores to `$1FF8`/`$1FF9` followed by an access to
  `$1FFC`. `$1FFC` is the reset vector in every other scheme and is never
  accessed by ordinary code.
- **Conflicts.** F8/F6/F4 also use `$1FF8`/`$1FF9` (usually with loads or
  `BIT`); the access to `$1FFC` is the discriminator.
- **Fallback.** The size's default scheme.

### 3.21 JANE (`BANKJANE`)

- **Sizes.** 16,384 bytes: four 4K banks [U-banks, T-fx].
- **Hotspots.** `$1FF0` bank 0, `$1FF1` bank 1, `$1FF8` bank 2, `$1FF9`
  bank 3; bank 1 at power-on [U-banks]. The game switches from small
  `LDA hotspot` / `RTS` subroutines [T-fx].
- **Evidence.** Accesses to `$1FF0`/`$1FF1` in a 16K image. **[R]** F6
  uses `$1FF6-$1FF9` and never `$1FF0`/`$1FF1`.
- **Conflicts.** F6 (shares `$1FF8`/`$1FF9`), E7, FC.
- **Fallback.** F6.

### 3.22 Schemes outside detection

- **P2 (DPC, `BANKP2`).** 8K of program in two F8-style banks plus 2K of
  display data reachable only through the chip: images are 10,240 bytes
  (8K + 2K) [H12, T-p2]. The size is unique here: every 10,240-byte image
  is `BANKP2`.
- **CTY, MC2K/4K/8K, 32-in-1.** Selected only from the menu. A 64K 32-in-1
  image looks like F0 and is detected as F0 [GB-readme].
- **ARM cartridges (DPC+, CDF, BUS, ELF)** cannot run in this core
  (`NO_ARM_MAPPER`); `BANKDPCP`, `BANKCDF`, `BANKBUS` and `BANKELF` all show
  the unsupported-cartridge screen [GB-patch]. Detecting them is optional.
  The one rule kept: a 29,696-byte image that is not FA2 (no FA2 evidence
  after its first 1,024 bytes, 3.19), including an all-zero image, is
  reported as `BANKDPCP`, so the test suite's unsupported-cartridge check
  keeps working [GB-suite].
- **AR (Supercharger)** is not supported by this core [GB-readme]; it need
  not be detected.
- **DF/BF (`BANKDF`).** 128K (32 banks, hotspots `$1FC0-$1FDF`) and 256K
  (64 banks, hotspots `$1F80-$1FBF`), with optional Superchip [U-banks,
  T-fx]. Core simulation only. Evidence: accesses to those hotspots.

## 4. Cross-cutting rules

### 4.1 Precedence

When the evidence of several schemes is present, the more specific one
wins. The order below follows from the facts above; within it the
implementer may order checks freely.

1. **Unique sizes** decide alone: 12,288 → FA; 10,240 → P2; 8,195 → WD
   swapped; 24,576 / 28,672 → FA2; 29,696 → FA2 or ARM (3.19, 3.22).
2. **Schemes with discriminating evidence** beat the size's default:
   CV over 2K; at 8K: E0, FE, UA, 0840, WD, 3E, 3F over F8; at 16K: E7,
   JANE, FC, 3E, 3F over F6; at 32K: FC, 3E, 3F over F4; at 64K: EF, 3E,
   3F over F0; at 128K/256K: DF/BF, SB, 3E, 3F.
3. **3E over 3F** when both `$3E` and `$3F` writes are present.
4. **Size defaults** last: ≤ 2K → 2K, 4K → 4K, 8K → F8, 16K → F6, 32K →
   F4, 64K → F0. Other sizes: the next power-of-two default if it fits,
   else the closest smaller one (**[R]**: the mappers mask addresses to the
   image size [U-cart]); the implementer documents what it chose.
5. **Superchip** is decided independently of the scheme and reported only
   for F8, F6, F4, 4K, EF, DF/BF, UA and JANE (3.5).

Conflicts between two discriminating schemes at the same size (for
example an 8K image with both E0 and 3F evidence) are the implementer's
choice; the differential test (section 5) shows how often they occur.

### 4.2 Sizes the core refuses

The Game Bub wrapper refuses images over 64K before they run, so detection
of DF/BF, SB and large 3E/3F only matters in the core simulation
[GB-core, GB-readme]. Images over 512K are outside the core's ROM.

## 5. Acceptance

- Every bankswitch test ROM in `sim/testroms` (via `sim/suite.py`) detects
  as the suite expects, except the ones the suite lists as not detectable.
- A differential run against upstream's detector, over the test ROMs and a
  set of synthetic images (`make -C sim/detect run`), lists every
  disagreement; each is either fixed by a sourced rule here or accepted.
- Lint-clean under Verilator `-Wall`; synthesises in Vivado for the Game
  Bub (Artix-7) at the system clock.

## Sources

| Tag | Source |
|---|---|
| H12 | Kevin Horton, *Mostly Inclusive Atari 2600 Mapper / Selected Hardware Document*, v1.00, 2012-03-04. <http://blog.kevtris.org/blogfiles/Atari%202600%20Mappers.txt> |
| H97 | Kevin Horton, *Cart Information* (sizes.txt), v6.00, 1997-04-18. <https://www.atariage.com/2600/programming/bankswitch_sizes.txt> |
| 6502 | MOS Technology MCS6500 instruction set (standard opcode table) |
| U-banks | `third_party/atari7800_mister/rtl/banks2600.sv` (MIT, Jamie Blanks): the mapper hardware this core runs, used for hotspot and image-layout facts only |
| U-fa2 | `third_party/atari7800_mister/rtl/mapper_fa2.sv` (MIT), same use |
| U-cart | `third_party/atari7800_mister/rtl/cart2600.sv` (MIT): ports and the use of `mapper_revision` |
| T-* | Our own test ROMs, `sim/testroms/bs_*.asm` (MIT), e.g. T-fx = `bs_fx.asm` |
| GB-core | `hdl/atari2600_core.sv`, `hdl/gamebub/atari2600_gamebub.sv` (load stream, sizes, timing) |
| GB-patch | `patches/atari7800_mister.patch` (ARM schemes unsupported) |
| GB-readme | `README.md`, Compatibility |
| GB-suite | `sim/suite.py` (expected detections) |

Not used, by rule: Stella's source, MAME/MESS source, and upstream's
`detect2600.sv`.
