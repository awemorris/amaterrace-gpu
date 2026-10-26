# atg_blt_2d

RTL: `rtl/gpu/blt/atg_blt_2d.v` (it was `atg_blt` until the blitter got its RESOLVE engine; only the module's name changed). Written from the RTL at amaterrace-gpu main a217bf8 (WS288 p023 part 2); the RTL is authoritative.

## 1. Purpose and place

The blitter: FILL, COPY, TILE and UNTILE of rectangles of 8-, 16-, 32-, 64- or 128-bit pixels (TILE and UNTILE: 16 and 32 bits), with blend-over (32 bits), KEEP (32-bit FILL and COPY), the reverse direction and clipping, through one AMB port. It takes its parameters from the BLT range of STATE (0x000–0x00A, 0x00C–0x00E) as the CP writes them (`st_we`, kept by `atg_blt_cfg`) and runs one blit per kick. Parent: `atg_blt` (instance `b2d`; `atg_blt` is `atg_top`'s instance `blt`, MC client 1, reset by the CP's `core_rst_n`). It gets the kicks with BLT_OP[2] = 0 and only the responses of its own requests. Children: `atg_blt_cfg` (the state, the operation's checks, the clip, the FILL line), `atg_blt_seg` (the segment geometry and byte enables), `atg_blt_port` (the request register, the outstanding counts, the line buffers), `atg_blt_blend` (blend-over), two `atg_blt_acc` (the row addresses).

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `ADDR_W` | 32 | GPU address width | 32 |
| `LINE_BYTES` | 32 | AMB line size | 32 (ZYBO), 64 (KC705) |
| `LINE_SHIFT` | 5 | log2(`LINE_BYTES`) | 5, 6 |

The walk is in bytes (`US` = `LINE_SHIFT`).

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

STATE fields (docs/ghci.md §8.2, §8.5): OP ([1:0] 0 FILL, 1 COPY, 2 TILE, 3 UNTILE; [4] blend; [9:8] pixel size 0 = 32, 1 = 16, 2 = 64, 3 = 8 bits, [13] with [9:8] = 0 128 bits; [12] reverse; [19:16] KEEP), DST_BASE, DST_STRIDE, SRC_BASE, SRC_STRIDE (bytes; low bits below the pixel size ignored), DST_XY, SRC_XY, SIZE (`[15:0]` x/width, `[31:16]` y/height), COLOR and COLOR1-3 (the FILL pixel's words), CLIP_MIN (inclusive), CLIP_MAX (exclusive; 0 = no clip). Other OP bits are ignored.

- Accepted combinations (`atg_blt_cfg`): every pixel size but [13] with [9:8] ≠ 0; blend only with 32-bit FILL or COPY; reverse only with FILL or COPY; TILE and UNTILE with 16- and 32-bit pixels; KEEP only with 32-bit FILL and COPY without blend. Anything else → `error` kind 2 at the kick, no memory access.
- KEEP: byte b of every 32-bit pixel with KEEP[b] = 1 is not written (the write's byte enables; no read).
- Clip: the destination rectangle is intersected with [CLIP_MIN, CLIP_MAX) when CLIP_MAX ≠ 0 (computed combinationally, registered at the kick, S_CLIP); the source origin moves with it. An empty result finishes with `done` and no access.
- Walk: rows top to bottom (reverse: bottom to top), pixels left to right (reverse: right to left), in bytes. Each row is cut into segments that stay inside one destination line, inside one 4-pixel row of a tile for a tiled destination, and inside one tile row of a tiled source. The row address is base + y × stride by a shift-and-add multiplier (S_MUL, once per blit); the next rows add the stride (tiled: the next row inside the tile, or stride − 12 pixels after the fourth).
- 4x4 tiles (CAPS[11]): pixel (x, y) at base + (y/4)·stride + (x/4)·16·ps + ((y%4)·4 + x%4)·ps.
- FILL: streaming writes into AMB directly or via burst engine pipeline.
- COPY, TILE, UNTILE:
  - Standard / Decoupled Burst DMA Mode (Phase 030): For regular COPY, TILE, UNTILE, and reverse copy without forward RAW self-smear, a 1 KiB ping-pong buffer (Bank 0 / Bank 1, 512B each) and decoupled prefetch walk decouple source burst reads from destination pipeline writes. The prefetch channel issues back-to-back source line reads into the active filling bank. When the bank completes, the write channel extracts lines, performs 1-cycle barrel shift alignment and byte-enables, and issues streaming pipeline burst writes. Ping-pong alternation eliminates per-segment stop-and-wait roundtrip penalties.
  - Legacy Serial Mode: For blend-over (32-bit FILL/COPY) and forward RAW self-overlapping smear (reading what earlier segments wrote in the same line), the engine falls back to serial wait -> read -> blend -> write per segment for 100% bit-exact ordering.
- Blend-over (32-bit FILL/COPY): also read the destination line (after the writes are answered), then a 3-stage pipeline over the line's words: out = src + round(dst × (255 − src.a) / 255) per byte, saturated at 255, written back into the destination buffer, then the write (enables of the segment only).
- Under the MC's quiesce the pending request waits and the blit continues where it stopped.
- After an error response (`fail`) no new request is made; the blit drains every outstanding request and then pulses `error` kind 5.

## 5. State machine

One FSM (`state`, 16 states):

- `S_IDLE` →(kick, unsupported)→ `S_IDLE` with `error` kind 2; →(kick, supported: latch mode and clipped rectangle)→ `S_CLIP`
- `S_CLIP` →(empty rectangle)→ `S_IDLE` with `done`; →(else: width, rows, source origin)→ `S_START`
- `S_START` →(first row and pixel, multiplier operands)→ `S_MUL`
- `S_MUL` →(both multipliers done)→ `S_BURST` if burst eligible (no blend, no RAW smear); else `S_SA` (serial legacy path)
- `S_BURST` → decoupled prefetch walk and ping-pong write burst engine; drains and returns to `S_IDLE` with `done` (or kind 5 on `fail`)
- `S_SA` →(`fail`)→ `S_DRAIN`; →(pixel unit addresses)→ `S_SB` →(segment length)→ `S_SC` →(first units, reverse adjusted)→ `S_SD` →(line, offset, source lines)→ `S_CRD` if copy / `S_DRD` if blend fill / `S_WR` if fill
- `S_CRD` →(`fail`)→ `S_DRAIN`; →(no request pending, `wr_out` = 0: issue first, then second source read)→ … →(both issued)→ `S_CWAIT`
- `S_CWAIT` →(`fail`)→ `S_DRAIN`; →(`rd_out` = 0)→ `S_DRD` if blend, else `S_WR`
- `S_DRD` →(`fail`)→ `S_DRAIN`; →(`wr_out` = 0: issue destination read)→ `S_DWAIT` →(`rd_out` = 0)→ `S_BLEND` (`fail` → `S_DRAIN`)
- `S_BLEND` →(all words through the 3 stages)→ `S_WR`
- `S_WR` →(`fail`)→ `S_DRAIN`; →(no request pending: queue the write)→ `S_SA` for the next segment or row; →(it was the last segment of the last row)→ `S_DRAIN`
- `S_DRAIN` →(no request pending, `wr_out` = `rd_out` = 0, no response this cycle)→ `S_IDLE` with `done`, or `error` kind 5 if `fail`

## 6. Latency and throughput

- Per segment: decoupled pipeline execution in `S_BURST`. Source prefetch and destination writes run concurrently with ping-pong buffering.
- Measured streaming DMA throughput (`sim/tb/atg_blt_tb.v`, 64 KiB COPY, 100 MHz clock):
  - 32-byte line (ZYBO shape): 5,785 cycles -> **1,132 MB/s (1.13 GB/s)**
  - 64-byte line (KC705 shape): 3,274 cycles -> **2,001 MB/s (2.00 GB/s)**
- Measured legacy baseline on ZYBO (prior to Phase 030): 64 MB/s (1,628,691 cycles / 1 MiB).
- Achieved **17x to 31x throughput speedup**, surpassing the 1.0+ GB/s milestone requirement.

## 7. Corner cases and errors

- Empty rectangle (width or height 0, or clipped away): `done` without memory access. A CLIP_MAX with one component 0 and the other not enables clipping and gives an empty x (or y) range.
- Overlapping COPY: correct only in the right direction (forward when the destination starts before the source, reverse when after); the wrong direction smears exactly as the TB's model says (each segment reads what earlier segments wrote).
- Address arithmetic wraps at 32 bits silently; the MC's aperture check catches accesses outside.
- An aperture refusal: the CP records the MC's fault first (kind 1) and quiesces; the BLT stays busy with its next request held until RESET. An AXI error alone gives kind 5 after the drain, with no address.
- Kick while busy: ignored here (the CP faults it).
- Blend with a source channel above its alpha saturates at 255.
- Strides and widths are not checked against each other; rows may overlap.

## 8. What the TB checks

- Unit testbench `sim/tb/atg_blt_tb.v`:
  - Vector regression against `sim/vec/blt.txt` (over 600 cases across 32-byte and 64-byte lines): `ps`, `keep`, `tile`, `refuse`, `resolve`.
  - Phase 030 throughput verification: 64 KiB memory copy at 100 MHz clock verifying >= 1.0 GB/s (1,132 MB/s on 32B lines, 2,001 MB/s on 64B lines).
  - Phase 030 2D sub-rectangle copy verification: 37x50 pixels stride-crossing copy verifying 100% bit-exact correctness.
- Full-system testbench `sim/tb/atg_top_tb.v` (`PASS atg_top`):
  - FILL, COPY at several alignments, clipped FILL; 16-bit FILL at an odd pixel and COPY; blend FILL and COPY; TILE then UNTILE back; 16-bit TILE; overlapping COPY reverse, forward, 16-bit reverse; wrong-direction smear; 120 random blits; HALT / resume; aperture fault.

## 9. References

- design.md §2.3 (BLT STATE range), §3.6 (BLT LUTs: 1.0k estimated, 2.73k measured), §7.6 (split if > 400 lines: `atg_blt_rd`/`atg_blt_wr`/`atg_blt_ctl`).
- `docs/ghci.md` §8 (BLT STATE, operations, tiles, overlap direction, fault kind 2), §14 (KICK).
- Related specs: `spec/gpu/cp/atg_cp.md` (STATE, KICK, faults), `spec/gpu/mc/atg_mc.md` (AMB port, no read-after-write order).

## 10. Status

2026-10-25: **split** below 400 lines (U38): `atg_blt_cfg`, `atg_blt_seg`, `atg_blt_port`, `atg_blt_blend`, `atg_blt_acc` (one FSM stays here); the walk in bytes for 8- to 128-bit pixels, KEEP, BLT_COLOR1-3.  The behaviour of the earlier pixel sizes is unchanged except one more cycle per blended segment (the blend's done) and that BLT_OP[9:8] = 2, 3 and [13], [19:16] now mean pixel sizes and KEEP (CAPS[30]; the top TB's refused example moved to [13] with 16-bit pixels).  The table below is the earlier proposal.

Earlier status:

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
3. **Shadow STATE is cleared by CTRL.RESET** while the STATE BRAM keeps its values (ghci.md §5 says STATE survives): after RESET the host must rewrite the BLT range before the next KICK. Difference from the spec of GHCI; fix in an implementation Phase (e.g. reset the shadow with the board reset only, or have the CP replay).
4. A memory error reports kind 5 with no address or direction.

Renamed from `atg_blt` (the module's name and its header comment only; the behaviour and the timing are the same) when `atg_blt` became the wrapper of this engine and the RESOLVE engine (`spec/gpu/blt/atg_blt.md`).

WS288 p037 (2026-10-25): the arithmetic is am_ modules (docs/style.md), function unchanged (equal to the former module on 200,000 random cycles).
