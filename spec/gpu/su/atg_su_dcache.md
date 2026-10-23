# atg_su_dcache

RTL: `rtl/gpu/su/atg_su_dcache.v`.  Parent: atg_su.  Implemented in: p008.

## 1. Purpose and place

The SU's data cache: 1 KiB direct-mapped (32 lines of 32 bytes), write-through, read-allocate, flash-invalidated; between the LSU's line requests and the MC.

`u_*` is the upstream AMB port from atg_su_lsu (this module is its server side); `m_*` goes to the MC (client 2·k+0 of SU k).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 (ZYBO) or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `DC_BYTES` | `1024` | Size in bytes. |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `inv` | in | 1 | Invalidate all (INVALIDATE[0], DRAW start, fence acquire). |
| **AMB client port (design §4.1)** | | | |
| `u_req_valid` | in | 1 | Request valid; payload held until `u_req_ready`. |
| `u_req_ready` | out | 1 | The MC (or mux) takes the request this cycle. |
| `u_req_write` | in | 1 | 1 write, 0 read. |
| `u_req_line` | in | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `u_req_be` | in | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `u_req_wdata` | in | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `u_req_tag` | in | 8 | The client's tag, returned with the response. |
| `u_rsp_valid` | out | 1 | Response, one cycle, no back-pressure; one per request. |
| `u_rsp_write` | out | 1 | The response is a write's (after BRESP). |
| `u_rsp_tag` | out | 8 | Tag of the request answered. |
| `u_rsp_rdata` | out | LINE_BYTES*8 | Read data (valid for reads). |
| `u_rsp_error` | out | 1 | Aperture or AXI error; the line was not accessed. |
| **AMB client port (design §4.1)** | | | |
| `m_req_valid` | out | 1 | Request valid; payload held until `m_req_ready`. |
| `m_req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `m_req_write` | out | 1 | 1 write, 0 read. |
| `m_req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `m_req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `m_req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `m_req_tag` | out | 8 | The client's tag, returned with the response. |
| `m_rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `m_rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `m_rsp_tag` | in | 8 | Tag of the request answered. |
| `m_rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `m_rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |

27 ports; 5 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Reads: hit → answer next cycle; miss → read the line from the MC, fill, answer.  Writes: write through to the MC with the byte enables and update a hit line; the response after the MC's.  Tags returned as received.

## 5. State machine

IDLE → (HIT | MISS_REQ → MISS_WAIT → FILL) → IDLE; writes: WRITE_REQ → WRITE_WAIT.

## 6. Latency and throughput

Hit 1 cycle; one miss outstanding (v1).

## 7. Corner cases and errors

- inv during a miss: the fill is not kept.  m_rsp_error is returned as u_rsp_error.

## 8. What the TB checks

`sim/tb/atg_su_dcache_tb.v` prints, in this order:

- `PASS atg_su_dcache.hit` — read hits and misses against a memory model
- `PASS atg_su_dcache.wt` — writes reach memory and update hit lines
- `PASS atg_su_dcache.inv` — invalidate
- `PASS atg_su_dcache` at the end.

## 9. References

design §3.5 (D$ 1 KiB, write-through), §4.1.

## 10. Status

Implemented in WS288 p008 part 2 (branch p1-su2; TB `sim/tb/atg_su_dcache_tb.v`).  As §4-§7: one request at a time, a write updates a line that is present when the MC answers, m_req_tag is 0.
