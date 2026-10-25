# atg_tu_tcrd

RTL: `rtl/gpu/tu/atg_tu_tcrd.v`.  Parent: atg_tu_addr (stage A of each lane).

## 1. Purpose and place

A lane's texel coordinates with 8 fraction bits, moved out of atg_tu_addr (whose source would otherwise pass 400 lines) when its arithmetic became modules.  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`cw0`, `cw1`, `cw4` (32), `mu`, `mv`, `mw` (2), `wl`, `hl`, `dl` (16), `fcs`, `fct` (27, signed), `cube`, `unn` / `cu`, `cv`, `cw` (31, signed): 16 ports.

## 4. Behaviour

(atg_tu_coord of the coordinate) × the level's size >> 16 (am_mul), a cube's face coordinate × the face size >> 16 (am_mul), or atg_tu_unnorm for unnormalized coordinates.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

atg_tu_addr's former and new versions on 100,000 random cycles (2026-10-25); sim/tb/atg_tu_addr_tb.v, sim/tb/atg_tu_tb.v.

## 9. References

`spec/gpu/tu/atg_tu_addr.md`, `spec/gpu/tu/atg_tu_foot.md`, tools/tumodel.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
