# atg_su

RTL: `rtl/gpu/su/atg_su.v`.  Parent: atg_top (generate over NSU).  Implemented in: p008 (wiring with the compute subset), p009.

## 1. Purpose and place

One shader unit (design §3): the warp scheduler, the front end (fetch, I$, decode), the scoreboard issue stage, the register file and operand collection, the execution units on one execution bus, the write-back arbiter, and its memory ports (D$ client, I$+constant client, atomics), the VF/RX inputs, the PT, the TU and ROP ports and the reserved SA port.

Children: `atg_su_sched`, `atg_su_fetch`, `atg_su_icache`, `atg_su_dec`, `atg_su_sb`, `atg_su_rf`, `atg_su_opd`, `atg_su_alu`, `atg_su_fpu`, `atg_su_pk`, `atg_su_lane`, `atg_su_lda`, `atg_su_exec`, `atg_su_lsu`, `atg_su_lds`, `atg_su_cbank`, `atg_su_tex`, `atg_su_xu`, `atg_su_div`, `atg_su_dcache`, `atg_su_exp`, `atg_su_rq`, `atg_su_wb`, `am_amb_mux`.

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
| **TU** | | | |
| `tx_valid` | out | 1 | Request quad. |
| `tx_ready` | in | 1 | Taken. |
| `tx_op` | out | 2 | Op. |
| `tx_slot` | out | 4 | Slot. |
| `tx_mask` | out | 4 | Lanes. |
| `tx_coord` | out | 384 | Coordinates. |
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

106 ports; 84 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Wiring only.  MC clients of SU k: `d_*` = 2k (D$), `i_*` = 2k+1 (I$ + constant bank).  The atomic port goes to atg_mc_atom.  The graphics ports (vl_*, fl_*, pt_*, tx/tr, ex_*) are connected for SU 0 only in v1 (atg_top); the other SUs run compute.

## 5. State machine

None (wiring).

## 6. Latency and throughput

One instruction issue per cycle across warps, NPHYS lanes per cycle (design §3.1).

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.

## 9. References

design §3 (all), §3.6 (size), §3.7 (parameters per board), include/atg_su_uop.vh.

## 10. Status

Wiring written in WS288 p023 (children are stubs unless their spec says otherwise).
