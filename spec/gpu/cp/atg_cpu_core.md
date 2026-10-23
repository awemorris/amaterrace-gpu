# atg_cpu_core

RTL: `rtl/gpu/cp/atg_cpu_core.v`.  Parent: atg_cpu.  Implemented in: p017.

## 1. Purpose and place

The RV32IM pipeline of the CP's control processor: fetch, decode/execute, writeback (3 stages), Machine mode only, one interrupt line, no CSRs but none needed (the control window replaces them).

Children: `atg_cpu_alu`, `atg_cpu_muldiv`.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low (also held low by atg_cpu_fw while firmware is loaded). |
| `run` | in | 1 | 1: execute; 0: stall at the next instruction boundary (CPFW HALT). |
| `stopped` | out | 1 | The pipeline is empty and stalled (run = 0 seen). |
| `irq` | in | 1 | Level interrupt from the window. |
| **Instruction port (IMEM, synchronous BRAM read)** | | | |
| `i_en` | out | 1 | Read enable. |
| `i_addr` | out | 32 | Byte address of the fetch (word aligned). |
| `i_rdata` | in | 32 | Instruction, the cycle after i_en. |
| **Data port (to atg_cpu_win)** | | | |
| `d_valid` | out | 1 | Load or store. |
| `d_write` | out | 1 | Store. |
| `d_addr` | out | 32 | Byte address. |
| `d_wdata` | out | 32 | Store data, already shifted to the byte lanes. |
| `d_be` | out | 4 | Byte enables. |
| `d_ready` | in | 1 | Completed this cycle; for loads d_rdata is valid in this cycle. |
| `d_rdata` | in | 32 | Load data (whole word; the core extracts bytes). |
| **Faults (to atg_cpu_fw)** | | | |
| `fault` | out | 1 | Pulse: illegal instruction, misaligned access, ECALL/EBREAK, or a fetch outside IMEM. |
| `fault_pc` | out | 32 | PC of the faulting instruction. |

17 ports.

## 4. Behaviour

- RV32IM user-level integer instructions (RV32I without FENCE.I semantics: FENCE is a no-op;
  M: MUL/MULH/MULHSU/MULHU through atg_cpu_muldiv's 3-cycle DSP path, DIV/DIVU/REM/REMU through its
  32-cycle divider).  No C, no F, no CSR instructions (CSR*, ECALL, EBREAK, MRET → fault), WFI = stall
  until irq.
- Interrupt: when irq is 1 and the core is between instructions, it jumps to IRQ_VECTOR = 0x10 with
  the return PC in a hidden register; the custom `mret` encoding (0x30200073) returns.  No nesting.
  Reset vector 0x0.
- Loads/stores: one outstanding; the core stalls until d_ready.  Byte/half loads extract and extend.
- ALU (add/sub/shift/compare/logic, branch compare) is atg_cpu_alu, combinational.

## 5. State machine

Pipeline, not an FSM: F (i_en, i_addr = pc) → D/E (decode, ALU, branch resolve, d_* issue,
muldiv start) → W (register write).  Stalls: d_valid && !d_ready, muldiv busy, run = 0.  A taken
branch flushes F (1 bubble).

## 6. Latency and throughput

CPI about 1.3 (1 bubble per taken branch, loads 1-2 wait cycles); 100 MHz on the 7010 -1, 200 MHz on the 325T -2 (design R25).

## 7. Corner cases and errors

- x0 is hard-wired to 0 (this is RISC-V, unlike GSI1).
- A fault stops the core (`stopped` = 1) until reset.

## 8. What the TB checks

`sim/tb/atg_cpu_core_tb.v` prints, in this order:

- `PASS atg_cpu_core.rv32i` — a self-checking subset of riscv-tests (add, sub, logic, shifts, slt, branches, jal/jalr, lui/auipc, loads/stores of all widths)
- `PASS atg_cpu_core.rv32m` — mul/mulh*/div/rem with corner values (div by 0, INT_MIN/-1)
- `PASS atg_cpu_core.irq` — an interrupt enters at 0x10 and mret returns
- `PASS atg_cpu_core.fault` — an illegal instruction pulses fault with its PC and stops
- `PASS atg_cpu_core.stall` — d_ready held low stalls without losing instructions
- `PASS atg_cpu_core` at the end.

## 9. References

design §2.4.7 (atg_cpu), §2.4.8 (firmware), RISC-V unprivileged spec (Values referenced: RV32IM encodings).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
