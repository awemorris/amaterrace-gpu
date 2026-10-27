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
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
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

	/* busy: the cycle of the high halves of a packed group (PK_SHARED). */
	reg busy;
	wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_FPU && x_uop[ATG_UOP_WRD] && !busy;
	wire [4:0] op = x_uop[ATG_UOP_OP +: 5];
	wire [2:0] rm = x_uop[ATG_UOP_RM +: 3];
	wire sat = x_uop[ATG_UOP_MOD + 6];
	/* A packed fp16 operation taken (PK_SHARED). */
	wire [3:0] pop = x_uop[ATG_UOP_OP +: 4];
	wire pk_fp = pop <= ATG_PK_FMAX2[3:0] || (pop >= ATG_PK_FCMPLT2[3:0] && pop <= ATG_PK_FCMPNE2[3:0]);
	wire mine_pk = SH && x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_PK && x_uop[ATG_UOP_WRD] &&
		pk_fp && !busy;
	wire [1:0] hsel = x_uop[ATG_UOP_HSEL +: 2];
	/* The high halves' operation and operands, kept for the busy cycle. */
	reg [3:0] k_op;
	reg [2:0] k_rm;
	reg [1:0] k_hs;
	reg k_sat;
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
		wire pk = SH && (busy || mine_pk);
		wire [4:0] lo = pk ? pkop(po) : op;
		wire [31:0] la = pk ? fa : x_a[gl*32 +: 32];
		wire [31:0] lb = pk ? fb : x_b[gl*32 +: 32];
		wire [31:0] lc = pk ? fc : x_c[gl*32 +: 32];
		wire [2:0] lr = pk ? ((busy ? k_rm : rm) == 3'd2 ? 3'd6 : 3'd5) : rm;
		wire [31:0] res;
		am_fpu_core #(.LAT(6)) u_core (
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
		assign fpu_res[gl*32 +: 32] = res;
	end
	endgenerate

	/* Pipeline control registers for Stages 1 to 4 */
	reg s1_valid, s2_valid, s3_valid, s4_valid;
	reg [WARP_W-1:0] s1_warp, s2_warp, s3_warp, s4_warp;
	reg [GRP_W-1:0]  s1_grp,  s2_grp,  s3_grp,  s4_grp;
	reg [6:0]        s1_rd,   s2_rd,   s3_rd,   s4_rd;
	reg [NPHYS-1:0]  s1_mask, s2_mask, s3_mask, s4_mask;
	reg s1_pk, s2_pk, s3_pk, s4_pk;
	reg [1:0] s1_hsel, s2_hsel, s3_hsel, s4_hsel;
	reg s1_sat, s2_sat, s3_sat, s4_sat;
	reg [3:0] s1_pop, s2_pop, s3_pop, s4_pop;
	reg [2:0] s1_rm, s2_rm, s3_rm, s4_rm;
	reg [NPHYS*16-1:0] s1_xa, s2_xa, s3_xa, s4_xa;
	reg s1_busy, s2_busy, s3_busy, s4_busy;
	reg [3:0] s1_k_op, s2_k_op, s3_k_op, s4_k_op;
	reg [2:0] s1_k_rm, s2_k_rm, s3_k_rm, s4_k_rm;
	reg [1:0] s1_k_hs, s2_k_hs, s3_k_hs, s4_k_hs;
	reg s1_k_sat, s2_k_sat, s3_k_sat, s4_k_sat;
	reg [NPHYS*16-1:0] s1_k_a, s2_k_a, s3_k_a, s4_k_a;

	integer p;
	always @(posedge clk) begin
		if (!rst_n) begin
			s1_valid <= 1'b0; s2_valid <= 1'b0; s3_valid <= 1'b0; s4_valid <= 1'b0;
			s1_warp  <= 0;    s2_warp  <= 0;    s3_warp  <= 0;    s4_warp  <= 0;
			s1_grp   <= 0;    s2_grp   <= 0;    s3_grp   <= 0;    s4_grp   <= 0;
			s1_rd    <= 0;    s2_rd    <= 0;    s3_rd    <= 0;    s4_rd    <= 0;
			s1_mask  <= 0;    s2_mask  <= 0;    s3_mask  <= 0;    s4_mask  <= 0;
			s1_pk    <= 0;    s2_pk    <= 0;    s3_pk    <= 0;    s4_pk    <= 0;
			s1_hsel  <= 0;    s2_hsel  <= 0;    s3_hsel  <= 0;    s4_hsel  <= 0;
			s1_sat   <= 0;    s2_sat   <= 0;    s3_sat   <= 0;    s4_sat   <= 0;
			s1_pop   <= 0;    s2_pop   <= 0;    s3_pop   <= 0;    s4_pop   <= 0;
			s1_rm    <= 0;    s2_rm    <= 0;    s3_rm    <= 0;    s4_rm    <= 0;
			s1_xa    <= 0;    s2_xa    <= 0;    s3_xa    <= 0;    s4_xa    <= 0;
			s1_busy  <= 0;    s2_busy  <= 0;    s3_busy  <= 0;    s4_busy  <= 0;
			s1_k_op  <= 0;    s2_k_op  <= 0;    s3_k_op  <= 0;    s4_k_op  <= 0;
			s1_k_rm  <= 0;    s2_k_rm  <= 0;    s3_k_rm  <= 0;    s4_k_rm  <= 0;
			s1_k_hs  <= 0;    s2_k_hs  <= 0;    s3_k_hs  <= 0;    s4_k_hs  <= 0;
			s1_k_sat <= 0;    s2_k_sat <= 0;    s3_k_sat <= 0;    s4_k_sat <= 0;
			s1_k_a   <= 0;    s2_k_a   <= 0;    s3_k_a   <= 0;    s4_k_a   <= 0;
		end else if (en) begin
			s1_valid <= mine || mine_pk;
			s1_warp  <= x_warp;
			s1_grp   <= x_grp;
			s1_rd    <= x_uop[ATG_UOP_RD +: 7];
			s1_mask  <= x_mask[NPHYS-1:0];
			s1_pk    <= SH && mine_pk;
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

			s2_valid <= s1_valid; s2_warp <= s1_warp; s2_grp <= s1_grp; s2_rd <= s1_rd;
			s2_mask  <= s1_mask;  s2_pk   <= s1_pk;   s2_hsel <= s1_hsel; s2_sat <= s1_sat;
			s2_pop   <= s1_pop;   s2_rm   <= s1_rm;   s2_xa   <= s1_xa;   s2_busy <= s1_busy;
			s2_k_op  <= s1_k_op;  s2_k_rm <= s1_k_rm; s2_k_hs <= s1_k_hs; s2_k_sat <= s1_k_sat;
			s2_k_a   <= s1_k_a;

			s3_valid <= s2_valid; s3_warp <= s2_warp; s3_grp <= s2_grp; s3_rd <= s2_rd;
			s3_mask  <= s2_mask;  s3_pk   <= s2_pk;   s3_hsel <= s2_hsel; s3_sat <= s2_sat;
			s3_pop   <= s2_pop;   s3_rm   <= s2_rm;   s3_xa   <= s2_xa;   s3_busy <= s2_busy;
			s3_k_op  <= s2_k_op;  s3_k_rm <= s2_k_rm; s3_k_hs <= s2_k_hs; s3_k_sat <= s2_k_sat;
			s3_k_a   <= s2_k_a;

			s4_valid <= s3_valid; s4_warp <= s3_warp; s4_grp <= s3_grp; s4_rd <= s3_rd;
			s4_mask  <= s3_mask;  s4_pk   <= s3_pk;   s4_hsel <= s3_hsel; s4_sat <= s3_sat;
			s4_pop   <= s3_pop;   s4_rm   <= s3_rm;   s4_xa   <= s3_xa;   s4_busy <= s3_busy;
			s4_k_op  <= s3_k_op;  s4_k_rm <= s3_k_rm; s4_k_hs <= s3_k_hs; s4_k_sat <= s3_k_sat;
			s4_k_a   <= s3_k_a;
		end
	end

	/* Stage 4: fp16 formatting and rounding */
	wire [NPHYS*16-1:0] pko_comb;
	genvar g4;
	generate
	for (g4 = 0; g4 < NPHYS; g4 = g4 + 1) begin : g_pko
		wire [31:0] res4 = fpu_res[g4*32 +: 32];
		wire [3:0] po4 = s4_busy ? s4_k_op : s4_pop;
		wire [2:0] hr4 = s4_busy ? s4_k_rm : s4_rm;
		wire sat4 = s4_busy ? s4_k_sat : s4_sat;
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
		wire unused_he4 = &{1'b0, he4_bo};
	end
	endgenerate

	/* Stage 5 & 6 registers */
	reg s5_valid;
	reg [WARP_W-1:0] s5_warp;
	reg [GRP_W-1:0]  s5_grp;
	reg [6:0]        s5_rd;
	reg [NPHYS-1:0]  s5_mask;
	reg s5_pk;
	reg [1:0] s5_k_hs;
	reg [NPHYS*16-1:0] s5_k_a;
	reg [DW-1:0] s5_data;

	reg s6_valid;
	reg [WARP_W-1:0] s6_warp;
	reg [GRP_W-1:0]  s6_grp;
	reg [6:0]        s6_rd;
	reg [NPHYS-1:0]  s6_lanes;
	reg              s6_pk;
	reg [DW-1:0]     s6_data;

	integer i5;
	always @(posedge clk) begin
		if (!rst_n) begin
			s5_valid <= 1'b0;
			s5_warp  <= 0;
			s5_grp   <= 0;
			s5_rd    <= 0;
			s5_mask  <= 0;
			s5_pk    <= 0;
			s5_k_hs  <= 0;
			s5_k_a   <= 0;
			s5_data  <= 0;

			s6_valid <= 1'b0;
			s6_warp  <= 0;
			s6_grp   <= 0;
			s6_rd    <= 0;
			s6_lanes <= 0;
			s6_pk    <= 1'b0;
			s6_data  <= 0;
		end else if (en) begin
			/* Stage 5 captures Stage 4 output */
			s5_valid <= s4_valid;
			s5_warp  <= s4_warp;
			s5_grp   <= s4_grp;
			s5_rd    <= s4_rd;
			s5_mask  <= s4_mask;
			s5_pk    <= s4_pk;
			s5_k_hs  <= s4_k_hs;
			s5_k_a   <= s4_k_a;
			for (i5 = 0; i5 < NPHYS; i5 = i5 + 1) begin
				s5_data[i5*32 +: 32] <= s4_pk ?
					{16'd0, (s4_hsel == 2'd2) ? s4_xa[i5*16 +: 16] : pko_comb[i5*16 +: 16]} :
					32'd0;
			end

			/* Stage 6 captures Stage 5 output */
			s6_valid <= s5_valid;
			s6_warp  <= s5_warp;
			s6_grp   <= s5_grp;
			s6_rd    <= s5_rd;
			s6_lanes <= s5_mask;
			s6_pk    <= s5_pk;
			for (i5 = 0; i5 < NPHYS; i5 = i5 + 1) begin
				if (s5_pk) begin
					s6_data[i5*32 +: 16]      <= s5_data[i5*32 +: 16];
					s6_data[i5*32 + 16 +: 16] <= (s5_k_hs == 2'd1) ?
						s5_k_a[i5*16 +: 16] : pko_comb[i5*16 +: 16];
				end else begin
					s6_data[i5*32 +: 32] <= 32'd0;
				end
			end
		end
	end

	integer q;
	always @(posedge clk) begin
		if (!rst_n)
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

	wire [DW-1:0] s_data_mux;
	genvar g_sd;
	generate
	for (g_sd = 0; g_sd < NPHYS; g_sd = g_sd + 1) begin : g_sd_mux
		assign s_data_mux[g_sd*32 +: 32] = s6_pk ? s6_data[g_sd*32 +: 32] : fpu_res[g_sd*32 +: 32];
	end
	endgenerate
	assign s_data = s_data_mux;

	assign x_ready = !busy;

	wire [DW-1:0] fpu_s4_data;
	genvar gf;
	generate
	for (gf = 0; gf < NPHYS; gf = gf + 1) begin : g_fwd4
		assign fpu_s4_data[gf*32 +: 32] = s4_pk ?
			{16'd0, (s4_hsel == 2'd2) ? s4_xa[gf*16 +: 16] : pko_comb[gf*16 +: 16]} :
			fpu_res[gf*32 +: 32];
	end
	endgenerate

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

	wire unused_s5 = &{1'b0, s5_valid, s5_warp, s5_grp, s5_rd, s5_mask, s5_data};
	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_mask[2*NPHYS-1:NPHYS], x_info, x_uop,
		k_hs, k_sat, (SHORT_LAT != 0), (NWARPS != 0), fpu_s4_data, unused_s5};
endmodule

`default_nettype wire
