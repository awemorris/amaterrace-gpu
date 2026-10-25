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
 * datapath (atg_su_ffma_p in atg_su_fpu_op, one per lane); fract = x - floor(x)
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
 * flushed, atg_su_h2f), fma rounded to odd (rm 5, 6 for RDN's zero
 * sign; atg_su_rnd), the result to fp16 under rm with atg_su_hrnd
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
`include "atg_su_fp.vh"
`include "atg_su_fp16.vh"

	localparam DW = NPHYS * 32;
	localparam EW = 1 + WARP_W + GRP_W + 7 + NPHYS + DW;

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

	/* The operands of a lane's one 33 x 33 signed multiply (am_mul): the
	 * significands of the fused datapath's x * y (atg_su_fsig, zero
	 * extended), or for mul, mulh, mulhsu and mulhu the operands extended
	 * by sign or zero. */
	function [65:0] mulops;
		input [4:0] o;
		input [31:0] a, b;
		reg [47:0] sg;
		begin
			case (o)
			ATG_FPU_FMUL[4:0], ATG_FPU_FMADD[4:0], ATG_FPU_FMSUB[4:0], ATG_FPU_FNMSUB[4:0],
			ATG_FPU_FNMADD[4:0]: sg = atg_su_fsig(a[30:0], b[30:0]);
			default: sg = atg_su_fsig(a[30:0], 31'h3F800000);
			endcase
			if (o <= ATG_FPU_FNMADD[4:0] || o == ATG_FPU_FRACT[4:0])
				mulops = {9'd0, sg[23:0], 9'd0, sg[47:24]};
			else
				mulops = {(o == ATG_FPU_MUL[4:0] || o == ATG_FPU_MULH[4:0]) && b[31], b,
					o != ATG_FPU_MULHU[4:0] && a[31], a};
		end
	endfunction

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
	wire [DW-1:0] y;
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
		atg_su_h2f u_ha (.h(po == ATG_PK_FCMPGE2[3:0] ? hb : ha), .f(fa));
		atg_su_h2f u_hb (.h(po == ATG_PK_FCMPGE2[3:0] ? ha : hb), .f(fb));
		atg_su_h2f u_hc (.h(hc), .f(fc));
		wire pk = SH && (busy || mine_pk);
		wire [4:0] lo = pk ? pkop(po) : op;
		wire [31:0] la = pk ? fa : x_a[gl*32 +: 32];
		wire [31:0] lb = pk ? fb : x_b[gl*32 +: 32];
		wire [31:0] lc = pk ? fc : x_c[gl*32 +: 32];
		wire [2:0] lr = pk ? ((busy ? k_rm : rm) == 3'd2 ? 3'd6 : 3'd5) : rm;
		wire [65:0] mo = mulops(lo, la, lb);
		wire [65:0] pr;
		am_mul #(.AW(33), .BW(33), .SIGNED(1)) mul (
			.clk(clk), .en(1'b1), .a(mo[32:0]), .b(mo[65:33]), .p(pr)
		);
		wire [31:0] res;
		atg_su_fpu_op u_op (.o(lo), .ia(la), .ib(lb), .ic(lc), .irm(lr), .ist(!pk && sat), .pr(pr[63:0]),
			.res(res));
		/* the fp16 result (fp32 to fp16 under rm, flushed; compares as
		 * they are) and sat */
		wire [2:0] hr = busy ? k_rm : rm;
		wire [9:0] he;
		wire [15:0] hn;
		wire he_bo;
		am_sub #(.W(10)) u_he (.a({2'd0, res[30:23]}), .b(10'd112), .bi(1'b0), .d(he), .bo(he_bo));
		atg_su_hrnd u_hn (.s(res[31]), .e(he), .m({1'b1, res[22:13]}), .g(res[12]), .st(|res[11:0]),
			.rm(hr), .h(hn));
		wire [15:0] f2h = res[30:23] == 8'hFF ? (res[22:0] != 0 ? 16'h7E00 : {res[31], 5'h1F, 10'd0}) :
			res[30:23] == 8'd0 ? {res[31], 15'd0} : hn;
		wire [15:0] ph = po >= ATG_PK_FCMPLT2[3:0] ? res[15:0] : f2h;
		wire [15:0] pko = (busy ? k_sat : sat) && po < ATG_PK_FCMPLT2[3:0] ? atg_su_hsat(ph) : ph;
		wire unused_pr = &{1'b0, pr[65:64], he_bo};
		assign y[gl*32 +: 32] = SH && busy ? {16'd0, k_hs == 2'd1 ? k_a[gl*16 +: 16] : pko} :
			mine_pk ? {16'd0, hsel == 2'd2 ? x_a[gl*32 +: 16] : pko} :
			mine ? res : 32'd0;	/* (only for this unit's groups: fast simulation) */
	end
	endgenerate

	/* SHORT_LAT stages; stage 0 is registered from x_*. */
	reg [EW-1:0] pipe [0:SHORT_LAT-1];
	integer k;
	always @(posedge clk) begin
		if (!rst_n) begin
			for (k = 0; k < SHORT_LAT; k = k + 1)
				pipe[k] <= {EW{1'b0}};
		end else begin
			pipe[0] <= {mine || mine_pk, x_warp, x_grp, x_uop[ATG_UOP_RD +: 7],
				x_mask[NPHYS-1:0], y};
			for (k = 1; k < SHORT_LAT; k = k + 1)
				pipe[k] <= pipe[k-1];
			/* The high halves join their group in stage 1. */
			if (SH && busy)
				for (k = 0; k < NPHYS; k = k + 1)
					pipe[1][k*32 + 16 +: 16] <= y[k*32 +: 16];
		end
	end

	integer q;
	always @(posedge clk) begin
		if (!rst_n)
			busy <= 1'b0;
		else
			busy <= mine_pk;
		if (mine_pk) begin
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

	wire [EW-1:0] o = pipe[SHORT_LAT-1];
	assign s_valid = o[EW-1];
	assign s_warp = o[EW-2 -: WARP_W];
	assign s_grp = o[EW-2-WARP_W -: GRP_W];
	assign s_rd = o[EW-2-WARP_W-GRP_W -: 7];
	assign s_lanes = o[DW +: NPHYS];
	assign s_data = o[DW-1:0];
	assign x_ready = !busy;

	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_mask[2*NPHYS-1:NPHYS], x_info, x_uop,
		(NWARPS != 0)};
endmodule

`default_nettype wire
