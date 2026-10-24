# atg_su

RTL: `rtl/gpu/su/atg_su.v`.  Parent: atg_top (generate over NSU).  Implemented in: p008 (wiring with the compute subset), p009.

## 1. Purpose and place

One shader unit (design §3): the warp scheduler, the front end (fetch, I$, decode), the scoreboard issue stage, the register file and operand collection, the execution units on one execution bus, the write-back arbiter, and its memory ports (D$ client, I$+constant client, atomics), the VF/RX inputs, the PT, the TU and ROP ports and the reserved SA port.

Children: `atg_su_sched`, `atg_su_fetch`, `atg_su_icache`, `atg_su_dec`, `atg_su_sb`, `atg_su_rf`, `atg_su_opd`, `atg_su_alu`, `atg_su_fpu`, `atg_su_pk`, `atg_su_lane`, `atg_su_lda`, `atg_su_exec`, `atg_su_lsu`, `atg_su_lds`, `atg_su_cbank`, `atg_su_tex` (with its child `atg_su_tex_ret`), `atg_su_xu`, `atg_su_div`, `atg_su_dcache`, `atg_su_exp`, `atg_su_pt`, `atg_su_rq`, `atg_su_wb`, `am_amb_mux`.

Wiring module (exempt from the port and line limits, spec/README.md).  Internal buses:
front end `f_*` (sched → fetch), `ic_*` (fetch ↔ icache), `d_*` (fetch → dec), `u_*` (dec → sb),
`i_*` (sb → opd), feedback `fb_*`/`wake` (sb → sched), warp control `wc_*` (exec → sched), the
execution bus `x_*` (opd → every unit, `unit_ready` back), short results `<unit>_s_*` (alu, fpu,
pk, lane, lda, exec → wb), long results `<unit>_l_*` (lsu, lds, cbank, tex, xu, div → wb), RF
ports `w_*` (wb → rf) and `r_*` (opd ↔ rf), releases `rel_*` (wb → sb), rq (`rq_*`).

