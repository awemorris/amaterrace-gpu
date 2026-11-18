# atg_tu_layer

RTL: `rtl/gpu/tu/atg_tu_layer.v`.  Parent: atg_tu_addr (a 2D array's layer).

## 1. Purpose and place

Vulkan's layer clamp(RNE(f), 0, cnt − 1); it replaces the function `tu_layer` of include/atg_tu_fn.vh (tools/tumodel.py rne_layer).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`f` (32, fp32), `cnt` (16) / `l` (16): 3 ports.

## 4. Behaviour

NaN, zeros, denormals and negative values give 0; k = 150 − e (am_sub): 1 ≤ k ≤ 24 gives 1.f >> k (am_shift) rounded to nearest even (am_add); k ≤ 0 or a value ≥ cnt gives cnt − 1 (am_sub).

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

The module against the former function on 1,000,000 random inputs, 0 errors (2026-10-25).

## 9. References

`spec/gpu/tu/atg_tu_addr.md`, `spec/gpu/tu/atg_tu_foot.md`, tools/tumodel.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
