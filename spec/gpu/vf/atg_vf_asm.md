# atg_vf_asm

RTL: `rtl/gpu/vf/atg_vf_asm.v`.  Parent: atg_vf.  Implemented in: p009.

## 1. Purpose and place

VF warp and primitive assembly: packs vertices into 32-lane vertex warps (one SU slot and 32 PT entries each), starts the warps, and builds the primitive list (points, lines, strips, fans, triangles, restart) as PT entries for the RX, with last-use flags.

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
| **Index stream (atg_vf_index → atg_vf_asm)** | | | |
| `iv_valid` | in | 1 | A vertex. |
| `iv_ready` | out | 1 | Taken. |
| `iv_index` | in | 32 | Vertex index (index buffer value or FIRST + n), before VERTEX_OFFSET. |
| `iv_inst` | in | 32 | Instance number (FIRST_INSTANCE + i). |
| `iv_restart` | in | 1 | Primitive restart marker (no vertex). |
| `iv_last` | in | 1 | Last vertex of the last instance. |
| **Vertices of a warp (atg_vf_asm → atg_vf_fetch)** | | | |
| `vb_valid` | out | 1 | A vertex for lane vb_lane. |
| `vb_ready` | in | 1 | Taken. |
| `vb_index` | out | 32 | Index (+ VERTEX_OFFSET applied). |
| `vb_inst` | out | 32 | Instance. |
| `vb_lane` | out | 5 | Lane. |
| `vb_last` | out | 1 | Last vertex of the warp. |
| `conv_done` | in | 1 | atg_vf_conv wrote the warp's last attribute. |
| **Vertex warps to the SU (atg_su vl_*)** | | | |
| `vl_req` | out | 1 | Slot request (level). |
| `vl_gnt` | in | 1 | Grant pulse. |
| `vl_ptbase` | in | 8 | PT base of the granted warp (with vl_gnt). |
| `vl_go` | out | 1 | Start the warp. |
| `vl_mask` | out | 32 | Valid vertices of the warp. |
| **Primitives to the RX** | | | |
| `prim_valid` | out | 1 | A primitive (point, line or triangle). |
| `prim_ready` | in | 1 | Taken. |
| `prim_vtx` | out | 24 | Three PT entries, v0 in [7:0] (provoking vertex first per PROVOKING). |
| `prim_free` | out | 3 | Vertex i is used for the last time (RX frees its PT entry after this primitive). |
| `prim_last` | out | 1 | Last primitive of the draw (a draw with no primitive sends one with prim_vtx unused and the topology... see atg_vf_asm). |
| `busy` | out | 1 | Work outstanding. |

29 ports.

## 4. Behaviour

- For a strip or fan, the vertices that later primitives still need (the last two of a strip, the
  fan's first) are re-sent into the next warp (duplicated lanes) so a primitive never refers to two
  warps' PT blocks.  v1 has no reuse cache: every vertex of a list is shaded (design §3.8).
- vl_req when a warp's first vertex is ready; on vl_gnt send the warp's vertices on vb_*; on
  conv_done pulse vl_go with vl_mask; then the warp's primitives go out with PT entries
  vl_ptbase + lane.  prim_free marks each PT entry's last use.  prim_last after the draw's last.

## 5. State machine

IDLE → ALLOC (vl_req) → SEND (vb) → WAIT_CONV → GO → PRIMS (emit) → (next warp | IDLE).

## 6. Latency and throughput

One vertex per cycle into a warp; one primitive per cycle out.

## 7. Corner cases and errors

- Degenerate counts (a triangle list of 4 vertices) drop the incomplete primitive.  A draw with no primitive: prim_valid with prim_last only... v1: no prim at all, busy falls (the CP waits for VF idle).

## 8. What the TB checks

`sim/tb/atg_vf_asm_tb.v` prints, in this order:

- `PASS atg_vf_asm.list` — triangle lists over several warps
- `PASS atg_vf_asm.strip` — strips and fans across warp boundaries
- `PASS atg_vf_asm.restart` — restart in a strip
- `PASS atg_vf_asm.free` — every PT entry gets exactly one last use
- `PASS atg_vf_asm` at the end.

## 9. References

design §3.8 (PT reservation, deadlock), §2.3 (TOPOLOGY, PROVOKING in RX).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
