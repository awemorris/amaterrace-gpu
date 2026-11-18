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
| `prim_vtx` | out | 26 | Three PT entries, v0 in [7:0] (provoking vertex first per PROVOKING); [25:24] the kind: 0 point, 1 line, 2 triangle (CAPS[30]; the RX no longer reads TOPOLOGY). |
| `prim_free` | out | 3 | Vertex i is used for the last time (RX frees its PT entry after this primitive). |
| `prim_last` | out | 1 | Last primitive of the draw (a draw with no primitive sends none, atg_vf_asm §7). |
| `busy` | out | 1 | Work outstanding. |

29 ports.

## 4. Behaviour

- One warp at a time: vl_req when the next vertex (not a restart marker) waits on iv; on vl_gnt the warp's vertices go out on vb_*, lanes 0, 1, … in order (every iv vertex gets its own lane: v1 has no reuse cache, design §3.8).  vb_index = iv_index + VERTEX_OFFSET for an indexed draw (INDEX_FORMAT ≠ 0); a non-indexed draw adds nothing (Vulkan: vertexOffset belongs to indexed draws).  The newest vertex is held back one item so that vb_last is known when it goes out.
- A warp closes when its 32 lanes are used, before a list primitive (line or triangle list) that no longer fits in the lanes left, or at the draw's last item.  For a strip or fan, the vertices that later primitives still need (the last two of a strip, the fan's first and last; the started vertices of a list primitive or a line strip's last) are re-sent into the next warp's lanes 0 and 1 (duplicated lanes) so a primitive never refers to two warps' PT blocks.
- Primitive restart (iv_restart) and a change of iv_inst (the next instance) end the strip, fan or incomplete list primitive.  TOPOLOGY 6 and 7 (reserved) assemble as points.
- On conv_done, vl_go pulses with vl_mask = the lanes that some primitive of the warp uses (unused lanes: an incomplete primitive, a strip piece of one or two vertices, a carried vertex not used again); then the warp's primitives go out, one per cycle, with PT entries vl_ptbase + lane.
- prim_vtx: v0 is the provoking vertex (PROVOKING, RX STATE 0x05D: [0] 0 first, 1 last), the winding of Vulkan's vertex order kept by rotation.  Triangle list (A, B, V) / last (V, A, B); strip triangle i (Vulkan's orders): first (i, i+1+i%2, i+2−i%2), last (i+2, i+i%2, i+1−i%2); fan (i+1, i+2, 0) / last (i+2, 0, i+1); line (a, b, b) / last (b, a, a); point (p, p, p).  prim_vtx[25:24] gives the kind (0 point lists, 1 the line topologies, 2 the triangle topologies), so a later draw's TOPOLOGY cannot change how the RX reads an earlier primitive (before CAPS[30] the RX read TOPOLOGY).
- prim_free bit s marks the last use of slot s's PT entry within its warp, set on one slot only when an entry appears twice (points, lines): every entry of a lane in vl_mask gets exactly one last use; the entries of the lanes outside vl_mask are never named on prim_*.
- prim_last after the draw's last primitive: the last primitive out is held back (prim_valid low) until the next one exists or the draw ends.

## 5. State machine

IDLE →(iv)→ NEXT (restart markers and instance changes between warps) →(vertex)→ ALLOC (vl_req) →(vl_gnt)→ SEND (vb: carried vertices, then iv) → CLOSE (vb_last) → WAIT (conv_done) → GO (vl_go) → PRIMS (emit) →(list empty)→ NEXT, or IDLE after the draw's last primitive (NEXT →(restart with iv_last)→ PRIMS when the draw ends between warps).

## 6. Latency and throughput

One vertex per cycle into a warp; one primitive per cycle out.  The next warp's SEND does not overlap the current warp's PRIMS (v1).

## 7. Corner cases and errors

- Degenerate counts (a triangle list of 4 vertices) drop the incomplete primitive.  A draw with no primitive sends none (no prim_last either) and busy falls (the CP waits for VF idle).
- A warp none of whose lanes a primitive uses (e.g. only restart-separated pairs of a strip) still gets vl_go, with vl_mask 0.
- **Needs from the SU (part B, Q1):** the PT allocator returns, at vl_go, the entries of the warp's lanes outside vl_mask (no primitive names them), and it allocates per 32-entry block, not as one counter: because the last primitive is held for prim_last, up to three entries of an older warp can still be taken when the next-but-one warp is granted.

## 8. What the TB checks

`sim/tb/atg_vf_asm_tb.v` prints, in this order:

- `PASS atg_vf_asm.list` — triangle, line and point lists over several warps
- `PASS atg_vf_asm.strip` — strips, fans and line strips across warp boundaries
- `PASS atg_vf_asm.restart` — restart in strips, fans and lists; instances
- `PASS atg_vf_asm.free` — every PT entry gets exactly one last use (a 64-entry PT model in two blocks, the lanes outside vl_mask returned at vl_go; mixed topologies)
- `PASS atg_vf_asm.kind` — prim_vtx[25:24] for every topology (CAPS[30])
- `PASS atg_vf_asm` at the end.

The primitives are checked in order against a reference assembly without warps (Vulkan's vertex orders, both PROVOKING modes); also the vb lanes, vb_last, VERTEX_OFFSET and vb_inst.

## 9. References

design §3.8 (PT reservation, deadlock), §2.3 (TOPOLOGY, PROVOKING in RX).

## 10. Status

Implemented in WS288 p009 part A (branch p1-vf).  Readings of the earlier text (Q1 to confirm): "a draw with no primitive" sends none (§7); vl_mask has only the lanes some primitive uses, and the SU returns the other entries (§7, a need for part B); points and lines as (p, p, p) and (a, b, b) with the free bit on one slot; VERTEX_OFFSET only for indexed draws; a change of instance ends strips and fans; the last primitive is held back for prim_last.  Ports and parameters unchanged.  2026-10-25: prim_vtx gains the kind in [25:24] (CAPS[30], spec first; the RTL follows with the RX's line and point support; at 393 lines, if it passes 400 the primitive output moves into a child).  Implemented the same day: the kind comes from TOPOLOGY at the output (its SET_REG waits while the VF is busy), 396 lines; `PASS atg_vf_asm.kind` checks every primitive of all eight topologies.
