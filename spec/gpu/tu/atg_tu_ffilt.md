# atg_tu_ffilt

RTL: `rtl/gpu/tu/atg_tu_ffilt.v`.  Parent: atg_tu (beside atg_tu_filter, after atg_tu_cache).  Implemented in: the Vulkan 1.0 formats work (TEX_FORMAT).

## 1. Purpose and place

The TU's fp32 filter path: the texture formats of TEX_FORMAT (docs/ghci.md §8.5) that the 8-bit path atg_tu_filter does not take, that is every sampled format but R8G8B8A8, B8G8R8A8, A8B8G8R8, R8 and R8G8 UNORM and the compares (atg_tu_addr sets ta_ctl[20] for them): SNORM, sRGB, the 16-bit and packed formats, 16- and 32-bit floats, the integer formats, 8- and 16-byte texels, the depth formats without compare (filtered linearly) and the stencil aspect.  Children: `atg_tu_etc` (the block decode), `atg_fmt_cvt` (the conversion, atg_fmt_comp pipelined) and `atg_tu_fma` (the fused multiply-add, pipelined).

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **From atg_tu_cache** | | | |
| `tc_valid` | in | 1 | One pass of a quad (atg_tu gives it only with tc_ctl[20]). |
| `tc_ready` | out | 1 | Taken (IDLE). |
| `tc_texels` | in | 512 | 4 lanes × 4 slots × 32 bits (1- and 2-byte texels right-justified). |
| `tc_bord` | in | 16 | The slots that are border texels. |
| `tc_lo` | in | 32 | The slots' address bits 1:0 (a block's texel position). |
| `tc_wts` | in | 128 | 4 lanes × {fw, fl, fv, fu}. |
| `tc_tag` | in | 16 | Tag. |
| `tc_mask` | in | 4 | Lanes. |
| `tc_ctl` | in | 50 | As ta_ctl (atg_tu_addr.md §3); used: [0] bilinear, [4] more passes follow, [5] not the first pass, [7:6] border colour class, [13] gather, [15:14] its component, [17] second slice, [18] second level, [21] row passes, [22] second row, [34:27] VkFormat, [35] stencil aspect, [47:36] swizzle, [48] second column, [49] four passes. |
| `tc_last` | in | 1 | Last. |
| `idle` | out | 1 | No quad in the unit (0 between the passes of a quad); atg_tu hands a pass of the 8-bit path only then. |
| **Return to the SU** | | | |
| `tr_valid` | out | 1 | The quad's result (after its last pass). |
| `tr_ready` | in | 1 | Taken. |
| `tr_tag` | out | 16 | Tag. |
| `tr_data` | out | 512 | 4 lanes × 4 × 32 bits (fp32, or the integer bits of an integer format), R first. |
| `tr_last` | out | 1 | Last. |

18 ports.

## 4. Behaviour

The reference is `tools/tumodel.py` `FFilter`, bit for bit.

