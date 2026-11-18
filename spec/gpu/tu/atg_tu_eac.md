# atg_tu_eac

RTL: `rtl/gpu/tu/atg_tu_eac.v`.  Parent: atg_tu_etc (two: the R or alpha block, the G block).  Written in WS288 p038 (the TU's pipeline, 2026-10-25; a leaf split off for the 400-line rule).

## 1. Purpose and place

One EAC block's value of a texel: 8-bit alpha (RGBA8's alpha block), R11 or signed R11.

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `i_w` | in | 64 | The block as its big-endian 64-bit integer (cycle 0). |
| `i_k` | in | 4 | {column, row} of the texel. |
| `i_r11` | in | 1 | R11 (else 8-bit alpha). |
| `i_sg` | in | 1 | Signed R11. |
| `o_v` | out | 11 | The value, cycle 2 (combinational from the last register): alpha in [7:0], R11 in [10:0] (two's complement when signed). |

6 ports.

## 4. Behaviour

As atg_tu_etc.md §4 (EAC): base + modifier × multiplier clamped to [0, 255]; R11 base × 8 + 4 + modifier × multiplier × 8 (multiplier 0: the modifier alone) clamped to [0, 2047]; signed base × 8 (−128 as −127) + the same, clamped to [−1023, 1023].

## 5. State machine

None (a pipeline).

## 6. Latency and throughput

One texel a cycle: E1 the modifier and the base, E1b the modifier times the multiplier (shifts and adds), E2 the sum and the clamp.  All the arithmetic through rtl/library/arith.

## 7. Corner cases and errors

None beyond the parent's.

## 8. What the TB checks

Through atg_tu_etc_tb (every EAC table, multipliers 0, 1, 15, extreme bases, random blocks).

## 9. References

The parent's spec.

## 10. Status

Implemented (2026-10-25, p038).
