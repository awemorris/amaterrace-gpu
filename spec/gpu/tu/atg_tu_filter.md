# atg_tu_filter

RTL: `rtl/gpu/tu/atg_tu_filter.v`.  Parent: atg_tu.  Implemented in: p009.

## 1. Purpose and place

TU filtering: converts texels (RGBA8/BGRA8 UNORM, or raw integers for texf) to fp32 RGBA and blends nearest or bilinear per lane.

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
| `tc_wts` | in | 64 | As ta_wts. |
| `tc_tag` | in | 16 | Tag. |
| `tc_mask` | in | 4 | Lanes. |
| `tc_ctl` | in | 8 | As ta_ctl. |
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

- bilinear (tc_ctl[0]): R = (a (256 − fu) + b fu) (256 − fv) + (c (256 − fu) + d fu) fv;
- otherwise R = a × 65536 (texels 1-3 are not looked at);
- the word is R / (255 × 65536) as fp32: P = R × 0x0101010101, rounded to 24 significant bits to nearest even, times 2^-56 (0 for R = 0).  For R = a × 65536 this is exactly the correctly rounded a / 255 (as atg_vf_conv's and the ROP's UNORM8; checked for all 256 values by `tools/tu-vectors.py`), and 255 gives 1.0.

Lanes outside tc_mask give four zeros.  texsz (tc_ctl[2]): word 0 = the lane's tc_value word, words 1-3 = 0.  texf converts like the others (v1's formats are UNORM; §10).  tr_data lane l = bits [128 l +: 128], R first.

## 5. State machine

IDLE →(tc_valid)→ RUN (lanes 0-3, one per cycle) → OUT →(tr_ready)→ IDLE.

## 6. Latency and throughput

Target one quad per cycle.  v1: one lane (its four channels) per cycle, a quad in 4 cycles + 2 (p015).

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_tu_filter_tb.v` prints, in this order:

- `PASS atg_tu_filter.nearest` — nearest
- `PASS atg_tu_filter.bilinear` — bilinear against a C reference
- `PASS atg_tu_filter` at the end.

The reference is `tools/tumodel.py` (vectors `sim/vec/tu_filter.txt` from `tools/tu-vectors.py`): nearest = every byte value in every channel, both formats, texsz, texf, lane masks; bilinear = random texels and weights with the end values 0, 1, 128, 255.  Random gaps and tr_ready.

## 9. References

design §3.7 (TU_BILINEAR).

## 10. Status

Implemented in WS288 p009 part C (P1, branch p1-tu).  Readings: "raw integers for texf" (§1) is not done: v1's texture formats are UNORM only (SAMPLER[12]: RGBA8/BGRA8), and Vulkan's texelFetch on a UNORM image returns the normalised value, so texf converts like texl (tc_ctl[3] is passed but unused here).  An integer format (and returning raw integers for it) needs a format code in SAMPLER first.  One lane per cycle (§6).
