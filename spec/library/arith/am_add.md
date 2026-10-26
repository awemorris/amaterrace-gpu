# am_add

RTL: `rtl/library/arith/am_add.v`.  Written for the shared arithmetic (docs/style.md, "Arithmetic",
2026-10-25).

## 1. Purpose and place

A W-bit adder with carry in and out: `{co, s} = a + b + ci`, combinational.  Every module outside `rtl/library/bus/` that needs this operation on signals instantiates
it; operations of one module that are never used in the same cycle share one instance.

## 2. Parameters

`W` (32).

## 3. Ports

`a`, `b` (W), `ci` / `s` (W), `co`: 5 ports.

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

Implemented.  Cells (Vivado OOC, 7 series): One CARRY4 per 4 bits (expected; the OOC run is pending).
