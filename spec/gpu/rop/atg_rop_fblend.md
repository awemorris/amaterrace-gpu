# atg_rop_fblend

RTL: `rtl/gpu/rop/atg_rop_fblend.v` (new).  Parent: atg_rop_wpix (in atg_rop_wb, beside atg_rop_blend; atg_rop_wpix chooses the path).  Children: atg_rx_fmul, atg_rx_fadd, atg_fmt_srgbenc.

## 1. Purpose and place

The fp32 blend path of the render output: blending, the write mask and the packing for the colour formats that the 8-bit path (atg_rop_blend) does not take: the sRGB formats, A2B10G10R10_UNORM and the 16-bit floats (R16, R16G16, R16G16B16A16_SFLOAT).  One beat (the four pixels of a quad's row pair for one attachment) at a time.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `i_valid` | in | 1 | A beat. |
| `i_ready` | out | 1 | Taken (1 only while idle). |
| `i_lanes` | in | 4 | The pixels to write (lane k = pixel k). |
| `i_src` | in | 512 | The source colours, fp32 RGBA per lane (lane 0 R in [31:0]). |
| `i_dst` | in | 256 | The destination pixels as stored, 64 bits per lane (the low ps bytes). |
| `i_fmt` | in | 8 | The attachment's VkFormat (one of §1's). |
| `i_blend` | in | 23 | The attachment's BLEND word [22:0] (0x07A or BLEND1-3): [0] enable, [4:1] source colour factor, [8:5] destination colour factor, [11:9] colour op, [15:12] source alpha factor, [19:16] destination alpha factor, [22:20] alpha op. |
| `i_const` | in | 128 | The blend constant, fp32 RGBA (BLEND_CONST_R-A, or BLEND_CONST's bytes / 255 when ROP_CTRL[1] = 0; atg_rop_wpix chooses). |
| `i_wm` | in | 4 | The attachment's write mask (R, G, B, A). |
| `o_valid` | out | 1 | The result; held until taken. |
| `o_ready` | in | 1 | Taken. |
| `o_raw` | out | 256 | The pixels to write, 64 bits per lane. |
| `o_keep` | out | 256 | Per bit: 1 = keep the stored bit (masked components, lanes not in i_lanes, bits outside the pixel). |

15 ports.

## 4. Behaviour

For each lane in i_lanes: d = `atg_fmt_unpack(i_dst, i_fmt)` (sRGB: R, G, B decoded to linear; formats without alpha read a destination alpha of 1).  For a fixed-point target (UNORM, sRGB) the source, the destination, the constant and every factor are clamped to [0, 1] before blending (Vulkan's rule for fixed-point attachments).  With i_blend[0]:

- factors (VkBlendFactor 0-14) per channel: 0 ZERO, 1 ONE, 2 SRC_COLOR, 3 ONE_MINUS_SRC_COLOR, 4 DST_COLOR, 5 ONE_MINUS_DST_COLOR, 6 SRC_ALPHA, 7 ONE_MINUS_SRC_ALPHA, 8 DST_ALPHA, 9 ONE_MINUS_DST_ALPHA, 10 CONSTANT_COLOR, 11 ONE_MINUS_CONSTANT_COLOR, 12 CONSTANT_ALPHA, 13 ONE_MINUS_CONSTANT_ALPHA, 14 SRC_ALPHA_SATURATE (min(A_s, 1 - A_d) for R, G, B; 1 for A); 15 reads as ZERO.  "One minus x" is 1 - x on the fadd.
- ops (VkBlendOp 0-4): 0 ADD s·Fs + d·Fd, 1 SUBTRACT s·Fs - d·Fd, 2 REVERSE_SUBTRACT d·Fd - s·Fs, 3 MIN min(s, d), 4 MAX max(s, d) (the factors are ignored); 5-7 read as ADD.  MIN and MAX compare as fp32 (-0 = +0); a NaN operand gives 0x7FC00000.
- the arithmetic is atg_rx_fmul and atg_rx_fadd (fp32, round to nearest even, denormals flushed, as tools/rxmodel.py's fmul and fadd).

Without i_blend[0] the result is the source.  Then the result is packed: sRGB R, G, B through an atg_fmt_srgbenc (one per lane), then `atg_fmt_pack(c, i_fmt, i_wm)`; o_keep is pack's keep, all ones for lanes outside i_lanes.

## 5. State machine

IDLE →(i_valid)→ per lane and channel: CH (the source, MIN or MAX in one step) → FS, FD (a "one minus" factor on the fadd) → P, Q (s·Fs, d·Fd on the fmul) → R (the op) → … → ENC (sRGB only: R, G, B of each lane through the one encoder) → PACK (one lane per cycle) → OUT →(o_ready)→ IDLE.  One operation at a time (no overlap in v1); the lane's destination is unpacked by one atg_fmt_unpack.

## 6. Latency and throughput

v1 does one operation at a time: about 5 cycles per fadd or fmul, up to 5 per channel, so up to about 400 cycles per beat with blending and 20 without, plus about 40 per lane for the sRGB encoding (one encoder, three channels); the testbench saw at most 638 cycles per beat.  Overlapping the channels on the pipelined units (the earlier estimate of about 50 cycles) is left to the timing Phase.  The 8-bit path stays at its speed.  Size ≈2k LUT and ≈4 DSP (estimated).

## 7. Corner cases and errors

- i_fmt outside §1's formats: nothing is written (o_keep all ones).
- Infinities in a float target pass through blending as IEEE arithmetic (inf - inf = NaN).
- The write mask: a masked component keeps its stored bits (packed formats bit by bit).

## 8. What the TB checks

`sim/tb/atg_rop_fblend_tb.v` (vectors from `tools/rxmodel.py`) prints, in this order:

- `PASS atg_rop_fblend.ops` — the 5 ops × 15 factors × the formats (sRGB, A2B10G10R10_UNORM, R16G16B16A16_SFLOAT, R16_SFLOAT) with random colours, constants and masks against the model
- `PASS atg_rop_fblend.srgb` — decoding the destination, blending in linear values and encoding: every code read and written back unchanged with ONE/ZERO
- `PASS atg_rop_fblend` at the end.

## 9. References

docs/ghci.md §8.5 (ROP range, per-sample operations), `spec/gpu/rop/atg_rop_blend.md`, `spec/gpu/fmt/atg_fmt.md`, `spec/gpu/fmt/atg_fmt_srgbenc.md`.  design §16.7.  Values referenced: Vulkan specification, Blending, VkBlendFactor, VkBlendOp.

## 10. Status

Implemented 2026-10-25: every PASS of §8 (`sim/vec/rop_fblend.txt` from `tools/rop-vectors.py`, the model `fblend_lane` in `tools/rxmodel.py`).  Wired in atg_rop_wpix (2026-10-25; checked through `sim/tb/atg_rop_mrt_tb.v`).  One encoder instead of the four of the first text (§6).
