/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_div: The SU's shared integer divider: div, divu, rem, remu
 * (RISC-V semantics), lane by lane, results as long beats.
 *
 * Takes one lane group at a time (x_ready is 1 only in IDLE), divides
 * its EXEC lanes one after the other with a 32-step restoring divider (34
 * cycles per lane: load, 32 steps, sign fix), then returns the group as
 * one long beat (l_wr 1, l_last = the group's x_last, class x).  A group
 * without EXEC lanes returns at once.  Division by zero gives all ones
 * (div/divu) and the dividend (rem/remu); INT_MIN / -1 gives INT_MIN and
 * remainder 0 (RISC-V).  The reference is tools/gsi1fp.py div().
 *
 * States: IDLE →(group)→ DIV (lane loop) → RET →(l_ready)→ IDLE.
*/

`timescale 1ns / 1ps
`default_nettype none

module atg_su_div #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
) (
	input wire clk,
	input wire rst_n,
	/* Issued instruction, one lane group per cycle (from atg_su_opd, shared by all units) */
	input wire x_valid,
	input wire [WARP_W-1:0] x_warp,
	input wire [GRP_W-1:0] x_grp,
	input wire x_last,
	input wire [SBE_W:0] x_sbe,
	input wire [15:0] x_pc,
	input wire [UOP_W-1:0] x_uop,
	input wire [NPHYS*32-1:0] x_a,
	input wire [NPHYS*32-1:0] x_b,
	input wire [NPHYS*32-1:0] x_c,
	input wire [2*NPHYS-1:0] x_mask,
	input wire [31:0] x_info,
	output wire x_ready,
	/* Long result to atg_su_wb (any time; wb may refuse with l_ready = 0) */
	output wire l_valid,
	input wire l_ready,
	output wire [WARP_W-1:0] l_warp,
	output wire [GRP_W-1:0] l_grp,
	output wire [6:0] l_rd,
	output wire [NPHYS*32-1:0] l_data,
	output wire [NPHYS-1:0] l_lanes,
	output wire l_wr,
	output wire l_last,
	output wire [SBE_W:0] l_sbe,
	output wire [2:0] l_cls
);
`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	localparam LW = NPHYS > 1 ? $clog2(NPHYS) : 1;
	localparam [1:0] IDLE = 2'd0, DIV = 2'd1, RET = 2'd2;

	(* max_fanout = 12 *) reg [1:0] st;
	(* max_fanout = 12 *) reg [NPHYS-1:0] rm;
	(* max_fanout = 12 *) reg [1:0] rop;
	reg [6:0] rrd;
	reg [WARP_W-1:0] rwarp;
	reg [GRP_W-1:0] rgrp;
	reg rlast;
	reg [SBE_W:0] rsbe;
	(* max_fanout = 12 *) reg [LW-1:0] li;
	(* max_fanout = 12 *) reg [5:0] step;
	/* The divider of the current lane. */
	(* max_fanout = 12 *) reg [31:0] dn, dd, q;
	(* max_fanout = 12 *) reg [32:0] r;
	(* max_fanout = 12 *) reg neg_q, neg_r, lb_zero_r;
	wire [31:0] la_cur_r, lb_cur_r;

	(* max_fanout = 12 *) wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_DIV;
	assign x_ready = st == IDLE;

	/* The next lane in the mask at or after lane n (NPHYS when none). */
	function [LW:0] next_lane;
		input [NPHYS-1:0] m;
		input [LW:0] n;
		integer i;
		begin
			next_lane = NPHYS[LW:0];
			for (i = NPHYS - 1; i >= 0; i = i - 1)
				if (m[i] && i >= n)
					next_lane = i[LW:0];
		end
	endfunction

	wire [LW:0] first = next_lane(x_mask[NPHYS-1:0], {(LW+1){1'b0}});
	wire [LW:0] li_1;
	wire l1_co_unused;
	am_add #(.W(LW + 1)) u_li_1 (.a({1'b0, li}), .b({(LW + 1){1'b0}}), .ci(1'b1), .s(li_1),
		.co(l1_co_unused));
	wire [LW:0] after = next_lane(rm, li_1);
	wire [DW-1:0] ra, rb, rq;
	wire [31:0] la = la_cur_r;
	wire [31:0] lb = lb_cur_r;
	wire sgn = !rop[0];	/* div, rem */

	/*
	 * One 33-bit subtractor, by step: 0 - a at the load (step 0), the
	 * trial r:dn[31] - d of the steps 1-32, 0 - the result at the end; and
	 * 0 - b at the load.
	 */
	(* max_fanout = 12 *) wire s_load = step == 6'd0;
	(* max_fanout = 12 *) wire s_end = step > 6'd32;
	(* max_fanout = 12 *) wire [32:0] d0;
	wire [31:0] neg_b;
	wire [5:0] step_next;
	wire d0_bo_unused, nb_bo_unused, sn_co_unused;
	am_sub #(.W(33)) u_d0 (.a(s_load || s_end ? 33'd0 : {r[31:0], dn[31]}),
		.b(s_load ? {1'b0, la} : s_end ? {1'b0, rop[1] ? r[31:0] : q} : {1'b0, dd}), .bi(1'b0),
		.d(d0), .bo(d0_bo_unused));
	am_sub #(.W(32)) u_neg_b (.a(32'd0), .b(lb), .bi(1'b0), .d(neg_b), .bo(nb_bo_unused));
	am_add #(.W(6)) u_step (.a(step), .b(6'd0), .ci(1'b1), .s(step_next), .co(sn_co_unused));
	(* keep = "true", max_fanout = 12 *) wire trial_pos = !d0[32];

	wire [31:0] div_res = lb_zero_r ? (rop[1] ? la : 32'hFFFFFFFF) :
		rop[1] ? (neg_r ? d0[31:0] : r[31:0]) :
		(neg_q ? d0[31:0] : q);

	/* Buffered control and index signals */
	wire [LW-1:0] first_a_lo, first_a_hi, first_b_lo, first_b_hi;
	wire [LW-1:0] after_a_lo, after_a_hi, after_b_lo, after_b_hi;
	genvar gbf;
	generate
		for (gbf = 0; gbf < LW; gbf = gbf + 1) begin : g_buf_sel
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_f_alo (.I0(first[gbf]), .O(first_a_lo[gbf]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_f_ahi (.I0(first[gbf]), .O(first_a_hi[gbf]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_f_blo (.I0(first[gbf]), .O(first_b_lo[gbf]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_f_bhi (.I0(first[gbf]), .O(first_b_hi[gbf]));

			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_a_alo (.I0(after[gbf]), .O(after_a_lo[gbf]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_a_ahi (.I0(after[gbf]), .O(after_a_hi[gbf]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_a_blo (.I0(after[gbf]), .O(after_b_lo[gbf]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_a_bhi (.I0(after[gbf]), .O(after_b_hi[gbf]));
`else
			assign first_a_lo[gbf] = first[gbf];
			assign first_a_hi[gbf] = first[gbf];
			assign first_b_lo[gbf] = first[gbf];
			assign first_b_hi[gbf] = first[gbf];

			assign after_a_lo[gbf] = after[gbf];
			assign after_a_hi[gbf] = after[gbf];
			assign after_b_lo[gbf] = after[gbf];
			assign after_b_hi[gbf] = after[gbf];
