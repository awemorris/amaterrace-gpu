# atg_tu_addr

RTL: `rtl/gpu/tu/atg_tu_addr.v`.  Parent: atg_tu.  Implemented in: p009.

## 1. Purpose and place

TU addressing: per quad, the slot's descriptor (STATE 16s+0..15), level of detail (texl explicit, texb from the quad derivatives + bias, texf level), mip selection (nearest, or the two levels of mip linear filtering in two passes), wrap modes and clamp to border, bilinear footprint, texel byte addresses (linear or 4×4 tiled), the reference of a compare sampler, and texsz.

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
| `st_idx` | in | 9 | STATE index (design §2.3). |
| `st_wdata` | in | 32 | STATE value; the block keeps the words of its range. |
| **Requests from the SU (atg_su tx_*/tr_*)** | | | |
| `tx_valid` | in | 1 | Quad. |
| `tx_ready` | out | 1 | Taken. |
| `tx_op` | in | 2 | 0 texl, 1 texb, 2 texf, 3 texsz. |
| `tx_slot` | in | 4 | Slot. |
| `tx_mask` | in | 4 | Lanes. |
| `tx_coord` | in | 384 | Coordinates. |
| `tx_tag` | in | 16 | Tag. |
| `tx_last` | in | 1 | Last. |
| **To atg_tu_cache** | | | |
| `ta_valid` | out | 1 | A quad's texel addresses. |
| `ta_ready` | in | 1 | Taken. |
| `ta_addr` | out | 512 | 4 lanes × 4 texels × 32-bit byte address (nearest: texel 0 only). |
| `ta_wts` | out | 96 | 4 lanes × {fl, fv, fu} 8-bit weights: bilinear fractions and the weight of the second mip level. |
| `ta_tag` | out | 16 | Tag. |
| `ta_mask` | out | 4 | Lanes. |
| `ta_ctl` | out | 16 | [0] bilinear, [1] format low bit (0 RGBA8 / D24, 1 BGRA8 / D32F), [2] texsz (no fetch), [3] integer (texf), [4] the first level of a mip linear pair (another pass follows), [5] the second level, [7:6] border colour class (0 transparent black, 1 opaque black, 2 opaque white), [8] depth format, [9] compare, [12:10] compare op, [15:13] 0. |
| `ta_value` | out | 128 | texsz: the per-lane {h, w} words; compare: the per-lane reference Dref (rs2). |
| `ta_last` | out | 1 | Last. |

22 ports.

## 4. Behaviour

Formats RGBA8/BGRA8, D24, D32F (SAMPLER {[14], [12]}).  Wrap: repeat, mirrored repeat, clamp to edge, clamp to border (2 bits each).  LOD from the quad's du/dv (max of the axes, log2 on the exponent).  Tiled layout of design §2.3 / atg_blt (4×4).

The numbers, bit for bit (the reference is `tools/tumodel.py`, `quad_addr`):

