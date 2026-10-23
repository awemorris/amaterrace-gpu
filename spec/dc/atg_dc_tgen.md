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

Counters run while enable; while enable is 0 they wait at the first pixel of the vsync line (h = 0, v = V_ACTIVE + V_FP) with the outputs idle, so each frame starts with a vsync.  Pixels are popped during DE (not in TEST_PATTERN, which reads no memory); an empty FIFO gives black and an underflow toggle.  During the vsync lines the FIFO is drained (pixels of a frame the DMA did not finish in time are dropped), so each frame starts aligned.  Events cross as toggles (one bit each through am_sync, the gclk side detects edges): vsync_toggle at the start of the sync, frame_toggle at the start of the back porch (the DMA has the back porch to fill the FIFO).  Formats: 0 BGRA8, 1 RGBA8, 2 RGB565 (channels widened by repeating their top bits).  The test pattern: eight bars of H_ACTIVE / 8 (white, yellow, cyan, green, magenta, red, blue, black) and a white one-pixel border.  SYNC_POL[0]/[1] = 1: hsync/vsync active high.  Outputs registered (one cycle after the counters).  TEST_PATTERN and FORMAT are taken while stopped and at each vsync (a CTRL write that clears them together with ENABLE must not show a frame of memory before ENABLE, two cycles later through am_sync, stops the counters).  FB_SIZE should equal the active size: a smaller framebuffer underflows, a larger one is drained.

## 5. State machine

None (counters).

## 6. Latency and throughput

One pixel per pclk (25.2 / 74.25 MHz).

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_dc_tgen_tb.v` prints, in this order:

- `PASS atg_dc_tgen.timing` — 640×480 timing against the VESA numbers (and 720p against CEA-861)
- `PASS atg_dc_tgen.pixels` — pixels in order after the drain, formats 1 and 2
- `PASS atg_dc_tgen.pattern` — test pattern
- `PASS atg_dc_tgen.underflow` — underflow
- `PASS atg_dc_tgen` at the end.

## 9. References

design §5.1 (atg_dc_tgen, PCLK_SEL), Values referenced: VESA DMT 640×480@60, CEA-861 720p.

## 10. Status

Implemented in WS288 p005 (TB `atg_dc_tgen_tb` PASS).
