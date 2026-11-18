# atg_cpu_fw

RTL: `rtl/gpu/cp/atg_cpu_fw.v`.  Parent: atg_cpu.  Implemented in: p017.

## 1. Purpose and place

The CPFW extended capability (design §2.4.10): CPFW_CTRL/STATUS/IBASE/IWORDS/DBASE/DWORDS/VERSION on the HCR (0x120-0x138) and CPFW_MBOX0-3 (0x150-0x15C), the image reload sequence, the core's run/reset, and the firmware fault report.

HCR layout (p017, Q1 2026-10-23: the 11 registers do not fit 0x120-0x13F and SA is fixed at
0x140; offsets in `include/ghci_regs.vh`/`.h` as `GHCI_CPFW_*`):

| Offset | Name | Access | Meaning |
| --- | --- | --- | --- |
| 0x120 | CPFW_CTRL | RW | [0] LOAD (W1S; reads 1 while loading), [1] RUN, [2] HALT |
| 0x124 | CPFW_STATUS | R | [0] READY, [1] FAULT, [2] ALIVE, [3] STOPPED (core stopped or held in reset), [4] LOADING, [15:8] firmware state |
| 0x128 | CPFW_IBASE | RW | GPU address of the IMEM image (line aligned) |
| 0x12C | CPFW_IWORDS | RW | its words |
| 0x130 | CPFW_DBASE | RW | GPU address of the DMEM image |
| 0x134 | CPFW_DWORDS | RW | its words |
| 0x138 | CPFW_VERSION | R | written by the firmware (window 0x25) |
| 0x13C | - | R | 0 |
| 0x150-0x15C | CPFW_MBOX0-3 | RW | shared with the firmware (window 0x21-0x24) |

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Reset (board reset; core_rst_n restarts the firmware too). |
| **HCR register snoop (from atg_cp_regs)** | | | |
| `hcr_we` | in | 1 | One-cycle write strobe to an HCR word (0x000-0xFFC). |
| `hcr_widx` | in | 10 | Word index of the write (byte offset >> 2). |
| `hcr_wdata` | in | 32 | Write data. |
| `hcr_wmask` | in | 32 | Bit mask from WSTRB (1 = written). |
| `hcr_ridx` | in | 10 | Word index being read; the read data is due in the same cycle (combinational from this registered index). |
| `hcr_rdata` | out | 32 | Read data of this module's registers at `hcr_ridx`, 0 for other indices (the parent ORs them). |
| **Window sub-bus (from atg_cpu_win)** | | | |
| `sb_we` | in | 1 | Write strobe (one cycle). |
| `sb_re` | in | 1 | Read strobe; data in the same cycle (combinational). |
| `sb_idx` | in | 6 | Window word index. |
| `sb_wdata` | in | 32 | Write data. |
| `sb_rdata` | out | 32 | Read data for this module's indices, else 0. |
| **To atg_cpu_dma** | | | |
| `ld_start` | out | 1 | Image load. |
| `ld_imem` | out | 1 | IMEM. |
| `ld_addr` | out | 32 | Address. |
| `ld_words` | out | 32 | Words. |
| `ld_done` | in | 1 | Done. |
| `ld_error` | in | 1 | Error. |
| **Core control** | | | |
| `core_rst_n` | out | 1 | Holds the core in reset during a load and after a fault until RESET. |
| `core_run` | out | 1 | CPFW_CTRL.RUN and not halted. |
| `core_stopped` | in | 1 | The core is stopped. |
| `core_fault` | in | 1 | Core fault pulse. |
| `core_fault_pc` | in | 32 | Its PC. |
| `halt_req` | in | 1 | CTRL.HALT from atg_cp_ctl (stop after the current packet). |
| `open` | in | 1 | IDLE/HALTED (LOAD allowed). |
| **Fault (to atg_cp_ctl, source 5)** | | | |
| `fault` | out | 1 | Firmware fault pulse (kind 4). |
| `fault_addr` | out | 32 | PC. |

28 ports.

## 4. Behaviour

- CPFW_CTRL [0] LOAD (W1S: only when open and the core is stopped or held in reset, and no load
  runs; else ignored), [1] RUN, [2] HALT.  LOAD: hold core reset, load IMEM from IBASE/IWORDS, DMEM
  from DBASE/DWORDS, then READY; the core restarts at 0 (if RUN) when the reset is released.
- CPFW_STATUS [0] READY (image present: 1 from configuration because the bitstream holds it, 0
  from LOAD until it succeeds), [1] FAULT, [2] ALIVE (toggles on each firmware FW_STATUS write),
  [3] STOPPED, [4] LOADING, [15:8] the firmware's state.
- rst_n is atg_cpu's rst_n, the CP's core_rst_n (CTRL.RESET).  IBASE/IWORDS/DBASE/DWORDS and READY
  survive it (design §2.6): they have no reset (initial values 0 and READY 1 from configuration).
  CTRL, FAULT, ALIVE, the state, VERSION and MBOX0-3 are cleared by it.
- Halt: core_run = RUN && !(PARK && (CTRL.HALT || halt_req)).  The firmware sees the halt request
  (window IRQ[2]), finishes its packet and writes FW_STATUS with [16] PARK = 1; the core then stops
  at the next instruction boundary (so it never stops inside a packet).  PARK clears when no halt
  is requested, and the core runs on.  Clearing RUN stops the core at once (for LOAD while IDLE).
- MBOX0-3 are shared: host and firmware both read and write them (last writer wins; the
  firmware's write wins a same-cycle collision).  Host writes use WSTRB.

## 5. State machine

IDLE →(LOAD)→ LOAD_I →(ld_done)→ LOAD_D →(ld_done)→ IDLE (READY).  Core: RUNNING / FAULTED (core held in reset).

## 6. Latency and throughput

-

## 7. Corner cases and errors

- A load error leaves READY 0 and FAULT 1 and the core held in reset; a later good LOAD clears
  FAULT and sets READY.
- A core fault: FAULT 1, `fault` pulse with the PC, the core held in reset until RESET (or LOAD).

## 8. What the TB checks

`sim/tb/atg_cpu_fw_tb.v` prints, in this order:

- `PASS atg_cpu_fw.regs` — register read/write and reset values
- `PASS atg_cpu_fw.load` — LOAD sequences two loads with the core in reset, then READY
- `PASS atg_cpu_fw.fault` — a core fault sets FAULT and reports kind 4 with the PC
- `PASS atg_cpu_fw` at the end.

## 9. References

design §2.4.7, §2.4.10 (CPFW registers), §2.6 (kept over RESET).

## 10. Status

Implemented in WS288 p017 (P2, branch p2-cpu); `sim/tb/atg_cpu_fw_tb.v` passes.  p017 spec
changes: the HCR layout (MBOX at 0x150, agreed with Q1), STATUS [3] STOPPED and [4] LOADING, the
PARK handshake for HALT, the reset rules (kept registers without reset), LOAD also while the core
is held in reset.
