# atg_tu_frnd

RTL: `rtl/gpu/tu/atg_tu_frnd.v`.  Parent: atg_tu_filter (one a channel).  Written in WS288 p038 (the TU's pipeline, 2026-10-25; a leaf split off for the 400-line rule).

## 1. Purpose and place

One channel's conversion of the 8-bit path to fp32 (rnd81): the sum A × 0x0101010101 or the other sources' integers, rounded to nearest even.

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `i_rr` | in | 40 | The sum A (cycle 12). |
| `i_sel` | in | 3 | The source (cycle 13). |
| `i_fx` | in | 16 | The LOD query's magnitude (cycle 14). |
| `i_g24` | in | 24 | Gather's D24 texel. |
| `i_gb` | in | 8 | Gather's byte. |
| `i_d24` | in | 24 | Texel 0's D24. |
| `i_c6` | in | 6 | RGB565's G. |
| `i_c5` | in | 5 | RGB565's R or B. |
| `o_rn` | out | 32 | The fp32, cycle 18 (a register). |

10 ports.

## 4. Behaviour

p × 2^(n + eb − 127), n the msb position of p, rounded to nearest even, 0 for p = 0; p and eb by i_sel: 0 A × 0x0101010101 (55), 1 the query (119), 2 and 4 c × (2^48 + 2^24 + 1) (55), 3 b × 0x0101010101 × 2^32 (55), 5 c × Σ 2^6i (49), 6 c × Σ 2^5i (47).

## 5. State machine

None (a pipeline).

## 6. Latency and throughput

One lane a cycle: P13-P14 the adders, P15 the leading zeros, P16 the shift, P17 the rounding.  All the arithmetic through rtl/library/arith.

## 7. Corner cases and errors

None beyond the parent's.

## 8. What the TB checks

Through atg_tu_filter_tb.

## 9. References

The parent's spec.

## 10. Status

Implemented (2026-10-25, p038).
