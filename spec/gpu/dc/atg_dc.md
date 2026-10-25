# atg_dc

RTL: `rtl/gpu/dc/atg_dc.v`.  Parent: atg_top (HAS_DISP).  Implemented in: p005, p012.

## 1. Purpose and place

The display controller of DISP2 (docs/ghci.md §13.2, design §18.5), a unit of the GPU inside `atg_top`: registers and DMA in gclk, a pixel FIFO (am_afifo) to the pixel clock, timing generator, a TMDS encoder and a parallel output, optional I2C; one AMB client port (MC client `C_DC`).  The CP's `atg_cp_disp` drives it through the internal register bus (`d_*`), the flips (`flip_*`, `taken`) and the status for the records.  Until `atg_cp_disp` exists, `atg_top` bridges the host's register bus at +0x10000 to `d_*` (every write passes) and makes no flips.

Children: `atg_dc_regs`, `atg_dc_mode`, `atg_dc_dma`, `atg_dc_cursor` and `am_amb_mux` (HAS_CURSOR), `atg_dc_tgen`, `atg_dc_tmds`, `atg_dc_ycc` (PX_FMT = 1), `atg_dc_i2c`, `am_afifo`, `am_sync`.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `HAS_I2C` | `0` | ADV7511 I2C master present (KC705, DC_CAPS[2]). |
| `HAS_CURSOR` | `1` | The cursor plane, plane 1 (DC_CAPS[8]): `atg_dc_cursor` between the DMA and the pixel FIFO, its reads behind the DMA's in an `am_amb_mux`. |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `FIFO_LOG2` | `9` | Pixel FIFO depth (2 lines of 640 need ≥ 1280 → 11 for 720p; 9 is the stub default). |
| `PX_FMT` | `0` | The parallel output `px_*`: 0 RGB888 (`px_rgb` = {r, g, b}, same cycle as TMDS); 1 YCbCr 4:2:2 16-bit through atg_dc_ycc (`px_rgb` = {8'd0, C, Y}, `px_de/hs/vs` two pclk later): the KC705's ADV7511 (p012). |

## 3. Ports

Clock/reset domain: clk (gclk) and pclk as marked unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | gclk. |
| `rst_n` | in | 1 | The board reset (not the CP's CTRL.RESET). |
| `pclk` | in | 1 | (pclk) Pixel clock. |
| `prst_n` | in | 1 | (pclk) pclk reset (synchronised to pclk by the board). |
| **Internal register bus (from atg_cp_disp)** | | | |
| `d_we`, `d_idx`, `d_wdata`, `d_wmask` | in | 1, 6, 32, 32 | A write of window word `d_idx` (one cycle), taken as it comes. |
| `d_ridx` | in | 6 | Read index. |
| `d_rdata` | out | 32 | The word at `d_ridx` (the OR of atg_dc_regs' and atg_dc_mode's), combinational. |
| **Flips and records (atg_cp_disp)** | | | |
| `flip_valid`, `flip_plane`, `flip_base` | in | 1, 1, 32 | One-cycle pulse: a flip of the CP. |
| `taken`, `taken_cancel` | out | 2 | Per plane, a one-cycle pulse: the CP's flip was taken (as cancelled). |
| `pending` | out | 2 | Per plane: a flip is pending. |
| `dc_err` | in | 2 | Pulses: [0] a record write failed, [1] a host write was refused (BAD_WRITE). |
| `idle` | out | 1 | No memory read of the DC outstanding. |
| `frame_count` | out | 32 | FRAME_COUNT. |
| `ev_vblank`, `ev_error`, `ev_hotplug` | out | 1 | One-cycle pulses: IRQ_STATUS VBLANK (also the CP's WAIT_VSYNC), DISP_ERROR, HOTPLUG. |
| `pclk_sel` | out | 1 | To the board's BUFGMUX (0 25.2 MHz, 1 74.25 MHz). |
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
| **Video outputs (pclk)** | | | |
| `tmds` | out | 30 | (pclk) TMDS symbols for the board's serialisers. |
| `px_rgb` | out | 24 | (pclk) Parallel pixel (ADV7511): RGB888, or {8'd0, C, Y} with PX_FMT = 1. |
| `px_de` | out | 1 | (pclk) DE. |
| `px_hs` | out | 1 | (pclk) HSYNC. |
| `px_vs` | out | 1 | (pclk) VSYNC. |
| **I2C (gclk; open drain through the board's IOBUF)** | | | |
| `scl_t` | out | 1 | Release SCL. |
| `scl_i` | in | 1 | SCL. |
| `sda_t` | out | 1 | Release SDA. |
| `sda_i` | in | 1 | SDA. |

43 ports; 32 counting the AMB port as one group (spec/README.md); a wiring module.

## 4. Behaviour

Wiring with the only clock crossing of the DC: am_afifo for pixels, am_sync for ENABLE and CTRL.RESET (to pclk: the 32-cycle dc_reset pulse resets the pixel side too, so both sides of am_afifo are reset together) and for the event toggles and the line number (to gclk), plus a 3-bit register for the toggle edges.  scan_sum/scan_words and the read errors go from the DMA to the registers.  The DC's CTRL.RESET resets the gclk side of the FIFO, the I2C master and the event synchronisers, and clears the DMA without its count of outstanding reads (the responses of reads issued before still come).  With `HAS_CURSOR` the cursor sits between the DMA's pixels and the pixel FIFO (no new clock crossing), takes `dma_done`, the frame start and CURSOR_POS/CTRL, and shares the AMB port (requester 0 the DMA, 1 the cursor); `idle` and the read errors cover both.  Without it `taken[1]`, `pending[1]` are 0.  The quasi-static configuration (timing, format, test pattern) goes to pclk directly (see atg_dc_regs §7).

## 5. State machine

None (wiring).

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_dc_tb.v` (it covers the clock crossings), driven as atg_cp_disp drives the DC: `PASS atg_dc.scanout` — frames compared with the image, VBLANK and FRAME_COUNT, a flip at once while disabled and one at a vsync (taken, FB_BASE), SCAN_WORDS, a read error (black lines, STATUS.read error, DISP_ERROR at most once a frame, W1C), ENABLE 0 with a pending flip (cancelled) and idle, RGB565, the cursor (a flip of plane 1, taken after its load through the shared port, CURSOR_BASE, frames unchanged under a transparent image), CTRL.RESET with a pending flip and reads on the way and frames after it — and `PASS atg_dc`.

## 9. References

design §5, §1.3 (pclk, pclk5).

## 10. Status

Wiring written in WS288 p023, completed in p005 (children implemented except atg_dc_i2c, p012).
WS288 p012 part A: atg_dc_i2c implemented; parameter `PX_FMT` and the child atg_dc_ycc added for
the KC705's 16-bit ADV7511 input (Q1 to ACK).  TMDS stays in the RTL; the KC705 top leaves it
unconnected (the tools remove it).  The VGA output (atg_dc_vga) was taken out with the ZYBO
target (2026-10-25; the source is kept under `docs/old/`): DC_CAPS[0] is 0.
WS288 p035 D3 (design §18.5): moved to `rtl/gpu/dc/` as a child of atg_top; the register bus is the
internal one, `atg_dc_mode` added, `STANDALONE`/`BASE` and the interrupt line are gone (the events
are pulses for IRQ_STATUS), the CP's flips and the record status ports added.  D5: the cursor plane (`HAS_CURSOR`, `atg_dc_cursor`).
