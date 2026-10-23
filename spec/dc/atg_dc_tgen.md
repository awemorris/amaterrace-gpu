# atg_dc_tgen

RTL: `rtl/dc/atg_dc_tgen.v`.  Parent: atg_dc.  Implemented in: p005.

## 1. Purpose and place

The DC's timing generator in the pixel clock: h/v counters, DE/HSYNC/VSYNC, pixel pop from the FIFO, format conversion to RGB888, the test pattern, frame start and vsync events.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: pclk unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | (pclk) Pixel clock (pclk). |
| `rst_n` | in | 1 | (pclk) Reset (pclk). |
| `enable` | in | 1 | (pclk) ENABLE through am_sync. |
| `test_pattern` | in | 1 | (pclk) Quasi-static. |
| `format` | in | 2 | (pclk) Quasi-static. |
| `timing` | in | 288 | (pclk) Quasi-static. |
| `px_valid` | in | 1 | (pclk) FIFO head (am_afifo r_*). |
| `px_ready` | out | 1 | (pclk) Pop. |
| `px_data` | in | 32 | (pclk) Pixel. |
| `rgb` | out | 24 | (pclk) Pixel {r, g, b}. |
| `de` | out | 1 | (pclk) Data enable. |
| `hs` | out | 1 | (pclk) HSYNC (polarity applied). |
| `vs` | out | 1 | (pclk) VSYNC. |
| `frame_toggle` | out | 1 | (pclk) Toggles at each frame start (to gclk through am_sync: edge = frame_start). |
| `vsync_toggle` | out | 1 | (pclk) Toggles at each vsync. |
| `underflow_toggle` | out | 1 | (pclk) Toggles when a pixel was due and the FIFO was empty. |
| `line` | out | 12 | (pclk) Current line (Gray code? no: binary, sampled in gclk as approximate). |

17 ports.

## 4. Behaviour

Counters run while enable; pixels are popped during DE; an empty FIFO gives black and an underflow toggle.  Events cross as toggles (one bit each through am_sync, the gclk side detects edges).  frame_start is raised a few lines before the active area so the DMA fills the FIFO.

## 5. State machine

None (counters).

## 6. Latency and throughput

One pixel per pclk (25.2 / 74.25 MHz).

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_dc_tgen_tb.v` prints, in this order:

- `PASS atg_dc_tgen.timing` — 640×480 timing against the VESA numbers
- `PASS atg_dc_tgen.pattern` — test pattern
- `PASS atg_dc_tgen.underflow` — underflow
- `PASS atg_dc_tgen` at the end.

## 9. References

design §5.1 (atg_dc_tgen, PCLK_SEL), Values referenced: VESA DMT 640×480@60, CEA-861 720p.

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
