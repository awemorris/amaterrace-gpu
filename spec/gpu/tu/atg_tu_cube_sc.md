# atg_tu_cube_sc

RTL: `rtl/gpu/tu/atg_tu_cube_sc.v`.  Parent: atg_tu_cube (s_c and t_c of the face).

## 1. Purpose and place

One of atg_tu_cube's face coordinates before the division: floor(v 2^(150 − em)) with the sign flipped by neg, clamped to [−3 mm, 3 mm], plus 3 mm; it replaces the function `scaled` of atg_tu_cube.  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`v` (32), `neg`, `em` (8), `m3` (27, 3 mm from the caller) / `o` (27): 5 ports.

## 4. Behaviour

A zero v gives 3 mm.  sh = e − em (am_sub): sh > 2 clamps; 0..2 shifts left; a negative sh shifts right by −sh (am_shift) with the sticky of the bits shifted out (≥ 24: 0 with the sticky).  q is clamped to 3 mm; negative (v's sign xor neg): 3 mm − q − sticky (0 when q + sticky ≥ 3 mm), else 3 mm + q (am_add).

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

sim/tb/atg_tu_tb.v (through atg_tu); atg_tu_cube's former and new versions compared on 300,000 random cycles with fp32 inputs near 1 (2026-10-25).

## 9. References

`spec/gpu/tu/atg_tu_cube.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
