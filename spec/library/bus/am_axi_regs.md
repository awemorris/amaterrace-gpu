# am_axi_regs

RTL: `rtl/library/bus/am_axi_regs.v`. Written from the RTL at amaterrace-gpu main a217bf8 (WS288 p023 part 2); the RTL is authoritative.

## 1. Purpose and place

An AXI slave (AXI3 or AXI4, 32-bit data) that turns host accesses into a simple register bus. Parent: `atg_top` (instance `regs`, between the host port `s_*` and `atg_cp`). Later also the DC-only bitstream and the KC705 PCIe/JTAG paths. Children: none.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `ADDR_BITS` | 17 | Address bits decoded; `reg_waddr`/`reg_raddr` are the low `ADDR_BITS` bits of AxADDR | `atg_top` uses 17 (128 KiB decode, design §2.2) |
| `ID_W` | 12 | AXI ID width | 12 for the Zynq GP0 (AXI3), 4 for the KC705 lint shape |
| `LEN_W` | 4 | ARLEN width | 4 (AXI3), 8 (AXI4) |

## 3. Ports

AXI slave (`s_*`, domain `clk`; AXI valid/ready rules):

| Name | Dir | Width | Meaning, handshake, timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | Clock; synchronous active-low reset (also forces `s_awready`, `s_arready` to 0) |
| `s_awaddr` | in | `ADDR_BITS` | Write address; kept for the whole burst |
| `s_awid` | in | `ID_W` | Echoed on `s_bid` |
| `s_awvalid` / `s_awready` | in / out | 1 | `s_awready = rst_n && !aw_full && !b_valid`: one write burst at a time, a new AW only after the previous B was taken |
| `s_wdata`, `s_wstrb` | in | 32, 4 | Beat data and byte strobes, passed to `reg_wdata`/`reg_wstrb` combinationally |
| `s_wlast` | in | 1 | Ends the burst (an AXI4-Lite master ties it to 1). AWLEN is not looked at |
| `s_wvalid` / `s_wready` | in / out | 1 | `s_wready = aw_full`: W is taken only after its AW (a master that sends W first waits; allowed by AXI) |
| `s_bid`, `s_bresp` | out | `ID_W`, 2 | The burst's ID; always OKAY (00) |
| `s_bvalid` / `s_bready` | out / in | 1 | One B per burst, the cycle after the beat with `s_wlast` |
| `s_araddr`, `s_arid` | in | `ADDR_BITS`, `ID_W` | Read address and ID |
| `s_arlen` | in | `LEN_W` | Beats − 1 (an AXI4-Lite master ties it to 0). ARSIZE/ARBURST are not ports |
| `s_arvalid` / `s_arready` | in / out | 1 | `s_arready` only in the read FSM's `R_IDLE` |
| `s_rdata`, `s_rid`, `s_rresp`, `s_rlast` | out | 32, `ID_W`, 2, 1 | Beat; RRESP always OKAY; RLAST on the last beat |
| `s_rvalid` / `s_rready` | out / in | 1 | Beat handshake; data held until taken |

Register bus (domain `clk`; the target is the CP):

| Name | Dir | Width | Meaning, timing |
| --- | --- | --- | --- |
| `reg_wr` | out | 1 | One-cycle pulse per written beat (= the W handshake) |
| `reg_waddr` | out | `ADDR_BITS` | Byte offset of the write (the burst's AWADDR, the same for every beat) |
| `reg_wdata`, `reg_wstrb` | out | 32, 4 | The beat |
| `reg_rd` | out | 1 | One-cycle pulse per read beat |
| `reg_raddr` | out | `ADDR_BITS` | Byte offset of the read (`s_araddr` in the AR cycle, then the held address) |
| `reg_rdata` | in | 32 | The target's answer, **sampled in the cycle after `reg_rd`** (the target registers it and never waits) |

## 4. Behaviour

- Write: AW is latched (`aw_full`), then each W beat makes one `reg_wr` with the latched address; the `s_wlast` beat clears `aw_full` and raises `s_bvalid`.
- Read: the AR handshake makes `reg_rd` with `s_araddr`; the next cycle (`R_FETCH`) takes `reg_rdata` into `r_data`; `R_VALID` shows it. For a burst, every following beat repeats `reg_rd` on the same (first) address, so a burst read returns the same register several times.
- Every access is answered OKAY, including unmapped offsets (the target returns 0 for those, design §2.2).
- One write and one read can be in progress at the same time (the two channels are independent).

## 5. State machine

Read channel (`r_state`):

- `R_IDLE` →(AR handshake: `reg_rd`, latch address, ID, `r_left = s_arlen`)→ `R_FETCH`
- `R_FETCH` →(always: `r_data <= reg_rdata`)→ `R_VALID`
- `R_VALID` →(`s_rready` and `r_left` = 0)→ `R_IDLE`; →(`s_rready` and `r_left` ≠ 0: `reg_rd` again, `r_left - 1`)→ `R_FETCH`

Write channel: a flag `aw_full` (address held) and `b_valid` (response owed), not a separate FSM: idle →(AW)→ address held →(W with WLAST)→ B owed →(B handshake)→ idle.

## 6. Latency and throughput

- Read: `s_rvalid` 2 cycles after the AR handshake; next AR accepted the cycle after the last R handshake: at least 3 cycles per single read; a burst beat every 2 cycles.
- Write: AW cycle, W accepted from the next cycle (`reg_wr` in that cycle), B the cycle after: at least 3 cycles per single write, plus the B handshake before the next AW.
- No back-pressure on the register bus; the target must answer every `reg_rd` in exactly one cycle.

## 7. Corner cases and errors

- Burst writes: every beat writes the first address (the last beat's data wins for a plain register). Burst reads repeat the read (registers must have no read side effects; the CP's have none).
- AxSIZE, AxBURST, AWLEN, AxLOCK/CACHE/PROT and AXI3 WID are ignored.
- Addresses above `ADDR_BITS` are cut off by the parent (`atg_top` takes the low 17 bits).
- No SLVERR/DECERR is ever returned.
- Reset during a transfer drops it (AXI protocol violation toward the host); `rst_n` is the board reset only.

## 8. What the TB checks

`sim/tb/am_axi_regs_tb.v` → `PASS am_axi_regs`: AXI3 shape (ID 12, LEN 4) in front of 16 test registers at 0x10000 + 4n. Single writes with byte strobes and read back; the write offset is the low 17 bits of AWADDR; a 4-beat burst read of one register (each beat that register, RLAST on beat 4, no RVALID after); a 2-beat burst write (both beats to the first register, the second wins, exactly one BRESP); random host-side ready delays (`+seed`, p002 also `SEED=42`). Also used by every `atg_top_tb`/Verilator access. Not checked: AXI4 8-bit ARLEN, W before AW from the master, reset in the middle of a transfer.

## 9. References

- design.md §2.2 (the 128 KiB decode, 0 for unmapped offsets), §7.1, §7.3.
- `docs/ghci.md` §2 (conventions: 32-bit accesses), `docs/style.md`.
- Related specs: `spec/gpu/cp/atg_cp.md` (the register-bus target), `spec/gpu/top/atg_top.md`.

## 10. Status

Implemented (70aaff5, p002; unchanged at a217bf8). 173 lines, 33 ports, one state machine (read), one clock: within U38. No difference between RTL and this spec. Measured on a Zynq-7010 (XC7Z010) (p003, Vivado 2026.1): 289 LUT, 111 FF.
