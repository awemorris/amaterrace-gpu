# atg_cp

RTL: `rtl/gpu/cp/atg_cp.v`. Written from the RTL at amaterrace-gpu main a217bf8 (WS288 p023 part 2); the RTL is authoritative.

**Port list will grow:** in p023 part 1 (P1) `atg_cp` gets more ports (for the new blocks, with constant outputs) and instantiates its planned children (`atg_cp_regs`, `atg_cp_state`, `atg_cp_ring`, `atg_cp_seq`, `atg_cp_fence`, `atg_cp_ctl`, `atg_cp_irq`, `atg_cp_dbg`) as shadow instances; `spec/README.md` (P1) describes that. This spec describes the module as it is at a217bf8; Q1 reconciles the two on merge.

## 1. Purpose and place

The command processor, version 0 (WS288 p003): the host side of GHCI without the ring. It holds the GHCI host control registers (HCR) on the register bus of `am_axi_regs`, the state register file STATE[0..511], the controls of the other blocks (KICK, quiesce, RESET order, aperture), fault capture, interrupts, the PERF capability and the asynchronous debug port (its own AMB client 0). Parent: `atg_top` (instance `cp`). Children: none today (planned split above, design §7.6).

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `ADDR_W` | 32 | GPU address width | 32 |
| `LINE_BYTES` | 32 | AMB line size | 32, 64 |
| `LINE_SHIFT` | 5 | log2(`LINE_BYTES`); also CAPS[23:20] | 5, 6 |
| `GCLK_HZ` | 100000000 | Read back as GCLK_HZ | the core clock |
| `VENDOR_ID` | 0x414D4154 ("AMAT") | VENDOR_ID | — |
| `DEVICE_ID` | 0x41544731 ("ATG1") | DEVICE_ID | — |
| `DEVICE_VERSION` | 0x00000002 (0.2) | DEVICE_VERSION | — |

Register offsets and fields come from `include/ghci_regs.vh`.

## 3. Ports

All in domain `clk`. 39 ports.

| Name | Dir | Width | Meaning, handshake, timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Core clock (`gclk`) |
| `rst_n` | in | 1 | Board reset of the whole GPU, synchronous active low |
| `reg_wr`, `reg_waddr`, `reg_wdata`, `reg_wstrb` | in | 1, 17, 32, 4 | Register-bus write: one-cycle pulse per beat (from `am_axi_regs`) |
| `reg_rd`, `reg_raddr` | in | 1, 17 | Register-bus read pulse and byte offset |
| `reg_rdata` | out | 32 | Answer, valid in the cycle after `reg_rd` (registered; never waits) |
| `irq` | out | 1 | Level interrupt: OR(IRQ_STATUS & IRQ_ENABLE) |
| `mem_ready` | in | 1 | Level, STATUS[12] (ZYBO: 1; KC705: MIG calibration) |
| `core_rst_n` | out | 1 | Core reset (= `rst_n` and not the RESET pulse cycle). Resets the BLT and the CP's own core registers |
| `mc_quiesce` | out | 1 | Level: HALT, FAULTED or RESETTING |
| `mc_flush` | out | 1 | One-cycle pulse in the RESET pulse cycle |
| `aperture_base`, `aperture_limit` | out | 32 | APERTURE_BASE/LIMIT (line-aligned) |
| `mc_idle` | in | 1 | Level, the MC's `axi_idle` (STATUS.AXI_IDLE) |
| `mc_fault` | in | 1 | One-cycle pulse from the MC: an aperture refusal |
| `mc_fault_client`, `mc_fault_addr`, `mc_fault_write` | in | 8, 32, 1 | Its client, address, direction (valid with the pulse) |
| `st_we`, `st_idx`, `st_wdata` | out | 1, 9, 32 | One-cycle pulse per accepted STATE write: index and word, for the blocks' shadow copies |
| `blt_kick` | out | 1 | One-cycle pulse: start the BLT |
| `blt_busy` | in | 1 | Level, STATUS[1] |
| `blt_error`, `blt_error_kind` | in | 1, 4 | One-cycle pulse and FAULT_INFO kind from the BLT |
| `req_valid` / `req_ready` | out / in | 1 | AMB request handshake of client 0 (the debug port); valid held until ready |
| `req_write`, `req_line`, `req_be`, `req_wdata`, `req_tag` | out | 1, `ADDR_W-LINE_SHIFT`, `LINE_BYTES`, `LINE_BYTES*8`, 8 | The request: the word replicated over the line, the enables of the word; tag 0 |
| `rsp_valid` | in | 1 | One-cycle pulse, this client's response (no back-pressure) |
| `rsp_write`, `rsp_rdata`, `rsp_error` | in | 1, `LINE_BYTES*8`, 1 | Response fields |

