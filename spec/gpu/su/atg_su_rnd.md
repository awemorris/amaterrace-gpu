# atg_su_rnd

RTL: `rtl/gpu/su/atg_su_rnd.v`.  Parents: atg_su_ffma_p, atg_su_i2f, atg_su_xu (the transcendental results).

## 1. Purpose and place

The fp32 rounding of a normalised magnitude; it replaces the function `atg_su_rnd` of include/atg_su_fp.vh (tools/gsi1fp.py).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`s`, `e` (12, signed: the biased exponent), `m` (24, bit 23 set), `g`, `st`, `rm` (3) / `r` (32): 7 ports.

## 4. Behaviour

Rounding up by rm (0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, 7 RNE; 5 and 6 round to odd: the last bit set when inexact) (am_add), + 1 on the exponent when the mantissa carries (am_add); e ≥ 255 gives infinity, or the largest finite under RTZ, round to odd and the directed modes away from it; e ≤ 0 a zero of the sign.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

The module against the former function on 1,000,000 random inputs, and 1,000,000 each with the exponent near the overflow and underflow limits and with a mantissa of all ones (the carry), 0 errors (2026-10-25).

## 9. References

design §3.1 (precision), tools/gsi1fp.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
