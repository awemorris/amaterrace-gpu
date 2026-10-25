# atg_tu_lod

RTL: `rtl/gpu/tu/atg_tu_lod.v`.  Parent: atg_tu_addr.  Implemented in: p009 (part F, split off atg_tu_addr).

## 1. Purpose and place

texb's quad level of detail (combinational).  No children.

## 2. Parameters

None.

## 3. Ports

Combinational.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `u` | in | 96 | u of lanes 0-2 (fp32), lane 0 in the low bits. |
| `v` | in | 96 | v. |
| `w` | in | 96 | The third coordinate (3D). |
| `cs` | in | 81 | A cube's s of lanes 0-2 on lane 0's face (27 bits each). |
| `ct` | in | 81 | t. |
| `is3d` | in | 1 | The view is 3D. |
| `cube` | in | 1 | The view is a cube map. |
| `w0` | in | 16 | Level 0's width. |
| `h0` | in | 16 | Height. |
| `d0` | in | 16 | Depth (3D). |
| `ax` | in | 2 | The axis: 0 u, 1 v, 2 w. |
| `lam` | out | 17 | λA of axis `ax` (w: −32768 but for a 3D image), signed, 8 fraction bits; λq is the largest of the three (atg_tu_addr). |

11 ports.

## 4. Behaviour

As `tools/tumodel.py` `lod_quad`: per axis A, with the lanes' fixed-point values A0-A2 (u, v and w as floor(x × 2^16); a cube's s and t >> 8), the largest of |A1 − A0| and |A2 − A0| = m, λA = L2(m) + L2(size) − 4096 (L2(x) = 256 × the msb position + the 8 bits below the msb), −32768 for m = 0; sizes: u w0, v h0 (a cube w0), w d0.  λq = the largest λA (w only for 3D).

## 5. State machine

None.

## 6. Latency and throughput

Combinational; atg_tu_addr registers the result in its LOD state.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

No unit testbench of its own: `sim/tb/atg_tu_addr_tb.v` (`lod`, `volume`, `cube`, `query`).

## 9. References

docs/ghci.md §8.4.

## 10. Status

Split off atg_tu_addr in WS288 p009 part F (P3) with the 3D and cube axes.

2026-10-25 (area): one axis at a time (input `ax`); atg_tu_addr's LOD state takes λq as the largest over three cycles (was one cycle, all three axes at once).  The values are unchanged.
