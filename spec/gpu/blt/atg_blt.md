# atg_blt

RTL: `rtl/gpu/blt/atg_blt.v`. Written from the RTL at amaterrace-gpu main a217bf8 (WS288 p023 part 2); the RTL is authoritative.

## 1. Purpose and place

The blitter (WS288 p003): FILL, COPY, TILE and UNTILE of rectangles of 16- or 32-bit pixels, with blend-over, the reverse direction and clipping, through one AMB port. It takes its parameters from the BLT range of STATE (0x000–0x00A) as the CP writes them (`st_we`) and runs one blit per kick. Parent: `atg_top` (instance `blt`, MC client 1, reset by the CP's `core_rst_n`). Children: none (see §10 for the proposed split).

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `ADDR_W` | 32 | GPU address width | 32 |
| `LINE_BYTES` | 32 | AMB line size | 32 (ZYBO), 64 (KC705) |
| `LINE_SHIFT` | 5 | log2(`LINE_BYTES`) | 5, 6 |

Derived: `WPL` = 32-bit words per line, `LU` = 16-bit units per line, `UA` = `ADDR_W` − 1 (unit address width).

## 3. Ports

All in domain `clk`. 22 ports.

| Name | Dir | Width | Meaning, handshake, timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Core clock |
| `rst_n` | in | 1 | Synchronous active low; `atg_top` connects the CP's `core_rst_n` (board reset or CTRL.RESET pulse). Also clears the shadow STATE copy |
| `st_we`, `st_idx`, `st_wdata` | in | 1, 9, 32 | STATE write pulse from the CP; indices 0x000–0x00A are copied, others ignored |
| `kick` | in | 1 | One-cycle pulse: start a blit with the current shadow STATE. Ignored while busy (the CP faults such a KICK before it gets here) |
| `busy` | out | 1 | Level: state ≠ IDLE, from the cycle after the kick to the cycle of `done`/`error` |
| `done` | out (reg) | 1 | One-cycle pulse: the blit finished and every request was answered |
| `error`, `error_kind` | out (reg) | 1, 4 | One-cycle pulse and FAULT_INFO kind: 2 (OPCODE) the cycle after a kick of an unsupported combination (busy stays 0); 5 (AXI) at the end of a blit that saw an error response |
| `req_valid` / `req_ready` | out / in | 1 | AMB request handshake; the request is a register (`q_*`) held until ready |
| `req_write`, `req_line`, `req_be`, `req_wdata` | out | 1, `ADDR_W-LINE_SHIFT`, `LINE_BYTES`, `LINE_BYTES*8` | The request. Reads use all enables; writes cover only the segment's units |
| `req_tag` | out | 8 | `{5'd0, write, slot}`; slot 0/1 the two source line buffers, 2 the destination line buffer (blend) |
| `rsp_valid` | in | 1 | This client's response pulse (no back-pressure) |
| `rsp_write`, `rsp_tag`, `rsp_rdata`, `rsp_error` | in | 1, 8, `LINE_BYTES*8`, 1 | Response fields; a read's `rsp_tag[1:0]` selects the buffer |

## 4. Behaviour

STATE fields (docs/ghci.md §8): OP ([1:0] 0 FILL, 1 COPY, 2 TILE, 3 UNTILE; [4] blend; [9:8] bpp 0 = 32, 1 = 16; [12] reverse), DST_BASE, DST_STRIDE, SRC_BASE, SRC_STRIDE (bytes; low bits below the pixel size ignored), DST_XY, SRC_XY, SIZE (`[15:0]` x/width, `[31:16]` y/height), COLOR, CLIP_MIN (inclusive), CLIP_MAX (exclusive; 0 = no clip). Other OP bits are ignored.

- Accepted combinations: bpp 0 or 1; blend only with 32-bit FILL or COPY; reverse only with FILL or COPY. Anything else → `error` kind 2 at the kick, no memory access.
- Clip: the destination rectangle is intersected with [CLIP_MIN, CLIP_MAX) when CLIP_MAX ≠ 0 (computed combinationally, registered at the kick, S_CLIP); the source origin moves with it. An empty result finishes with `done` and no access.
- Walk: rows top to bottom (reverse: bottom to top), pixels left to right (reverse: right to left), in 16-bit units. Each row is cut into segments that stay inside one destination line, inside one 4-pixel row of a tile for a tiled destination, and inside one tile row of a tiled source. The row address is base + y × stride by a shift-and-add multiplier (S_MUL, once per blit); the next rows add the stride (tiled: the next row inside the tile, or stride − 12 pixels after the fourth).
- 4x4 tiles (CAPS[11]): pixel (x, y) at base + (y/4)·stride + (x/4)·16·ps + ((y%4)·4 + x%4)·ps.
- FILL: the segment's write (COLOR replicated, enables of the segment) is queued and the walk continues: writes stream up to the MC's limit.
- COPY, TILE, UNTILE: before reading, **wait until every earlier write of this blit is answered** (`wr_out` = 0), then read the one or two source lines covering the segment, wait for them, shift the 2-line window by whole units to align with the destination line, write.
- Blend-over (32-bit FILL/COPY): also read the destination line (after the writes are answered), then a 3-stage pipeline over the line's words: out = src + round(dst × (255 − src.a) / 255) per byte, saturated at 255, written back into the destination buffer, then the write (enables of the segment only).
- Under the MC's quiesce the pending request waits and the blit continues where it stopped.
- After an error response (`fail`) no new request is made; the blit drains every outstanding request and then pulses `error` kind 5.

## 5. State machine

One FSM (`state`, 15 states):

- `S_IDLE` →(kick, unsupported)→ `S_IDLE` with `error` kind 2; →(kick, supported: latch mode and clipped rectangle)→ `S_CLIP`
- `S_CLIP` →(empty rectangle)→ `S_IDLE` with `done`; →(else: width, rows, source origin)→ `S_START`
- `S_START` →(first row and pixel, multiplier operands)→ `S_MUL`
- `S_MUL` →(both multipliers done)→ `S_SA`; else stay (one bit per cycle)
- `S_SA` →(`fail`)→ `S_DRAIN`; →(pixel unit addresses)→ `S_SB` →(segment length)→ `S_SC` →(first units, reverse adjusted)→ `S_SD` →(line, offset, source lines)→ `S_CRD` if copy / `S_DRD` if blend fill / `S_WR` if fill
- `S_CRD` →(`fail`)→ `S_DRAIN`; →(no request pending, `wr_out` = 0: issue first, then second source read)→ … →(both issued)→ `S_CWAIT`
- `S_CWAIT` →(`fail`)→ `S_DRAIN`; →(`rd_out` = 0)→ `S_DRD` if blend, else `S_WR`
- `S_DRD` →(`fail`)→ `S_DRAIN`; →(`wr_out` = 0: issue destination read)→ `S_DWAIT` →(`rd_out` = 0)→ `S_BLEND` (`fail` → `S_DRAIN`)
- `S_BLEND` →(all words through the 3 stages)→ `S_WR`
- `S_WR` →(`fail`)→ `S_DRAIN`; →(no request pending: queue the write)→ `S_SA` for the next segment or row; →(it was the last segment of the last row)→ `S_DRAIN`
- `S_DRAIN` →(no request pending, `wr_out` = `rd_out` = 0, no response this cycle)→ `S_IDLE` with `done`, or `error` kind 5 if `fail`

## 6. Latency and throughput

- Per segment: 4 cycles of address computation (S_SA–S_SD) + 1 (S_WR) for FILL. Per blit: S_CLIP, S_START and up to 17 S_MUL cycles.
- Measured on the ZYBO (p003, 1024 × 256 = 1 MiB, PERF0 = busy cycles, 100 MHz):

| Operation | cycles | MB/s | cycles per 32-byte line |
| --- | --- | --- | --- |
| FILL 32 bpp / 16 bpp | 163,864 | 640 | 5.0 |
| COPY 32 bpp aligned / reverse / 16 bpp | 1,628,691 | 64 | 49.7 |
| COPY 32 bpp, source 1 pixel off (2 line reads) | 1,760,324 | 60 | 53.7 |
| FILL + blend | 1,929,072 | 54 | 58.9 |
| COPY + blend | 2,955,814 | 35 | 90.2 |
| TILE 32 bpp (4-pixel segments) | 3,165,985 | 33 | 96.6 |

- COPY is bound by the serial wait → read → write per segment (HP0 read latency plus the write response round trip).
- Timing: 100 MHz on the ZYBO with WNS +0.190 ns; the worst path starts at `q_valid` into the MC.

## 7. Corner cases and errors

- Empty rectangle (width or height 0, or clipped away): `done` without memory access. A CLIP_MAX with one component 0 and the other not enables clipping and gives an empty x (or y) range.
- Overlapping COPY: correct only in the right direction (forward when the destination starts before the source, reverse when after); the wrong direction smears exactly as the TB's model says (each segment reads what earlier segments wrote).
- Address arithmetic wraps at 32 bits silently; the MC's aperture check catches accesses outside.
- An aperture refusal: the CP records the MC's fault first (kind 1) and quiesces; the BLT stays busy with its next request held until RESET. An AXI error alone gives kind 5 after the drain, with no address.
- Kick while busy: ignored here (the CP faults it).
- Blend with a source channel above its alpha saturates at 255.
- Strides and widths are not checked against each other; rows may overlap.

## 8. What the TB checks

No `sim/tb/atg_blt_tb.v`. Checked through `sim/tb/atg_top_tb.v` (`PASS atg_top`, ZYBO and KC705 shapes, against a reference model in which every source pixel is read before any is written; `sim/models/axi_mem.v` with `READ_EARLY`, so a read may overtake a write): FILL, COPY at several alignments, clipped FILL; 16-bit FILL at an odd pixel and COPY; blend FILL and COPY (with saturation); TILE then UNTILE back; 16-bit TILE; overlapping COPY reverse, forward, 16-bit reverse by one pixel; reverse clipped FILL; the wrong-direction "smear" (fails if reads do not wait for earlier writes: checked by mutation in p003); 120 random blits of every kind and option (`+seed`, p003 also 2, 3, 42); HALT in the middle of a COPY and resume; aperture fault → RESET → FILL; OPCODE faults (pixel size 2, tile blend). The Verilator harness checks a FILL and a COPY. On the ZYBO (p003) `ghci-blt-board.py` checks every operation 5 times. Not checked: AXI error responses (kind 5), the shadow STATE after RESET, coordinates near 65535, address wrap.

## 9. References

- design.md §2.3 (BLT STATE range), §3.6 (BLT LUTs: 1.0k estimated, 2.73k measured), §7.6 (split if > 400 lines: `atg_blt_rd`/`atg_blt_wr`/`atg_blt_ctl`).
- `docs/ghci.md` §8 (BLT STATE, operations, tiles, overlap direction, fault kind 2), §11 (KICK).
- Related specs: `spec/gpu/cp/atg_cp.md` (STATE, KICK, faults), `spec/gpu/mc/atg_mc.md` (AMB port, no read-after-write order).

## 10. Status

Implemented (p002 70aaff5 and 053c1ba, rewritten in p003 a2af156, simple wait restored a6e6d16; unchanged at a217bf8). Measured on the ZYBO (p003): 2,727 LUT, 2,196 FF, DSP 0 (the four 8 × 8 products are LUTs).

**U38: 696 lines > 400.** 22 ports and one clock are fine; there is one encoded FSM, but the blend pipeline, the multiplier and the AMB port bookkeeping live beside it. Not refactored here. Proposed split (design §7.6 names `atg_blt_ctl`/`atg_blt_rd`/`atg_blt_wr`; a fourth for the port keeps each part small):

| Module | Content (from the current RTL) | Est. lines |
| --- | --- | --- |
| `atg_blt_ctl` | Shadow STATE, op check, clip, the walk FSM (S_IDLE–S_SD and the advance of S_WR), multiplier; emits a segment descriptor (line, first unit, units, source lines, shift, slot, mode) with valid/ready; takes "segment written" and `fail` | ~330 |
| `atg_blt_rd` | Waits for `wr_out` = 0, issues the 1–2 source reads and the destination read, holds `buf0`/`buf1`/`bufd`, the 2-line shifter (`copy_line`) | ~150 |
| `atg_blt_wr` | The blend pipeline, fill/copy/blend line select, byte enables (`seg_be`), the write request | ~140 |
| `atg_blt_port` (or inside `atg_blt`) | The single AMB request register (rd/wr mux), `wr_out`/`rd_out`, response routing by tag, `fail` | ~80 |
| `atg_blt` | Wiring, `busy`/`done`/`error` | ~100 |

Known limitations and residuals:

1. **COPY waits for every earlier write** before each read (correct for overlaps, slow: 64 MB/s). A table of 8 written lines (wait only for writes to the lines read) was tried in p003: 19% faster for +0.75k LUT, not kept.
2. **Read prefetch residual**: reads are issued one segment at a time; issuing reads several segments ahead (a request FIFO and a separate data path) is the residual from p003 (Q1's decision when).
3. **Shadow STATE is cleared by CTRL.RESET** while the STATE BRAM keeps its values (ghci.md §4 says STATE survives): after RESET the host must rewrite the BLT range before the next KICK. Difference from the spec of GHCI; fix in an implementation Phase (e.g. reset the shadow with the board reset only, or have the CP replay).
4. A memory error reports kind 5 with no address or direction.