`endif
		end
	endgenerate

	wire cur_load_raw = ((st == IDLE) && mine && (first != NPHYS[LW:0])) ||
	                    ((st == DIV) && s_end && (after != NPHYS[LW:0]));
	wire idle_sel_raw = (st == IDLE);

	wire cur_load_alo, cur_load_ahi, cur_load_blo, cur_load_bhi;
	wire idle_sel_alo, idle_sel_ahi, idle_sel_blo, idle_sel_bhi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cl_alo (.I0(cur_load_raw), .O(cur_load_alo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cl_ahi (.I0(cur_load_raw), .O(cur_load_ahi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cl_blo (.I0(cur_load_raw), .O(cur_load_blo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cl_bhi (.I0(cur_load_raw), .O(cur_load_bhi));

	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_is_alo (.I0(idle_sel_raw), .O(idle_sel_alo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_is_ahi (.I0(idle_sel_raw), .O(idle_sel_ahi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_is_blo (.I0(idle_sel_raw), .O(idle_sel_blo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_is_bhi (.I0(idle_sel_raw), .O(idle_sel_bhi));
`else
	assign cur_load_alo = cur_load_raw;
	assign cur_load_ahi = cur_load_raw;
	assign cur_load_blo = cur_load_raw;
	assign cur_load_bhi = cur_load_raw;

	assign idle_sel_alo = idle_sel_raw;
	assign idle_sel_ahi = idle_sel_raw;
	assign idle_sel_blo = idle_sel_raw;
	assign idle_sel_bhi = idle_sel_raw;
