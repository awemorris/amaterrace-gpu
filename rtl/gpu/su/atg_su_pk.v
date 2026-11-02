/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_pk: The 16-bit packed unit:
 * fadd2/fsub2/fmul2/ffma2/fmin2/fmax2/fcmp2, iadd2/isub2/imul2, swaph, and
 * the always-present packh/unpackh. Short pipeline (SHORT_LAT = 6 stages).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_pk #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter PACKED = 0,	/* Packed arithmetic present (0: only packh/unpackh/swaph) */
	parameter SHORT_LAT = 6,	/* Cycles from x_valid to the short result (one fixed pipeline for classes a and f, design §3.1.1) */
	parameter PK_SHARED = 0	/* With PACKED: the fp16 operations on atg_su_fpu (above) */
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
	/* Short result to atg_su_wb (exactly SHORT_LAT cycles after x_valid) */
	output wire s_valid,
	output wire [WARP_W-1:0] s_warp,
	output wire [GRP_W-1:0] s_grp,
	output wire [6:0] s_rd,
	output wire [NPHYS*32-1:0] s_data,
	output wire [NPHYS-1:0] s_lanes
);
`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	localparam CW = 1 + WARP_W + GRP_W + 7 + NPHYS;
	localparam SH = PK_SHARED != 0 && PACKED != 0;

	(* dont_touch = "true" *) wire rst_p = !rst_n;

	wire [3:0] op = x_uop[ATG_UOP_OP +: 4];
	/* PK_SHARED: an fp16 operation goes to atg_su_fpu; busy is the cycle
	 * after it is taken (as atg_su_fpu's). */
	wire pk_fp = op <= ATG_PK_FMAX2[3:0] || (op >= ATG_PK_FCMPLT2[3:0] && op <= ATG_PK_FCMPNE2[3:0]);
	reg busy;
	wire grp = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_PK && x_uop[ATG_UOP_WRD] && !busy;
	wire mine = grp && !(SH && pk_fp);
	always @(posedge clk)
		if (rst_p)
			busy <= 1'b0;
		else
			busy <= SH && grp && pk_fp;
	wire [2:0] rm = x_uop[ATG_UOP_RM +: 3];
	wire [1:0] hsel = x_uop[ATG_UOP_HSEL +: 2];
	wire sub = x_uop[ATG_UOP_SUB];
	wire sat = x_uop[ATG_UOP_MOD + 6];

	wire is_unpack = (op == ATG_PK_UNPACKH[3:0]);
	wire is_swaph  = (op == ATG_PK_SWAPH[3:0]);
	wire is_packh  = (op == ATG_PK_PACKH[3:0]);
	wire ovr_lo = is_unpack || is_swaph || (!is_packh && (PACKED == 0 || hsel == 2'd2));
	wire ovr_hi = is_unpack || is_swaph || (!is_packh && (PACKED == 0 || hsel == 2'd1));
	wire hsel_swap = (hsel == 2'd3);

	wire [3:0] op_q0, op_q1;
	wire [2:0] rm_q0, rm_q1;
	wire sat_q0, sat_q1, mine_q0, mine_q1;
	wire ovr_lo_q0, ovr_lo_q1, ovr_hi_q0, ovr_hi_q1;
	wire hsel_sw_q0, hsel_sw_q1;
`ifdef SYNTH_KINTEX7
	genvar gqb;
	generate
		for (gqb = 0; gqb < 4; gqb = gqb + 1) begin : g_q_op
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bq_op0 (.I0(op[gqb]), .O(op_q0[gqb]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bq_op1 (.I0(op[gqb]), .O(op_q1[gqb]));
		end
		for (gqb = 0; gqb < 3; gqb = gqb + 1) begin : g_q_rm
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bq_rm0 (.I0(rm[gqb]), .O(rm_q0[gqb]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bq_rm1 (.I0(rm[gqb]), .O(rm_q1[gqb]));
		end
	endgenerate
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bq_sat0 (.I0(sat), .O(sat_q0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bq_sat1 (.I0(sat), .O(sat_q1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bq_min0 (.I0(mine), .O(mine_q0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bq_min1 (.I0(mine), .O(mine_q1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bq_ovl0 (.I0(ovr_lo), .O(ovr_lo_q0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bq_ovl1 (.I0(ovr_lo), .O(ovr_lo_q1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bq_ovh0 (.I0(ovr_hi), .O(ovr_hi_q0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bq_ovh1 (.I0(ovr_hi), .O(ovr_hi_q1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bq_hsw0 (.I0(hsel_swap), .O(hsel_sw_q0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bq_hsw1 (.I0(hsel_swap), .O(hsel_sw_q1));
`else
	assign op_q0 = op;
	assign op_q1 = op;
	assign rm_q0 = rm;
	assign rm_q1 = rm;
	assign sat_q0 = sat;
	assign sat_q1 = sat;
	assign mine_q0 = mine;
	assign mine_q1 = mine;
	assign ovr_lo_q0 = ovr_lo;
	assign ovr_lo_q1 = ovr_lo;
	assign ovr_hi_q0 = ovr_hi;
	assign ovr_hi_q1 = ovr_hi;
	assign hsel_sw_q0 = hsel_swap;
	assign hsel_sw_q1 = hsel_swap;
`endif

	genvar l;
	generate
	for (l = 0; l < NPHYS; l = l + 1) begin : g_lane
		wire [3:0] op_lane = (l < 4) ? op_q0 : op_q1;
		wire [2:0] rm_lane = (l < 4) ? rm_q0 : rm_q1;
		wire sat_lane      = (l < 4) ? sat_q0 : sat_q1;
		wire mine_lane     = (l < 4) ? mine_q0 : mine_q1;
		wire ovr_lo_lane   = (l < 4) ? ovr_lo_q0 : ovr_lo_q1;
		wire ovr_hi_lane   = (l < 4) ? ovr_hi_q0 : ovr_hi_q1;
		wire hsel_sw_lane  = (l < 4) ? hsel_sw_q0 : hsel_sw_q1;

`ifdef __ICARUS__
		wire [31:0] la  = mine ? x_a[l*32 +: 32] : 32'd0;
		wire [31:0] lb0 = mine ? x_b[l*32 +: 32] : 32'd0;
		wire [31:0] lc  = mine ? x_c[l*32 +: 32] : 32'd0;
`else
		wire [31:0] la = x_a[l*32 +: 32];
		wire [31:0] lb0 = x_b[l*32 +: 32];
		wire [31:0] lc = x_c[l*32 +: 32];
`endif
		wire hsel_sw_lo_l, hsel_sw_hi_l;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_hsw0 (.I0(hsel_sw_lane), .O(hsel_sw_lo_l));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_hsw1 (.I0(hsel_sw_lane), .O(hsel_sw_hi_l));
`else
		assign hsel_sw_lo_l = hsel_sw_lane;
		assign hsel_sw_hi_l = hsel_sw_lane;
`endif
		wire [15:0] lb_lo = hsel_sw_lo_l ? lb0[31:16] : lb0[15:0];
		wire [15:0] lb_hi = hsel_sw_hi_l ? lb0[15:0]  : lb0[31:16];
		wire [31:0] lb = {lb_hi, lb_lo};
		wire sub_l;
		wire [3:0] op_lo_l, op_hi_l;
		wire [2:0] rm_lo_l, rm_hi_l;
		wire sat_lo_l, sat_hi_l;
		wire mine_lo_l, mine_hi_l;
		wire ovr_lo_l, ovr_hi_l;
`ifdef SYNTH_KINTEX7
		genvar gob;
		for (gob = 0; gob < 4; gob = gob + 1) begin : g_op_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bop_lo (.I0(op_lane[gob]), .O(op_lo_l[gob]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bop_hi (.I0(op_lane[gob]), .O(op_hi_l[gob]));
		end
		for (gob = 0; gob < 3; gob = gob + 1) begin : g_rm_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_brm_lo (.I0(rm_lane[gob]), .O(rm_lo_l[gob]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_brm_hi (.I0(rm_lane[gob]), .O(rm_hi_l[gob]));
		end
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bsat_lo (.I0(sat_lane), .O(sat_lo_l));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bsat_hi (.I0(sat_lane), .O(sat_hi_l));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bmine_lo (.I0(mine_lane), .O(mine_lo_l));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bmine_hi (.I0(mine_lane), .O(mine_hi_l));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bovr_lo (.I0(ovr_lo_lane), .O(ovr_lo_l));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bovr_hi (.I0(ovr_hi_lane), .O(ovr_hi_l));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bsub    (.I0(sub),          .O(sub_l));
`else
		assign op_lo_l = op_lane;
		assign op_hi_l = op_lane;
		assign rm_lo_l = rm_lane;
		assign rm_hi_l = rm_lane;
		assign sat_lo_l = sat_lane;
		assign sat_hi_l = sat_lane;
		assign mine_lo_l = mine_lane;
		assign mine_hi_l = mine_lane;
		assign ovr_lo_l = ovr_lo_lane;
		assign ovr_hi_l = ovr_hi_lane;
		assign sub_l = sub;
`endif
		wire [31:0] un;
		am_fp_h2f #(.DENORM(0), .LAT(0)) u_un (.h(sub_l ? la[31:16] : la[15:0]), .f(un));

		wire [15:0] ovr_val_lo = is_unpack ? un[15:0]  : is_swaph ? la[31:16] : (PACKED != 0 ? la[15:0]  : 16'd0);
		wire [15:0] ovr_val_hi = is_unpack ? un[31:16] : is_swaph ? la[15:0]  : (PACKED != 0 ? la[31:16] : 16'd0);

		wire [15:0] lo, hi;
		atg_su_pk_half #(.ARITH(PACKED), .FP(!SH), .LAT(SHORT_LAT)) u_lo (
			.clk(clk), .rst_n(rst_n),
			.valid_in(mine_lo_l), .ovr_en(ovr_lo_l), .ovr_val(ovr_val_lo),
			.o(op_lo_l), .ha(la[15:0]), .hb(lb[15:0]), .hc(lc[15:0]), .r(rm_lo_l), .sat(sat_lo_l), .xw(la),
			.y(lo)
		);
		atg_su_pk_half #(.ARITH(PACKED), .FP(!SH), .LAT(SHORT_LAT)) u_hi (
			.clk(clk), .rst_n(rst_n),
			.valid_in(mine_hi_l), .ovr_en(ovr_hi_l), .ovr_val(ovr_val_hi),
			.o(op_hi_l), .ha(la[31:16]), .hb(lb[31:16]), .hc(lc[31:16]), .r(rm_hi_l), .sat(sat_hi_l), .xw(lb0),
			.y(hi)
		);
		assign s_data[l*32 +: 32] = {hi, lo};
	end
	endgenerate

	/* SHORT_LAT stages of control pipeline matching u_lo / u_hi */
	(* shreg_extract = "no" *) reg [CW-1:0] pipe [0:SHORT_LAT-1];
	integer k;
	always @(posedge clk) begin
		if (rst_p) begin
			for (k = 0; k < SHORT_LAT; k = k + 1)
				pipe[k][CW-1] <= 1'b0;
		end else begin
			pipe[0][CW-1] <= mine;
			for (k = 1; k < SHORT_LAT; k = k + 1)
				pipe[k][CW-1] <= pipe[k-1][CW-1];
		end
		pipe[0][CW-2:0] <= {x_warp, x_grp, x_uop[ATG_UOP_RD +: 7], x_mask[NPHYS-1:0]};
		for (k = 1; k < SHORT_LAT; k = k + 1)
			pipe[k][CW-2:0] <= pipe[k-1][CW-2:0];
	end

	wire [CW-1:0] o_ctrl = pipe[SHORT_LAT-1];
	assign s_valid = o_ctrl[CW-1];
	assign s_warp  = o_ctrl[CW-2 -: WARP_W];
	assign s_grp   = o_ctrl[CW-2-WARP_W -: GRP_W];
	assign s_rd    = o_ctrl[CW-2-WARP_W-GRP_W -: 7];
	assign s_lanes = o_ctrl[NPHYS-1:0];
	assign x_ready = !busy;

	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_mask[2*NPHYS-1:NPHYS], x_info, x_uop,
		(NWARPS != 0)};
endmodule

`default_nettype wire
