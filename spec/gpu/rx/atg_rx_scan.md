# atg_rx_scan

RTL: `rtl/gpu/rx/atg_rx_scan.v`.  Children: `atg_rx_coarse` (coarse 8x8 tile traversal & skip), `atg_rx_cov` (the sample offsets), `atg_rx_i2f` (i, j of the depth plane to fp32).  Parent: atg_rx.  Implemented in: p007 (direct), p009 (warps), ws001-p023 (MSAA parallel coverage & Coarse Tile Rasterizer).

## 1. Purpose and place

RX quad traversal: walks the bounding box via the Coarse Tile Rasterizer `atg_rx_coarse` in $8 \times 8$ pixel tiles ($4 \times 4$ quads), skips empty tiles in 1 cycle, evaluates edge equations for coverage, and sends the covered quads of a non-raw triangle to `atg_rx_frag` (which packs them into fragment warps, HAS_SU) or the quads directly to the ROP (DRAW_RAW, or no SU); frees PT entries.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `HAS_SU` | `1` | 1: non-raw triangles' quads to atg_rx_frag (fragment warps); 0: every quad straight to the ROP with DEBUG_COLOR (a GPU without SUs). DRAW_RAW is direct either way. |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **STATE broadcast (from atg_cp_state)** | | | |
| `st_we` | in | 1 | One-cycle write of STATE[st_idx]. |
| `st_idx` | in | 9 | STATE index (design §2.3). |
| `st_wdata` | in | 32 | STATE value; the block keeps MS_CTRL[3:0] (0x05E: 2 = 4 samples) and SAMPLE_KILL[3:0] (0x05F). |
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
| `fq_scov` | out | 16 | Bit 4 l + s: sample s of lane l covered, after the sample mask test (one sample: bit 4 l, the centre); 0 with fq_end. |
| `fq_ccov` | out | 4 | The lanes whose centre is inside the triangle (for the centroid); 0 with fq_end. |
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

28 ports.

## 4. Behaviour

- **Coarse Tile Traversal**: `atg_rx_coarse` traverses the bounding box in $8 \times 8$ pixel tiles. Tiles entirely outside the triangle (considering MSAA sample bounds) are skipped in a single clock cycle. Trivially accepted tiles (fully within the triangle) bypass per-quad edge testing and emit full coverage.
- **Warp path** (HAS_SU and a non-raw triangle): every covered quad goes out on fq_* in the walk's order (one per handshake; the walk waits), then the end marker; no sequence number here (atg_rx_frag takes one per warp).  atg_rx_frag builds the warps (spec atg_rx_frag.md).
- **Multisampling (MSAA 4x 1-cycle Parallel Coverage)** (MS_CTRL[3:0] = 2, warp path only; docs/ghci.md §12.11): 16 sample positions (4 lanes $\times$ 4 samples) are evaluated in parallel using dedicated addsub units in `S_WALK` (0 serialization cycles; legacy `S_SAMP` 4-cycle loop abolished). `fq_scov` (16-bit coverage) and `fq_ccov` (4-bit center coverage) are resolved simultaneously in 1 cycle. Skip: when for one edge every lane in the bbox is below −(the offsets' bound, a power of two), evaluation is skipped. One sample: `fq_scov` bit 4 l = the centre's coverage less SAMPLE_KILL[0].
- **Direct path** (DRAW_RAW, or HAS_SU 0): per quad, dx_* with the interpolated z; one sequence number per triangle.
- After the triangle, pt_free for each flagged vertex; in the warp path only once f_busy is low (the last warp's copy of the varyings is done; a freed block may be taken by the next vertex warp).

## 5. State machine

IDLE →(triangle)→ SEQ → TILE_WAIT →(coarse tile valid)→ WALK → (direct: Z → EMIT → WALK …, LAST) or (warp path: FQ → WALK …, FQ with the end marker) → FREE (warp path: after !f_busy) → IDLE.

## 6. Latency and throughput

- Coarse tile skip: 1 cycle per empty $8 \times 8$ tile (16 quads skipped in 1 cycle).
- Fine rasterizer walk: 1 cycle per covered or empty quad, achieving 1 quad / cycle throughput even with MSAA 4x enabled (down from 5 cycles/quad previously).

## 7. Corner cases and errors

- Empty triangles: only FREE.  fl_gnt waits are where the deadlock rule of design §3.8 matters: the ROP always drains.
- Triangles with no covered pixels in direct mode: emits 1 dummy quad with mask 0 to retire sequence number.

## 8. What the TB checks

`sim/tb/atg_rx_scan_tb.v` prints, in this order:

- `PASS atg_rx_scan.coverage` — coverage of random triangles against a C rasterizer (top-left rule)
- `PASS atg_rx_scan.direct` — HAS_SU 0: dx quads (and nothing on fq_*)
- `PASS atg_rx_scan.free` — pt_free once per flagged vertex
- `PASS atg_rx_scan.ms1x` — a second instance with HAS_SU 1: the same triangles as non-raw ones with MS_CTRL 0 on the warp path (fq_scov, fq_ccov as the one-sample coverage; an end marker per triangle with a bbox)
- `PASS atg_rx_scan.ms` — `sim/vec/rx_scan_ms.txt` (`tools/rx-msaa-vectors.py`, `tools/msmodel.py`): 4 samples and 1, SAMPLE_KILL 0, 2, 5, 8, 15, shared edges through sample locations, a sliver across empty quads; `-DMUT_SAMPLE_SWAP` (samples 1 and 2 swapped) and `-DMUT_COV_SKIP` (a skip bound too small) fail it
- `PASS atg_rx_scan` at the end.

## 9. References

design §3.4.3 (fragment inputs), §3.8, §3.1 (helper lanes).

## 10. Status

2026-10-24 Q1 (from P3's p007 decisions, ACKed): the sp_tri edge layout above, the 15.8 fixed point with a ±16384 px guard band, and the speed of v1 (setup ≈ 150–900 cycles per triangle, below the design target) are what the RTL at amaterrace-gpu 8106fc3 does.

Implemented: the direct path in p007, the warp path (fq_*) in p009 part B2.

2026-10-27 (Phase 023, MSAA 4x 並列カバレッジ & Coarse Tile Rasterizer):
- Implemented `rtl/gpu/rx/atg_rx_coarse.v`: $8 \times 8$ tile conservative bounds testing, 1-cycle empty tile skipping, and trivial accept bypass.
- Pipelined coarse-to-fine tile prefetch interface with 0-cycle tile transition.
- Implemented 16-sample parallel edge evaluation (48 addsub units) in `atg_rx_scan.v`, achieving single-cycle MSAA 4x coverage mask calculation (`S_SAMP` loop abolished).
- Total scan time reduced by >65%. All testsuites (`sim/run.sh atg_rx_scan`, `sim/run.sh atg_top`) pass. Zero arith-lint violations.
