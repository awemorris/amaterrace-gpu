# atg_cp_disp

RTL: `rtl/gpu/cp/atg_cp_disp.v`.  Parent: atg_cp.  Implemented in: (empty).

## 1. Purpose and place

The command processor's side of a DISP2 display controller (docs/ghci.md §13.2): the micro-ops
DISP_SET and FLIP that `atg_cp_seq` executes, the host's gate to the controller's registers, the
plane slots and the flip records.  Parent: `atg_cp`.  The controller itself (`atg_dc`) is a child of
`atg_top`; this module reaches its registers through the DC's internal register bus (`d_*`) and its
flips through `flip_*`/`taken`.  It is in the board reset's domain (CTRL.RESET does not reset it).
No children but the record writer's request logic (one AMB leaf of the CP's `am_amb_mux`).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `NPLANES` | `1` | 1, or 2 with the cursor plane (DC_CAPS[8]). |
| `LOCAL_BASE` | `0` | Local memory (the MEM capability): a FLIP's base must be in [LOCAL_BASE, LOCAL_BASE + LOCAL_BYTES). |
| `LOCAL_BYTES` | `0` | 0: no local memory, no such check. |
| `BASE_IDX` | `10'h080` | HCR word index of the DISP2 window (byte 0x200; 64 words). |

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | gclk. |
| `rst_n` | in | 1 | Board reset (not the CP's core reset). |
| `hcr_*` | — | — | HCR snoop port (one group): the host's writes of the window (gated, §4) and reads (`hcr_rdata`: the DC's word at `hcr_ridx` OR this module's, 0 outside the window). |
| `cp_state` | in | 4 | STATUS[19:16] of `atg_cp_ctl`. |
| `uop_we` | in | 1 | `atg_cp_seq`'s payload write, routed here when `uop_idx[9:8]` = 3. |
| `uop_idx` | in | 10 | 0x3C0 + offset/4: a DISP_SET register write; 0x3B8-0x3BB: FLIP's plane, base, record, value. |
| `uop_wdata` | in | 32 | The value. |
| `kick_flip` | in | 1 | One-cycle pulse: `atg_cp_seq` executes the staged FLIP (its waits are done). |
| `kick_idle` | in | 1 | One-cycle pulse: DISP_SET with flags[0] executes (the wait follows). |
| `seq_tag` | in | 8 | The job tag of `atg_cp_seq`'s current µop (for the fault). |
| `disp_wait` | out | 1 | Level to `atg_cp_seq`'s busy bit 8 (only while active): the staged FLIP's plane is not free, a DISP_SET wait has not seen the DC idle, or a host write waits in the buffer. |
| `aperture_base`, `aperture_limit` | in | `ADDR_W` | APERTURE_BASE/LIMIT. |
| `fault` | out | 1 | One-cycle pulse: a bad FLIP (kind 3). |
| `fault_kind` | out | 4 | 3. |
| `fault_addr` | out | 32 | The bad plane, base or record. |
| `fault_tag` | out | 8 | `seq_tag` at the kick. |
| `d_we` | out | 1 | DC register bus: write strobe (one cycle). |
| `d_idx` | out | 6 | Word index in the window. |
| `d_wdata` | out | 32 | Data. |
| `d_wmask` | out | 32 | Bit mask (DISP_SET: all ones). |
| `d_ridx` | out | 6 | Read index (`hcr_ridx` − `BASE_IDX`). |
| `d_rdata` | in | 32 | The DC's word at `d_ridx`, combinational. |
| `flip_valid` | out | 1 | One-cycle pulse: the plane gets a pending image. |
| `flip_plane` | out | 1 | The plane. |
| `flip_base` | out | 32 | The image's GPU address. |
| `taken` | in | 2 | Per plane, a one-cycle pulse: the DC took a pending flip this module placed. |
| `taken_cancel` | in | 2 | With `taken`: as cancelled. |
| `dc_pending` | in | 2 | Per plane: the DC has a pending flip (the host's or this module's). |
| `dc_idle` | in | 1 | The DC's STATUS.idle. |
| `frame_count` | in | 32 | FRAME_COUNT, for the record. |
| `dc_err` | out | 2 | One-cycle pulses to the DC's STATUS: [0] record error, [1] BAD_WRITE. |
| AMB client port | — | — | The record writer (one group), a leaf of the CP's `am_amb_mux`. |
| `ev_flip` | out | 1 | One-cycle pulse: IRQ_STATUS.FLIP. |

34 ports (the HCR and AMB groups counted once each).

## 4. Behaviour

- **Active**: DISP µops take effect only while `cp_state` is RUNNING or HALTING.  Outside, payload
  writes, `kick_flip` and `kick_idle` are ignored and `disp_wait` is 0 (so a STEP of a DISP µop
  ends at once).
- **DISP_SET**: a payload write 0x3C0 + k (k < 64) goes to the DC's register bus as a whole-word
  write of word k, in the same cycle (it has priority over the host's buffer).  `atg_cp_seq` has
  checked the offset.  `kick_idle` sets `idle_req`; it falls in the first cycle with `dc_idle`;
  `disp_wait` covers `idle_req && !dc_idle`.
- **FLIP**: 0x3B8-0x3BB stage plane, base, record and value; a write of 0x3B8 marks a FLIP staged.
  While staged, `disp_wait` = the plane (if it exists) has `dc_pending`, a slot, or a record still
  to write.  At `kick_flip`: plane ≥ `NPLANES`, base outside [aperture_base, aperture_limit) or
  outside local memory or not aligned (plane 0: `LINE_BYTES`, plane 1: 64), or record ≠ 0 not
  8-byte aligned or outside the aperture → fault 3 (`fault_addr` the bad word); else the plane's
  slot = {record, value}, `flip_valid` with the base, and the staging is cleared.
- **Take**: `taken[p]` with a slot: TAKENp = value with bit 31 = `taken_cancel[p]`; the slot falls;
  with record ≠ 0 the record {TAKENp's value, `frame_count`} is due; with record 0 `ev_flip` pulses.
  `taken` without a slot is ignored.
- **Record writer** (one FSM, IDLE → REQ → RSP → IDLE): a due record (plane 0 first) is requested
  only while `cp_state` is IDLE, RUNNING or HALTING: one write of 8 bytes (byte enables of the
  word pair at record[LINE_SHIFT−1:3]).  At the response `ev_flip` pulses; an error response
  pulses `dc_err[0]` (not retried).  A request offered stays until ready (the CP's MC client is
  not held by a quiesce).
- **Host gate**: a host write inside the window (`hcr_widx` − `BASE_IDX` < 64) by the offset's
  kind (docs/ghci.md §13.2): S (CTRL, FB_NEXT, FB_STRIDE, FB_SIZE, 0x30-0x50, PCLK_SEL) passes only
  in IDLE, HALTED and FAULTED, else it is dropped and `dc_err[1]` pulses; C (0xA4, 0xA8), L
  (0x60, 0x64, 0x6C), I (0x80) and W (STATUS) always pass; others (R) are dropped.  A passed write
  goes to the DC bus in its cycle, or, when the sequencer or the buffer has the bus in that cycle,
  into a one-entry buffer that goes out in the next cycle; while the buffer is full `disp_wait` is 1,
  so the sequencer's next DISP_SET write waits for it (the host may write in every cycle).
- **Reads**: `d_ridx` = `hcr_ridx` − `BASE_IDX`; inside the window `hcr_rdata` = `d_rdata`, with
  STATUS[31] (a record due or being written) and TAKEN0/TAKEN1 from this module.

## 5. State machine

The record writer: IDLE →(record due and the state lets it)→ REQ →(req_ready)→ RSP →(rsp_valid)→
IDLE.  The slots, staging, `idle_req` and the host buffer are flags.

## 6. Latency and throughput

A DISP_SET write reaches the DC in the cycle of the payload dword.  A FLIP is placed in the cycle
of `kick_flip`.  A record: request one cycle after the take, `ev_flip` the cycle after its
response.

## 7. Corner cases and errors

- A host write and a sequencer write in the same cycle: the host's waits in the buffer, and the
  sequencer's next write waits for the buffer (busy bit 8).
- HALT while a FLIP waits for its slot: the record of the plane's earlier flip may be written in
  HALTING, so the wait ends.
- CTRL.RESET of the GPU: the slots and due records survive; the records are written once the CP is
  IDLE.
- The DC's own reset takes the pending flips as cancelled (`taken_cancel`).

## 8. What the TB checks

`sim/tb/atg_cp_disp_tb.v` (design §18.12): `set`, `flip`, `take`, `excl`, `order`, `taken`,
`cancel`, `gate`, `reset`, `err`, then `PASS atg_cp_disp`.  The FIFO's fault 2 is `atg_cp_seq`'s
(`atg_cp_seq_tb`).  Mutations: `MUT_DISP_NOEXCL`, `MUT_DISP_NOGATE`, `MUT_DISP_EARLYIRQ`,
`MUT_DISP_HALTSEND`, `MUT_DISP_NOTAKE`.  As implemented (D4): the groups are `set`, `flip`, `take`,
`taken` (TAKEN0/1, STATUS[31], cancelled flips; the host's FB_NEXT cancel is the DC's and is
checked by `atg_dc_regs_tb`), `excl`, `gate`, `reset`, `err`; `order` (COMPLETE) is
`atg_cp_seq_tb.disp`'s.  Each mutation fails the TB.

## 9. References

docs/ghci.md §7.3 (DISP_SET, FLIP), §13.2; design §18.4.

## 10. Status

Implemented (WS288 p035 D4, 2026-10-25, P3): about 350 lines, 34 ports as above; one FSM (the
record writer); no arithmetic (the checks are comparisons, the byte enables a decoder).  The fault
is combinational in the kick's cycle so that `atg_cp_ctl` is FAULTED before the sequencer's next
header.  A record is requested only in IDLE, RUNNING or HALTING; one already offered stays until
ready (RS_WAIT waits for `mc_idle`, which counts the CP's client).  In `atg_cp` it is the fourth
requester of the `am_amb_mux` (`req_chk` 0).
