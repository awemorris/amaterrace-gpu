# atg_tu_etc

RTL: `rtl/gpu/tu/atg_tu_etc.v`.  Parent: atg_tu_ffront (the fp32 filter path decodes a block texel before converting it).  Children: two atg_tu_eac (the EAC blocks).

## 1. Purpose and place

The ETC2 and EAC block decoder: one compressed 4 × 4 block and a texel position in it to that texel, for the ten ETC2/EAC formats (VkFormat 147-156), the compressed family Vulkan 1.0 requires one of.

## 2. Parameters

None.

## 3. Ports

Inputs in cycle 0, outputs in cycle 4 (registers); one texel a cycle.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `i_fmt` | in | 4 | The format, VkFormat - 147: 0 ETC2_R8G8B8_UNORM, 1 its SRGB, 2 ETC2_R8G8B8A1_UNORM, 3 its SRGB, 4 ETC2_R8G8B8A8_UNORM, 5 its SRGB, 6 EAC_R11_UNORM, 7 EAC_R11_SNORM, 8 EAC_R11G11_UNORM, 9 EAC_R11G11_SNORM. |
| `i_block` | in | 128 | The block's bytes as stored (8 or 16 bytes; byte 0 in [7:0]). |
| `i_s`, `i_t` | in | 2 | The texel's column and row in the block. |
| `o_kind` | out | 2 | 0 RGBA8 UNORM, 1 RGBA8 sRGB (R, G, B to be decoded as sRGB), 2 unsigned 11-bit (R11, R11G11 UNORM), 3 signed 11-bit (SNORM). |
| `o_texel` | out | 32 | kind 0, 1: R in [7:0], G [15:8], B [23:16], A [31:24]; kind 2, 3: R in [10:0], G in [26:16] (two's complement for 3; G 0 for one channel). |

7 ports.

## 4. Behaviour

The decoding rules are those of the Khronos Data Format Specification's ETC2 and EAC sections (written from that text, not from another decoder): the colour modes individual, differential, T, H and planar; RGB8A1's punch-through alpha (no individual mode; the opaque bit; the transparent index gives (0, 0, 0, 0)); RGBA8's 8-bit EAC alpha block before the colour block; EAC R11 (base × 8 + 4, multiplier 0 as 1/8, the UNORM and SNORM ranges) and R11G11 as two R11 blocks.  The output is the texel before any conversion: atg_tu_ffilt converts kind 0 and 1 as R8G8B8A8_UNORM and _SRGB (alpha 255 for the formats without alpha), kind 2 as UNORM c / 2047, kind 3 as SNORM max(c / 1023, -1).

## 5. State machine

None.

## 6. Latency and throughput

Four stages (p038): E0 the block's words (the colour block's word chosen); E1 the mode (individual, differential, T, H, planar), the base colour and the signed offset of the three channels (the modifier or T and H's distance), planar's h − o and v − o, EAC's modifier and base; E1b planar's x (h − o) and y (v − o) parts, EAC's modifier times the multiplier (shifts and adds); E2 the sums and the clamps.  One texel a cycle, 4 cycles.  All the arithmetic through rtl/common.  A bilinear sample or gather of a 16-byte block format takes 4 passes and of an 8-byte one 2 (the four texels may lie in four blocks; atg_tu_addr and atg_tu_cache fetch a block per texel).

## 7. Corner cases and errors

- i_fmt 10-15: the output is (0, 0, 0, 0) with kind 0.
- The bit layouts, the mode selection, the modifier, distance and EAC tables and the punch-through rules were taken from the Khronos Data Format Specification's ETC2 text (the asciidoc source, 2026-10-25); `tools/etcmodel.py --selftest` checks the specification's worked examples (the planar block's 16 texels, T and H paint colours, the EAC alpha, R11 with multiplier 0, signed R11).

## 8. What the TB checks

`sim/tb/atg_tu_etc_tb.v` (vectors from `tools/etcmodel.py`) prints, in this order:

- `PASS atg_tu_etc.modes` — hand-made blocks of every colour mode, punch-through and EAC rule, every texel
- `PASS atg_tu_etc.random` — random blocks of every format against the model
- `PASS atg_tu_etc` at the end.

`MUT_ETC_TMODE` (a wrong T-mode distance table entry) must make the TB fail.

## 9. References

design §16.11a; `spec/gpu/tu/atg_tu.md`.  Values referenced: Khronos Data Format Specification (CC-BY-4.0), ETC2 and EAC compressed texture image formats.

## 10. Status

Implemented (2026-10-25), combinational instead of the two register stages first planned (it sits in atg_tu_ffilt's one-step-a-cycle loop).

2026-10-25 (p038): pipelined in four stages (§6), the arithmetic through rtl/common (the negations by tables, 45 − 3k by a table, the EAC multiply by shifts and adds); the values are unchanged (the TB clocked, MUT_ETC_TMODE still fails).
