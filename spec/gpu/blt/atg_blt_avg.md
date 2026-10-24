# atg_blt_avg

RTL: `rtl/gpu/blt/atg_blt_avg.v`.  Parent: `atg_blt_rsv_px`.  Children: none.

## 1. Purpose and place

The averages of the blitter's RESOLVE (docs/ghci.md §8.2), combinational: four pixels of four samples in, four pixels out.

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `fmt` | in | 2 | 0 UNORM8, 1 UNORM565 (16-bit pixels), 2 SAMPLE0 (others read as SAMPLE0) |
| `is16` | in | 1 | 16-bit pixels |
| `in_s` | in | 512 | Sample s of pixel p at slot 4p + s: bits 32·slot (32-bit), 16·slot (16-bit, the low 256 bits) |
| `out_p` | out | 128 | Pixel p at bits 32p (16p for 16-bit pixels, the low 64 bits; the rest 0) |

4 ports.

## 4. Behaviour

- UNORM8: every byte of a pixel: the sum Σ of the four samples' bytes, q = Σ >> 2, rounded up when Σ mod 4 = 3, or = 2 with q odd (nearest, ties to even).
- UNORM565: the fields [4:0], [10:5], [15:11] the same way.
- SAMPLE0: sample 0.

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

Implemented (the MSAA work).  SRGB8_A8 and SFLOAT16/32 come here when the render output writes those formats.
