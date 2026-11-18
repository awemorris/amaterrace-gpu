# atg_su_fpu_op

RTL: `rtl/gpu/su/atg_su_fpu_op.v`.  Parents: atg_su_fpu (one per lane).

## 1. Purpose and place

One lane's operation of atg_su_fpu, given its multiplier's product; it replaces the function `fpu` of atg_su_fpu (tools/gsi1fp.py).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`o` (5: ATG_FPU_*), `ia`, `ib`, `ic` (32 each), `irm` (3), `ist` (sat), `pr` (64: the low bits of the lane's 33 × 33 product, atg_su_fpu's mulops) / `res` (32): 8 ports.

## 4. Behaviour

The operations share one atg_su_rint (fround, fract under RDN, fcvt.w*), one atg_su_i2f (fround and fract with RNE from the rounded integer, fcvt.s.w* with the uop's rm from the magnitude, 0 − a by am_sub for a negative fcvt.s.w) and one atg_su_ffma_p: fadd = a × 1 + b, fsub = a × 1 − b, fmul = a × b without an addend, the fmadd family with the negations of a and c, fract = a × 1 − fround(a, RDN) with RNE.  atg_su_f2i gives fcvt.w(u).s from the shared rounded integer.  fmin, fmax, fsgnj, the compares (all ones or 0) and mul, mulh* (pr) are as atg_su_fpu's spec says; sat clamps the float results.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

As atg_su_fpu.

## 8. What the TB checks

Through atg_su_fpu: `sim/tb/atg_su_fpu_tb.v` and `atg_su_pk_tb.v` (PK_SHARED), and atg_su_fpu against the former version (the function) for 200,000 cycles of random FPU and packed operations, with and without PK_SHARED, every output compared, 0 differences (2026-10-25).

## 9. References

design §3.1 (precision), tools/gsi1fp.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
