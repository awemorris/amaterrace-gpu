# atg_rx_edge

RTL: `rtl/gpu/rx/atg_rx_edge.v` (new; the integer steps move here from atg_rx_setup).  Parent: atg_rx_setup.  Child: `atg_rx_f2fix` (the snap to 15.8).

## 1. Purpose and place

The integer part of triangle setup: snaps the window coordinates to 15.8 fixed point, builds the triangle that the scan converter walks (a triangle, one of a line's two sub-triangles, or one of a point's), its edges with the top-left rule, its bounding box ∩ scissor ∩ render target (∩ the viewport's rectangle), its facing and culling, and the integer deltas that the plane equations need, converted to fp32.  atg_rx_setup's micro-program starts it with its INT micro-op.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `start` | in | 1 | One cycle: run (atg_rx_setup's INT micro-op). |
| `mode` | in | 4 | [1:0] kind (0 point, 1 line, 2 triangle), [2] sub-triangle (0 first, 1 second; lines and points), [3] raw (DRAW_RAW: no viewport rectangle, no culling of raw by the rectangle). |
| `smin`, `smax`, `rts` | in | 32 | SCISSOR_MIN, SCISSOR_MAX, RT_SIZE ({y, x} 16 bits each), kept by atg_rx_setup. |
| `cull` | in | 3 | CULL [2:0]. |
| `vprect` | in | 1 | RAST_MODE[3]: cut by the viewport's rectangle. |
| `r_ra` | out | 7 | Read address into atg_rx_setup's fp registers. |
| `r_rd` | in | 32 | Its data, the next cycle. |
| `r_we` | out | 1 | Write one fp register. |
| `r_wa` | out | 7 | Its address. |
| `r_wd` | out | 32 | Its data. |
| `done` | out | 1 | One cycle: finished; the outputs below hold until the next start. |
| `edges` | out | 288 | 3 edges, 96 bits each = {E[47:0], B[23:0], A[23:0]} (atg_rx_setup's sp_tri layout). |
| `bbox` | out | 64 | {ymax, xmax, ymin, xmin}, 16 bits each, max exclusive. |
| `front` | out | 1 | Front facing (lines and points: 1). |
| `empty` | out | 1 | Nothing to walk (zero area, culled, empty bbox, a line shorter than a subpixel). |

19 ports.

## 4. Behaviour

Inputs read from the fp registers (atg_rx_setup's numbering, `spec/gpu/rx/atg_rx_setup.md` §4): the window x, y of vertices 0-2 (31, 32, 34, 35, 37, 38) and, with vprect, the viewport's rectangle (fp32 integers; registers listed in atg_rx_setup's spec).  Each is snapped: fp32 to 15.8 fixed point, round to nearest even, saturated to ±(2^22 - 1), NaN 0 (as before).

- **Triangle**: the three snapped vertices.
- **Line** (vertices 0 = a, 1 = b): the major axis is x when |Δx| ≥ |Δy| (x when equal), else y.  The parallelogram's corners are a⁻, a⁺, b⁻, b⁺: a ∓ (0, 128) for an x-major line, a ∓ (128, 0) for a y-major one (half a pixel in subpixels, exact), the same at b.  Sub-triangle 0 is (a⁻, b⁻, b⁺), sub-triangle 1 is (a⁻, b⁺, a⁺); the shared diagonal is covered by one of them only (the top-left rule).  A line with no extent along its major axis is empty.  The plane deltas (below) are those of (a, b, c) with c = a + one pixel along the minor axis.
- **Point** (vertex 0 = p): the square p ± (128, 128); sub-triangle 0 (p⁻⁻, p⁺⁻, p⁺⁺), sub-triangle 1 (p⁻⁻, p⁺⁺, p⁻⁺).
- **Edges**: D = dx1·dy2 - dx2·dy1 of the triangle walked; its winding orders the corners counter-clockwise for the scan converter; A, B per edge, E at the bbox origin's pixel centre with the top-left bias, as before (the same subpixel² units).
- **Facing and culling** (triangles only): front from the winding and CULL[2]; CULL[0] culls front, CULL[1] back faces.  Lines and points are front and never culled.
- **Bounding box**: the pixels of the whole primitive (a triangle's vertices; all four corners of a line or a point, for both sub-triangles, so that the planes at the box's origin are the same for both) ∩ scissor (when SCISSOR_MAX ≠ 0) ∩ [0, RT_SIZE) and, with vprect and not raw, ∩ the viewport's rectangle [x_off - |x_scale|, x_off + |x_scale|) × [y_off - |y_scale|, y_off + |y_scale|) (integers: the firmware rounds the viewport; viewportSubPixelBits is 0).
- **Deltas to the fp registers**: DX1, DY1, DX2, DY2 (in pixels), DF (= D in pixels²) and OX, OY (the bbox origin's pixel centre minus vertex 0, in pixels) into registers 40-46, of the triangle that defines the planes: the triangle itself, the line's (a, b, c), the point's (p, p + (1, 0), p + (0, 1)).

## 5. State machine

IDLE →(start)→ READ (the 6 coordinates and the 4 of the rectangle, always) → SNAP → CORNERS → D (two products) → EDGES → E (three products) → CONV (seven int-to-fp32 conversions, written to registers 40-46) → IDLE (done).

## 6. Latency and throughput

33 cycles per call (the integer steps of atg_rx_setup took 28; the rectangle's 4 reads and the corners add 5); a line or a point calls it twice.  One 25 × 25-bit multiplier.

## 7. Corner cases and errors

- Saturated coordinates (outside the guard band) cannot reach it for clipped primitives; DRAW_RAW's may, and keep the earlier saturating result.
- An empty result zeroes the edges and the bbox (the scan converter sees nothing to walk).

## 8. What the TB checks

`sim/tb/atg_rx_edge_tb.v` is not separate: atg_rx_setup's TB checks this module through its outputs (`PASS atg_rx_setup.edges`, `.cull`, `.line`, `.point`, `.viewport`).

## 9. References

`spec/gpu/rx/atg_rx_setup.md`, docs/ghci.md §8.5 (lines, points, the viewport's rectangle), design §16.9.  Values referenced: Vulkan specification, Basic Line Segment Rasterization (strictLines = false, the parallelogram), Basic Point Rasterization.

## 10. Status

Implemented 2026-10-25 (the integer steps moved here from atg_rx_setup, the same arithmetic; checked through atg_rx_setup's testbench, every PASS there).
