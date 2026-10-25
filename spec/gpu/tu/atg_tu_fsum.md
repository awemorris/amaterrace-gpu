# atg_tu_fsum

RTL: `rtl/gpu/tu/atg_tu_fsum.v`.  Parent: atg_tu_filter (one a channel).  Written in WS288 p038 (the TU's pipeline, 2026-10-25; a leaf split off for the 400-line rule).

## 1. Purpose and place

One channel's sum of the 8-bit path: R = Σ byte × weight over the four texels, A = (first pass ? 0 : A) + R × W.

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `i_by` | in | 32 | The four texels' bytes (cycle 5). |
| `i_w` | in | 68 | Their weights (cycle 5). |
| `i_wp` | in | 17 | The pass's weight (cycle 5). |
| `i_al` | in | 40 | The lane's sum (cycle 11). |
| `i_acc` | in | 1 | Not the first pass (cycle 11). |
| `o_rr` | out | 40 | The new sum, cycle 11 (combinational). |

7 ports.

## 4. Behaviour

R (below 2^24, the weights sum to 65536) and A as in atg_tu_filter.md §4 (the same integers as (a (256 − fu) + b fu)(256 − fv) + (c (256 − fu) + d fu) fv).

## 5. State machine

None (a pipeline).

## 6. Latency and throughput

One lane a cycle: products in 7 (am_mul, 2 registers), R in 9, R × W in 11 (am_mul, 2 registers).  All the arithmetic through rtl/common.

## 7. Corner cases and errors

None beyond the parent's.

## 8. What the TB checks

Through atg_tu_filter_tb.

## 9. References

The parent's spec.

## 10. Status

Implemented (2026-10-25, p038).
