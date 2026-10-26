# atg_rx_clip

RTL: `rtl/gpu/rx/atg_rx_clip.v`.  Parent: atg_rx.  Children: atg_rx_cpoly (the polygon and the arithmetic; before CAPS[30] the fp units were here).  Implemented in: p007 (the near plane); this spec adds CAPS[30]'s clipping (§10).

## 1. Purpose and place

RX primitive input and clipping: reads the vertices' clip-space positions from the PT (or DRAW_RAW's screen-space vertices from STATE 0x1E0-0x1E8), clips points, lines and triangles against the w, near, far and guard-band planes, and passes the results to atg_rx_setup with weights relative to the original vertices.

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
| `st_wdata` | in | 32 | STATE value; the module keeps 16-entry VIEWPORT 0x050-0x053 array indexed by VIEWPORT_IDX 0x065, DEPTH_CLAMP 0x059, RAST_MODE 0x05A and DRAW_RAW's 0x1E0-0x1E8. |
| `raw_kick` | in | 1 | DRAW_RAW. |
| **Primitives to the RX** | | | |
| `prim_valid` | in | 1 | A primitive. |
| `prim_ready` | out | 1 | Taken. |
| `prim_vtx` | in | 26 | Three PT entries, v0 in [7:0] (provoking vertex first per PROVOKING); [25:24] the kind: 0 point (p, p, p), 1 line (a, b, b), 2 triangle. |
| `prim_free` | in | 3 | Vertex i is used for the last time (RX frees its PT entry after this primitive). |
| `prim_last` | in | 1 | Last primitive of the draw (a draw with no primitive sends none, atg_vf_asm §7). |
| **PT read (shared with atg_rx_frag in atg_rx: frag has priority)** | | | |
| `pt_rd` | out | 1 | Read one PT word. |
| `pt_idx` | out | 8 | Entry. |
| `pt_word` | out | 7 | Word (this module reads the position, 0-3). |
| `pt_rdata` | in | 32 | Data, next cycle. |
| `pt_busy` | in | 1 | atg_rx_frag is using the PT port: do not read. |
| **To atg_rx_setup** | | | |
| `cl_valid` | out | 1 | A primitive after clipping. |
| `cl_ready` | in | 1 | Taken. |
| `cl_tri` | out | 702 | [383:0] 3 × clip-space xyzw (fp32, v0 x in [31:0]); [671:384] 3 × 3 weights of the original vertices (fp32); [695:672] the original PT entries; [698:696] last-use flags; [699] raw (DRAW_RAW: screen space); [701:700] kind (0 point, 1 line, 2 triangle; raw: 2). |
| `cl_last` | out | 1 | Last of the draw. |
| `busy` | out | 1 | Work outstanding. |

21 ports (no change in number; prim_vtx and cl_tri are 2 bits wider).

## 4. Behaviour