Design §7.6 also lists `atg_su_pkx` (packed transcendentals); design v4 §3.9 point 4 withdrew
those instructions, so the module is not part of the tree (Q1, 2026-10-23).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `NREGS` | `32` | GPRs per thread: 32 or 64 (r0..r62 at most; 63 is rq). |
| `SB_ENTRIES` | `4` | Scoreboard entries per warp (ZYBO 4, KC705 8). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh). |
| `SHORT_LAT` | `6` | Cycles from x_valid to the short result (one fixed pipeline for classes a and f, design §3.1.1). |
| `NSU` | `1` | SUs in the GPU. |
| `SU_INDEX` | `0` | This SU's number. |
| `FRAG_RESERVE` | `1` | Slots kept for fragment warps. |
| `PACKED` | `0` | Packed fp16 arithmetic. |
| `SUBGROUP` | `0` | shfl/vote/ballot. |
| `HAS_SA` | `0` | SA attached (v1 0). |
| `MS4` | `0` | 4x multisampling (CAPS[29]): texsz.s in the decoder. |
| `LDS_BYTES` | `4096` | Shared memory bytes. |
| `PT_ENTRIES` | `64` | PT vertices. |
| `VARY_WORDS` | `16` | Varying words per vertex. |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 (ZYBO) or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |

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
| **From the CP** | | | |
| `cs_kick` | in | 1 | DISPATCH. |
| `lc_kick` | in | 1 | LOAD_CONST. |
| `inv` | in | 4 | INVALIDATE mask: [0] D$, [2] constant, [3] I$ ([1] T$ is the TU's). |
| **Vertex warps from the VF** | | | |
| `vl_req` | in | 1 | Slot request. |
| `vl_gnt` | out | 1 | Grant pulse. |
| `vl_slot` | out | WARP_W | Slot. |
| `vl_ptbase` | out | 8 | First PT entry of the warp's 32 vertices (valid with vl_gnt). |
| `vl_we` | in | 1 | Attribute word write. |
| `vl_reg` | in | 6 | Register (ATTR_DST). |
| `vl_lane` | in | 5 | Lane (vertex). |
| `vl_data` | in | 32 | Data. |
| `vl_go` | in | 1 | Start the warp. |
| `vl_mask` | in | 32 | Valid vertices. |
| **Fragment warps from the RX** | | | |
| `fl_req` | in | 1 | Slot request. |
| `fl_gnt` | out | 1 | Grant pulse. |
| `fl_slot` | out | WARP_W | Slot. |
| `fl_we` | in | 1 | Register write (b0, b1, b2, z, x, y → r0-r5). |
| `fl_reg` | in | 6 | Register. |
| `fl_lane` | in | 5 | Lane. |
| `fl_data` | in | 32 | Data. |
| `fl_pw_we` | in | 1 | Primitive table write. |
| `fl_pw_addr` | in | 12 | {primitive, vertex, word}. |
| `fl_pw_data` | in | 32 | Data. |
| `fl_go` | in | 1 | Start. |
| `fl_mask` | in | 32 | Initial EXEC (quads). |
| `fl_info` | in | 64 | Coverage, sequence number, front, primitive. |
| **PT read for the RX** | | | |
| `pt_rd` | in | 1 | Read. |
| `pt_idx` | in | 8 | Entry. |
| `pt_word` | in | 6 | Word. |
| `pt_rdata` | out | 32 | Data. |
| `pt_free` | in | 1 | Free an entry. |
| `pt_free_idx` | in | 8 | Entry. |
| `pt_done` | out | 8 | Bit b: block b's vertex warp has ended (atg_su_pt; atg_top holds the VF's primitives of a block until then). |
| **TU** | | | |
| `tx_valid` | out | 1 | Request quad. |
| `tx_ready` | in | 1 | Taken. |
| `tx_op` | out | 8 | Op and its modifiers (atg_su_tex). |
| `tx_slot` | out | 4 | Slot. |
| `tx_mask` | out | 4 | Lanes. |
| `tx_coord` | out | 640 | Coordinates, 5 words a lane (atg_su_tex). |
| `tx_off` | out | 12 | Texel offsets (atg_su_tex). |
| `tx_tag` | out | 16 | Tag. |
| `tx_last` | out | 1 | Last. |
| `tr_valid` | in | 1 | Return quad. |
| `tr_ready` | out | 1 | Taken. |
| `tr_tag` | in | 16 | Tag. |
| `tr_data` | in | 512 | Texels. |
| `tr_last` | in | 1 | Last. |
| **ROP** | | | |
| `ex_valid` | out | 1 | Fragment quad. |
| `ex_ready` | in | 1 | Taken. |
| `ex_seq` | out | 16 | Sequence. |
| `ex_xy` | out | 32 | Position. |
| `ex_mask` | out | 4 | Lanes. |
| `ex_color` | out | 512 | Colour. |
| `ex_depth` | out | 128 | Depth. |
| `ex_last` | out | 1 | Last quad of the warp. |
| `ex_ms` | out | 148 | Multisampling with the quad: {d_s, zexp, smask} (atg_su_exp). |
| `ex_next` | in | 16 | The ROP's next sequence number. |
| **AMB client port (design §4.1)** | | | |
| `d_req_valid` | out | 1 | Request valid; payload held until `d_req_ready`. |
| `d_req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `d_req_write` | out | 1 | 1 write, 0 read. |
| `d_req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `d_req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `d_req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `d_req_tag` | out | 8 | The client's tag, returned with the response. |
| `d_rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `d_rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `d_rsp_tag` | in | 8 | Tag of the request answered. |
| `d_rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `d_rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |
| **AMB client port (design §4.1)** | | | |
| `i_req_valid` | out | 1 | Request valid; payload held until `i_req_ready`. |
| `i_req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `i_req_write` | out | 1 | 1 write, 0 read. |
| `i_req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `i_req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `i_req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `i_req_tag` | out | 8 | The client's tag, returned with the response. |
| `i_rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `i_rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `i_rsp_tag` | in | 8 | Tag of the request answered. |
| `i_rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `i_rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |
| **Atomics (atg_mc_atom)** | | | |
| `at_valid` | out | 1 | Request. |
| `at_ready` | in | 1 | Taken. |
| `at_op` | out | 4 | Op. |
| `at_addr` | out | 30 | Word address. |
| `at_a` | out | 32 | Operand. |
| `at_b` | out | 32 | Compare value. |
| `at_rsp_valid` | in | 1 | Response. |
| `at_old` | in | 32 | Old value. |
| `at_error` | in | 1 | Error. |
| **Systolic array (reserved, design §3.9)** | | | |
| `sa_push_valid` | out | 1 | To the SA. |
| `sa_push_ready` | in | 1 | Taken. |
| `sa_push_data` | out | NPHYS*32 | Data. |
| `sa_pop_valid` | in | 1 | From the SA. |
| `sa_pop_ready` | out | 1 | Taken. |
| `sa_pop_data` | in | NPHYS*32 | Data. |
| `sa_ctl_valid` | out | 1 | sactl. |
| `sa_ctl_data` | out | 32 | Control word. |
| `sa_qstat` | in | 32 | qstat. |
| `sa_stat` | in | 32 | sastat. |
| `sa_qtag` | in | 32 | qtag. |
| **Status** | | | |
| `busy` | out | 1 | STATUS.SU_BUSY contribution. |
| `fault` | out | 1 | ISA fault (FAULT kind 8). |
| `fault_addr` | out | 32 | PC of the fault. |

