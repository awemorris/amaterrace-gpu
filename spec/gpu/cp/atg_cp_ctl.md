# atg_cp_ctl

RTL: `rtl/gpu/cp/atg_cp_ctl.v`.  Parent: atg_cp.  Implemented in: p004 (done).

## 1. Purpose and place

The CP's state machine (design §2.6): CTRL (RUN/RESET/HALT/STEP/WDT_EN), STATUS, KICK from the host, HALT and quiesce, the RESET order of design §1.3, the watchdog, and FAULT_ADDR/FAULT_INFO from all fault sources.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NSRC` | `8` | Number of fault sources (0 ring, 1 seq, 2 state, 3 fence, 4 SU, 5 CPU, 6 BLT, 7 other blocks). |
| `WDT_RESET` | `32'h10000000` | WDT_CYCLES after reset (2^28). |
| `LINE_SHIFT` | `5` | The aperture registers' alignment. |
| `UNITS` | `8'h03` | Present blocks (STATUS order): KICK.DRAW needs bit 2, KICK.DISPATCH bit 6, else fault kind 2. |
| `SRC_BLOCK` | `64'h00_01_00_06_00_00_00_00` | FAULT_INFO[23:16] per source (BLT 1, SU 6, the CP's own 0). |
| `SRC_CLIENT` | `64'h00_01_00_00_00_00_00_00` | FAULT_INFO[7:0] per source (BLT client 1). |

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
| `ring_busy` | in | 1 | The ring is inside a packet: HALTING waits for it to be 0 (a packet boundary). |
| `cmd_active` | in | 1 | The watchdog counts while 1. |
| `replay_busy` | in | 1 | atg_cp_state's replay after the RESET pulse: RESETTING lasts while 1. |
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
| `aperture_base` | out | 32 | APERTURE_BASE (0x060), line-aligned, written only when open, kept over RESET. |
| `aperture_limit` | out | 32 | APERTURE_LIMIT (0x064), the same. |

37 ports.

## 4. Behaviour

- Registers: CTRL 0x030, STATUS 0x034 (read), WDT_CYCLES 0x044, FAULT_ADDR 0x068, FAULT_INFO 0x06C,
  KICK 0xF00 (write).  STATUS = {busy_in, AXI_IDLE = mc_idle, FAULT, HALTED, RING_EMPTY, MEM_READY,
  AXI_STUCK, QUIESCED, state} as design §2.2.
- Locked writes (RING_BASE/SIZE, APERTURE_*, CP_HEAP_* outside open) and KICK while RUNNING are faults
  of kind 7 and 6, found by snooping.
- The first fault wins: FAULT_INFO = {tag, block (source number or MC client), kind, write, client},
  FAULT_ADDR; then FAULTED and quiesce until RESET.  MC faults of client 0 (the CP's own debug port)
  are not device faults (atg_cp_dbg reports them).
- RESET (W1S, from any state): RESETTING (quiesce) → wait `mc_idle` → one cycle `core_rst_n` low and
  `mc_flush` (RUN, HALT, FAULT_*, AXI_STUCK cleared) → the STATE replay (`replay_busy`, 513 cycles) →
  IDLE, the bit reads 0 again.  From RUNNING it does not pass HALTING (the quiesce is the same).
- HALT quiesces at once (the p003 choice: blocks freeze at their next memory access); HALTING →
  HALTED when `mc_idle` and `!ring_busy`.  Once HALTED it stays HALTED while memory is busy again
  (the debug port, a fence poll).  RUNNING → IDLE (RUN = 0) waits for STATUS[0] (CP busy) to be 0.
- `run` = RUNNING and CTRL.RUN; `halt` = HALTING, HALTED, FAULTED or RESETTING; `quiesce` = `halt`
  (atg_cp lifts it for its own MC client).  STEP pulses `step` only in HALTED.
- KICK of a present unit when not open or while it is busy: kind 6; of an absent unit: kind 2.
- First-fault priority in one cycle: the MC, KICK (6), KICK absent (2), locked (7), the watchdog (4),
  then src 0..NSRC-1.  FAULT_INFO of src k: {tag, SRC_BLOCK[k], kind, 4'b0, SRC_CLIENT[k]}; of KICK,
  locked and watchdog: {0, 0, kind, 0, 0}; of the MC: {0, client, 1, 3'b0, write, client}.  AXI_STUCK after 4 × WDT_CYCLES waiting for mc_idle.
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

Implemented (WS288 p004 (P3, amaterrace-gpu p3-cp 4a4d2da..65cc445, merged as a094748)).  326 lines, one state register (IDLE, RUNNING, HALTING, HALTED, FAULTED,
RS_WAIT, RS_PULSE, RS_REPLAY).  Spec changes in p004: the parameters `LINE_SHIFT`, `UNITS`,
`SRC_BLOCK`, `SRC_CLIENT`; the ports `ring_busy`, `replay_busy`, `aperture_base/limit`.  Remaining
differences from design §2.6: HALTING does not wait for the blocks' asynchronous work (p003 choice,
the blocks freeze); RESET from RUNNING skips HALTING; the watchdog fault's job tag is 0.