`endif

	reg [15:0] la_cur_lo, la_cur_hi, lb_cur_lo, lb_cur_hi;
	always @(posedge clk) begin
		if (rst_p) begin
			la_cur_lo <= 16'd0;
			la_cur_hi <= 16'd0;
			lb_cur_lo <= 16'd0;
			lb_cur_hi <= 16'd0;
		end else begin
			if (cur_load_alo)
				la_cur_lo <= idle_sel_alo ? x_a[first_a_lo*32 +: 16] : ra[after_a_lo*32 +: 16];
			if (cur_load_ahi)
				la_cur_hi <= idle_sel_ahi ? x_a[first_a_hi*32 + 16 +: 16] : ra[after_a_hi*32 + 16 +: 16];
			if (cur_load_blo)
				lb_cur_lo <= idle_sel_blo ? x_b[first_b_lo*32 +: 16] : rb[after_b_lo*32 +: 16];
			if (cur_load_bhi)
				lb_cur_hi <= idle_sel_bhi ? x_b[first_b_hi*32 + 16 +: 16] : rb[after_b_hi*32 + 16 +: 16];
		end
	end
	assign la_cur_r = {la_cur_hi, la_cur_lo};
	assign lb_cur_r = {lb_cur_hi, lb_cur_lo};

	genvar gdl, gdh;
	generate
	for (gdl = 0; gdl < NPHYS; gdl = gdl + 1) begin : g_div_lane
		for (gdh = 0; gdh < 2; gdh = gdh + 1) begin : g_div_half
			wire ra_we_b, rb_we_b, rq_clr_b, rq_we_b;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_ra_we  (.I0((st == IDLE) && mine), .O(ra_we_b));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rb_we  (.I0((st == IDLE) && mine), .O(rb_we_b));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rq_clr (.I0((st == IDLE) && mine), .O(rq_clr_b));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rq_we  (.I0((st == DIV) && s_end && (li == gdl[LW-1:0])), .O(rq_we_b));
`else
			assign ra_we_b = (st == IDLE) && mine;
			assign rb_we_b = (st == IDLE) && mine;
			assign rq_clr_b = (st == IDLE) && mine;
			assign rq_we_b = (st == DIV) && s_end && (li == gdl[LW-1:0]);
`endif
			(* shreg_extract = "no" *) reg [15:0] ra_h_r, rb_h_r, rq_h_r;
			always @(posedge clk) begin
				if (ra_we_b)
					ra_h_r <= x_a[gdl*32 + gdh*16 +: 16];
				if (rb_we_b)
					rb_h_r <= x_b[gdl*32 + gdh*16 +: 16];
				if (rq_clr_b)
					rq_h_r <= 16'd0;
				else if (rq_we_b)
					rq_h_r <= div_res[gdh*16 +: 16];
			end
			assign ra[gdl*32 + gdh*16 +: 16] = ra_h_r;
			assign rb[gdl*32 + gdh*16 +: 16] = rb_h_r;
			assign rq[gdl*32 + gdh*16 +: 16] = rq_h_r;
		end
	end
	for (gdh = 0; gdh < 2; gdh = gdh + 1) begin : g_div_op
		wire load_dn, load_dd, load_q, load_r;
		wire step_dn, step_q, step_r;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ldn (.I0((st == DIV) && s_load), .O(load_dn));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ldd (.I0((st == DIV) && s_load), .O(load_dd));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lq  (.I0((st == DIV) && s_load), .O(load_q));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lr  (.I0((st == DIV) && s_load), .O(load_r));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_sdn (.I0((st == DIV) && !s_load && !s_end), .O(step_dn));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_sq  (.I0((st == DIV) && !s_load && !s_end), .O(step_q));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_sr  (.I0((st == DIV) && !s_load && !s_end), .O(step_r));
`else
		assign load_dn = (st == DIV) && s_load;
		assign load_dd = (st == DIV) && s_load;
		assign load_q  = (st == DIV) && s_load;
		assign load_r  = (st == DIV) && s_load;
		assign step_dn = (st == DIV) && !s_load && !s_end;
		assign step_q  = (st == DIV) && !s_load && !s_end;
		assign step_r  = (st == DIV) && !s_load && !s_end;
