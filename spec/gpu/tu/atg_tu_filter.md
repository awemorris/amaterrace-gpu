# atg_tu_filter

RTL: `rtl/gpu/tu/atg_tu_filter.v`.  Parent: atg_tu.  Children (p038): atg_tu_fpre, four atg_tu_fsum, four atg_tu_frnd, atg_tu_fword, am_fifo.  Implemented in: p009.

## 1. Purpose and place

TU filtering: converts texels (RGBA8/BGRA8 UNORM, D24, D32F) to fp32 RGBA, compares depth texels with a compare sampler's reference, and blends nearest, bilinear and, over the passes of 3D linear and mip linear filtering, trilinear per lane.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **From atg_tu_cache** | | | |
| `tc_valid` | in | 1 | Texels of a quad. |
| `tc_ready` | out | 1 | Taken. |
| `tc_texels` | in | 512 | 4 lanes × 4 texels × 32 bits (raw). |
| `tc_wts` | in | 128 | As ta_wts: lane l = {fw, fl, fv, fu}. |
| `tc_tag` | in | 16 | Tag. |
| `tc_mask` | in | 4 | Lanes. |
| `tc_ctl` | in | 48 | As ta_ctl (atg_tu_addr.md §3). |
| `tc_value` | in | 128 | As ta_value. |
| `tc_last` | in | 1 | Last. |
| `idle` | out | 1 | No quad taken and not yet returned, no pass with more to follow pending; atg_tu hands a pass of the fp32 path only then. |
| **Return to the SU** | | | |
| `tr_valid` | out | 1 | Returned quad (in request order; the head of a FIFO of 4 quads). |
| `tr_ready` | in | 1 | Taken. |
| `tr_tag` | out | 16 | Tag. |
| `tr_data` | out | 512 | 4 lanes × RGBA fp32 (texsz: lane word 0 = {h, w}). |
| `tr_last` | out | 1 | Last. |

17 ports.

## 4. Behaviour

Bilinear: lerp(lerp(t00, t10, fu), lerp(t01, t11, fu), fv) per channel with 8-bit fractions; output x/255 as fp32.

Exactly (the reference is `tools/tumodel.py`, `filt_quad`): per lane and channel, with a, b, c, d the channel's bytes of texels 0-3 (RGBA8: bytes 0-3 are R, G, B, A; BGRA8, tc_ctl[1]: bytes 0 and 2 swapped) and fu, fv the lane's weights (tc_wts lane l = {fv, fu}):

- with a compare (tc_ctl[9]) the four channels' bytes of texel t are (255 if it passes else 0, 0, 0, 255): VkCompareOp tc_ctl[12:10] of Dref (the lane's tc_value word) against the texel's depth — D24 (tc_ctl[1] = 0): Dref to unorm24 (RNE of Dref × (2^24 − 1), NaN and ≤ 0 to 0, ≥ 1 to all ones) against bits 23:0 as integers; D32F: fp32 order keys (−0 = +0, denormals 0), a NaN on either side passes NOT_EQUAL and ALWAYS only (`include/atg_depth.vh`, shared with the ROP's depth test);
- bilinear (tc_ctl[0]): R = (a (256 − fu) + b fu) (256 − fv) + (c (256 − fu) + d fu) fv;
- otherwise R = a × 65536 (texels 1-3 are not looked at);
- **passes**: each adds R × W to the lane's sums A (the first, tc_ctl[5] = 0, starts them), W = (fw or 256 − fw) × (fl or 256 − fl) by the pass's slice bit tc_ctl[17] and level bit tc_ctl[18] (W = 2^16 for a quad of one pass); a pass with tc_ctl[4] (more follow) returns nothing (back to IDLE);
- the word of the last pass is A / (255 × 2^32) as fp32: P = A × 0x0101010101, rounded to 24 significant bits to nearest even, times 2^-72 (0 for A = 0).  For A = a × 2^32 this is exactly the correctly rounded a / 255 (as atg_vf_conv's and the ROP's UNORM8; checked for all 256 values by `tools/tu-vectors.py`), and 255 gives 1.0; one pass gives the same word as part C's R × 0x0101010101 × 2^-56.

