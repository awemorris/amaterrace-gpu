# atg_su_rint

RTL: `rtl/gpu/su/atg_su_rint.v`.  Parents: atg_su_fpu (one per lane: fround, fract, fcvt.w*).

## 1. Purpose and place

The integer nearest to |x| under the rounding mode and x's sign; it replaces the function `atg_su_rint` of include/atg_su_fp.vh (tools/gsi1fp.py).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`x` (32: flushed, exponent below 150), `rm` (3) / `n` (25: the magnitude): 3 ports.

## 4. Behaviour

The fraction bits f = 150 − e (am_sub); the integer part is the significand shifted right by f (am_shift; 0 for f ≥ 24), the guard bit the one below it (f − 1, am_sub), the sticky bit the OR of those below (a mask, am_shift of all ones); rounding up by rm (0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, others RNE; the directed modes by x's sign) adds 1 (am_add).  An exponent of 150 or more is not an input (the result is not used then).

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

The module against the former function on 1,000,000 random inputs (exponents near 1, special exponents and mantissas, and random; the former function's X results, at exponent 150, not compared), 0 errors (2026-10-25).

## 9. References

design §3.1 (precision), tools/gsi1fp.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
