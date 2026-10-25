# atg_tu_unnorm

RTL: `rtl/gpu/tu/atg_tu_unnorm.v`.  Parent: atg_tu_tcrd.

## 1. Purpose and place

An unnormalized coordinate floor(u × 256) clamped to [−2^28, 2^28]; it replaces the function `tu_unnorm` of include/atg_tu_fn.vh (tools/tumodel.py unnorm_c).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`f` (32, fp32) / `c` (30, signed): 2 ports.

## 4. Behaviour

atg_tu_fx32 with sh 8, clamped.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

The module against the former function on 300,000 random inputs, 0 errors (2026-10-25).

## 9. References

`spec/gpu/tu/atg_tu_addr.md`, `spec/gpu/tu/atg_tu_foot.md`, tools/tumodel.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
