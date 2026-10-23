# atg_rx_fdiv

RTL: `rtl/gpu/rx/atg_rx_fdiv.v`.  Parent: atg_rx_setup (and atg_rx_clip).  Implemented in: p007.

## 1. Purpose and place

The RX setup's fp32 divider a / b (perspective divide, 1/w).

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `i_start` | in | 1 | Start a division; taken only while !busy. |
| `i_a` | in | 32 | Dividend. |
| `i_b` | in | 32 | Divisor. |
| `busy` | out | 1 | A division is running. |
| `o_done` | out | 1 | One cycle: o_r holds the quotient. |
| `o_r` | out | 32 | The quotient (held until the next start). |

8 ports.

## 4. Behaviour

Restoring division, one quotient bit per cycle (24 bits + guard, with sticky from the remainder), then round to nearest even (correctly rounded).

Arithmetic rules (shared by the three RX fp units and the SU, design §3.1): IEEE single, round to nearest even, denormal inputs read as zero and denormal results flushed to zero (sign kept), NaN results are the canonical 0x7FC00000, infinities follow IEEE.

## 5. State machine

IDLE → RUN (one quotient bit per cycle) → DONE (o_done for one cycle) → IDLE.

## 6. Latency and throughput

Iterative: 27 cycles from i_start to o_done, 2 cycles for special cases; one division at a time.

## 7. Corner cases and errors

x/0 = ±inf (x ≠ 0), 0/0 and inf/inf = NaN, a denormal operand counts as 0.

## 8. What the TB checks

`sim/tb/atg_rx_fp_tb.v` compares atg_rx_fdiv with `tools/rxmodel.py`'s fp model on the vectors in `sim/vec/` (6000 operations across the three units, including zeros, denormals, infinities, NaNs, overflow, ties) and prints `PASS atg_rx_fp`.

## 9. References

design §3.1 (fp rules), §3.8 (RX setup); plan/ws288/phase007/phase.md.

## 10. Status

Implemented in p007 (P3, amaterrace-gpu 8106fc3); this spec written from the RTL by Q1 on 2026-10-24.
