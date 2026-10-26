# atg_rx_hiz

RTL: `rtl/gpu/rx/atg_rx_hiz.v`. Parent: `atg_rx_scan`. Implemented in: `ws003-p003`.

## 1. Purpose and place

Hierarchical Early-Z (Hi-Z) RAM: maintains coarse per-tile maximum depth bounds in on-chip BRAM. When `CFG_ENABLE_EARLY_Z=1`, the Hi-Z RAM tracking logic and storage are instantiated. Note that actual early tile occlusion culling (`hiz_cull`) is currently a placeholder / stub for future extension (`assign hiz_cull = 1'b0;`), establishing the hardware interface and memory hierarchy without impacting current rendering semantics. When `CFG_ENABLE_EARLY_Z=0`, this module is completely omitted from elaboration and synthesis, achieving minimum resource utilization.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `DEPTH_W` | `16` | Bit width of stored coarse depth bounds (half-precision or quantized depth). |
| `TILE_ADDR_W` | `11` | Address width (2048 tile depth cache entries). |

## 3. Ports

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `rst_n` | in | 1 | Synchronous active-low reset. |
| `clear` | in | 1 | Hi-Z buffer clear request. |
| `rd_addr` | in | 11 | Tile read address. |
| `rd_zmax` | out | 16 | Tile stored maximum depth. |
| `wr_en` | in | 1 | Tile depth update write enable. |
| `wr_addr` | in | 11 | Tile write address. |
| `wr_zmax` | in | 16 | New tile maximum depth. |
