# atg_tu_addr

RTL: `rtl/gpu/tu/atg_tu_addr.v`.  Parent: atg_tu.  Implemented in: p009.

## 1. Purpose and place

TU addressing: per quad, the slot's descriptor, level of detail (texl explicit, texb from the quad derivatives + bias, texf level), mip selection and the passes of mip linear and 3D linear filtering, the layer (2D array), the slice (3D), the face (cube), wrap on integer texel coordinates after the texel offsets, clamp to border, cube edges, bilinear footprint, texel byte addresses (linear or 4×4 tiled; texels of 1-16 bytes), the path of the quad's format (the 8-bit filter or the fp32 filter), the reference of a compare sampler, and texsz.

Children: `atg_tu_desc` (the descriptors and their level offsets), `atg_tu_cube` (cube faces and face coordinates), `atg_tu_lod` (texb's quad LOD, combinational), `atg_tu_foot` (a lane's footprint and addresses, combinational), `atg_tu_lsel` (a lane's λ and level, combinational).

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **STATE broadcast (from atg_cp_state)** | | | |
| `st_we` | in | 1 | One-cycle write of STATE[st_idx]. |
| `st_idx` | in | 10 | STATE index (design §2.3). |
| `st_wdata` | in | 32 | STATE value; the block keeps the words of its range. |
| `desc_busy` | out | 1 | atg_tu_desc computes level offsets (part of STATUS.TU_BUSY). |
| **Requests from the SU (atg_su tx_*/tr_*)** | | | |
| `tx_valid` | in | 1 | Quad. |
| `tx_ready` | out | 1 | Taken (IDLE and desc_busy low). |
| `tx_op` | in | 8 | [1:0] 0 texl, 1 texb, 2 texf, 3 texsz; modifiers (the uop's TEX op bits): [2] .c form, [3] gather (texl) or the depth query (texsz.d), [5:4] gather's component, [6] query (texb: texqlod; texsz: texsz.l), [7] 0. |
| `tx_slot` | in | 4 | Slot. |
| `tx_vs` | in | 1 | The vertex stage's slots (atg_tu_desc's slots 16-31). |
| `tx_mask` | in | 4 | Lanes. |
| `tx_coord` | in | 640 | 4 lanes × {u (or x), v (or y), lod/bias/level, Dref (.c forms, else 0), the third coordinate (.3 forms: layer, w, cube z; else 0)} × 32 bits, lane 0 first. |
| `tx_off` | in | 12 | The texel offsets {dw, dv, du}, signed 4 bits each. |
| `tx_tag` | in | 16 | Tag. |
| `tx_last` | in | 1 | Last. |
| **To atg_tu_cache** | | | |
| `ta_valid` | out | 1 | A quad's texel addresses (one pass). |
| `ta_ready` | in | 1 | Taken. |
| `ta_addr` | out | 512 | 4 lanes × 4 slots × 32-bit byte address (nearest: four times texel 0; the slots of 8- and 16-byte texels and of gather: §4). |
| `ta_bord` | out | 16 | 4 lanes × 4 slots: the slot is a border texel (clamp to border). |
| `ta_wts` | out | 128 | 4 lanes × {fw, fl, fv, fu} 8-bit weights: the bilinear fractions, the weight of the second level (mip linear) and of the second slice (3D linear). |
| `ta_tag` | out | 16 | Tag. |
| `ta_mask` | out | 4 | Lanes. |
| `ta_ctl` | out | 50 | [0] bilinear, [1] format bit (0 RGBA8 / D24 / D16, 1 BGRA8 / D32F), [2] no fetch (texsz, texqlod), [3] integer (texf), [4] a later pass follows, [5] not the first pass, [7:6] border colour class (0 transparent black, 1 opaque black, 2 opaque white), [8] depth format, [9] compare, [12:10] compare op, [13] gather, [15:14] its component, [16] texqlod, [17] the pass's second slice, [18] the pass's second level, [19] the earlier RGB565 code, [20] the fp32 path (atg_tu_ffilt), [21] row passes (8-byte bilinear), [22] the pass's second row, [24:23] texel size for the cache (0 a word, 1 two bytes, 2 one byte), [26:25] slots without bilinear (0 one, 1 two: 8-byte texels, 2 four: 16-byte texels), [34:27] the VkFormat (0: the earlier codes or a value without the sampled feature), [35] the stencil aspect, [47:36] the swizzle (TEX_FORMAT[20:9]), [48] the pass's second column, [49] four passes (16-byte blocks). |
| `ta_value` | out | 128 | Per lane: texsz {h, w}; texsz.l the level count; texsz.d the layer count or depth; texqlod {λ'[15:0], the level accessed [15:0]} (8 fraction bits); compare the reference Dref (word 3). |
| `ta_last` | out | 1 | Last. |

26 ports.

## 4. Behaviour

The numbers, bit for bit (the reference is `tools/tumodel.py`, `quad_addr`; the shared functions are in `include/atg_tu_fn.vh`):

- **Descriptor** (STATE 0x090 + 16s, docs/ghci.md §8.4; atg_tu_desc): BASE, SIZE (w = [15:0], h = [31:16]; 0 reads as 1), IMAGE ([3:0] levels: 0 reads as 1, above 13 as 13; [7:4] format 0 RGBA8, 1 BGRA8, 2 D24, 3 D32F, 4-15 as 0; [8] tiled; [11:9] view type 0 2D, 1 2D array, 2 3D, 3 cube, 4-7 as 2D; [15:12] reserved (samples); [31:16] count, 0 as 1), LAYER_STRIDE, SAMPLER (wrap u [1:0], v [3:2], w [5:4]; mag [6], min [7], mip [8] linear; compare [9], op [12:10]; border colour [15:13]; unnormalized [16]; mipLodBias [31:19] signed 5.8), LOD (minLod [11:0], 15.996 − maxLod [23:12], unsigned 4.8).  The level offsets O_l come from atg_tu_desc.
- **Unnormalized coordinates** (SAMPLER[16]): the view type reads as 2D, λ' = λ = 0, mip linear off, repeat and mirrored repeat read as clamp to edge, the texel coordinates are floor(x × 256) of u and v clamped to [−2^28, 2^28].
- **Format** (TEX_FORMAT, docs/ghci.md §8.5; the class is `include/atg_tu_fmt.vh` tu_fcls): TEX_FORMAT[7:0] = 0 keeps the earlier codes of TEX_IMAGE[7:4] exactly as before; otherwise the VkFormat: its texel size ps (1, 2, 4, 8, 16 bytes), depth (a depth format, not the stencil aspect), the stencil aspect (TEX_FORMAT[8] with D24_UNORM_S8_UINT), FILTER_LINEAR; a value without the sampled feature reads as no format (4-byte texels, the fp32 path with format 0: (0, 0, 0, 1)).  Tiles only with 4-byte texels and the earlier RGB565 (TEX_IMAGE[8] reads as linear otherwise).
- **Quad mode**: compare = depth, SAMPLER[9], texl/texb and not texqlod; filtering is allowed, for the earlier codes, unless a depth format without compare, and for TEX_FORMAT's formats with the FILTER_LINEAR feature or a compare (the depth formats are filtered with and without compare; integer formats and the stencil aspect never); without it mag, min and mip linear read as 0; mip linear = allowed, not gather, not unnormalized, SAMPLER[8].  The fp32 path (ta_ctl[20]) = a TEX_FORMAT format other than R8G8B8A8, B8G8R8A8, A8B8G8R8, R8, R8G8 UNORM, without compare, not a query.
- **Cube** (view type 3, a texl or texb that samples, gather included): before the lanes, atg_tu_cube computes each lane's face and face coordinates (s, t, 24 fraction bits) from (word 0, word 1, word 4); texb and texqlod also project lanes 1 and 2 on lane 0's face (for the LOD).  They are kept for every pass.
- **LOD λ**: signed, 8 fraction bits, saturated to [−32768, 32767].  `fx(x, k)` = floor(x × 2^k) saturated to 32 bits (zero, denormals and NaN 0; infinities saturate).  texl: sat(fx(lod, 8)).  texb: the quad's λq (atg_tu_lod: u, v, and w of a 3D image, or a cube's face coordinates on lane 0's face); each lane λ = sat(λq + sat(fx(bias, 8))).  texqlod: λq.  Then λ' = sat(that + mipLodBias), λ = max(min(λ', maxLod), minLod).
- **Level and filter**: λ > 0: minification, filter SAMPLER[7]; mip nearest: level (λ + 127) >> 8 clamped to LEVELS − 1; mip linear: d = λ >> 8; d ≥ LEVELS − 1: level LEVELS − 1 alone (fl = 0), else level d in the first passes and d + 1 in the second with fl = λ & 255.  λ ≤ 0: magnification, SAMPLER[6], level 0, fl = 0.  Gather: level 0, bilinear.  Level size w_l = max(1, w >> l), h_l likewise (a cube: h_l = w_l), d_l = max(1, count >> l) for 3D (else 1).
- **Texel coordinates** (8 fraction bits, floor): the normalized coordinate's `tu_coord` (repeat floor(u × 2^24) mod 2^24, mirrored repeat mod 2^25, clamp to edge and border floor(u × 2^24) clamped to [−16, 17] × 2^24; zero, denormals, NaN 0; infinities 0 or the ends) × the level size >> 16; a cube's s, t × w_l >> 16; unnormalized as above.  w of a 3D image with wrap w and d_l.
- **Layer**: a 2D array: clamp(RNE(word 4), 0, count − 1) (NaN, zeros, negative 0); texf: word 4 as an integer clamped (an array: count − 1, a cube: 5); otherwise 0.  Level base = BASE + layer × LAYER_STRIDE + O_level.
- **Footprint** (atg_tu_foot): nearest i = (cu >> 8) + du; bilinear cu − 128, i0 = its integer part + du, i1 = i0 + 1, fu its low 8 bits; j, v alike.  3D: the slice nearest (cw >> 8) + dw, or (linear, not gather) ((cw − 128) >> 8) + dw plus 1 in the second-slice passes, fw = the low 8 bits.  Each index into the level by its mode: repeat i mod n, mirrored repeat (n − 1) − mirror((i mod 2n) − n), clamp to edge clamp, clamp to border clamp and a **border texel** (bit 0 of the address) when outside.  A cube: nearest clamps; bilinear takes a texel past one edge from the adjacent face (the table of tools/tumodel.py CUBE_ADJ) and replaces a corner texel by the face's own corner texel; offsets are ignored.  texf: x + du, y + dv (z + dw for 3D) clamped into the level.  Texels 0-3 = (i0, j0), (i1, j0), (i0, j1), (i1, j1).
- **Address** (ps bytes a texel, 32-bit wrap): level base + k × P_level (+ face × LAYER_STRIDE for a cube) + the texel in the plane: linear (j × w_l + i) × ps; tiled (4 bytes) (j / 4) × ceil(w_l / 4) × 64 + (i / 4) × 64 + ((j % 4) × 4 + i % 4) × 4 (the earlier RGB565: 32-byte tiles of 2 bytes); a border texel's slot has its ta_bord bit set.
- **Blocks** (ETC2 and EAC, the FMT capability reports them: VkFormat 147-156): 8- or 16-byte 4 × 4 blocks, never tiled; the block of texel (i, j) at the level base + ((j / 4) × ceil(w_l / 4) + i / 4) × bb, the plane ceil(w_l / 4) × ceil(h_l / 4) × bb rounded to 64; the slots as the 8- and 16-byte texels', with i mod 4 in address bits 1:0 of the block's first slot and j mod 4 in its second.  Bilinear and gather of 8-byte blocks: the row passes; of 16-byte blocks: four passes per slice and level (row, column: ta_ctl[22], [48], with [49]); up to 16 passes.
- **Slots** (the four of a lane): 1- to 4-byte texels: texels 0-3; gather on the fp32 path: texel t's address plus 4 × the word of the texel that holds the component after the swizzle (tu_gwi; 0 below 8 bytes); 8-byte texels: the two words of (i0, j) and of (i1, j), j = j0, or j1 in the pass's second row; 16-byte texels: the four words of texel 0.
- **Passes**: pass 0; pass 1 (the second slice at the first level) when a lane of tx_mask has fw ≠ 0; pass 2 (the second level) when one has fl ≠ 0; pass 3 (both) after pass 2 when one has fw ≠ 0 there.  On the fp32 path with 8-byte texels and a bilinear lane (not gather; ta_ctl[21]) each of them is done twice, row j0 and then row j1 (ta_ctl[22]): up to 8 passes.  ta_ctl[4] on a pass with a later one, [5] on all but the first, [17] on passes 1 and 3, [18] on 2 and 3.  ta_wts lane l = {fw of this pass's level, fl, fv, fu}.
- **texsz**: the level is word 0 of the lane (unsigned, clamped to 15); ta_value {max(1, h >> level), max(1, w >> level)}; texsz.l the level count; texsz.d a 2D array's count, a 3D level's depth, else 1; no address (0).  **texqlod**: no fetch; ta_value {λ'[15:0], clamp(λ, 0, (LEVELS − 1) × 256)}.
- **ta_ctl[0]** = some lane of tx_mask is bilinear (the cache then fetches texels 1-3); **ta_value** of a compare quad: word 3 (Dref).

## 5. State machine

IDLE →(tx_valid, desc not busy)→ [CUBE ⇄ CWAIT (one atg_tu_cube run per job: lane 0, with the LOD lanes 1 and 2 on lane 0's face, then lanes 1-3)] → [LOD (texb)] → LA (lane k: λ, level, sizes, texel coordinates, layer, level base) → LB (lane k: footprint, addresses, weights) → LA … (lanes 0-3) → OUT →(ta_ready)→ IDLE, or LA (the next pass).  One state machine; the children atg_tu_desc and atg_tu_cube have their own.

## 6. Latency and throughput

Target one quad per cycle.  v1: 2 cycles per lane, 9 cycles per quad (10 for texb) plus the handshake, for each pass (up to 4); a cube quad adds about 28 cycles per atg_tu_cube run (4 runs, 6 for texb); one quad at a time (p015, the performance Phase, pipelines it).

## 7. Corner cases and errors

- Masked lanes are computed like the others (from whatever their coordinates hold) and the cache does not fetch them.
- texb's derivatives use lanes 0-2 whatever the mask (helper lanes are in EXEC, design §3.1).
- A STATE write of the TU range while a quad is inside would change it under the quad: atg_cp_seq holds such a SET_REG while the TU, the RX or the SUs are busy; a quad waits while atg_tu_desc computes (tx_ready low).
- The integer wrap of repeat and mirrored repeat needs the index within 9 texels of [0, n) (or [0, 2n)): it is, since the normalized coordinate is first taken modulo the period and the offsets are −8..7.

## 8. What the TB checks

`sim/tb/atg_tu_addr_tb.v` prints, in this order:

- `PASS atg_tu_addr.wrap` — wrap modes on random coordinates (texl, texf and texsz on random linear and tiled descriptors, special values: ±0, denormals, ±1, infinities, NaN, huge)
- `PASS atg_tu_addr.lod` — texb LOD from derivatives (derivatives 2^-14..2^3, biases, level counts 0-15)
- `PASS atg_tu_addr.tile` — tiled addresses
- `PASS atg_tu_addr.trilinear` — mip linear: both levels, the weight, one pass when no lane needs two
- `PASS atg_tu_addr.border` — clamp to border: border texels (ta_bord), border colour classes
- `PASS atg_tu_addr.compare` — depth formats with and without compare, every op: the reference (word 3), no filter without compare
- `PASS atg_tu_addr.lodclamp` — minLod, maxLod, mipLodBias on texl and texb, mip nearest and linear
- `PASS atg_tu_addr.gather` — every component, DrefGather, depth, border: the level-0 footprint
- `PASS atg_tu_addr.query` — texqlod's level and λ', texsz.l's level count, texsz.d
- `PASS atg_tu_addr.layout` — the level offsets of atg_tu_desc: texf at every level of 2D (linear, tiled), array and 3D images, the slot written just before the quad
- `PASS atg_tu_addr.array` — the layer (RNE ties, clamps, NaN), the layer stride; texl, texb, gather, compare, texf, texsz.d
- `PASS atg_tu_addr.volume` — 3D: the slice, the four passes of 3D and mip linear filtering, w's address mode, texb's w derivative, texf, gather, offsets
- `PASS atg_tu_addr.cube` — the face (ties, zeros, infinities, NaN), the face coordinates, edges and corners, texb's LOD on lane 0's face, gather, compare, texqlod, texf as 6 layers
- `PASS atg_tu_addr.offset` — texel offsets on texl, texb, texf and gather with every address mode, levels of 1-17 texels
- `PASS atg_tu_addr.unnorm` — unnormalized coordinates: every op and view type, every address mode
- `PASS atg_tu_addr.ms` — multisampled images (texf: the sample mod 4, rows of roundup(w, 2) × 4 texels, 2D and arrays, odd widths; texsz.s, texsz) and RGB565 (texf linear and tiled with levels, texl, texb); `-DMUT_TU_MSROW` fails it
- `PASS atg_tu_addr.formats` — TEX_FORMAT: random sampled formats (and values without the feature) and swizzles on every view type and op, the fp32 path's fields, gather's word
- `PASS atg_tu_addr.wide` — 8- and 16-byte texels: the slots, the row passes with 3D and mip linear filtering; `-DMUT_TU_ROW` (the second row read as the first) fails it and `formats`
- `PASS atg_tu_addr.depthfmt` — D16, X8_D24, D32F, D24S8 with and without compare (linear filtering without compare), the stencil aspect
- `PASS atg_tu_addr.small` — 1- and 2-byte texels on small images with clamp to border, the tiled bit read as linear
- `PASS atg_tu_addr.stage` — the vertex stage's 16 slots (STATE 0x200-0x2FF, tx_vs) beside the fragment stage's
- `PASS atg_tu_addr.blocks` — the ETC2 and EAC formats: block addresses and texel positions, the row and four-pass sequences with mip and 3D linear, gather, arrays and cubes
- `PASS atg_tu_addr.rows` — TEX_ROW: first a 5 × 3 RGBA8 image of three levels with even rows (texf of each level's last column: rows of 6, 2 and 2 texels, levels at 0, 128 and 192), then random slots of both stages with rows of w_l rounded up to 2, 4 or 8 texels on every view type, odd widths, texels of 1-16 bytes and every op; tiled, compressed and multisampled slots with TEX_ROW set keep their rows.  `-DMUT_TU_PITCH` (atg_tu_foot's packed rows) and `-DMUT_TU_PITCHOFF` (atg_tu_desc's planes of packed rows) fail it alone
- `PASS atg_tu_addr` at the end.

Vectors: `sim/vec/tu_addr.txt` from `tools/tu-vectors.py` (about 10000 quads, 6200 outputs, 1 to 4 passes), random gaps and ta_ready.  `tools/tu-vectors.py` also checks the model against plain floating point first (the cube's face coordinates, the footprint's texels next to the direction across faces, the integer wrap with offsets against Vulkan's formulas on u × size, the layer against round-half-even) and the rows of TEX_ROW against the layout written out plainly (levels back to back, planes of rows of roundup(w_l, 2^n) texels rounded up to 64 bytes).

## 9. References

design §2.3 (TU STATE), §3.7 (limits), atg_blt's tile layout, docs/ghci.md §8.4 and §12.9.

## 10. Status

Implemented in WS288 p009 part C (P1, branch p1-tu); mip linear, clamp to border, depth formats and compare in part E (P3, branch p3-p009e); the descriptor of docs/ghci.md §8.4 (image and sampler words, the level offsets computed by atg_tu_desc), 2D arrays, 3D images, cube maps, texel offsets and unnormalized coordinates in part F (P3, branch p3-p009f).  Readings (to confirm with Q1):

1. Part C/E readings kept: mip linear in passes through the cache and the filter; a lane with weight 0 in a later pass is fetched again (cache hits) rather than masked; the border colour is chosen in the cache (address bit 0); Dref is word 3; a depth format without compare is nearest only; compare on a colour format is ignored; mipLodBias is not clamped to maxSamplerLodBias; minLod wins when minLod > maxLod; the gather level is 0; texqlod returns (level, λ') as GLSL does (Vulkan-Docs issue 2383); texsz takes the level from word 0; texf's out-of-range coordinates, level and layer are clamped.
2. Part F: **the wrap moved to integer texel coordinates** (Vulkan's formulas, after the offsets); the normalized coordinate is only taken modulo the period (repeat 1, mirrored repeat 2) or clamped to [−16, 17] before × size.  Repeat, clamp to edge and border give the part-E texels; **mirrored repeat differs from part E in the last bits** (part E reflected the normalized coordinate before × size: at exact texel boundaries the index, and the bilinear weights everywhere past the mirror, now follow the unwrapped coordinate, as Vulkan's integer formula does).
3. Part F: **cube corner texels**: a texel past two edges is the face's own corner texel (Vulkan: the corner texel "should be replaced by the average of the three values of the adjacent texels in each incident face. However, implementations may replace the cube map corner texel by other methods", keeping three equal texels' value); faces are squares of the width; texb's derivatives project lanes 1 and 2 on lane 0's face (atg_tu_cube clamps the ratio to [−3, 3]); offsets and the address modes are ignored on cubes; texf on a cube reads it as 6 layers.
4. Part F: 3D linear filtering in two passes per level (8 texels a lane do not fit the 4-texel port; the filter accumulates the passes with the weights fw × fl); gather on a 3D image takes the nearest slice of level 0 (Vulkan does not allow it).
5. Reserved for multisampled images (the MSAA Phase, p027): TEX_IMAGE[15:12] = log2(samples) (0 one sample, 2 four, others reserved), not looked at now; texf's address stage is to take x' = x × S + s (s from rs2, whose level meaning a multisampled image, with one level, does not need) and rows of roundup(w, 2) × S texels — only samples = 0 is taken now.  Also reserved for it: format 4 (RGB565; read as RGBA8 now) and texsz's immediate 3 (`texsz.s`, the sample count; an ISA fault in atg_su_dec now).  Part F uses no new CAPS bit (CAPS[26] says the whole of docs/ghci.md §8.4; CAPS[29] is kept for MS4).

Multisampling and RGB565 (the MSAA work, docs/ghci.md §8.4, §12.11): TEX_IMAGE[15:12] = 2 (and linear) makes texf's rs2 the sample (level 0); format 4 (RGB565) has 2-byte texels (ta_ctl[19]); texsz.s (op 0x4B) gives the sample count; texsz.l and texsz.d now look at op[6] and op[3] alone.  `atg_tu_foot` takes ms, smp.

TEX_FORMAT (Vulkan 1.0's formats, docs/ghci.md §8.5, CAPS[30]; 2026-10-25): the class of the format, texels of 1-16 bytes, the fp32 path, the slots of 8- and 16-byte texels and the row passes, gather's word; the border bit moved from address bit 0 to ta_bord (1-byte texels use every address bit); ta_ctl widened to 48 bits.  The earlier codes (TEX_FORMAT[7:0] = 0) give the same outputs as before (the earlier vectors are kept; only the border bit moved).  Readings: the depth formats of TEX_FORMAT are filtered without compare (they have FILTER_LINEAR in the FMT capability), the earlier codes keep nearest; a format without FILTER_LINEAR samples nearest whatever the sampler asks (Vulkan does not allow it); a value without the sampled feature reads (0, 0, 0, 1).

TEX_ROW (2026-10-25, docs/ghci.md §8.4 word +7): atg_tu_desc keeps TEX_ROW[1:0] (rd_row, 0 for tiled, compressed and multisampled slots) and computes the planes and level offsets of rows of w_l rounded up to a multiple of 2^n texels; atg_tu_foot (`ra`) addresses those rows.  The firmware sets 1 for an image that may be an attachment (the render output's even rows), so an odd-width attachment is read as it was written.  Vectors of word +7 = 0 are those of before (the reserved word +7 that the earlier vectors wrote at random is now written 0; their quads and outputs are unchanged).

2026-10-25 (area): texb's LOD state takes three cycles (atg_tu_lod an axis a cycle, the largest kept), was one; the results are unchanged.
