# atg_cp_ring

RTL: `rtl/gpu/cp/atg_cp_ring.v`.  Parent: atg_cp.  Implemented in: p004.

## 1. Purpose and place

The command ring: RING_BASE/SIZE/WPTR/RPTR, line reads of the ring through the CP's AMB port, the packet envelope (design §2.4.2), class N packets to the sequencer, class V packets to the CPU, class 3 padding skipped.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 (ZYBO) or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |

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
| **Control (from atg_cp_ctl)** | | | |
| `run` | in | 1 | RUNNING: fetch packets. |
| `halt` | in | 1 | Stop at the next packet boundary (HALTING, FAULTED, RESETTING). |
| `step` | in | 1 | In HALTED: one packet (one-cycle pulse). |
| `open` | in | 1 | IDLE/HALTED: RING_BASE/SIZE writes are taken (else ignored; ctl reports the fault). |
| **Class N packets (to atg_cp_seq)** | | | |
| `n_valid` | out | 1 | A dword of a class N packet. |
| `n_ready` | in | 1 | Taken. |
| `n_data` | out | 32 | Header first (dword0 as in the ring), then the payload. |
| `n_last` | out | 1 | Last dword of the packet. |
| **Class V packets (to atg_cpu)** | | | |
| `v_valid` | out | 1 | A class V packet is waiting (level until v_done). |
| `v_addr` | out | 32 | GPU address of its dword1. |
| `v_dwords` | out | 16 | n from the header (dwords after the header). |
| `v_tag` | out | 8 | JOB_TAG. |
| `v_done` | in | 1 | One-cycle pulse: the firmware finished the packet (DONE). |
| **Status** | | | |
| `empty` | out | 1 | WPTR == RPTR (RING_EMPTY). |
| `retire` | out | 1 | One-cycle pulse when RPTR passes a packet (IRQ RETIRE). |
| `busy` | out | 1 | A packet is being fetched or handed over. |
| **Fault report to atg_cp_ctl (one source of its `src_*` vectors)** | | | |
| `fault` | out | 1 | One-cycle pulse: this module found a fault. |
| `fault_kind` | out | 4 | FAULT_INFO[15:12] kind (design §2.2), valid with the pulse. |
| `fault_addr` | out | 32 | FAULT_ADDR value (address or PC), valid with the pulse. |
| `fault_tag` | out | 8 | JOB_TAG of the command at fault, valid with the pulse. |
| **AMB client port (design §4.1)** | | | |
| `req_valid` | out | 1 | Request valid; payload held until `req_ready`. |
| `req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `req_write` | out | 1 | 1 write, 0 read. |
| `req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `req_tag` | out | 8 | The client's tag, returned with the response. |
| `rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `rsp_tag` | in | 8 | Tag of the request answered. |
| `rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |

40 ports.

## 4. Behaviour

- Registers (snoop): RING_BASE 0x050, RING_SIZE 0x054 (log2 bytes 10..20), RING_WPTR 0x058 (a write
  is the doorbell), RING_RPTR 0x05C (read only).  WPTR/RPTR are dword indices; RPTR resets to 0.
- Fetch: while `run && !halt` (or once per `step`) and RPTR != WPTR, read the line holding RPTR
  (re-read on every doorbell: design §2.7, no stale prefetch), take dword0, decode the class:
  class 0/1 (N): stream header + n payload dwords on `n_*`; class 2 (V): raise `v_*` and wait for
  `v_done`; class 3: skip n dwords.  RPTR advances past the packet when it has been handed over
  (N: last dword taken; V: v_done) and `retire` pulses.
- A packet whose end passes WPTR, or which crosses the ring end, is fault kind 3 (RING) with
  `fault_addr` = the packet's address; nothing of it is handed over.
- AMB tags: one read outstanding at a time is enough for v1 (tag 0); prefetching the next line up to
  WPTR is an optimisation the implementation may add.

## 5. State machine

IDLE →(run, RPTR≠WPTR)→ READ (request the line) →(rsp)→ HEADER → {N_PAYLOAD (stream; next line
when needed) | V_WAIT (until v_done) | SKIP} → ADVANCE (RPTR, retire) → IDLE.  halt is looked at
only in IDLE; fault → FAULTED (stay until core reset).

## 6. Latency and throughput

One dword per cycle on n_* within a line, plus one AMB round trip per line (about 20-40 cycles on the ZYBO).

## 7. Corner cases and errors

- RING_SIZE out of 10..20 is clamped by the driver contract; the module treats other values as 10.
- AMB error on a ring read: fault kind 5 (AXI) or 1 (aperture, the MC already raised it) — report
  kind 3 only for envelope errors; for rsp_error report kind 1 with the ring address.
- Core reset clears RPTR and WPTR (design §2.6) but not BASE/SIZE.

## 8. What the TB checks

`sim/tb/atg_cp_ring_tb.v` prints, in this order:

- `PASS atg_cp_ring.classn` — a ring with SET_REG/BLIT packets streams them with n_last at the right dword
- `PASS atg_cp_ring.classv` — a class V packet raises v_* with address/length/tag and waits for v_done
- `PASS atg_cp_ring.pad` — class 3 padding at the ring end, then a packet at index 0
- `PASS atg_cp_ring.wrap` — WPTR wraps; RPTR follows; empty and retire pulse correctly
- `PASS atg_cp_ring.fault` — a header whose n passes WPTR: fault kind 3, nothing handed over
- `PASS atg_cp_ring.halt` — halt stops between packets; step fetches one
- `PASS atg_cp_ring` at the end.

## 9. References

design §2.4.2 (envelope), §2.7 (ring rules), §2.2 (registers), include/ghci_packets.h.

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
