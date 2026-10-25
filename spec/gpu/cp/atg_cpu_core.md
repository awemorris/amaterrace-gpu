# atg_cpu_core

RTL: `rtl/gpu/cp/atg_cpu_core.v`.  Parent: atg_cpu.  Implemented in: p017.

## 1. Purpose and place

The RV32IM pipeline of the CP's control processor: fetch, decode/register read, execute, writeback (4 stages; p017: 3 stages did not meet 100 MHz), Machine mode only, one interrupt line, no CSRs but none needed (the control window replaces them).

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
| `stopped` | out | 1 | run = 0 and no access or multiply/divide in progress (the next instruction will not start), or the core has faulted. |
| `irq` | in | 1 | Level interrupt from the window. |
| **Instruction port (IMEM, synchronous BRAM read)** | | | |
| `i_en` | out | 1 | Read enable. |
| `i_addr` | out | 32 | Byte address of the fetch (word aligned). |
| `i_rdata` | in | 32 | Instruction, the cycle after i_en; held while i_en is 0 (the BRAM output register keeps it, atg_cpu_mem). |
| **Data port (to atg_cpu_win)** | | | |
| `d_valid` | out | 1 | Load or store. |
| `d_write` | out | 1 | Store. |
| `d_addr` | out | 32 | Byte address. |
| `d_wdata` | out | 32 | Store data, already shifted to the byte lanes. |
| `d_be` | out | 4 | Byte enables. |
| `d_ready` | in | 1 | Completed this cycle; for loads d_rdata is valid in this cycle. |
| `d_rdata` | in | 32 | Load data (whole word; the core extracts bytes). |
| **Faults (to atg_cpu_fw)** | | | |
| `fault` | out | 1 | Pulse (the cycle after the faulting instruction reached E): illegal instruction, CSR*/ECALL/EBREAK, misaligned access or jump/branch target, or an instruction fetched outside 0x0000_0000-0x0001_FFFF. |
| `fault_pc` | out | 32 | PC of the faulting instruction: valid with `fault` and held after it (before a fault it follows E). |

17 ports.

## 4. Behaviour

- RV32IM user-level integer instructions (RV32I without FENCE.I semantics: FENCE is a no-op;
  M: MUL/MULH/MULHSU/MULHU through atg_cpu_muldiv's 3-cycle DSP path, DIV/DIVU/REM/REMU through its
  32-cycle divider).  No C, no F, no CSR instructions (CSR*, ECALL, EBREAK, MRET → fault), WFI = stall
  until irq.
- Interrupt: when irq is 1, the core is not in the handler and run = 1, it is taken before the
  instruction in E starts: the hidden mepc gets that instruction's PC (a WFI's PC + 4: the WFI
  completes), the core jumps to IRQ_VECTOR = 0x10, and `mret` (0x30200073) jumps to mepc and leaves
  the handler.  No nesting: irq is ignored inside the handler.  irq is masked by the window's IRQ_EN
  (atg_cpu_win), so the firmware decides when it may come.  Reset vector 0x0.
- WFI (0x10500073) completes when irq is 1 (inside the handler too); FENCE and FENCE.I are no-ops.
- Loads/stores: one outstanding; the core stalls until d_ready.  Byte/half loads extract and extend.
- ALU (add/sub/shift/compare/logic, branch compare) is atg_cpu_alu, combinational.

## 5. State machine

Pipeline, not an FSM: F (i_en, i_addr = pc) → D (register read of i_rdata's rs1/rs2, taking the
value W writes in that cycle) → E (decode, ALU, branch resolve, d_* issue, muldiv start; an operand
takes W's value when W holds the instruction just before) → W (result register, register file
write).  No stall for data hazards (the two forwarding paths cover them).  Stalls: d_valid &&
!d_ready, muldiv busy, WFI, run = 0 (D and F wait; i_en = 0).  A taken branch, jump, mret or
interrupt refetches (2 bubbles).

## 6. Latency and throughput

CPI about 1.3 (2 bubbles per taken branch, loads 1-2 wait cycles; measured 1.27 on rv32i with the data port answering at once); 100 MHz on the 7010 -1, 200 MHz on the 325T -2 (design R25).

## 7. Corner cases and errors

- x0 is hard-wired to 0 (this is RISC-V, unlike GSI1).
- A fault stops the core (`stopped` = 1, no fetch, no access) until reset.
- run = 0 while a load/store waits or a multiply/divide runs: it completes (d_valid stays up until
  d_ready), then the core stops.

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

Implemented in WS288 p017 (P2, branch p2-cpu); `sim/tb/atg_cpu_core_tb.v` passes.  The test
programs are `sim/tb/cpu/*.S` (rv32i/rv32m generated by `gen.py` with a Python reference model),
built into committed `.hex` images by `tools/cpu-tests.sh`.  p017 spec changes: 4 stages (F, D, E,
W, with forwarding from W into D and E) instead of 3, because the 3-stage form (BRAM → register
read → ALU → data decode → load data → register write in one cycle) had WNS -8.2 ns at 10 ns on
the 7010; the IRQ_EN mask of the window; i_rdata held while i_en = 0; the fault causes made exact.
