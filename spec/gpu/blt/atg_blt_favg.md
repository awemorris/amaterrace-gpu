# atg_blt_favg

RTL: `rtl/gpu/blt/atg_blt_favg.v`.  Parent: `atg_blt_rsv_px`.  Children: `atg_fmt_srgbenc`.

## 1. Purpose and place

The floating-point and sRGB averages of the blitter's RESOLVE (docs/ghci.md §8.2, §8.5): 3 SRGB8_A8, 4 SFLOAT16, 5 SFLOAT32, one group of pixels at a time while `atg_blt_rsv_px` stalls.

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1, 1 | Clock, synchronous active-low reset (`atg_blt_rsv_px`'s stop too) |
| `i_valid`, `i_ready` | in, out | 1, 1 | A group, taken in IDLE |
| `fmt`, `psl`, `npx` | in | 3, 3, 3 | The average, log2 of the pixel's bytes, the group's pixels (1-4) |
| `in_s` | in | 512 | Sample s of pixel p at slot 4 p + s of 2^psl bytes |
| `o_valid`, `o_ready` | out, in | 1, 1 | The averages, held until taken |
| `out_p` | out | 128 | Pixel p at bits 8 ps p |

10 ports.

## 4. Behaviour

Per channel (sRGB: bytes 0-2 of 32-bit pixels; SFLOAT16: every 16 bits of 16-, 32-, 64-bit pixels; SFLOAT32: every 32 bits of 32-, 64-, 128-bit pixels): the four samples as fp32 (sRGB by `atg_srgb_dec`, fp16 exactly by `atg_fmt_h2f`), r01 = s0 + s1, r23 = s2 + s3, s = r01 + r23, avg = s × 0.25, each one fused multiply-add of `include/atg_su_fp.vh` (round to nearest even, denormals flushed, NaN 0x7FC00000); SFLOAT16 then `atg_fmt_f2h` (to nearest even), sRGB `atg_fmt_srgbenc` (the nearest code).  sRGB's byte 3: the UNORM8 average (ties to even).  The reference is `tools/blt-vectors.py` (`average`, with `tools/gsi1fp.py` fma and `tools/fmtmodel.py`).

## 5. State machine

IDLE →(i_valid)→ RUN (steps 0-3 of a channel; sRGB → ENC, the encoder's 9 cycles) → … → OUT →(o_ready)→ IDLE.

## 6. Latency and throughput

4 cycles a channel (sRGB about 14): a 4-pixel group of RGBA16F about 66 cycles, of sRGB about 170.

## 7. Corner cases and errors

- `MUT_FAVG_PAIR` sums (s0 + s2) + (s1 + s3) (the TB's `resolve` group fails).

## 8. What the TB checks

Through `sim/tb/atg_blt_tb.v` (`resolve`: every average with each pixel size).

## 9. References

docs/ghci.md §8.2, §8.5; `atg_blt_rsv_px.md`, `spec/gpu/fmt/atg_fmt_srgbenc.md`.

## 10. Status

New (2026-10-25).  Reading: GHCI leaves the precision of the linear sRGB values and the floats' rounding to the implementation; Amaterrace uses the GPU's fp32 rules and the order of the GHCI text.

WS288 p037 (2026-10-25): the arithmetic is am_ modules (docs/style.md), function unchanged (equal to the former module on 200,000 random cycles): the sample and output places are am_shift and am_add of the same 32-bit values, the sRGB alpha averages four am_add each.
