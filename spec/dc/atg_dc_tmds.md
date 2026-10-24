# atg_dc_tmds

RTL: `rtl/dc/atg_dc_tmds.v`.  Parent: atg_dc.  Implemented in: p005.

## 1. Purpose and place

DVI/HDMI TMDS encoding (8b/10b with DC balance, control symbols in blanking) of the three channels; the 10-bit symbols are serialised by OSERDESE2 in the board top (vendor primitive).

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: pclk unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | (pclk) pclk. |
| `rst_n` | in | 1 | (pclk) Reset. |
| `rgb` | in | 24 | (pclk) Pixel. |
| `de` | in | 1 | (pclk) DE. |
| `hs` | in | 1 | (pclk) HSYNC. |
| `vs` | in | 1 | (pclk) VSYNC. |
| `tmds` | out | 30 | (pclk) {ch2 (red), ch1 (green), ch0 (blue + sync)} 10-bit symbols, LSB first. |

7 ports.

## 4. Behaviour

DVI 1.0 TMDS algorithm per channel; ch0 control = {vs, hs}.

## 5. State machine

None (a running disparity per channel).

## 6. Latency and throughput

1 pixel/cycle, 2 cycles latency.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_dc_tmds_tb.v` prints, in this order:

- `PASS atg_dc_tmds.encode` — random pixels: decode(encode(x)) == x and the running disparity stays bounded
- `PASS atg_dc_tmds.ctrl` — control symbols
- `PASS atg_dc_tmds` at the end.

## 9. References

design §5.1 (HDMI), Values referenced: DVI 1.0 §3.2 (TMDS encoding).

## 10. Status

Implemented in WS288 p005 (TB `atg_dc_tmds_tb` PASS).
