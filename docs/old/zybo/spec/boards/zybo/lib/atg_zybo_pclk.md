# atg_zybo_pclk

RTL: `boards/zybo/lib/atg_zybo_pclk.v`.  Parent: atg_zybo_dc.  Implemented in: p005.

## 1. Purpose and place

The ZYBO DC's pixel clocks: an MMCME2 from FCLK_CLK0 (100 MHz) making 25.2 / 126 MHz (640×480) and 74.25 / 371.25 MHz (720p), selected by a BUFGMUX pair (design §1.3, §5.1).

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | 100 MHz. |
| `rst_n` | in | 1 | Reset. |
| `sel` | in | 1 | PCLK_SEL[0] (gclk; the BUFGMUX takes it glitch-free). |
| `pclk` | out | 1 | (pclk) Pixel clock. |
| `pclk5` | out | 1 | (pclk5) 5 × pclk for the TMDS serialisers. |
| `prst_n` | out | 1 | (pclk) Reset synchronised to pclk (low until the MMCM locks). |
| `locked` | out | 1 | MMCM locked (gclk through am_sync in the implementation). |

7 ports.

## 4. Behaviour

Two MMCME2_BASE and two BUFGMUX (vendor primitives: this file is in boards/).  One MMCM cannot make both modes (the pixel clock and 5× of both need a common VCO far above 1200 MHz), so each mode has its own (the 7010 has two), the pixel clock on CLKOUT0 and 5× on CLKOUT1 of one VCO.  sel 0: D 5, M 50.375, VCO 1007.5 MHz, O0 40 → **25.1875 MHz** (VESA 25.175, +0.05 %), O1 8 → 125.9375.  sel 1: D 8, M 59.375, VCO 742.1875, O0 10 → **74.21875 MHz** (CEA 74.25, −0.04 %), O1 2 → 371.09375.  Values referenced: UG472 (VCO 600–1200 MHz for −1, PFD ≥ 10 MHz, fractional M and O0 in 0.125 steps), computed by hand.  prst_n = rst_n and both locked, through two flops in pclk; locked through am_sync to gclk.

## 5. State machine

None.

## 6. Latency and throughput

-

## 7. Corner cases and errors

- 25.175 MHz is not reachable from 100 MHz with integer M: the fractional M gives 25.1875 (closer than design §1.3's 25.2), to be confirmed on a monitor.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.

## 9. References

design §1.3 (pclk), §5.1, Values referenced: UG472 (MMCM).

## 10. Status

Implemented in WS288 p005 (lint stubs of the primitives in sim/lint/xilinx_stubs.v).
