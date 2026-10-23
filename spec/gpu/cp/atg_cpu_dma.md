# atg_cpu_dma

RTL: `rtl/gpu/cp/atg_cpu_dma.v`.  Parent: atg_cpu.  Implemented in: p017.

## 1. Purpose and place

The CPU's line DMA between GPU memory (AMB) and IMEM/DMEM: the firmware's heap ↔ DMEM copies (window DMA_*) and the CPFW image load (from atg_cpu_fw).

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
| `rst_n` | in | 1 | Reset. |
| **Window sub-bus (from atg_cpu_win)** | | | |
| `sb_we` | in | 1 | Write strobe (one cycle). |
| `sb_re` | in | 1 | Read strobe; data in the same cycle (combinational). |
| `sb_idx` | in | 6 | Window word index. |
| `sb_wdata` | in | 32 | Write data. |
| `sb_rdata` | out | 32 | Read data for this module's indices, else 0. |
| **Image load (from atg_cpu_fw)** | | | |
| `ld_start` | in | 1 | Pulse: copy ld_words words from ld_addr to IMEM or DMEM offset 0. |
| `ld_imem` | in | 1 | 1 IMEM, 0 DMEM. |
| `ld_addr` | in | 32 | GPU address (line aligned). |
| `ld_words` | in | 32 | Words. |
| `ld_done` | out | 1 | Pulse: finished (or error). |
| `ld_error` | out | 1 | With ld_done: an AMB error. |
| **Memory port (atg_cpu_mem x_*)** | | | |
| `x_en` | out | 1 | Access. |
| `x_we` | out | 1 | Write. |
| `x_imem` | out | 1 | IMEM. |
| `x_addr` | out | 32 | Byte offset. |
| `x_wdata` | out | 32 | Data. |
| `x_rdata` | in | 32 | Data, next cycle. |
| `wait_amb` | out | 1 | Waiting on AMB responses (not counted by the watchdog). |
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

32 ports.

## 4. Behaviour

- Reads a line, writes its words to the memory port one per cycle (or reads DMEM words into a line
  buffer and writes the line).  Up to 4 reads outstanding; writes counted until their responses
  (DMA_STATUS[15:8]) so the firmware can follow the memory order rule of design §2.4.8.
- The image load has priority only when the CPU is held in reset (atg_cpu_fw does that), so the two
  sources never overlap.

## 5. State machine

IDLE →(go)→ READ_REQ/READ_WAIT → STORE_WORDS → … → IDLE; or GATHER → WRITE_REQ → IDLE.

## 6. Latency and throughput

One word per cycle into the BRAM; the AMB round trip limits it (about 1 line per 20 cycles on the ZYBO with 4 outstanding).

## 7. Corner cases and errors

- rsp_error: DMA_STATUS.error (window) or ld_error; the copy stops.

## 8. What the TB checks

`sim/tb/atg_cpu_dma_tb.v` prints, in this order:

- `PASS atg_cpu_dma.read` — memory → DMEM of several lines
- `PASS atg_cpu_dma.write` — DMEM → memory; the write counter falls to 0 on the responses
- `PASS atg_cpu_dma.load` — image load into IMEM
- `PASS atg_cpu_dma.error` — an error response stops and reports
- `PASS atg_cpu_dma` at the end.

## 9. References

design §2.4.7 (DMA, CPFW), §2.4.8 (memory order rule).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
