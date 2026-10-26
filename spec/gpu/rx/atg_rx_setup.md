# atg_rx_setup

RTL: `rtl/gpu/rx/atg_rx_setup.v`.  Parent: atg_rx.  Implemented in: p007.

## 1. Purpose and place

RX setup: perspective divide and viewport (VIEWPORT 0-5), the integer steps through its child atg_rx_edge (snap, edges, bounding box ∩ scissor ∩ render target ∩ the viewport's rectangle, facing and culling), the plane equations of depth, 1/w and the perspective barycentrics, depth bias, and the two sub-triangles of a line or a point.  Child: atg_rx_edge (new with CAPS[30]; before it the integer steps were inside this module).

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
| `st_wdata` | in | 32 | STATE value; the module keeps VIEWPORT 0x050-0x055, SCISSOR 0x056-0x057, CULL 0x058, RAST_MODE 0x05A, DEPTH_BIAS_CONST, _SLOPE, _CLAMP 0x060-0x062 and RT_SIZE 0x073. |
| **From atg_rx_clip** | | | |
| `cl_valid` | in | 1 | A primitive (after clipping). |
| `cl_ready` | out | 1 | Taken. |
| `cl_tri` | in | 702 | [383:0] 3 × clip-space xyzw (fp32, v0 x in [31:0]); [671:384] 3 × 3 weights of the original vertices (fp32); [695:672] the original PT entries; [698:696] last-use flags; [699] raw (DRAW_RAW: screen space); [701:700] kind (0 point, 1 line, 2 triangle). |
| `cl_last` | in | 1 | Last of the draw. |
| **To atg_rx_scan** | | | |
| `sp_valid` | out | 1 | A set-up triangle. |
| `sp_ready` | in | 1 | Taken. |
| `sp_tri` | out | 768 | [287:0] 3 edges, 96 bits each = `{E[47:0], B[23:0], A[23:0]}`: A, B the edge coefficients in signed 15.8 fixed point, E the edge value at the pixel centre of the bbox origin, top-left bias included, in subpixel² units (a 32-bit C cannot hold an exact edge value; p007); [351:288] bbox {ymax, xmax, ymin, xmin} (16 bits each); [447:352] z plane (A, B, C fp32, depth bias included); [543:448] 1/w plane; [735:544] b0/w and b1/w planes (perspective barycentrics, 2 × 3 fp32; a point's PointCoord s and t); [759:736] PT entries; [762:760] last-use flags; [763] front facing; [764] raw; [766:765] kind (0 point, 1 line, 2 triangle); [767] 0. |
| `sp_last` | out | 1 | Last of the draw. |
| `busy` | out | 1 | Work outstanding. |

14 ports.

## 4. Behaviour

Stream Setup Engine (Phase 022): The legacy micro-program (`include/atg_rx_setup_uc.vh`) has been replaced by a direct hardware sequencer FSM with dedicated pipelined arithmetic stages (fadd, fmul, fdiv) and direct control of the integer step child `atg_rx_edge`.

- **Direct Hardware Sequencing**: Eliminates instruction fetch/decode overhead and sequentially computes perspective divide, viewport mapping, edge setup, plane equations, and depth bias.
- **Single-Cycle Parallel Register Loading**: All clip-space vertices, viewport scales/offsets, and state values are latched in a single clock cycle upon primitive acceptance (`cl_valid && cl_ready`), removing the 28-cycle sequential loading delay.
- **Zero-Delay Culled Triangle Drop**: If `atg_rx_edge` reports `e_empty == 1` (culled, zero-area, or clipped outside viewport/scissor), non-culled work is immediately aborted and the triangle is retired without calculating plane equations or depth bias, returning immediately to accept the next primitive.
- **Triangle** (as before): divide, viewport, INT (`atg_rx_edge`), the planes z, 1/w, b0/w, b1/w from the deltas.  **Depth bias** (RAST_MODE[0], and [5:4] ≠ 0): m = max(|A_z|, |B_z|), r = 2^-16 (RAST_MODE[5:4] = 1, D16), 2^-24 (2, D24) or 2^(e - 23) (3, D32_SFLOAT, e the largest exponent of the three window depths), o = m·DEPTH_BIAS_SLOPE + r·DEPTH_BIAS_CONST, then with DEPTH_BIAS_CLAMP c: c > 0 min(o, c), c < 0 max(o, c), c = 0 o; o is added to the z plane's C (FragCoord.z is biased).
- **Line** (strictLines = false, width 1): divide and viewport of a and b; INT with sub-triangle 0 and then 1 (atg_rx_edge §4: the parallelogram); the planes from (a, b, c), c = a + one pixel along the minor axis with a's attributes, so they vary along the major axis only (b0 = vertex 0's weight, b1 = vertex 1's, b2 ≈ 0).  Never culled, front.  Two outputs on sp_*, the same planes; the last-use flags and sp_last on the second only.
- **Point** (size 1): divide and viewport of p; the square in two sub-triangles; z plane (0, 0, z_p), 1/w plane (0, 0, 1), b0/w plane = PointCoord s: (1, 0, ½ + OX), b1/w = t: (0, 1, ½ + OY) with OX, OY the bbox origin's pixel centre minus p (so atg_rx_frag's r0 and r1 are PointCoord and r = 1); never culled, front; two outputs as for a line.
- **Viewport's rectangle** (RAST_MODE[3], not raw): calculated directly as x_off - |x_scale|, x_off + |x_scale|, y_off - |y_scale|, y_off + |y_scale| before calling `atg_rx_edge`.

## 5. State machine

IDLE →(cl_valid, 1-cycle parallel load)→ S_VP_RECT (if RAST_MODE[3]) → S_DIV → S_VP → S_EDGE (runs `atg_rx_edge`) →
If culled (`e_empty`): immediately → S_OUT (or IDLE) to drop or emit empty marker.
Otherwise: → S_PL_PREP → S_PLANE (sequencing Z, 1/W, B0, B1 planes via S_PL_Dxy, S_PL_MUL, S_PL_DET, S_PL_COEF) → S_BIAS (if depth bias enabled) → S_OUT →(sp_ready)→ IDLE (or loop back to S_EDGE for sub-triangle 1 in line/point).

## 6. Latency and throughput

- Culled/empty primitives: dropped in ~30–45 cycles (zero-delay kill after edge check, bypassing all plane equations and depth bias).
- Active triangles: ~80–120 cycles (down from legacy microcode's ~150–900 cycles), achieving bit-for-bit identical results with significant throughput increase.

## 7. Corner cases and errors

- Zero-area triangles, culled triangles and lines shorter than a subpixel pass as empty (bbox empty) so their PT entries are freed.
- w below 2^-16 cannot arrive (atg_rx_clip's w plane).
- A line or point with a DRAW_RAW origin cannot happen (DRAW_RAW is a triangle).

## 8. What the TB checks

`sim/tb/atg_rx_setup_tb.v` prints, in this order:

- `PASS atg_rx_setup.edges` — edge coefficients against the model
- `PASS atg_rx_setup.cull` — front/back/none
- `PASS atg_rx_setup.planes` — z and barycentric planes
- `PASS atg_rx_setup.line` — the parallelogram's edges and planes, x- and y-major and equal
- `PASS atg_rx_setup.point` — the square and the PointCoord planes
- `PASS atg_rx_setup.viewport` — the viewport's rectangle against a viewport smaller than the scissor
- `PASS atg_rx_setup.bias` — the four bias formats and both signs of the clamp
- `PASS vecdiff.rx_setup` — the triangles of the earlier vectors (`sim/vec/rx_setup.txt`) give the same sp_tri, all 768 bits with the kind 2 in [766:765] (checked in the testbench; the new cases are `sim/vec/rx_setup2.txt` from `tools/rx-setup-vectors.py`)
- `PASS atg_rx_setup` at the end.

Deliberate errors `MUT_LINE_MAJOR` (y-major when equal) and `MUT_BIAS_R` (r = 2^-23 for D24) must make the TB fail.

## 9. References

design §2.3 (RX STATE 0x050-0x05D), §3.8, §16.9; `spec/gpu/rx/atg_rx_edge.md`; docs/ghci.md §8.5.  Values referenced: Vulkan specification, Depth Bias Computation, Basic Line Segment Rasterization, Basic Point Rasterization.

## 10. Status

2026-10-24 Q1 (from P3's p007 decisions, ACKed): the sp_tri edge layout above, the 15.8 fixed point with a ±16384 px guard band, and the speed of v1 (setup ≈ 150–900 cycles per triangle, below the design target) are what the RTL at amaterrace-gpu 8106fc3 does.

Implemented in p007 (triangles; cl_tri 700 bits, the integer steps inside).  2026-10-25: this spec describes the CAPS[30] form (lines, points, the viewport's rectangle, depth bias, atg_rx_edge, the kind bits); implemented the same day, every PASS of §8 (the model `setup2` in `tools/rxmodel.py`; `-DMUT_LINE_MAJOR` fails `.line`, `-DMUT_BIAS_R` fails `.bias`).  A triangle's sp_tri is unchanged bit for bit when RAST_MODE is 0 (the 160 earlier cases); the setup takes about 25 cycles more per triangle (the rectangle's registers and the branches).  sp_last is now a wire (the last output only).

2026-10-27 (Phase 022, Stream Setup Engine): Microcode FSM and `include/atg_rx_setup_uc.vh` dependency completely abolished. Implemented fully pipelined direct hardware sequencer with 1-cycle parallel register loading, zero-delay culled triangle kill, and bit-for-bit identical 768-bit primitive generation passing all vector tests in `rx_setup.txt` and `rx_setup2.txt`. Zero arithmetic lint violations.
