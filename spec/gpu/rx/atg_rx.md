# atg_rx

RTL: `rtl/gpu/rx/atg_rx.v`.  Parent: atg_top (HAS_RX).  Implemented in: p007, p009.

## 1. Purpose and place

The rasterizer (design §3.8): clip, setup, quad scan into fragment warps (or direct quads), sequence numbers for the ROP order.

Children: `atg_rx_clip` (with `atg_rx_cpoly`), `atg_rx_setup`, `atg_rx_scan`, `atg_rx_frag`, `atg_rx_order`.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `HAS_SU` | `1` | Fragment warps to an SU (0: DEBUG_COLOR quads to the ROP). |

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
| `busy` | out | 1 | STATUS.RX_BUSY. |
| **Primitives to the RX** | | | |
| `prim_valid` | in | 1 | A primitive (point, line or triangle). |
| `prim_ready` | out | 1 | Taken. |
| `prim_vtx` | in | 24 | Three PT entries, v0 in [7:0] (provoking vertex first per PROVOKING). |
| `prim_free` | in | 3 | Vertex i is used for the last time (RX frees its PT entry after this primitive). |
| `prim_last` | in | 1 | Last primitive of the draw (a draw with no primitive sends none, atg_vf_asm §7). |
| **PT of SU 0 (atg_su pt_*)** | | | |
| `pt_rd` | out | 1 | Read. |
| `pt_idx` | out | 8 | Entry. |
| `pt_word` | out | 7 | Word (0-3 position, 4 + w varying word w). |
| `pt_rdata` | in | 32 | Data. |
| `pt_free` | out | 1 | Free. |
| `pt_free_idx` | out | 8 | Entry. |
| **Fragment warps to the SU (atg_su fl_*)** | | | |
| `fl_req` | out | 1 | Slot request. |
| `fl_gnt` | in | 1 | Grant. |
| `fl_we` | out | 1 | Register word (r0..r5: b0, b1, b2, z, x, y). |
| `fl_reg` | out | 6 | Register. |
| `fl_lane` | out | 5 | Lane. |
| `fl_data` | out | 32 | Data. |
| `fl_pw_we` | out | 1 | Primitive table word (the 3 vertices' varyings). |
| `fl_pw_addr` | out | 12 | {primitive, vertex, varying word} (atg_rx_frag §3). |
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
| **Sequence numbers to the ROP** | | | |
| `ord_valid` | out | 1 | Issued. |
| `ord_seq` | out | 16 | Number. |

39 ports.

## 4. Behaviour

Wiring, plus the three-line PT read mux (atg_rx_frag first; the clip obeys pt_busy) and the OR of the two sequence-number requests (atg_rx_scan's direct quads, atg_rx_frag's warps; never in the same cycle).

## 5. State machine

None (wiring).

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_rx_ext_prim_tb.v` tests extended primitives across the RX pipeline:
- Wide Lines: line width scaling (1.0 to 16.0) via `GHCI_S_LINE_WIDTH` (0x063).
- Point Sprites: quad expansion and auto PointCoord generation via `GHCI_S_POINT_SIZE` (0x064).
- Multi-Viewport & Scissors: 16-entry array indexing via `GHCI_S_VIEWPORT_IDX` (0x065).
- Complete Depth Clamping: near/far plane bypass with `DEPTH_CLAMP[0]` and [0, 1] fragment depth clamping.

## 9. References

design §3.8, §2.3.

## 10. Status

Wiring written in WS288 p023 (children are stubs unless their spec says otherwise).

WS288 p009 part B2 (P1): the new child `atg_rx_frag` (fragment warps), its PT reads in the mux, `busy` includes it.  Ports unchanged.

WS002 p007 (P2): Extended primitives (Wide Lines, Point Sprites, Multi-Viewport & Scissors 16-entry arrays, Depth Clamping) implemented and verified in `sim/tb/atg_rx_ext_prim_tb.v`.
