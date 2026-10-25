# atg_tu_wrap

RTL: `rtl/gpu/tu/atg_tu_wrap.v`.  Parent: atg_tu_foot (the slice and the footprint's i0, i1, j0, j1).

## 1. Purpose and place

An integer texel coordinate into the level, {border texel, index}; it replaces the functions `tu_wrap` and `tu_mod` of include/atg_tu_fn.vh (tools/tumodel.py wrap_idx).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`i` (24, signed), `n` (16), `mode` (2) / `w` (17): 4 ports.

## 4. Behaviour

Repeat i mod n, mirrored repeat i mod 2n folded (2n − 1 − m beyond n), clamp to edge and to border clamp(i, 0, n − 1) with the border bit for clamp to border outside the level.  i mod p for i in [−9, p + 7]: p ≥ 16 one correction (am_addsub); p < 16 (i + 9) mod p − 9 mod p from a table of constants, + p when negative (am_add, am_sub).

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

The module against the former function on 1,000,000 random inputs, 0 errors (the 1,898 inputs where the function gives X, p = 0, not compared; 2026-10-25); sim/tb/atg_tu_addr_tb.v.

## 9. References

`spec/gpu/tu/atg_tu_addr.md`, `spec/gpu/tu/atg_tu_foot.md`, tools/tumodel.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
