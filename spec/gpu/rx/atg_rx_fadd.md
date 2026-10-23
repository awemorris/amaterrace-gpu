# atg_rx_fadd

RTL: `rtl/gpu/rx/atg_rx_fadd.v`.  Parent: atg_rx_setup (and atg_rx_clip).  Implemented in: p007.

## 1. Purpose and place

The RX setup's fp32 adder (a + b, or a − b with i_sub).

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `i_valid` | in | 1 | An operation starts this cycle (no back-pressure; one per cycle). |
| `i_a` | in | 32 | Operand a. |
| `i_b` | in | 32 | Operand b. |
| `i_sub` | in | 1 | 1 = a − b (b is negated). |
| `o_valid` | out | 1 | The result is valid, exactly 4 cycles after i_valid. |
| `o_r` | out | 32 | The result. |

8 ports.

## 4. Behaviour

Align the smaller operand by the exponent difference (with guard/sticky), add or subtract the mantissas, normalize (leading-zero count), round to nearest even.

Arithmetic rules (shared by the three RX fp units and the SU, design §3.1): IEEE single, round to nearest even, denormal inputs read as zero and denormal results flushed to zero (sign kept), NaN results are the canonical 0x7FC00000, infinities follow IEEE.

## 5. State machine

None (a pipeline).

## 6. Latency and throughput

4-stage pipeline: one operation per cycle, result exactly 4 cycles after i_valid.

## 7. Corner cases and errors

x + (−x) = +0; inf − inf = NaN; a denormal operand counts as 0; overflow gives ±inf.

## 8. What the TB checks

`sim/tb/atg_rx_fp_tb.v` compares atg_rx_fadd with `tools/rxmodel.py`'s fp model on the vectors in `sim/vec/` (6000 operations across the three units, including zeros, denormals, infinities, NaNs, overflow, ties) and prints `PASS atg_rx_fp`.

## 9. References

design §3.1 (fp rules), §3.8 (RX setup); plan/ws288/phase007/phase.md.

## 10. Status

Implemented in p007 (P3, amaterrace-gpu 8106fc3); this spec written from the RTL by Q1 on 2026-10-24.
