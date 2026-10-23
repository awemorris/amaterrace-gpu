# atg_rop

RTL: `rtl/gpu/rop/atg_rop.v`.  Parent: atg_top (HAS_ROP).  Implemented in: p007.

## 1. Purpose and place

The ROP / buffer writer (design §2.3, §3.8): primitive-order retirement, depth/stencil, blend, write-back; one MC client (depth and colour behind am_amb_mux).

Children: `atg_rop_order`, `atg_rop_ds`, `atg_rop_blend`, `atg_rop_wb`, `am_amb_mux`.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 (ZYBO) or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `STENCIL` | `0` | ROP_STENCIL. |

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
| `busy` | out | 1 | STATUS.ROP_BUSY. |
| **Fragment output of SU 0 (atg_su ex_*)** | | | |
| `ex_valid` | in | 1 | Quad. |
| `ex_ready` | out | 1 | Taken. |
| `ex_seq` | in | 16 | Sequence. |
| `ex_xy` | in | 32 | Position. |
| `ex_mask` | in | 4 | Lanes. |
| `ex_color` | in | 512 | Colour. |
| `ex_depth` | in | 128 | Depth. |
| `ex_last` | in | 1 | Last quad of the warp. |
| `ex_next` | out | 16 | The next sequence number to retire. |
| **Direct fragments to the ROP (no SU: DEBUG_COLOR)** | | | |
| `dx_valid` | in | 1 | A quad. |
| `dx_ready` | out | 1 | Taken. |
| `dx_seq` | in | 16 | Sequence number. |
| `dx_xy` | in | 32 | {y, x} of the quad. |
| `dx_mask` | in | 4 | Covered lanes. |
| `dx_depth` | in | 128 | 4 × z (fp32). |
| `dx_last` | in | 1 | Last quad of the primitive's sequence number. |
| **Issued sequence numbers (atg_rx ord_*)** | | | |
| `ord_valid` | in | 1 | Issued. |
| `ord_seq` | in | 16 | Number. |
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

36 ports; 25 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Wiring only; ds is requester 0, wb requester 1.

## 5. State machine

None (wiring).

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.

## 9. References

design §2.3, §3.8.

## 10. Status

2026-10-24 Q1 (P3's p007 decisions, ACKed; ghci.md to follow): stencil ops are not implemented in v1 (the ROP gets no facing bit; a port change belongs to p009). STATE bits: SCISSOR_MIN/MAX `{y, x}` (MAX 0 = none), RT_SIZE `{h, w}`, CULL [1:0] 1 front/2 back/3 both and [2] front = CCW, DEBUG_COLOR and BLEND_CONST RGBA8 (R in [7:0]), BLEND [0] enable, [4:1] src colour, [8:5] dst colour, [11:9] colour op, [15:12] src alpha, [19:16] dst alpha, [22:20] alpha op (VkBlendFactor/VkBlendOp numbers), WRITE_MASK [3:0] RGBA (0 writes nothing), DEPTH func = VkCompareOp and no test without a depth format bit; DS_BASE/RT_BASE/stride aligned to 8 bytes (4 for RGB565). The CP sequencer holds a SET_REG into the RX range (0x050–0x06F) while RX or ROP is busy and into the ROP range (0x070–0x08F) while the ROP is busy.

Wiring written in WS288 p023 (children are stubs unless their spec says otherwise).
