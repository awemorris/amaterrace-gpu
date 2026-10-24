# atg_rx_clip

RTL: `rtl/gpu/rx/atg_rx_clip.v`.  Parent: atg_rx.  Implemented in: p007.

## 1. Purpose and place

RX primitive input and near-plane clipping: reads the three vertices' clip-space positions from the PT (or DRAW_RAW's screen-space vertices from STATE 0x1E0-0x1E8), clips against the near plane (one triangle → 0, 1 or 2), and passes triangles with weights relative to the original vertices.

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
| `raw_kick` | in | 1 | DRAW_RAW. |
| **Primitives to the RX** | | | |
| `prim_valid` | in | 1 | A primitive (point, line or triangle). |
| `prim_ready` | out | 1 | Taken. |
| `prim_vtx` | in | 24 | Three PT entries, v0 in [7:0] (provoking vertex first per PROVOKING). |
| `prim_free` | in | 3 | Vertex i is used for the last time (RX frees its PT entry after this primitive). |
| `prim_last` | in | 1 | Last primitive of the draw (a draw with no primitive sends none, atg_vf_asm §7). |
| **PT read (shared with atg_rx_scan in atg_rx: scan has priority)** | | | |
| `pt_rd` | out | 1 | Read one PT word. |
| `pt_idx` | out | 8 | Entry. |
| `pt_word` | out | 6 | Word. |
| `pt_rdata` | in | 32 | Data, next cycle. |
| `pt_busy` | in | 1 | atg_rx_scan is using the PT port: do not read. |
| **Triangles to atg_rx_setup** | | | |
| `cl_valid` | out | 1 | A triangle (after clipping). |
| `cl_ready` | in | 1 | Taken. |
| `cl_tri` | out | 700 | [383:0] 3 × clip-space xyzw (fp32, v0 x in [31:0]); [671:384] 3 × 3 weights of the original vertices (fp32); [695:672] the original PT entries; [698:696] last-use flags; [699] raw (DRAW_RAW: screen space). |
| `cl_last` | out | 1 | Last of the draw. |
| `busy` | out | 1 | Work outstanding. |

21 ports.

## 4. Behaviour

Points and lines are expanded to two triangles (v1: points as 1×1 quads... points/lines with v1 limits in the spec of setup).  Near plane z > -w (Vulkan z ≥ 0 after the divide): vertices outside are replaced by the edge intersections; the weights express each new vertex as a combination of the three originals (design §3.8: barycentrics stay relative to the original vertices).

## 5. State machine

IDLE →(prim)→ READ (12 PT words) → CLIP → EMIT (0-2) → IDLE; RAW: IDLE →(raw_kick)→ EMIT → IDLE.

## 6. Latency and throughput

About 16 cycles per primitive (PT reads dominate).

## 7. Corner cases and errors

- A fully clipped primitive still passes its last-use flags (an empty cl with... v1: a zero-area triangle with the flags, so scan frees the entries).

## 8. What the TB checks

`sim/tb/atg_rx_clip_tb.v` prints, in this order:

- `PASS atg_rx_clip.pass` — unclipped triangles pass with identity weights
- `PASS atg_rx_clip.near` — one and two vertices behind the near plane
- `PASS atg_rx_clip.raw` — DRAW_RAW
- `PASS atg_rx_clip.ptbusy` — no PT read while pt_busy
- `PASS atg_rx_clip` at the end.

## 9. References

design §3.8 (clip), §2.3 (RX STATE), §2.4.3 (DRAW_RAW).

## 10. Status

2026-10-24 Q1 (P3's p007 decision, ACKed): the near plane is Vulkan's z ≥ 0 (not the GL form z > −w); DEPTH_CLAMP is ignored and z is always clamped to [0, 1].

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