## 4. Behaviour

Write decode: HCR at `reg_waddr[16:12]` = 0 (offsets 0x000–0xFFF, `wa = reg_waddr[11:0]`), STATE alias at 0x1000–0x17FF. Writes honour WSTRB (`merge`) except where noted. Reads: HCR from 0x000–0xFFF, STATE from 0x1000–0x17FF, 0 elsewhere (including 0x10000, DISP_KC705).

| Register | RTL behaviour |
| --- | --- |
| MAGIC, VERSION, VENDOR_ID, DEVICE_ID, DEVICE_VERSION, GCLK_HZ | Constants. ISA_ID = 0, CAPS2 = 0 |
| CAPS | `{8'd0, LINE_SHIFT[3:0], 4'd0, 4'd1 (state v1), 4'b1000 ([11] 4x4 tiles), 4'd0, 4'b0010 ([1] BLT)}`; CAPS[0] (ring) = 0. ZYBO 0x00501802 |
| EXTCAP | 0x100. List: 0x100 = `{0, next 0, ver 1, id PERF}`, 0x104 = 0x110; 0x110..0x11C PERF_SRC0..3 = 1 (BLT busy), 8 (memory), 0xFF, 0xFF |
| SCRATCH | RW, board reset only |
| COUNTER | Free-running cycle count, board reset only |
| CTRL | [0] RUN, [2] HALT written together (byte 0) in the core part; [1] RESET is W1S and starts the RESET order from any state; [4] WDT_EN stored only. Read: `{WDT_EN, 0, HALT, resetting, RUN}`. STEP does nothing |
| STATUS | [0] dbg busy or resetting, [1] BLT busy, [8] `mc_idle`, [9] faulted, [10] halted, [11] RING_WPTR == 0, [12] `mem_ready`, [13] AXI_STUCK, [14] quiesce, [19:16] CP state; others 0 |
| IRQ_STATUS | 7 bits, W1C (byte 0). Raised: [1] FAULT (first fault), [4] DBG_DONE (debug response), [5] SOFT (IRQ_SET[5]), [6] HALTED (rising edge of `halted`). [0] FENCE, [2], [3] never raised |
| IRQ_ENABLE | 7 bits, board reset only |
| WDT_CYCLES | RW, reset 0x10000000; used only for AXI_STUCK (4 × WDT_CYCLES) |
| RING_BASE (32-byte aligned), RING_SIZE (clamped 10..20, reset 12), APERTURE_BASE/LIMIT (line-aligned, reset 0) | Written only in IDLE/HALTED; otherwise ignored and a LOCKED fault (kind 7). Board reset only |
| RING_WPTR, FENCE_LAST | Plain RW, cleared by RESET (core part) |
| FAULT_ADDR / FAULT_INFO | First fault since reset (see below), cleared by RESET |
| PERF0 / PERF1 (0x80 / 0x84) | BLT busy cycles / cycles with `!mc_idle`; PERF_CTRL[0] write clears both; board reset only |
| DBG_ADDR / DBG_DATA / DBG_STATUS | Debug port, below |
| KICK (0xF00) | [0] BLIT: `blt_kick` if the state is IDLE or HALTED and the BLT is not busy, else KICK fault (kind 6). [1] DRAW or [2] DISPATCH: OPCODE fault (kind 2) |
| STATE[0..511] (0x1000 + 4i) | 512 × 32 BRAM. A write with all four strobes is taken in IDLE/HALTED unless the index is in the BLT range (< 0x20) while the BLT is busy; then it is written to the BRAM and pulsed on `st_we`. A full write when locked is ignored and a LOCKED fault; a partial-strobe write is ignored silently. Reads come from the BRAM. Kept over RESET |

CP state (`STATUS[19:16]`, derived each cycle, priority order): RESETTING if the RESET order runs; else FAULTED if faulted; else HALTED if HALT and `mc_idle`, HALTING if HALT; else RUNNING if RUN; else IDLE. "Open" states (KICK, STATE, locked registers allowed) are IDLE and HALTED.

Faults: the first of, in priority order in one cycle, (1) an MC refusal of a client other than 0 → FAULT_INFO `{0, block = client, kind 1, 0, write, client}`, FAULT_ADDR = the refused address; (2) `blt_error` → `{0, block 1, kind, 0, 0, client 1}`, FAULT_ADDR 0; (3) KICK fault → kind 6; (4) KICK of an absent unit → kind 2; (5) locked write → kind 7. It sets `faulted` (quiesce until RESET) and IRQ_STATUS.FAULT. Later faults are not recorded.

