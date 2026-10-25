# atg_rop_dtest

RTL: `rtl/gpu/rop/atg_rop_dtest.v` (new).  Parent: atg_rop_ds (one instance per entry it tests in a cycle).

## 1. Purpose and place

The per-sample depth-bounds, stencil and depth test of one (lane, sample) entry, in Vulkan's order (depth bounds → stencil → depth), and the word to write back.  atg_rop_ds keeps the line, walks the entries and merges the writes; this module only decides.

## 2. Parameters

None.

## 3. Ports

Combinational: no clock.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| **State (atg_rop_ds keeps the STATE words)** | | | |
| `depth` | in | 10 | DEPTH (0x076) [9:0]: [0] depth test, [1] depth write, [4:2] compare op, [5] D24_UNORM_S8_UINT (also X8_D24), [6] D32_SFLOAT, [7] D16_UNORM, [8] stencil test, [9] depth bounds test. |
| `sfront` | in | 27 | STENCIL_FRONT (0x077) [26:0]: [7:0] reference, [15:8] compare mask, [23:16] write mask, [26:24] compare op. |
| `sback` | in | 27 | STENCIL_BACK (0x079), the same. |
| `sops` | in | 25 | STENCIL_OPS (0x078) [24:0]: [2:0], [5:3], [8:6] front fail, pass and depth-fail ops; [18:16], [21:19], [24:22] back. |
| `bmin`, `bmax` | in | 32 | DEPTH_BOUNDS_MIN, _MAX (0x08B, 0x08C), fp32. |
| **The entry** | | | |
| `cov` | in | 1 | The sample is covered (after the rasterizer's and atg_rop_ms's coverage). |
| `front` | in | 1 | Front facing (lines, points and the direct path are front). |
| `zf` | in | 32 | The sample's depth, fp32, after atg_rop_ms (exported or interpolated, clamped as DEPTH_CLAMP says). |
| `stored` | in | 32 | The stored word: D24S8 and D32F the 32-bit word, D16 the halfword in [15:0]. |
| **Result** | | | |
| `pass` | out | 1 | The sample stays covered (passed every enabled test). |
| `wword` | out | 32 | The word to write (D16: [15:0]); only the enabled bytes matter. |
| `wbe` | out | 4 | Byte enables of wword (D16 uses [1:0]); 0 when nothing changes. |

14 ports.

## 4. Behaviour

The format is the one bit of DEPTH[7:5] that is set; with none or more than one there is no depth/stencil attachment: every test passes and nothing is written (pass = cov).  z_a is the stored depth: D16 and D24 as UNORM to fp32 (`atg_fmt_unorm`, nearest), D32F the stored word.

1. **Depth bounds** (DEPTH[9]): z_a below bmin or above bmax (fp32 order, -0 = +0; a NaN z_a is outside) → pass = 0, wbe = 0 (no stencil op: Vulkan sets the coverage to 0 before the stencil test).
2. **Stencil** (DEPTH[8] and D24S8; the state of `front`'s face): s_a = stored[31:24]; the test is (reference & compare mask) op (s_a & compare mask) with the VkCompareOp.  Failed: new = op(fail op), pass = 0.  Passed: new = op(depth result ? pass op : depth-fail op), pass = the depth result.  Ops (VkStencilOp): 0 KEEP s_a, 1 ZERO, 2 REPLACE reference, 3 INCREMENT_AND_CLAMP min(s_a + 1, 255), 4 DECREMENT_AND_CLAMP max(s_a - 1, 0), 5 INVERT ~s_a, 6 INCREMENT_AND_WRAP s_a + 1, 7 DECREMENT_AND_WRAP s_a - 1 (8 bits).  The written stencil is (s_a & ~write mask) | (new & write mask); byte 3 is enabled when it differs from s_a.  Without the stencil test the stencil passes and is not written.
3. **Depth** (DEPTH[0]): the compare op of the new depth against z_a: D32F by the order keys of `atg_fmt_depth_key` (zf and the stored word, one instance each), D24 by `atg_fmt_depth_u24` of zf against stored[23:0], D16 by RNE(clamp01(zf) x 65535) (`atg_fmt_f2unorm(zf, 16)`) against stored[15:0]; NaN as in `atg_depth_pass`.  Without the depth test the depth result is 1.  Written (bytes 0-2 for D24, 0-1 for D16, 0-3 for D32F) when DEPTH[1], the stencil passed and the depth passed.
4. `cov` = 0: pass = 0, wbe = 0.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational; atg_rop_ds registers around it (it tests 2 or 8 entries per cycle, design §15.6).  Size ≈0.4k LUT per instance (estimated).

## 7. Corner cases and errors

- X8_D24 is set as D24S8 with the stencil test off: the stencil byte is never written.
- Stencil with D16 or D32F (no stencil attachment): the stencil passes, nothing is written.
- Bounds with NaN in bmin or bmax: a comparison with NaN is false, so the stored depth is outside.

## 8. What the TB checks

`sim/tb/atg_rop_dtest_tb.v` (vectors from `tools/rxmodel.py`) prints, in this order:

- `PASS atg_rop_dtest.stencil` — the 8 ops × 8 compare ops × front/back × random masks and references against the model
- `PASS atg_rop_dtest.d16` — D16 compare and write, the RNE and saturation
- `PASS atg_rop_dtest.bounds` — inside, outside, at the bounds, NaN
- `PASS atg_rop_dtest.order` — bounds before stencil before depth (a bounds failure writes no stencil)
- `PASS atg_rop_dtest` at the end.

Deliberate errors: `MUT_STENCIL_FACE` (front and back swapped) and `MUT_STENCIL_WRAP` (wrap as clamp) must make the TB fail.

## 9. References

docs/ghci.md §8.5 (ROP range, the per-sample operations), `spec/gpu/rop/atg_rop_ds.md`, `spec/gpu/fmt/atg_fmt.md`, `spec/gpu/fmt/atg_fmt_depth_u24.md`, `spec/gpu/fmt/atg_fmt_depth_key.md`, include/atg_depth.vh (`atg_depth_pass`).  design §16.5, §16.6.  Values referenced: Vulkan specification, Depth Bounds Test, Stencil Test, Depth Test, VkStencilOp, VkCompareOp.

## 10. Status

Implemented 2026-10-25: every PASS of §8 (`sim/vec/rop_dtest.txt` from `tools/rop-vectors.py`, the model `dtest` in `tools/rxmodel.py`); `-DMUT_STENCIL_FACE` and `-DMUT_STENCIL_WRAP` fail `.stencil` (and the sections with a stencil).  wword's bytes outside wbe are unspecified (the TB compares the enabled ones).

2026-10-25 (p037, P1): the D24 conversion and the D32F keys are instances of atg_fmt_depth_u24 and atg_fmt_depth_key (the shared arithmetic, docs/style.md); the behaviour is unchanged (the old module and the new one compared on 200,000 random inputs).