- **Descriptor** (STATE 0x090 + 16s, docs/ghci.md §8.4): BASE, SIZE (w = [15:0], h = [31:16]; 0 reads as 1), LEVELS[3:0] (0 reads as 1, above 13 as 13), SAMPLER (wrap u [1:0], wrap v [3:2], mag linear [4], min linear [5], mip linear [6], compare [7], compare op [10:8], format {[14], [12]} 0 RGBA8 / 1 BGRA8 / 2 D24 / 3 D32F, **[13] 4×4 tiled**, border colour [18:16] VkBorderColor), MIP_OFFSET[1..12] (words 4-15).  The block keeps all 256 words.
- **Quad mode**: depth = SAMPLER[14]; compare = depth, SAMPLER[7] and texl/texb; filtering is allowed unless a depth format without compare (then mag, min and mip linear read as 0); mip linear = allowed and SAMPLER[6].
- **LOD λ**: signed, 8 fraction bits, saturated to [−32768, 32767].  `fx(x, k)` = floor(x × 2^k) saturated to 32 bits (zero, denormals and NaN 0; infinities saturate).  texl: λ = sat(fx(lod, 8)).  texb: the quad's λq from lanes 0, 1 (x + 1) and 2 (y + 1): U = fx(u, 16), V = fx(v, 16) per lane, mu = max(|U1 − U0|, |U2 − U0|), mv likewise; λu = L2(mu) + L2(w) − 4096 (L2(x) = 256 × msb position + the 8 bits below the msb), λv with h; λq = max(λu, λv), −32768 for a zero; each lane λ = sat(λq + sat(fx(bias, 8))).
- **Compare**: λ = 0 for texl and λq (no bias) for texb; rs2 is the reference, on ta_value.
- **Level and filter**: λ > 0: minification, filter SAMPLER[5]; mip nearest: level (λ + 127) >> 8 clamped to LEVELS − 1 (Vulkan's nearest mip, ceil(λ + 0.5) − 1); mip linear: d = λ >> 8; d ≥ LEVELS − 1: level LEVELS − 1 alone (fl = 0), else level d in pass 0 and d + 1 in pass 1 with fl = λ & 255.  λ ≤ 0: magnification, SAMPLER[4], level 0, fl = 0.  Level size max(1, w >> level) × max(1, h >> level); level base BASE + MIP_OFFSET[level] (BASE at level 0).
- **Passes**: pass 0 always; if some lane of tx_mask has fl ≠ 0 (texl, texb), ta_ctl[4] is set and, after it is taken, pass 1 goes out with the same lanes recomputed at their second level (lanes with fl = 0 at their only level) and ta_ctl[5].  ta_wts lane l = {fl, fv, fu} in both passes.
- **Wrap** on the normalised coordinate, to f with 24 fraction bits: repeat floor(u × 2^24) mod 2^24; mirrored repeat t = floor(u × 2^24) mod 2^25, f = t or 2^25 − t when t ≥ 2^24; clamp to edge 0 for u < 0, 2^24 for u ≥ 1, else floor(u × 2^24); clamp to border floor(u × 2^24) clamped to [−2^24, 2^25] (u in [−1, 2]: any u beyond is as far outside the level).  Zero, denormals, NaN and infinities (repeat, mirror) give 0; infinities of clamp to border the ends.  Then c = f × size >> 16 (texel units, 8 fraction bits, floor).
- **Back into the level**: repeat −1 → size − 1, size → 0; mirrored repeat and clamp to edge clamp to [0, size − 1]; clamp to border clamps too and marks the texel a **border texel** (any index outside [0, size − 1]).
- **Nearest**: texel (cu >> 8, cv >> 8) back into the level (for the modes other than border only size can be out: it clamps), all four addresses the same, weights 0.
- **Bilinear**: c − 128; i0 = its integer part, the weight its low 8 bits, i1 = i0 + 1; each back into the level.  Texels 0-3 = (i0, j0), (i1, j0), (i0, j1), (i1, j1).
- **texf**: x, y, level (rs1, rs1+1, rs2) as signed integers; the level clamped to [0, LEVELS − 1], x and y to the level; nearest, weights 0.
- **texsz**: the level is word 0 of the lane (rs1, unsigned, clamped to 15); ta_value lane l = {max(1, h >> level), max(1, w >> level)} (16 bits each); no address (0).
- **Address** (4 bytes a texel, 32-bit wrap): linear base + (j × w_level + i) × 4; tiled base + (j / 4) × ceil(w_level / 4) × 64 + (i / 4) × 64 + ((j % 4) × 4 + i % 4) × 4 (atg_blt's layout); bits 1:0 are 0, then bit 0 is set for a border texel.
- **ta_ctl**: [0] = some lane of tx_mask is bilinear (the cache then fetches texels 1-3; a nearest lane's four addresses are the same texel), [1] SAMPLER[12], [2] texsz, [3] texf, [4] pass 0 with a pass 1 to follow, [5] pass 1, [7:6] SAMPLER[18:17] (3, codes 6 and 7, reads as 0), [8] SAMPLER[14], [9] compare, [12:10] SAMPLER[10:8], [15:13] 0.
- **ta_value**: texsz {h, w}; compare the lane's rs2; otherwise 0.

## 5. State machine

IDLE →(tx_valid)→ [LOD (texb: the quad's λ)] → LA (lane k: λ, level, size, wrapped coordinates × size) → LB (lane k: footprint, addresses, weights) → LA … (lanes 0-3) → OUT →(ta_ready)→ IDLE, or (pass 0 of a mip linear pair) → LA … (pass 1) → OUT → IDLE.  One state machine.

## 6. Latency and throughput

Target one quad per cycle.  v1: 2 cycles per lane, 9 cycles per quad (10 for texb) plus the handshake, twice for a mip linear pair; one quad at a time (p015, the performance Phase, pipelines it).

## 7. Corner cases and errors

- Masked lanes produce addresses of texel 0 of level 0 (fetched but discarded; keeps the cache simple) — or are skipped; the implementation chooses and records it.  **Chosen**: masked lanes are computed like the others (from whatever their coordinates hold) and the cache does not fetch them.
- texb's derivatives use lanes 0-2 whatever the mask (helper lanes are in EXEC, design §3.1).
- A STATE write of the TU range while a quad is inside would change it under the quad: atg_cp_seq holds such a SET_REG while the TU, the RX or the SUs are busy.

## 8. What the TB checks

`sim/tb/atg_tu_addr_tb.v` prints, in this order:

- `PASS atg_tu_addr.wrap` — wrap modes on random coordinates (texl, texf and texsz on random linear and tiled descriptors, special values: ±0, denormals, ±1, infinities, NaN, huge)
- `PASS atg_tu_addr.lod` — texb LOD from derivatives against the reference (`tools/tumodel.py`; derivatives 2^-14..2^3, biases, level counts 0-15)
- `PASS atg_tu_addr.tile` — tiled addresses
- `PASS atg_tu_addr.trilinear` — mip linear: both levels, the weight, one pass when no lane needs two
- `PASS atg_tu_addr.border` — clamp to border: border texels (address bit 0), border colour classes
- `PASS atg_tu_addr.compare` — depth formats with and without compare, every op: the reference, λ, no filter without compare
- `PASS atg_tu_addr` at the end.

Vectors: `sim/vec/tu_addr.txt` from `tools/tu-vectors.py` (2300 quads, 2572 outputs), random gaps and ta_ready.

## 9. References

design §2.3 (TU STATE), §3.7 (limits), atg_blt's tile layout.

## 10. Status

Implemented in WS288 p009 part C (P1, branch p1-tu); mip linear, clamp to border, depth formats and compare in part E (P3, branch p3-p009e).  Readings of this spec and of design §2.3 (to confirm with Q1):

1. **SAMPLER[13] = 4×4 tiled** (design §2.3's SAMPLER has no layout bit; CAPS[11] says tiles may be used).  Proposal for design §2.3 / the standard state.
2. (Part C) wrap value 3 read as clamp to edge, mip linear and compare were not done.  Since part E (P3): all three are done as above.  Readings: mip linear in two passes through the cache and the filter (1 lane has 8 texels: the alternatives, 8 addresses per lane on wider ports or a second cache port, cost more wiring for the same throughput in v1); a lane with fl = 0 in pass 1 is fetched again at its level (cache hits) rather than masked; clamp to border clamps u to [−1, 2] first; the border colour is chosen in the cache (address bit 0, so no extra port); a compare sampler takes Dref from rs2 (the SU has three operand reads: no fourth for rs1+2), so texb has no bias and texl samples at λ = 0; a depth format without compare is nearest only (linear filtering of depth values is not offered); compare on a colour format is ignored.
3. texsz takes the level from word 0 (its rs1; the I form has no rs2).  texf's out-of-range coordinates and level are clamped (Vulkan leaves them undefined; robust access would give 0).
4. LOD per quad from coarse derivatives (lanes 0-2), bias per lane; log2 piecewise linear (8 fraction bits).
