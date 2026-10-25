# atg_blt_seg

RTL: `rtl/gpu/blt/atg_blt_seg.v`.  Parent: `atg_blt_2d`.  Children: none.

## 1. Purpose and place

The segment geometry of the 2D engine, combinational, in bytes: the segment's length, the bytes back from a reversed segment's rightmost pixel, the source window and the write's byte enables.

## 2. Parameters

`ADDR_W` (32), `LINE_BYTES` (32), `LINE_SHIFT` (5).

## 3. Ports

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `psl`, `rev`, `dtile`, `stile`, `keep` | in | 3, 1, 1, 1, 4 | The blit's mode |
| `da`, `px`, `spx`, `rem` | in | `LINE_SHIFT`, 2, 2, 17 | The byte of the pixel in its line, x mod 4 of the pixel and its source, the row's pixels left |
| `seg_n` | out | `LINE_SHIFT`+1 | Pixels: min(rem, the room in the line (reversed: back to its start), in the tile row of a tiled destination or source) |
| `sn` | in | `LINE_SHIFT`+1 | The segment's pixels |
| `back` | out | `ADDR_W` | (sn − 1) × ps |
| `snu`, `dlo`, `slo` | in | `LINE_SHIFT`+1, `LINE_SHIFT`, `ADDR_W` | The segment's bytes, its first destination byte in the line, its first source byte |
| `src_base`, `last_line` | out | `ADDR_W`, `ADDR_W-LINE_SHIFT` | slo − dlo (the source byte of the line's byte 0), the line of slo + snu − 1 |
| `p0`, `be` | in, out | `LINE_SHIFT`, `LINE_BYTES` | Bytes p0 .. p0 + snu − 1, without byte b of each 32-bit pixel where keep[b] |

16 ports.

## 4. Behaviour

As the ports say; a 32-bit pixel's byte b is byte u of the line with u mod 4 = b (pixels and lines are 4-byte aligned).

## 5. State machine

None.

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

- `MUT_BLT_KEEP` ignores keep (the TB's `keep` group fails).

## 8. What the TB checks

Through `sim/tb/atg_blt_tb.v` and `sim/tb/atg_top_tb.v`.

## 9. References

docs/ghci.md §8.2, §8.5; `atg_blt_2d.md`.

## 10. Status

New (2026-10-25): split off `atg_blt_2d`, in bytes for pixels of 1 to 16 bytes, KEEP.

WS288 p037 (2026-10-25): the arithmetic is am_ modules (docs/style.md), function unchanged (equal to the former module on 200,000 random cycles).
