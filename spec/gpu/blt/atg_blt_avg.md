# atg_blt_avg

RTL: `rtl/gpu/blt/atg_blt_avg.v`.  Parent: `atg_blt_rsv_px`.  Children: none.

## 1. Purpose and place

The integer averages of the blitter's RESOLVE (docs/ghci.md §8.2, §8.5), combinational: up to four pixels of four samples in, the pixels out (`atg_blt_favg` does sRGB and the floats).

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `fmt` | in | 3 | 0 UNORM8 (1-, 2-, 4-byte pixels), 1 UNORM565, 6 UNORM2_10_10_10, 7 UNORM1555, 2 SAMPLE0 (and 3-5) |
| `psl` | in | 3 | log2 of the pixel's bytes |
| `in_s` | in | 512 | Sample s of pixel p at slot 4p + s of 2^psl bytes |
| `out_p` | out | 128 | Pixel p at bits 8·2^psl·p (the pixels that fit; the rest 0) |

4 ports.

## 4. Behaviour

- UNORM8: every byte of a pixel: the sum Σ of the four samples' bytes, q = Σ >> 2, rounded up when Σ mod 4 = 3, or = 2 with q odd (nearest, ties to even).
- UNORM565: the fields [4:0], [10:5], [15:11] the same way; UNORM2_10_10_10 [9:0], [19:10], [29:20], [31:30]; UNORM1555 [4:0], [9:5], [14:10], [15].
- SAMPLE0: sample 0, every pixel size.

## 5. State machine

None.

## 6. Latency and throughput

Combinational (four 10-bit sums per byte; `atg_blt_rsv_px` registers the output).

## 7. Corner cases and errors

- Σ ≤ 1020: no overflow (q ≤ 255).  `MUT_RSV_RNE`: ties rounded up.

## 8. What the TB checks

`sim/tb/atg_blt_avg_tb.v` prints `PASS atg_blt_avg.unorm8` (every sum 0..1020 in every byte of the four pixels, both pixel sizes), `.rgb565` (every field sum, the high 64 bits 0), `.sample0`, and `PASS atg_blt_avg`; `MUT_RSV_RNE` fails the first two.  Also through `sim/tb/atg_blt_rsv_tb.v` (random sources).

## 9. References

docs/ghci.md §8.2.

## 10. Status

Implemented (the MSAA work).  2026-10-25: `psl` instead of `is16`, the averages 6 and 7, 8-bit UNORM8 and SAMPLE0 of every size; SRGB8_A8 and SFLOAT16/32 are in `atg_blt_favg`.  The new cases are checked by `sim/tb/atg_blt_tb.v`.

WS288 p037 (2026-10-25): the arithmetic is am_ modules (docs/style.md), function unchanged (equal to the former module on 200,000 random cycles): sixteen averagers (channel c of pixel p, three am_add for the sum and one for the rounding), their samples chosen by the format and the pixel size, instead of one set of sums for every format and size.
