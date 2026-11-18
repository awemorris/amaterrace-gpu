# atg_tu_cube_texel

RTL: `rtl/gpu/tu/atg_tu_cube_texel.v`.  Parent: atg_tu_foot (the four texels of a cube footprint).

## 1. Purpose and place

A texel of a cube face's bilinear footprint, taking a texel beyond one edge from the adjacent face; it replaces the function `tu_cube_texel` of include/atg_tu_fn.vh (tools/tumodel.py cube_texel).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`tface` (3), `i` (24, signed), `j` (24, signed), `n` (16) / `t` (35, {face, i, j}): 5 ports.

## 4. Behaviour

On the face: {face, i, j}; beyond one edge: the adjacent face and i', j' from CUBE_ADJ (0, n − 1, a or n − 1 − a, am_sub); beyond two (a corner): the face's own corner texel (i and j clamped).

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
