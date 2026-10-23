# atg_vf_fetch

RTL: `rtl/gpu/vf/atg_vf_fetch.v`.  Parent: atg_vf.  Implemented in: p009.

## 1. Purpose and place

VF attribute fetch: for each vertex of a warp and each enabled attribute k (ATTR[k]_BASE/DESC), computes the address (per-vertex or per-instance with divisor) and reads the attribute's bytes through the AMB.

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
| **Vertices of a warp (atg_vf_asm → atg_vf_fetch)** | | | |
| `vb_valid` | in | 1 | A vertex for lane vb_lane. |
| `vb_ready` | out | 1 | Taken. |
| `vb_index` | in | 32 | Index (+ VERTEX_OFFSET applied). |
| `vb_inst` | in | 32 | Instance. |
| `vb_lane` | in | 5 | Lane. |
| `vb_last` | in | 1 | Last vertex of the warp. |
| **Attribute data (atg_vf_fetch → atg_vf_conv)** | | | |
| `af_valid` | out | 1 | One attribute of one vertex. |
| `af_ready` | in | 1 | Taken. |
| `af_attr` | out | 4 | Attribute k. |
| `af_lane` | out | 5 | Lane. |
| `af_raw` | out | 128 | Raw bytes (up to 16), byte 0 in [7:0]. |
| `af_last` | out | 1 | Last attribute of the last lane of the warp. |
| `busy` | out | 1 | Work outstanding. |
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

30 ports; 19 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

addr = ATTR_BASE + stride × (per_instance ? inst / divisor : index).  An attribute that crosses a line needs two reads; the bytes are merged.  The attributes with ATTR_DST components 0 are skipped.  Order out: lane-major (all attributes of lane 0, then lane 1) so conv can write as data comes.

## 5. State machine

IDLE → (per vertex, per attribute) REQ → WAIT → EMIT → IDLE.

## 6. Latency and throughput

Up to 4 reads outstanding; one attribute per line round trip at worst.

## 7. Corner cases and errors

- Divisor 0 means every instance uses instance 0's data (Vulkan's divisor 0 rule).

## 8. What the TB checks

`sim/tb/atg_vf_fetch_tb.v` prints, in this order:

- `PASS atg_vf_fetch.addr` — strides, offsets, per-instance with divisors
- `PASS atg_vf_fetch.cross` — attributes that cross a line
- `PASS atg_vf_fetch` at the end.

## 9. References

design §2.3 (ATTR_*), §3.4.3.

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
