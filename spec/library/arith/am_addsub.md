# am_addsub

RTL: `rtl/library/arith/am_addsub.v`.  Written for the shared arithmetic (docs/style.md, "Arithmetic",
2026-10-25).

## 1. Purpose and place

A W-bit adder-subtractor: `s = sub ? a - b : a + b`, `co` the carry out of `a + (sub ? ~b : b) + sub` (1 = no borrow for a subtraction).  Every module outside `rtl/library/bus/` that needs this operation on signals instantiates
it; operations of one module that are never used in the same cycle share one instance.

## 2. Parameters

`W` (32).

## 3. Ports

`a`, `b` (W), `sub` / `s` (W), `co`: 5 ports.

## 4. Behaviour

As in 1.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None.

## 8. What the TB checks

`sim/tb/am_arith_tb.v` against the testbench's own arithmetic (8 bits exhaustively, 32 bits at
random).

## 9. References

docs/style.md ("Arithmetic").

## 10. Status

Implemented.  Cells (Vivado OOC, 7 series): One CARRY4 per 4 bits and the XOR of b in the LUTs before it (expected; the OOC run is pending).