A depth format without compare (tc_ctl[8], not [9]) returns texel 0 as (D, 0, 0, 1.0): D32F the word itself, D24 c / (2^24 − 1) of bits 23:0 as c × (2^48 + 2^24 + 1) rounded to nearest even times 2^-72 — the correctly rounded quotient for every c (checked for all 2^24 values once; `tools/tu-vectors.py` checks the ends and a sample).  **Gather** (tc_ctl[13]): the lane's words 0-3 are component tc_ctl[15:14] of texels 2, 3, 1, 0 ((i0, j1), (i1, j1), (i1, j0), (i0, j0)), each alone: UNORM a / 255 (BGRA8 swapped as above), a depth format's component 0 D (D32F the word, D24 as below), 1 and 2 0, 3 1.0; with compare 1.0 or 0.0.  Lanes outside tc_mask give four zeros.  texsz (tc_ctl[2]): word 0 = the lane's tc_value word, words 1-3 = 0; **texqlod** (tc_ctl[2] and [16]): word 0 = tc_value[15:0] / 256, word 1 = tc_value[31:16] / 256 (both signed, exact fp32), words 2-3 = 0.  texf converts like the others (§10).  tr_data lane l = bits [128 l +: 128], R first.

TEX_FORMAT's formats of this path (tc_ctl[34:27] the VkFormat, 0 for the earlier codes): R8_UNORM (9) and R8G8_UNORM (16) texels are taken as RGBA8 with the missing bytes 0 and alpha 255 (border texels too: the border colour replaces the format's components only, the others read (0, 0, 1)); D16_UNORM (124) compares the texel's bits 15:0 with Dref converted to 16-bit UNORM (`atg_fmt_f2unorm`: RNE of Dref × 65535, NaN and ≤ 0 to 0, ≥ 1 to all ones); X8_D24 and D24S8 as D24.  The component swizzle (tc_ctl[47:36], VkComponentSwizzle of R, G, B, A: 0 IDENTITY, 1 ZERO, 2 ONE (1.0), 3-6 R, G, B, A, 7 as IDENTITY) is applied last (after a compare); gather takes the component the swizzle puts in place tc_ctl[15:14] (ZERO and ONE: 0.0 and 1.0; DrefGather's results are not swizzled); texsz and texqlod are not swizzled.

## 5. State machine

