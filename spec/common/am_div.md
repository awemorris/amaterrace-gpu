# am_div

RTL: `rtl/common/am_div.v`.  Written for the shared arithmetic (docs/style.md, "Arithmetic",
2026-10-25).

## 1. Purpose and place

A W-bit unsigned integer divider, one quotient bit per cycle (restoring, one W+1-bit subtractor): `start` takes `a` and `b` while `!busy`; `busy` for W cycles; `done` pulses with `q = a / b`, `r = a % b`, held until the next start.  `b` = 0 gives `q` all ones and `r = a` (RISC-V divu/remu); signed division is the caller's.  Every module outside `rtl/common/` that needs this operation on signals instantiates
it; operations of one module that are never used in the same cycle share one instance.

## 2. Parameters

`W` (32), `CW` (clog2(W+1), the step counter).

## 3. Ports

`clk`, `rst_n`, `start`, `a`, `b` / `busy`, `done`, `q`, `r`: 9 ports.

## 4. Behaviour

As in 1.

## 5. State machine

idle → (start) busy (W cycles) → done for one cycle → idle.

## 6. Latency and throughput

W cycles from start to done; one division at a time.

## 7. Corner cases and errors

A start while busy is ignored; rst_n stops a division.

## 8. What the TB checks

`sim/tb/am_arith_tb.v` against the testbench's own arithmetic (8 bits exhaustively, 32 bits at
random).

## 9. References

docs/style.md ("Arithmetic").

## 10. Status

Implemented.  Cells (Vivado OOC, 7 series): LUTs and one CARRY4 chain of W+1 bits, 3 W flip-flops (expected; the OOC run is pending).
