# atg_cpu_win

RTL: `rtl/gpu/cp/atg_cpu_win.v`.  Parent: atg_cpu.  Implemented in: p017.

## 1. Purpose and place

The CPU's data-bus decoder and control window: routes loads/stores to DMEM or to the window registers (class V packet, UOP_FIFO, STATE read, FENCE_LAST, cycle counter, RESULT, interrupt), and the sub-bus to atg_cpu_dma and atg_cpu_fw.

Address map of the core (byte addresses):

| Range | What |
| --- | --- |
| 0x0000_0000-0x0000_FFFF | IMEM (fetch only; IMEM_WORDS words) |
| 0x0001_0000-0x0001_FFFF | DMEM (load/store; DMEM_WORDS words: .data, .rodata, .bss, stack) |
| 0xF000_0000-0xF000_00FF | control window (atg_cpu_win; word index = sub-bus index) |

Control window (word index, R/W):

| Index | Name | Owner | Meaning |
| --- | --- | --- | --- |
| 0x00 | PKT_ADDR | win | R: GPU address of the class V packet's dword1 |
| 0x01 | PKT_DWORDS | win | R: its n |
| 0x02 | PKT_INFO | win | R: [7:0] JOB_TAG, [31] a packet is waiting (v_valid, 0 from DONE until v_valid falls); a read with [31] = 1 takes the packet (IRQ[0] clears) |
| 0x03 | DONE | win | W: any value: the packet is finished (v_done, RPTR moves) |
| 0x04 | UOP | win | W: one µop dword to the sequencer (stalls while the FIFO is full) |
| 0x05 | UOP_LAST | win | W: the last dword of a µop packet |
| 0x06 | UOP_FREE | win | R: free FIFO entries |
| 0x07 | STATE_IDX | win | W: STATE index to read |
| 0x08 | STATE_DATA | win | R: STATE[STATE_IDX] (one wait cycle) |
| 0x09 | FENCE_LAST | win | R |
| 0x0A | CYCLE | win | R: cycle counter (mcycle) |
| 0x0B | RESULT | win | W: raise IRQ_STATUS.RESULT |
| 0x0C | IRQ | win | R: [0] packet, [1] fence, [2] halt request; W: 1s clear [1] |
| 0x0D | IRQ_EN | win | RW: [2:0] enables of the IRQ causes (reset 0); irq = \|(IRQ & IRQ_EN) (p017) |
| 0x10 | DMA_AMB | dma | RW: GPU address (line aligned) |
| 0x11 | DMA_MEM | dma | RW: DMEM byte offset (line aligned) |
| 0x12 | DMA_GO | dma | W: [15:0] lines, [16] 1 = DMEM → memory, 0 = memory → DMEM |
| 0x13 | DMA_STATUS | dma | R: [0] busy, [1] error, [15:8] writes not yet answered |
| 0x20 | FW_STATUS | fw | W: [15:8] → CPFW_STATUS[15:8] firmware state, [16] PARK (the firmware has stopped for a halt request: the core stops); any write is the ALIVE heartbeat.  R: CPFW_STATUS |
| 0x21-0x24 | MBOX0-3 | fw | RW: CPFW_MBOX0..3 (shared with the host) |
| 0x25 | FW_VERSION | fw | RW: CPFW_VERSION |

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `UOP_DEPTH_LOG2` | `4` | UOP_FIFO depth log2 (16 dwords). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Reset. |
| **Core data port** | | | |
| `d_valid` | in | 1 | Access. |
| `d_write` | in | 1 | Store. |
| `d_addr` | in | 32 | Byte address. |
| `d_wdata` | in | 32 | Data. |
| `d_be` | in | 4 | Byte enables. |
| `d_ready` | out | 1 | Done this cycle. |
| `d_rdata` | out | 32 | Load data. |
| **DMEM data port (atg_cpu_mem)** | | | |
| `m_en` | out | 1 | Access. |
| `m_we` | out | 4 | Byte writes. |
| `m_addr` | out | 32 | DMEM byte offset. |
| `m_wdata` | out | 32 | Data. |
| `m_rdata` | in | 32 | Data, next cycle. |
| **Sub-bus to atg_cpu_dma and atg_cpu_fw** | | | |
| `sb_we` | out | 1 | Write. |
| `sb_re` | out | 1 | Read. |
| `sb_idx` | out | 6 | Index. |
| `sb_wdata` | out | 32 | Data. |
| `dma_rdata` | in | 32 | atg_cpu_dma's read data. |
| `fw_rdata` | in | 32 | atg_cpu_fw's read data. |
| **Class V packet (from atg_cp_ring)** | | | |
| `v_valid` | in | 1 | Packet waiting. |
| `v_addr` | in | 32 | dword1 address. |
| `v_dwords` | in | 16 | n. |
| `v_tag` | in | 8 | JOB_TAG. |
| `v_done` | out | 1 | DONE pulse. |
| **µops to atg_cp_seq** | | | |
| `fw_valid` | out | 1 | FIFO head valid. |
| `fw_ready` | in | 1 | Taken. |
| `fw_data` | out | 32 | Dword. |
| `fw_last` | out | 1 | Last dword of a packet. |
| `fw_active` | out | 1 | PKT_INFO[31]: from v_valid until v_done (DONE and the FIFO empty). |
| **Other** | | | |
| `st_ridx` | out | 9 | STATE read index (atg_cp_state cpu port). |
| `st_rdata` | in | 32 | STATE word, next cycle. |
| `fence_last` | in | 32 | FENCE_LAST. |
| `fence_ev` | in | 1 | Fence completion pulse (interrupt cause 1). |
| `halt_req` | in | 1 | CTRL.HALT / CPFW HALT pending (interrupt cause 2). |
| `irq` | out | 1 | To the core. |
| `ev_result` | out | 1 | IRQ_STATUS.RESULT pulse. |
| `stall` | out | 1 | The core waits on a full UOP_FIFO (not counted by the watchdog). |

