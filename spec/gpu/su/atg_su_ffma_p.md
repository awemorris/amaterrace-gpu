# atg_su_ffma_p

RTL: `rtl/gpu/su/atg_su_ffma_p.v`.  Parents: atg_su_ffma, atg_su_fpu (the fused datapath, with the product of the shared multiplier).

## 1. Purpose and place

The fused a * b + c of fp32 with one rounding, given the product of the significands; it replaces the function `atg_su_ffma_p` of include/atg_su_fp.vh (tools/gsi1fp.py).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`a0`, `b0`, `c0` (32 each), `rm` (3), `noc`, `p` (48: the product of the significands {!z, m} of the flushed a and b) / `r` (32): 7 ports.

## 4. Behaviour

Denormal operands are flushed.  k, the position of C's LSB relative to P's (k = ec - ea - eb + 150, am_add and am_sub), places C in a 77-bit window with two bits below P's LSB: far above P (k > 49) P becomes a sticky bit and the exponent is adjusted by k - 49; otherwise C is shifted left by k + 2 or right by -k - 2 with the bits shifted out as a sticky bit (one am_shift; the sticky bit through a mask, am_shift of all ones), or becomes a sticky bit (k ≤ -26).  The sum (one am_addsub) is P + C, P - C or C - P, the larger first, with the sign of the larger.  The sum is normalised to bit 76 (am_msb, am_sub and am_shift), the exponent is msb + ea + eb + adj - 175 (am_add, am_sub), and atg_su_rnd rounds it under rm.  NaN operands, inf * 0 and inf - inf give 0x7FC00000; infinities pass; with a zero product the result is C, or a zero whose sign is the product's (noc), or by the rounding mode (RDN and mode 6: the sign of either, else of both); an exact zero sum is +0, or -0 under RDN and mode 6.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

Through atg_su_ffma: the module against the former function on 1,000,000 random inputs (operand exponents near 1, special exponents and mantissas, and random), 0 errors (2026-10-25).

## 9. References

design §3.1 (precision), tools/gsi1fp.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
