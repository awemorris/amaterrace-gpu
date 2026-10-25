# atg_tu

RTL: `rtl/gpu/tu/atg_tu.v`.  Parent: atg_top (HAS_TU).  Implemented in: p009.

## 1. Purpose and place

The texture unit (design §2.3, §3.7): addressing, cache, filter; one MC client.

Children: `atg_tu_addr` (with its children `atg_tu_desc`, `atg_tu_cube`, `atg_tu_lod`, `atg_tu_foot`), `atg_tu_cache`, `atg_tu_filter` (the 8-bit path), `atg_tu_ffilt` (the fp32 path of TEX_FORMAT's formats, with `atg_tu_etc`, the ETC2 and EAC decoder).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **STATE broadcast (from atg_cp_state)** | | | |
| `st_we` | in | 1 | One-cycle write of STATE[st_idx]. |
| `st_idx` | in | 10 | STATE index (design §2.3; 0x200-0x2FF the vertex stage's slots). |
| `st_wdata` | in | 32 | STATE value; the block keeps the words of its range. |
| `inv` | in | 1 | INVALIDATE[1] (T$). |
| `busy` | out | 1 | STATUS.TU_BUSY (approximation: a stage holds a quad, or atg_tu_desc computes level offsets). |
| **Requests from the SU (atg_su tx_*/tr_*)** | | | |
| `tx_valid` | in | 1 | Quad. |
| `tx_ready` | out | 1 | Taken. |
| `tx_op` | in | 8 | [1:0] 0 texl, 1 texb, 2 texf, 3 texsz; modifiers (the uop's TEX op bits): [2] .c form, [3] gather (texl) or the depth query (texsz.d), [5:4] gather's component, [6] query (texb: texqlod; texsz: texsz.l), [7] 0. |
| `tx_slot` | in | 4 | Slot. |
| `tx_vs` | in | 1 | The request is a vertex warp's: the vertex stage's slots (STATE 0x200 + 16 slot). |
| `tx_mask` | in | 4 | Lanes. |
| `tx_coord` | in | 640 | 4 lanes × {u (or x), v (or y), lod/bias/level, Dref (.c forms, else 0), the third coordinate (.3 forms, else 0)} × 32 bits, lane 0 first. |
| `tx_off` | in | 12 | The texel offsets {dw, dv, du}, signed 4 bits each. |
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

33 ports; 22 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Wiring only; busy is the OR of the stage valids (the cache's misses are inside ta_valid).  The cache's output goes to atg_tu_filter, or with tc_ctl[20] to atg_tu_ffilt, and is taken only while both filters are idle (tc_ready is the AND of theirs): one quad at a time is in the filters, so the returns (tr_* is the one filter's that holds a result) stay in request order; switching paths costs no more than the filters' own one-quad-at-a-time.

As implemented: busy = tx_valid | ta_valid | tc_valid | tr_valid | desc_busy (a quad on one of the links, or atg_tu_desc computing level offsets; a quad being worked on inside a child is not seen).  STATUS.TU_BUSY is therefore approximate; the STATE of the TU is protected by atg_cp_seq, whose SET_REG of 0x090-0x18F also waits for the RX and the SUs (they hold every fragment that is still to be textured).

## 5. State machine

None (wiring).

## 6. Latency and throughput

Mip linear and 3D linear filtering send a quad two or four times through the cache and the filter (atg_tu_addr §4); the filter returns one quad for the passes.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_tu_tb.v` prints `PASS atg_tu.quads (32)`, `PASS atg_tu.quads (64)`, `PASS atg_tu.rows (32)`, `PASS atg_tu.rows (64)` and `PASS atg_tu`: about 1900 quads (sim/vec/tu_quad.txt from `tools/tu-vectors.py`, `tools/tumodel.py` `sample`) through the whole TU with 32- and 64-byte lines on a memory model (word a = (a >> 2) × 0x9E3779B1, random request accept and latency): random descriptors of the earlier codes and of TEX_FORMAT's formats, every op (rows: small images of odd widths with TEX_ROW 1-3), random gaps and tr_ready, the 16 words, tag and last of every quad in order (the two paths interleaved).  `sim/tb/atg_top_tex_tb.v` (`PASS atg_top_tex`) and the Verilator TEX mode run the whole TU in a textured scene.

## 9. References

design §2.3, §3.7.

## 10. Status

Wiring written in WS288 p023; the children implemented in WS288 p009 part C (P1, branch p1-tu): `atg_tu_addr`, `atg_tu_cache`, `atg_tu_filter`.  busy now includes tr_valid.  Part E (P3): the internal ta_* / tc_* links widened (wts 96, ctl 16) for mip linear filtering, clamp to border, the depth formats and compare; the ports are unchanged.  CAPS[26] = 1 with the TU (atg_cp).

TEX_FORMAT (2026-10-25, Vulkan 1.0's formats, docs/ghci.md §8.5): atg_tu_ffilt and the routing of the two paths; ta_bord / tc_bord, ta_ctl / tc_ctl 48 bits inside; the ports are unchanged.  The CAPS bit (CAPS[30]) is set with the rest of CAPS[30]'s work.

Part F (P3, branch p3-p009f): the descriptor of docs/ghci.md §8.4 (2D arrays, 3D, cube maps, the level offsets computed by atg_tu_desc), texel offsets (the new port tx_off), unnormalized coordinates; tx_coord 5 words a lane; ta_wts / tc_wts 128 bits (fw added); busy includes desc_busy.  CAPS[26] now says the whole of §8.4.
