# am_shift

RTL: `rtl/library/arith/am_shift.v`. Written for the shared arithmetic (docs/style.md, "Arithmetic",
2026-10-25; physical optimization with Bit Reversal in Phase 009).

## 1. Purpose and place

A W-bit barrel shifter by a variable amount: left (`a << amt`), right logical (`a >> amt`) or right arithmetic (`a >>> amt`, the sign shifted in). `left` and `arith` may be constants; synthesis keeps only the direction used. Every module outside `rtl/library/bus/` that needs this operation on signals instantiates it; operations of one module that are never used in the same cycle share one instance.

## 2. Architecture & Physical Optimization

To eliminate duplicate parallel barrel shifters and post-multiplexer layers:
1. **Bit Reversal on Left Shift**: Left shift is performed by reversing the input bits (`rev_a[i] = a[W - 1 - i]`), passing through a single sign-extended right shifter, and reversing the output bits. Bit reversals are wiring-only constructs (0 LUTs, 0 ns delay).
2. **Unified Extended Right Shifter**: A single sign-extended `(W+1)`-bit arithmetic right shifter (`ext_data >>> amt`) is shared across all modes:
   - Left shift: input `rev_a`, fill bit `0`.
   - Logical right: input `a`, fill bit `0`.
   - Arithmetic right: input `a`, fill bit `a[W-1]`.
3. **Delay & Area Reduction**: Replaces 3 parallel barrel shifters and 2 MUX levels with 1 barrel shifter and pre/post 2:1 multiplexing. Reduces LUT usage by 50-60% and cuts logic depth from 5-6 LUT levels down to 3 LUT levels (saving ~1.2 ns on 7-series).

## 3. Parameters

`W` (32), `SW` (5, the amount bits).

## 4. Ports

`a` (W), `amt` (SW), `left`, `arith` / `y` (W): 5 ports.

## 5. Behaviour

As in 1. An amount of `W` or more gives 0 (or all sign bits).

## 6. State machine

None (combinational).

## 7. Latency and throughput

Combinational (single barrel shifter path).

## 8. Corner cases and errors

- `amt == 0`: passes input unchanged.
- `amt >= W`: fills all output bits with 0 (for left or logical right) or `a[W-1]` (for arithmetic right).

## 9. What the TB checks

- `sim/tb/am_arith_tb.v`: regression test (8 bits exhaustively, 32 bits at random).
- `sim/tb/am_shift_tb.v`: equivalence test across multiple widths ($W=8, 16, 24, 32, 48$), all shift amounts ($0 \le amt \le W+2$), and all modes against reference behavior.

## 10. References

- `docs/style.md` ("Arithmetic")
- `plan/ws001/phase009/phase.md`

## 11. Status

Implemented and physically optimized (Phase 009).
