# atg_cpu

RTL: `rtl/gpu/cp/atg_cpu.v`.  Parent: atg_top (HAS_CPU).  Implemented in: p017.

## 1. Purpose and place

The CP's control processor (design §2.4.7): RV32IM core, IMEM/DMEM, control window, line DMA and the CPFW capability; the firmware decodes class V packets into µops.

Children: `atg_cpu_core`, `atg_cpu_mem`, `atg_cpu_win`, `atg_cpu_dma`, `atg_cpu_fw`.

Address map of the core (byte addresses):

| Range | What |
| --- | --- |
| 0x0000_0000-0x0001_FFFF | IMEM (fetch only; IMEM_WORDS words, 128 KiB at most) |
| 0x0002_0000-0x0002_FFFF | DMEM (load/store; DMEM_WORDS words: .data, .rodata, .bss, stack) |
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
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `IMEM_WORDS` | `8192` | IMEM size in 32-bit words (32 KiB; atg_top's CPU_IMEM_WORDS, KC705 32768 = 128 KiB). |
| `DMEM_WORDS` | `4096` | DMEM size in words (16 KiB; atg_top's CPU_DMEM_WORDS, KC705 8192 = 32 KiB). |
| `IMEM_INIT` | `""` | IMEM image file. |
| `DMEM_INIT` | `""` | DMEM image file. |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Core reset (core_rst_n). |
| **HCR register snoop (from atg_cp_regs)** | | | |
| `hcr_we` | in | 1 | One-cycle write strobe to an HCR word (0x000-0xFFC). |
| `hcr_widx` | in | 10 | Word index of the write (byte offset >> 2). |
| `hcr_wdata` | in | 32 | Write data. |
| `hcr_wmask` | in | 32 | Bit mask from WSTRB (1 = written). |
| `hcr_ridx` | in | 10 | Word index being read; the read data is due in the same cycle (combinational from this registered index). |
| `hcr_rdata` | out | 32 | Read data of this module's registers at `hcr_ridx`, 0 for other indices (the parent ORs them). |
| **Class V packet (atg_cp_ring)** | | | |
| `v_valid` | in | 1 | Packet waiting. |
| `v_addr` | in | 32 | dword1 address. |
| `v_dwords` | in | 16 | n. |
| `v_tag` | in | 8 | JOB_TAG. |
| `v_done` | out | 1 | DONE. |
| **µops (atg_cp_seq)** | | | |
| `fw_valid` | out | 1 | Dword. |
| `fw_ready` | in | 1 | Taken. |
| `fw_data` | out | 32 | Data. |
| `fw_last` | out | 1 | Last. |
| `fw_active` | out | 1 | Packet open. |
| **CP state** | | | |
| `st_ridx` | out | 10 | STATE read index. |
| `st_rdata` | in | 32 | STATE data. |
| `fence_last` | in | 32 | FENCE_LAST. |
| `fence_ev` | in | 1 | Fence event. |
| `halt_req` | in | 1 | HALT. |
| `open` | in | 1 | IDLE/HALTED. |
| `ev_result` | out | 1 | IRQ RESULT. |
| `stall` | out | 1 | Watchdog exclusion. |
| `fault` | out | 1 | Firmware fault (kind 4). |
| `fault_addr` | out | 32 | PC. |
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

Wiring only: the children's specs hold the behaviour.  hcr_rdata is atg_cpu_fw's.

## 5. State machine

None (wiring).

## 6. Latency and throughput

See the children.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_cpu_tb.v` (added in p017; the module itself is wiring) runs `sim/tb/cpu/cpu_top.S` from
the init images (32-byte lines) with ring, sequencer, STATE, host and AMB models, and prints, in this
order:

- `PASS atg_cpu.packet` — a class V packet is taken by the interrupt, read by DMA, and its dwords
  (with a STATE word) come out as µops in order, then v_done once
- `PASS atg_cpu.dma` — the firmware's DMA write lands in memory; MBOX1 and RESULT follow
- `PASS atg_cpu.halt` — halt_req parks the core (CPFW_STATUS.STOPPED)
- `PASS atg_cpu.reload` — CPFW LOAD of `cpu_reload.S` from memory runs (its .data word shows in
  MBOX3) and then faults with its PC (fault, CPFW_STATUS.FAULT)
- `PASS atg_cpu` at the end.

The children's own testbenches: `atg_cpu_core` (RV32IM programs), `atg_cpu_alu`, `atg_cpu_muldiv`,
`atg_cpu_mem`, `atg_cpu_win`, `atg_cpu_dma`, `atg_cpu_fw`.

## 9. References

design §2.4.7, §2.4.8, §2.4.10.

## 10. Status

Wiring written in WS288 p023; the children implemented in WS288 p017 (P2, branch p2-cpu), with
`sim/tb/atg_cpu_tb.v`.  p017 spec changes: window IRQ_EN (0x0D), FW_STATUS [16] PARK, the CPFW HCR
layout (MBOX0-3 at 0x150, see atg_cpu_fw).  With the firmware (fw/cp/, p017 part 2):
`sim/tb/atg_top_fw_tb.v` runs atg_top with HAS_CPU and the firmware images (spec/gpu/cp/atg_cp.md §8).

2026-10-25 (CAPS[30]): STATE has 0x000-0x2FF (0x200-0x2FF the vertex stage's texture slots, docs/ghci.md §8.1, §8.5); STATE indices are 10 bits.

2026-10-25 (ws288-p034, user decision "IMEM を 128 KiB"): IMEM 0x0000_0000-0x0001_FFFF (the core faults a fetch above it), DMEM moved to 0x0002_0000-0x0002_FFFF; the KC705 has IMEM 32768 words (128 KiB).  The firmware had reached 65520 of 64 KiB with session protection.
