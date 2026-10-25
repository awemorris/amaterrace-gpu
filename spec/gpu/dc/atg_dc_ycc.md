# atg_dc_ycc

RTL: `rtl/gpu/dc/atg_dc_ycc.v`.  Parent: atg_dc (PX_FMT = 1).  Implemented in: p012.

## 1. Purpose and place

The KC705 HDMI pixel format: RGB888 from atg_dc_tgen to 16-bit YCbCr 4:2:2 with separate syncs, the parallel input of the board's ADV7511 (the KC705 wires 16 data lines to it).

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: pclk unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | (pclk) Pixel clock. |
| `rst_n` | in | 1 | (pclk) Reset. |
| `rgb` | in | 24 | (pclk) Pixel {r, g, b}. |
| `de` | in | 1 | (pclk) DE. |
| `hs` | in | 1 | (pclk) HSYNC (polarity already applied). |
| `vs` | in | 1 | (pclk) VSYNC. |
| `ycc` | out | 16 | (pclk) {C, Y}: C is Cb on the first pixel of each pair from the rise of DE and Cr on the second. |
| `ycc_de` | out | 1 | (pclk) DE, two cycles late. |
| `ycc_hs` | out | 1 | (pclk) HSYNC, two cycles late. |
| `ycc_vs` | out | 1 | (pclk) VSYNC, two cycles late. |

10 ports.

## 4. Behaviour

- BT.601, studio range, 8-bit coefficients: Y = ((66 R + 129 G + 25 B + 128) >> 8) + 16,
  Cb = ((-38 R - 74 G + 112 B + 128) >> 8) + 128, Cr = ((112 R - 94 G - 18 B + 128) >> 8) + 128
  (the RTL folds the offsets into one non-negative 16-bit sum; within 1 of the real BT.601 values).
- Chroma co-sited: the pair's Cb and Cr both come from its first pixel.  The pair phase restarts at
  each rise of DE (a line of odd width ends with a Cb).
- Outside DE the output is black (Y 16, C 128).  All outputs are registered; DE/HS/VS are delayed
  by the same two stages as the data.
- Bit order on the KC705: ycc[7:0] = Y and ycc[15:8] = C on HDMI_R_D[7:0] and HDMI_R_D[15:8], as
  ADI's KC705 reference (ad_ss_444to422: {C, Y}).  The ADV7511's input mode (input ID 1, 16-bit
  4:2:2 separate syncs; the style and the CSC to RGB) is set over I2C by the host (part B).

## 5. State machine

None (the pair phase bit).

## 6. Latency and throughput

Two cycles, one pixel per pclk (74.25 MHz for 720p).

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_dc_ycc_tb.v` prints, in this order:

- `PASS atg_dc_ycc.colors` — the model within 1 of BT.601 for white, black, red, green, blue, grey; the RTL's pair after blanking
- `PASS atg_dc_ycc.stream` — random lines and syncs against the model (pairs, blanking, the delay of DE/HS/VS)
- `PASS atg_dc_ycc` at the end.

## 9. References

design §5.1 (KC705 HDMI, U7).  Values referenced: ITU-R BT.601 (coefficients); Analog Devices'
wiki "ADV7511 HDMI reference design for KC705" (16-bit 4:2:2 YCbCr) and ADI hdl
`library/common/ad_ss_444to422.v` at hdl_2016_r1 (71e609b7; the {C, Y} order).  The ADV7511's
register settings are not used here.

## 10. Status

New in WS288 p012 part A (TB `atg_dc_ycc_tb` PASS); not in design §7.6's list (added because the
KC705 has 16 data lines to the ADV7511, not 24: Q1 to ACK).