- **Planes** (inside is distance ≥ 0, -0 included, NaN outside), in this order: (0) w ≥ 2^-16, always; (1) z ≥ 0 (near); (2) z ≤ w (far); (3-6) the guard band in x and y, |x_off·w + x_scale·x| ≤ 16383·w, the same in y.  Plane 1 applies with DEPTH_CLAMP[1] (DEPTH_CLIP) and without DEPTH_CLAMP[0], and always when DEPTH_CLAMP[1] = 0 (the earlier behaviour: the near plane only, r3 clamped later); plane 2 only with DEPTH_CLAMP[1] and without [0].
- **Trivial accept**: every vertex has w ≥ 2^-16, |x| ≤ 4w and |y| ≤ 4w while |x_off|, |y_off| ≤ 6144 and |x_scale|, |y_scale| ≤ 2048 (Vulkan's viewport limits of v1, maxViewportDimensions 4096 and viewportBoundsRange ±8192, give that; then 6144 + 4·2048 = 14336 ≤ 16383 and the vertex is inside the guard band), and is inside the applicable depth planes: the primitive passes unchanged (fp32 compares only, no arithmetic: the cycle count of a primitive that needs no clipping does not grow).  Otherwise the vertices go to atg_rx_cpoly and each applicable plane cuts in order (a plane that every vertex is inside leaves the polygon unchanged); planes 3-6 are cut only when some vertex fails the bound in x or y (a viewport beyond the bounds: always).  Points, depth and w are compared exactly (no flushing); the polygon's distances are atg_rx_cpoly's fp32.
- **Triangles**: the clipped polygon (up to 10 vertices) is emitted as a fan (v0, v_i, v_i+1), up to 8 triangles, kind 2.
- **Lines** (a, b, b): the segment a-b is cut (atg_rx_cpoly in line mode); one line (a', b', b'), kind 1, or nothing.
- **Points** (p, p, p): discarded when p is outside plane 0, 1 or 2 as they apply; otherwise passed unchanged, kind 0, the three vertices all p with p's weights (x and y are not clipped: atg_rx_setup cuts the square by the viewport's rectangle).  A line's third vertex is its second (weights included), clipped or not.
- **Nothing left, and RAST_MODE[6] (rasterizer discard)**: one empty triangle (kind 2, all positions (0, 0, 0, 1), weights 0) with the last-use flags, so the PT entries are freed; with DISCARD every primitive takes this path without reading the PT.
- **Last-use flags**: of all the primitives one input primitive becomes, only the last carries prim_free; the others carry 0.  cl_last is set on the last output of the draw's last primitive.
- **DRAW_RAW**: screen-space vertices, no clipping, kind 2, raw = 1 (as before).

## 5. State machine

IDLE →(prim; DISCARD: → OUT with the empty triangle)→ READ (4, 8 or 12 PT words by kind) → TRIV →(accept, or a point)→ OUT →(cl_ready)→ IDLE; TRIV →(not)→ LOAD (2 or 3 vertices into atg_rx_cpoly) → CMD ↔ CWAIT (one cmd per plane; nothing left: OUT with the empty triangle) → EMIT (read v0, v_i, v_i+1) → OUT →(more fan triangles)→ EMIT, or IDLE.  RAW: IDLE →(raw_kick)→ OUT → IDLE.

## 6. Latency and throughput

A primitive that needs no clipping: about 16 cycles (PT reads) as before.  One cut plane: about 100 more cycles (atg_rx_cpoly §6); each fan triangle one output handshake.

## 7. Corner cases and errors

- A fully clipped primitive passes its last-use flags in one empty triangle (§4).
- A line clipped to a point (both ends on the plane): passed; atg_rx_setup drops lines shorter than one subpixel.
- w ≥ 2^-16 is an absolute bound: clip coordinates scaled down uniformly (all |w| < 2^-16) are clipped away although Vulkan's result does not depend on the scale (recorded as a small departure, risk R36 of the design).
- prim_vtx's kind 3 reads as a triangle.

## 8. What the TB checks

`sim/tb/atg_rx_clip_tb.v` (vectors from `tools/rxmodel.py`; LINE_BYTES does not apply) prints, in this order:

- `PASS atg_rx_clip.pass` — unclipped triangles pass with identity weights
- `PASS atg_rx_clip.near` — one and two vertices behind the near plane (DEPTH_CLAMP[1] = 0: the earlier result bit for bit)
- `PASS atg_rx_clip.raw` — DRAW_RAW
- `PASS atg_rx_clip.ptbusy` — no PT read while pt_busy
- `PASS atg_rx_clip.line` — clipped lines come out as one line
- `PASS atg_rx_clip.point` — points inside and outside each depth plane
- `PASS atg_rx_clip.clampw` — DEPTH_CLAMP[0]: no near or far cut, the w plane still
- `PASS atg_rx_clip.wneg` — a vertex with z > 0 and w < 0 (a reversed-Z projection's vertex behind the camera) is clipped
- `PASS atg_rx_clip.guard` — large triangles leaving the guard band against the model's polygon
- `PASS atg_rx_clip.guardline` — lines leaving the guard band
- `PASS atg_rx_clip.lastuse` — the last-use flags only on the last output of each primitive
- `PASS atg_rx_clip.discard` — RAST_MODE[6]: empty triangles only
- `PASS atg_rx_clip` at the end.

Deliberate errors `MUT_FARCLIP` (no far plane) and `MUT_WCLIP` (no w plane) must make the TB fail.

## 9. References

design §3.8 (clip), §16.9; `spec/gpu/rx/atg_rx_cpoly.md`; docs/ghci.md §8.5 (RX range, clipping); §2.4.3 (DRAW_RAW).  Values referenced: Vulkan specification, Primitive Clipping, Depth Clamping and Range Adjustment.

## 10. Status

2026-10-24 Q1 (P3's p007 decision, ACKed): the near plane is Vulkan's z ≥ 0 (not the GL form z > -w); DEPTH_CLAMP is ignored and z is always clamped to [0, 1].

Implemented in p007: the near plane only, prim_vtx 24 and cl_tri 700 bits, the fp units inside this module (the PASS lines pass, near, raw, ptbusy).  2026-10-25: this spec describes the CAPS[30] form (planes 0-6, kinds, atg_rx_cpoly, DISCARD, the 2 bits of kind); implemented the same day, every PASS of §8 (`sim/vec/rx_clip.txt` unchanged, the new cases in `sim/vec/rx_clip2.txt` from `tools/rx-clip-vectors.py`, the model `clip2` in `tools/rxmodel.py`); `-DMUT_FARCLIP` and `-DMUT_WCLIP` fail it.  DEPTH_CLAMP[1] = 0's results are unchanged except where a vertex has w < 2^-16 or leaves the guard band (checked: 6000 random near-plane triangles with and without a 640 × 480 viewport give clip()'s result).  The trivial bound is 4w (with the viewport limits), not w as the first text said, so that a triangle partly off the screen needs no polygon work.

WS002 p007 (P2): Added 16-entry VIEWPORT array indexing via VIEWPORT_IDX (0x065), complete depth clamping bypass; verified with `sim/tb/atg_rx_ext_prim_tb.v`.
