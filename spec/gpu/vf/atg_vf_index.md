# atg_vf_index

RTL: `rtl/gpu/vf/atg_vf_index.v`.  Parent: atg_vf.  Implemented in: p009.

## 1. Purpose and place

VF index stage: walks FIRST..FIRST+COUNT (non-indexed) or reads the index buffer (u16/u32), detects primitive restart, and repeats for INSTANCE_COUNT instances.

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
| **STATE broadcast (from atg_cp_state)** | | | |
| `st_we` | in | 1 | One-cycle write of STATE[st_idx]. |
| `st_idx` | in | 9 | STATE index (design §2.3). |
| `st_wdata` | in | 32 | STATE value; the block keeps the words of its range. |
| `kick` | in | 1 | DRAW (one-cycle). |
| `busy` | out | 1 | Walking. |
| **Index stream (atg_vf_index → atg_vf_asm)** | | | |
| `iv_valid` | out | 1 | A vertex. |
| `iv_ready` | in | 1 | Taken. |
| `iv_index` | out | 32 | Vertex index (index buffer value or FIRST + n), before VERTEX_OFFSET. |
| `iv_inst` | out | 32 | Instance number (FIRST_INSTANCE + i). |
| `iv_restart` | out | 1 | Primitive restart marker (no vertex). |
| `iv_last` | out | 1 | Last vertex of the last instance. |
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

25 ports; 14 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Indexed: line reads of the index buffer from INDEX_BASE + FIRST × size; each index (u16/u32) out in order; with PRIM_RESTART, 0xFFFF/0xFFFFFFFF gives iv_restart.  Instances: the whole index walk repeated, iv_inst = FIRST_INSTANCE + i (design §2.3 VF range).

## 5. State machine

IDLE →(kick)→ READ (line) → EMIT (indices of the line) → … → NEXT_INSTANCE → … → IDLE.

## 6. Latency and throughput

One index per cycle from a line; one line request ahead.

## 7. Corner cases and errors

- COUNT 0 or INSTANCE_COUNT 0: iv_last without vertices? No: nothing is sent and atg_vf_asm ends the draw (it sees busy fall).  rsp_error: stop (the MC faulted).

## 8. What the TB checks

`sim/tb/atg_vf_index_tb.v` prints, in this order:

- `PASS atg_vf_index.direct` — non-indexed draws
- `PASS atg_vf_index.u16u32` — index buffers of both sizes, unaligned FIRST
- `PASS atg_vf_index.restart` — restart markers
- `PASS atg_vf_index.inst` — instances
- `PASS atg_vf_index` at the end.

## 9. References

design §2.3 (VF STATE 0x020-0x02F), §3.8.

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
