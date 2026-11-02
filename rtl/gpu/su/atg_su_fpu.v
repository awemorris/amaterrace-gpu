/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fpu: The fp32 unit of the SU, NPHYS lanes: fadd/fsub/fmul/fmadd
 * family (FMA on DSPs), fmin/fmax, fsgnj, fround, fcvt, feq/flt/fle/fne
 * (Boolean), fract, sat; also the integer mul* (DSP). Short pipeline.
 *
 * Takes every group of a uop whose unit is FPU (x_ready is 1 but in the
 * busy cycle of PK_SHARED, below) and
 * presents its result on s_* exactly SHORT_LAT cycles after x_valid, in
 * order, like atg_su_alu.  IEEE binary32 with the rules of design §3.1:
 * one rounding under the uop's rm (0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM,
 * 7 = RNE), denormals flushed on input and output, canonical NaN
 * 0x7FC00000.  fadd/fsub/fmul and the fmadd family share one fused
 * datapath (am_fp_fma_p in atg_su_fpu_op, one per lane); fract = x - floor(x)
 * through the same datapath (RNE); compares write Boolean (all ones/0);
 * the sat bit clamps float results to [0, 1].  mul* are the integer
 * multiplies of RISC-V M.  The reference is tools/gsi1fp.py.
 *
 * PK_SHARED (with PACKED): this unit also takes the packed unit's fp16
 * operations (fadd2/fsub2/fmul2/ffma2/fmin2/fmax2/fcmp*2, atg_su_pk does
 * the others) and does them on its fp32 datapath, a half a cycle: the low
 * halves in the cycle it takes the group, the high halves (from operands
 * kept then) in the next, in which x_ready is 0 (atg_su_pk's x_ready is 0
 * in that cycle too, and no FPU or PK group is taken).  The result is the
 * same, SHORT_LAT cycles after x_valid: the operands to fp32 (exact,
 * flushed, am_fp_h2f), fma rounded to odd (rm 5, 6 for RDN's zero
 * sign; am_fp_rnd), the result to fp16 under rm with am_fp_hrnd
 * (one rounding of the exact result), min, max and the compares exact;
 * then hsel and sat as in atg_su_pk.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_fpu #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter SHORT_LAT = 6,	/* Cycles from x_valid to the short result (one fixed pipeline for classes a and f, design §3.1.1) */
	parameter PACKED = 0,	/* Packed fp16 arithmetic present (atg_su_pk) */
	parameter PK_SHARED = 0	/* With PACKED: the fp16 arithmetic on this unit's fp32 datapath, a half a cycle (above) */
) (
	input wire clk,
	input wire rst_n,
	input wire en,
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
	output wire [NPHYS-1:0] s_lanes,

	/* Forwarding buses (to atg_su_opd) */
	output wire fwd_ex4_valid,
	output wire [WARP_W-1:0] fwd_ex4_warp,
	output wire [GRP_W-1:0] fwd_ex4_grp,
	output wire [6:0] fwd_ex4_rd,
	output wire [NPHYS*32-1:0] fwd_ex4_data,
	output wire [NPHYS-1:0] fwd_ex4_lanes,

	output wire fwd_ex5_valid,
	output wire [WARP_W-1:0] fwd_ex5_warp,
	output wire [GRP_W-1:0] fwd_ex5_grp,
	output wire [6:0] fwd_ex5_rd,
	output wire [NPHYS*32-1:0] fwd_ex5_data,
	output wire [NPHYS-1:0] fwd_ex5_lanes
);
`include "atg_su_uop.vh"
`include "atg_su_fp.vh"
`include "atg_su_fp16.vh"

	localparam DW = NPHYS * 32;

	localparam SH = PK_SHARED != 0 && PACKED != 0;

	wire rst_p = !rst_n;

	/* busy: the cycle of the high halves of a packed group (PK_SHARED). */
	(* max_fanout = 12 *) reg busy;
	(* max_fanout = 12 *) wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_FPU && x_uop[ATG_UOP_WRD] && !busy;
	(* max_fanout = 12 *) wire [4:0] op = x_uop[ATG_UOP_OP +: 5];
	(* max_fanout = 12 *) wire [2:0] rm = x_uop[ATG_UOP_RM +: 3];
	(* max_fanout = 12 *) wire sat = x_uop[ATG_UOP_MOD + 6];
	/* A packed fp16 operation taken (PK_SHARED). */
	(* max_fanout = 12 *) wire [3:0] pop = x_uop[ATG_UOP_OP +: 4];
	wire pk_fp = pop <= ATG_PK_FMAX2[3:0] || (pop >= ATG_PK_FCMPLT2[3:0] && pop <= ATG_PK_FCMPNE2[3:0]);
	(* max_fanout = 12 *) wire mine_pk = SH && x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_PK && x_uop[ATG_UOP_WRD] &&
		pk_fp && !busy;
	(* max_fanout = 12 *) wire [1:0] hsel = x_uop[ATG_UOP_HSEL +: 2];
	/* The high halves' operation and operands, kept for the busy cycle. */
	(* max_fanout = 12 *) reg [3:0] k_op;
	(* max_fanout = 12 *) reg [2:0] k_rm;
	(* max_fanout = 12 *) reg [1:0] k_hs;
	(* max_fanout = 12 *) reg k_sat;
	reg [NPHYS*16-1:0] k_a, k_b, k_c;


	/* A packed fp16 operation o (atg_su_pk's half): the FPU operation that
	 * does it on the fp32 operands (fcmpge2: le with them swapped). */
	function [4:0] pkop;
		input [3:0] o;
		case (o)
		ATG_PK_FADD2[3:0]: pkop = ATG_FPU_FADD[4:0];
		ATG_PK_FSUB2[3:0]: pkop = ATG_FPU_FSUB[4:0];
		ATG_PK_FMUL2[3:0]: pkop = ATG_FPU_FMUL[4:0];
		ATG_PK_FFMA2[3:0]: pkop = ATG_FPU_FMADD[4:0];
		ATG_PK_FMIN2[3:0]: pkop = ATG_FPU_FMIN[4:0];
		ATG_PK_FMAX2[3:0]: pkop = ATG_FPU_FMAX[4:0];
		ATG_PK_FCMPLT2[3:0]: pkop = ATG_FPU_FLT[4:0];
		ATG_PK_FCMPGE2[3:0]: pkop = ATG_FPU_FLE[4:0];
		ATG_PK_FCMPEQ2[3:0]: pkop = ATG_FPU_FEQ[4:0];
		default: pkop = ATG_FPU_FNE[4:0];
		endcase
	endfunction

	/* The lanes: this unit's operation, a packed group's low halves (the
	 * high ones from rs1 for hsel 10), or in the busy cycle the kept high
	 * halves (those of rs1 for hsel 01); each lane's one multiplier. */
	wire [DW-1:0] fpu_res;
	genvar gl;
	generate
	for (gl = 0; gl < NPHYS; gl = gl + 1) begin : g_lane
		wire [31:0] res;
		if (SH) begin : g_core_sh
			/* the packed halves (kept ones in the busy cycle), to fp32 */
			wire [3:0] po = busy ? k_op : pop;
			wire [15:0] bsw = hsel == 2'd3 ? x_b[gl*32 + 16 +: 16] : x_b[gl*32 +: 16];
			wire [15:0] ha = busy ? k_a[gl*16 +: 16] : x_a[gl*32 +: 16];
			wire [15:0] hb = busy ? k_b[gl*16 +: 16] : bsw;
			wire [15:0] hc = busy ? k_c[gl*16 +: 16] : x_c[gl*32 +: 16];
			wire [31:0] fa, fb, fc;
			am_fp_h2f #(.DENORM(0), .LAT(0)) u_ha (.h(po == ATG_PK_FCMPGE2[3:0] ? hb : ha), .f(fa));
			am_fp_h2f #(.DENORM(0), .LAT(0)) u_hb (.h(po == ATG_PK_FCMPGE2[3:0] ? ha : hb), .f(fb));
			am_fp_h2f #(.DENORM(0), .LAT(0)) u_hc (.h(hc), .f(fc));
			wire pk = busy || mine_pk;
			wire [4:0] lo = pk ? pkop(po) : op;
			wire [31:0] la = pk ? fa : x_a[gl*32 +: 32];
			wire [31:0] lb = pk ? fb : x_b[gl*32 +: 32];
			wire [31:0] lc = pk ? fc : x_c[gl*32 +: 32];
			wire [2:0] lr = pk ? ((busy ? k_rm : rm) == 3'd2 ? 3'd6 : 3'd5) : rm;
			am_fpu_core #(.LAT(SHORT_LAT)) u_core (
				.clk(clk),
				.rst_n(rst_n),
				.en(en),
				.op(lo),
				.rm(lr),
				.sat(!pk && sat),
				.a(la),
				.b(lb),
				.c(lc),
				.res(res)
			);
		end else begin : g_core_nosh
`ifdef __ICARUS__
			wire [4:0]  sim_op  = mine ? op : 5'd0;
			wire [2:0]  sim_rm  = mine ? rm : 3'd0;
			wire        sim_sat = mine && sat;
			wire [31:0] sim_a   = mine ? x_a[gl*32 +: 32] : 32'd0;
			wire [31:0] sim_b   = mine ? x_b[gl*32 +: 32] : 32'd0;
			wire [31:0] sim_c   = mine ? x_c[gl*32 +: 32] : 32'd0;
