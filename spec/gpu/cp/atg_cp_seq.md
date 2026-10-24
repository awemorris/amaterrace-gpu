# atg_cp_seq

RTL: `rtl/gpu/cp/atg_cp_seq.v`.  Parent: atg_cp.  Child: `atg_cp_seq_wait` (the waits).  Implemented in: p004 (done).

## 1. Purpose and place

The class N µop sequencer: takes µop packets from the ring or from the firmware (UOP_FIFO), writes STATE, kicks the blocks, waits for idle, and hands fences, results and WAIT_FENCE to atg_cp_fence.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `UNITS` | `8'h03` | Present blocks in STATUS busy-bit order; a µop of an absent unit (DRAW: VF, DISPATCH/LOAD_CONST: SU, DRAW_RAW: RX, BLIT: BLT) is a fault of kind 2. |
| `HAS_VSYNC` | `0` | 1: WAIT_VSYNC is accepted (CAPS[10]); 0: fault kind 2. |

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
| `occ_count` | in | 40 | (CAPS[30]) The occlusion counter (atg_rop_occ), for QUERY. |
| `occ_clear` | out | 1 | (CAPS[30]) One cycle: clear the counter (QUERY flags[0], or flags[1] with the write's request). |
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
- As implemented (the rules are in `atg_cp_seq_wait`): SET_REG to the BLT range waits while the BLT is busy (the RX range 0x050-0x06F and the ROP range 0x070-0x08F while the VF, the SUs, the RX or the ROP are: the ROP's busy covers only the sequence numbers the RX has issued, so a draw still in the VF, in a vertex warp or in the RX's setup would otherwise be drawn with the next draw's RX or ROP state — MS_CTRL and SAMPLE_KILL included; WS288 p009 part C: the TU range 0x090-0x18F while the TU, the RX or the SUs are, which hold fragments still to be textured; its state must not change
  under a blit); DISPATCH and LOAD_CONST payload writes wait while the SUs are busy, DRAW_RAW's while
  the RX is; BLIT waits for the BLT idle before its kick; a wait after a kick starts one cycle later.
  RESULT waits for every block idle and `f_busy` 0; FENCE for every block idle (the fence unit takes
  one request at a time).  A SET_REG with odd n is short (kind 3); `fault_addr` of a bad index is the
  index.
- The parent (atg_cp) drives `halt` only in FAULTED and RESETTING: in HALTING/HALTED the ring
  already stops at packet boundaries, and a packet handed over (also by STEP) runs to its end.
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
- `PASS atg_cp_seq.kicks` — BLIT/DRAW/DISPATCH/DRAW_RAW write their payload to STATE then pulse their kick; SET_REG into the BLT and the VF ranges waits for that block, into the TU range for the SUs
- `PASS atg_cp_seq.drawstate` — SET_REG of RX state (0x05E) and ROP state (0x07A) right after a DRAW waits until the VF is idle, of ROP state (0x072) during a DISPATCH until the SUs are; the monitor fails any write to 0x050-0x08F while busy_in[2], [3], [4] or [6] is set (the earlier rule, RX/ROP only, fails it: `-DMUT_SEQ_DRAWSTATE`)
- `PASS atg_cp_seq.tuwait`, `.progwait`, `.ldconst`, `.attrlimit_wait` — right after a DRAW (the VF busy): TU state 0x095, FS_BASE 0x192, a LOAD_CONST's kick and ATTR_LIMIT 0x1D2 wait until the VF is idle (monitors: the TU range not while the VF is busy, the program range not while the VF, the RX or the SUs are, LOAD_CONST not while the VF or the RX is, 0x1C0-0x1DF not while the VF is); the earlier rules (`-DMUT_SEQ_DRAWSTATE`) fail all four
- `PASS atg_cp_seq.wait` — WAIT_IDLE with a mask waits only for those busy bits
- `PASS atg_cp_seq.fence` — FENCE waits for idle then requests; RESULT waits for f_busy 0
- `PASS atg_cp_seq.query` — (CAPS[30]) QUERY flags[0] clears at once while the BLT is busy; flags 0 waits for every block and the fence unit, then requests op 1 with addr, the counter's low word and its high bits; flags[1] clears with the request
- `PASS atg_cp_seq.source` — fw_active switches the source; µops of the two sources never interleave
- `PASS atg_cp_seq.badop` — op 14 and vendor op 5 fault kind 2
- `PASS atg_cp_seq` at the end.

## 9. References

design §2.4.3 (µops), §2.5 (FENCE), §3.8 (DRAW order), §2.3 (STATE).

## 10. Status

Implemented (WS288 p004 (P3, amaterrace-gpu p3-cp 4a4d2da..65cc445, merged as a094748)).  397 lines, one FSM (IDLE, PAY, EXEC, POST, FREQ, FWAIT, VSYNC, DEAD).  Spec
change in p004: the parameters `UNITS`, `HAS_VSYNC`.  Not checked against real VF/SU/RX blocks (they
are later Phases); the TB uses busy models.

WS288 p009 part B1 (P1): SET_REG into the VF's ranges (STATE 0x020-0x04F and ATTR_DST 0x1C0-0x1CF) waits while the VF is busy (busy_in[2]), like the BLT, RX and ROP ranges (the VF reads its STATE during the draw).  406 lines (the earlier count of 397 was before later changes; the line limit is over by 6, unchanged by this step).

WS288 p009 part C (P1, branch p1-tu): SET_REG into the TU's range (STATE 0x090-0x18F, the 16 texture slots) waits while the TU, the RX or the SUs are busy (busy_in[5], [3], [6]): a fragment that has not been textured yet may sit in the RX or in an SU's warp, and the TU reads the slot's words per quad.  408 lines (+2; the split for the line limit stays with p016).  The TB's kicks case writes 0x095 during a DISPATCH and checks that it waits.

WS288 p008 (P2, branch p2-dispatch): the compute µops are checked against the real SU in `sim/tb/atg_top_cs_tb.v` (atg_top with NSU 1): SET_REG of the program range, INVALIDATE (flags 1, D$), LOAD_PROGRAM (inv[3]), LOAD_CONST (0x1EC-0x1EE, lc_kick, waits for the SU), DISPATCH (0x1E9-0x1EB, cs_kick) and FENCE (waits for the SU and the atomic unit) — no change of this module.  Readings (no change of the RTL): DISPATCH does not invalidate a cache (ghci §7.3 says so only for DRAW), so a driver that rewrote the data sends INVALIDATE first; LOAD_PROGRAM's stage word is not looked at (the whole I$ is invalidated); the SU starts a compute warp at instruction 0 of CS_BASE (0x194), so CS_BASE is the address of the code (header word 5 applied; the header's entry point is the firmware's or driver's to add).

