# atg_blt_rsv_px

RTL: `rtl/gpu/blt/atg_blt_rsv_px.v`.  Parent: `atg_blt_rsv`.  Children: two `am_fifo` (row descriptors, source lines), `atg_blt_avg`.

## 1. Purpose and place

The pixel path of the blitter's RESOLVE: takes row descriptors and the rows' source lines in order, averages the samples of each pixel and assembles the destination lines, which it hands back as writes.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | 32 | GPU address width |
| `LINE_BYTES`, `LINE_SHIFT` | 32, 5 | AMB line size, its log2 |
| `DEPTH_LOG2` | 2 | Source lines in the FIFO: 2^`DEPTH_LOG2` |
| `RD_W` | 32 + 51 + 5 | Descriptor width (`ADDR_W` + 51 + `LINE_SHIFT`) |

## 3. Ports

All in domain `clk`.

| Name | Dir | Width | Meaning, handshake, timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1, 1 | Clock, synchronous active-low reset |
| `stop` | in | 1 | Level: empty everything now (the FIFOs too), no write |
| `m16`, `fmt`, `tiled` | in | 1, 2, 1 | The mode (16-bit pixels, the average, a tiled destination); stable during a resolve |
| `rd_valid` / `rd_ready`, `rd_data` | in / out, in | 1, 1, `RD_W` | A row descriptor {off0, nlines, w, x, drow} (`atg_blt_rsv.md` §3); FIFO of 2 |
| `ln_push`, `ln_data` | in | 1, `LINE_BYTES*8` | A source line (no ready: the sender keeps the credit) |
| `ln_count` | out | `DEPTH_LOG2`+1 | Lines in the FIFO |
| `wr_valid` / `wr_ready`, `wr_line`, `wr_be`, `wr_data` | out / in, out | 1, 1, `ADDR_W-LINE_SHIFT`, `LINE_BYTES`, `LINE_BYTES*8` | A destination line write, held until taken |
| `idle` | out | 1 | Nothing queued or held |

16 ports (counting `rd_*`, `ln_*` and `wr_*` as listed).

## 4. Behaviour

- A row starts when no row is active: x, the pixels left, drow, the lines to load (nlines), the byte pointer (off0); the window (two lines w0, w1) empty.
- A line is loaded from the FIFO into the window's first empty slot while the row still has lines to load, so exactly nlines per row.
- A group per cycle: n pixels at x with n ≤ min(4, LINE_BYTES / (4·ps)), ≤ the pixels left, inside one destination line (linear: ≤ the line's rest / ps) or inside one tile row (tiled: ≤ 4 − x%4); its 4·n·ps source bytes at the pointer (w1 needed when they pass the end of w0).  The destination address: drow + x·ps (linear) or drow + (x/4)·16·ps + (x%4)·ps (tiled).  The pointer advances by 4·n·ps; past the end of w0 the window shifts.  At the row's last group the window is emptied.
- Stage A: the group's average (`atg_blt_avg`), its line, offset and bytes.  Stage B: the assembly line; a group of the same line merges (only its bytes: the average's other pixels are masked), of another line hands the assembly line over as a write (when the write register is free) and starts anew.  With nothing more queued (no row, no descriptor, stage A empty) the assembly line is handed over.

## 5. State machine

Implicit (active row, stage A, stage B, write register).

## 6. Latency and throughput

One group per cycle: 32-bit pixels, LINE_BYTES 64: 4 pixels (a source line) per cycle; LINE_BYTES 32: 2 pixels; 16-bit pixels: 4 pixels.

## 7. Corner cases and errors

- `MUT_RSV_SPLIT`: a linear group is not cut at the destination line's end.  `MUT_RSV_ROWEND`: a line is loaded although the row has none left (the next row's first line is taken).

## 8. What the TB checks

Through `sim/tb/atg_blt_rsv_tb.v` (`atg_blt_rsv.md` §8); its monitor fails a line pushed into a full FIFO.

## 9. References

design §15.8.  Related: `atg_blt_rsv.md`, `atg_blt_avg.md`, `spec/common/am_fifo.md`.

## 10. Status

Implemented (the MSAA work).