Debug port: a write to DBG_ADDR (when not busy) sets the word address (4-byte aligned) and starts a read; a write to DBG_DATA (when not busy) stores the value and starts a write of it with its byte strobes to DBG_ADDR. Both set busy and clear error; the request goes to the MC as client 0. The response clears busy, sets DBG_STATUS.error = `rsp_error` (aperture refusal or AXI error; never a device fault), and a read loads DBG_DATA with the addressed word. Writes while busy are ignored.

RESET order (design §1.3): quiesce (the MC stops granting), wait for `mc_idle`, one cycle with `core_rst_n` = 0 and `mc_flush` = 1, then IDLE. AXI_STUCK is set when quiesced for 4 × WDT_CYCLES without `mc_idle`, cleared by the reset pulse.

## 5. State machine

RESET sequencer `rs` (the only encoded FSM):

- `RS_NONE` →(CTRL write with [1] RESET)→ `RS_QUIESCE`
- `RS_QUIESCE` →(`mc_idle`)→ `RS_PULSE`
- `RS_PULSE` →(always; core reset and MC flush in this cycle)→ `RS_NONE`

The GHCI CP state is derived (§4), not a register. Its transitions as seen by the host: IDLE →(RUN = 1)→ RUNNING; IDLE/RUNNING →(HALT = 1)→ HALTING →(`mc_idle`)→ HALTED →(HALT = 0)→ RUNNING or IDLE; any →(fault)→ FAULTED; any →(RESET)→ RESETTING →(`mc_idle`, pulse)→ IDLE (RUN, HALT cleared). Other per-feature state: debug port idle →(DBG write)→ busy →(response)→ idle; `faulted` flag; `halted_q` for the HALTED edge.

## 6. Latency and throughput

- Register read: answer in the cycle after `reg_rd` (HCR mux or BRAM).
- KICK → `blt_kick` in the same cycle as `reg_wr`.
- STATE write → `st_we` in the same cycle.
- Debug access: request valid from the cycle after the write; done with the response (some tens of cycles on the ZYBO).
- RESET: 2 cycles after `mc_idle`.
- Fault → `faulted`/IRQ the next cycle; `irq` follows IRQ_STATUS combinationally.

## 7. Corner cases and errors

- KICK with both BLIT and DRAW set: the BLT may start and an OPCODE fault is recorded.
- KICK while the BLT is busy (even in IDLE) is a KICK fault (kind 6), and a full STATE write to the BLT range while busy is a LOCKED fault.
- In HALTED the MC is quiesced, so a KICK.BLIT is accepted but the blit makes no memory access until HALT is released, and **a debug access in HALTED or FAULTED waits until HALT is released or RESET** (see §10).
- HALT during a blit: HALTED comes when the MC is idle, with the BLT still busy and frozen; it resumes on HALT = 0 (the TB checks the result).
- A locked write during RESETTING may record a fault that the reset pulse then clears.
- If AXI never goes idle, RESET never completes; AXI_STUCK tells the driver.
- Faults of client 0 (debug) are not device faults.

## 8. What the TB checks

No `sim/tb/atg_cp_tb.v`. Checked through `sim/tb/atg_top_tb.v` (`PASS atg_top`, ZYBO and KC705 shapes) and the Verilator harness (`PASS verilator`): identification, CAPS, DEVICE_VERSION, EXTCAP list and PERF_SRC, 0 at unmapped offsets (0x120, 0xF04, 0x10000); SCRATCH with byte strobes; STATUS at reset; STATE alias write/read and a partial-strobe write ignored; aperture alignment; DBG read, write, read-back, DBG_DONE IRQ, an outside address → DBG_STATUS.error and no FAULT; PERF0/1 count and PERF_CTRL clears; HALT in the middle of a COPY → HALTED with BLT busy → resume, same result; aperture fault → FAULTED, QUIESCED, FAULT_INFO (kind 1, client 1, write), FAULT_ADDR, IRQ and the line, a STATE write while FAULTED (made, but its read-back is compared with mask 0, so not actually checked), RESET → IDLE, FAULT_INFO and IRQ_STATUS 0, aperture kept, the next FILL works; OPCODE faults (pixel size 2, tile blend, KICK.DRAW); HALT/HALTED IRQ, IRQ_SET soft IRQ and W1C. On the ZYBO (p003) `plan/tools/zybo/ghci-blt-board.py` (zedBSD) checks the same paths through `fpgareg`. Not checked: RUNNING-state locked writes and KICK fault kind 6, AXI_STUCK, RING_SIZE clamping, KICK with several bits, a debug access while HALTED, the STATE contents seen by the BLT after RESET.

## 9. References