- **Texels** of lane k from its slots: 1- to 4-byte texels: slots 0-3 are texels 0-3 ((i0, j0), (i1, j0), (i0, j1), (i1, j1)); 8-byte texels: texel 0 = {slot 1, slot 0}, texel 1 = {slot 3, slot 2} ((i0, j) and (i1, j) of the pass's row); 16-byte texels: texel 0 = {slots 3-0}; gather: slot t holds the word of texel t that has the component (`tu_gwi`), placed back at its word.
- **Blocks** (ETC2 and EAC, 8 or 16 bytes): an 8-byte block per texel as the 8-byte texels (texels 0 and 1 of a row pass), a 16-byte block per pass (tc_ctl[49]: the pass's texel {row, column tc_ctl[48]}); the texel's column and row in the block are bits 1:0 of the block's first and second slot address (`tc_lo`); `atg_tu_etc` decodes it: RGBA8 to UNORM (sRGB: R, G, B through `atg_srgb_dec`), R11 c / 2047, signed R11 max(c / 1023, −1).  Gather of blocks comes in the same passes (the footprint texel decides the word's place).
- **Conversion**: `atg_fmt_unpack(raw, VkFormat, stencil)`: UNORM and SNORM to the nearest fp32, the floats exactly (NaN 0x7FC00000), integers zero or sign extended, sRGB R, G, B to linear (before filtering) and A as UNORM, the stencil aspect (s, 0, 0, 1) as integers; a format without an entry (a value without the sampled feature, ctl format 0) (0, 0, 0, 1.0).  A **border texel** is the border colour in the format's components (class 0 transparent black (0, 0, 0, 0), 1 opaque black (0, 0, 0, 1), 2 opaque white (1, 1, 1, 1); 1.0, or the integer 1 for the integer formats and the stencil aspect; an sRGB format's border is linear) and (0, 0, 0, 1) in the others (Vulkan: the border colour replaces the components of the image format).
- **Weights**: texel t's integer weight is wu × wv × wa × wb: bilinear wu = 256 − fu (t = 0, 2) or fu (1, 3), wv = 256 − fv (0, 1) or fv (2, 3); row passes (tc_ctl[21]): texel 0 256 − fu, texel 1 fu, wv = 256 − fv in the first row and fv in the second, texels 2 and 3 none; without bilinear 65536 for texel 0; wa = fw or 256 − fw by tc_ctl[17], wb = fl or 256 − fl by tc_ctl[18].  As fp32 the weight is n × 2^-32 rounded to nearest even (n ≤ 2^32); a weight of 0 is skipped (an infinite texel with weight 0 does not make a NaN).
- **Accumulation**: per lane and component c below the format's component count, A = fma(w, x_c, A) with one rounding to nearest even and denormals flushed (`atg_su_ffma`, the SU's rules, `tools/gsi1fp.py` fma), from A = −0.0 at the quad's first pass; texels in the order 0-3, passes in order (mip linear and 3D linear: up to 4, with row passes up to 8).  The components the format does not have are (0, 0, 0, 1).
- **Bypass**: a lane with one texel of weight 1 (a quad of one pass without bilinear, or a bilinear lane with fu = fv = 0 in a quad of one pass) returns its converted texel as it is: nearest sampling, texf and the integer formats (always nearest) are exact, NaN payloads and denormals included.
- **Gather** (tc_ctl[13]): words 0-3 of the lane are the component of texels 2, 3, 1, 0 that the swizzle puts in place tc_ctl[15:14] (ZERO 0, ONE 1.0 or 1), from the converted texels or the border colour.
- **Swizzle** (tc_ctl[47:36]: R, G, B, A, 3 bits each: 0 IDENTITY, 1 ZERO, 2 ONE, 3-6 R, G, B, A, 7 as IDENTITY) last, ONE 1.0 or the integer 1; gather's words are not swizzled again.  Lanes outside tc_mask give 0.
- A pass with tc_ctl[4] (more to follow) returns nothing and keeps the sums; the last returns the quad.

## 5. State machine

IDLE →(tc_valid)→ LOAD (the pass's work: a mask of {texel, lane}; the quad's constants) → RUN (the steps) → DRAIN (until the pipeline is empty) → FIN (the 16 words, the swizzle, a lane a cycle) → OUT →(tr_ready)→ IDLE; a pass with more to follow goes from RUN back to IDLE, its steps still in the pipeline.

## 6. Latency and throughput

A step is one component of a lane's texel (a term), a bypassed lane's component or a gathered texel; the steps are issued one a cycle in the order texel, lane, component (the work mask skips masked lanes, texels of weight 0 and the texels of a pass that are not present without a cycle).  Pipeline: P1 (the texel's bits and border bit, the lane's weights), P2-P5 (atg_tu_etc, 4 cycles; the weight's factors 256 − f, wu × wv and wa × wb, n = wu wv wa wb, n × 2^-32 as fp32 in P7), P6 (the converter's inputs), P6-P13 (atg_fmt_cvt, 7 cycles), P13 (a bypassed or gathered value is written to its accumulator; a term enters atg_tu_fma, which reads the accumulator in its cycle 3 and writes it in its cycle 10).  A term is issued only 8 or more cycles after the last term of the same accumulator (a pass with fewer than 8 accumulators in turn waits: few lanes, few components); the order of the terms of one accumulator is the reference's (texels, passes).  Per pass 1 (LOAD) + the steps (+ the waits) cycles; the next pass is taken while the last one's steps are in the pipeline; a quad's last pass then waits for the pipeline (about 13 cycles after a bypass or gather, 23 after a term) and FIN (4).  Measured by `atg_tu_ffilt_tb` (cycles a quad keeps the unit, the TB's gaps not counted; before → after p038): nearest 14.6 → 28.4, bilinear 32.2 → 48.5, passes (2-8) 80.3 → 80.3, gather 24.0 → 34.0, border 14.5 → 28.2.  One quad at a time (atg_tu).

