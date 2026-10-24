# atg_rop_ds

RTL: `rtl/gpu/rop/atg_rop_ds.v`.  Parent: atg_rop.  Implemented in: p007.

## 1. Purpose and place

ROP depth and stencil: reads the depth/stencil line of the quad (DS_BASE/STRIDE, D32F or D24S8), tests (DEPTH func, STENCIL_* front/back), updates and writes it back, and passes the surviving lanes.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
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
| `q_smask` | in | 16 | Samples: bit 4 l + s (one sample: bit 4 l). |
| `q_color` | in | 512 | Colour (fp32 RGBA × 4). |
| `q_sdepth` | in | 512 | The samples' depths: sample s of lane l at 32 (4 l + s). |
| `q_dbg` | in | 1 | From the direct path: use DEBUG_COLOR. |
| `q_front` | in | 1 | (CAPS[30]) The quad's facing (the direct path reads as front). |
| `q_beat` | in | 4 | (CAPS[30]) {rt, nocol, first} of the beat (atg_rop_ms's o_beat). |
| **To atg_rop_wb** | | | |
| `d_valid` | out | 1 | A quad after depth/stencil. |
| `d_ready` | in | 1 | Taken. |
| `d_xy` | out | 32 | Position. |
| `d_smask` | out | 16 | Samples that passed. |
| `d_color` | out | 512 | Colour (DEBUG_COLOR expanded for q_dbg). |
| `d_beat` | out | 4 | The beat's {rt, nocol, first}. |
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

33 ports; 22 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Depth test off: pass all.  A quad's 2×2 pixels lie in two rows: two reads (or one line per row), compare, write if DEPTH[1] and any lane passed.  Read-after-write order: the next quad touching the same line waits for the write response (small address match).

**CAPS[30]**: the module keeps DEPTH[9:0], STENCIL_FRONT, STENCIL_OPS, STENCIL_BACK and DEPTH_BOUNDS_MIN/MAX; each covered (lane, sample) entry goes through `atg_rop_dtest` (bounds, stencil with the quad's facing, depth; spec atg_rop_dtest.md), and its byte enables say which bytes of the line are written.  The line is read when exactly one format bit is set and the depth test, the stencil test (D24S8) or the bounds test is on.  D16 pixels are 2 bytes: sample s of pixel x at byte 2 (S x + s) of the row.

## 5. State machine

IDLE → READ → TEST → WRITE → IDLE.

## 6. Latency and throughput

One quad per AMB round trip (v1); a depth line cache is p015.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_rop_ds_tb.v` prints, in this order:

- `PASS atg_rop_ds.funcs` — all 8 depth functions
- `PASS atg_rop_ds.stencil` — (CAPS[30], `sim/vec/rop_ds2.txt` from `tools/rop-vectors.py`) D24S8 runs with the stencil test and ops, random faces per quad, the buffer at the end
- `PASS atg_rop_ds.raw` — overlapping quads in order
- `PASS atg_rop_ds.d16` — D16 runs (2-byte pixels)
- `PASS atg_rop_ds.bounds` — the depth bounds of the three formats
- `PASS atg_rop_ds` at the end.

## 9. References

design §2.3 (ROP STATE 0x070-0x07C).

## 10. Status

2026-10-24 Q1 (P3's p007 decisions, ACKed; ghci.md to follow): stencil ops are not implemented in v1 (the ROP gets no facing bit; a port change belongs to p009). STATE bits: SCISSOR_MIN/MAX `{y, x}` (MAX 0 = none), RT_SIZE `{h, w}`, CULL [1:0] 1 front/2 back/3 both and [2] front = CCW, DEBUG_COLOR and BLEND_CONST RGBA8 (R in [7:0]), BLEND [0] enable, [4:1] src colour, [8:5] dst colour, [11:9] colour op, [15:12] src alpha, [19:16] dst alpha, [22:20] alpha op (VkBlendFactor/VkBlendOp numbers), WRITE_MASK [3:0] RGBA (0 writes nothing), DEPTH func = VkCompareOp and no test without a depth format bit; DS_BASE/RT_BASE/stride aligned to 8 bytes (4 for RGB565). The CP sequencer holds a SET_REG into the RX range (0x050–0x06F) while RX or ROP is busy and into the ROP range (0x070–0x08F) while the ROP is busy.

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.

2026-10-24 (p009 part E, P3): the depth conversion and compare functions moved to `include/atg_depth.vh`, shared with the TU's compare samplers (atg_tu_filter); the behaviour is unchanged.

Multisampling (the MSAA work): MS_CTRL[3:0] = 2 makes the row's address base + y stride + 16 x and the test runs per sample (8 entries per row: sample s of pixel x at word 4 x + s); one sample: as before (2 entries).  `q_mask`/`q_depth`/`d_mask` became `q_smask`/`q_sdepth`/`d_smask` (the same port count).  The 4-sample cases are in `sim/tb/atg_rop_ms_tb.v`; this TB drives the one-sample masks as bit 4 l and checks that no other bit of d_smask is set.

2026-10-25 (CAPS[30]): atg_rop_dtest per entry, q_front, D16, the stencil and the bounds (§4); every PASS of §8 (`-DMUT_STENCIL_FACE` fails `.stencil` and `.bounds`).  The earlier vectors are unchanged.

2026-10-25 (CAPS[30], colour attachments): `q_beat`, `d_beat`.  The first beat of a quad is tested and written as before; a later beat goes to OUT with the first's surviving samples (no memory access) and is dropped when none survived.  A beat without colour goes on to atg_rop_wb (which drops it), so atg_rop counts the samples of every quad's first beat once (occlusion).  Checked by `sim/tb/atg_rop_beat_tb.v` (`-DMUT_DS_BEAT`, testing every beat, fails `.colour`).
