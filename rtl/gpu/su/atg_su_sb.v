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
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter SHORT_LAT = 6,	/* Cycles from x_valid to the short result */
	parameter BYPASS = 1	/* Short interlock bypass support (0: stall until RF write, 1: bypass) */
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
	localparam CD_W = 4;	/* the short countdown, up to SHORT_LAT + 1 */
	localparam NSH = SHORT_LAT + 2;	/* short writers counting down (one per cycle at most) */
	localparam NIF = 4;
	localparam NE_W = $clog2(NE);	/* issued, not yet past atg_su_opd */

	/* The uop's fields. */
	wire [3:0] unit = u_uop[ATG_UOP_UNIT +: 4];
	wire [7:0] op = u_uop[ATG_UOP_OP +: 8];
	wire [2:0] cls = u_uop[ATG_UOP_CLS +: 3];
	wire [6:0] rd = u_uop[ATG_UOP_RD +: 7];
	wire [6:0] rs1 = u_uop[ATG_UOP_RS1 +: 7];
	wire [6:0] rs2 = u_uop[ATG_UOP_RS2 +: 7];
	wire [6:0] rs3 = u_uop[ATG_UOP_RS3 +: 7];
	wire [6:0] rs1p;
	wire r1p_co_unused, r3p_co_unused, rk_co_unused, r4_co_unused, rw_co_unused;
	am_add #(.W(7)) u_rs1p (.a(rs1), .b(7'd0), .ci(1'b1), .s(rs1p), .co(r1p_co_unused));
	wire wrd = u_uop[ATG_UOP_WRD];
	wire pair = u_uop[ATG_UOP_PAIR];
	wire ill = u_uop[ATG_UOP_ILL];
	wire wide = u_uop[ATG_UOP_NDST +: 3] == 3'd4;
	wire is_long = cls == ATG_CLS_M || cls == ATG_CLS_T || cls == ATG_CLS_X;
	wire [31:0] imm = u_uop[ATG_UOP_IMM +: 32];
	wire src1 = u_uop[ATG_UOP_USE1] && rs1 < 7'd63;
	wire src2 = u_uop[ATG_UOP_USE2] && rs2 < 7'd63;
	wire src3 = u_uop[ATG_UOP_USE3] && rs3 < 7'd63;
	wire src4 = pair && rs1p < 7'd63;
	/* A texture .3 form with Dref also reads rs1+3 (rs3 + 1). */
	wire [6:0] rs3p;
	am_add #(.W(7)) u_rs3p (.a(rs3), .b(7'd0), .ci(1'b1), .s(rs3p), .co(r3p_co_unused));
	/* The destination's end: rd + 4 (wide) or rd + 1; and rd + 4 (an entry inside a wide rd). */
	wire [7:0] rd_k, rd_4;
	am_add #(.W(8)) u_rd_k (.a({2'b00, rd[5:0]}), .b(wide ? 8'd4 : 8'd1), .ci(1'b0), .s(rd_k),
		.co(rk_co_unused));
	am_add #(.W(8)) u_rd_4 (.a({2'b00, rd[5:0]}), .b(8'd4), .ci(1'b0), .s(rd_4), .co(r4_co_unused));
	wire src5 = unit == ATG_UNIT_TEX && u_uop[ATG_UOP_SUB + 4] && op[ATG_TEX_CFORM] &&
		rs3p < 7'd63;
	wire dst = wrd && rd < 7'd63;

	/* Scoreboard entries, warp-major: {base, wide, cls}. */
	reg [NE-1:0] e_valid;
	reg [NE*6-1:0] e_base;
	reg [NE-1:0] e_wide;
	reg [NWARPS*CNT_W-1:0] cm;
	reg [NWARPS*CNT_W-1:0] ct;
	reg [NWARPS*CNT_W-1:0] cx;

	/* The release of this cycle, applied before the checks. */
	wire rel_e = rel_valid && rel_sbe != {(SBE_W+1){1'b1}};
	/* warp SB_ENTRIES + entry (an entry index's top bit carries into the warp). */
	wire [WARP_W-1:0] rel_w;
	am_add #(.W(WARP_W)) u_rel_w (.a(rel_warp), .b({WARP_W{1'b0}}), .ci(rel_sbe[SBE_W]), .s(rel_w),
		.co(rw_co_unused));
	wire [NE_W-1:0] rel_idx = {rel_w, rel_sbe[SBE_W-1:0]};
	reg [NE-1:0] ev;
	integer n;
	always @(*) begin
		ev = e_valid;
		if (rel_e)
			ev[rel_idx] = 1'b0;
	end

	/* x in [base, base_end): base_end is base + 4 (wide) or + 1, computed by the caller. */
	function in_range;
		input [6:0] x;
		input [5:0] base;
		input [7:0] base_end;
		in_range = {1'b0, x} >= {2'b00, base} && {1'b0, x} < base_end;
	endfunction

	/* The warp's entries (valid, base, wide, the base's end) and counters. */
	reg [SB_ENTRIES-1:0] uw_v;
	reg [SB_ENTRIES*6-1:0] uw_base;
	reg [SB_ENTRIES-1:0] uw_wide;
	wire [SB_ENTRIES*8-1:0] uw_end;
	reg [CNT_W-1:0] ucm, uct, ucx;
	integer uj, uw;
	always @(*) begin
		uw_v = {SB_ENTRIES{1'b0}};
		uw_base = {(SB_ENTRIES*6){1'b0}};
		uw_wide = {SB_ENTRIES{1'b0}};
		{ucm, uct, ucx} = {(3*CNT_W){1'b0}};
		for (uw = 0; uw < NWARPS; uw = uw + 1)
			if (u_warp == uw[WARP_W-1:0]) begin
				for (uj = 0; uj < SB_ENTRIES; uj = uj + 1) begin
					uw_v[uj] = ev[uw * SB_ENTRIES + uj];
					uw_base[uj*6 +: 6] = e_base[(uw * SB_ENTRIES + uj)*6 +: 6];
					uw_wide[uj] = e_wide[uw * SB_ENTRIES + uj];
				end
				{ucm, uct, ucx} = {cm[uw*CNT_W +: CNT_W], ct[uw*CNT_W +: CNT_W],
					cx[uw*CNT_W +: CNT_W]};
			end
	end
	genvar ge;
	generate
		for (ge = 0; ge < SB_ENTRIES; ge = ge + 1) begin : g_end
			wire co_unused;
			am_add #(.W(8)) u_end (.a({2'b00, uw_base[ge*6 +: 6]}), .b(uw_wide[ge] ? 8'd4 : 8'd1),
				.ci(1'b0), .s(uw_end[ge*8 +: 8]), .co(co_unused));
		end
	endgenerate

	/* Long hazards: a used source or the destination range meets an entry. */
	reg hz_long;
	reg [SBE_W:0] free_e;
	reg have_free;
	integer j;
	reg [5:0] jb;
	reg [7:0] je;
	always @(*) begin
		hz_long = 1'b0;
		have_free = 1'b0;
		free_e = {(SBE_W+1){1'b1}};
		for (j = SB_ENTRIES - 1; j >= 0; j = j - 1) begin
			jb = uw_base[j*6 +: 6];
			je = uw_end[j*8 +: 8];
			if (uw_v[j]) begin
				if ((src1 && in_range(rs1, jb, je)) ||
				    (src2 && in_range(rs2, jb, je)) ||
				    (src3 && in_range(rs3, jb, je)) ||
				    (src4 && in_range(rs1p, jb, je)) ||
				    (src5 && in_range(rs3p, jb, je)) ||
				    (dst && (in_range(rd, jb, je) ||
				    (wide && in_range({1'b0, jb}, rd[5:0], rd_4)))))
					hz_long = 1'b1;
			end else begin
				have_free = 1'b1;
				free_e = j[SBE_W:0];
			end
		end
	end

	/* Short writers: issued and not past atg_su_opd (in order), then counting. */
	reg [NIF-1:0] f_valid;
	reg [NIF*WARP_W-1:0] f_warp;
	reg [NIF*7-1:0] f_rd;
	reg [NIF-1:0] f_short;
	reg [NIF-1:0] f_pipe_alu;
	reg [NIF-1:0] f_pipe_fpu;
	reg [NSH-1:0] c_valid;
	reg [NSH*WARP_W-1:0] c_warp;
	reg [NSH*6-1:0] c_rd;
	reg [NSH*CD_W-1:0] c_cnt;
	reg [NSH-1:0] c_pipe_alu;
	reg [NSH-1:0] c_pipe_fpu;

	function hit;
		input [6:0] x;
		input [6:0] r;
		hit = x == r;
	endfunction

	reg hz_short;
	integer m;
	always @(*) begin
		hz_short = 1'b0;
		for (m = 0; m < NIF; m = m + 1)
			if (f_valid[m] && f_short[m] && f_warp[(m)*WARP_W +: WARP_W] == u_warp) begin
				if ((!BYPASS || is_long || !(f_pipe_alu[m] || f_pipe_fpu[m]) || (G < 4)) &&
				    ((src1 && hit(rs1, f_rd[(m)*7 +: 7])) || (src2 && hit(rs2, f_rd[(m)*7 +: 7])) ||
				    (src3 && hit(rs3, f_rd[(m)*7 +: 7])) || (src4 && hit(rs1p, f_rd[(m)*7 +: 7])) ||
				    (src5 && hit(rs3p, f_rd[(m)*7 +: 7]))))
					hz_short = 1'b1;
				if (dst && is_long && (f_rd[(m)*7 +: 7] >= {1'b0, rd[5:0]}) &&
				    (f_rd[(m)*7 +: 7] < rd_k[6:0]))
					hz_short = 1'b1;
			end
		for (m = 0; m < NSH; m = m + 1)
			if (c_valid[m] && c_warp[(m)*WARP_W +: WARP_W] == u_warp) begin
				if (((!BYPASS && {28'd0, c_cnt[(m)*CD_W +: CD_W]} > G + 1) ||
				     (BYPASS && is_long && {28'd0, c_cnt[(m)*CD_W +: CD_W]} > 1) ||
				     (BYPASS && !is_long && !c_pipe_alu[m] && !c_pipe_fpu[m] && {28'd0, c_cnt[(m)*CD_W +: CD_W]} > G + 1) ||
				     (BYPASS && !is_long && c_pipe_alu[m] && {28'd0, c_cnt[(m)*CD_W +: CD_W]} > SHORT_BP_WAIT_ALU) ||
				     (BYPASS && !is_long && c_pipe_fpu[m] && {28'd0, c_cnt[(m)*CD_W +: CD_W]} > SHORT_BP_WAIT_FPU)) &&
				    ((src1 && hit(rs1, {1'b0, c_rd[(m)*6 +: 6]})) ||
				    (src2 && hit(rs2, {1'b0, c_rd[(m)*6 +: 6]})) || (src3 && hit(rs3, {1'b0, c_rd[(m)*6 +: 6]})) ||
				    (src4 && hit(rs1p, {1'b0, c_rd[(m)*6 +: 6]})) ||
				    (src5 && hit(rs3p, {1'b0, c_rd[(m)*6 +: 6]}))))
					hz_short = 1'b1;
				if (dst && is_long && in_range({1'b0, c_rd[(m)*6 +: 6]}, rd[5:0], rd_k))
					hz_short = 1'b1;
			end
	end

	/* Counters (the warp's, less this cycle's release) and the instructions that wait for them. */
	wire rel_u = rel_valid && rel_warp == u_warp;
	wire [CNT_W-1:0] rcm, rct, rcx;
	wire rcm_bo_unused, rct_bo_unused, rcx_bo_unused;
	am_sub #(.W(CNT_W)) u_rcm (.a(ucm), .b({CNT_W{1'b0}}), .bi(rel_u && rel_cls == ATG_CLS_M), .d(rcm),
		.bo(rcm_bo_unused));
	am_sub #(.W(CNT_W)) u_rct (.a(uct), .b({CNT_W{1'b0}}), .bi(rel_u && rel_cls == ATG_CLS_T), .d(rct),
		.bo(rct_bo_unused));
	am_sub #(.W(CNT_W)) u_rcx (.a(ucx), .b({CNT_W{1'b0}}), .bi(rel_u && rel_cls == ATG_CLS_X), .d(rcx),
		.bo(rcx_bo_unused));
	wire is_wait = unit == ATG_UNIT_CTL;
	wire is_fence = unit == ATG_UNIT_LSU && op == ATG_LSU_FENCE;
	wire is_end = unit == ATG_UNIT_EXEC && op == ATG_EXEC_END;
	wire is_nop = unit == ATG_UNIT_NONE;
	wire wait_ok = rcm <= {2'b00, imm[3:0]} && rct <= {2'b00, imm[7:4]} &&
		rcx <= {2'b00, imm[11:8]};
	wire cnt_wait = (is_wait && !wait_ok) || (is_fence && imm[0] && rcm != 0) ||
		(is_end && (rcm != 0 || rct != 0 || rcx != 0));
	wire [CNT_W-1:0] rcc = cls == ATG_CLS_M ? rcm : cls == ATG_CLS_T ? rct : rcx;
	wire cnt_full = is_long && rcc == {CNT_W{1'b1}};
	wire need_e = is_long && wrd;
	wire rq_wait = (u_uop[ATG_UOP_RQS] && rq_empty) || (u_uop[ATG_UOP_RQD] && rq_full);

	wire replay = !ill && (hz_long || cnt_wait || cnt_full || (need_e && !have_free) || rq_wait);
	wire quiet = !ill && !replay && (is_nop || is_wait);	/* consumed without issue */
	wire hold = wb_stall || hz_short || !(|(~f_valid));
	wire go = u_valid && !hold;
	assign i_valid = go && !ill && !replay && !quiet;
	wire issued = i_valid && i_ready;
	assign u_ready = go && (ill || replay || quiet || i_ready);
	assign i_warp = u_warp;
	assign i_pc = u_pc;
	assign i_uop = u_uop;
	assign i_sbe = need_e ? free_e : {(SBE_W+1){1'b1}};

	wire wc_kind = unit == ATG_UNIT_EXEC && (op <= ATG_EXEC_BEXZ || op == ATG_EXEC_END ||
		op == ATG_EXEC_BAR);
	assign fb_valid = u_valid && u_ready;
	assign fb_warp = u_warp;
	assign fb_kind = ill ? 2'd1 : replay ? 2'd2 : (issued && wc_kind) ? 2'd1 : 2'd0;
	assign fault = u_valid && u_ready && ill;
	assign fault_pc = u_pc;

	genvar w;
	generate
		for (w = 0; w < NWARPS; w = w + 1) begin : wk
			assign wake[w] = rel_valid && rel_warp == w;
		end
	endgenerate

	/* State updates. */
	wire alloc = issued && need_e;
	wire [NE_W-1:0] alloc_idx = {u_warp, free_e[SBE_W-1:0]};	/* free_e < SB_ENTRIES at an alloc */

	/* Each warp's counters: + 1 at an issue of the class, - 1 at its release. */
	wire [NWARPS*CNT_W-1:0] cm_next, ct_next, cx_next;
	genvar gq;
	generate
		for (gq = 0; gq < NWARPS; gq = gq + 1) begin : g_cnt
			wire iw = issued && u_warp == gq;
			wire rw = rel_valid && rel_warp == gq;
			wire im = iw && cls == ATG_CLS_M, rm = rw && rel_cls == ATG_CLS_M;
			wire it = iw && cls == ATG_CLS_T, rt = rw && rel_cls == ATG_CLS_T;
			wire ix = iw && cls == ATG_CLS_X, rx = rw && rel_cls == ATG_CLS_X;
			wire m_co_unused, t_co_unused, x_co_unused;
			am_add #(.W(CNT_W)) u_cm (.a(cm[gq*CNT_W +: CNT_W]),
				.b({{(CNT_W-1){rm && !im}}, im ^ rm}), .ci(1'b0), .s(cm_next[gq*CNT_W +: CNT_W]), .co(m_co_unused));
			am_add #(.W(CNT_W)) u_ct (.a(ct[gq*CNT_W +: CNT_W]),
				.b({{(CNT_W-1){rt && !it}}, it ^ rt}), .ci(1'b0), .s(ct_next[gq*CNT_W +: CNT_W]), .co(t_co_unused));
			am_add #(.W(CNT_W)) u_cx (.a(cx[gq*CNT_W +: CNT_W]),
				.b({{(CNT_W-1){rx && !ix}}, ix ^ rx}), .ci(1'b0), .s(cx_next[gq*CNT_W +: CNT_W]), .co(x_co_unused));
		end
	endgenerate

	/* The short writers' countdowns, - 1 a cycle. */
	wire [NSH*CD_W-1:0] c_cnt_m1;
	genvar gc;
	generate
		for (gc = 0; gc < NSH; gc = gc + 1) begin : g_cd
			wire bo_unused;
			am_sub #(.W(CD_W)) u_cd (.a(c_cnt[gc*CD_W +: CD_W]), .b({CD_W{1'b0}}), .bi(1'b1),
				.d(c_cnt_m1[gc*CD_W +: CD_W]), .bo(bo_unused));
		end
	endgenerate
	wire short_w = (cls == ATG_CLS_A || cls == ATG_CLS_F) && dst;
	/* The oldest issued instruction leaves atg_su_opd on x_end (index 0);
	 * the free places after that shift. */
	wire [NIF-1:0] f_shift = x_end ? {1'b0, f_valid[NIF-1:1]} : f_valid;
	reg [31:0] f_slot, c_slot;
	reg c_have;
	integer q;
	always @(*) begin
		f_slot = 0;
		for (q = NIF - 1; q >= 0; q = q - 1)
			if (!f_shift[q])
				f_slot = q;
		c_have = 1'b0;
		c_slot = 0;
		for (q = NSH - 1; q >= 0; q = q - 1)
			if (!c_valid[q] || c_cnt[(q)*CD_W +: CD_W] == 1) begin
				c_have = 1'b1;
				c_slot = q;
			end
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			e_valid    <= {NE{1'b0}};
			f_valid    <= {NIF{1'b0}};
			f_pipe_alu <= {NIF{1'b0}};
			f_pipe_fpu <= {NIF{1'b0}};
			c_valid    <= {NSH{1'b0}};
			c_pipe_alu <= {NSH{1'b0}};
			c_pipe_fpu <= {NSH{1'b0}};
			cm <= {(NWARPS*CNT_W){1'b0}};
			ct <= {(NWARPS*CNT_W){1'b0}};
			cx <= {(NWARPS*CNT_W){1'b0}};
		end else begin
			/* Entries and counters. */
			e_valid <= ev;
			if (alloc) begin
				e_valid[alloc_idx] <= 1'b1;
				for (q = 0; q < NE; q = q + 1)
					if (alloc_idx == q[NE_W-1:0])
						e_base[q*6 +: 6] <= rd[5:0];
				e_wide[alloc_idx] <= wide;
			end
			cm <= cm_next;
			ct <= ct_next;
			cx <= cx_next;
			/* Count down the short writers past the bus. */
			for (q = 0; q < NSH; q = q + 1)
				if (c_valid[q]) begin
					if (c_cnt[(q)*CD_W +: CD_W] == 1)
						c_valid[q] <= 1'b0;
					c_cnt[(q)*CD_W +: CD_W] <= c_cnt_m1[(q)*CD_W +: CD_W];
				end
			if (x_end && f_valid[0] && f_short[0] && c_have) begin
				c_valid[c_slot] <= 1'b1;
				c_warp[(c_slot)*WARP_W +: WARP_W] <= f_warp[(0)*WARP_W +: WARP_W];
				c_rd[(c_slot)*6 +: 6] <= f_rd[5:0];
				c_cnt[(c_slot)*CD_W +: CD_W] <= SHORT_LAT[CD_W-1:0] + 1'b1;
				c_pipe_alu[c_slot] <= f_pipe_alu[0];
				c_pipe_fpu[c_slot] <= f_pipe_fpu[0];
			end
			/* The in-order list: pop on x_end, push on issue. */
			if (x_end)
				for (q = 0; q < NIF - 1; q = q + 1) begin
					f_warp[(q)*WARP_W +: WARP_W] <= f_warp[(q+1)*WARP_W +: WARP_W];
					f_rd[(q)*7 +: 7] <= f_rd[(q+1)*7 +: 7];
					f_short[q] <= f_short[q+1];
					f_pipe_alu[q] <= f_pipe_alu[q+1];
					f_pipe_fpu[q] <= f_pipe_fpu[q+1];
				end
			f_valid <= f_shift;
			if (issued) begin
				f_valid[f_slot] <= 1'b1;
				f_warp[(f_slot)*WARP_W +: WARP_W] <= u_warp;
				f_rd[(f_slot)*7 +: 7] <= rd;
				f_short[f_slot] <= short_w;
				f_pipe_alu[f_slot] <= (unit == ATG_UNIT_ALU);
				f_pipe_fpu[f_slot] <= (unit == ATG_UNIT_FPU);
			end
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
	genvar gw_r;
	generate
		for (gw_r = 0; gw_r < NWARPS; gw_r = gw_r + 1) begin : g_wr
			wire [SB_ENTRIES-1:0] w_ev = ev[gw_r * SB_ENTRIES +: SB_ENTRIES];
			wire w_u_hold = u_valid && (u_warp == gw_r[WARP_W-1:0]) && !i_valid;
			assign warp_ready[gw_r] = !(|w_ev) && !w_u_hold;
		end
	endgenerate

	wire unused_ok = &{1'b0, imm[31:12], u_uop, f_slot, c_slot, rd_k[7]};
endmodule

`default_nettype wire
