# atg_kc705_clk

RTL: `boards/kc705/lib/atg_kc705_clk.v`.  Parent: atg_kc705_top.  Implemented in: p012.

## 1. Purpose and place

The KC705's clocks: SYSCLK 200 MHz (differential) → MMCME2 → gclk (1000 MHz / `GCLK_DIVIDE`), the MIG reference, and the pixel clocks (BUFGMUX by PCLK_SEL); resets synchronised per domain.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `sys_clk_p` | in | 1 | SYSCLK +. |
| `sys_clk_n` | in | 1 | SYSCLK -. |
| `cpu_reset` | in | 1 | CPU_RESET button (active high). |
| `pclk_sel` | in | 1 | PCLK_SEL[0] (gclk). |
| `gclk` | out | 1 | 1000 MHz / `GCLK_DIVIDE` (the board top's 50 = 20 MHz is a placeholder, chosen in p025; the simulation model gives 100 MHz). |
| `grst_n` | out | 1 | gclk reset. |
| `sys_cc` | out | 1 | SYSCLK 200 MHz straight from the IBUFDS: the MIG's PLL (dedicated route to bank 33's CMT, no BUFG). |
| `ref_clk` | out | 1 | The same 200 MHz after a BUFG: the MIG's IDELAYCTRL reference and the three clock managers. |
| `ref_rst_n` | out | 1 | Its reset. |
| `pclk` | out | 1 | (pclk) Pixel clock. |
| `prst_n` | out | 1 | (pclk) pclk reset. |

10 ports.

## 4. Behaviour

IBUFDS: sys_cc (the MIG's system clock, taken without the MIG's own buffer, straight to its PLL; ws288 p024: with the BUFG in front the calibration failed, the suspected cause); then a BUFG: ref_clk (the MIG's IDELAYCTRL reference).
Three clock managers from ref_clk: gclk MMCM (DIVCLK 1, MULT 5, O0 `GCLK_DIVIDE`, BUFG; 2026-10-25 p024: the parameter, was a fixed 10 = 100 MHz); 640×480
PLL (DIVCLK 5, MULT 34, O0 54: 25.185 MHz); 720p MMCM (DIVCLK 10, MULT 59.375, O0 16: 74.21875
MHz); BUFGMUX by pclk_sel.  No 5 × pixel clock (no TMDS on the KC705).  Each reset = CPU_RESET
released and the domain's clock manager locked, through am_sync (unreset) in the domain.  The
simulation model `sim/models/kc705/atg_kc705_clk.v` (same ports) makes the same frequencies.

## 5. State machine

-

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.

## 9. References

design §1.3 (KC705 column), §5.1 (PCLK_SEL).  Values referenced: UG472, DS182 (the VCO and PFD ranges of the -2 grade, not re-checked in p012).

## 10. Status

Implemented in WS288 p012 part A (lint; simulated only as its model).  MMCME2_BASE and
PLLE2_BASE instead of the stub text's MMCME2_ADV (no DRP yet: other modes come later with it).
Unverified until part B: the settings against DS182, the BUFGMUX of a PLL and an MMCM output.
