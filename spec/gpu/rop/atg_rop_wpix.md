# atg_rop_wpix

RTL: `rtl/gpu/rop/atg_rop_wpix.v` (new).  Parent: atg_rop_wb.  Child: `atg_rop_fblend`.

## 1. Purpose and place

The pixels of `atg_rop_wb` (CAPS[30], docs/ghci.md §8.5): the colour attachments' state, the place of each pixel of a beat in the lines, the choice of the blend path and the new pixel bytes.  No state machine of its own; it holds `atg_rop_fblend`.  Split off `atg_rop_wb` for the line limit (design §16.7).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1, 1 | Clock, reset. |
| `st_we`, `st_idx`, `st_wdata` | in | 1, 9, 32 | STATE; the module keeps RT_BASE, RT_STRIDE, RT_FORMAT, BLEND, BLEND_CONST, WRITE_MASK, RT_FORMATS, RT1-3_BASE/STRIDE, BLEND1-3, BLEND_CONST_R-A, ROP_CTRL[1], MS_CTRL. |
| `i_xy`, `i_rt`, `i_smask`, `i_color` | in | 32, 2, 16, 512 | The beat (atg_rop_wb's copy): position, attachment, surviving samples (bit 4 l + s), colours. |
| `i_r`, `i_j`, `i_g` | in | 1, 2, 2 | The place: row, line of the row (several lines), pass (one line: the sample). |
| `i_line0`, `i_line1` | in | LINE_BYTES*8 each | The two entries' lines. |
| `i_off0`, `i_off1` | in | LINE_SHIFT each | The quad's first byte in each row's line. |
| `b_pix` | in | 128 | atg_rop_blend's result (path 0). |
| `f_go` | in | 1 | Start atg_rop_fblend on the current slots (path 1; it is idle). |
| `f_done` | out | 1 | atg_rop_fblend's result is there. |
| `f_take` | in | 1 | atg_rop_wb takes it (atg_rop_fblend's o_ready). |
| `o_addr` | out | 32 | The row's address (r = i_r), plus i_j lines with several lines. |
| `o_nl`, `o_np`, `o_multi` | out | 2, 2, 1 | Lines of a row − 1 (several), passes − 1 (one line), several lines. |
| `o_drop`, `o_read`, `o_path` | out | 1, 1, 2 | Nothing to write; the old pixels needed; the path (0 atg_rop_blend, 1 atg_rop_fblend, 2 the packing). |
| `o_lw`, `o_mask` | out | 1, 4 | The row (one line) or the line (several) has a surviving slot; the pass's slots. |
| `o_bsrc`, `o_bdst` | out | 512, 128 | The slots' sources and 32-bit destinations (to atg_rop_blend). |
| `o_res` | out | 512 | Slot k's new pixel at [128 k], ps bytes. |
| `o_ent`, `o_soff`, `o_ps` | out | 4, 4*LINE_SHIFT, 5 | Slot k's entry, its byte in the line, the pixel's bytes. |

35 ports.

## 4. Behaviour

- **Format**: RT_FORMATS byte i_rt, or for attachment 0 with that byte 0 the earlier RT_FORMAT code (0 B8G8R8A8_UNORM, 1 R8G8B8A8_UNORM, 2 and 3 R5G6B5_UNORM_PACK16).  ps = 1, 2, 4, 8 or 16 bytes (`atg_fmt_info`).  o_drop: the format lacks the colour-attachment feature (an absent attachment's 0 included), or the write mask has no channel of the format.  o_read: blend enabled for a blending format, or a write mask without every channel of the format.
- **Places**: S = 4 with MS_CTRL[3:0] = 2, else 1; sample s of pixel x at (S x + s) ps of the row, the row at RTk_BASE + y RTk_STRIDE.  A quad's row is 2 S ps bytes: one line when 2 S ps ≤ LINE_BYTES, else (o_multi) 2 S ps / LINE_BYTES whole lines (only with S = 4).
  - One line: pass g's slot k is lane k, sample g, in entry k >> 1 at i_off + (S (k & 1) + g) ps.
  - Several lines: line j of row r holds the slots n = E j + k for k < E = LINE_BYTES / ps (lane 2 r + n / 4, sample n mod 4) at byte k ps of entry r; one pass.
  - A slot is in o_mask when its sample survived (i_smask).
- **Paths**: 0 atg_rop_blend: B8G8R8A8, R8G8B8A8, A8B8G8R8, R5G6B5, R8, R8G8, A1R5G5B5 (UNORM); its result is the slot's 32-bit lane (the bytes above ps unused).  1 atg_rop_fblend: R8G8B8A8_SRGB, B8G8R8A8_SRGB, A8B8G8R8_SRGB, A2B10G10R10_UNORM, R16, R16G16, R16G16B16A16_SFLOAT; the constant is BLEND_CONST_R-A with ROP_CTRL[1], else BLEND_CONST's bytes / 255; o_res = raw where written, the old bits where kept.  2 the packing (`atg_fmt_pack`) of the source alone: the integer formats and R32, R32G32, R32G32B32A32_SFLOAT (Vulkan does not blend them; BLEND's enable is ignored); the same merge.

## 5. State machine

None (atg_rop_fblend has its own).

## 6. Latency and throughput

Combinational from the inputs to o_* (the paths' results come from their units).

## 7. Corner cases and errors

- `-DMUT_WPIX_LINE` (several lines: the line index left out of o_addr) and `-DMUT_WPIX_KEEP` (the packing's kept bits not merged) fail `atg_rop_mrt`.

## 8. What the TB checks

Through `sim/tb/atg_rop_mrt_tb.v` (spec atg_rop_wb.md §8).

## 9. References

docs/ghci.md §8.5 (ROP range, the colour formats), design §16.7; spec atg_rop_wb.md, atg_rop_blend.md, atg_rop_fblend.md, atg_fmt.md.  Values referenced: Vulkan specification, Blending (formats without blending), Fixed-Point Data Conversions, Required Format Support.

## 10. Status

Implemented 2026-10-25 (CAPS[30], colour attachments).  The design's text had wpix without a child; atg_rop_fblend sits here so that atg_rop_wb stays within 40 ports.

2026-10-25 (area): the old pixel of a slot (o_bdst, the fblend destination, the kept bits of path 2) is read from the 16-byte block of its offset and then its ps bytes there, the offset being a multiple of ps as docs/ghci.md section 8.5 requires (as atg_rop_wb, whose merge ignores the low bits of an offset that is not); the bytes above ps are 0 (before, the next bytes of the line; no path uses them).
