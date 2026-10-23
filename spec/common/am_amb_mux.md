# am_amb_mux

RTL: `rtl/common/am_amb_mux.v`.  Parent: any block with several memory users behind one MC client (atg_cp: ring, fence, dbg; atg_su: icache, cbank; atg_cpu: dma).  Implemented in: p004 (first user: atg_cp).

## 1. Purpose and place

Merges N AMB requesters into one AMB client port: fixed priority (requester 0 first), the requester number in the top bits of the tag, responses routed back by those bits.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 (ZYBO) or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `N` | `2` | Number of requesters, 2..4. |
| `ID_W` | `1` | log2(N) rounded up: the tag bits [7:8-ID_W] carry the requester. |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Requesters (packed, requester 0 in the low bits)** | | | |
| `i_req_valid` | in | N | Request valid per requester. |
| `i_req_ready` | out | N | Taken this cycle. |
| `i_req_write` | in | N | Write per requester. |
| `i_req_line` | in | N*(ADDR_W-LINE_SHIFT) | Line addresses. |
| `i_req_be` | in | N*LINE_BYTES | Byte enables. |
| `i_req_wdata` | in | N*LINE_BYTES*8 | Write data. |
| `i_req_tag` | in | N*8 | Tags; a requester uses only bits [7-ID_W:0]. |
| `i_rsp_valid` | out | N | Response to requester k (one cycle). |
| `i_rsp_write` | out | 1 | Shared response fields, valid with `i_rsp_valid`. |
| `i_rsp_tag` | out | 8 | Tag with the requester bits cleared. |
| `i_rsp_rdata` | out | LINE_BYTES*8 | Read data. |
| `i_rsp_error` | out | 1 | Error. |
| **AMB client port (design §4.1)** | | | |
| `o_req_valid` | out | 1 | Request valid; payload held until `o_req_ready`. |
| `o_req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `o_req_write` | out | 1 | 1 write, 0 read. |
| `o_req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `o_req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `o_req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `o_req_tag` | out | 8 | The client's tag, returned with the response. |
| `o_rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `o_rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `o_rsp_tag` | in | 8 | Tag of the request answered. |
| `o_rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `o_rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |

26 ports.

## 4. Behaviour

- Each cycle the lowest-numbered requester with `i_req_valid` is offered on `o_req_*` (combinational
  mux); `i_req_ready[k] = o_req_ready` for the chosen k only.  The chosen requester is locked while
  `o_req_valid && !o_req_ready` so the payload does not change under the handshake (valid/ready rule
  of docs/style.md).
- `o_req_tag = {k[ID_W-1:0], i_req_tag_k[7-ID_W:0]}`.  A response's tag bits [7:8-ID_W] select
  `i_rsp_valid[k]`; `i_rsp_tag` returns the requester's bits with the top ID_W bits 0.
- Order: a requester's requests keep their order (the MC keeps one client's order).

## 5. State machine

No state machine: one `lock` flag and the locked requester number.

## 6. Latency and throughput

Combinational request path, one request per cycle; responses pass through in the same cycle.

## 7. Corner cases and errors

- Requester tags must leave the top ID_W bits 0; a set bit there is a design error (the TB checks
  the parent's tags, the mux ignores those bits).
- Reset drops the lock.  Starvation of high requesters is accepted (the CP's users are short and the
  priority is ring > fence > dbg).

## 8. What the TB checks

`sim/tb/am_amb_mux_tb.v` prints, in this order:

- `PASS am_amb_mux.priority` — with all requesters valid, requester 0 is served first, then 1, ...
- `PASS am_amb_mux.hold` — payload does not change while o_req_ready is 0 even if a lower requester becomes valid
- `PASS am_amb_mux.route` — random requests and an MC model: every response reaches its requester with its own tag
- `PASS am_amb_mux` at the end.

## 9. References

design §4.1 (AMB), `rtl/gpu/mc/atg_mc.v` (the client port), docs/style.md (handshakes).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
