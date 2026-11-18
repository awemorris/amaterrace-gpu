# atg_tu_ffront

RTL: `rtl/gpu/tu/atg_tu_ffront.v`.  Parent: atg_tu_ffilt.  Written in WS288 p038 (the TU's pipeline, 2026-10-25; a leaf split off for the 400-line rule).

## 1. Purpose and place

The front of the fp32 filter path's pipeline: a step (one component of a lane's texel) to its converted value and its weight as fp32.

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `rst_n` | in | 1 | Synchronous reset (the valid bits). |
| `i_vld` | in | 1 | A step (cycle 0). |
| `i_op` | in | 2 | Its kind (term, bypass, gather). |
| `i_cs` | in | 2 | The component. |
| `i_aid` | in | 4 | The accumulator. |
| `i_t` | in | 2 | The texel. |
| `i_sl` | in | 128 | The lane's four slots. |
| `i_bd` | in | 4 | Their border bits. |
| `i_lo` | in | 8 | Their address bits 1:0. |
| `i_ft` | in | 2 | The footprint texel. |
| `i_wl` | in | 32 | The lane's {fw, fl, fv, fu}. |
| `i_bil` | in | 1 | Bilinear. |
| `i_p17` | in | 1 | The pass's slice bit. |
| `i_p18` | in | 1 | Its level bit. |
| `i_wg` | in | 1 | Gather of a word of the texel (quad constant). |
| `i_gwi` | in | 2 | That word. |
| `i_b8` | in | 1 | 8-byte texels. |
| `i_b16` | in | 1 | 16-byte texels. |
| `i_ifmt` | in | 4 | atg_tu_etc's format. |
| `i_blk` | in | 1 | A block format. |
| `i_inf` | in | 68 | The format's atg_fmt_info word. |
| `i_sten` | in | 1 | The stencil aspect. |
| `o_vld` | out | 1 | The step in cycle 13. |
| `o_meta` | out | 12 | {op, cs, aid, tb, es, ers, egs}. |
| `o_up` | out | 32 | The converted component. |
| `o_wf` | out | 32 | The weight n × 2^-32 as fp32. |
| `o_busy` | out | 1 | A step inside. |

28 ports.

## 4. Behaviour

P0 the texel's bits and border bit from the lane's slots and its position in a block (atg_tu_ffilt.md §4), P1 the step's fields, P2-P5 atg_tu_etc, P2-P7 the weight wu × wv × wa × wb (am_mul) and its fp32 rounded to nearest even, P6 the converter's inputs (a block's texel as RGBA8 UNORM or sRGB, or EAC's 11-bit UNORM components, the signed ones as 10-bit magnitudes with the sign set), P6-P13 atg_fmt_cvt.

## 5. State machine

None (a pipeline).

## 6. Latency and throughput

One step a cycle, no stall, 13 cycles.  All the arithmetic through rtl/library/arith.

## 7. Corner cases and errors

None beyond the parent's.

## 8. What the TB checks

Through atg_tu_ffilt_tb.

## 9. References

The parent's spec.

## 10. Status

Implemented (2026-10-25, p038).
