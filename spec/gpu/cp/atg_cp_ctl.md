# atg_cp_ctl

RTL: `rtl/gpu/cp/atg_cp_ctl.v`.  Parent: atg_cp.  Implemented in: p004.

## 1. Purpose and place

The CP's state machine (design §2.6): CTRL (RUN/RESET/HALT/STEP/WDT_EN), STATUS, KICK from the host, HALT and quiesce, the RESET order of design §1.3, the watchdog, and FAULT_ADDR/FAULT_INFO from all fault sources.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NSRC` | `8` | Number of fault sources (0 ring, 1 seq, 2 state, 3 fence, 4 SU, 5 CPU, 6 BLT, 7 other blocks). |
| `WDT_RESET` | `32'h10000000` | WDT_CYCLES after reset (2^28). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **HCR register snoop (from atg_cp_regs)** | | | |
| `hcr_we` | in | 1 | One-cycle write strobe to an HCR word (0x000-0xFFC). |
| `hcr_widx` | in | 10 | Word index of the write (byte offset >> 2). |
| `hcr_wdata` | in | 32 | Write data. |
| `hcr_wmask` | in | 32 | Bit mask from WSTRB (1 = written). |
| `hcr_ridx` | in | 10 | Word index being read; the read data is due in the same cycle (combinational from this registered index). |
| `hcr_rdata` | out | 32 | Read data of this module's registers at `hcr_ridx`, 0 for other indices (the parent ORs them). |
| **Inputs** | | | |
| `mc_idle` | in | 1 | AXI_IDLE from the MC. |
| `mem_ready` | in | 1 | MEM_READY. |
| `busy_in` | in | 8 | STATUS[7:0] busy bits (CP bit 0 included). |
| `ring_empty` | in | 1 | RING_EMPTY. |
| `cmd_active` | in | 1 | The watchdog counts while 1. |
| `mc_fault` | in | 1 | Aperture/AXI fault pulse from the MC. |
| `mc_fault_client` | in | 8 | Its client. |
| `mc_fault_addr` | in | 32 | Its address. |
| `mc_fault_write` | in | 1 | Its direction. |
| `src_fault` | in | NSRC | Fault pulses of the CP modules and blocks. |
| `src_kind` | in | NSRC*4 | Their kinds. |
| `src_addr` | in | NSRC*32 | Their addresses. |
| `src_tag` | in | NSRC*8 | Their JOB_TAGs. |
| **Outputs** | | | |
| `run` | out | 1 | RUNNING. |
| `halt` | out | 1 | Stop at a command boundary (HALTING, HALTED, FAULTED, RESETTING). |
| `quiesce` | out | 1 | To the MC: stop granting. |
| `mc_flush` | out | 1 | MC flush, one cycle of the RESET order. |
| `core_rst_n` | out | 1 | Core reset (design §1.3 domain a), low for one cycle in the RESET order. |
| `open` | out | 1 | IDLE or HALTED. |
| `cp_state` | out | 4 | STATUS[19:16]. |
| `host_kick` | out | 3 | KICK [0] BLIT [1] DRAW [2] DISPATCH, pulses, only when open. |
| `step` | out | 1 | STEP pulse in HALTED. |
| `ev_halted` | out | 1 | Pulse: HALTED reached. |
| `ev_fault` | out | 1 | Pulse: FAULT raised. |
| `ev_wdt` | out | 1 | Pulse: watchdog expired. |

33 ports.

## 4. Behaviour

- Registers: CTRL 0x030, STATUS 0x034 (read), WDT_CYCLES 0x044, FAULT_ADDR 0x068, FAULT_INFO 0x06C,
  KICK 0xF00 (write).  STATUS = {busy_in, AXI_IDLE = mc_idle, FAULT, HALTED, RING_EMPTY, MEM_READY,
  AXI_STUCK, QUIESCED, state} as design §2.2.
- Locked writes (RING_BASE/SIZE, APERTURE_*, CP_HEAP_* outside open) and KICK while RUNNING are faults
  of kind 7 and 6, found by snooping.
- The first fault wins: FAULT_INFO = {tag, block (source number or MC client), kind, write, client},
  FAULT_ADDR; then FAULTED and quiesce until RESET.  MC faults of client 0 (the CP's own debug port)
  are not device faults (atg_cp_dbg reports them).
- RESET (W1S): HALTING → wait `mc_idle` → one cycle `core_rst_n` low and `mc_flush` → IDLE, the bit
  reads 0 again.  AXI_STUCK after 4 × WDT_CYCLES waiting for mc_idle.
- Watchdog: when WDT_EN, a counter of cycles with `cmd_active`; reset when cmd_active falls; at
  WDT_CYCLES → fault kind 4 and ev_wdt.

## 5. State machine

IDLE ↔ RUNNING (RUN), RUNNING →(HALT)→ HALTING →(blocks idle, mc_idle)→ HALTED →(HALT=0)→ RUNNING;
any →(fault)→ FAULTED (quiesce); any →(RESET)→ RESETTING →(mc_idle)→ pulse → IDLE.  One state
register, the table of design §2.6.

## 6. Latency and throughput

Register effects in 1 cycle.

## 7. Corner cases and errors

- RESET while RESETTING is ignored; a fault during RESETTING is ignored.
- The state survives core_rst_n (this module is reset by rst_n only), as the RESET order needs.

## 8. What the TB checks

`sim/tb/atg_cp_ctl_tb.v` prints, in this order:

- `PASS atg_cp_ctl.states` — every transition of the design §2.6 table
- `PASS atg_cp_ctl.reset` — RESET waits for mc_idle, pulses core_rst_n and mc_flush once, the bit falls
- `PASS atg_cp_ctl.stuck` — mc_idle never comes: AXI_STUCK after 4 × WDT_CYCLES
- `PASS atg_cp_ctl.fault` — first fault wins, FAULT_INFO fields, MC client 0 ignored
- `PASS atg_cp_ctl.wdt` — watchdog fires only with WDT_EN and cmd_active
- `PASS atg_cp_ctl.locked` — locked writes and KICK in RUNNING fault with kinds 7 and 6
- `PASS atg_cp_ctl` at the end.

## 9. References

design §1.3 (RESET order, quiesce), §2.2, §2.5, §2.6, the inline code of `rtl/gpu/cp/atg_cp.v` (RESET sequencing, faults).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