The waits for work upstream (the MSAA work, branch p2-p027): SET_REG into 0x050-0x08F waits for the VF, the SUs, the RX and the ROP (it waited for the RX and ROP, or the ROP alone, before), into the TU range also for the VF, into the program range (0x190-0x1AF, no wait before) for the VF, the SUs and the RX, into 0x1D0-0x1DF (ATTR_LIMIT) for the VF like ATTR_DST; LOAD_CONST's kick also for the VF and the RX; so a draw upstream keeps its state.  The waits moved to the child `atg_cp_seq_wait` (130 lines), which brings this module to 355 lines (under the limit).  Not checked here: whether the busy bits of the blocks leave a cycle without any of them set while work passes from one block to the next (the VF to a vertex warp, a vertex warp to the RX); a back-to-back test of the whole pipeline checks that.

2026-10-25 (CAPS[30]): µop 14 QUERY (payload 1: addr; needs the ROP, UNITS[4]): after the waits of RESULT (every block idle, f_busy 0) the counter is taken (a1 = occ_count[31:0], a2 = occ_count[39:32]) and the fence unit's RESULT request (f_op 1) writes it; flags[0] only clears, without waiting or writing; flags[1] clears with the request.  Ports occ_count and occ_clear (the badop TB case moved from op 14 to op 15).  `PASS atg_cp_seq.query`.
