# atg_tu_fword

RTL: `rtl/gpu/tu/atg_tu_fword.v`.  Parent: atg_tu_filter.  Written in WS288 p038 (the TU's pipeline, 2026-10-25; a leaf split off for the 400-line rule).

## 1. Purpose and place

A lane's four words of the 8-bit path (P18, combinational).

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `i_rn` | in | 128 | The four conversions. |
| `i_lt` | in | 128 | The lane's texels. |
| `i_vw` | in | 32 | The lane's tc_value word. |
| `i_ok` | in | 4 | The compares. |
| `i_ctl` | in | 50 | The pass's tc_ctl. |
| `i_mk` | in | 1 | The lane is in the mask. |
| `o_res` | out | 128 | The words. |

7 ports.

## 4. Behaviour

RGB565's texf alpha 1.0; a depth texel without compare (D, 0, 0, 1.0; D32F the word itself); gather (texels 2, 3, 1, 0: the compare's 1.0 or 0.0, ZERO/ONE, a depth component, the byte's conversion), else the component swizzle; texsz (the tc_value word), texqlod (the two signed values); 0 outside the mask (atg_tu_filter.md §4).

## 5. State machine

None (a pipeline).

## 6. Latency and throughput

Combinational.  All the arithmetic through rtl/library/arith.

## 7. Corner cases and errors

None beyond the parent's.

## 8. What the TB checks

Through atg_tu_filter_tb.

## 9. References

The parent's spec.

## 10. Status

Implemented (2026-10-25, p038).