- design.md §1.3 (RESET order, quiesce), §2.2 (HCR), §2.3 (STATE), §2.5 (faults), §2.6 (CP states), §7.6 (planned split).
- `docs/ghci.md` §2 (HCR), §3 (EXTCAP), §4 (CP states), §7 (faults, reset), §8 (STATE), §11 (debug port and KICK), Appendix (implementation status).
- Related specs: `spec/common/am_axi_regs.md`, `spec/gpu/blt/atg_blt.md`, `spec/gpu/mc/atg_mc.md`, `spec/gpu/top/atg_top.md`; the planned `spec/gpu/cp/atg_cp_*.md` (P1).

## 10. Status

Implemented (p002 70aaff5, p003 a2af156; unchanged at a217bf8). Measured on the ZYBO (p003): 610 LUT, 531 FF, 0.5 BRAM (the STATE BRAM18).

**U38: 481 lines > 400**, 39 ports (at the limit), one encoded FSM (RESET) but several independent state holders (CP state, debug port, faults, IRQ). Not refactored here. Proposed split (matches design §7.6): `atg_cp_regs` (write decode, plain registers, read mux with EXTCAP/PERF; about 180 lines), `atg_cp_state` (BRAM, alias, lock test, `st_*`; about 50), `atg_cp_ctl` (RUN/HALT, derived CP state, RESET sequencer, AXI_STUCK, fault capture and FAULT_ADDR/INFO; about 130), `atg_cp_irq` (IRQ_STATUS/ENABLE/SET, raise and W1C; about 40), `atg_cp_dbg` (debug port and its AMB request; about 70), and `atg_cp` as wiring. With the ring and fence (p004) the CP needs an internal arbiter for its single MC client (debug, ring fetch, fence writes) or more MC clients.

Differences between the RTL and design.md / docs/ghci.md (to fix in an implementation Phase, not here):

1. **BLT parameters after RESET**: ghci.md §4 and design §2.6 say STATE survives RESET. The BRAM does, but the BLT's shadow copy (fed by `st_we`) is reset by `core_rst_n`, so after RESET the BLT runs with zero parameters until the host rewrites them, while the STATE alias still reads the old values. The TB rewrites every field before each blit, so it does not see this.
2. **Debug port in HALTED/FAULTED**: ghci.md §4 lets HALTED take the debug port like IDLE; in the RTL `mc_quiesce` holds the debug request until HALT = 0 or RESET.
3. HALTED does not wait for the BLT to finish (design §2.6: HALTING waits for the current command including the blocks' work); the RTL halts at memory idle and freezes the blit. This was the p003 choice and the TB checks it.
4. RESET from RUNNING goes straight to RESETTING (design §2.6: through HALTING); the quiesce is the same.
5. RING_EMPTY is `RING_WPTR == 0` (no RPTR yet).
6. FAULT_INFO[23:16] for an aperture fault is the client number, not the block number of ghci.md §2 (equal for the BLT, client 1 = block 1). FAULT_INFO[31:24] (job tag) is always 0. A memory error from the BLT reports no address and no direction.
7. No watchdog (WDT_EN is stored), no ring, no STEP, no fence; IRQ bits [8:7] (RESULT, RETIRE, design v3) are absent; ISA_ID is 0.

**WS288 p023 (P1) additions to the RTL**: (a) new ports for the blocks of design §7.6 —
`draw_kick`, `cs_kick`, `lc_kick`, `raw_kick`, `inv[3:0]`, `busy_ext[7:0]`, `vsync`,
`x_fault[1:0]`/`x_fault_kind`/`x_fault_addr`/`x_fault_tag` (fault sources 4 = SUs, 7 = other
blocks), the HCR snoop bus `hcr_*` and `x_rdata` (atg_cpu's CPFW registers), the class V packet
`v_*`, the firmware µop stream `fw_*`, `cpu_st_ridx/cpu_st_rdata`, `cp_fence_last`,
`cp_fence_ev`, `cp_halt`, `cp_open`, `cpu_fault`, `cpu_fault_addr`, `cpu_stall`, `cpu_result`
(see spec/gpu/cp/atg_cpu.md and the children's specs); (b) a scaffold at the end of the file
that instantiates the proposed children (`atg_cp_regs`, `atg_cp_state`, `atg_cp_ring`,
`atg_cp_seq`, `atg_cp_fence`, `atg_cp_ctl`, `atg_cp_irq`, `atg_cp_dbg`, `am_amb_mux` for
ring/fence/dbg) wired to the real inputs; they are stubs, their outputs drive only the new
ports, and the inline logic still does all the work.  p004 moves the inline logic into the
children, connects `am_amb_mux` to MC client 0 and removes the inline code.
