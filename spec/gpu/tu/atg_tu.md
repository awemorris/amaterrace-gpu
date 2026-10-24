# atg_tu

RTL: `rtl/gpu/tu/atg_tu.v`.  Parent: atg_top (HAS_TU).  Implemented in: p009.

## 1. Purpose and place

The texture unit (design §2.3, §3.7): addressing, cache, filter; one MC client.

Children: `atg_tu_addr`, `atg_tu_cache`, `atg_tu_filter`.

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
| `inv` | in | 1 | INVALIDATE[1] (T$). |
| `busy` | out | 1 | STATUS.TU_BUSY (approximation: a stage holds a quad). |
| **Requests from the SU (atg_su tx_*/tr_*)** | | | |
| `tx_valid` | in | 1 | Quad. |
| `tx_ready` | out | 1 | Taken. |
| `tx_op` | in | 2 | 0 texl, 1 texb, 2 texf, 3 texsz. |
| `tx_slot` | in | 4 | Slot. |
| `tx_mask` | in | 4 | Lanes. |
| `tx_coord` | in | 384 | Coordinates. |
| `tx_tag` | in | 16 | Tag. |
| `tx_last` | in | 1 | Last. |
| **Return** | | | |
| `tr_valid` | out | 1 | Returned quad (in request order). |
| `tr_ready` | in | 1 | Taken. |
| `tr_tag` | out | 16 | Tag. |
| `tr_data` | out | 512 | 4 lanes × RGBA fp32 (texsz: lane word 0 = {h, w}). |
| `tr_last` | out | 1 | Last. |
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

32 ports; 21 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Wiring only; busy is the OR of the stage valids (the cache's misses are inside ta_valid).

As implemented: busy = tx_valid | ta_valid | tc_valid | tr_valid (a quad on one of the links; a quad being worked on inside a child is not seen).  STATUS.TU_BUSY is therefore approximate; the STATE of the TU is protected by atg_cp_seq, whose SET_REG of 0x090-0x18F also waits for the RX and the SUs (they hold every fragment that is still to be textured).

## 5. State machine

None (wiring).

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.  `sim/tb/atg_top_tex_tb.v` (`PASS atg_top_tex`) and the Verilator TEX mode run the whole TU in a textured scene.

## 9. References

design §2.3, §3.7.

## 10. Status

Wiring written in WS288 p023; the children implemented in WS288 p009 part C (P1, branch p1-tu): `atg_tu_addr`, `atg_tu_cache`, `atg_tu_filter`.  busy now includes tr_valid.
