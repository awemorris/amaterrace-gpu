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

Vendor primitives (boards/): per channel a MASTER/SLAVE OSERDESE2 pair (DATA_WIDTH 10, DDR, CLK pclk5, CLKDIV pclk; the master takes bits 0–7 on D1–D8, the slave 8–9 on D3–D4 through SHIFTOUT; bit 0 first), and OBUFDS (TMDS_33 in the XDC).  The clock channel sends 1111100000.  RST is !rst_n (pclk).  Values referenced: UG471 (OSERDESE2 width expansion).

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

Implemented in WS288 p005.