IDLE →(tc_valid)→ RUN (lanes 0-3, one a cycle) → IDLE; the next pass is also taken in the cycle of lane 3 (RUN goes on).  A pass is taken only while the last passes taken whose quads are not yet returned are fewer than 4 (the FIFO's room).

## 6. Latency and throughput

4 cycles a pass, the passes back to back, the quads of the path overlapping in the pipeline.  Pipeline of 18 stages without stalls (cycle of the stage after the issue): P1 the lane's texels (RGB565, R8 and R8G8 as RGBA8), weights, Dref; P2 Dref × (2^24 − 1) and × (2^16 − 1), the shift amounts, the order keys, 256 − f; P3 the shifts, the bilinear weights (256 − fu or fu)(256 − fv or fv) and W (am_mul); P4 the roundings, Dref's key; P5 the compares and the channels' bytes; P7 the bytes × the weights (16 am_mul); P8-P9 R, their sum; P11 R × W (am_mul); the sums A are read in P10 (registered) and written in P11 (A of a lane in the next pass comes 4 or more cycles later); P13-P14 A × 257 × 65537 + A × 2^32 = A × 0x0101010101; P14 the conversion's integer (the sum, or the depth's, gather's, the LOD query's, RGB565's); P15 leading zeros, P16 shifted, P17 rounded (rnd81); P18 the lane's words (depth, gather, swizzle, the queries, the mask), written to the quad's place; the quad goes into the FIFO with lane 3.  A quad returns 4 + 18 cycles after its last pass is taken.  Streamed (`atg_tu_filter_tb`, random gaps and tr_ready): 3420 quads in 39,436 cycles before p038, 33,306 after.  All the arithmetic through rtl/common (am_add, am_sub, am_shift, am_mul, am_fifo).

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_tu_filter_tb.v` prints, in this order:

- `PASS atg_tu_filter.nearest` — nearest
- `PASS atg_tu_filter.bilinear` — bilinear against a C reference
- `PASS atg_tu_filter.trilinear` — 2 to 4 passes (mip linear, 3D linear, both): those with more to follow return nothing, the last the weighted sum (weights 0, 1, 128, 255 and random)
- `PASS atg_tu_filter.depth` — D24 and D32F without compare
- `PASS atg_tu_filter.compare` — every compare op on both depth formats, references at and next to the texels, NaN, nearest, bilinear and trilinear
- `PASS atg_tu_filter.gather` — the four texels' component: colour, depth, compare
- `PASS atg_tu_filter.query` — texqlod's two values, texsz.l's word
- `PASS atg_tu_filter.rgb565` — RGB565 (ctl[19]): texf exactly (R / 31, G / 63, B / 31, 1) for the 16-bit values, texl/texb/gather as RGBA8 of the replicated bits
- `PASS atg_tu_filter.vkformat` — TEX_FORMAT's formats of this path: R8 and R8G8 (texels and border texels), D16 compare, the swizzle after filtering and compare, gather through the swizzle
- `PASS atg_tu_filter` at the end.

The reference is `tools/tumodel.py` (vectors `sim/vec/tu_filter.txt` from `tools/tu-vectors.py`): nearest = every byte value in every channel, both formats, texsz, texf, lane masks; bilinear = random texels and weights with the end values 0, 1, 128, 255.  Passes go in as soon as they are taken (random gaps); tr_ready is random and sometimes low for 40 cycles (the FIFO full, the credits); the returns are checked in order, and a return without one expected fails (a pass with more to follow must return nothing).

## 9. References

design §3.7 (TU_BILINEAR).

## 10. Status

Implemented in WS288 p009 part C (P1, branch p1-tu); the compare, the depth formats and the mip linear blend in part E (P3).  Readings: a depth format without compare is nearest only (Vulkan leaves linear filtering of depth formats optional; compare results are filtered); the compare result is (r, 0, 0, 1).  "raw integers for texf" (§1) is not done: v1's texture formats are UNORM only (SAMPLER[12]: RGBA8/BGRA8), and Vulkan's texelFetch on a UNORM image returns the normalised value, so texf converts like texl (tc_ctl[3] is passed but unused here).  An integer format (and returning raw integers for it) needs a format code in SAMPLER first.  One lane per cycle (§6).

Part F (P3): the passes accumulate (sums of 40 bits a channel, the pass weight fw × fl), up to four (3D linear and mip linear); tc_wts 128 bits.

TEX_FORMAT (2026-10-25): tc_ctl 48 bits, R8 and R8G8, D16 compare, the swizzle (above); the other formats of TEX_FORMAT go to atg_tu_ffilt, the earlier codes are unchanged (the earlier vectors are kept).

RGB565 (the MSAA work): ctl[19]: texf converts exactly (c × sum(2^5i) × 2^-80, c × sum(2^6i) × 2^-78, both rounded to nearest even: never a tie, so the correctly rounded c / 31 and c / 63; `tools/tu-vectors.py` checks every c against fractions); the other operations take the texel as RGBA8 ((c << 3) | (c >> 2), (c << 2) | (c >> 4), alpha 255).

p038 (2026-10-25, the pipeline): §5, §6; the bilinear sum as the four bytes times their weights ((256 − fu)(256 − fv), fu (256 − fv), (256 − fu) fv, fu fv; the same integer); Dref's conversions and A × 0x0101010101 in stages through rtl/common; quads overlap (FIFO of 4, `idle` for atg_tu).  The values are unchanged.
