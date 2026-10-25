# atg_tu_toff

RTL: `rtl/gpu/tu/atg_tu_toff.v`.  Parent: atg_tu_foot (each slot's texel).

## 1. Purpose and place

The byte offset of texel (i, j) in a plane of width w (linear rows, 4 × 4 tiles, or compressed blocks), 32-bit wrap; it replaces the function `toff` of atg_tu_foot.  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`i` (16), `j` (16), `w` (17), `tl`, `pl` (3), `bk` / `off` (32): 7 ports.

## 4. Behaviour

tw = ceil(w / 4) (am_add); one product (am_mul): (j / 4) tw for tiles and blocks, else j w; plus i / 4 or i (am_add); blocks and linear rows << pl (am_shift); tiles: × 64 (32 for pl 1) with the texel's row and column in the tile in the low bits.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

sim/tb/atg_tu_addr_tb.v, sim/tb/atg_tu_tb.v; atg_tu_foot's former and new versions on 200,000 random inputs (2026-10-25).

## 9. References

`spec/gpu/tu/atg_tu_foot.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
