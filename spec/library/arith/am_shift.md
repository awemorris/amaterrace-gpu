# am_shift

RTL: `rtl/library/arith/am_shift.v`.  Written for the shared arithmetic (docs/style.md, "Arithmetic",
2026-10-25).

## 1. Purpose and place

A W-bit barrel shifter by a variable amount: left (`a << amt`), right logical (`a >> amt`) or right arithmetic (`a >>> amt`, the sign shifted in).  `left` and `arith` may be constants; synthesis keeps only the direction used.  Every module outside `rtl/library/bus/` that needs this operation on signals instantiates
it; operations of one module that are never used in the same cycle share one instance.

## 2. Parameters

`W` (32), `SW` (5, the amount bits).

## 3. Ports

`a` (W), `amt` (SW), `left`, `arith` / `y` (W): 5 ports.

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

Implemented.  Cells (Vivado OOC, 7 series): LUTs: log2(W) levels of 2:1 multiplexers, about W x SW LUT inputs (expected; the OOC run is pending).
