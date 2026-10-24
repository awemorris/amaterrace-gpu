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
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter SB_ENTRIES = 4,	/* Scoreboard entries per warp (ZYBO 4, KC705 8) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter SHORT_LAT = 6	/* Cycles from x_valid to the short result */
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
	output wire [15:0] fault_pc
);
`include "atg_su_uop.vh"

	localparam G = 32 / NPHYS;
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
	wire [6:0] rs1p = rs1 + 7'd1;
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
	wire [6:0] rs3p = rs3 + 7'd1;
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
	wire [31:0] rel_idx = {{(32-WARP_W){1'b0}}, rel_warp} * SB_ENTRIES +
		{{(31-SBE_W){1'b0}}, rel_sbe};
	reg [NE-1:0] ev;
	integer n;
	always @(*) begin
		ev = e_valid;
		if (rel_e)
			ev[rel_idx[NE_W-1:0]] = 1'b0;
	end

	function wq;
		input [WARP_W-1:0] a;
		input integer b;
		wq = {{(32-WARP_W){1'b0}}, a} == b;
	endfunction

	function in_range;
		input [6:0] x;
		input [5:0] base;
		input w4;
		in_range = {1'b0, x} >= {2'b00, base} &&
			{1'b0, x} < {2'b00, base} + (w4 ? 8'd4 : 8'd1);
	endfunction

	/* Long hazards: a used source or the destination range meets an entry. */
	reg hz_long;
	reg [SBE_W:0] free_e;
	reg have_free;
	integer j, ix;
	always @(*) begin
		hz_long = 1'b0;
		have_free = 1'b0;
		free_e = {(SBE_W+1){1'b1}};
		for (j = SB_ENTRIES - 1; j >= 0; j = j - 1) begin
			ix = {{(32-WARP_W){1'b0}}, u_warp} * SB_ENTRIES + j;
			if (ev[ix]) begin
				if ((src1 && in_range(rs1, e_base[(ix)*6 +: 6], e_wide[ix])) ||
				    (src2 && in_range(rs2, e_base[(ix)*6 +: 6], e_wide[ix])) ||
				    (src3 && in_range(rs3, e_base[(ix)*6 +: 6], e_wide[ix])) ||
				    (src4 && in_range(rs1p, e_base[(ix)*6 +: 6], e_wide[ix])) ||
				    (src5 && in_range(rs3p, e_base[(ix)*6 +: 6], e_wide[ix])) ||
				    (dst && (in_range(rd, e_base[(ix)*6 +: 6], e_wide[ix]) ||
				    (wide && in_range({1'b0, e_base[(ix)*6 +: 6]}, rd[5:0], 1'b1)))))
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
	reg [NSH-1:0] c_valid;
	reg [NSH*WARP_W-1:0] c_warp;
	reg [NSH*6-1:0] c_rd;
	reg [NSH*CD_W-1:0] c_cnt;

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
			if (f_valid[m] && f_short[m] && f_warp[(m)*WARP_W +: WARP_W] == u_warp &&
			    ((src1 && hit(rs1, f_rd[(m)*7 +: 7])) || (src2 && hit(rs2, f_rd[(m)*7 +: 7])) ||
			    (src3 && hit(rs3, f_rd[(m)*7 +: 7])) || (src4 && hit(rs1p, f_rd[(m)*7 +: 7])) ||
			    (src5 && hit(rs3p, f_rd[(m)*7 +: 7])) ||
			    (dst && is_long && (f_rd[(m)*7 +: 7] >= {1'b0, rd[5:0]}) &&
			    (f_rd[(m)*7 +: 7] < {1'b0, rd[5:0]} + (wide ? 7'd4 : 7'd1)))))
				hz_short = 1'b1;
		for (m = 0; m < NSH; m = m + 1)
			if (c_valid[m] && c_warp[(m)*WARP_W +: WARP_W] == u_warp &&
			    (({28'd0, c_cnt[(m)*CD_W +: CD_W]} > G + 1 && ((src1 && hit(rs1, {1'b0, c_rd[(m)*6 +: 6]})) ||
			    (src2 && hit(rs2, {1'b0, c_rd[(m)*6 +: 6]})) || (src3 && hit(rs3, {1'b0, c_rd[(m)*6 +: 6]})) ||
			    (src4 && hit(rs1p, {1'b0, c_rd[(m)*6 +: 6]})) ||
			    (src5 && hit(rs3p, {1'b0, c_rd[(m)*6 +: 6]})))) ||
			    (dst && is_long && in_range({1'b0, c_rd[(m)*6 +: 6]}, rd[5:0], wide))))
				hz_short = 1'b1;
	end

	/* Counters and the instructions that wait for them. */
	wire [CNT_W-1:0] rcm = cm[(u_warp)*CNT_W +: CNT_W] -
		{{(CNT_W-1){1'b0}}, rel_valid && rel_warp == u_warp && rel_cls == ATG_CLS_M};
	wire [CNT_W-1:0] rct = ct[(u_warp)*CNT_W +: CNT_W] -
		{{(CNT_W-1){1'b0}}, rel_valid && rel_warp == u_warp && rel_cls == ATG_CLS_T};
	wire [CNT_W-1:0] rcx = cx[(u_warp)*CNT_W +: CNT_W] -
		{{(CNT_W-1){1'b0}}, rel_valid && rel_warp == u_warp && rel_cls == ATG_CLS_X};
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
	wire [31:0] alloc_idx = {{(32-WARP_W){1'b0}}, u_warp} * SB_ENTRIES +
		{{(31-SBE_W){1'b0}}, free_e};
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
			e_valid <= {NE{1'b0}};
			f_valid <= {NIF{1'b0}};
			c_valid <= {NSH{1'b0}};
			for (q = 0; q < NWARPS; q = q + 1) begin
				cm[(q)*CNT_W +: CNT_W] <= {CNT_W{1'b0}};
				ct[(q)*CNT_W +: CNT_W] <= {CNT_W{1'b0}};
				cx[(q)*CNT_W +: CNT_W] <= {CNT_W{1'b0}};
			end
		end else begin
			/* Entries and counters. */
			e_valid <= ev;
			if (alloc) begin
				e_valid[alloc_idx[NE_W-1:0]] <= 1'b1;
				e_base[(alloc_idx[NE_W-1:0])*6 +: 6] <= rd[5:0];
				e_wide[alloc_idx[NE_W-1:0]] <= wide;
			end
			for (q = 0; q < NWARPS; q = q + 1) begin
				cm[(q)*CNT_W +: CNT_W] <= cm[(q)*CNT_W +: CNT_W] + {{(CNT_W-1){1'b0}}, issued && wq(u_warp, q) &&
					cls == ATG_CLS_M} - {{(CNT_W-1){1'b0}}, rel_valid && wq(rel_warp, q) &&
					rel_cls == ATG_CLS_M};
				ct[(q)*CNT_W +: CNT_W] <= ct[(q)*CNT_W +: CNT_W] + {{(CNT_W-1){1'b0}}, issued && wq(u_warp, q) &&
					cls == ATG_CLS_T} - {{(CNT_W-1){1'b0}}, rel_valid && wq(rel_warp, q) &&
					rel_cls == ATG_CLS_T};
				cx[(q)*CNT_W +: CNT_W] <= cx[(q)*CNT_W +: CNT_W] + {{(CNT_W-1){1'b0}}, issued && wq(u_warp, q) &&
					cls == ATG_CLS_X} - {{(CNT_W-1){1'b0}}, rel_valid && wq(rel_warp, q) &&
					rel_cls == ATG_CLS_X};
			end
			/* Count down the short writers past the bus. */
			for (q = 0; q < NSH; q = q + 1)
				if (c_valid[q]) begin
					if (c_cnt[(q)*CD_W +: CD_W] == 1)
						c_valid[q] <= 1'b0;
					c_cnt[(q)*CD_W +: CD_W] <= c_cnt[(q)*CD_W +: CD_W] - 1'b1;
				end
			if (x_end && f_valid[0] && f_short[0] && c_have) begin
				c_valid[c_slot] <= 1'b1;
				c_warp[(c_slot)*WARP_W +: WARP_W] <= f_warp[(0)*WARP_W +: WARP_W];
				c_rd[(c_slot)*6 +: 6] <= f_rd[5:0];
				c_cnt[(c_slot)*CD_W +: CD_W] <= SHORT_LAT[CD_W-1:0] + 1'b1;
			end
			/* The in-order list: pop on x_end, push on issue. */
			if (x_end)
				for (q = 0; q < NIF - 1; q = q + 1) begin
					f_warp[(q)*WARP_W +: WARP_W] <= f_warp[(q+1)*WARP_W +: WARP_W];
					f_rd[(q)*7 +: 7] <= f_rd[(q+1)*7 +: 7];
					f_short[q] <= f_short[q+1];
				end
			f_valid <= f_shift;
			if (issued) begin
				f_valid[f_slot] <= 1'b1;
				f_warp[(f_slot)*WARP_W +: WARP_W] <= u_warp;
				f_rd[(f_slot)*7 +: 7] <= rd;
				f_short[f_slot] <= short_w;
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

	wire unused_ok = &{1'b0, imm[31:12], u_uop, rel_idx, alloc_idx, ix, f_slot, c_slot};
endmodule

`default_nettype wire