`else
			wire [4:0] op_l;
			wire [2:0] rm_l;
			wire       sat_l;
`ifdef SYNTH_KINTEX7
			genvar gbop;
			for (gbop = 0; gbop < 5; gbop = gbop + 1) begin : g_buf_op
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_op (.I0(op[gbop]), .O(op_l[gbop]));
			end
			for (gbop = 0; gbop < 3; gbop = gbop + 1) begin : g_buf_rm
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rm (.I0(rm[gbop]), .O(rm_l[gbop]));
			end
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_sat (.I0(sat), .O(sat_l));
`else
			assign op_l  = op;
			assign rm_l  = rm;
			assign sat_l = sat;
`endif
			wire [4:0]  sim_op  = op_l;
			wire [2:0]  sim_rm  = rm_l;
			wire        sim_sat = sat_l;
			wire [31:0] sim_a   = x_a[gl*32 +: 32];
			wire [31:0] sim_b   = x_b[gl*32 +: 32];
			wire [31:0] sim_c   = x_c[gl*32 +: 32];
`endif
			am_fpu_core #(.LAT(SHORT_LAT)) u_core (
				.clk(clk),
				.rst_n(rst_n),
				.en(en),
				.op(sim_op),
				.rm(sim_rm),
				.sat(sim_sat),
				.a(sim_a),
				.b(sim_b),
				.c(sim_c),
				.res(res)
			);
		end
		assign fpu_res[gl*32 +: 32] = res;
	end
	endgenerate

	/* Pipeline control registers for Stages 1 to 6 */
	(* shreg_extract = "no", max_fanout = 12 *) reg s1_valid, s2_valid, s3_valid, s4_valid, s5_valid, s6_valid;
	(* shreg_extract = "no", max_fanout = 12 *) reg [WARP_W-1:0] s1_warp, s2_warp, s3_warp, s4_warp, s5_warp, s6_warp;
	(* shreg_extract = "no", max_fanout = 12 *) reg [GRP_W-1:0]  s1_grp,  s2_grp,  s3_grp,  s4_grp,  s5_grp,  s6_grp;
	(* shreg_extract = "no", max_fanout = 12 *) reg [6:0]        s1_rd,   s2_rd,   s3_rd,   s4_rd,   s5_rd,   s6_rd;
	(* shreg_extract = "no", max_fanout = 12 *) reg [NPHYS-1:0]  s1_mask, s2_mask, s3_mask, s4_mask, s5_mask, s6_lanes;

	always @(posedge clk) begin
		if (rst_p) begin
			s1_valid <= 1'b0; s2_valid <= 1'b0; s3_valid <= 1'b0; s4_valid <= 1'b0; s5_valid <= 1'b0; s6_valid <= 1'b0;
			s1_warp  <= 0;    s2_warp  <= 0;    s3_warp  <= 0;    s4_warp  <= 0;    s5_warp  <= 0;    s6_warp  <= 0;
			s1_grp   <= 0;    s2_grp   <= 0;    s3_grp   <= 0;    s4_grp   <= 0;    s5_grp   <= 0;    s6_grp   <= 0;
			s1_rd    <= 0;    s2_rd    <= 0;    s3_rd    <= 0;    s4_rd    <= 0;    s5_rd    <= 0;    s6_rd    <= 0;
			s1_mask  <= 0;    s2_mask  <= 0;    s3_mask  <= 0;    s4_mask  <= 0;    s5_mask  <= 0;    s6_lanes <= 0;
		end else if (en) begin
			s1_valid <= mine || mine_pk;
			s1_warp  <= x_warp;
			s1_grp   <= x_grp;
			s1_rd    <= x_uop[ATG_UOP_RD +: 7];
			s1_mask  <= x_mask[NPHYS-1:0];

			s2_valid <= s1_valid; s2_warp <= s1_warp; s2_grp <= s1_grp; s2_rd <= s1_rd; s2_mask  <= s1_mask;
			s3_valid <= s2_valid; s3_warp <= s2_warp; s3_grp <= s2_grp; s3_rd <= s2_rd; s3_mask  <= s2_mask;
			s4_valid <= s3_valid; s4_warp <= s3_warp; s4_grp <= s3_grp; s4_rd <= s3_rd; s4_mask  <= s3_mask;
			s5_valid <= s4_valid; s5_warp <= s4_warp; s5_grp <= s4_grp; s5_rd <= s4_rd; s5_mask  <= s4_mask;
			s6_valid <= s5_valid; s6_warp <= s5_warp; s6_grp <= s5_grp; s6_rd <= s5_rd; s6_lanes <= s5_mask;
		end
	end

	generate
	if (SH) begin : g_sh_pipe
		(* shreg_extract = "no", max_fanout = 12 *) reg s1_pk, s2_pk, s3_pk, s4_pk, s5_pk, s6_pk;
		(* shreg_extract = "no", max_fanout = 12 *) reg [1:0] s1_hsel, s2_hsel, s3_hsel, s4_hsel;
		(* shreg_extract = "no", max_fanout = 12 *) reg s1_sat, s2_sat, s3_sat, s4_sat;
		(* shreg_extract = "no", max_fanout = 12 *) reg [3:0] s1_pop, s2_pop, s3_pop, s4_pop;
		(* shreg_extract = "no", max_fanout = 12 *) reg [2:0] s1_rm, s2_rm, s3_rm, s4_rm;
		(* shreg_extract = "no" *) reg [NPHYS*16-1:0] s1_xa, s2_xa, s3_xa, s4_xa;
		(* shreg_extract = "no", max_fanout = 12 *) reg s1_busy, s2_busy, s3_busy, s4_busy;
		(* shreg_extract = "no", max_fanout = 12 *) reg [3:0] s1_k_op, s2_k_op, s3_k_op, s4_k_op, s5_k_op;
		(* shreg_extract = "no", max_fanout = 12 *) reg [2:0] s1_k_rm, s2_k_rm, s3_k_rm, s4_k_rm, s5_k_rm;
		(* shreg_extract = "no", max_fanout = 12 *) reg [1:0] s1_k_hs, s2_k_hs, s3_k_hs, s4_k_hs, s5_k_hs;
		(* shreg_extract = "no", max_fanout = 12 *) reg s1_k_sat, s2_k_sat, s3_k_sat, s4_k_sat, s5_k_sat;
		(* shreg_extract = "no" *) reg [NPHYS*16-1:0] s1_k_a, s2_k_a, s3_k_a, s4_k_a, s5_k_a;
		(* shreg_extract = "no" *) reg [DW-1:0] s5_data;
		(* shreg_extract = "no", max_fanout = 12 *) reg [DW-1:0] s6_data;

		wire [NPHYS*16-1:0] pko_comb;
		genvar g4;
		for (g4 = 0; g4 < NPHYS; g4 = g4 + 1) begin : g_pko
			wire [31:0] res4 = fpu_res[g4*32 +: 32];
			wire [3:0] po4 = s5_pk ? s5_k_op : s4_pop;
			wire [2:0] hr4 = s5_pk ? s5_k_rm : s4_rm;
			wire sat4 = s5_pk ? s5_k_sat : s4_sat;
			wire [9:0] he4;
			wire he4_bo;
			wire [15:0] hn4;
			am_sub #(.W(10)) u_he (.a({2'd0, res4[30:23]}), .b(10'd112), .bi(1'b0), .d(he4), .bo(he4_bo));
			am_fp_hrnd #(.LAT(0)) u_hn (.s(res4[31]), .e(he4), .m({1'b1, res4[22:13]}), .g(res4[12]), .st(|res4[11:0]),
				.rm(hr4), .h(hn4));
			wire [15:0] f2h4 = res4[30:23] == 8'hFF ? (res4[22:0] != 0 ? 16'h7E00 : {res4[31], 5'h1F, 10'd0}) :
				res4[30:23] == 8'd0 ? {res4[31], 15'd0} : hn4;
			wire [15:0] ph4 = po4 >= ATG_PK_FCMPLT2[3:0] ? res4[15:0] : f2h4;
			wire [15:0] pko4 = sat4 && po4 < ATG_PK_FCMPLT2[3:0] ? atg_su_hsat(ph4) : ph4;
			assign pko_comb[g4*16 +: 16] = pko4;
			wire unused_he4 = &{1'b0, he4_bo, s1_busy, s2_busy, s3_busy, s4_busy, s6_pk};
		end

		integer p, i5;
		always @(posedge clk) begin
			if (rst_p) begin
				s1_pk    <= 0; s2_pk    <= 0; s3_pk    <= 0; s4_pk    <= 0; s5_pk    <= 0; s6_pk <= 0;
				s1_hsel  <= 0; s2_hsel  <= 0; s3_hsel  <= 0; s4_hsel  <= 0;
				s1_sat   <= 0; s2_sat   <= 0; s3_sat   <= 0; s4_sat   <= 0;
				s1_pop   <= 0; s2_pop   <= 0; s3_pop   <= 0; s4_pop   <= 0;
				s1_rm    <= 0; s2_rm    <= 0; s3_rm    <= 0; s4_rm    <= 0;
				s1_xa    <= 0; s2_xa    <= 0; s3_xa    <= 0; s4_xa    <= 0;
				s1_busy  <= 0; s2_busy  <= 0; s3_busy  <= 0; s4_busy  <= 0;
				s1_k_op  <= 0; s2_k_op  <= 0; s3_k_op  <= 0; s4_k_op  <= 0; s5_k_op  <= 0;
				s1_k_rm  <= 0; s2_k_rm  <= 0; s3_k_rm  <= 0; s4_k_rm  <= 0; s5_k_rm  <= 0;
				s1_k_hs  <= 0; s2_k_hs  <= 0; s3_k_hs  <= 0; s4_k_hs  <= 0; s5_k_hs  <= 0;
				s1_k_sat <= 0; s2_k_sat <= 0; s3_k_sat <= 0; s4_k_sat <= 0; s5_k_sat <= 0;
				s1_k_a   <= 0; s2_k_a   <= 0; s3_k_a   <= 0; s4_k_a   <= 0; s5_k_a   <= 0;
				s5_data  <= 0; s6_data  <= 0;
			end else if (en) begin
				s1_pk    <= mine_pk;
				s1_hsel  <= hsel;
				s1_sat   <= sat;
				s1_pop   <= pop;
				s1_rm    <= rm;
				for (p = 0; p < NPHYS; p = p + 1)
					s1_xa[p*16 +: 16] <= x_a[p*32 +: 16];
				s1_busy  <= busy;
				s1_k_op  <= pop;
				s1_k_rm  <= rm;
				s1_k_hs  <= hsel;
				s1_k_sat <= sat;
				for (p = 0; p < NPHYS; p = p + 1)
					s1_k_a[p*16 +: 16] <= x_a[p*32 + 16 +: 16];

				s2_pk   <= s1_pk;   s2_hsel <= s1_hsel; s2_sat <= s1_sat;
				s2_pop  <= s1_pop;  s2_rm   <= s1_rm;   s2_xa  <= s1_xa;   s2_busy  <= s1_busy;
				s2_k_op <= s1_k_op; s2_k_rm <= s1_k_rm; s2_k_hs <= s1_k_hs; s2_k_sat <= s1_k_sat;
				s2_k_a  <= s1_k_a;

				s3_pk   <= s2_pk;   s3_hsel <= s2_hsel; s3_sat <= s2_sat;
				s3_pop  <= s2_pop;  s3_rm   <= s2_rm;   s3_xa  <= s2_xa;   s3_busy  <= s2_busy;
				s3_k_op <= s2_k_op; s3_k_rm <= s2_k_rm; s3_k_hs <= s2_k_hs; s3_k_sat <= s2_k_sat;
				s3_k_a  <= s2_k_a;

				s4_pk   <= s3_pk;   s4_hsel <= s3_hsel; s4_sat <= s3_sat;
				s4_pop  <= s3_pop;  s4_rm   <= s3_rm;   s4_xa  <= s3_xa;   s4_busy  <= s3_busy;
				s4_k_op <= s3_k_op; s4_k_rm <= s3_k_rm; s4_k_hs <= s3_k_hs; s4_k_sat <= s3_k_sat;
				s4_k_a  <= s3_k_a;

				s5_pk    <= s4_pk;
				s5_k_op  <= s4_k_op;
				s5_k_rm  <= s4_k_rm;
				s5_k_sat <= s4_k_sat;
				s5_k_hs  <= s4_k_hs;
				s5_k_a   <= s4_k_a;
				for (i5 = 0; i5 < NPHYS; i5 = i5 + 1) begin
					s5_data[i5*32 +: 32] <= s4_pk ?
						{16'd0, (s4_hsel == 2'd2) ? s4_xa[i5*16 +: 16] : pko_comb[i5*16 +: 16]} :
						fpu_res[i5*32 +: 32];
				end

				s6_pk <= s5_pk;
				for (i5 = 0; i5 < NPHYS; i5 = i5 + 1) begin
					if (s5_pk) begin
						s6_data[i5*32 +: 16]      <= s5_data[i5*32 +: 16];
						s6_data[i5*32 + 16 +: 16] <= (s5_k_hs == 2'd1) ?
							s5_k_a[i5*16 +: 16] : pko_comb[i5*16 +: 16];
					end else begin
						s6_data[i5*32 +: 32] <= s5_data[i5*32 +: 32];
					end
				end
			end
		end

		assign s_data = s6_data;
	end else begin : g_nosh_pipe
		assign s_data = fpu_res;
	end
	endgenerate

	integer q;
	always @(posedge clk) begin
		if (rst_p)
			busy <= 1'b0;
		else if (en)
			busy <= mine_pk;
		if (mine_pk && en) begin
			k_op <= pop;
			k_rm <= rm;
			k_hs <= hsel;
			k_sat <= sat;
			for (q = 0; q < NPHYS; q = q + 1) begin
				k_a[q*16 +: 16] <= x_a[q*32 + 16 +: 16];
				k_b[q*16 +: 16] <= hsel == 2'd3 ? x_b[q*32 +: 16] : x_b[q*32 + 16 +: 16];
				k_c[q*16 +: 16] <= x_c[q*32 + 16 +: 16];
			end
		end
	end

	assign s_valid = s6_valid;
	assign s_warp  = s6_warp;
	assign s_grp   = s6_grp;
	assign s_rd    = s6_rd;
	assign s_lanes = s6_lanes;

	assign x_ready = !busy;

	assign fwd_ex4_valid = 1'b0;
	assign fwd_ex4_warp  = {WARP_W{1'b0}};
	assign fwd_ex4_grp   = {GRP_W{1'b0}};
	assign fwd_ex4_rd    = 7'd0;
	assign fwd_ex4_data  = {DW{1'b0}};
	assign fwd_ex4_lanes = {NPHYS{1'b0}};

	assign fwd_ex5_valid = 1'b0;
	assign fwd_ex5_warp  = {WARP_W{1'b0}};
	assign fwd_ex5_grp   = {GRP_W{1'b0}};
	assign fwd_ex5_rd    = 7'd0;
	assign fwd_ex5_data  = {DW{1'b0}};
	assign fwd_ex5_lanes = {NPHYS{1'b0}};

	wire unused_s5 = &{1'b0, s5_valid, s5_warp, s5_grp, s5_rd, s5_mask};
	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_mask[2*NPHYS-1:NPHYS], x_info, x_uop,
		k_op, k_rm, k_hs, k_sat, k_a, k_b, k_c, hsel, (SHORT_LAT != 0), (NWARPS != 0), unused_s5};
endmodule

`default_nettype wire
