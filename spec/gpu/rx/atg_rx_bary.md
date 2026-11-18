# atg_rx_bary

RTL: `rtl/gpu/rx/atg_rx_bary.v`.  Parent: atg_rx_frag.  Children: `am_fp_mul`, `am_fp_add`, `am_fp_div`, `am_fp_fix2f` (i, j in eighths to fp32).

## 1. Purpose and place

The lane arithmetic of the fragment warps: the planes, the perspective division and the barycentrics of a quad's four lanes at their centres or at sample locations, and the samples' depth slopes of a triangle.  Moved out of `atg_rx_frag` for the line limit.

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1, 1 | Clock, synchronous active-low reset |
| `i_start` | in | 1 | Pulse while idle: the barycentric pass |
| `i_dz` | in | 1 | Pulse while idle: the depth slopes |
| `i_pl` | in | 384 | (z, 1/w, b0/w, b1/w) × (A, B, C) fp32, as sp_tri[735:352] |
| `i_qx`, `i_qy`, `i_bx0`, `i_by0` | in | 16 each | The quad and the bbox origin; held during the pass |
| `i_osel` | in | 12 | Lane l's location (3 bits): 0 the centre, 1 + s sample s; held during the pass |
| `busy` | out | 1 | Not idle |
| `o_done` | out | 1 | Pulse at the end of a pass |
| `o_b0`, `o_b1`, `o_b2`, `o_z` | out | 128 each | Lane l at bits 32 l (z not clamped); held until the next pass |
| `o_ds` | out | 128 | d_s of sample s at bits 32 s |

16 ports.

## 4. Behaviour

- The pass: i = x − bx0 + dx, j = y − by0 + dy as fp32 (8 i + 8 dx is an integer, converted exactly and scaled by 1/8; the centre has dx = dy = 0 and gives the same bits as before); per lane P = (A i + B j) + C for the four planes, r = 1 / (1/w), b0 = (b0/w) r, b1 = (b1/w) r, b2 = (1 − b0) − b1 (RNE, denormals flushed: the RX's units).
- Evaluates all 4 quad lanes in parallel across planes Z, 1/W, B0/W, B1/W using a 2-stage adder pipeline (`u_fadd1`, `u_fadd2`) to eliminate structural hazards, followed by 4 parallel `am_fp_div` units for perspective reciprocal division.
- d_s = Az dx_s + Bz dy_s: two fmul and one fadd per sample evaluated across the 4 samples in parallel. The offsets (dx, dy): (−1/8, −3/8), (3/8, −1/8), (−3/8, 1/8), (1/8, 3/8) (Values referenced: Vulkan specification, Multisampling, standard sample locations).

## 5. State machine

IDLE →(i_start)→ PL (20 cycles) → DIV (28 cycles, 4 lanes parallel) → BC (13 cycles) → IDLE with o_done;
IDLE →(i_dz)→ DZ (10 cycles) → IDLE with o_done.

## 6. Latency and throughput

- Barycentric pass: 61 cycles total (PL: 20 cycles, DIV: 28 cycles, BC: 13 cycles). Speedup of >3x over legacy 200-cycle serial engine.
- Depth slope pass (DZ): 10 cycles total.

## 7. Corner cases and errors

- `MUT_DZ_SIGN` flips d_s's sign (the TB's mutation check).

## 8. What the TB checks

- Unit testbench: `sim/tb/atg_rx_bary_tb.v` (verifies depth slopes, plane evaluations, 4-lane parallel divisions, and barycentric identity $b0+b1+b2 = 1$).
- Full rasterization pipeline: `sim/tb/atg_rx_frag_tb.v` (`.warps`: the centre, bit for bit as before; `.ms`: the samples and d_s).

## 9. References

design §15.4; spec atg_rx_frag.md, atg_rx_setup.md (the planes).

## 10. Status

Implemented & verified (Phase 024 Fast Parallel Plane Evaluator).
