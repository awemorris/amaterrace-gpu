# atg_tu_foot

RTL: `rtl/gpu/tu/atg_tu_foot.v`.  Parent: atg_tu_addr.  Implemented in: p009 (part F, split off atg_tu_addr).

## 1. Purpose and place

One lane's footprint and texel addresses (combinational; stage B of atg_tu_addr).  No children.

## 2. Parameters

None.

## 3. Ports

Combinational.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `op` | in | 2 | 0 texl, 1 texb, 2 texf, 3 texsz. |
| `gather` | in | 1 | Gather (nearest slice of a 3D image). |
| `cube` | in | 1 | Cube map. |
| `is3d` | in | 1 | 3D image. |
| `tiled` | in | 1 | 4×4 tiled layout. |
| `lin` | in | 1 | Bilinear (and linear in depth for 3D). |
| `p0` | in | 1 | The pass's second slice. |
| `mu` | in | 2 | Address mode u. |
| `mv` | in | 2 | v. |
| `mw` | in | 2 | w. |
| `off` | in | 12 | Texel offsets {dw, dv, du} (0 for a cube). |
| `x` | in | 32 | texf: the integer x (word 0). |
| `y` | in | 32 | texf: y (word 1). |
| `z` | in | 32 | texf: z of a 3D image (word 4). |
| `cu` | in | 31 | The texel coordinate u, 8 fraction bits, signed. |
| `cv` | in | 31 | v. |
| `cw` | in | 31 | w (3D). |
| `wl` | in | 16 | The level's width. |
| `hl` | in | 16 | Height. |
| `dl` | in | 16 | Depth. |
| `face` | in | 3 | A cube lane's face. |
| `lbase` | in | 32 | The level base (BASE + layer × stride + level offset). |
| `plane` | in | 32 | The level's plane in bytes. |
| `stride` | in | 32 | The layer stride (a cube's faces). |
| `addr` | out | 128 | Texels 0-3: byte address, bit 0 a border texel. |
| `fuv` | out | 16 | {fv, fu}. |
| `fw` | out | 8 | The depth weight (3D linear), else 0. |

27 ports.

## 4. Behaviour

As spec/gpu/tu/atg_tu_addr.md §4, "Footprint" and "Address" (`tools/tumodel.py` `lane_addr`), with the functions of `include/atg_tu_fn.vh` (`tu_wrap`, `tu_mod`, `tu_cube_texel`).

## 5. State machine

None.

## 6. Latency and throughput

Combinational; atg_tu_addr registers its outputs in LB.

## 7. Corner cases and errors

- `tu_mod` takes an index within 9 texels of [0, p): one correction for p ≥ 16, a 5-bit remainder below.

## 8. What the TB checks

No unit testbench of its own: `sim/tb/atg_tu_addr_tb.v` (every group).

## 9. References

docs/ghci.md §8.4.

## 10. Status

Split off atg_tu_addr in WS288 p009 part F (P3) with the integer wrap, the offsets, the slice and the cube edges.
