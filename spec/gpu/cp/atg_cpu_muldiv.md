# atg_cpu_muldiv

RTL: `rtl/gpu/cp/atg_cpu_muldiv.v`.  Parent: atg_cpu_core.  Implemented in: p017.

## 1. Purpose and place

The RV32M unit: MUL/MULH/MULHSU/MULHU on a DSP (3 cycles) and DIV/DIVU/REM/REMU by a 32-step restoring divider.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Reset. |
| `start` | in | 1 | One-cycle start with op, a, b. |
| `op` | in | 3 | funct3 of the M instruction: 0 MUL 1 MULH 2 MULHSU 3 MULHU 4 DIV 5 DIVU 6 REM 7 REMU. |
| `a` | in | 32 | rs1. |
| `b` | in | 32 | rs2. |
| `busy` | out | 1 | 1 from the cycle after start until done. |
| `done` | out | 1 | One-cycle pulse with y. |
| `y` | out | 32 | Result, held until the next start. |

9 ports.

## 4. Behaviour

RISC-V semantics including division by zero (quotient all ones, remainder a) and overflow (INT_MIN / -1 = INT_MIN, remainder 0).

## 5. State machine

IDLE →(start)→ MUL1..MUL3 | DIV (32 steps) + FIX (signs) → IDLE (done).

## 6. Latency and throughput

MUL 3 cycles, DIV 34 cycles; one operation at a time.

## 7. Corner cases and errors

- start while busy is ignored (the core never does it).

## 8. What the TB checks

`sim/tb/atg_cpu_muldiv_tb.v` prints, in this order:

- `PASS atg_cpu_muldiv.mul` — random and corner products of all four MUL forms
- `PASS atg_cpu_muldiv.div` — random quotients/remainders, divide by zero, INT_MIN/-1
- `PASS atg_cpu_muldiv` at the end.

## 9. References

RISC-V unprivileged spec (RV32M).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
