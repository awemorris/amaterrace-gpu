# atg_blt_cfg

RTL: `rtl/gpu/blt/atg_blt_cfg.v`.  Parents: `atg_blt_2d` and `atg_blt_rsv` (each its own copy).  Children: none.

## 1. Purpose and place

The BLT state of the blitter's engines and what it means: the copy of STATE 0x000-0x00E (docs/ghci.md §8.2, §8.5) as the CP writes it, the operation and its options, the pixel size, whether the 2D engine does the operation, the clipped destination rectangle, the bases and strides without their bits below the pixel size, and the FILL line.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `LINE_BYTES` | 32 | AMB line size (the FILL line's width) |

## 3. Ports

All in domain `clk`; outputs combinational from the copy.

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1, 1 | Clock; synchronous active-low reset (clears the copy) |
| `st_we`, `st_idx`, `st_wdata` | in | 1, 9, 32 | STATE writes; 0x000-0x00E are kept |
| `op`, `op2` | out | 2, 1 | BLT_OP[1:0], BLT_OP[2] |
| `resolve` | out | 9 | BLT_RESOLVE[8:0] |
| `blend`, `rev`, `keep` | out | 1, 1, 4 | BLT_OP[4], [12], [19:16] |
| `psl` | out | 3 | log2 of the pixel's bytes: [9:8] 0 → 2, 1 → 1, 2 → 3, 3 → 0; [13] → 4 |
| `op_ok` | out | 1 | The 2D engine does it (§4) |
| `x0`, `y0`, `x1`, `y1` | out | 17 each | The clipped destination rectangle, [x0, x1) × [y0, y1) |
| `dx`, `dy`, `src_xy` | out | 17, 17, 32 | BLT_DST_XY's x and y, BLT_SRC_XY |
| `dbase`, `sbase`, `dstride`, `sstride` | out | 32 each | Bases and strides with the bits below the pixel size cleared |
| `fill_line` | out | `LINE_BYTES*8` | The pixel of {COLOR3, COLOR2, COLOR1, COLOR} (its low 2^psl bytes) repeated |

20 ports.

## 4. Behaviour

- op_ok (the 2D engine): not [13] with [9:8] ≠ 0; blend only with 32-bit FILL and COPY; reverse only with FILL and COPY; TILE and UNTILE only with 16- and 32-bit pixels; KEEP ≠ 0 only with FILL and COPY of 32-bit pixels without blend.  `atg_blt_rsv` checks its combinations itself.
- The clip: [CLIP_MIN, CLIP_MAX) when CLIP_MAX ≠ 0, as before.

## 5. State machine

None.

## 6. Latency and throughput

Combinational outputs (the CP writes no BLT state while an engine is busy).

## 7. Corner cases and errors

- Reset clears the copy (the earlier engines did the same; see `atg_blt_2d.md` §10, residual 3).

## 8. What the TB checks

Through `sim/tb/atg_blt_tb.v` (`atg_blt.md` §8) and `sim/tb/atg_top_tb.v`.

## 9. References

docs/ghci.md §8.2, §8.5.

## 10. Status

New (2026-10-25): the copy of the state moved out of the two engines (the split of the 2D engine below 400 lines; the RESOLVE engine uses it too).
