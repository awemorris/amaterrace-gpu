# atg_su_h2f

RTL: `rtl/gpu/su/atg_su_h2f.v`.  Parents: atg_su_fpu (the packed operations' fp32 operands, PK_SHARED), atg_su_pk (unpackh).

## 1. Purpose and place

fp16 to fp32, exact; it replaces the function `atg_su_h2f` of include/atg_su_fp16.vh (tools/gsi1fp.py).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`h` (16) / `f` (32): 2 ports.

## 4. Behaviour

Infinity and NaN (0x7FC00000) kept; zeros and denormals give a zero of the sign (flushed); else the exponent + 112 (am_add) and the mantissa.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

The module against the former function on 300,000 random inputs, 0 errors (2026-10-25).

## 9. References

design §3.1 (precision), tools/gsi1fp.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
