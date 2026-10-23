# atg_cp_seq

RTL: `rtl/gpu/cp/atg_cp_seq.v`.  Parent: atg_cp.  Implemented in: p004.

## 1. Purpose and place

The class N µop sequencer: takes µop packets from the ring or from the firmware (UOP_FIFO), writes STATE, kicks the blocks, waits for idle, and hands fences, results and WAIT_FENCE to atg_cp_fence.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **µop packets from the ring (atg_cp_ring)** | | | |
| `n_valid` | in | 1 | Dword valid. |
| `n_ready` | out | 1 | Taken. |
| `n_data` | in | 32 | Header then payload. |
| `n_last` | in | 1 | Last dword. |
| **µop packets from the firmware (atg_cpu UOP_FIFO)** | | | |
| `fw_valid` | in | 1 | Dword valid. |
| `fw_ready` | out | 1 | Taken. |
| `fw_data` | in | 32 | Header then payload (same envelope). |
| `fw_last` | in | 1 | Last dword. |
| `fw_active` | in | 1 | A class V packet is being processed: take µops from fw_* only. |
| `halt` | in | 1 | Do not start a new µop (HALTING/FAULTED/RESETTING). |
| **STATE writes (to atg_cp_state)** | | | |
| `uop_we` | out | 1 | Write. |
| `uop_idx` | out | 9 | Index. |
| `uop_wdata` | out | 32 | Value. |
| **Kicks (one-cycle pulses)** | | | |
| `blt_kick` | out | 1 | BLIT. |
| `draw_kick` | out | 1 | DRAW (VF). |
| `cs_kick` | out | 1 | DISPATCH (the SUs; gx/gy/gz are in STATE 0x1E9-0x1EB). |
| `lc_kick` | out | 1 | LOAD_CONST (the SUs' constant banks; region/addr/words in STATE 0x1EC-0x1EE). |
| `raw_kick` | out | 1 | DRAW_RAW (RX; 9 words in STATE 0x1E0-0x1E8). |
| `inv` | out | 4 | INVALIDATE mask pulse: [0] D$, [1] T$, [2] constant, [3] I$ (DRAW also pulses [1:0]). |
| `perf_reset` | out | 1 | PERF_RESET. |
| `busy_in` | in | 8 | Block busy levels, STATUS[7:0] order (CP bit 0 ignored). |
| `vsync` | in | 1 | One-cycle pulse per display vsync (WAIT_VSYNC), 0 without a DC. |
| **Fences (to atg_cp_fence)** | | | |
| `f_valid` | out | 1 | Request valid. |
| `f_ready` | in | 1 | Taken. |
| `f_op` | out | 2 | 0 FENCE, 1 RESULT, 2 WAIT_FENCE. |
| `f_addr` | out | 32 | Address. |
| `f_value` | out | 32 | FENCE/WAIT_FENCE value, RESULT status. |
| `f_aux` | out | 32 | RESULT aux. |
| `f_irq` | out | 1 | FENCE flags[0]. |
| `f_busy` | in | 1 | The fence unit has work outstanding (WAIT_FENCE polling, writes unanswered). |
| **Status** | | | |
| `busy` | out | 1 | A µop is executing (STATUS[0] with the ring's busy). |
| `cmd_active` | out | 1 | A command is running: the watchdog counts (atg_cp_ctl). |
| **Fault report to atg_cp_ctl (one source of its `src_*` vectors)** | | | |
| `fault` | out | 1 | One-cycle pulse: this module found a fault. |
| `fault_kind` | out | 4 | FAULT_INFO[15:12] kind (design §2.2), valid with the pulse. |
| `fault_addr` | out | 32 | FAULT_ADDR value (address or PC), valid with the pulse. |
| `fault_tag` | out | 8 | JOB_TAG of the command at fault, valid with the pulse. |

38 ports.

## 4. Behaviour

- Header (design §2.4.2): class 0 standard µops op 0-13, class 1 vendor (0 DRAW_RAW, 1 DBG_MARK).
  Semantics per design §2.4.3: SET_REG (index ≥ 512 → fault kind 3), BLIT (flags[0]: wait for BLT
  idle), DRAW (pulse inv[1:0], draw_kick, wait until VF/SU/RX/ROP idle before the next DRAW only if
  flags say so — v1 waits for VF idle), DISPATCH (write gx/gy/gz to STATE 0x1E9-0x1EB then cs_kick),
  FENCE (wait until every block in busy_in is idle, then f_op 0), WAIT_IDLE (flags = block mask,
  0 = all), LOAD_CONST (write 0x1EC-0x1EE, wait SU idle, lc_kick, wait SU idle), LOAD_PROGRAM
  (inv[3]), WAIT_FENCE (f_op 2, wait !f_busy), PERF_RESET, WAIT_VSYNC (wait one vsync), INVALIDATE
  (flags → inv), RESULT (wait for the earlier writes: f_busy 0, then f_op 1), DRAW_RAW (9 words →
  0x1E0-0x1E8, raw_kick), DBG_MARK (STATE 0x1FF).  Unknown op → fault kind 2.
- Source select: `fw_active` 1 → fw_*, else n_*.  The ring does not hand over a new packet while a
  class V packet is open, so the order is the ring's.
- `cmd_active` is 1 from a header until its µop has finished; while waiting on fw_valid = 0
  (the firmware is computing) it is 0, so the watchdog does not count the firmware's DMA waits twice
  (atg_cpu reports its own stalls).

## 5. State machine

IDLE →(header)→ DECODE → {PAYLOAD (SET_REG pairs / payload into STATE) | KICK | WAIT_IDLE |
FENCE_REQ → FENCE_WAIT | VSYNC_WAIT} → IDLE.  halt is looked at in IDLE only.

## 6. Latency and throughput

One SET_REG pair per 2 cycles (one dword per cycle); kick 1 cycle after the header.

## 7. Corner cases and errors

- A payload shorter than the op needs (n too small) is fault kind 3; longer is skipped.
- Faults stop the sequencer (it waits for the core reset).

## 8. What the TB checks

`sim/tb/atg_cp_seq_tb.v` prints, in this order:

- `PASS atg_cp_seq.setreg` — SET_REG pairs reach uop_we in order; index 512 faults
- `PASS atg_cp_seq.kicks` — BLIT/DRAW/DISPATCH/DRAW_RAW write their payload to STATE then pulse their kick
- `PASS atg_cp_seq.wait` — WAIT_IDLE with a mask waits only for those busy bits
- `PASS atg_cp_seq.fence` — FENCE waits for idle then requests; RESULT waits for f_busy 0
- `PASS atg_cp_seq.source` — fw_active switches the source; µops of the two sources never interleave
- `PASS atg_cp_seq.badop` — op 14 and vendor op 5 fault kind 2
- `PASS atg_cp_seq` at the end.

## 9. References

design §2.4.3 (µops), §2.5 (FENCE), §3.8 (DRAW order), §2.3 (STATE).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
