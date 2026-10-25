# atg_cp

RTL: `rtl/gpu/cp/atg_cp.v`.  Parent: `atg_top` (instance `cp`).  A **wiring module** (README rule:
no logic of its own beyond a few `assign`s; exempt from the port and line limits).  Rewritten in
WS288 p004 from the CP v0 spec (p023 part 2).

## 1. Purpose and place

The command processor: the GHCI host control registers, the state register file, the command ring
with the class N sequencer, fences, interrupts, faults, the RESET order and the debug port.  Children
(spec/gpu/cp/): `atg_cp_regs` (register bus, identification, CAPS, EXTCAP, PERF; the HCR snoop bus and
the STATE alias), `atg_cp_state` (STATE[0..511], broadcast, replay), `atg_cp_ctl` (CTRL/STATUS, CP
states, KICK, quiesce, RESET order, watchdog, aperture, FAULT_*), `atg_cp_ring`, `atg_cp_seq`,
`atg_cp_fence`, `atg_cp_irq`, `atg_cp_dbg`, and `am_amb_mux` (ring, fence, dbg behind MC client 0).
The CPU (`atg_cpu`) is outside, in `atg_top`, connected through the `hcr_*`, `v_*`, `fw_*`,
`cpu_*` ports.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `ADDR_W` | 32 | GPU address width | 32 |
| `LINE_BYTES` | 32 | AMB line size | 32, 64 |
| `LINE_SHIFT` | 5 | log2(`LINE_BYTES`); also CAPS[23:20] | 5, 6 |
| `GCLK_HZ` | 100000000 | GCLK_HZ | the core clock |
| `VENDOR_ID` | 0x414D4154 ("AMAT") | VENDOR_ID | — |
| `DEVICE_ID` | 0x41544731 ("ATG1") | DEVICE_ID | — |
| `DEVICE_VERSION` | 0x00000003 (0.3) | DEVICE_VERSION (0.3: p004, CP with the ring) | — |
| `UNITS` | 8'h03 | Present blocks in STATUS busy-bit order (CP, BLT, VF, RX, ROP, TU, SU, SA); set by `atg_top` from its `HAS_*`/`NSU` | — |
| `HAS_CPU` | 0 | `atg_cpu` takes class V packets (else they fault, kind 2); CAPS[17], [18]; CPFW in the EXTCAP list | 0, 1 |
| `HAS_VSYNC` | 0 | A display's vsync reaches the CP: CAPS[10], WAIT_VSYNC | 0, 1 |
| `HAS_DISP` | 0 | A display controller's registers are in this window at +0x10000: CAPS[3] and the DISP capability (WS288 p012, KC705) | 0, 1 |
| `HAS_DBG` | 0 | A debug bridge outside the host bus (JTAG): the DBG capability | 0, 1 |
| `PACKED` | 0 | The SU has the packed arithmetic: CAPS[28] | 0, 1 |
| `SUBGROUP` | 0 | The SU has shfl/vote/ballot: CAPS[24] (`atg_top` passes NSU ≠ 0 && SU_SUBGROUP, WS288 p008) | 0, 1 |
| `MS4` | 0 | 4x multisampling in the blocks (`atg_top`'s `MS4`): CAPS[29] when the VF, RX, ROP, TU and an SU are present too | 0, 1 |

Derived: CAPS = {2'd0, MS4 && graphics && TU && SU (CAPS[29]), PACKED && SU, VF && RX && ROP (graphics, CAPS[27]), TU (CAPS[26]), 0, SUBGROUP && SU (CAPS[24]), LS, 0, HAS_CPU, HAS_CPU, 0, state version 1, 4x4 tiles 1, HAS_VSYNC, 0, TU (bilinear, WS288 p009),
SU ? 5 : 0, HAS_DISP, UNITS[6], UNITS[1], 1} (CP, BLT and MC alone: 0x00501803); CAPS2 = 1 (one ring) | (TU ? 4 : 0) << 24 (16 texture slots, WS288 p009); ISA_ID =
NATIVE_ISA_ID = "GSI1" with an SU, else 0; EXTCAP list: PERF (+ CPFW with the CPU, + DISP pointing at +0x10000 with HAS_DISP, + DBG with HAS_DBG); PERF0 = BLT busy,
PERF1 = memory busy (PERF_SRC 1, 8, 0xFF, 0xFF).

## 3. Ports

All in domain `clk`.  The CP v0 ports keep their meaning (see the children for the registers); new
or changed in p004:

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `reg_*` | in/out | — | Register bus from `am_axi_regs`; `reg_rdata` the cycle after `reg_rd` |
| `irq` | out | 1 | Level interrupt, registered: OR(IRQ_STATUS & IRQ_ENABLE) |
| `core_rst_n` | out | 1 | Core reset: low for one cycle in the RESET order (the blocks outside) |
| `mc_quiesce` | out | 1 | `atg_cp_ctl`'s quiesce, lifted while MC client 0 (this module) has a request valid |
| `mc_flush` | out | 1 | One-cycle pulse with the core reset |
| `aperture_base/limit` | out | 32 | From `atg_cp_ctl` |
| `mc_idle`, `mc_fault*` | in | — | From the MC; refusals of client 0 are reported by ring/fence/dbg themselves |
| `st_we/idx/wdata` | out | 1, 9, 32 | From `atg_cp_state`: every accepted write and the replay, one register stage later (p017: timing of a Zynq-7010 (XC7Z010) with the CPU; a kick follows its last STATE write by at least 2 cycles) |
| `blt_kick`, `draw_kick`, `cs_kick` | out | 1 | KICK (host, `atg_cp_ctl`) OR the sequencer's µop |
| `lc_kick`, `raw_kick`, `inv` | out | 1, 1, 4 | From the sequencer |
| `blt_busy`, `busy_ext[7:2]`, `blt_error*`, `x_fault*` | in | — | Busy levels and fault sources (STATUS, waits, FAULT_INFO) |
| `req_*`, `rsp_*` | — | AMB | MC client 0 through `am_amb_mux` (requester 0 ring, 1 fence, 2 dbg in tag bits [7:6]); **`rsp_tag` is new in p004** (the mux routes by it) |
| `hcr_*`, `x_rdata`, `v_*`, `fw_*`, `cpu_st_*`, `cp_fence_last`, `cp_fence_ev`, `cp_halt`, `cp_open`, `cpu_*` | — | — | To and from `atg_cpu` (spec/gpu/cp/atg_cpu.md).  p017: the watchdog counts while a class V packet is open (`v_valid`) and pauses while `cpu_stall` with no µop running |

## 4. Behaviour

- Register map, CP states, ring, fences, faults, RESET: docs/ghci.md §3-§10 and the children's specs.
- Resets: `rst_n` (board) for regs, ctl, state, the ring's BASE/SIZE, IRQ_ENABLE, the mux;
  `core_rst_n` (from ctl) for the ring's pointers, seq, fence, dbg, IRQ_STATUS and the blocks.
- The sequencer's `halt` is driven only in FAULTED and RESETTING (the ring stops at packet boundaries
  in HALTING/HALTED).
