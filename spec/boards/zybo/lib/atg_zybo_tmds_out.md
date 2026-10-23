# atg_zybo_tmds_out

RTL: `boards/zybo/lib/atg_zybo_tmds_out.v`.  Parent: atg_zybo_dc.  Implemented in: p005.

## 1. Purpose and place

The ZYBO HDMI output stage: three OSERDESE2 10:1 serialisers (DDR, pclk5) for the TMDS symbols, the TMDS clock channel, and OBUFDS (TMDS_33) for the four pairs.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `pclk` | in | 1 | (pclk) Pixel clock. |
| `pclk5` | in | 1 | (pclk5) 5 × pclk. |
| `rst_n` | in | 1 | (pclk) pclk reset. |
| `tmds` | in | 30 | (pclk) Symbols from atg_dc. |
| `hdmi_clk_p` | out | 1 | TMDS clock +. |
| `hdmi_clk_n` | out | 1 | TMDS clock -. |
| `hdmi_d_p` | out | 3 | TMDS data +. |
| `hdmi_d_n` | out | 3 | TMDS data -. |

8 ports.

## 4. Behaviour

Vendor primitives (boards/).  The clock channel sends 1111100000.

## 5. State machine

None.

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

- 720p's 742.5 Mb/s on the 7010 -1 is unverified (DS187 unread, design §5.1): 640×480 first.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.

## 9. References

design §5.1, Values referenced: UG471 (OSERDESE2), DS187.

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
