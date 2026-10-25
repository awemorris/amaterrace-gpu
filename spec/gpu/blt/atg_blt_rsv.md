# atg_blt_rsv

RTL: `rtl/gpu/blt/atg_blt_rsv.v`.  Parent: `atg_blt` (with `MS4`, instance `g_rsv.rsv`).  Child: `atg_blt_rsv_px` (the pixel path).

## 1. Purpose and place

The blitter's RESOLVE (docs/ghci.md §8.2, BLT_OP[2:0] = 4): converts a 4x multisampled source rectangle to one sample per pixel, streaming the source lines at the rate of the port.  It walks the rows, reads the source lines, and owns the AMB request register; `atg_blt_rsv_px` averages and assembles the destination lines.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `ADDR_W` | 32 | GPU address width | 32 |
| `LINE_BYTES` | 32 | AMB line size | 32, 64 |
| `LINE_SHIFT` | 5 | log2(`LINE_BYTES`) | 5, 6 |
| `DEPTH_LOG2` | 2 | The source line FIFO of `atg_blt_rsv_px`: 2^`DEPTH_LOG2` lines | ≥ 1 (deeper with an AXI master of more outstanding reads) |

## 3. Ports

All in domain `clk`; those of `atg_blt` (`atg_blt.md` §3).  22 ports.

Widths inside: a row's source bytes 4·w·ps up to 21 bits, its source lines up to 17 bits (w = 65535, ps 4); the row descriptor to the pixel path is {off0 `LINE_SHIFT`, nlines 17, w 17, x 17, drow 32} (`ADDR_W` + 51 + `LINE_SHIFT` bits).

## 4. Behaviour

- STATE copy: `atg_blt_cfg` (BLT_OP, DST/SRC_BASE and _STRIDE, DST/SRC_XY, SIZE, CLIP_MIN/MAX, BLT_RESOLVE).  Bases and strides lose their bits below ps (destination) and 4·ps (source); ps = 1 to 16 bytes (BLT_OP[9:8], [13], docs/ghci.md §8.5).
- Taken at the kick: BLT_OP[2:0] = 4, no blend ([4]), no reverse ([12]), no KEEP ([19:16]), a valid pixel size, BLT_RESOLVE[3:0] = 2 (4 samples), BLT_RESOLVE[7:4] with a pixel size it takes: 0 UNORM8 8, 16, 32 bits; 1 UNORM565 16; 2 SAMPLE0 all; 3 SRGB8_A8 32; 4 SFLOAT16 16, 32, 64; 5 SFLOAT32 32, 64, 128; 6 UNORM2_10_10_10 32; 7 UNORM1555 16; a tiled destination (BLT_RESOLVE[8]) only with 16- and 32-bit pixels.  Anything else: `error` kind OPCODE the next cycle, busy 0, no access.
- Clip as `atg_blt_2d`: the destination rectangle ∩ [CLIP_MIN, CLIP_MAX) when CLIP_MAX ≠ 0, the source moves with it; empty → `done`, no access.
- Rows: src_row = SRC_BASE + sy·SRC_STRIDE, dst_row = DST_BASE + dy·DST_STRIDE (tiled: + (dy/4)·DST_STRIDE + (dy%4)·4·ps), by two `atg_blt_acc` once; the next row adds SRC_STRIDE and DST_STRIDE (tiled: 4·ps, or DST_STRIDE − 12·ps after dy%4 = 3).  Per row: first = src_row + sx·4·ps, its line and offset, nlines = the lines of [first, first + w·4·ps); the descriptor goes to the pixel path, then the row's lines are read in order.
- The request register takes a request in a cycle when it is empty or fires, a write of the pixel path first, else the next read when `held` (reads in flight + lines in the pixel path's FIFO + a read in the register) < 2^`DEPTH_LOG2`: the responses have no ready and come in order (`atg_mc.md` §4).  Tags: {7'd0, write}.
- An error response: `fail`; no new request, the pixel path stopped (`stop`, which empties it and its FIFOs), responses no longer pushed; when nothing is outstanding, `error` kind AXI.
- Source and destination must not overlap (no read waits for a write).

## 5. State machine