## 7. Corner cases and errors

- Integer formats and the stencil aspect never come bilinear or in several passes (atg_tu_addr: no FILTER_LINEAR); if they did, the integer bits would be multiplied as floats (no harm, not a valid use).
- A format whose value the GPU does not have reads (0, 0, 0, 1.0), whatever its texels.
- The −0.0 start keeps the sign of a zero sum of negative zeros; a sum of +0 and −0 terms is +0 (round to nearest even).

## 8. What the TB checks

`sim/tb/atg_tu_ffilt_tb.v` (vectors `sim/vec/tu_ffilt.txt` from `tools/tu-vectors.py`, `tools/tumodel.py` `FFilter`; random gaps and tr_ready) prints, in this order (each group over every sampled format of the path and format 0, random swizzles, masks and border texels):

- `PASS atg_tu_ffilt.nearest` — one pass, the converted texel
- `PASS atg_tu_ffilt.bilinear` — the formats with FILTER_LINEAR; 8-byte texels in two row passes
- `PASS atg_tu_ffilt.passes` — mip linear and 3D linear (2 to 8 passes): those with more to follow return nothing
- `PASS atg_tu_ffilt.gather` — the component through the swizzle, the word of 8- and 16-byte texels
- `PASS atg_tu_ffilt.border` — half the texels border texels, every colour class
- `PASS atg_tu_ffilt` at the end.

`-DMUT_FFILT_ROW` (the second row weighted as the first) fails `bilinear` and `passes`.  `tools/tu-vectors.py` first checks the model's bilinear result against plain floating point (within 2^-20 of the exact blend of the converted texels).  `sim/tb/atg_tu_tb.v` runs the path inside the whole TU.

## 9. References

docs/ghci.md §8.4, §8.5 (texture slots, conversions); `spec/gpu/fmt/atg_fmt.md`; design §16.11.  Values referenced: Vulkan specification, Texel Filtering, Border Replacement, Component Swizzle, VkComponentSwizzle, VkBorderColor.

## 10. Status

Implemented (2026-10-25).  Readings: one fused multiply-add per term (design §16.11 named an fmul and an fadd; the fused form rounds once per term and needs one unit); the weight is rounded once as n × 2^-32 (the 8-bit weights of atg_tu_addr, the same as the 8-bit path); the bypass of a single texel of weight 1.  The ETC2 and EAC decoder (`atg_tu_etc`) is in this path (2026-10-25); the vectors have every block format with random blocks and texel positions.

2026-10-25 (area): a block's texel (atg_tu_etc) is converted by the same atg_fmt_unpack as the other texels (atg_fmt_unpack_i with RGBA8's UNORM or sRGB table word, or EAC's two 11-bit UNORM components, the signed ones as their 10-bit magnitudes with the sign set), not by its own conversions; FIN takes the four lanes one a cycle (3 cycles more a quad).  The values are unchanged.

2026-10-25 (area, later): one component of the texel is converted a cycle (atg_fmt_comp: c, or gather's component), so a lane that returns its texel as it is (bypass) takes a cycle per component of the format (was one cycle for all four).  The values are unchanged.

2026-10-25 (p038, the pipeline): the steps issued in the order texel, lane, component (was lane, texel, component) through a pipeline (§6); the conversion is atg_fmt_cvt, the accumulation atg_tu_fma, the weight's fp32 three stages; all its arithmetic through rtl/common (the block decoder atg_tu_etc still has its own).  The values are unchanged (the TB, the mutation `-DMUT_FFILT_ROW` fails; a hazard window of 6 instead of 7 cycles fails).
