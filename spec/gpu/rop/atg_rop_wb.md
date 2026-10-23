# atg_rop_wb

RTL: `rtl/gpu/rop/atg_rop_wb.v`.  Parent: atg_rop.  Implemented in: p007.

## 1. Purpose and place

ROP write-back: a small write-combining buffer of render-target lines; reads the destination line when blending, sends pixels through atg_rop_blend, writes lines back; drains when idle.

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
| **From atg_rop_ds** | | | |
| `d_valid` | in | 1 | A quad after depth/stencil. |
| `d_ready` | out | 1 | Taken. |
| `d_xy` | in | 32 | Position. |
| `d_mask` | in | 4 | Lanes that passed. |
| `d_color` | in | 512 | Colour (DEBUG_COLOR expanded for q_dbg). |
| **atg_rop_blend** | | | |
| `b_valid` | out | 1 | Blend. |
| `b_src` | out | 512 | Source. |
| `b_dst` | out | 128 | Destination. |
| `b_mask` | out | 4 | Lanes. |
| `b_rvalid` | in | 1 | Result. |
| `b_pix` | in | 128 | Pixels. |
| `busy` | out | 1 | Lines not yet written or responses outstanding. |
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

29 ports; 18 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Two line buffers (one per quad row).  A quad: find/allocate the lines (read them first when blending or with a partial WRITE_MASK), blend, merge, mark dirty; a line is written when replaced or when the ROP is idle for 16 cycles (and before busy falls, so FENCE sees the pixels).

## 5. State machine

IDLE → (LOOKUP → READ? → BLEND → MERGE) → (EVICT → WRITE) → IDLE.

## 6. Latency and throughput

One quad per cycle on buffer hits.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_rop_wb_tb.v` prints, in this order:

- `PASS atg_rop_wb.write` — pixels reach memory
- `PASS atg_rop_wb.blend` — read-blend-write
- `PASS atg_rop_wb.drain` — busy falls only after the writes are answered
- `PASS atg_rop_wb` at the end.

## 9. References

design §2.3 (RT_*), §3.8 (ROP is never blocked by the SU).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
