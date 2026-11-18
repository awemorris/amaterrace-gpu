# atg_tu_coord

RTL: `rtl/gpu/tu/atg_tu_coord.v`.  Parent: atg_tu_tcrd.

## 1. Purpose and place

The normalized coordinate with 24 fraction bits before the texel coordinate; it replaces the function `tu_coord` of include/atg_tu_fn.vh (tools/tumodel.py coord_t).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`f` (32, fp32), `mode` (2, the address mode) / `c` (30, signed): 3 ports.

## 4. Behaviour

Repeat floor(u × 2^24) mod 2^24, mirrored repeat mod 2^25, clamp to edge and border floor(u × 2^24) clamped to [−16, 17] × 2^24; zero, denormals and NaN 0.  1.f << (e − 126) or >> with the sticky (am_sub, am_shift), negative values −(q + sticky) (am_add).

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

The module against the former function on 1,000,000 random inputs, 0 errors (2026-10-25); sim/tb/atg_tu_tb.v.

## 9. References

`spec/gpu/tu/atg_tu_addr.md`, `spec/gpu/tu/atg_tu_foot.md`, tools/tumodel.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
