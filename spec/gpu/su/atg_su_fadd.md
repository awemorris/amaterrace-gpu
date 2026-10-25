# atg_su_fadd

RTL: `rtl/gpu/su/atg_su_fadd.v`.  Parents: atg_su_lane (qdx, qdy: two per quad).

## 1. Purpose and place

The fp32 sum a + b; it replaces the function `atg_su_fadd` of include/atg_su_fp.vh.  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`a`, `b` (32 each) / `r` (32): 3 ports.

## 4. Behaviour

Round to nearest even, denormals flushed on input and output, NaN results 0x7FC00000 (design §3.1).  The smaller magnitude is aligned to the larger by the exponent difference (am_sub, am_shift right), the bits shifted out kept as a sticky bit (beyond 27 bits only the sticky bit).  One am_addsub gives the sum (same signs) or the difference; a carry shifts right by one, a cancellation normalises left by 26 − msb (am_sub, am_shift), and one am_addsub moves the exponent by the carry or by 26 − msb.  The rounding adds the round-up bit (am_add) and a carry out of the mantissa adds 1 to the exponent (am_add).  An exponent of 0 or below gives a zero of the sign (flushed), 255 and above an infinity.  NaN operands and inf − inf give 0x7FC00000, an infinity passes, (−0) + (−0) = −0, other zero sums +0.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

The module against the former function on 1,000,000 random inputs (exponents near 1, special exponents and mantissas, and random) and 1,000,000 with b close to −a (the cancellations), 0 errors (2026-10-25).

## 9. References

design §3.1 (precision).

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
