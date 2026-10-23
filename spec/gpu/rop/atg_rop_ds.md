# atg_rop_ds

RTL: `rtl/gpu/rop/atg_rop_ds.v`.  Parent: atg_rop.  Implemented in: p007.

## 1. Purpose and place

ROP depth and stencil: reads the depth/stencil line of the quad (DS_BASE/STRIDE, D32F or D24S8), tests (DEPTH func, STENCIL_* front/back), updates and writes it back, and passes the surviving lanes.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 (ZYBO) or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `STENCIL` | `0` | Stencil present (ROP_STENCIL). |

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
| **From atg_rop_order** | | | |
| `q_valid` | in | 1 | A quad in primitive order. |
| `q_ready` | out | 1 | Taken. |
| `q_xy` | in | 32 | Position. |
| `q_mask` | in | 4 | Lanes. |
| `q_color` | in | 512 | Colour (fp32 RGBA × 4). |
| `q_depth` | in | 128 | Depth. |
| `q_dbg` | in | 1 | From the direct path: use DEBUG_COLOR. |
| **To atg_rop_wb** | | | |
| `d_valid` | out | 1 | A quad after depth/stencil. |
| `d_ready` | in | 1 | Taken. |
| `d_xy` | out | 32 | Position. |
| `d_mask` | out | 4 | Lanes that passed. |
| `d_color` | out | 512 | Colour (DEBUG_COLOR expanded for q_dbg). |
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

Depth test off: pass all.  A quad's 2×2 pixels lie in two rows: two reads (or one line per row), compare, write if DEPTH[1] and any lane passed.  Read-after-write order: the next quad touching the same line waits for the write response (small address match).

## 5. State machine

IDLE → READ → TEST → WRITE → IDLE.

## 6. Latency and throughput

One quad per AMB round trip (v1); a depth line cache is p015.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_rop_ds_tb.v` prints, in this order:

- `PASS atg_rop_ds.funcs` — all 8 depth functions
- `PASS atg_rop_ds.stencil` — stencil ops (STENCIL 1)
- `PASS atg_rop_ds.raw` — overlapping quads in order
- `PASS atg_rop_ds` at the end.

## 9. References

design §2.3 (ROP STATE 0x070-0x07C).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
