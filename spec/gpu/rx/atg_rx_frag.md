# atg_rx_frag

RTL: `rtl/gpu/rx/atg_rx_frag.v`.  Parent: atg_rx.  Child: `atg_rx_bary` (the lane arithmetic).  Implemented in: p009 (part B2; split off atg_rx_scan).

## 1. Purpose and place

The RX's fragment warps: packs the covered quads of one triangle (from atg_rx_scan) into 32-lane warps of SU 0, copies the triangle's varyings from the PT into the warp's primitive table, writes each lane's r0-r6 (r7-r9 with CENTROID) and starts the warp with a sequence number for the ROP order.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **STATE broadcast (from atg_cp_state)** | | | |
| `st_we` | in | 1 | One-cycle write of STATE[st_idx]. |
| `st_idx` | in | 9 | STATE index; this module keeps VARYING_COUNT (0x05B, 0-32 words) and MS_CTRL (0x05E: [3:0] = 2 four samples, [4] CENTROID). |
| `st_wdata` | in | 32 | STATE value. |
| **The triangle** | | | |
| `t_load` | in | 1 | atg_rx_scan takes a set-up triangle (sp_valid && sp_ready). |
| `t_tri` | in | 768 | atg_rx_setup's sp_tri (planes, bbox origin, PT entries, facing; atg_rx_setup §3). |
| **Covered quads from atg_rx_scan** | | | |
| `fq_valid` | in | 1 | A covered quad, or the triangle's end marker (fq_end). |
| `fq_ready` | out | 1 | Taken (while collecting fewer than 8 quads). |
| `fq_xy` | in | 32 | {y, x} of the quad (even). |
| `fq_scov` | in | 16 | The quad's samples (bit 4 l + s, after the sample mask test). |
| `fq_ccov` | in | 4 | The lanes whose centre is inside. |
| `fq_end` | in | 1 | The end marker. |
| `busy` | out | 1 | Quads held or a warp being built (atg_rx_scan's frees wait; RX_BUSY). |
| **PT of SU 0 (the read port shared with atg_rx_clip)** | | | |
| `pt_rd` | out | 1 | Read one PT word. |
| `pt_idx` | out | 8 | Entry. |
| `pt_word` | out | 6 | Word (4 + varying). |
| `pt_rdata` | in | 32 | Data, the cycle after pt_rd. |
| `pt_busy` | out | 1 | Copying (atg_rx_clip does not read). |
| **Fragment warps to the SU (atg_su fl_*)** | | | |
| `fl_req` | out | 1 | Slot request (level until fl_gnt). |
| `fl_gnt` | in | 1 | Grant pulse. |
| `fl_we` | out | 1 | Register word. |
| `fl_reg` | out | 6 | Register r0-r6 (r0-r9 with CENTROID). |
| `fl_lane` | out | 5 | Lane (4 × quad + lane of the quad). |
| `fl_data` | out | 32 | Data. |
| `fl_pw_we` | out | 1 | Primitive table word. |
| `fl_pw_addr` | out | 12 | [10:8] primitive (0), [7:6] vertex, [5:0] word; 0xFFF the primitive map; 0xFF8-0xFFB the samples' depth slopes (4 samples). |
| `fl_pw_data` | out | 32 | Data. |
| `fl_go` | out | 1 | Start the warp. |
| `fl_mask` | out | 32 | EXEC: the warp's quads, all 4 lanes (helper lanes, design §3.1). |
| `fl_info` | out | 64 | [31:0] coverage (the lanes with a sample), [47:32] sequence number, [48] front, [63:49] 0. |
| **Sequence numbers (atg_rx_order)** | | | |
| `sq_req` | out | 1 | One number per warp (with fl_go). |
| `sq_seq` | in | 16 | The number, in the same cycle. |

33 ports.

## 4. Behaviour

- Collect: quads are taken while fewer than 8 are held; at 8, or at the end marker with at least one,
  the warp is built (the end marker with none is just taken).  A warp holds quads of one triangle only.
- After fl_gnt: the 3 vertices × VARYING_COUNT words (PT word 4 + w of the triangle's PT entry v →
  table word {0, v, 4 + w}, vertex by vertex), then the primitive map (0xFFF, 0: one triangle per warp).
- Per quad, per lane (pixel (x, y), i = x − bbox x0, j = y − bbox y0 as fp32, the RX's fmul, fadd, fdiv,
  round to nearest even, denormals flushed):
  - P = (A i + B j) + C for the planes z, 1/w, b0/w, b1/w of sp_tri;
  - z clamped to [0, 1] (NaN and negatives 0) with one sample, as on the direct path; not clamped with four (the ROP adds each sample's slope and clamps);
  - r = 1 / (1/w); b0 = (b0/w) r; b1 = (b1/w) r; b2 = (1 − b0) − b1 (relative to the original
    vertices also after a near-plane clip, design §3.8);
  - r0 = b0, r1 = b1, r2 = b2, r3 = z, r4 = x + 0.5, r5 = y + 0.5 (the pixel centre: Vulkan FragCoord), r6 = the lane's 4 bits of fq_scov (0 in a helper lane);
  - with CENTROID, r7-r9 = b0, b1, b2 at the centroid: the centre when fq_ccov's bit is set or the lane has no sample, else at the covered sample of the lowest index (`atg_rx_bary` with the sample's offset: i, j plus multiples of 1/8, exact), a second pass for a quad that has such a lane.
  The registers go out lane by lane (r0 to r6 or r9), quad by quad; then fl_go with a new sequence number.
- Four samples: before the first warp's copy of a triangle, d_s = Az dx_s + Bz dy_s (`atg_rx_bary`, once per triangle: reset at t_load); every warp's copy ends with the 4 words at 0xFF8-0xFFB after the map.
- tools/rxmodel.py (`warps`, `frag_lane`) is the reference.

## 5. State machine

COL (quads in) →(8 quads, or the end marker after some)→ ALLOC (fl_req) →(fl_gnt; 4 samples, first warp of the triangle)→ [DZ] → COPY (PT reads, table writes, the map, d_s) → per quad: [BARYC: the centroid's pass] → BARY (atg_rx_bary: PL 44, DIV 4 divisions, BC 16 cycles) → WR (4 × 7 or 4 × 10 register writes) → back to COPY (done: on) for the next quad, or GO → COL.

## 6. Latency and throughput

About 200 cycles per quad plus 3 × VARYING_COUNT + 2 cycles per warp; one quad at a time (v1, below the design target; p015).

## 7. Corner cases and errors

- A triangle without covered quads makes no warp and takes no sequence number.
- Helper lanes (covered quad, uncovered lane) get the same computation, extrapolated.
- VARYING_COUNT above 32 is taken as 32; the driver keeps it within the SU's VARY_WORDS.

## 8. What the TB checks

`sim/tb/atg_rx_frag_tb.v` prints, in this order:

- `PASS atg_rx_frag.copy` — per warp the 3 × VARYING_COUNT table writes from the PT and the map, after the grant, with pt_busy
- `PASS atg_rx_frag.warps` — the warps of sim/vec/rx_frag.txt (tools/rx-vectors.py, unchanged by the multisampling work): r0-r5 of every lane bit for bit and r6 the lane's coverage bit, fl_go with EXEC, coverage, sequence number and facing
- `PASS atg_rx_frag.ms` — sim/vec/rx_frag_ms.txt (tools/rx-msaa-vectors.py, tools/msmodel.py): 4 samples with and without CENTROID and 1 sample with it: r0-r9, the d_s words after the map; `-DMUT_R3_CLAMP` and `-DMUT_DZ_SIGN` (in atg_rx_bary) fail it
- `PASS atg_rx_frag` at the end.

## 9. References

design §3.4.3 (the fragment warp's inputs), §3.8 (clip, barycentrics, ROP order); spec atg_rx_setup.md (sp_tri), atg_rx_scan.md, atg_su_lda.md (the primitive table), atg_su_exp.md (r3-r5 snooped).

## 10. Status

Implemented in WS288 p009 part B2 (P1, branch p1-su-gfx), split off atg_rx_scan (its p009 warp path).  320 lines, one FSM.  2026-10-25 (CAPS[30]): with DEPTH_CLAMP[1] (0x059) r3 is not clamped with one sample either (the RX clips the depth geometrically); DEPTH_CLAMP[1] = 0 as before.  Not yet in this TB (the scene of the integration step checks it).

Multisampling (the MSAA work): the lane arithmetic moved to `atg_rx_bary` (for the line limit), r6, the centroid's pass and r7-r9, d_s, MS_CTRL; `fq_cov` became `fq_scov` and `fq_ccov` (33 ports).  342 lines.
