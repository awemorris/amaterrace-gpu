# atg_tu_fx32

RTL: `rtl/gpu/tu/atg_tu_fx32.v`.  Parent: atg_tu_lod (the lanes' coordinates), atg_tu_lsel (texl's λ, texb's bias), atg_tu_unnorm.

## 1. Purpose and place

floor(f × 2^sh) saturated to 32 bits; it replaces the function `tu_fx32` of include/atg_tu_fn.vh (tools/tumodel.py fx32).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`f` (32, fp32), `sh` (5) / `q` (32): 3 ports.

## 4. Behaviour

Zero, denormals and NaN give 0; infinities and k = e − 150 + sh ≥ 8 saturate (0x7FFFFFFF, 0x80000000 negative); else 1.f << k or >> −k (am_add, am_sub, am_shift) with the sticky of the bits shifted out, negative values −(q + sticky) (am_add of ~q).

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

The module against the former function on 1,000,000 random inputs (fp32 near 1 three times in four), 0 errors (2026-10-25); sim/tb/atg_tu_tb.v.

## 9. References

`spec/gpu/tu/atg_tu_addr.md`, `spec/gpu/tu/atg_tu_foot.md`, tools/tumodel.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
