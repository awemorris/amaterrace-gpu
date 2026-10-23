# atg_kc705_clk

RTL: `boards/kc705/lib/atg_kc705_clk.v`.  Parent: atg_kc705_raster.  Implemented in: p012.

## 1. Purpose and place

The KC705's clocks: SYSCLK 200 MHz (differential) → MMCME2 → gclk 100 MHz, the MIG reference, and the pixel clocks (BUFGMUX by PCLK_SEL); resets synchronised per domain.

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
| `gclk` | out | 1 | 100 MHz. |
| `grst_n` | out | 1 | gclk reset. |
| `ref_clk` | out | 1 | 200 MHz for the MIG. |
| `ref_rst_n` | out | 1 | Its reset. |
| `pclk` | out | 1 | (pclk) Pixel clock. |
| `prst_n` | out | 1 | (pclk) pclk reset. |

10 ports.

## 4. Behaviour

Stub until p012 (IBUFDS, MMCME2_ADV, BUFG, BUFGMUX).

## 5. State machine

-

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.

## 9. References

design §1.3 (KC705 column).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
