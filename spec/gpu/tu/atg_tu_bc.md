# atg_tu_bc

RTL: `rtl/gpu/tu/atg_tu_bc.v`. Parent: `atg_tu_decp`. Children: `am_add`, `am_sub`, `am_mul`. Implemented in: ws002-p006.

## 1. Purpose and place

`atg_tu_bc` implements hardware block decompression for desktop standard Block Compression formats BC1 through BC7 (DXT1..DXT5, RGTC1/2, BPTC_FLOAT, BPTC_UNORM) in accordance with the Vulkan 1.0 and Khronos Data Format specifications.
Given a 64-bit or 128-bit compressed block and a sub-texel index ($k \in [0..15]$ in the $4 \times 4$ footprint), `atg_tu_bc` decompresses the corresponding RGBA8 or FP16 texel with single-cycle throughput.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: `clk`, synchronous active-low reset `rst_n`.

| Name | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Decode Request Interface** | | | |
| `in_valid` | in | 1 | Valid decode request. |
| `in_ready` | out | 1 | Decompressor ready to accept request. |
| `fmt_bc` | in | 4 | Format selector: `1:BC1`, `2:BC2`, `3:BC3`, `4:BC4`, `5:BC5`, `6:BC6H`, `7:BC7`. |
| `in_block` | in | 128 | 64-bit or 128-bit block data. |
| `sub_texel` | in | 4 | Sub-texel index in $4 \times 4$ block ($0..15$). |
| **Decode Result Interface** | | | |
| `out_valid` | out | 1 | Decompressed texel valid. |
| `out_ready` | in | 1 | Downstream receiver ready. |
| `out_rgba` | out | 32 | Decompressed 32-bit RGBA8 texel `{A, B, G, R}`. |
| `out_fp16` | out | 64 | Decompressed 64-bit FP16x4 half-float `{A, B, G, R}`. |

## 4. Architectural Details

### 4.1 BC1 (DXT1, 64-bit)
- Color endpoints $c_0, c_1$ in RGB565 are bit-replicated to RGB888.
- 4-color mode ($c_0 > c_1$): weights $(1, 0), (0, 1), (2/3, 1/3), (1/3, 2/3)$, alpha = 255. Division by 3 is implemented using exact integer multiplier $\times 683 \gg 11$ with `am_mul`.
- 3-color mode ($c_0 \le c_1$): weights $(1, 0), (0, 1), (1/2, 1/2)$, transparent black for index 3.

### 4.2 BC2 (DXT3, 128-bit)
- Explicit 4-bit alpha per texel expanded to 8-bit alpha `{nibble, nibble}`.
- Color block decompressed using BC1 4-color mode.

### 4.3 BC3 (DXT5, 128-bit)
- 8-level interpolated alpha from 8-bit endpoints $\alpha_0, \alpha_1$ with 3-bit index per texel.
- $\alpha_0 > \alpha_1$: 8-ramp mode via exact multiplier $\times 2341 \gg 14$ (/ 7).
- $\alpha_0 \le \alpha_1$: 6-ramp mode via exact multiplier $\times 1639 \gg 13$ (/ 5) plus 0 and 255.
- Color block decompressed using BC1 4-color mode.

### 4.4 BC4 / BC5 (RGTC1 / RGTC2)
- BC4: Single Red channel using the BC3 8-level interpolation engine.
- BC5: Dual Red and Green channels independently decompressed using the 8-level engine.

### 4.5 BC6H (BPTC_FLOAT, 128-bit)
- Decodes unsigned half-precision floating point (`fp16`) channels.
- Output delivered on `out_fp16`.

### 4.6 BC7 (BPTC_UNORM, 128-bit)
- Mode-based decompression (Modes 0 to 7).
- Supports 1, 2, and 3 subsets with partition tables and P-bits.
- Interpolation using exact 64-level weight scaling $((64-w) E_0 + w E_1 + 32) \gg 6$.

### 4.7 Timing and Throughput
- 1-cycle registered latency.
- 1 texel/cycle sustained throughput.
- Zero raw arithmetic operators outside `rtl/library/arith/`.
