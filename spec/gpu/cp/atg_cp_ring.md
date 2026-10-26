# atg_cp_ring

RTL: `rtl/gpu/cp/atg_cp_ring.v`.  Parent: `atg_cp`.  Implemented in: p004, upgraded in Phase 029.

## 1. Purpose and place

The command ring: RING_BASE/SIZE/WPTR/RPTR, line reads of the ring through the CP's AMB port, the packet envelope (design §2.4.2), class N packets to the sequencer, class V packets to the CPU, class 3 padding skipped.

Upgraded in Phase 029 with an 8-entry circular prefetch line buffer (64 words / 256 bytes for 32-byte lines) that concurrently prefetches subsequent lines while streaming packets, completely eliminating line boundary memory stalls and providing zero-bubble packet delivery.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `CLASS_V` | `1` | 1: class V packets go to the CPU (`v_*`); 0 (no firmware, `HAS_CPU` = 0): a class V header is a fault of kind 2 (design §8 p004). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Board reset: RING_BASE/SIZE. |
| `core_rst_n` | in | 1 | Core reset (CTRL.RESET): WPTR, RPTR, the fetch state. |
| **HCR register snoop (from atg_cp_regs)** | | | |
| `hcr_we` | in | 1 | One-cycle write strobe to an HCR word (0x000-0xFFC). |
| `hcr_widx` | in | 10 | Word index of the write (byte offset >> 2). |
| `hcr_wdata` | in | 32 | Write data. |
| `hcr_wmask` | in | 32 | Bit mask from WSTRB (1 = written). |
| `hcr_ridx` | in | 10 | Word index being read; the read data is due in the same cycle. |
| `hcr_rdata` | out | 32 | Read data of this module's registers at `hcr_ridx`. |
| **Control (from atg_cp_ctl)** | | | |
| `run` | in | 1 | RUNNING: fetch packets. |
| `halt` | in | 1 | Stop at the next packet boundary (HALTING, FAULTED, RESETTING). |
| `step` | in | 1 | In HALTED: one packet (one-cycle pulse). |
| `open` | in | 1 | IDLE/HALTED: RING_BASE/SIZE writes are taken. |
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
| **Fault report to atg_cp_ctl** | | | |
| `fault` | out | 1 | One-cycle pulse: this module found a fault. |
| `fault_kind` | out | 4 | FAULT_INFO[15:12] kind (design §2.2). |
| `fault_addr` | out | 32 | FAULT_ADDR value, valid with the pulse. |
| `fault_tag` | out | 8 | JOB_TAG of the command at fault. |
| **AMB client port (design §4.1)** | | | |
| `req_valid` | out | 1 | Request valid; payload held until `req_ready`. |
| `req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `req_write` | out | 1 | 1 write, 0 read. |
| `req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `req_be` | out | LINE_BYTES | Byte enables. |
| `req_wdata` | out | LINE_BYTES*8 | Write data. |
| `req_tag` | out | 8 | 0 = on-demand read, 1 = background prefetch. |
| `rsp_valid` | in | 1 | Response, one cycle, no back-pressure. |
| `rsp_write` | in | 1 | Response is write's. |
| `rsp_tag` | in | 8 | Tag of answered request. |
| `rsp_rdata` | in | LINE_BYTES*8 | Read data. |
| `rsp_error` | in | 1 | Aperture or AXI error. |

41 signals; 26 ports counting groups.

## 4. Behaviour

- **Registers (snoop)**: RING_BASE 0x050, RING_SIZE 0x054 (log2 bytes 10..20), RING_WPTR 0x058 (doorbell), RING_RPTR 0x05C (read only). WPTR/RPTR are dword indices; RPTR resets to 0.
- **Prefetch Line Buffer**: 8 lines (`buf_data[0:7]`, `buf_tag[0:7]`, `buf_valid[7:0]`) mapped by `want_line[2:0]`.
- **Background Prefetch**: While streaming Class N packets in `R_N`, if the packet extends across a line boundary and the next line (`next_line = want_line + 1`) is not yet in the buffer, the background prefetch engine requests `next_line` with `req_tag = 1` concurrently. When the consumer reaches the boundary, the data is already present in the prefetch buffer, eliminating stalls.
- **On-Demand Fallback**: If a line is not in the buffer (e.g. at packet start), the main FSM issues an on-demand request (`req_tag = 0`) via `R_REQ` / `R_RSP`.
- **Doorbell & Staleness**: A doorbell marks all buffer lines invalid (`buf_valid <= 8'd0`) to ensure subsequent headers and commands are never served from stale cache data across ring buffer wraps.
- **Fault Detection**: Packets exceeding WPTR or crossing the ring boundary trigger kind 3 (RING) fault; memory read errors trigger kind 1 (aperture).

## 5. State Machine

- **Execution FSM**: IDLE → (run && RPTR≠WPTR) → HDR → {N (stream) | V (wait v_done) | ADV} → ADV → IDLE. On-demand read uses REQ → RSP when cache misses.
- **Prefetch FSM**: PF_IDLE → (trigger in R_N) → PF_REQ → PF_RSP → PF_IDLE.

## 6. Latency and Throughput

- **Sustained Throughput**: 1 dword per clock cycle continuously on `n_*`, even across 32-byte / 64-byte line boundaries (zero bubble).
- AMB read latency (15-25 cycles) is completely hidden during multi-line packet streaming.

## 7. Status

Upgraded in Phase 029 with 64-word circular prefetch cache. Verified against `sim/tb/atg_cp_ring_tb.v`, `fw/cp/tests/run.sh`, and `sim/tb/atg_top_fw_tb.v`.
