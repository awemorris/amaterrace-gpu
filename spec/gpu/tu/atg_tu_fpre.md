# atg_tu_fpre

RTL: `rtl/gpu/tu/atg_tu_fpre.v`.  Parent: atg_tu_filter.  Written in WS288 p038 (the TU's pipeline, 2026-10-25; a leaf split off for the 400-line rule).

## 1. Purpose and place

The per-lane front of the 8-bit path (P1 → P5): Dref's conversions and the compares of the four texels, the bilinear and pass weights, the LOD query's magnitudes.

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `i_vw` | in | 32 | The lane's tc_value word (cycle 1). |
| `i_lt` | in | 128 | The lane's texels. |
| `i_wl` | in | 32 | {fw, fl, fv, fu}. |
| `i_bil` | in | 1 | Bilinear. |
| `i_p17` | in | 1 | Slice bit. |
| `i_p18` | in | 1 | Level bit. |
| `i_d32` | in | 1 | D32F. |
| `i_d16` | in | 1 | D16. |
| `i_op` | in | 3 | VkCompareOp. |
| `o_ok` | out | 4 | The compares, cycle 4 (combinational). |
| `o_w` | out | 68 | The four texels' weights, cycle 5. |
| `o_wp` | out | 17 | The pass's weight, cycle 5. |
| `o_fa` | out | 32 | |tc_value[31:16]|, |[15:0]|, cycle 5. |

14 ports.

## 4. Behaviour

Dref as unorm24 (RNE of Dref × (2^24 − 1); NaN, ≤ 0, denormals 0, ≥ 1 all ones; as atg_fmt_depth_u24), unorm16 (as atg_fmt_f2unorm), or the fp32 order key; the texels' keys; VkCompareOp as atg_depth_pass (D32F: NaN passes NOT_EQUAL and ALWAYS only); weights (256 − fu or fu)(256 − fv or fv), without bilinear 65536 for texel 0; W = (fw or 256 − fw)(fl or 256 − fl).

## 5. State machine

None (a pipeline).

## 6. Latency and throughput

One lane a cycle, no stall.  All the arithmetic through rtl/common.

## 7. Corner cases and errors

None beyond the parent's.

## 8. What the TB checks

Through atg_tu_filter_tb (compare, depth, query groups).

## 9. References

The parent's spec.

## 10. Status

Implemented (2026-10-25, p038).

2026-10-25 (p037, P1): the order keys of Dref and the texels are atg_fmt_depth_key instances (the same keys as the former am_sub copies; old and new compared on 200,000 random cycles).
