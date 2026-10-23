# atg_rx_setup

RTL: `rtl/gpu/rx/atg_rx_setup.v`.  Parent: atg_rx.  Implemented in: p007.

## 1. Purpose and place

RX triangle setup: perspective divide and viewport (VIEWPORT 0-5), cull (CULL), edge functions in 15.8 fixed point (guard band ±16384 px; design §3.8 said 16.8), bounding box ∩ scissor, depth and perspective-barycentric planes.

## 2. Parameters

None.

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
| **Triangles from atg_rx_clip** | | | |
| `cl_valid` | in | 1 | A triangle (after clipping). |
| `cl_ready` | out | 1 | Taken. |
| `cl_tri` | in | 700 | [383:0] 3 × clip-space xyzw (fp32, v0 x in [31:0]); [671:384] 3 × 3 weights of the original vertices (fp32); [695:672] the original PT entries; [698:696] last-use flags; [699] raw (DRAW_RAW: screen space). |
| `cl_last` | in | 1 | Last of the draw. |
| **To atg_rx_scan** | | | |
| `sp_valid` | out | 1 | A set-up triangle. |
| `sp_ready` | in | 1 | Taken. |
| `sp_tri` | out | 768 | [287:0] 3 edges, 96 bits each = `{E[47:0], B[23:0], A[23:0]}`: A, B the edge coefficients in signed 15.8 fixed point, E the edge value at the pixel centre of the bbox origin, top-left bias included, in subpixel² units (a 32-bit C cannot hold an exact edge value; p007); [351:288] bbox {ymax, xmax, ymin, xmin} ∩ scissor (16 bits each); [447:352] z plane (A, B, C fp32); [543:448] 1/w plane; [735:544] b0/w and b1/w planes (perspective barycentrics, 2 × 3 fp32); [759:736] PT entries; [762:760] last-use flags; [763] front facing; [764] raw; [767:765] 0. |
| `sp_last` | out | 1 | Last of the draw. |
| `busy` | out | 1 | Work outstanding. |

14 ports.

## 4. Behaviour

Facing from the signed area and CULL[2] (front = CCW); culled triangles pass as empty (bbox empty) so their PT entries are freed.  DEPTH_CLAMP clamps z.  Raw triangles skip the divide and viewport.  Guard band: x/y within the 16.8 range (design §3.8).

## 5. State machine

A fixed pipeline (no FSM).

## 6. Latency and throughput

One triangle every few cycles (DSP-bound, design §3.6 RX 3.3k LUT, 15 DSP).

## 7. Corner cases and errors

- Zero-area triangles are empty.  w ≤ 0 cannot arrive (near clip).

## 8. What the TB checks

`sim/tb/atg_rx_setup_tb.v` prints, in this order:

- `PASS atg_rx_setup.edges` — edge coefficients against a C model
- `PASS atg_rx_setup.cull` — front/back/none
- `PASS atg_rx_setup.planes` — z and barycentric planes
- `PASS atg_rx_setup` at the end.

## 9. References

design §2.3 (RX STATE 0x050-0x05D), §3.8.

## 10. Status

2026-10-24 Q1 (from P3's p007 decisions, ACKed): the sp_tri edge layout above, the 15.8 fixed point with a ±16384 px guard band, and the speed of v1 (setup ≈ 150–900 cycles per triangle, below the design target) are what the RTL at amaterrace-gpu 8106fc3 does.

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
