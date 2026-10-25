# atg_su_ffma

RTL: `rtl/gpu/su/atg_su_ffma.v`.  Parents: atg_blt_favg (the filtered average).

## 1. Purpose and place

The fused a * b + c of fp32 with one rounding and its own multiplier; it replaces the function `atg_su_ffma` of include/atg_su_fp.vh (tools/gsi1fp.py).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`a0`, `b0`, `c0` (32 each), `rm` (3), `noc` / `r` (32): 6 ports.

## 4. Behaviour

The significands {!z, m} of the flushed a and b are multiplied (am_mul 24 x 24, combinational: DSP48E1) and atg_su_ffma_p gives the result.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

As atg_su_ffma_p.

## 8. What the TB checks

The module against the former function on 1,000,000 random inputs (operand exponents near 1, special exponents and mantissas, and random), 0 errors (2026-10-25).

## 9. References

design §3.1 (precision), tools/gsi1fp.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
