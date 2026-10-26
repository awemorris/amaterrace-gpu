# atg_rx_coarse

RTL: `rtl/gpu/rx/atg_rx_coarse.v`. Parent: `atg_rx_scan`. Implemented in: ws001-p023.

## 1. Purpose and Architecture

`atg_rx_coarse` is the Coarse Tile Rasterizer of the Amaterrace GPU RX pipeline. It traverses the triangle's bounding box in $8 \times 8$ pixel tiles ($4 \times 4$ quads) before fine-grained quad evaluation.

### Key Features
1. **1-Cycle Empty Tile Skip**:
   - Evaluates the three edge functions across the four conservative tile corners $(tx, ty)$, $(tx+8, ty)$, $(tx, ty+8)$, $(tx+8, ty+8)$ simultaneously.
   - If any edge function has all four corners negative ($E_{max} < 0$), the entire tile is guaranteed to lie outside the triangle and is discarded in a single cycle.
2. **Trivially Accepted Tile Detection**:
   - If all three edge functions have all corners positive ($E_{min} \ge 0$) and the tile is fully contained in the bounding box, the tile is marked `tile_trivial = 1`.
   - Allows the Fine Rasterizer to bypass per-quad edge testing and emit full-coverage masks directly.
3. **Pipelined Interfacing**:
   - Connects to `atg_rx_scan` via a standard `valid` / `ready` handshake per active tile.

## 2. Ports

Clock/reset domain: `clk` (gclk), synchronous active-low reset `rst_n`.

| Name | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **From Setup / Scan** | | | |
| `tri_valid` | in | 1 | Triangle parameters valid. |
| `tri_ready` | out | 1 | Ready to accept next triangle. |
| `bbox_min_x` | in | 16 | Bounding box minimum X. |
| `bbox_min_y` | in | 16 | Bounding box minimum Y. |
| `bbox_max_x` | in | 16 | Bounding box maximum X. |
| `bbox_max_y` | in | 16 | Bounding box maximum Y. |
| `e0_a8`, `e0_b8`, `e0_er` | in | 48 | Edge 0 slope A (<<8), slope B (<<8), and base edge value at bbox origin. |
| `e1_a8`, `e1_b8`, `e1_er` | in | 48 | Edge 1 parameters. |
| `e2_a8`, `e2_b8`, `e2_er` | in | 48 | Edge 2 parameters. |
| `lowm0`, `lowm1`, `lowm2` | in | 48 | Maximum MSAA sample reach offset bound per edge. |
| **To Fine Rasterizer** | | | |
| `tile_valid` | out | 1 | Active (non-culled) tile valid. |
| `tile_ready` | in | 1 | Fine rasterizer ready for next tile. |
| `tile_x` | out | 16 | Tile X coordinate (aligned to 8 pixels). |
| `tile_y` | out | 16 | Tile Y coordinate (aligned to 8 pixels). |
| `tile_e0`, `tile_e1`, `tile_e2` | out | 48 | Edge values at tile origin. |
| `tile_trivial` | out | 1 | Asserted when the tile is 100% inside triangle. |
| `tile_last` | out | 1 | Last tile of this triangle. |
| `busy` | out | 1 | Coarse traversal active. |

## 3. Mathematical Evaluation

For edge $e$ with step coefficients $A_{8} = A \ll 8$ and $B_{8} = B \ll 8$, stepping 8 pixels yields:
$$\Delta X_8 = A_8 \ll 3, \quad \Delta Y_8 = B_8 \ll 3$$

The conservative corner extremes over $[0, 8] \times [0, 8]$ are determined by sign inspection:
$$\Delta_{max} = (A_8 > 0 ? \Delta X_8 : 0) + (B_8 > 0 ? \Delta Y_8 : 0)$$
$$\Delta_{min} = (A_8 < 0 ? \Delta X_8 : 0) + (B_8 < 0 ? \Delta Y_8 : 0)$$

At tile origin edge value $E_{tl}$:
- $E_{max} = E_{tl} + \Delta_{max}$. If $E_{max} < 0$, all points in tile have $E < 0 \implies$ Skip tile.
- $E_{min} = E_{tl} + \Delta_{min}$. If $E_{min} \ge 0$ for all 3 edges $\implies$ Trivial accept.

## 4. Verification & Constraints
- Verilog-2005 compliant.
- Raw arithmetic operators prohibited outside `rtl/library/arith/` (checked via `tools/arith-lint.py`).
