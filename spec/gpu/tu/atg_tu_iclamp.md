# atg_tu_iclamp

RTL: `rtl/gpu/tu/atg_tu_iclamp.v`.  Parent: atg_tu_foot (texf's x, y, z).

## 1. Purpose and place

A signed integer clamped into [0, n − 1]; it replaces the function `iclamp` of atg_tu_foot.  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`v` (33, signed), `n` (16) / `c` (16): 3 ports.

## 4. Behaviour

v < 0: 0; v ≥ n: n − 1 (am_sub); else v.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

sim/tb/atg_tu_addr_tb.v; atg_tu_foot's former and new versions on 200,000 random inputs (2026-10-25).

## 9. References

`spec/gpu/tu/atg_tu_foot.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
