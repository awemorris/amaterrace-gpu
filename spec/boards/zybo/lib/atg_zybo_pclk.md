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

MMCME2_ADV and BUFGMUX instances (vendor primitives: this file is in boards/).  Values referenced: the MMCM's M/D/O for 25.2 and 74.25 MHz from 100 MHz (to compute in p005 with the Clocking Wizard's numbers or by hand, UG472).

## 5. State machine

None.

## 6. Latency and throughput

-

## 7. Corner cases and errors

- 25.175 MHz is not reachable from 100 MHz: 25.2 MHz is inside VGA's tolerance (design §1.3), to be confirmed on a monitor.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.

## 9. References

design §1.3 (pclk), §5.1, Values referenced: UG472 (MMCM).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
