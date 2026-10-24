# atg_rx_scan

RTL: `rtl/gpu/rx/atg_rx_scan.v`.  Parent: atg_rx.  Implemented in: p007 (direct), p009 (warps).

## 1. Purpose and place

RX quad traversal: walks the bounding box in 2×2 quads, evaluates the edges for coverage, and sends the covered quads of a non-raw triangle to `atg_rx_frag` (which packs them into fragment warps, HAS_SU) or the quads directly to the ROP (DRAW_RAW, or no SU); frees PT entries.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `HAS_SU` | `1` | 1: non-raw triangles' quads to atg_rx_frag (fragment warps); 0: every quad straight to the ROP with DEBUG_COLOR (bitstream 3). DRAW_RAW is direct either way. |

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
| **From atg_rx_setup** | | | |
| `sp_valid` | in | 1 | A set-up triangle. |
| `sp_ready` | out | 1 | Taken. |
| `sp_tri` | in | 768 | [287:0] 3 edges, 96 bits each = `{E[47:0], B[23:0], A[23:0]}`: A, B the edge coefficients in signed 15.8 fixed point, E the edge value at the pixel centre of the bbox origin, top-left bias included, in subpixel² units (a 32-bit C cannot hold an exact edge value; p007); [351:288] bbox {ymax, xmax, ymin, xmin} ∩ scissor (16 bits each); [447:352] z plane (A, B, C fp32); [543:448] 1/w plane; [735:544] b0/w and b1/w planes (perspective barycentrics, 2 × 3 fp32); [759:736] PT entries; [762:760] last-use flags; [763] front facing; [764] raw; [767:765] 0. |
| `sp_last` | in | 1 | Last of the draw. |
| **PT entries** | | | |
| `pt_free` | out | 1 | Free a PT entry. |
| `pt_free_idx` | out | 8 | Entry. |
| **Covered quads to atg_rx_frag (warp path)** | | | |
| `fq_valid` | out | 1 | A covered quad, or (fq_end) the triangle's end marker. |
| `fq_ready` | in | 1 | Taken. |
| `fq_xy` | out | 32 | {y, x} of the quad. |
| `fq_cov` | out | 4 | Covered lanes (0 with fq_end). |
| `fq_end` | out | 1 | The end marker: no more quads of this triangle. |
| `f_busy` | in | 1 | atg_rx_frag still has the triangle's quads (the frees wait). |
| **Direct fragments to the ROP (no SU: DEBUG_COLOR)** | | | |
| `dx_valid` | out | 1 | A quad. |
| `dx_ready` | in | 1 | Taken. |
| `dx_seq` | out | 16 | Sequence number. |
| `dx_xy` | out | 32 | {y, x} of the quad. |
| `dx_mask` | out | 4 | Covered lanes. |
| `dx_depth` | out | 128 | 4 × z (fp32). |
| `dx_last` | out | 1 | Last quad of the primitive's sequence number. |
| **Sequence numbers (atg_rx_order)** | | | |
| `sq_req` | out | 1 | A fragment warp (or direct quad group) needs a sequence number. |
| `sq_seq` | in | 16 | The number, in the same cycle. |
| `busy` | out | 1 | Work outstanding. |

27 ports.

## 4. Behaviour

- Warp path (HAS_SU and a non-raw triangle): every covered quad goes out on fq_* in the walk's
  order (one per handshake; the walk waits), then the end marker; no sequence number here
  (atg_rx_frag takes one per warp).  atg_rx_frag builds the warps (spec atg_rx_frag.md).
- Direct path (DRAW_RAW, or HAS_SU 0): per quad, dx_* with the interpolated z; one sequence number
  per triangle.
- After the triangle, pt_free for each flagged vertex; in the warp path only once f_busy is low (the
  last warp's copy of the varyings is done; a freed block may be taken by the next vertex warp).

## 5. State machine

IDLE →(triangle)→ SEQ → WALK → (direct: Z → EMIT → WALK …, LAST) or (warp path: FQ → WALK …, FQ with the end marker) → FREE (warp path: after !f_busy) → IDLE.

## 6. Latency and throughput

One quad per cycle in the walk (edges incremental).

## 7. Corner cases and errors

- Empty triangles: only FREE.  fl_gnt waits are where the deadlock rule of design §3.8 matters: the ROP always drains.

## 8. What the TB checks

`sim/tb/atg_rx_scan_tb.v` prints, in this order:

- `PASS atg_rx_scan.coverage` — coverage of random triangles against a C rasterizer (top-left rule)
- `PASS atg_rx_scan.direct` — HAS_SU 0: dx quads (and nothing on fq_*)
- `PASS atg_rx_scan.free` — pt_free once per flagged vertex
- `PASS atg_rx_scan` at the end.

## 9. References

design §3.4.3 (fragment inputs), §3.8, §3.1 (helper lanes).

## 10. Status

2026-10-24 Q1 (from P3's p007 decisions, ACKed): the sp_tri edge layout above, the 15.8 fixed point with a ±16384 px guard band, and the speed of v1 (setup ≈ 150–900 cycles per triangle, below the design target) are what the RTL at amaterrace-gpu 8106fc3 does.

Implemented: the direct path in p007, the warp path (fq_*) in p009 part B2.

WS288 p009 part B2 (P1, branch p1-su-gfx): the fragment-warp work moved to the new module `atg_rx_frag` (one module of ≤ 400 lines and one state machine could not hold both, spec/README.md); this module keeps the walk and sends the covered quads on the new ports `fq_*` (with `f_busy` back).  Removed ports: `pt_rd`, `pt_idx`, `pt_word`, `pt_rdata`, `pt_busy` and the `fl_*` (now atg_rx_frag's).  DRAW_RAW stays on the direct path also with an SU (it has no varyings; DEBUG_COLOR).  The warp path is tested by `atg_rx_frag_tb` and `atg_top_shade_tb` (the `warps` line of this TB is dropped).
