# atg_tu_plane

RTL: `rtl/gpu/tu/atg_tu_plane.v`.  Parent: atg_tu_desc (the level offsets, and rd_plane).

## 1. Purpose and place

P_l, the bytes of the plane of level l of an image, a multiple of 64; it replaces the function `plane` of atg_tu_desc.  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`sz` (32), `tiled`, `blk`, `psl` (3), `ra` (2), `l` (4) / `plane` (32): 7 ports.

## 4. Behaviour

The level's w, h (am_shift, at least 1); linear: rows of w rounded up to 2^ra texels (am_add) × h (am_mul) << psl; compressed: ceil(w / 4) ceil(h / 4) (am_add, am_mul) blocks << psl; tiled: the 4 × 4 tiles × 64 (32 for psl 1); + 63 and the low 6 bits cleared (am_add).  MUT_TU_PITCHOFF: packed rows.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

sim/tb/atg_tu_tb.v; the module against the former function on 1,000,000 random inputs, and atg_tu_desc's former and new versions on 100,000 random cycles (2026-10-25).

## 9. References

`spec/gpu/tu/atg_tu_desc.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