38 ports.

## 4. Behaviour

- Every access is answered the cycle after it is taken (d_ready comes from a register, never from
  d_addr in the same cycle: the 100 MHz timing of the core's address adder → decode → stall path).
  Decode: d_addr in DMEM → m_* in the cycle taken, a load's data is m_rdata in the answer cycle;
  window → own registers (indices 0x00-0x0F) or sb_* (0x10-0x3F), read data registered; a UOP
  write waits while the FIFO is full; anything else → answered with 0 (the firmware is trusted; a
  store there is dropped).  STATE_DATA is read in the cycle taken: st_rdata is valid there because
  a STATE_IDX store is answered a cycle later than it is taken.  Window accesses are whole words: d_be is
  ignored.  Unused own indices read 0.
- UOP_FIFO: am_fifo of {last, dword}; fw_valid = not empty.  The sequencer takes µops only while
  fw_active, so µops written outside a packet wait for the next one.
- Packet: `taken` is set by a PKT_INFO read while PKT_INFO[31] = 1.  DONE (only while
  PKT_INFO[31] = 1, else ignored) waits for the FIFO to empty, then pulses v_done once; PKT_INFO[31]
  is 0 from then until v_valid falls (atg_cp_ring drops v_valid for at least one cycle between two
  packets), so the old packet is never seen twice.
- irq = |({halt_req, fence_pending, v_valid & !taken} & IRQ_EN).  IRQ_EN (0x0D, reset 0) is the p017
  addition: halt_req is a level the firmware cannot clear, so without a mask the handler could
  never return; it also keeps interrupts away until boot has set up the stack.

## 5. State machine

One small FSM for the data access: IDLE →(access; a UOP write only when the FIFO has room)→ ACK
(d_ready) → IDLE.

## 6. Latency and throughput

Every load and store 2 cycles (taken, answered).

## 7. Corner cases and errors

- DONE with µops still in the FIFO: fw_active stays 1 until the FIFO drains, then v_done.
- fence_ev in the same cycle as the W1C of IRQ[1]: the event wins (stays pending).

## 8. What the TB checks

`sim/tb/atg_cpu_win_tb.v` prints, in this order:

- `PASS atg_cpu_win.decode` — DMEM, window and sub-bus accesses go to the right place
- `PASS atg_cpu_win.uop` — UOP/UOP_LAST fill the FIFO, a full FIFO stalls with stall = 1
- `PASS atg_cpu_win.packet` — PKT_* reflect v_*, DONE pulses v_done after the FIFO drains
- `PASS atg_cpu_win.irq` — the three interrupt causes
- `PASS atg_cpu_win` at the end.

## 9. References

design §2.4.7 (the control window), §2.4.8 (firmware use).

## 10. Status

Implemented in WS288 p017 (P2, branch p2-cpu); `sim/tb/atg_cpu_win_tb.v` passes.  p017 spec
changes: IRQ_EN (0x0D), PKT_INFO/taken/DONE rules, every access answered from a register the
cycle after (timing), d_be ignored in the window.