109 ports; 87 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Wiring only.  MC clients of SU k: `d_*` = 2k (D$), `i_*` = 2k+1 (I$ + constant bank).  The atomic port goes to atg_mc_atom.  The graphics ports (vl_*, fl_*, pt_*, tx/tr, ex_*) are connected for SU 0 only in v1 (atg_top); the other SUs run compute.

## 5. State machine

None (wiring).

## 6. Latency and throughput

One instruction issue per cycle across warps, NPHYS lanes per cycle (design §3.1).

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

Wiring module; the SU as a whole is checked by two testbenches (and the parent's, and `tools/lint.sh`):

- `sim/tb/atg_su_tb.v` — compute dispatches of the programs of `sim/tb/su` against `tools/gsi1model.py` on NPHYS 8, 16 and 32 (the same binary), and the ISA faults of the subgroup instructions without SUBGROUP: `PASS atg_su.nphys8`, `.nphys16`, `.nphys32`, `.nosubgroup`, `PASS atg_su`.
- `sim/tb/atg_su_gfx_tb.v` — graphics warps with PACKED and SUBGROUP on NPHYS 8, 16 (the KC705's shape: 8 scoreboard entries, FRAG_RESERVE 2) and 32, the testbench as VF, RX and ROP:
  - `PASS atg_su_gfx.gfx` — `sim/tb/su/gfx.s` as one vertex warp and three fragment warps (EXEC whole quads, coverage in the mask operand, so helper lanes, and killed lanes): qd, shfl, vote and ballot see the helper and killed lanes; sw, atom, sts and exp skip them (design §3.1 M10); the packed arithmetic; against `tools/gsi1model.py --warps`: the registers, the data memory, the quads at the ROP in sequence order (positions, masks, colours, exported or rasterized depth) and the vertex warp's PT entries (and the words it must not write).
  - `PASS atg_su_gfx.loop` — the closed loop of design §3.8 (vertex warps with random vl_mask, also 0; per block after pt_done 1-3 fragment warps ending out of order; the PT entries freed except the last three of a block until the next block's fragment warps, as atg_vf_asm holds its last primitive; the ROP at random): no deadlock, every vertex grant leaves more than FRAG_RESERVE slots free and gets a PT block with no entry in use, the quads in sequence order.  With PT_ENTRIES 32 (one block) the same loop deadlocks, which the testbench reports.
  - `PASS atg_su_gfx.ms` — the fragment warps' r6 (some lanes 0) and two SAMPLE_MASK exports: the quads' masks and ex_ms on the mask's lanes against `gfx.msexp` (`tools/gsi1model.py --ms-out`)
  - `PASS atg_su_gfx` at the end.

## 9. References

design §3 (all), §3.6 (size), §3.7 (parameters per board), include/atg_su_uop.vh.

## 10. Status

Wiring written in WS288 p023 (children are stubs unless their spec says otherwise).

WS288 p009 part B1 (P1): the new child `atg_su_pt` (the PT and its allocator, split off atg_su_exp; pt_take = vl_gnt with pt_warp = vl_slot, vl_go/vl_mask to it), the new output `pt_done`; atg_su_exp snoops fl_we/fl_slot/fl_reg/fl_lane/fl_data/fl_go/fl_info.

WS288 p009 part C (P1, branch p1-tu): `atg_su_tex` implemented; its return half is the new module `atg_su_tex_ret` (a child of atg_su_tex, not of atg_su: the module rule of one state machine).  No port of atg_su changes.

Graphics checks (`atg_su_gfx_tb`, no RTL change in the SU): the helper-lane rule of design §3.1 (M10) holds as implemented: atg_rx_frag's fl_mask is the EXEC of whole quads and fl_info[31:0] the coverage (the mask operand); atg_su_opd's side-effect lanes are EXEC & coverage & ~KILLED and are used by sw, atom (atg_su_lsu), sts (atg_su_lds), exp (atg_su_exp, atg_su_pt); qd, shfl, vote, ballot and tex use EXEC.  Readings: (1) shfl, vote and ballot count helper and killed lanes as active (they are in EXEC; GHCI §12.5 defines them over EXEC), so `vote.all` over a coverage Boolean is false in a partly covered warp; a compiler that wants the covered lanes only combines with `mask` (or ballots it).  (2) KILLED is not limited to fragment warps: a kill in a vertex warp also stops its PT exports (the same side-effect mask).  (3) FRAG_RESERVE is not what keeps the loop of §3.8 deadlock-free in this SU (vertex warps never wait on the RX once granted, and fragment grants win over vertex grants); it keeps fragment slots free while the VF floods (the loop of atg_su_gfx_tb also ends with FRAG_RESERVE 0).  The block allocator of atg_su_pt with at least two blocks is what the held primitive needs.
