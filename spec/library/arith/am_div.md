# am_div

RTL: `rtl/library/arith/am_div.v`. Written for the shared arithmetic (docs/style.md, "Arithmetic",
2026-10-25; Non-restoring physical optimization in Phase 009).

## 1. Purpose and place

A W-bit unsigned integer divider, one quotient bit per cycle. `start` takes `a` and `b` while `!busy`; `busy` for W cycles; `done` pulses with `q = a / b`, `r = a % b`, held until the next start. `b = 0` gives `q = all ones` and `r = a` (RISC-V divu/remu); signed division is the caller's. Every module outside `rtl/library/bus/` that needs this operation on signals instantiates it; operations of one module that are never used in the same cycle share one instance.

## 2. Architecture & Physical Optimization

To eliminate the restoring multiplexer from the critical feedback path:
1. **Non-Restoring Algorithm**: Employs signed $(W+2)$-bit non-restoring arithmetic via `am_addsub`:
   - If previous remainder $R \ge 0$ (sign bit `rem[W+1] == 0`), subtract divisor: $R_{k+1} = 2 R_k + q_{in} - D$.
   - If previous remainder $R < 0$ (sign bit `rem[W+1] == 1`), add divisor: $R_{k+1} = 2 R_k + q_{in} + D$.
   - Next quotient bit is $q_k = !R_{k+1}[W+1]$.
2. **Direct Flip-Flop Drive**: The output of `am_addsub` connects directly to the register D inputs with zero multiplexer delay on the critical path, eliminating ~0.4 ns of MUX logic from each cycle.
3. **Static Correction Adder**: If the final remainder $R_W < 0$, a correction addition $R = R_W + D$ is performed at `done`. This adder is outside the iterative feedback loop and operates on held registers.
4. **Division by Zero**: $b = 0$ naturally produces $q = \text{all ones}$ and $r = a$ through standard non-restoring execution without special bypass logic.

## 3. Parameters

`W` (32), `CW` (clog2(W+1), the step counter).

## 4. Ports

`clk`, `rst_n`, `start`, `a`, `b` / `busy`, `done`, `q`, `r`: 9 ports.

## 5. Behaviour

As in 1.

## 6. State machine

idle → (start) busy (W cycles) → done for one cycle → idle.

## 7. Latency and throughput

W cycles from start to done; one division at a time.

## 8. Corner cases and errors

- `b == 0`: gives `q = {W{1'b1}}`, `r = a`.
- `a == 0, b != 0`: gives `q = 0, r = 0`.
- `a == b`: gives `q = 1, r = 0`.
- `a < b`: gives `q = 0, r = a`.
- A start while busy is ignored; `rst_n` stops a division.

## 9. What the TB checks

- `sim/tb/am_arith_tb.v`: regression test (8 bits exhaustively, 32 bits at random).
- `sim/tb/am_div_tb.v`: exhaustive test for $W=8$ (65536 combinations), boundary conditions, zero divisor, and randomized $W=32$ vectors.

## 10. References

- `docs/style.md` ("Arithmetic")
- `plan/ws001/phase009/phase.md`

## 11. Status

Implemented and physically optimized with Non-restoring architecture (Phase 009).
