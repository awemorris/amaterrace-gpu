# atg_dc_cursor

RTL: `rtl/gpu/dc/atg_dc_cursor.v`.  Parent: atg_dc.  Implemented in: p035 D5.

## 1. Purpose and place

The cursor plane (plane 1, docs/ghci.md §13.2, design §18.5): a 64 x 64 BGRA8 image with
premultiplied alpha, read once per flip into a BRAM and blended, in gclk, over the pixels that
`atg_dc_dma` sends to the pixel FIFO.  Parent: `atg_dc`, which puts it between the DMA and the FIFO
and shares the DC's AMB port between the DMA (first) and this module with `am_amb_mux`.  No
children.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | gclk. |
| `rst_n` | in | 1 | Board reset. |
| `dc_reset` | in | 1 | The DC's CTRL.RESET (a level for some cycles): a pending flip is taken as cancelled, the image is hidden, a load stops (its responses are still counted). |
| `enable` | in | 1 | CTRL.ENABLE.  Its fall takes a pending flip as cancelled and stops a load. |
| `format` | in | 2 | CTRL.FORMAT of plane 0. |
| `frame_start` | in | 1 | One-cycle pulse: the DMA starts a frame (the back porch). |
| `dma_done` | in | 1 | Level: the DMA has requested every line of the frame and pushed every pixel (or has no frame). |
| `fb_width` | in | 16 | FB_SIZE.width (the pixels per row of the DMA's stream). |
| `i_valid`, `i_ready`, `i_data` | in, out, in | 1, 1, 32 | The DMA's pixels (valid/ready). |
| `o_valid`, `o_ready`, `o_data` | out, in, out | 1, 1, 32 | To the pixel FIFO (valid/ready). |
| `pos` | in | 32 | CURSOR_POS: [15:0] x, [31:16] y, signed. |
| `show` | in | 1 | CURSOR_CTRL[0]. |
| `flip_valid` | in | 1 | One-cycle pulse: a FLIP of plane 1. |
| `flip_base` | in | 32 | Its image, 64-byte aligned. |
| `taken` | out | 1 | One-cycle pulse: the pending flip was taken. |
| `taken_cancel` | out | 1 | With `taken`: as cancelled. |
| `pending` | out | 1 | A flip is pending. |
| `cursor_base` | out | 32 | CURSOR_BASE: the image shown (the last taken, not cancelled). |
| `idle` | out | 1 | No read of the cursor offered or outstanding. |
| `err` | out | 1 | One-cycle pulse: a read of the image had an error response. |
| AMB client port | — | — | Reads only (one group). |

23 ports.

## 4. Behaviour

- **Flip and load**: `flip_valid` makes `flip_base` pending.  With `enable` 0 it is taken at once,
  cancelled.  A pending image is loaded once `dma_done` is 1 (the frame's reads are over): 16 KiB
  as 16384 / `LINE_BYTES` line reads, the responses unpacked into the BRAM (4096 x 32 bits, one
  word a cycle) through a line FIFO of 4 entries (a read is issued only when it has room).  While
  loading, the cursor is not shown.  At the first `frame_start` after the load: `taken`, the
  image becomes `cursor_base`, and the cursor shows it from that frame.  A load not finished by a
  `frame_start` goes on during the frame (the DMA has priority on the port).  An error response
  pulses `err`; the image is then not shown until the next flip (the flip is still taken).
- **Position**: `pos` and `show` are taken at `frame_start` (a write in the middle of a frame does
  not tear it).  `test pattern` needs nothing here (atg_dc_tgen ignores the FIFO).
- **Blend**: the module counts the stream's pixels (x from 0 to `fb_width` − 1, then y + 1) from
  `frame_start`.  A pixel inside the shown cursor (0 ≤ x − pos.x < 64, 0 ≤ y − pos.y < 64) gets
  per channel c + round(p × (255 − a) / 255), saturated at 255, with the cursor's c and a and the
  pixel's p; the round is (t + 128 + ((t + 128) >> 8)) >> 8 of t = p × (255 − a).  BGRA8: the
  bytes as they are; RGBA8: the cursor's R and B are swapped; RGB565: each channel widened by
  repeating its top bits, blended, and narrowed by rounding (round(v × 31 / 255) or × 63 / 255).
  The pixel's alpha byte is kept.  Other pixels pass unchanged.
- **Pipeline**: one register stage (the BRAM read); `i_ready` = !stage_valid || `o_ready`.  At
  `frame_start` and when `enable` is 0 the stage is emptied (a stale pixel of an aborted frame does
  not reach the next frame).

## 5. State machine

IDLE →(pending, `dma_done`, `enable`)→ LOAD →(every line requested and written)→ READY
→(`frame_start`)→ IDLE (`taken`).  From LOAD or READY: `enable` falls or `dc_reset` → DRAIN
→(no read outstanding)→ IDLE, the flip taken as cancelled.

## 6. Latency and throughput

One pixel per cycle through the stage (1 cycle).  A load: 16384 / `LINE_BYTES` reads and 4096
BRAM writes, about 4100 cycles; the window between a frame's last read and the next frame start is
about 26k gclk at 720p60 and 13k at 480p60.

## 7. Corner cases and errors

- A flip while a load or READY: not possible (the CP's slot holds one flip per plane until it is
  taken).
- A cursor partly outside the screen: clipped (negative positions included).
- RGB565 with a = 0 and c = 0 gives the pixel back unchanged (checked for all values in the TB).

## 8. What the TB checks

`sim/tb/atg_dc_cursor_tb.v` (every output pixel against a model, random valid/ready on both sides): `load` (no read before `dma_done`, hidden while loading, 16384 / `LINE_BYTES` reads, the take at the next frame start, CURSOR_BASE), `blend` (clipping at every edge with negative positions, alpha 0, 255 and in between, saturation, a cursor outside; at least 5000 blended pixels), `pos` (a write in the middle of a frame is taken at the next one), `fmt` (RGBA8, RGB565, every 565 value unchanged under a = 0, c = 0), `cancel` (ENABLE 0 at the flip, ENABLE falling before the load, the DC's reset during the load, then idle and a new load), `err` (an image in the error range: `err`, taken, not shown), then `PASS atg_dc_cursor`.  A mutation that swaps R and B in the BGRA8 blend fails it.

## 9. References

docs/ghci.md §13.2; design §18.5.

## 10. Status

Implemented in WS288 p035 D5 (`atg_dc_cursor_tb` PASS: load, blend, pos, fmt, cancel, err).  About 340 lines, one FSM, gclk only; the BRAM is 4096 x 32 bits (BRAM36 x 4 when inferred), the line FIFO 4 lines.  Differences from the first draft of this spec: the blend's round is written as (t + (t >> 8)) >> 8 of t = p x (255 − a) + 128 (exact for every t, checked exhaustively off line); `test pattern` needs nothing here.
