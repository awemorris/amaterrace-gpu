# atg_dc_regs

RTL: `rtl/gpu/dc/atg_dc_regs.v`.  Parent: atg_dc.  Implemented in: p005; DISP2 (p035 D3).

## 1. Purpose and place

The DC's scan-out registers of the DISP2 window (docs/ghci.md §13.2): DC_ID/VERSION/CAPS, CTRL, STATUS, FB_*, the timing, FRAME_COUNT, PCLK_SEL, the I2C window and Amaterrace's SCAN_SUM/SCAN_WORDS; plane 0's pending flip; the events VBLANK and DISP_ERROR.  The other registers of the window are `atg_dc_mode`'s (mode table, CONNECTED, cursor) and `atg_cp_disp`'s (STATUS[31], TAKEN0/1).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `HAS_I2C` | `0` | ADV7511 I2C master present (KC705, DC_CAPS[2]). |
| `HAS_CURSOR` | `0` | The cursor plane (DC_CAPS[8]). |

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | gclk; the board reset. |
| `d_we`, `d_idx`, `d_wdata`, `d_wmask` | in | 1, 6, 32, 32 | The DC's internal bus: a write (one cycle) of word `d_idx` of the window under the bit mask; every write that comes is taken (atg_cp_disp has checked who writes). |
| `d_ridx` | in | 6 | Read index. |
| `d_rdata` | out | 32 | This module's word at `d_ridx`, combinational; 0 for the words it does not hold. |
| `enable`, `test_pattern`, `format` | out | 1, 1, 2 | CTRL (quasi-static, §7). |
| `fb_base` | out | 32 | FB_BASE: plane 0's image. |
| `fb_stride`, `fb_size` | out | 32 | FB_STRIDE, FB_SIZE. |
| `timing` | out | 288 | H_ACTIVE .. V_BP, SYNC_POL (word 0 in [31:0]). |
| `pclk_sel` | out | 1 | PCLK_SEL[0] (the board's clock mux). |
| `dc_reset` | out | 1 | CTRL.RESET, a level for 32 cycles. |
| `flip_valid`, `flip_base` | in | 1, 32 | One-cycle pulse: a flip of plane 0 by the CP. |
| `taken`, `taken_cancel` | out | 1, 1 | One-cycle pulse the cycle after: a flip of the CP was taken (cancelled). |
| `pending` | out | 1 | Plane 0 has a pending flip (the CP's or the host's). |
| `ev_vsync`, `ev_underflow` | in | 1 | Pulses from atg_dc_tgen (synchronised). |
| `idle_in` | in | 1 | No memory read of the DC outstanding (DMA and cursor). |
| `line` | in | 12 | The current line (approximate). |
| `scan_sum`, `scan_words` | in | 32 | atg_dc_dma's SCAN_SUM/SCAN_WORDS. |
| `rd_err` | in | 1 | Pulse: a scan-out read had an error response. |
| `dc_err` | in | 2 | Pulses from atg_cp_disp: [0] record error, [1] BAD_WRITE. |
| `connected`, `pending1` | in | 1 | STATUS[28] and [30]. |
| `ev_vblank` | out | 1 | VBLANK: `ev_vsync` while ENABLE is 1. |
| `ev_error` | out | 1 | DISP_ERROR pulse. |
| `frame_count` | out | 32 | FRAME_COUNT (for the records). |
| `i2c_we`, `i2c_idx`, `i2c_wdata`, `i2c_rdata` | out, out, out, in | 1, 2, 32, 32 | To atg_dc_i2c. |

39 ports.

## 4. Behaviour

- CTRL: ENABLE, RESET (W1S), TEST_PATTERN, FORMAT, OUTPUT.  CTRL.RESET raises `dc_reset` for 32 cycles and clears ENABLE, the sticky status, FRAME_COUNT and a pending flip (a flip of the CP is taken as cancelled); the configuration keeps its values.
- Refusals (BAD_WRITE): a write of the timing, FB_STRIDE, FB_SIZE or PCLK_SEL while ENABLE is 1, and a write of CTRL that keeps ENABLE 1 with another FORMAT (its other bits are taken).
- STATUS: [0] ENABLE, [1] underflow, [2] idle (ENABLE 0 and `idle_in`), [3] read error, [4] record error, [5] BAD_WRITE ([1], [3]-[5] sticky, W1C; a set and a clear in the same cycle leave it set; [1] is also cleared when ENABLE goes 0 → 1), [27:16] line, [28] `connected`, [29] `pending`, [30] `pending1`, [31] 0 (atg_cp_disp ORs its own).
- Plane 0: `flip_valid` or a write of FB_NEXT while ENABLE is 1 (and does not fall in that cycle) makes FB_NEXT pending, taken at the next `ev_vsync` (FB_BASE = FB_NEXT); while ENABLE is 0 it sets FB_BASE at once (a flip of the CP is then taken at once).  ENABLE falling takes a pending flip as cancelled; a write of FB_NEXT over a flip of the CP takes that one as cancelled and makes the host's pending.  `taken` pulses only for the CP's flips.
- DISP_ERROR: a pulse when one of the sticky errors is set; while ENABLE is 1 at most once between two vsyncs, while it is 0 at every error.
- FRAME_COUNT counts `ev_vsync`.  Amaterrace's 0x70 SCAN_SUM and 0x74 SCAN_WORDS (R).  I2C reads give `i2c_rdata` only with `HAS_I2C`.  DC_VERSION 0.2; DC_CAPS [1] TMDS or [2] the transmitter, [7:4] 0111, [8] `HAS_CURSOR`, [11:9] 2.

## 5. State machine

None.

## 6. Latency and throughput

Reads are combinational from `d_ridx`; a write takes effect in its cycle.

## 7. Corner cases and errors

- The timing and FB_STRIDE/SIZE are quasi-static: they change only with ENABLE = 0 (now enforced); atg_dc_tgen samples them in pclk without a synchroniser (they are stable for many cycles before ENABLE, which crosses through am_sync).
- A flip and ENABLE falling in the same cycle: the flip is taken at once (not left pending without vsyncs).

## 8. What the TB checks

`sim/tb/atg_dc_regs_tb.v` prints, in this order:

- `PASS atg_dc_regs.map` — every register, strobes, the outputs, the words of other modules read 0, STATUS's fields
- `PASS atg_dc_regs.bad` — the refusals while ENABLE is 1 and BAD_WRITE, one DISP_ERROR for several in a frame, a FORMAT change with ENABLE 0 in the same write is taken
- `PASS atg_dc_regs.flip` — at once while disabled, at a vsync, cancelled by ENABLE falling, by a host FB_NEXT (the host's image then taken without `taken`) and by CTRL.RESET
- `PASS atg_dc_regs.status` — the sticky bits, W1C, set wins, DISP_ERROR once a frame and at every error while disabled, underflow cleared by ENABLE 0 → 1, FRAME_COUNT, VBLANK, CTRL.RESET's pulse and what it clears
- `PASS atg_dc_regs` at the end.

## 9. References

docs/ghci.md §13.2; design §18.5.

## 10. Status

Implemented in WS288 p005; DISP2 in p035 D3 (the internal bus, plane 0's flips of the CP, the new STATUS, BAD_WRITE, DISP_ERROR; the standalone GHCI header, IRQ_STATUS/IRQ_ENABLE and `STANDALONE`/`BASE` are gone).  About 320 lines.

WS288 p037 (2026-10-25): the arithmetic is am_ modules (docs/style.md), function unchanged (equal to the former module on 200,000 random cycles).
