# atg_tu_filter

RTL: `rtl/gpu/tu/atg_tu_filter.v`.  Parent: atg_tu.  Implemented in: p009.

## 1. Purpose and place

TU filtering: converts texels (RGBA8/BGRA8 UNORM, D24, D32F) to fp32 RGBA, compares depth texels with a compare sampler's reference, and blends nearest, bilinear or (over the two passes of mip linear filtering) trilinear per lane.

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
| `tc_wts` | in | 96 | As ta_wts: lane l = {fl, fv, fu}. |
| `tc_tag` | in | 16 | Tag. |
| `tc_mask` | in | 4 | Lanes. |
| `tc_ctl` | in | 24 | As ta_ctl. |
| `tc_value` | in | 128 | As ta_value. |
| `tc_last` | in | 1 | Last. |
| **Return to the SU** | | | |
| `tr_valid` | out | 1 | Returned quad (in request order). |
| `tr_ready` | in | 1 | Taken. |
| `tr_tag` | out | 16 | Tag. |
| `tr_data` | out | 512 | 4 lanes × RGBA fp32 (texsz: lane word 0 = {h, w}). |
| `tr_last` | out | 1 | Last. |

16 ports.

## 4. Behaviour

Bilinear: lerp(lerp(t00, t10, fu), lerp(t01, t11, fu), fv) per channel with 8-bit fractions; output x/255 as fp32.

Exactly (the reference is `tools/tumodel.py`, `filt_quad`): per lane and channel, with a, b, c, d the channel's bytes of texels 0-3 (RGBA8: bytes 0-3 are R, G, B, A; BGRA8, tc_ctl[1]: bytes 0 and 2 swapped) and fu, fv the lane's weights (tc_wts lane l = {fv, fu}):

- with a compare (tc_ctl[9]) the four channels' bytes of texel t are (255 if it passes else 0, 0, 0, 255): VkCompareOp tc_ctl[12:10] of Dref (the lane's tc_value word) against the texel's depth — D24 (tc_ctl[1] = 0): Dref to unorm24 (RNE of Dref × (2^24 − 1), NaN and ≤ 0 to 0, ≥ 1 to all ones) against bits 23:0 as integers; D32F: fp32 order keys (−0 = +0, denormals 0), a NaN on either side passes NOT_EQUAL and ALWAYS only (`include/atg_depth.vh`, shared with the ROP's depth test);
- bilinear (tc_ctl[0]): R = (a (256 − fu) + b fu) (256 − fv) + (c (256 − fu) + d fu) fv;
- otherwise R = a × 65536 (texels 1-3 are not looked at);
- **mip linear**: a quad with tc_ctl[4] is the first level: its 16 sums R0 are kept and nothing is returned (back to IDLE).  The next quad, tc_ctl[5], is the second level: R' = R0 (256 − fl) + R1 fl.  Otherwise R' = R × 256;
- the word is R' / (255 × 2^24) as fp32: P = R' × 0x0101010101, rounded to 24 significant bits to nearest even, times 2^-64 (0 for R' = 0).  For R' = a × 2^24 this is exactly the correctly rounded a / 255 (as atg_vf_conv's and the ROP's UNORM8; checked for all 256 values by `tools/tu-vectors.py`), and 255 gives 1.0; R' = R × 256 gives the same word as part C's R × 0x0101010101 × 2^-56.

A depth format without compare (tc_ctl[8], not [9]) returns texel 0 as (D, 0, 0, 1.0): D32F the word itself, D24 c / (2^24 − 1) of bits 23:0 as c × (2^48 + 2^24 + 1) rounded to nearest even times 2^-72 — the correctly rounded quotient for every c (checked for all 2^24 values once; `tools/tu-vectors.py` checks the ends and a sample).  **Gather** (tc_ctl[13]): the lane's words 0-3 are component tc_ctl[15:14] of texels 2, 3, 1, 0 ((i0, j1), (i1, j1), (i1, j0), (i0, j0)), each alone: UNORM a / 255 (BGRA8 swapped as above), a depth format's component 0 D (D32F the word, D24 as below), 1 and 2 0, 3 1.0; with compare 1.0 or 0.0.  Lanes outside tc_mask give four zeros.  texsz (tc_ctl[2]): word 0 = the lane's tc_value word, words 1-3 = 0; **texqlod** (tc_ctl[2] and [16]): word 0 = tc_value[15:0] / 256, word 1 = tc_value[31:16] / 256 (both signed, exact fp32), words 2-3 = 0.  texf converts like the others (§10).  tr_data lane l = bits [128 l +: 128], R first.

## 5. State machine

IDLE →(tc_valid)→ RUN (lanes 0-3, one per cycle) → OUT →(tr_ready)→ IDLE; a first level (tc_ctl[4]) goes from RUN to IDLE.

## 6. Latency and throughput

Target one quad per cycle.  v1: one lane (its four channels) per cycle, a quad in 4 cycles + 2 (p015).

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_tu_filter_tb.v` prints, in this order:

- `PASS atg_tu_filter.nearest` — nearest
- `PASS atg_tu_filter.bilinear` — bilinear against a C reference
- `PASS atg_tu_filter.trilinear` — pairs of passes: the first returns nothing, the second the blend (weights 0, 1, 128, 255 and random)
- `PASS atg_tu_filter.depth` — D24 and D32F without compare
- `PASS atg_tu_filter.compare` — every compare op on both depth formats, references at and next to the texels, NaN, nearest, bilinear and trilinear
- `PASS atg_tu_filter.gather` — the four texels' component: colour, depth, compare
- `PASS atg_tu_filter.query` — texqlod's two values, texsz.l's word
- `PASS atg_tu_filter` at the end.

The reference is `tools/tumodel.py` (vectors `sim/vec/tu_filter.txt` from `tools/tu-vectors.py`): nearest = every byte value in every channel, both formats, texsz, texf, lane masks; bilinear = random texels and weights with the end values 0, 1, 128, 255.  Random gaps and tr_ready.

## 9. References

design §3.7 (TU_BILINEAR).

## 10. Status

Implemented in WS288 p009 part C (P1, branch p1-tu); the compare, the depth formats and the mip linear blend in part E (P3).  Readings: a depth format without compare is nearest only (Vulkan leaves linear filtering of depth formats optional; compare results are filtered); the compare result is (r, 0, 0, 1).  "raw integers for texf" (§1) is not done: v1's texture formats are UNORM only (SAMPLER[12]: RGBA8/BGRA8), and Vulkan's texelFetch on a UNORM image returns the normalised value, so texf converts like texl (tc_ctl[3] is passed but unused here).  An integer format (and returning raw integers for it) needs a format code in SAMPLER first.  One lane per cycle (§6).
