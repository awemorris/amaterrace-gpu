# atg_rx_scan

RTL: `rtl/gpu/rx/atg_rx_scan.v`.  Parent: atg_rx.  Implemented in: p007 (direct), p009 (warps).

## 1. Purpose and place

RX quad traversal: walks the bounding box in 2×2 quads, evaluates the edges for coverage, packs up to 8 quads of one triangle into a 32-lane fragment warp (or sends quads directly to the ROP without an SU), copies the vertices' varyings into the SU's primitive table, frees PT entries.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `HAS_SU` | `1` | 1: fragment warps to the SU; 0: quads straight to the ROP with DEBUG_COLOR (bitstream 3). |

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
| `sp_tri` | in | 768 | [287:0] 3 edges × (A, B, C) signed 16.8 fixed point; [351:288] bbox {ymax, xmax, ymin, xmin} ∩ scissor (16 bits each); [447:352] z plane (A, B, C fp32); [543:448] 1/w plane; [735:544] b0/w and b1/w planes (perspective barycentrics, 2 × 3 fp32); [759:736] PT entries; [762:760] last-use flags; [763] front facing; [764] raw; [767:765] 0. |
| `sp_last` | in | 1 | Last of the draw. |
| **PT read (shared with atg_rx_scan in atg_rx: scan has priority)** | | | |
| `pt_rd` | out | 1 | Read one PT word. |
| `pt_idx` | out | 8 | Entry. |
| `pt_word` | out | 6 | Word. |
| `pt_rdata` | in | 32 | Data, next cycle. |
| `pt_busy` | out | 1 | Using the PT port (atg_rx_clip waits). |
| `pt_free` | out | 1 | Free a PT entry. |
| `pt_free_idx` | out | 8 | Entry. |
| **Fragment warps to the SU (atg_su fl_*)** | | | |
| `fl_req` | out | 1 | Slot request. |
| `fl_gnt` | in | 1 | Grant. |
| `fl_we` | out | 1 | Register word (r0..r5: b0, b1, b2, z, x, y). |
| `fl_reg` | out | 6 | Register. |
| `fl_lane` | out | 5 | Lane. |
| `fl_data` | out | 32 | Data. |
| `fl_pw_we` | out | 1 | Primitive table word (the 3 vertices' varyings). |
| `fl_pw_addr` | out | 12 | {primitive, vertex, word}. |
| `fl_pw_data` | out | 32 | Data. |
| `fl_go` | out | 1 | Start the warp. |
| `fl_mask` | out | 32 | EXEC (whole quads). |
| `fl_info` | out | 64 | [31:0] coverage, [47:32] sequence, [48] front, [63:49] 0. |
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

38 ports.

## 4. Behaviour

- Per warp (HAS_SU): fl_req → fl_gnt → copy 3 vertices × VARYING_COUNT words PT → primitive table
  (pt_rd + fl_pw), write r0-r5 per covered quad lane (b0, b1, b2 from the planes, z, x, y) →
  fl_go with mask (quads) and info (coverage, sq_seq, front).  Helper lanes: whole quads (design §3.1).
- Without SU: per quad, dx_* with the interpolated z; one sequence number per triangle.
- After the triangle's last warp, pt_free for each flagged vertex.

## 5. State machine

IDLE → (per triangle) WALK → (warp full or triangle done) ALLOC → COPY → WRITE → GO → WALK … → FREE → IDLE.

## 6. Latency and throughput

One quad per cycle in the walk (edges incremental).

## 7. Corner cases and errors

- Empty triangles: only FREE.  fl_gnt waits are where the deadlock rule of design §3.8 matters: the ROP always drains.

## 8. What the TB checks

`sim/tb/atg_rx_scan_tb.v` prints, in this order:

- `PASS atg_rx_scan.coverage` — coverage of random triangles against a C rasterizer (top-left rule)
- `PASS atg_rx_scan.warps` — quads per warp, register writes, primitive table copy
- `PASS atg_rx_scan.direct` — HAS_SU 0: dx quads
- `PASS atg_rx_scan.free` — pt_free once per flagged vertex
- `PASS atg_rx_scan` at the end.

## 9. References

design §3.4.3 (fragment inputs), §3.8, §3.1 (helper lanes).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
