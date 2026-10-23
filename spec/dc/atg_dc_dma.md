# atg_dc_dma

RTL: `rtl/dc/atg_dc_dma.v`.  Parent: atg_dc.  Implemented in: p005.

## 1. Purpose and place

The DC's scan-out DMA: reads the framebuffer FB_BASE line by line (FB_STRIDE, FB_SIZE) through the AMB and pushes pixel words into the pixel FIFO towards pclk.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 (ZYBO) or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `enable` | in | 1 | ENABLE (gclk). |
| `frame_start` | in | 1 | Pulse (from tgen via am_sync): start the frame at fb_base. |
| `fb_base` | in | 32 | Frame address. |
| `fb_stride` | in | 32 | Stride. |
| `fb_size` | in | 32 | {h, w}. |
| `format` | in | 2 | Pixel size from FORMAT (RGB565: 16 bits). |
| `px_valid` | out | 1 | Pixel word to the FIFO (am_afifo w_*). |
| `px_ready` | in | 1 | Room. |
| `px_data` | out | 32 | One pixel (RGB565 in the low 16 bits). |
| `idle` | out | 1 | No request outstanding (STATUS.idle; detach quiesce). |
| **AMB client port (design §4.1)** | | | |
| `req_valid` | out | 1 | Request valid; payload held until `req_ready`. |
| `req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `req_write` | out | 1 | 1 write, 0 read. |
| `req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `req_tag` | out | 8 | The client's tag, returned with the response. |
| `rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `rsp_tag` | in | 8 | Tag of the request answered. |
| `rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |

24 ports; 13 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Keeps the FIFO (2 lines) full ahead of the scan: reads lines up to 4 outstanding.  ENABLE = 0 stops new requests; idle when the responses are in.

## 5. State machine

IDLE →(frame_start)→ LINE (requests) → … → IDLE.

## 6. Latency and throughput

Must sustain the pixel rate: 640×480@60 25 Mpx/s (100 MB/s), 720p 74 Mpx/s.

## 7. Corner cases and errors

- An error response: the pixels are 0 (the MC raised the fault).

## 8. What the TB checks

`sim/tb/atg_dc_dma_tb.v` prints, in this order:

- `PASS atg_dc_dma.frame` — a frame's words in order
- `PASS atg_dc_dma.stop` — ENABLE 0 stops and idle rises
- `PASS atg_dc_dma` at the end.

## 9. References

design §5.1 (atg_dc_dma), §4.2.

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