One FSM: `S_IDLE` →(kick, refused)→ `S_IDLE` (error kind 2) / →(kick, taken: mode and clipped rectangle)→ `S_CLIP` →(empty)→ `S_IDLE` (done) / → `S_MUL` →(both multipliers 0)→ `S_RCALC` (the row's descriptor and lines) → `S_RISSUE` →(descriptor taken, lines read; last row)→ `S_DRAIN` / →(next row)→ `S_RCALC`.  `fail` in `S_MUL`, `S_RCALC`, `S_RISSUE` → `S_DRAIN`.  `S_DRAIN` →(pixel path idle or `fail`, register empty, nothing outstanding, no response this cycle)→ `S_IDLE` with done, or error kind 5.

## 6. Latency and throughput

- Per blit: kick, clip, up to 17 multiplier cycles.  Per row: 2 cycles (descriptor) plus the reads.
- With latency 1 and ready always 1 (the TB's stream case): 4x, 32-bit, LINE_BYTES 64, aligned, 64×16: 381 cycles for 64 destination lines (≈6 per line: 4 reads and 1 write per line, plus the rows); LINE_BYTES 32: 701 for 128 (≈5.5).
- On the MC the reads in flight are bounded by the AXI master's outstanding transactions (4); the design's estimate is in design §15.8.

## 7. Corner cases and errors

- Rows sharing a line (strides below `LINE_BYTES`): the shared source line is read once per row; the destination's merge in the pixel path.
- Quiesce: the request waits.  Reset (`core_rst_n`): IDLE, the pixel path empty.
- Mutations: `MUT_RSV_CREDIT` (no read credit), with the pixel path's `MUT_RSV_SPLIT`, `MUT_RSV_ROWEND` and `atg_blt_avg`'s `MUT_RSV_RNE`.

## 8. What the TB checks

`sim/tb/atg_blt_rsv_tb.v` (`atg_blt` with `MS4`, LINE_BYTES 32 and 64 at once, and one instance without `MS4`; a memory with random latency, random ready with bursts of 0, error responses above 0x8000; the whole memory compared with a reference written in the TB from ghci §8.2 after each case) prints, in this order:

- `PASS atg_blt_rsv.unorm8`, `.rgb565`, `.sample0` — fixed rectangles of each average
- `PASS atg_blt_rsv.offset` — source and destination x of other alignments, strides not of whole lines
- `PASS atg_blt_rsv.tiled` — a 4x4 tiled destination, both pixel sizes
- `PASS atg_blt_rsv.clip` — the clip rectangle, and one clipped away (no request)
- `PASS atg_blt_rsv.rowshare` — rows that share source and destination lines
- `PASS atg_blt_rsv.random` — 60 random cases (`+seed`)
- `PASS atg_blt_rsv.stream` — latency 1, ready 1: ≤ 7 cycles per destination line; latency 40 with the port blocked half of the time: the source line FIFO never takes a push when full
- `PASS atg_blt_rsv.fault` — the refused combinations (kind 2, no request), error responses (kind 5 after the drain), then a normal resolve
- `PASS atg_blt_rsv.2d` — FILL, RESOLVE, COPY, RESOLVE in turn
- `PASS atg_blt_rsv.halt` — the port held at 0 for 300 cycles in the middle
- `PASS atg_blt_rsv.nms4` — without `MS4`: RESOLVE is kind 2, FILL and COPY work
- `PASS atg_blt_rsv` at the end.

Each mutation fails some of them: `MUT_RSV_RNE`, `MUT_RSV_SPLIT`, `MUT_RSV_RSP` (`.2d`), `MUT_RSV_ROWEND` and `MUT_RSV_CREDIT` (no final PASS: lost or extra lines).

## 9. References

docs/ghci.md §8.2, §12.11; design §15.7 (the multisampled layout), §15.8 (the resolve).  Related: `atg_blt.md`, `atg_blt_rsv_px.md`, `atg_blt_avg.md`, `atg_blt_2d.md`, `spec/gpu/mc/atg_mc.md`.

## 10. Status

Implemented (the MSAA work).  2026-10-25: pixels of 1 to 16 bytes, the averages 3-7 (`atg_blt_favg` for 3-5, `atg_blt_avg` for 6 and 7), the state in `atg_blt_cfg` and the row addresses in `atg_blt_acc` (below 400 lines); `sim/tb/atg_blt_tb.v` (`atg_blt.md` §8) checks the new combinations, `atg_blt_rsv_tb`'s refused example of SRGB8_A8 moved to the average 8.