- STATUS[0] (CP busy) = ring busy, sequencer busy or a debug access; RESETTING sets it too.
- The STATE replay after the RESET pulse (bug 1 of p023): the blocks' copies of STATE match the
  STATE that survives RESET (design §2.6).
- The debug port answers in HALTED and FAULTED (bug 2 of p023) through the quiesce exception above.

## 5. State machine

None of its own (the CP states are in `atg_cp_ctl`).

## 6. Latency and throughput

As the children: register read 1 cycle; KICK → `blt_kick` in the cycle of `reg_wr`; a STATE write →
`st_we` one cycle later (p017); the ring one dword per cycle within a line plus one AMB round trip per
line; RESET: `mc_idle`, 1 pulse cycle, 513 replay cycles.

## 7. Corner cases and errors

- The quiesce exception relies on the MC's `HIGH_MASK` holding client 0 alone at the top (atg_mc.md).
- A fence or ring request already waiting for a grant when a block faults is granted (it was
  requested before the fault); the debug port's request waits behind it (priority ring, fence, dbg).

## 8. What the TB checks

No `atg_cp_tb.v` (a wiring module).  Through `sim/tb/atg_top_tb.v` (KC705 shape), besides
the CP v0 checks: CAPS[0], DEVICE_VERSION 0.3; a STATE write in FAULTED refused (read back with a full
mask); the debug port in FAULTED and HALTED; a FILL on the STATE kept over RESET (the replay); the
ring: SET_REG+BLIT FILL and FENCE with IRQ and RETIRE, padding and wrap, RESULT, DBG_MARK, WAIT_FENCE
released by a debug write, HALT with STEP one packet at a time, KICK (6) and STATE (7) in RUNNING,
class V without firmware (2, address, tag), fault → RESET → the ring from 0 again, a packet past WPTR
(3), a fence outside the aperture (1, client 0), the watchdog (4).  The Verilator harness: a ring FILL
and FENCE with its interrupt.  With `HAS_CPU` and the firmware (p017): `sim/tb/atg_top_fw_tb.v` (KC705
shape) checks CAPS[17]/[18], the EXTCAP list (PERF, CPFW → 0x120), CPFW start, a class V
GHCI_FRAME whose fill and copy give the same memory as the class N packet, its result records and
RESULT/RETIRE, a frame stopped by an unknown command, the watchdog on a class V packet nothing takes
→ RESET → the firmware restarts with `.data` restored, CPFW LOAD (a zero image faults at PC 0, then the
image runs).  The children's unit TBs: their specs §8.

## 9. References

design.md §1.3, §2.2-§2.7, §7.6, §8 (p004); docs/ghci.md; the children's specs; spec/common/am_amb_mux.md;
spec/gpu/mc/atg_mc.md (quiesce exception).

## 10. Status

WS288 p004 (P3): the inline CP v0 logic moved into the children; this module is wiring (369 lines).
Resolved p023 differences: 1 (BLT state after RESET: replay), 2 (debug port in HALTED/FAULTED),
5 (RING_EMPTY is WPTR = RPTR), 7 (ring, fence, watchdog, STEP, IRQ [8:7]; ISA_ID with an SU).
Remaining: 3 (HALTED does not wait for the blocks' work: they freeze, the p003 choice), 4 (RESET from
RUNNING skips HALTING), 6 (FAULT_INFO[23:16] of an MC refusal is the client number; the job tag of a
BLT error and of the watchdog is 0).

2026-10-25 (CAPS[30]): parameters HAS_FMT (default 0: the FMT capability, atg_cp_fmt, XCAP bit 9) and HAS_ETC (default 0: FMT reports the ETC2/EAC formats); ports occ_count (in, 40) and occ_clear (out) between atg_cp_seq's QUERY and atg_rop's occlusion counter (atg_top wires them).

RESIDENT_WARPS (parameter, default 0): the RESIDENT_WARPS register (0x04C), NSU x NWARPS from atg_top, passed to atg_cp_regs.

2026-10-25: parameters NREGS (default 0: RESIDENT_WARPS[23:16], SU_NREGS from atg_top) and LOCAL_BASE, LOCAL_BYTES, WINDOW_BYTES (default 0: the MEM capability, XCAP bit 7 when LOCAL_BYTES is not 0), passed to atg_cp_regs.
