# atg_su_hrnd

RTL: `rtl/gpu/su/atg_su_hrnd.v`.  Parents: atg_su_fpu (the fp32 to fp16 of the packed results, PK_SHARED), atg_su_pk.

## 1. Purpose and place

The fp16 rounding of a normalised magnitude; it replaces the function `atg_su_hrnd` of include/atg_su_fp16.vh (tools/gsi1fp.py).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`s`, `e` (10, signed: the biased exponent), `m` (11, bit 10 set), `g`, `st`, `rm` (3) / `h` (16): 7 ports.

## 4. Behaviour

Rounding up by rm (0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, others RNE) (am_add), + 1 on the exponent when the mantissa carries (am_add); e ≥ 31 gives infinity, or the largest finite under RTZ and the directed modes away from it; e ≤ 0 a zero of the sign.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

The module against the former function on 1,000,000 random inputs, 0 errors (2026-10-25).

## 9. References

design §3.1 (precision), tools/gsi1fp.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
