# atg_dc_regs

RTL: `rtl/dc/atg_dc_regs.v`.  Parent: atg_dc.  Implemented in: p005.

## 1. Purpose and place

The DC's registers (design §5.1): DC_ID/VERSION/CAPS, CTRL, STATUS, IRQ, FB_*, timing, FRAME_COUNT, PCLK_SEL, the I2C window, and in the standalone bitstream the GHCI header that makes the DC a display-only GHCI device.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `STANDALONE` | `0` | 1: a DC-only GHCI device: GHCI header at 0x000, DISP registers at 0x200; 0: DISP registers at BASE (KC705 0x10000). |
| `BASE` | `17'h10000` | Window of the DISP registers when STANDALONE = 0. |
| `HAS_I2C` | `0` | ADV7511 I2C master present (KC705, DC_CAPS[2]). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Register bus (am_axi_regs; the DC decodes its own window)** | | | |
| `reg_wr` | in | 1 | Write strobe. |
| `reg_waddr` | in | 17 | Byte address. |
| `reg_wdata` | in | 32 | Data. |
| `reg_wstrb` | in | 4 | Strobes. |
| `reg_rd` | in | 1 | Read strobe. |
| `reg_raddr` | in | 17 | Address. |
| `reg_rdata` | out | 32 | Data the cycle after reg_rd, 0 outside the window (so a top can OR it with the GPU's). |
| **Configuration to atg_dc_dma and atg_dc_tgen** | | | |
| `enable` | out | 1 | CTRL.ENABLE (quasi-static, see §4). |
| `test_pattern` | out | 1 | CTRL.TEST_PATTERN. |
| `format` | out | 2 | CTRL.FORMAT. |
| `fb_next` | out | 32 | FB_NEXT. |
| `fb_stride` | out | 32 | FB_STRIDE. |
| `fb_size` | out | 32 | FB_SIZE. |
| `timing` | out | 288 | H_ACTIVE, H_FP, H_SYNC, H_BP, V_ACTIVE, V_FP, V_SYNC, V_BP, SYNC_POL (word 0 in [31:0]). |
| `pclk_sel` | out | 1 | PCLK_SEL[0] (to the board's clock mux). |
| `dc_reset` | out | 1 | CTRL.RESET pulse (gclk). |
| **Status (gclk, already synchronised by atg_dc)** | | | |
| `ev_vsync` | in | 1 | Vsync pulse. |
| `ev_flip` | in | 1 | FB_NEXT was taken at this vsync. |
| `ev_underflow` | in | 1 | Underflow pulse. |
| `dma_idle` | in | 1 | No DMA outstanding. |
| `line` | in | 12 | Current line (approximate, synchronised). |
| `scan_sum` | in | 32 | From atg_dc_dma: sum of the last frame's pixel words (SCAN_SUM). |
| `scan_words` | in | 32 | From atg_dc_dma: pixel words of the last frame (SCAN_WORDS). |
| `fb_base` | out | 32 | FB_BASE: the frame being scanned (updated at ev_flip). |
| `irq` | out | 1 | Level interrupt. |
| **I2C window (to atg_dc_i2c)** | | | |
| `i2c_we` | out | 1 | Write. |
| `i2c_idx` | out | 2 | 0 CTRL, 1 DATA, 2 STATUS. |
| `i2c_wdata` | out | 32 | Data. |
| `i2c_rdata` | in | 32 | Data (combinational). |

31 ports (scan_sum and scan_words added in p005, Q1 to ACK).

## 4. Behaviour

Register map of design §5.1 (offsets from the DISP base; the window is 128 bytes, 128-byte aligned).  FRAME_COUNT counts ev_vsync.  CTRL.RESET (W1S) raises dc_reset for 32 cycles (so that atg_dc can carry it to pclk and reset both sides of the pixel FIFO) and clears ENABLE, IRQ_STATUS, the sticky underflow, FRAME_COUNT and a pending flip; the configuration registers keep their values.  STATUS: [0] ENABLE, [1] underflow (sticky; cleared by RESET and when ENABLE goes 0 → 1), [2] idle = ENABLE 0 and dma_idle, [15:4] line.  FB_NEXT written while ENABLE = 1 makes a flip pending: at the next ev_flip (a vsync) FB_BASE takes it and FLIP_DONE is raised; written while ENABLE = 0 (no vsyncs) it sets FB_BASE at once.  Amaterrace's debug registers after the I2C window: 0x70 SCAN_SUM and 0x74 SCAN_WORDS (R, scan_sum and scan_words).  I2C reads give i2c_rdata only with HAS_I2C.  IRQ_STATUS [0] VSYNC [1] UNDERFLOW [2] FLIP_DONE, W1C; irq = OR(status & enable).  Standalone header: MAGIC, VERSION, VENDOR "AMAT", DEVICE "ATDC", ISA 0, CAPS = bit 3 only, EXTCAP → one DISP entry pointing to 0x200.

## 5. State machine

None.

## 6. Latency and throughput

Register read latency 1.

## 7. Corner cases and errors

- The timing and FB_STRIDE/SIZE are quasi-static: the driver changes them only with ENABLE = 0; atg_dc_tgen samples them in pclk without a synchroniser (documented exception: they are stable for many cycles before ENABLE, which crosses through am_sync).

## 8. What the TB checks

`sim/tb/atg_dc_regs_tb.v` prints, in this order:

- `PASS atg_dc_regs.map` — every register
- `PASS atg_dc_regs.header` — STANDALONE header and EXTCAP
- `PASS atg_dc_regs.irq` — W1C and the line
- `PASS atg_dc_regs` at the end.

## 9. References

design §5.1, §2.2 (EXTCAP DISP).

## 10. Status

Implemented in WS288 p005 (TB `atg_dc_regs_tb` PASS).