`endif
		always @(posedge clk) begin
			if (load_dn)
				dn[gdh*16 +: 16] <= (sgn && la[31]) ? d0[gdh*16 +: 16] : la[gdh*16 +: 16];
			else if (step_dn) begin
				if (gdh == 0)
					dn[15:0] <= {dn[14:0], 1'b0};
				else
					dn[31:16] <= dn[30:15];
			end
		end
		always @(posedge clk) begin
			if (load_dd)
				dd[gdh*16 +: 16] <= (sgn && lb[31]) ? neg_b[gdh*16 +: 16] : lb[gdh*16 +: 16];
		end
		always @(posedge clk) begin
			if (load_q)
				q[gdh*16 +: 16] <= 16'd0;
			else if (step_q) begin
				if (gdh == 0)
					q[15:0] <= {q[14:0], trial_pos};
				else
					q[31:16] <= q[30:15];
			end
		end
		always @(posedge clk) begin
			if (load_r)
				r[gdh*16 +: 16] <= 16'd0;
			else if (step_r) begin
				if (gdh == 0)
					r[15:0] <= trial_pos ? d0[15:0] : {r[14:0], dn[31]};
				else
					r[31:16] <= trial_pos ? d0[31:16] : r[30:15];
			end
		end
	end
	endgenerate

	(* dont_touch = "true" *) wire rst_p = !rst_n;
	wire idle_mine_rm;
	wire idle_mine_ctl1, idle_mine_ctl2;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_im_rm (.I0((st == IDLE) && mine), .O(idle_mine_rm));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_im_c1 (.I0((st == IDLE) && mine), .O(idle_mine_ctl1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_im_c2 (.I0((st == IDLE) && mine), .O(idle_mine_ctl2));
`else
	assign idle_mine_rm = (st == IDLE) && mine;
	assign idle_mine_ctl1 = (st == IDLE) && mine;
	assign idle_mine_ctl2 = (st == IDLE) && mine;
`endif

	always @(posedge clk) begin
		if (rst_p) begin
			rm <= {NPHYS{1'b0}};
			rop <= 2'd0;
			rrd <= 7'd0;
			rwarp <= {WARP_W{1'b0}};
			rgrp <= {GRP_W{1'b0}};
			rlast <= 1'b0;
			rsbe <= {(SBE_W+1){1'b0}};
		end else begin
			if (idle_mine_rm)
				rm <= x_mask[NPHYS-1:0];
			if (idle_mine_ctl1) begin
				rop <= x_uop[ATG_UOP_OP +: 2];
				rrd <= x_uop[ATG_UOP_RD +: 7];
			end
			if (idle_mine_ctl2) begin
				rwarp <= x_warp;
				rgrp <= x_grp;
				rlast <= x_last;
				rsbe <= x_sbe;
			end
		end
	end

	always @(posedge clk) begin
		if (rst_p) begin
			st <= IDLE;
			li <= {LW{1'b0}};
			step <= 6'd0;
			r[32] <= 1'b0;
			neg_q <= 1'b0;
			neg_r <= 1'b0;
			lb_zero_r <= 1'b0;
		end else begin
			case (st)
			IDLE: if (mine) begin
				step <= 6'd0;
				if (first == NPHYS[LW:0])
					st <= RET;
				else begin
					li <= first[LW-1:0];
					st <= DIV;
				end
			end
			DIV: begin
				if (step == 6'd0) begin
					/* Load the lane: magnitudes and the signs of the results. */
					neg_q <= sgn && (la[31] ^ lb[31]);
					neg_r <= sgn && la[31];
					lb_zero_r <= (lb == 32'd0);
					r[32] <= 1'b0;
					step <= 6'd1;
				end else if (step <= 6'd32) begin
					r[32] <= trial_pos ? d0[32] : r[31];
					step <= step_next;
				end else begin
					step <= 6'd0;
					if (after == NPHYS[LW:0])
						st <= RET;
					else begin
						li <= after[LW-1:0];
						st <= DIV;
					end
				end
			end
			default: if (l_ready)
				st <= IDLE;
			endcase
		end
	end

	wire l_valid_buf;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_l_val (.I0(st == RET), .O(l_valid_buf));
`else
	assign l_valid_buf = st == RET;
`endif
	assign l_valid = l_valid_buf;
	assign l_warp = rwarp;
	assign l_grp = rgrp;
	assign l_rd = rrd;
	assign l_data = rq;
	assign l_lanes = rm;
	assign l_wr = 1'b1;
	assign l_last = rlast;
	assign l_sbe = rsbe;
	assign l_cls = ATG_CLS_X;

	wire unused_ok = &{1'b0, x_pc, x_c, x_mask[2*NPHYS-1:NPHYS], x_info, x_uop, r[32],
		(NWARPS != 0)};
endmodule

`default_nettype wire
