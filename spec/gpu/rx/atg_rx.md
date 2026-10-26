# atg_rx

RTL: `rtl/gpu/rx/atg_rx.v`.  Parent: atg_top (HAS_RX).

## 1. Purpose and place

The rasterizer (design §3.8): clip, setup, quad scan into fragment warps (or direct quads), sequence numbers for the ROP order.
Integrates a 6-stage stream pipeline with skid buffers (`am_skid`) for high-throughput (up to 1 quad/cycle) and timing closure.

Children:
- `atg_rx_clip` (with `atg_rx_cpoly`): Stage 0 (Prune & Cull)
- `atg_rx_setup`: Stage 1 (Stream Setup)
- `atg_rx_scan` (with `atg_rx_coarse`): Stage 2 (Coarse Raster) & Stage 3 (Fine Raster / MSAA 4x)
- `atg_rx_frag` (with `atg_rx_bary`): Stage 4 (Fast DDA Interpolator) & Stage 5 (Warp Pack & Fire)
- `atg_rx_order`: ROP sequence ordering

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
| `fsm` | out | 4 | {frag_busy, scan_busy, setup_busy, clip_busy}. |
| **Primitives to the RX** | | | |
| `prim_valid` | in | 1 | A primitive (point, line or triangle). |
| `prim_ready` | out | 1 | Taken. |
| `prim_vtx` | in | 26 | Three PT entries, v0 in [7:0] (provoking vertex first per PROVOKING). |
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

- **6-Stage Stream Pipeline**:
  - ST0 (Prune & Cull): Vertex assembly, culling, guard-band and frustum clipping.
  - Skid Buffer 0: `am_skid #(.WIDTH(703))` completely isolates ST0 from ST1.
  - ST1 (Stream Setup): 1-cycle triangle loading, perspective divide, edge slope and plane calculation.
  - ST2/ST3 (Coarse & Fine Raster): $8 \times 8$ conservative tile skipping, $2 \times 2$ fine walk, and 16-sample parallel MSAA 4x coverage evaluation.
  - Skid Buffer 1: `am_skid #(.WIDTH(53))` isolates ST3 coverage output from ST4 quad collection.
  - ST4/ST5 (Fast DDA & Warp Pack): 4-lane parallel DDA interpolation and 32-lane warp formation to SU 0.
  - Skid Buffer 2: `am_skid #(.WIDTH(181))` for direct fragment stream (`dx_*`) to ROP.
- **Backpressure & Flow Control**:
  - Registered skid buffers (`am_skid`) allow zero-bubble flow under full throughput while breaking all combinational paths between stages.
  - Full backpressure propagation from SU grant stalls upstream.

## 5. State machine

Pipelined architecture. Individual stage state machines in child specifications.

## 6. Latency and throughput

- Peak rasterization throughput: up to 1 quad / cycle.
- Full timing closure at 200 MHz on KC705.

## 7. Corner cases and errors

- Triangles with zero area or culled are rejected with zero latency in ST1.
- Skid buffers prevent overrun or dropped quads during SU dispatch delays.

## 8. What the TB checks

- Unit testbench: `sim/tb/atg_rx_pipeline_tb.v` (tests multi-primitive stream execution, skid buffer backpressure, and warp dispatch).
- Submodule testbenches: `atg_rx_clip_tb`, `atg_rx_setup_tb`, `atg_rx_scan_tb`, `atg_rx_bary_tb`, `atg_rx_frag_tb`, `atg_rx_order_tb`.
- System regression: `sim/verilator/run.sh` (all 7 modes: basic, raster, shade, tex, msaa, compute, core).

## 9. References

design §3.8, §2.3; WS001 Phase 025.

## 10. Status

Implemented & verified (Phase 025 RX Stream Pipeline Integration).
