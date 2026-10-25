# atg_su_f2i

RTL: `rtl/gpu/su/atg_su_f2i.v`.  Parents: atg_su_fpu (one per lane: fcvt.w.s, fcvt.wu.s).

## 1. Purpose and place

fcvt.w.s and fcvt.wu.s from the flushed x and its rounded integer (atg_su_rint, shared in atg_su_fpu with fround); it replaces the functions `atg_su_f2i` of include/atg_su_fp.vh and `f2i_n` of atg_su_fpu (tools/gsi1fp.py).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`x` (32: flushed), `n` (25: atg_su_rint of x), `uns` / `r` (32): 4 ports.

## 4. Behaviour

Exponents 150 to 158 give the significand shifted left by e − 150 (am_sub on the low 5 bits, am_shift), smaller ones n.  Unsigned: negatives (not NaN) give 0, exponents of 159 and more all ones.  Signed: exponents of 159 and more and magnitudes out of range saturate to 0x7FFFFFFF or 0x80000000; negatives give 0 − magnitude (am_sub).  NaN is +inf.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

atg_su_rint and the module together against the former function atg_su_f2i on 1,000,000 random inputs (exponents near 1, special exponents including 150, 158 and 159, and random), 0 errors (2026-10-25).

## 9. References

design §3.1 (precision), tools/gsi1fp.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
