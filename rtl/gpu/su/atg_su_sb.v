/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_sb: The issue stage with the per-warp scoreboard (design
 * §3.1.1): checks the operand ranges of an instruction against the warp's
 * outstanding long operations, the wait counters, rq and write-back
 * stalls; issues to atg_su_opd with an entry, or replays.
 *
 * u_* (one instruction at a time, from atg_su_dec) ends in one of:
 *   - issue (i_valid && i_ready): fb kind 0, or 1 for a branch/end/bar;
 *   - replay (fb kind 2, no issue): a long hazard (an operand range meets a
 *     scoreboard entry), no free entry, a counter not low enough for
 *     wait/fence/end, rq; atg_su_sched fetches the pc again after wake;
 *   - consumed without issue: nop, a satisfied wait (fb 0), ILL (fault, fb 1);
 *   - hold (u_ready 0): wb_stall, atg_su_opd busy, or the short interlock.
 * The short interlock: the results of classes a and f come SHORT_LAT
 * cycles after their group is on the bus, without bypass.  Issued
 * instructions are kept in order until their last group leaves atg_su_opd
 * (x_end); a short writer then counts down SHORT_LAT+1 cycles.  A reader
 * of its rd waits while the instruction is still before the bus or the
 * count is above G+1 (G = 32/NPHYS groups); a long writer of the same rd
 * waits until the count ends (its result could overtake).
 * A release and an allocation of the same entry in one cycle: the release
 * first.  wake[w] pulses on every release of warp w.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_sb #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter SB_ENTRIES = 4,	/* Scoreboard entries per warp (KC705 8) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter SHORT_LAT = 6,	/* Cycles from x_valid to the short result */
	parameter BYPASS = 0,	/* Short interlock bypass support (0: stall until RF write, 1: bypass) */
	parameter FAST_REL = 1	/* 1: 1-cycle combinational issue; 0: 3-stage registered issue pipeline */
) (
	input wire clk,
	input wire rst_n,
	/* From atg_su_dec */
	input wire u_valid,
	output wire u_ready,
	input wire [WARP_W-1:0] u_warp,
	input wire [15:0] u_pc,
	input wire [UOP_W-1:0] u_uop,
	/* To atg_su_opd */
	output wire i_valid,
	input wire i_ready,
	output wire [WARP_W-1:0] i_warp,
	output wire [15:0] i_pc,
	output wire [UOP_W-1:0] i_uop,
	output wire [SBE_W:0] i_sbe,
	input wire x_end,
	/* To atg_su_sched */
	output wire fb_valid,
	output wire [WARP_W-1:0] fb_warp,
	output wire [1:0] fb_kind,
	output wire [NWARPS-1:0] wake,
	/* Releases (from atg_su_wb) */
	input wire rel_valid,
	input wire [WARP_W-1:0] rel_warp,
	input wire [SBE_W:0] rel_sbe,
	input wire [2:0] rel_cls,
	input wire wb_stall,
	input wire rq_empty,
	input wire rq_full,
	output wire busy,
	output wire fault,
	output wire [15:0] fault_pc,
	output wire [NWARPS-1:0] warp_ready
);
`include "atg_su_uop.vh"

	localparam G = 32 / NPHYS;
	localparam SHORT_BP_WAIT_ALU = 3 + G;
	localparam SHORT_BP_WAIT_FPU = 2 + G;
	localparam NE = NWARPS * SB_ENTRIES;
	localparam CNT_W = 6;
	localparam NSC = SHORT_LAT + 1;	/* short writers counting down (shift register stages 0..SHORT_LAT) */
	localparam NIF = 4;
	localparam NE_W = $clog2(NE);	/* issued, not yet past atg_su_opd */

	wire rst_p = !rst_n;

	wire [WARP_W-1:0] u_warp_r, u_warp_ev, u_warp_r0, u_warp_r1, u_warp_r2, u_warp_r3, u_warp_cnt;
	wire [WARP_W-1:0] u_warp_m, u_warp_f, u_warp_c, u_warp_w, u_warp_out;
`ifdef SYNTH_KINTEX7
	genvar guw;
	generate
		for (guw = 0; guw < WARP_W; guw = guw + 1) begin : g_buf_uwarp
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_uwr (.I0(u_warp[guw]), .O(u_warp_r[guw]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_uwev(.I0(u_warp[guw]), .O(u_warp_ev[guw]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_uwr0(.I0(u_warp[guw]), .O(u_warp_r0[guw]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_uwr1(.I0(u_warp[guw]), .O(u_warp_r1[guw]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_uwr2(.I0(u_warp[guw]), .O(u_warp_r2[guw]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_uwr3(.I0(u_warp[guw]), .O(u_warp_r3[guw]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_uwct(.I0(u_warp[guw]), .O(u_warp_cnt[guw]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_uwm (.I0(u_warp[guw]), .O(u_warp_m[guw]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_uwf (.I0(u_warp[guw]), .O(u_warp_f[guw]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_uwc (.I0(u_warp[guw]), .O(u_warp_c[guw]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_uww (.I0(u_warp[guw]), .O(u_warp_w[guw]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_uwo (.I0(u_warp[guw]), .O(u_warp_out[guw]));
		end
	endgenerate
`else
	assign u_warp_r   = u_warp;
	assign u_warp_ev  = u_warp;
	assign u_warp_r0  = u_warp;
	assign u_warp_r1  = u_warp;
	assign u_warp_r2  = u_warp;
	assign u_warp_r3  = u_warp;
	assign u_warp_cnt = u_warp;
	assign u_warp_m   = u_warp;
	assign u_warp_f   = u_warp;
	assign u_warp_c   = u_warp;
	assign u_warp_w   = u_warp;
	assign u_warp_out = u_warp;
`endif

	/* The uop's fields. */
	wire [3:0] unit = u_uop[ATG_UOP_UNIT +: 4];
	wire [7:0] op = u_uop[ATG_UOP_OP +: 8];
	wire [2:0] cls = u_uop[ATG_UOP_CLS +: 3];
	wire [6:0] rd = u_uop[ATG_UOP_RD +: 7];
	wire [6:0] rs1 = u_uop[ATG_UOP_RS1 +: 7];
	wire [6:0] rs2 = u_uop[ATG_UOP_RS2 +: 7];
	wire [6:0] rs3 = u_uop[ATG_UOP_RS3 +: 7];

	wire rs1_lt63 = !rs1[6] && (rs1[5:0] != 6'h3F);
	wire rs2_lt63 = !rs2[6] && (rs2[5:0] != 6'h3F);
	wire rs3_lt63 = !rs3[6] && (rs3[5:0] != 6'h3F);
	wire rs1_lt62 = !rs1[6] && (rs1[5:1] != 5'h1F);
	wire rs3_lt62 = !rs3[6] && (rs3[5:1] != 5'h1F);
	wire rd_lt63  = !rd[6]  && (rd[5:0]  != 6'h3F);

	wire [5:0] rs1p_lo, rs3p_lo;
	am_add #(.W(6)) u_add_rs1p (.a(rs1[5:0]), .b(6'd1), .ci(1'b0), .s(rs1p_lo), .co());
	am_add #(.W(6)) u_add_rs3p (.a(rs3[5:0]), .b(6'd1), .ci(1'b0), .s(rs3p_lo), .co());
	wire [6:0] rs1p = {1'b0, rs1p_lo};
	wire [6:0] rs3p = {1'b0, rs3p_lo};

	wire wrd = u_uop[ATG_UOP_WRD];
	wire pair = u_uop[ATG_UOP_PAIR];
	wire ill = u_uop[ATG_UOP_ILL];
	wire wide = u_uop[ATG_UOP_NDST +: 3] == 3'd4;
	wire is_long = cls == ATG_CLS_M || cls == ATG_CLS_T || cls == ATG_CLS_X;
	wire [31:0] imm = u_uop[ATG_UOP_IMM +: 32];
	wire src1 = u_uop[ATG_UOP_USE1] && rs1_lt63;
	wire src2 = u_uop[ATG_UOP_USE2] && rs2_lt63;
	wire src3 = u_uop[ATG_UOP_USE3] && rs3_lt63;
	wire src4 = pair && rs1_lt62;
	/* A texture .3 form with Dref also reads rs1+3 (rs3 + 1). */
	wire [5:0] rd_p1, rd_p2, rd_p3;
	am_add #(.W(6)) u_add_rdp1 (.a(rd[5:0]), .b(6'd1), .ci(1'b0), .s(rd_p1), .co());
	am_add #(.W(6)) u_add_rdp2 (.a(rd[5:0]), .b(6'd2), .ci(1'b0), .s(rd_p2), .co());
	am_add #(.W(6)) u_add_rdp3 (.a(rd[5:0]), .b(6'd3), .ci(1'b0), .s(rd_p3), .co());
	wire src5 = unit == ATG_UNIT_TEX && u_uop[ATG_UOP_SUB + 4] && op[ATG_TEX_CFORM] &&
		rs3_lt62;
	wire dst = wrd && rd_lt63;

	/* Scoreboard entries, warp-major: {r0, r1, r2, r3, wide, cls}. */
	reg [NE-1:0] e_valid;
	reg [NE*6-1:0] e_r0;
	reg [NE*6-1:0] e_r1;
	reg [NE*6-1:0] e_r2;
	reg [NE*6-1:0] e_r3;
	reg [NE-1:0] e_wide;
	reg [NWARPS*CNT_W-1:0] cm;
	reg [NWARPS*CNT_W-1:0] ct;
	reg [NWARPS*CNT_W-1:0] cx;

	/* The release of this cycle, applied before the checks when FAST_REL != 0. */
	wire rel_e = rel_valid && rel_sbe != {(SBE_W+1){1'b1}};
	/* warp SB_ENTRIES + entry (an entry index's top bit carries into the warp). */
	wire [WARP_W-1:0] rel_w;
	am_add #(.W(WARP_W)) u_add_relw (
		.a(rel_warp),
		.b({{(WARP_W-1){1'b0}}, rel_sbe[SBE_W]}),
		.ci(1'b0),
		.s(rel_w),
		.co()
	);
	wire [NE_W-1:0] rel_idx = {rel_w, rel_sbe[SBE_W-1:0]};
	reg [NE-1:0] ev_comb;
	integer n;
	always @(*) begin
		ev_comb = e_valid;
		if (rel_e)
			ev_comb[rel_idx] = 1'b0;
	end
	wire [NE-1:0] ev = (FAST_REL != 0) ? ev_comb : e_valid;

	/* Check if register x matches entry (single register or wide 4-register window). */
	function hit_entry;
		input [5:0] x;
		input [5:0] r0, r1, r2, r3;
		input is_wide;
		begin
			hit_entry = (x == r0) || (is_wide && ((x == r1) || (x == r2) || (x == r3)));
		end
	endfunction

	/* Short writers: issued and not past atg_su_opd (in order), then counting in shift register. */
	reg [NIF-1:0]        f_valid;
	reg [NIF*WARP_W-1:0] f_warp;
	reg [NIF*7-1:0]      f_rd;
	reg [NIF-1:0]        f_short;
	reg [NIF-1:0]        f_pipe_alu;
	reg [NIF-1:0]        f_pipe_fpu;

	reg [NSC-1:0]        c_valid;
	reg [NSC*WARP_W-1:0] c_warp;
	reg [NSC*6-1:0]      c_rd;
	reg [NSC-1:0]        c_pipe_alu;
	reg [NSC-1:0]        c_pipe_fpu;

	function hit;
		input [6:0] x;
		input [6:0] r;
		hit = x == r;
	endfunction

	/* Delay counter increment by 1 cycle to completely decouple counter updates
	 * from the 5ns hazard checking critical path. */
	reg [NWARPS-1:0] inc_m, inc_t, inc_x;

	/* Each warp's counters: + 1 at an issue of the class, - 1 at its release.
	 * Structural am_add and am_sub instances per warp. */
	wire [NWARPS*CNT_W-1:0] cm_next, ct_next, cx_next;
	wire [NWARPS*CNT_W-1:0] warp_rcm, warp_rct, warp_rcx;
	genvar gq;
	generate
		for (gq = 0; gq < NWARPS; gq = gq + 1) begin : g_cnt
			wire rw = rel_valid && rel_warp == gq[WARP_W-1:0];
			wire im = inc_m[gq], rm = rw && rel_cls == ATG_CLS_M;
			wire it = inc_t[gq], rt = rw && rel_cls == ATG_CLS_T;
			wire ix = inc_x[gq], rx = rw && rel_cls == ATG_CLS_X;

			wire [CNT_W-1:0] w_cm = cm[gq*CNT_W +: CNT_W];
			wire [CNT_W-1:0] w_ct = ct[gq*CNT_W +: CNT_W];
			wire [CNT_W-1:0] w_cx = cx[gq*CNT_W +: CNT_W];

			wire [CNT_W-1:0] w_cm_p1, w_cm_m1;
			wire [CNT_W-1:0] w_ct_p1, w_ct_m1;
			wire [CNT_W-1:0] w_cx_p1, w_cx_m1;

			am_add #(.W(CNT_W)) u_cm_p1 (.a(w_cm), .b(6'd1), .ci(1'b0), .s(w_cm_p1), .co());
			am_sub #(.W(CNT_W)) u_cm_m1 (.a(w_cm), .b(6'd1), .bi(1'b0), .d(w_cm_m1), .bo());
			am_add #(.W(CNT_W)) u_ct_p1 (.a(w_ct), .b(6'd1), .ci(1'b0), .s(w_ct_p1), .co());
			am_sub #(.W(CNT_W)) u_ct_m1 (.a(w_ct), .b(6'd1), .bi(1'b0), .d(w_ct_m1), .bo());
			am_add #(.W(CNT_W)) u_cx_p1 (.a(w_cx), .b(6'd1), .ci(1'b0), .s(w_cx_p1), .co());
			am_sub #(.W(CNT_W)) u_cx_m1 (.a(w_cx), .b(6'd1), .bi(1'b0), .d(w_cx_m1), .bo());

			assign cm_next[gq*CNT_W +: CNT_W] = (im && !rm) ? w_cm_p1 : (rm && !im) ? w_cm_m1 : w_cm;
			assign ct_next[gq*CNT_W +: CNT_W] = (it && !rt) ? w_ct_p1 : (rt && !it) ? w_ct_m1 : w_ct;
			assign cx_next[gq*CNT_W +: CNT_W] = (ix && !rx) ? w_cx_p1 : (rx && !ix) ? w_cx_m1 : w_cx;

			assign warp_rcm[gq*CNT_W +: CNT_W] = (FAST_REL != 0 && rm) ? w_cm_m1 : w_cm;
			assign warp_rct[gq*CNT_W +: CNT_W] = (FAST_REL != 0 && rt) ? w_ct_m1 : w_ct;
			assign warp_rcx[gq*CNT_W +: CNT_W] = (FAST_REL != 0 && rx) ? w_cx_m1 : w_cx;
		end
	endgenerate

	wire is_wait = unit == ATG_UNIT_CTL;
	wire is_fence = unit == ATG_UNIT_LSU && op == ATG_LSU_FENCE;
	wire is_end = unit == ATG_UNIT_EXEC && op == ATG_EXEC_END;
	wire is_nop = unit == ATG_UNIT_NONE;
	wire need_e = is_long && wrd;
	wire rq_wait = (u_uop[ATG_UOP_RQS] && rq_empty) || (u_uop[ATG_UOP_RQD] && rq_full);
	wire wc_kind = unit == ATG_UNIT_EXEC && (op <= ATG_EXEC_BEXZ || op == ATG_EXEC_END ||
		op == ATG_EXEC_BAR);
	wire short_w = (cls == ATG_CLS_A || cls == ATG_CLS_F) && dst;

	wire        hz_long;
	wire        have_free;
	wire [SBE_W:0] free_e;
	wire        hz_short;
	wire        cnt_wait;
	wire        cnt_full;
	wire        go_gate;
	wire [NWARPS-1:0] pipe_wake;

	generate
	if (FAST_REL == 0) begin : g_pipe_issue
		/* 3-State Registered Issue Pipeline (st_issue: 0 -> 1 -> 2):
		 * State 0: Register decoded operand indices and muxed warp scoreboard/counters (<= 3 LUTs)
		 * State 1: Register per-entry long/short hazard matches, free entry, and counter checks (<= 4 LUTs)
		 * State 2: Combine hazard flags and drive i_valid / u_ready / fb_valid / alloc (<= 3 LUTs)
		 */
		reg [1:0] st_issue;

		/* Stage 0 -> 1 registers */
		reg [5:0] r_rs1, r_rs2, r_rs3, r_rs1p, r_rs3p;
		reg [5:0] r_rd, r_rd_p1, r_rd_p2, r_rd_p3;
		reg       r_src1, r_src2, r_src3, r_src4, r_src5, r_dst;
		reg       r_wide, r_is_long, r_need_e;
		reg       r_is_wait, r_is_fence, r_is_end;
		reg [2:0] r_cls;
		reg [11:0] r_imm12;
		reg [WARP_W-1:0] r_warp;

		wire [5:0] r_rs1_e, r_rs1_f;
		wire [5:0] r_rs2_e, r_rs2_f;
		wire [5:0] r_rs3_e, r_rs3_f;
		wire [5:0] r_rs1p_e, r_rs1p_f;
		wire [5:0] r_rs3p_e, r_rs3p_f;
		wire [5:0] r_rd_e, r_rd_f, r_rd_o;
		wire [5:0] r_rd_p1_e, r_rd_p1_f, r_rd_p1_o;
		wire [5:0] r_rd_p2_e, r_rd_p2_f, r_rd_p2_o;
		wire [5:0] r_rd_p3_e, r_rd_p3_f, r_rd_p3_o;
		wire       r_wide_e, r_wide_f, r_wide_o;
`ifdef SYNTH_KINTEX7
		genvar gsb_b;
		for (gsb_b = 0; gsb_b < 6; gsb_b = gsb_b + 1) begin : g_sb_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rs1_e (.I0(r_rs1[gsb_b]), .O(r_rs1_e[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rs1_f (.I0(r_rs1[gsb_b]), .O(r_rs1_f[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rs2_e (.I0(r_rs2[gsb_b]), .O(r_rs2_e[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rs2_f (.I0(r_rs2[gsb_b]), .O(r_rs2_f[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rs3_e (.I0(r_rs3[gsb_b]), .O(r_rs3_e[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rs3_f (.I0(r_rs3[gsb_b]), .O(r_rs3_f[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rs1p_e (.I0(r_rs1p[gsb_b]), .O(r_rs1p_e[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rs1p_f (.I0(r_rs1p[gsb_b]), .O(r_rs1p_f[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rs3p_e (.I0(r_rs3p[gsb_b]), .O(r_rs3p_e[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rs3p_f (.I0(r_rs3p[gsb_b]), .O(r_rs3p_f[gsb_b]));

			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rd_e   (.I0(r_rd[gsb_b]), .O(r_rd_e[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rd_f   (.I0(r_rd[gsb_b]), .O(r_rd_f[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rd_o   (.I0(r_rd[gsb_b]), .O(r_rd_o[gsb_b]));

			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rdp1_e (.I0(r_rd_p1[gsb_b]), .O(r_rd_p1_e[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rdp1_f (.I0(r_rd_p1[gsb_b]), .O(r_rd_p1_f[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rdp1_o (.I0(r_rd_p1[gsb_b]), .O(r_rd_p1_o[gsb_b]));

			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rdp2_e (.I0(r_rd_p2[gsb_b]), .O(r_rd_p2_e[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rdp2_f (.I0(r_rd_p2[gsb_b]), .O(r_rd_p2_f[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rdp2_o (.I0(r_rd_p2[gsb_b]), .O(r_rd_p2_o[gsb_b]));

			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rdp3_e (.I0(r_rd_p3[gsb_b]), .O(r_rd_p3_e[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rdp3_f (.I0(r_rd_p3[gsb_b]), .O(r_rd_p3_f[gsb_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rdp3_o (.I0(r_rd_p3[gsb_b]), .O(r_rd_p3_o[gsb_b]));
		end
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_wide_e (.I0(r_wide), .O(r_wide_e));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_wide_f (.I0(r_wide), .O(r_wide_f));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_wide_o (.I0(r_wide), .O(r_wide_o));
`else
		assign r_rs1_e = r_rs1; assign r_rs1_f = r_rs1;
		assign r_rs2_e = r_rs2; assign r_rs2_f = r_rs2;
		assign r_rs3_e = r_rs3; assign r_rs3_f = r_rs3;
		assign r_rs1p_e = r_rs1p; assign r_rs1p_f = r_rs1p;
		assign r_rs3p_e = r_rs3p; assign r_rs3p_f = r_rs3p;
		assign r_rd_e = r_rd; assign r_rd_f = r_rd; assign r_rd_o = r_rd;
		assign r_rd_p1_e = r_rd_p1; assign r_rd_p1_f = r_rd_p1; assign r_rd_p1_o = r_rd_p1;
		assign r_rd_p2_e = r_rd_p2; assign r_rd_p2_f = r_rd_p2; assign r_rd_p2_o = r_rd_p2;
		assign r_rd_p3_e = r_rd_p3; assign r_rd_p3_f = r_rd_p3; assign r_rd_p3_o = r_rd_p3;
		assign r_wide_e = r_wide; assign r_wide_f = r_wide; assign r_wide_o = r_wide;
`endif

		wire [WARP_W-1:0] r_warp_e, r_warp_f, r_warp_c, r_warp_w;
`ifdef SYNTH_KINTEX7
		genvar gsb_w;
		for (gsb_w = 0; gsb_w < WARP_W; gsb_w = gsb_w + 1) begin : g_sb_warp_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rw_e (.I0(r_warp[gsb_w]), .O(r_warp_e[gsb_w]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rw_f (.I0(r_warp[gsb_w]), .O(r_warp_f[gsb_w]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rw_c (.I0(r_warp[gsb_w]), .O(r_warp_c[gsb_w]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rw_w (.I0(r_warp[gsb_w]), .O(r_warp_w[gsb_w]));
		end
`else
		assign r_warp_e = r_warp;
		assign r_warp_f = r_warp;
		assign r_warp_c = r_warp;
		assign r_warp_w = r_warp;
`endif

		reg [SB_ENTRIES-1:0]   w_ev_r;
		wire [SB_ENTRIES-1:0]  w_ev_r_hit, w_ev_r_free, w_ev_r_alloc;
`ifdef SYNTH_KINTEX7
		genvar gsb_ev;
		for (gsb_ev = 0; gsb_ev < SB_ENTRIES; gsb_ev = gsb_ev + 1) begin : g_sb_ev_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_ev_hit   (.I0(w_ev_r[gsb_ev]), .O(w_ev_r_hit[gsb_ev]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_ev_free  (.I0(w_ev_r[gsb_ev]), .O(w_ev_r_free[gsb_ev]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_ev_alloc (.I0(w_ev_r[gsb_ev]), .O(w_ev_r_alloc[gsb_ev]));
		end
`else
		assign w_ev_r_hit   = w_ev_r;
		assign w_ev_r_free  = w_ev_r;
		assign w_ev_r_alloc = w_ev_r;
`endif
		reg [SB_ENTRIES*6-1:0] w_er0_r, w_er1_r, w_er2_r, w_er3_r;
		reg [SB_ENTRIES-1:0]   w_ewd_r;
		reg [CNT_W-1:0]        w_rcm_r, w_rct_r, w_rcx_r;

		/* Stage 1 -> 2 registers */
		reg [SB_ENTRIES-1:0] r_ehit_r12, r_ehit_r345, r_ehit_w;
		reg                  r_have_free;
		reg [SBE_W:0]        r_free_e;
		(* dont_touch = "true" *) reg [NE-1:0] r_alloc_mask;
		(* dont_touch = "true" *) reg [NE-1:0] r_alloc_mask_hi;
		reg                  r_cnt_wait, r_cnt_full;
		reg [NIF-1:0]        r_f_hit_r12, r_f_hit_r345w;
		reg [NSC-1:0]        r_c_hit_r12, r_c_hit_r345w;
		reg                  r_rel_s1, r_rel_s2;

		reg [SBE_W:0] w_free_e_s1;
		integer s1j;
		always @(*) begin
			w_free_e_s1 = {(SBE_W+1){1'b1}};
			for (s1j = SB_ENTRIES - 1; s1j >= 0; s1j = s1j - 1)
				if (!w_ev_r_free[s1j])
					w_free_e_s1 = s1j[SBE_W:0];
		end

		wire s0_en = u_valid && (st_issue == 2'd0) && !rst_p;
		wire s1_en = u_valid && (st_issue == 2'd1) && !rst_p;

		wire s0_we_0, s0_we_1, s0_we_2, s0_we_3, s0_we_4, s0_we_5, s0_we_6, s0_we_7;
		wire s0_we_8a, s0_we_8b, s0_we_9a, s0_we_9b, s0_we_10a, s0_we_10b, s0_we_11a, s0_we_11b;
		wire s0_we_cnt;

		wire s1_we_0, s1_we_1, s1_we_2a, s1_we_2b, s1_we_3a, s1_we_3b, s1_we_4, s1_we_5, s1_we_6;

`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_0   (.I0(s0_en), .O(s0_we_0));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_1   (.I0(s0_en), .O(s0_we_1));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_2   (.I0(s0_en), .O(s0_we_2));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_3   (.I0(s0_en), .O(s0_we_3));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_4   (.I0(s0_en), .O(s0_we_4));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_5   (.I0(s0_en), .O(s0_we_5));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_6   (.I0(s0_en), .O(s0_we_6));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_7   (.I0(s0_en), .O(s0_we_7));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_8a  (.I0(s0_en), .O(s0_we_8a));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_8b  (.I0(s0_en), .O(s0_we_8b));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_9a  (.I0(s0_en), .O(s0_we_9a));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_9b  (.I0(s0_en), .O(s0_we_9b));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_10a (.I0(s0_en), .O(s0_we_10a));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_10b (.I0(s0_en), .O(s0_we_10b));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_11a (.I0(s0_en), .O(s0_we_11a));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_11b (.I0(s0_en), .O(s0_we_11b));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s0_cnt (.I0(s0_en), .O(s0_we_cnt));

		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s1_0   (.I0(s1_en), .O(s1_we_0));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s1_1   (.I0(s1_en), .O(s1_we_1));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s1_2a  (.I0(s1_en), .O(s1_we_2a));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s1_2b  (.I0(s1_en), .O(s1_we_2b));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s1_3a  (.I0(s1_en), .O(s1_we_3a));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s1_3b  (.I0(s1_en), .O(s1_we_3b));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s1_4   (.I0(s1_en), .O(s1_we_4));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s1_5   (.I0(s1_en), .O(s1_we_5));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_s1_6   (.I0(s1_en), .O(s1_we_6));
`else
		assign s0_we_0   = s0_en;
		assign s0_we_1   = s0_en;
		assign s0_we_2   = s0_en;
		assign s0_we_3   = s0_en;
		assign s0_we_4   = s0_en;
		assign s0_we_5   = s0_en;
		assign s0_we_6   = s0_en;
		assign s0_we_7   = s0_en;
		assign s0_we_8a  = s0_en;
		assign s0_we_8b  = s0_en;
		assign s0_we_9a  = s0_en;
		assign s0_we_9b  = s0_en;
		assign s0_we_10a = s0_en;
		assign s0_we_10b = s0_en;
		assign s0_we_11a = s0_en;
		assign s0_we_11b = s0_en;
		assign s0_we_cnt = s0_en;

		assign s1_we_0   = s1_en;
		assign s1_we_1   = s1_en;
		assign s1_we_2a  = s1_en;
		assign s1_we_2b  = s1_en;
		assign s1_we_3a  = s1_en;
		assign s1_we_3b  = s1_en;
		assign s1_we_4   = s1_en;
		assign s1_we_5   = s1_en;
		assign s1_we_6   = s1_en;
`endif

		integer sw, sj, sm;
		always @(posedge clk) begin
			if (rst_p) begin
				st_issue <= 2'd0;
			end else begin
				if (!u_valid) begin
					st_issue <= 2'd0;
				end else if (st_issue == 2'd0) begin
					st_issue <= 2'd1;
				end else if (st_issue == 2'd1) begin
					st_issue <= 2'd2;
				end else begin
					st_issue <= 2'd0;
				end
			end
			if (s0_we_0) begin
				r_rs1  <= rs1[5:0];
				r_rs2  <= rs2[5:0];
			end
			if (s0_we_1) begin
				r_rs3  <= rs3[5:0];
				r_rs1p <= rs1p_lo;
			end
			if (s0_we_2) begin
				r_rs3p <= rs3p_lo;
				r_rd   <= rd[5:0];
			end
			if (s0_we_3) begin
				r_rd_p1 <= rd_p1;
				r_rd_p2 <= rd_p2;
			end
			if (s0_we_4) begin
				r_rd_p3 <= rd_p3;
				r_src1  <= src1;
				r_src2  <= src2;
				r_src3  <= src3;
				r_src4  <= src4;
				r_src5  <= src5;
				r_dst   <= dst;
				r_wide  <= wide;
				r_is_long <= is_long;
				r_need_e  <= need_e;
			end
			if (s0_we_5) begin
				r_is_wait  <= is_wait;
				r_is_fence <= is_fence;
				r_is_end   <= is_end;
				r_cls      <= cls;
				r_warp     <= u_warp_r;
				r_rel_s1   <= rel_valid && (rel_warp == u_warp_r);
			end
			if (s0_we_6) begin
				r_imm12 <= imm[11:0];
			end
			if (s0_we_7) begin
				for (sw = 0; sw < NWARPS; sw = sw + 1) begin
					if (u_warp_ev == sw[WARP_W-1:0]) begin
						w_ev_r  <= ev_comb[sw*SB_ENTRIES +: SB_ENTRIES];
						w_ewd_r <= e_wide[sw*SB_ENTRIES +: SB_ENTRIES];
					end
				end
			end
			if (s0_we_8a) begin
				for (sw = 0; sw < NWARPS; sw = sw + 1) begin
					if (u_warp_r0 == sw[WARP_W-1:0]) begin
						w_er0_r[SB_ENTRIES*3-1:0] <= e_r0[sw*SB_ENTRIES*6 +: SB_ENTRIES*3];
					end
				end
			end
			if (s0_we_8b) begin
				for (sw = 0; sw < NWARPS; sw = sw + 1) begin
					if (u_warp_r0 == sw[WARP_W-1:0]) begin
						w_er0_r[SB_ENTRIES*6-1:SB_ENTRIES*3] <= e_r0[sw*SB_ENTRIES*6 + SB_ENTRIES*3 +: SB_ENTRIES*3];
					end
				end
			end
			if (s0_we_9a) begin
				for (sw = 0; sw < NWARPS; sw = sw + 1) begin
					if (u_warp_r1 == sw[WARP_W-1:0]) begin
						w_er1_r[SB_ENTRIES*3-1:0] <= e_r1[sw*SB_ENTRIES*6 +: SB_ENTRIES*3];
					end
				end
			end
			if (s0_we_9b) begin
				for (sw = 0; sw < NWARPS; sw = sw + 1) begin
					if (u_warp_r1 == sw[WARP_W-1:0]) begin
						w_er1_r[SB_ENTRIES*6-1:SB_ENTRIES*3] <= e_r1[sw*SB_ENTRIES*6 + SB_ENTRIES*3 +: SB_ENTRIES*3];
					end
				end
			end
			if (s0_we_10a) begin
				for (sw = 0; sw < NWARPS; sw = sw + 1) begin
					if (u_warp_r2 == sw[WARP_W-1:0]) begin
						w_er2_r[SB_ENTRIES*3-1:0] <= e_r2[sw*SB_ENTRIES*6 +: SB_ENTRIES*3];
					end
				end
			end
			if (s0_we_10b) begin
				for (sw = 0; sw < NWARPS; sw = sw + 1) begin
					if (u_warp_r2 == sw[WARP_W-1:0]) begin
						w_er2_r[SB_ENTRIES*6-1:SB_ENTRIES*3] <= e_r2[sw*SB_ENTRIES*6 + SB_ENTRIES*3 +: SB_ENTRIES*3];
					end
				end
			end
			if (s0_we_11a) begin
				for (sw = 0; sw < NWARPS; sw = sw + 1) begin
					if (u_warp_r3 == sw[WARP_W-1:0]) begin
						w_er3_r[SB_ENTRIES*3-1:0] <= e_r3[sw*SB_ENTRIES*6 +: SB_ENTRIES*3];
					end
				end
			end
			if (s0_we_11b) begin
				for (sw = 0; sw < NWARPS; sw = sw + 1) begin
					if (u_warp_r3 == sw[WARP_W-1:0]) begin
						w_er3_r[SB_ENTRIES*6-1:SB_ENTRIES*3] <= e_r3[sw*SB_ENTRIES*6 + SB_ENTRIES*3 +: SB_ENTRIES*3];
					end
				end
			end
			if (s0_we_cnt) begin
				for (sw = 0; sw < NWARPS; sw = sw + 1) begin
					if (u_warp_cnt == sw[WARP_W-1:0]) begin
						w_rcm_r <= cm_next[sw*CNT_W +: CNT_W];
						w_rct_r <= ct_next[sw*CNT_W +: CNT_W];
						w_rcx_r <= cx_next[sw*CNT_W +: CNT_W];
					end
				end
			end

			if (s1_we_0) begin
				r_rel_s2 <= r_rel_s1 || (rel_valid && (rel_warp == r_warp_w));
				for (sj = 0; sj < SB_ENTRIES; sj = sj + 1) begin
					r_ehit_r12[sj] <= w_ev_r_hit[sj] && (
						(r_src1 && hit_entry(r_rs1_e, w_er0_r[sj*6 +: 6], w_er1_r[sj*6 +: 6], w_er2_r[sj*6 +: 6], w_er3_r[sj*6 +: 6], w_ewd_r[sj])) ||
						(r_src2 && hit_entry(r_rs2_e, w_er0_r[sj*6 +: 6], w_er1_r[sj*6 +: 6], w_er2_r[sj*6 +: 6], w_er3_r[sj*6 +: 6], w_ewd_r[sj]))
					);
					r_ehit_r345[sj] <= w_ev_r_hit[sj] && (
						(r_src3 && hit_entry(r_rs3_e,  w_er0_r[sj*6 +: 6], w_er1_r[sj*6 +: 6], w_er2_r[sj*6 +: 6], w_er3_r[sj*6 +: 6], w_ewd_r[sj])) ||
						(r_src4 && hit_entry(r_rs1p_e, w_er0_r[sj*6 +: 6], w_er1_r[sj*6 +: 6], w_er2_r[sj*6 +: 6], w_er3_r[sj*6 +: 6], w_ewd_r[sj])) ||
						(r_src5 && hit_entry(r_rs3p_e, w_er0_r[sj*6 +: 6], w_er1_r[sj*6 +: 6], w_er2_r[sj*6 +: 6], w_er3_r[sj*6 +: 6], w_ewd_r[sj]))
					);
					r_ehit_w[sj] <= w_ev_r_hit[sj] && r_dst && (
						(w_er0_r[sj*6 +: 6] == r_rd_e) ||
						(r_wide_e && (w_er0_r[sj*6 +: 6] == r_rd_p1_e || w_er0_r[sj*6 +: 6] == r_rd_p2_e || w_er0_r[sj*6 +: 6] == r_rd_p3_e)) ||
						(w_ewd_r[sj] && (r_rd_e == w_er1_r[sj*6 +: 6] || r_rd_e == w_er2_r[sj*6 +: 6] || r_rd_e == w_er3_r[sj*6 +: 6]))
					);
				end
			end
			if (s1_we_1) begin
				r_have_free <= ~(&w_ev_r_free);
				r_free_e    <= w_free_e_s1;
				r_cnt_wait <= (r_is_wait && !((w_rcm_r <= {2'd0, r_imm12[3:0]}) && (w_rct_r <= {2'd0, r_imm12[7:4]}) && (w_rcx_r <= {2'd0, r_imm12[11:8]}))) ||
					(r_is_fence && r_imm12[0] && (w_rcm_r != 0)) ||
					(r_is_end && (w_rcm_r != 0 || w_rct_r != 0 || w_rcx_r != 0));
				r_cnt_full <= r_is_long && (
					(r_cls == ATG_CLS_M && w_rcm_r == {CNT_W{1'b1}}) ||
					(r_cls == ATG_CLS_T && w_rct_r == {CNT_W{1'b1}}) ||
					(r_cls == ATG_CLS_X && w_rcx_r == {CNT_W{1'b1}})
				);
			end
			if (s1_we_2a) begin
				for (sw = 0; sw < NE/2; sw = sw + 1) begin
					r_alloc_mask[sw] <= r_need_e && !w_ev_r_alloc[sw[SBE_W-1:0]] &&
						(w_free_e_s1[SBE_W-1:0] == sw[SBE_W-1:0]) &&
						(r_warp_e == sw[NE_W-1:SBE_W]);
				end
			end
			if (s1_we_2b) begin
				for (sw = NE/2; sw < NE; sw = sw + 1) begin
					r_alloc_mask[sw] <= r_need_e && !w_ev_r_alloc[sw[SBE_W-1:0]] &&
						(w_free_e_s1[SBE_W-1:0] == sw[SBE_W-1:0]) &&
						(r_warp_e == sw[NE_W-1:SBE_W]);
				end
			end
			if (s1_we_3a) begin
				for (sw = 0; sw < NE/2; sw = sw + 1) begin
					r_alloc_mask_hi[sw] <= r_need_e && !w_ev_r_alloc[sw[SBE_W-1:0]] &&
						(w_free_e_s1[SBE_W-1:0] == sw[SBE_W-1:0]) &&
						(r_warp_e == sw[NE_W-1:SBE_W]);
				end
			end
			if (s1_we_3b) begin
				for (sw = NE/2; sw < NE; sw = sw + 1) begin
					r_alloc_mask_hi[sw] <= r_need_e && !w_ev_r_alloc[sw[SBE_W-1:0]] &&
						(w_free_e_s1[SBE_W-1:0] == sw[SBE_W-1:0]) &&
						(r_warp_e == sw[NE_W-1:SBE_W]);
				end
			end
			if (s1_we_4) begin
				for (sm = 0; sm < NIF; sm = sm + 1) begin
					r_f_hit_r12[sm] <= f_valid[sm] && f_short[sm] && (f_warp[sm*WARP_W +: WARP_W] == r_warp_f) && !f_rd[sm*7 + 6] && (
						(r_src1 && (r_rs1_f == f_rd[sm*7 +: 6])) ||
						(r_src2 && (r_rs2_f == f_rd[sm*7 +: 6]))
					);
					r_f_hit_r345w[sm] <= f_valid[sm] && f_short[sm] && (f_warp[sm*WARP_W +: WARP_W] == r_warp_f) && !f_rd[sm*7 + 6] && (
						(r_src3 && (r_rs3_f  == f_rd[sm*7 +: 6])) ||
						(r_src4 && (r_rs1p_f == f_rd[sm*7 +: 6])) ||
						(r_src5 && (r_rs3p_f == f_rd[sm*7 +: 6])) ||
						(r_dst && r_is_long && (f_rd[sm*7 +: 6] != 6'h3F) && (
							(f_rd[sm*7 +: 6] == r_rd_f) ||
							(r_wide_f && (f_rd[sm*7 +: 6] == r_rd_p1_f || f_rd[sm*7 +: 6] == r_rd_p2_f || f_rd[sm*7 +: 6] == r_rd_p3_f))
						))
					);
				end
			end
			if (s1_we_5) begin
				for (sm = 0; sm < NSC; sm = sm + 1) begin
					r_c_hit_r12[sm] <= c_valid[sm] && (c_warp[sm*WARP_W +: WARP_W] == r_warp_c) && ((SHORT_LAT + 1 - sm) > G + 1) && (
						(r_src1 && (r_rs1_f == c_rd[sm*6 +: 6])) ||
						(r_src2 && (r_rs2_f == c_rd[sm*6 +: 6]))
					);
				end
			end
			if (s1_we_6) begin
				for (sm = 0; sm < NSC; sm = sm + 1) begin
					r_c_hit_r345w[sm] <= c_valid[sm] && (c_warp[sm*WARP_W +: WARP_W] == r_warp_c) && (
						(((SHORT_LAT + 1 - sm) > G + 1) && (
							(r_src3 && (r_rs3_f  == c_rd[sm*6 +: 6])) ||
							(r_src4 && (r_rs1p_f == c_rd[sm*6 +: 6])) ||
							(r_src5 && (r_rs3p_f == c_rd[sm*6 +: 6]))
						)) ||
						(r_dst && r_is_long && (
							(c_rd[sm*6 +: 6] == r_rd_f) ||
							(r_wide_f && (c_rd[sm*6 +: 6] == r_rd_p1_f || c_rd[sm*6 +: 6] == r_rd_p2_f || c_rd[sm*6 +: 6] == r_rd_p3_f))
						))
					);
				end
			end
		end

		assign hz_long   = (|r_ehit_r12) || (|r_ehit_r345) || (|r_ehit_w);
		assign have_free = r_have_free;
		assign free_e    = r_free_e;
		assign hz_short  = (|r_f_hit_r12) || (|r_f_hit_r345w) || (|r_c_hit_r12) || (|r_c_hit_r345w);
		assign cnt_wait  = r_cnt_wait;
		assign cnt_full  = r_cnt_full;
		assign go_gate   = (st_issue == 2'd2);
		genvar gpw;
		for (gpw = 0; gpw < NWARPS; gpw = gpw + 1) begin : g_pw
			assign pipe_wake[gpw] = (st_issue == 2'd2) && r_rel_s2 && (r_warp_w == gpw[WARP_W-1:0]);
		end
	end else begin : g_comb_issue
		assign pipe_wake = {NWARPS{1'b0}};
		/* Per-warp parallel long hazard checks and free entry search. */
		wire [NWARPS-1:0] warp_hz_long;
		wire [NWARPS-1:0] warp_have_free;
		wire [NWARPS*(SBE_W+1)-1:0] warp_free_e;

		genvar gw, gj;
		for (gw = 0; gw < NWARPS; gw = gw + 1) begin : g_whz
			wire [SB_ENTRIES-1:0] entry_hit;
			for (gj = 0; gj < SB_ENTRIES; gj = gj + 1) begin : g_ehit
				localparam EIDX = gw * SB_ENTRIES + gj;
				wire ev_val = ev[EIDX];
				wire [5:0] er0 = e_r0[EIDX*6 +: 6];
				wire [5:0] er1 = e_r1[EIDX*6 +: 6];
				wire [5:0] er2 = e_r2[EIDX*6 +: 6];
				wire [5:0] er3 = e_r3[EIDX*6 +: 6];
				wire ewd = e_wide[EIDX];

				wire rhit = (src1 && hit_entry(rs1[5:0], er0, er1, er2, er3, ewd)) ||
				            (src2 && hit_entry(rs2[5:0], er0, er1, er2, er3, ewd)) ||
				            (src3 && hit_entry(rs3[5:0], er0, er1, er2, er3, ewd)) ||
				            (src4 && hit_entry(rs1p[5:0], er0, er1, er2, er3, ewd)) ||
				            (src5 && hit_entry(rs3p[5:0], er0, er1, er2, er3, ewd));
				wire whit = dst && (
				            (er0 == rd[5:0]) ||
				            (wide && (er0 == rd_p1 || er0 == rd_p2 || er0 == rd_p3)) ||
				            (ewd && (rd[5:0] == er1 || rd[5:0] == er2 || rd[5:0] == er3)));

				assign entry_hit[gj] = ev_val && (rhit || whit);
			end

			assign warp_hz_long[gw] = |entry_hit;

			wire [SB_ENTRIES-1:0] wev = ev[gw*SB_ENTRIES +: SB_ENTRIES];
			assign warp_have_free[gw] = ~(&wev);
			reg [SBE_W:0] w_free;
			integer ej;
			always @(*) begin
				w_free = {(SBE_W+1){1'b1}};
				for (ej = SB_ENTRIES - 1; ej >= 0; ej = ej - 1)
					if (!wev[ej])
						w_free = ej[SBE_W:0];
			end
			assign warp_free_e[gw*(SBE_W+1) +: (SBE_W+1)] = w_free;
		end

		assign hz_long = warp_hz_long[u_warp_w];
		assign have_free = warp_have_free[u_warp_w];
		reg [SBE_W:0] free_e_c;
		integer mfe;
		always @(*) begin
			free_e_c = {(SBE_W+1){1'b1}};
			for (mfe = 0; mfe < NWARPS; mfe = mfe + 1)
				if (u_warp_m == mfe[WARP_W-1:0])
					free_e_c = warp_free_e[mfe*(SBE_W+1) +: (SBE_W+1)];
		end
		assign free_e = free_e_c;

		reg [CNT_W-1:0] rcm, rct, rcx;
		integer urw;
		always @(*) begin
			{rcm, rct, rcx} = {(3*CNT_W){1'b0}};
			for (urw = 0; urw < NWARPS; urw = urw + 1)
				if (u_warp_m == urw[WARP_W-1:0]) begin
					{rcm, rct, rcx} = {warp_rcm[urw*CNT_W +: CNT_W], warp_rct[urw*CNT_W +: CNT_W],
						warp_rcx[urw*CNT_W +: CNT_W]};
				end
		end

		reg hz_short_c;
		integer m;
		always @(*) begin
			hz_short_c = 1'b0;
			for (m = 0; m < NIF; m = m + 1)
				if (f_valid[m] && f_short[m] && f_warp[(m)*WARP_W +: WARP_W] == u_warp_f) begin
					if ((!BYPASS || is_long || !(f_pipe_alu[m] || f_pipe_fpu[m]) || (G < 4)) &&
					    ((src1 && hit(rs1, f_rd[(m)*7 +: 7])) || (src2 && hit(rs2, f_rd[(m)*7 +: 7])) ||
					    (src3 && hit(rs3, f_rd[(m)*7 +: 7])) || (src4 && hit(rs1p, f_rd[(m)*7 +: 7])) ||
					    (src5 && hit(rs3p, f_rd[(m)*7 +: 7]))))
						hz_short_c = 1'b1;
					if (dst && is_long && (f_rd[(m)*7 +: 7] < 7'd63) &&
					    (hit(f_rd[(m)*7 +: 7], {1'b0, rd[5:0]}) ||
					     (wide && (hit(f_rd[(m)*7 +: 7], {1'b0, rd_p1}) ||
					               hit(f_rd[(m)*7 +: 7], {1'b0, rd_p2}) ||
					               hit(f_rd[(m)*7 +: 7], {1'b0, rd_p3})))))
						hz_short_c = 1'b1;
				end
			for (m = 0; m < NSC; m = m + 1)
				if (c_valid[m] && c_warp[(m)*WARP_W +: WARP_W] == u_warp_f) begin
					if (((!BYPASS && (SHORT_LAT + 1 - m) > G + 1) ||
					     (BYPASS && is_long && (SHORT_LAT + 1 - m) > 1) ||
					     (BYPASS && !is_long && !c_pipe_alu[m] && !c_pipe_fpu[m] && (SHORT_LAT + 1 - m) > G + 1) ||
					     (BYPASS && !is_long && c_pipe_alu[m] && (SHORT_LAT + 1 - m) > SHORT_BP_WAIT_ALU) ||
					     (BYPASS && !is_long && c_pipe_fpu[m] && (SHORT_LAT + 1 - m) > SHORT_BP_WAIT_FPU)) &&
					    ((src1 && hit(rs1, {1'b0, c_rd[(m)*6 +: 6]})) ||
					    (src2 && hit(rs2, {1'b0, c_rd[(m)*6 +: 6]})) || (src3 && hit(rs3, {1'b0, c_rd[(m)*6 +: 6]})) ||
					    (src4 && hit(rs1p, {1'b0, c_rd[(m)*6 +: 6]})) ||
					    (src5 && hit(rs3p, {1'b0, c_rd[(m)*6 +: 6]}))))
						hz_short_c = 1'b1;
					if (dst && is_long &&
					    (c_rd[(m)*6 +: 6] == rd[5:0] ||
					     (wide && (c_rd[(m)*6 +: 6] == rd_p1 ||
					               c_rd[(m)*6 +: 6] == rd_p2 ||
					               c_rd[(m)*6 +: 6] == rd_p3))))
						hz_short_c = 1'b1;
				end
		end
		assign hz_short = hz_short_c;

		wire inc_any = inc_m[u_warp_c] || inc_t[u_warp_c] || inc_x[u_warp_c];
		wire wait_ok = !inc_any && (rcm <= {2'd0, imm[3:0]}) && (rct <= {2'd0, imm[7:4]}) && (rcx <= {2'd0, imm[11:8]});
		assign cnt_wait = (is_wait && !wait_ok) || (is_fence && imm[0] && (rcm != 0 || inc_m[u_warp_c])) ||
			(is_end && (rcm != 0 || rct != 0 || rcx != 0 || inc_any));
		wire [CNT_W-1:0] rcc = cls == ATG_CLS_M ? rcm : cls == ATG_CLS_T ? rct : rcx;
		assign cnt_full = is_long && rcc == {CNT_W{1'b1}};
		assign go_gate  = 1'b1;
	end
	endgenerate

	wire replay_long = !ill && (hz_long || cnt_full || (need_e && !have_free) || rq_wait);
	wire is_cnt_dep = is_fence || is_end;
	wire replay_eff = replay_long || (is_cnt_dep && cnt_wait);
	wire replay = replay_long || (!is_long && cnt_wait);
	wire hold = wb_stall || hz_short || f_valid[NIF-1];
	wire go = u_valid && go_gate && !hold;
	wire no_issue = ill || is_nop || is_wait || replay_eff;
	assign i_valid = go && !no_issue;
	wire issued = i_valid && i_ready;
	wire issued_long = go && !ill && !replay_long && i_ready;
	wire fast_ready = i_ready || ill || is_nop || is_wait;
	assign u_ready = go && fast_ready;
	assign i_warp = u_warp_out;
	assign i_pc = u_pc;
	assign i_uop = u_uop;
	assign i_sbe = need_e ? free_e : {(SBE_W+1){1'b1}};

	wire issued_cand = !no_issue && i_ready;
	assign fb_valid = u_valid && u_ready;
	assign fb_warp = u_warp_out;
	assign fb_kind = ill ? 2'd1 : replay ? 2'd2 : (issued_cand && wc_kind) ? 2'd1 : 2'd0;
	assign fault = go && ill;
	assign fault_pc = u_pc;

	genvar w;
	generate
		for (w = 0; w < NWARPS; w = w + 1) begin : wk
			assign wake[w] = (rel_valid && rel_warp == w[WARP_W-1:0]) || pipe_wake[w];
		end
	endgenerate

	/* State updates. */
	wire alloc = issued_long && need_e;
	wire [NE_W-1:0] alloc_idx = {u_warp_r, free_e[SBE_W-1:0]};	/* free_e < SB_ENTRIES at an alloc */

	integer gi;
	always @(posedge clk) begin
		if (rst_p) begin
			inc_m <= {NWARPS{1'b0}};
			inc_t <= {NWARPS{1'b0}};
			inc_x <= {NWARPS{1'b0}};
		end else begin
			for (gi = 0; gi < NWARPS; gi = gi + 1) begin
				inc_m[gi] <= issued_long && (u_warp_c == gi[WARP_W-1:0]) && (cls == ATG_CLS_M);
				inc_t[gi] <= issued_long && (u_warp_c == gi[WARP_W-1:0]) && (cls == ATG_CLS_T);
				inc_x[gi] <= issued_long && (u_warp_c == gi[WARP_W-1:0]) && (cls == ATG_CLS_X);
			end
		end
	end

	wire [5:0] e_wr_r0, e_wr_r1, e_wr_r2, e_wr_r3;
	wire       e_wr_wide;
	(* dont_touch = "true" *) wire [NE-1:0] alloc_e_en;
	(* dont_touch = "true" *) wire [NE-1:0] alloc_e_en_hi;
	wire [NE-1:0] alloc_v_en;
	genvar gqe;
	generate
	if (FAST_REL == 0) begin : g_ewr_pipe
		assign e_wr_r0   = g_pipe_issue.r_rd_o;
		assign e_wr_r1   = g_pipe_issue.r_rd_p1_o;
		assign e_wr_r2   = g_pipe_issue.r_rd_p2_o;
		assign e_wr_r3   = g_pipe_issue.r_rd_p3_o;
		assign e_wr_wide = g_pipe_issue.r_wide_o;
		for (gqe = 0; gqe < NE; gqe = gqe + 1) begin : g_am
			assign alloc_e_en[gqe]    = u_valid && go_gate && g_pipe_issue.r_alloc_mask[gqe];
			assign alloc_e_en_hi[gqe] = u_valid && go_gate && g_pipe_issue.r_alloc_mask_hi[gqe];
			assign alloc_v_en[gqe]    = issued_long && g_pipe_issue.r_alloc_mask[gqe];
		end
	end else begin : g_ewr_comb
		assign e_wr_r0   = rd[5:0];
		assign e_wr_r1   = rd_p1;
		assign e_wr_r2   = rd_p2;
		assign e_wr_r3   = rd_p3;
		assign e_wr_wide = wide;
		for (gqe = 0; gqe < NE; gqe = gqe + 1) begin : g_am
			assign alloc_e_en[gqe]    = u_valid && go_gate && need_e && have_free && (alloc_idx == gqe[NE_W-1:0]);
			assign alloc_e_en_hi[gqe] = u_valid && go_gate && need_e && have_free && (alloc_idx == gqe[NE_W-1:0]);
			assign alloc_v_en[gqe]    = alloc && (alloc_idx == gqe[NE_W-1:0]);
		end
	end
	endgenerate

	wire [NIF-1:0] f_shift = x_end ? {1'b0, f_valid[NIF-1:1]} : f_valid;
	integer q;
	always @(posedge clk) begin
		if (rst_p) begin
			e_valid <= {NE{1'b0}};
			cm <= {(NWARPS*CNT_W){1'b0}};
			ct <= {(NWARPS*CNT_W){1'b0}};
			cx <= {(NWARPS*CNT_W){1'b0}};
			f_valid    <= {NIF{1'b0}};
			f_pipe_alu <= {NIF{1'b0}};
			f_pipe_fpu <= {NIF{1'b0}};
			c_valid    <= {NSC{1'b0}};
			c_pipe_alu <= {NSC{1'b0}};
			c_pipe_fpu <= {NSC{1'b0}};
		end else begin
			for (q = 0; q < NE; q = q + 1) begin
				if (alloc_v_en[q])
					e_valid[q] <= 1'b1;
				else
					e_valid[q] <= ev_comb[q];
			end
			cm <= cm_next;
			ct <= ct_next;
			cx <= cx_next;

			c_valid[0]    <= x_end && f_valid[0] && f_short[0];
			c_pipe_alu[0] <= f_pipe_alu[0];
			c_pipe_fpu[0] <= f_pipe_fpu[0];
			for (q = 1; q < NSC; q = q + 1) begin
				c_valid[q]    <= c_valid[q-1];
				c_pipe_alu[q] <= c_pipe_alu[q-1];
				c_pipe_fpu[q] <= c_pipe_fpu[q-1];
			end

			if (issued && !x_end)
				f_valid <= {f_valid[NIF-2:0], 1'b1};
			else if (!issued && x_end)
				f_valid <= {1'b0, f_valid[NIF-1:1]};
			else
				f_valid <= f_valid;

			for (q = 0; q < NIF - 1; q = q + 1) begin
				if (x_end && f_valid[q+1]) begin
					f_pipe_alu[q] <= f_pipe_alu[q+1];
					f_pipe_fpu[q] <= f_pipe_fpu[q+1];
				end else if (!f_shift[q]) begin
					f_pipe_alu[q] <= (unit == ATG_UNIT_ALU);
					f_pipe_fpu[q] <= (unit == ATG_UNIT_FPU);
				end
			end
			if (!f_shift[NIF-1]) begin
				f_pipe_alu[NIF-1] <= (unit == ATG_UNIT_ALU);
				f_pipe_fpu[NIF-1] <= (unit == ATG_UNIT_FPU);
			end
		end

		for (q = 0; q < NE; q = q + 1) begin
			if (alloc_e_en[q]) begin
				e_r0[q*6 +: 6] <= e_wr_r0;
				e_r1[q*6 +: 6] <= e_wr_r1;
			end
			if (alloc_e_en_hi[q]) begin
				e_r2[q*6 +: 6] <= e_wr_r2;
				e_r3[q*6 +: 6] <= e_wr_r3;
				e_wide[q]      <= e_wr_wide;
			end
		end

		c_warp[0 +: WARP_W] <= f_warp[0 +: WARP_W];
		c_rd[0 +: 6]        <= f_rd[5:0];
		for (q = 1; q < NSC; q = q + 1) begin
			c_warp[q*WARP_W +: WARP_W] <= c_warp[(q-1)*WARP_W +: WARP_W];
			c_rd[q*6 +: 6]             <= c_rd[(q-1)*6 +: 6];
		end

		for (q = 0; q < NIF - 1; q = q + 1) begin
			if (x_end && f_valid[q+1]) begin
				f_warp[q*WARP_W +: WARP_W] <= f_warp[(q+1)*WARP_W +: WARP_W];
				f_rd[q*7 +: 7]             <= f_rd[(q+1)*7 +: 7];
				f_short[q]                 <= f_short[q+1];
			end else if (!f_shift[q]) begin
				f_warp[q*WARP_W +: WARP_W] <= u_warp_r;
				f_rd[q*7 +: 7]             <= rd;
				f_short[q]                 <= short_w;
			end
		end
		if (!f_shift[NIF-1]) begin
			f_warp[(NIF-1)*WARP_W +: WARP_W] <= u_warp_r;
			f_rd[(NIF-1)*7 +: 7]             <= rd;
			f_short[NIF-1]                   <= short_w;
		end
	end

	reg any_c;
	always @(*) begin
		any_c = |e_valid || |f_valid || |c_valid;
		for (n = 0; n < NWARPS; n = n + 1)
			if (cm[(n)*CNT_W +: CNT_W] != 0 || ct[(n)*CNT_W +: CNT_W] != 0 || cx[(n)*CNT_W +: CNT_W] != 0)
				any_c = 1'b1;
	end
	assign busy = any_c;

	/* Warp readiness feedback to scheduler (Phase 012) */
	reg [NWARPS-1:0] r_warp_ready;
	genvar gw_r;
	generate
		for (gw_r = 0; gw_r < NWARPS; gw_r = gw_r + 1) begin : g_wr
			wire [SB_ENTRIES-1:0] w_ev = e_valid[gw_r * SB_ENTRIES +: SB_ENTRIES];
			wire w_u_hold = u_valid && (u_warp_w == gw_r[WARP_W-1:0]) && !i_valid;
			wire w_rdy = !(|w_ev) && !w_u_hold;

			always @(posedge clk) begin
				if (rst_p)
					r_warp_ready[gw_r] <= 1'b0;
				else
					r_warp_ready[gw_r] <= w_rdy;
			end
			assign warp_ready[gw_r] = r_warp_ready[gw_r];
		end
	endgenerate

	wire unused_ok = &{1'b0, imm[31:12], u_uop, alloc, alloc_idx};
endmodule

`default_nettype wire
