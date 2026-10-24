# atg_rop_blend

RTL: `rtl/gpu/rop/atg_rop_blend.v`.  Parent: atg_rop.  Implemented in: p007.

## 1. Purpose and place

ROP blend: converts fp32 colour to the render-target format, blends with the destination pixels (BLEND factors and ops, BLEND_CONST), applies WRITE_MASK; a fixed pipeline used by atg_rop_wb.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `LAT` | `3` | Pipeline cycles from b_valid to b_rvalid. |

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
| `b_valid` | in | 1 | Blend 4 pixels. |
| `b_src` | in | 512 | Source colours (fp32). |
| `b_dst` | in | 128 | Destination pixels (RT_FORMAT). |
| `b_mask` | in | 4 | Lanes. |
| `b_rt` | in | 2 | (CAPS[30]) The colour attachment of the beat: its format, BLEND word and write mask. |
| `b_rvalid` | out | 1 | Result LAT cycles later. |
| `b_pix` | out | 128 | Result pixels (RT_FORMAT; masked lanes keep b_dst). |

12 ports (11 before CAPS[30]).

## 4. Behaviour

Formats BGRA8, RGBA8, RGB565 (RT_FORMAT).  Blend equation per design §2.3 BLEND (the v1 bit layout of the blitter's blend for the factors; one/zero/src alpha/one minus src alpha/dst/const).

**With CAPS[30]** (the 8-bit path of the render output; atg_rop_fblend takes the other blendable formats):

- The module keeps BLEND (0x07A) and BLEND1-BLEND3 (0x084-0x086), RT_FORMAT (0x072), RT_FORMATS (0x07D), BLEND_CONST (0x07B), BLEND_CONST_R-A (0x087-0x08A) and ROP_CTRL (0x08D); b_rt selects the attachment's BLEND word and format (RT_FORMATS byte b_rt, or RT_FORMAT's code when attachment 0's byte is 0).
- Formats (VkFormat): 37 R8G8B8A8_UNORM, 44 B8G8R8A8_UNORM, 51 A8B8G8R8_UNORM_PACK32 (37's memory), 9 R8_UNORM, 16 R8G8_UNORM, 4 R5G6B5_UNORM_PACK16, 8 A1R5G5B5_UNORM_PACK16; pixels of 1, 2 or 4 bytes in the low bytes of each 32-bit lane of b_dst and b_pix.  Formats without alpha (R8, R8G8, R5G6B5) read a destination alpha of 255 (1.0); A1R5G5B5's alpha reads 0 or 255 and writes RNE(a / 255), so 1 from 128 up.  The missing colour channels of R8 and R8G8 read 0 and are not written.
- The constant: with ROP_CTRL[1] = 1 the fp32 BLEND_CONST_R-A, each clamped to [0, 1] and rounded to 8 bits (RNE(c × 255)) when written; with 0 BLEND_CONST's bytes as before.
- Blend enable is ignored (no blending) for a format outside this list; atg_rop_wpix sends such beats to atg_rop_fblend or packs them.

## 5. State machine

A pipeline.

## 6. Latency and throughput

4 pixels per cycle.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_rop_blend_tb.v` prints, in this order:

- `PASS atg_rop_blend.formats` — format conversion
- `PASS atg_rop_blend.factors` — every factor and op against a C reference
- `PASS atg_rop_blend.r8rg8` — R8, R8G8 and A1R5G5B5 with every factor (CAPS[30])
- `PASS atg_rop_blend.const` — the fp32 constants' quantization (CAPS[30])
- `PASS atg_rop_blend` at the end.

## 9. References

design §2.3 (BLEND, WRITE_MASK).

## 10. Status

2026-10-24 Q1 (P3's p007 decisions, ACKed; ghci.md to follow): stencil ops are not implemented in v1 (the ROP gets no facing bit; a port change belongs to p009). STATE bits: SCISSOR_MIN/MAX `{y, x}` (MAX 0 = none), RT_SIZE `{h, w}`, CULL [1:0] 1 front/2 back/3 both and [2] front = CCW, DEBUG_COLOR and BLEND_CONST RGBA8 (R in [7:0]), BLEND [0] enable, [4:1] src colour, [8:5] dst colour, [11:9] colour op, [15:12] src alpha, [19:16] dst alpha, [22:20] alpha op (VkBlendFactor/VkBlendOp numbers), WRITE_MASK [3:0] RGBA (0 writes nothing), DEPTH func = VkCompareOp and no test without a depth format bit; DS_BASE/RT_BASE/stride aligned to 8 bytes (4 for RGB565). The CP sequencer holds a SET_REG into the RX range (0x050–0x06F) while RX or ROP is busy and into the ROP range (0x070–0x08F) while the ROP is busy.

Implemented in p007 (the three RT_FORMAT codes).  2026-10-25: this spec adds the CAPS[30] form (b_rt, the VkFormat list, R8, R8G8, A1R5G5B5, the fp32 constants); implemented the same day: `.r8rg8` and `.const` from `sim/vec/rop_blend2.txt` (`tools/rop-vectors.py`, the model `blend_pixel8` in `tools/rxmodel.py`; a format outside the list writes nothing), the earlier vectors unchanged; atg_rop wires b_rt to 0 until the attachments' beats exist (S8 of the plan).  The pipeline carries the attachment's BLEND word, format, write mask and constant with the beat.
