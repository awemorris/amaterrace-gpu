# am_msb

RTL: `rtl/library/arith/am_msb.v`.  Parents: atg_su_fadd, atg_su_ffma_p, atg_su_i2f (the normalisations).

## 1. Purpose and place

A priority encoder: the index of the highest set bit.  Not arithmetic (docs/style.md, "Arithmetic"); shared so that the normalisations of the fp datapaths have one form without a loop.  A loop in an always @(*) runs again on every change of its input while the logic in front of it settles; with the fp datapaths as modules that made iverilog six times slower than the former functions (atg_su_ffma: 15 s as a function, 95 s as a module with loops, 25 s with am_msb and shifted masks for the sticky bits, 200,000 operations).

## 2. Parameters

`W` (the width, 32), `SW` (the index bits, 5; W ≤ 2^SW).

## 3. Ports

`a` (W) / `n` (SW), `nz`: 3 ports.

## 4. Behaviour

a is zero-extended to 2^SW bits; level k (SW − 1 down to 0) sets bit k of n when the upper half of the vector of level k + 1 has a set bit and passes that half (else the lower) on.  n is 0 when a is 0; nz = |a.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational (LUTs: SW levels of an OR and a half select).

## 7. Corner cases and errors

None.

## 8. What the TB checks

Against a loop on 200,000 random values of every width (W 77, 32 and 27), 0 errors (2026-10-25, scratch TB).

## 9. References

docs/style.md, "Arithmetic".

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
