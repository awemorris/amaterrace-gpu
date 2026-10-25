# atg_tu_fma

RTL: `rtl/gpu/tu/atg_tu_fma.v`.  Parent: atg_tu_ffilt (the accumulation of the fp32 filter path).  Written in WS288 p038 (the TU's pipeline, 2026-10-25).

## 1. Purpose and place

The TU's pipelined fp32 fused multiply-add r = fma(a, b, c), one rounding to nearest even, denormals flushed: bit for bit the module `atg_su_ffma` with rm 0 (formerly the function of `include/atg_su_fp.vh`; the TB checks against that function, `sim/tb/atg_su_fp_ref.vh`) (`tools/gsi1fp.py` fma).  The addend is read late (cycle 3), so that the caller can keep an accumulator in its registers and give the operation the value it has then.

## 2. Parameters

`TW` (4): the tag bits.

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | Clock; synchronous reset (the valid bits). |
| `i_vld`, `i_tag` | in | 1, TW | An operation in cycle 0 (no ready: one a cycle). |
| `i_a`, `i_b` | in | 32 | The factors, cycle 0. |
| `c_vld`, `c_tag` | out | 1, TW | Cycle 3: the operation whose addend is read. |
| `c_val` | in | 32 | The addend, in the same cycle (combinational from c_tag; registered at its end). |
| `r_vld`, `r_tag`, `r_val` | out | 1, TW, 32 | Cycle 10: the result (combinational from the last register). |
| `o_busy` | out | 1 | An operation in the unit. |

## 4. Behaviour

As atg_su_ffma_p with rm 0: NaN (0x7FC00000) for a NaN operand or ∞ × 0, ∞ of the product's sign (NaN against an opposite ∞ addend), the addend for an infinite addend or a zero product (with a zero addend the sign AND of both), otherwise the product and the addend aligned in a 77-bit window (P's LSB at bit 2; an addend far below P a sticky bit, far above it P a sticky bit), added or subtracted, normalised, rounded to nearest even with overflow to ∞ and underflow to zero.

## 5. State machine

None (a pipeline).

## 6. Latency and throughput

One operation a cycle; addend read in cycle 3 (registered), result in cycle 10: an accumulator written by one operation is read by another whose cycle 3 is 8 or more cycles after the first one's (atg_tu_ffilt waits for that).  Stages: M0 (classify a, b; exponent sum) R1, the 24 × 24 product (am_mul, 3 registers) R2-R4 (the addend registered in R4), A1 (the addend, the alignment k, the special results) R5, A2 (the aligned addend, am_shift) R6, B (P + C and C − P: am_addsub, am_sub) R7, C1 (the magnitude, its leading zeros) R8, C2 (normalised, am_shift; exponent) R9, D1 (round up) R10, D2 (carry, range, special results).  Arithmetic only through rtl/common (am_add, am_sub, am_addsub, am_shift, am_mul).

## 7. Corner cases and errors

None beyond §4.

## 8. What the TB checks

`sim/tb/atg_tu_fma_tb.v`: 175,000 operations (random bubbles, seed) against atg_su_ffma: random words, zeros, denormals, infinities, NaNs, smallest and largest, exponents near one another, cancellation (c ≈ −ab), atg_tu_ffilt's weights; `PASS atg_tu_fma`.  A rounding error (up without the sticky bit) fails it.

## 9. References

`rtl/gpu/su/atg_su_ffma_p.v`, `sim/tb/atg_su_fp_ref.vh`; docs/style.md (Arithmetic).

## 10. Status

Implemented (2026-10-25, p038).
