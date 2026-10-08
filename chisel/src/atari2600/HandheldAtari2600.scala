// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser

package atari2600

import chisel3._
import net.gamebub.framework.Core
import net.gamebub.framework.interface._

object HandheldAtari2600 {
  // Clock plan; hdl/gamebub/atari2600_mmcm.sv implements it and must use the
  // same numbers. The MMCM multiplies the board's 50 MHz up to a 601.25 MHz
  // VCO (divide by 5, multiply by 60.125). Dividing that by 42 gives
  // 14.315 MHz for the console, within 0.02% of the 2600's 14.318182 MHz
  // NTSC master clock. The host SPI clock is VCO / 3.25 = 185 MHz: VCO / 3
  // failed timing in the framework's SPI receiver (see the MMCM file).
  val mmcmVcoHz = 601_250_000.0
  val systemDivider = 42
  val spiDivider = 3.25

  // One NTSC frame: 262 lines of 228 colour clocks, 4 master clocks each.
  val clocksPerFrame = 228 * 262 * 4

  /**
   * Framebuffer: each TIA pixel is stored twice side by side, 240 of the 262
   * lines are kept, so the framework scales it x2 to 640x480. A pixel is the
   * raw 7-bit TIA colour {chroma, luma} split over r/g/b; the video filter
   * turns it into RGB with the NTSC palette.
   */
  val videoWidth = 320
  val videoHeight = 240
}

/**
 * Atari 2600 core. All logic is in the Verilog module atari2600_gamebub
 * (hdl/gamebub/), bound to the whole io bundle; this class only declares the
 * framework interfaces.
 */
class HandheldAtari2600 extends Module with Core {
  import HandheldAtari2600._

  val displayDivider = (mmcmVcoHz / ClocksV0.getClockDisplayHz(1.0 / 60.0)._1).floor.toInt
  val clockSystemHz = (mmcmVcoHz / systemDivider).toInt

  val io = IO(new Bundle {
    val clocks = new ClocksV0(
      clockSystemHz = clockSystemHz,
      clockDisplayHz = (mmcmVcoHz / displayDivider).toInt,
      clockSpiHz = (mmcmVcoHz / spiDivider).toInt,
    )
    val video = new VideoV0(
      videoWidth = videoWidth,
      videoHeight = videoHeight,
      colorDepthR = 3,
      colorDepthG = 2,
      colorDepthB = 2,
      framePeriod = clocksPerFrame.toDouble / clockSystemHz,
    )
    val videoFilter = new VideoFilterBasicV0(
      colorInDepthR = 3,
      colorInDepthG = 2,
      colorInDepthB = 2,
      latency = 2,
    )
    val audio = new AudioV0()
    val host = new HostV0()
    val input = new InputV0()
  })

  bindExtModule("atari2600_gamebub", io, Map(
    "DISPLAY_DIVIDER" -> displayDivider,
  ))
}
