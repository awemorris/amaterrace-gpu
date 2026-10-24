# atg_dc

RTL: `rtl/dc/atg_dc.v`.  Parent: the board top (atg_kc705_raster, next to atg_top).  Implemented in: p005, p012.

## 1. Purpose and place

The display controller IP (design §5): registers and DMA in gclk, a pixel FIFO (am_afifo) to the pixel clock, timing generator, a TMDS encoder and a parallel output, optional I2C; its own AMB client port (an MC client of atg_top; STANDALONE: to its own am_axi_master).

Children: `atg_dc_regs`, `atg_dc_dma`, `atg_dc_tgen`, `atg_dc_tmds`, `atg_dc_ycc` (PX_FMT = 1), `atg_dc_i2c`, `am_afifo`, `am_sync`.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `STANDALONE` | `0` | 1: a DC-only GHCI device: GHCI header at 0x000, DISP registers at 0x200; 0: DISP registers at BASE (KC705 0x10000). |
| `BASE` | `17'h10000` | Window of the DISP registers when STANDALONE = 0. |
| `HAS_I2C` | `0` | ADV7511 I2C master present (KC705, DC_CAPS[2]). |
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
| `rst_n` | in | 1 | gclk reset. |
| `pclk` | in | 1 | (pclk) Pixel clock. |
| `prst_n` | in | 1 | (pclk) pclk reset (synchronised to pclk by the board). |
| **Register bus (am_axi_regs; the DC decodes its own window)** | | | |
| `reg_wr` | in | 1 | Write strobe. |
| `reg_waddr` | in | 17 | Byte address. |
| `reg_wdata` | in | 32 | Data. |
| `reg_wstrb` | in | 4 | Strobes. |
| `reg_rd` | in | 1 | Read strobe. |
| `reg_raddr` | in | 17 | Address. |
| `reg_rdata` | out | 32 | Data the cycle after reg_rd, 0 outside the window (so a top can OR it with the GPU's). |
| `irq` | out | 1 | Level interrupt (gclk). |
| `vsync` | out | 1 | One-cycle vsync pulse in gclk (WAIT_VSYNC). |
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

40 ports; 29 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Wiring with the only clock crossing of the DC: am_afifo for pixels, am_sync for ENABLE and CTRL.RESET (to pclk: the 32-cycle dc_reset pulse resets the pixel side too, so both sides of am_afifo are reset together) and for the event toggles and the line number (to gclk), plus a 3-bit register for the toggle edges.  scan_sum/scan_words go from the DMA to the registers.  The quasi-static configuration (timing, format, test pattern) goes to pclk directly (see atg_dc_regs §7).

## 5. State machine

None (wiring).

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_dc_tb.v` (added in p005; it covers the clock crossings): `PASS atg_dc.scanout` — frames compared with the framebuffer, vsync IRQ and FRAME_COUNT, a flip, SCAN_WORDS, RGB565, idle, CTRL.RESET — and `PASS atg_dc`.

## 9. References

design §5, §1.3 (pclk, pclk5).

## 10. Status

Wiring written in WS288 p023, completed in p005 (children implemented except atg_dc_i2c, p012).
WS288 p012 part A: atg_dc_i2c implemented; parameter `PX_FMT` and the child atg_dc_ycc added for
the KC705's 16-bit ADV7511 input (Q1 to ACK).  TMDS stays in the RTL; the KC705 top leaves it
unconnected (the tools remove it).  The VGA output (atg_dc_vga) was taken out with the ZYBO
target (2026-10-25; the source is kept under `docs/old/`): DC_CAPS[0] is 0.
