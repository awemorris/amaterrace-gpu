# atg_cpu_alu

RTL: `rtl/gpu/cp/atg_cpu_alu.v`.  Parent: atg_cpu_core.  Implemented in: p017.

## 1. Purpose and place

The RV32I integer ALU and branch comparator of atg_cpu_core, combinational.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: none (combinational) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `op` | in | 4 | 0 ADD 1 SUB 2 SLL 3 SLT 4 SLTU 5 XOR 6 SRL 7 SRA 8 OR 9 AND 10 PASS_B (LUI). |
| `a` | in | 32 | Operand a. |
| `b` | in | 32 | Operand b. |
| `y` | out | 32 | Result (SLT/SLTU: 0 or 1, RISC-V). |
| `eq` | out | 1 | a == b (BEQ/BNE). |
| `lt` | out | 1 | signed a < b (BLT/BGE). |
| `ltu` | out | 1 | unsigned a < b (BLTU/BGEU). |

7 ports.

## 4. Behaviour

y = op(a, b); shifts use b[4:0].  eq/lt/ltu are independent of op.

## 5. State machine

None.

## 6. Latency and throughput

Combinational, one level of the core's E stage (the 100/200 MHz targets include it).

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_cpu_alu_tb.v` prints, in this order:

- `PASS atg_cpu_alu.ops` — every op on random and corner operands against a reference
- `PASS atg_cpu_alu.cmp` — eq/lt/ltu on signed/unsigned corners
- `PASS atg_cpu_alu` at the end.

## 9. References

RISC-V unprivileged spec (RV32I).

## 10. Status

Implemented in WS288 p017 (P2, branch p2-cpu); `sim/tb/atg_cpu_alu_tb.v` passes.  Op codes 11-15 give y = 0.
