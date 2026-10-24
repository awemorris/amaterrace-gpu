# atg_rx_cpoly

RTL: `rtl/gpu/rx/atg_rx_cpoly.v` (new).  Parent: atg_rx_clip.  Children: atg_rx_fadd, atg_rx_fmul, atg_rx_fdiv (moved here from atg_rx_clip).

## 1. Purpose and place

The clipping polygon of one primitive: a buffer of up to 10 vertices and the cut of the polygon (or of a line segment) by one clip plane at a time (Sutherland-Hodgman).  atg_rx_clip loads the vertices, chooses the planes and emits the result.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `vp` | in | 128 | VIEWPORT 0x050-0x053 (x scale, y scale, x offset, y offset; fp32), kept by atg_rx_clip. |
| `ld_we` | in | 1 | Load: write one vertex word (only while idle). |
| `ld_idx` | in | 4 | Vertex 0-9. |
| `ld_word` | in | 3 | Word: 0 x, 1 y, 2 z, 3 w (clip space), 4-6 the weights of the original vertices 0-2. |
| `ld_data` | in | 32 | fp32. |
| `ld_n` | in | 4 | The vertex count of the loaded polygon (3 for a triangle, 2 for a line), taken with cmd_valid of the first plane. |
| `ld_line` | in | 1 | A line segment: no closing edge; the result has at most 2 vertices. |
| `cmd_valid` | in | 1 | Cut by one plane. |
| `cmd_ready` | out | 1 | Taken (idle). |
| `cmd_plane` | in | 3 | 0 w ≥ 2^-16 (dist = w - 2^-16); 1 near (dist = z); 2 far (w - z); 3 x ≤ guard (G·w - (x_off·w + x_scale·x)); 4 x ≥ -guard (G·w + x_off·w + x_scale·x); 5, 6 the same in y; G = 16383. |
| `cmd_first` | in | 1 | This is the first plane after a load (ld_n applies). |
| `done` | out | 1 | One cycle: the cut is finished. |
| `n_out` | out | 4 | The polygon's vertex count now (0: nothing left). |
| `rd_idx` | in | 4 | Read vertex (while idle). |
| `rd_word` | in | 3 | Word, as ld_word. |
| `rd_data` | out | 32 | The word, the next cycle. |

18 ports.

## 4. Behaviour

For each vertex the plane's distance (fp32) is computed; inside is dist ≥ 0 (-0 and denormals inside, NaN outside).  The polygon is replaced by Sutherland-Hodgman's: for each edge (p, q) (for a line only the one edge), p inside → p; exactly one of p, q inside → the intersection p + (q - p)·t, t = dist_p / (dist_p - dist_q), every one of the 7 words interpolated (so the weights stay relative to the original vertices).  When every vertex is inside the polygon is unchanged and done comes after the distances; when every vertex is outside n_out = 0.  A triangle grows by at most one vertex per plane: 3 + 7 = 10.  The arithmetic is the RX's fp32 (atg_rx_fadd, atg_rx_fmul, atg_rx_fdiv: round to nearest even, denormals flushed; tools/rxmodel.py is the reference).

## 5. State machine

IDLE →(cmd)→ DIST (one distance per vertex) → CUT (per edge: in/out, intersections) → IDLE (done).  The new polygon goes to the other half of a two-polygon buffer, so a cut reads one half and writes the other.

## 6. Latency and throughput

Distances: 1 fadd (planes 0, 2), none (1) or 3 fmul and 2 fadd (3-6) per vertex; an intersection: 1 fadd, 1 fdiv, then 7 × (fadd, fmul, fadd).  A triangle that needs one cut takes about 100 cycles; one that needs none never comes here (atg_rx_clip's trivial accept).

## 7. Corner cases and errors

- A plane with every distance NaN: everything is outside (n_out = 0).
- A line whose one vertex is on the plane (dist = 0) stays inside.
- cmd while not idle is not taken (cmd_ready = 0).

## 8. What the TB checks

`sim/tb/atg_rx_cpoly_tb.v` (vectors from `tools/rxmodel.py`) prints, in this order:

- `PASS atg_rx_cpoly.planes` — each plane alone on random triangles against the model's polygon (vertex by vertex, word by word)
- `PASS atg_rx_cpoly.seq` — the seven planes in order on triangles that cross several (up to 10 vertices)
- `PASS atg_rx_cpoly.line` — line segments: one vertex out, both out, both in
- `PASS atg_rx_cpoly` at the end.

## 9. References

`spec/gpu/rx/atg_rx_clip.md`, docs/ghci.md §8.5 (clipping), design §16.9.  Values referenced: Vulkan specification, Primitive Clipping (the clip volume z_m ≤ z_c ≤ w_c).

## 10. Status

Spec only (2026-10-25); no RTL yet.
