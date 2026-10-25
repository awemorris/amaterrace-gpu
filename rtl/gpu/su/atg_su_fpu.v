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
 * datapath (atg_su_ffma of include/atg_su_fp.vh); fract = x - floor(x)
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
 * flushed, include/atg_su_fp16.vh atg_su_h2f), fma rounded to odd (rm 5,
 * 6 for RDN's zero sign; include/atg_su_fp.vh), the result to fp16 under
 * rm (one rounding of the exact result), min, max and the compares exact;
 * then hsel and sat as in atg_su_pk.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_fpu #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
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

	/* fcvt.w.s / fcvt.wu.s of the flushed x from its rounded integer n
	 * (atg_su_rint): atg_su_f2i with the rounding shared with fround. */
	function [31:0] f2i_n;
		input [31:0] x;
		input [24:0] n;
		input uns;
		reg [31:0] mag;
		reg s, nan, big;
		begin
			nan = x[30:23] == 8'hFF && x[22:0] != 0;
			s = x[31] && !nan;
			big = x[30:23] >= 8'd159;
			if (x[30:23] >= 8'd150)
				mag = {8'd0, 1'b1, x[22:0]} << (x[30:23] - 8'd150);
			else
				mag = {7'd0, n};
			if (uns)
				f2i_n = s ? 32'd0 : big ? 32'hFFFFFFFF : mag;	/* negatives give 0 */
			else begin
				if (big || (!s && mag[31]) || (s && mag > 32'h80000000))
					f2i_n = s ? 32'h80000000 : 32'h7FFFFFFF;
				else
					f2i_n = s ? 32'd0 - mag : mag;
			end
		end
	endfunction

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

	/* One lane.  The operations share one rounding to an integer (fround,
	 * fract, fcvt.w*), one integer-to-float (fround, fract, fcvt.s.w*)
	 * and one 33 x 33 signed multiply pr (mulops: the fused datapath's
	 * significands, or mul, mulh, mulhsu and mulhu); the results are those
	 * of atg_su_ffma, atg_su_fround, atg_su_f2i, atg_su_i2f and the 64-bit
	 * products.  (Measured with Vivado, NPHYS 8: with PK_SHARED one shared
	 * multiplier is 20,774 LUTs and 32 DSP48E1, two multipliers (24 x 24
	 * and 33 x 33) 21,076 and 48; without PK_SHARED 18,386 / 32 against
	 * 17,431 / 48.) */
	function [31:0] fpu;
		input [4:0] o;
		input [31:0] a, b, c;
		input [2:0] r;
		input st;
		input [63:0] pr;	/* the product's low 64 bits */
		reg [31:0] x, y, z, fl, res, xf, iv, in_n;
		reg [24:0] n;
		reg [2:0] rr, in_r;
		reg noc, fma, flt, in_s;
		begin
			/* Rounding to an integer and integer to float, shared. */
			xf = atg_su_flush(a);
			n = atg_su_rint(xf, o == ATG_FPU_FRACT[4:0] ? 3'd2 : r);
			case (o)
			ATG_FPU_FCVTSW[4:0]: begin
				in_s = a[31];
				in_n = a[31] ? 32'd0 - a : a;
				in_r = r;
			end
			ATG_FPU_FCVTSWU[4:0]: begin
				in_s = 1'b0;
				in_n = a;
				in_r = r;
			end
			default: begin
				in_s = xf[31];
				in_n = {7'd0, n};
				in_r = 3'd0;
			end
			endcase
			iv = atg_su_i2f(in_s, in_n, in_r);
			/* fround (atg_su_fround) */
			if (xf[30:23] == 8'hFF && xf[22:0] != 0)
				fl = 32'h7FC00000;
			else if (xf[30:23] >= 8'd150 || xf[30:23] == 8'd0)
				fl = xf;
			else
				fl = iv;
			/* The fused datapath's operands. */
			x = a;
			y = 32'h3F800000;
			z = b;
			noc = 1'b0;
			rr = r;
			case (o)
			ATG_FPU_FSUB[4:0]: z = {!b[31], b[30:0]};
			ATG_FPU_FMUL[4:0]: begin
				y = b;
				noc = 1'b1;
			end
			ATG_FPU_FMADD[4:0]: begin
				y = b;
				z = c;
			end
			ATG_FPU_FMSUB[4:0]: begin
				y = b;
				z = {!c[31], c[30:0]};
			end
			ATG_FPU_FNMSUB[4:0]: begin
				x = {!a[31], a[30:0]};
				y = b;
				z = c;
			end
			ATG_FPU_FNMADD[4:0]: begin
				x = {!a[31], a[30:0]};
				y = b;
				z = {!c[31], c[30:0]};
			end
			ATG_FPU_FRACT[4:0]: begin
				z = {!fl[31], fl[30:0]};
				rr = 3'd0;
			end
			default: ;
			endcase
			fma = o <= ATG_FPU_FNMADD[4:0] || o == ATG_FPU_FRACT[4:0];
			flt = 1'b1;
			res = 32'd0;
			if (fma)
				res = atg_su_ffma_p(x, y, z, rr, noc, pr[47:0]);
			else begin
				case (o)
				ATG_FPU_FSGNJ[4:0]: res = {b[31], a[30:0]};
				ATG_FPU_FMIN[4:0]: res = atg_su_fminmax(a, b, 1'b0);
				ATG_FPU_FMAX[4:0]: res = atg_su_fminmax(a, b, 1'b1);
				ATG_FPU_FCVTWS[4:0], ATG_FPU_FCVTWUS[4:0]:
					res = f2i_n(xf, n, o == ATG_FPU_FCVTWUS[4:0]);
				ATG_FPU_FCVTSW[4:0], ATG_FPU_FCVTSWU[4:0]: res = iv;
				ATG_FPU_FEQ[4:0]: res = {32{atg_su_fcmp(a, b, 2'd0)}};
				ATG_FPU_FLT[4:0]: res = {32{atg_su_fcmp(a, b, 2'd1)}};
				ATG_FPU_FLE[4:0]: res = {32{atg_su_fcmp(a, b, 2'd2)}};
				ATG_FPU_FNE[4:0]: res = {32{atg_su_fcmp(a, b, 2'd3)}};
				ATG_FPU_FROUND[4:0]: res = fl;
				ATG_FPU_MUL[4:0]: res = pr[31:0];
				ATG_FPU_MULH[4:0], ATG_FPU_MULHSU[4:0], ATG_FPU_MULHU[4:0]: res = pr[63:32];
				default: ;
				endcase
			end
			case (o)
			ATG_FPU_FCVTWS[4:0], ATG_FPU_FCVTWUS[4:0], ATG_FPU_FEQ[4:0], ATG_FPU_FLT[4:0],
			ATG_FPU_FLE[4:0], ATG_FPU_FNE[4:0], ATG_FPU_MUL[4:0], ATG_FPU_MULH[4:0],
			ATG_FPU_MULHSU[4:0], ATG_FPU_MULHU[4:0]: flt = 1'b0;
			default: ;
			endcase
			fpu = st && flt ? atg_su_sat(res) : res;
		end
	endfunction

	/* fp32 -> fp16 under rm (atg_su_f2h's rules), flushed. */
	function [15:0] f2hr;
		input [31:0] x;
		input [2:0] r;
		begin
			if (x[30:23] == 8'hFF)
				f2hr = x[22:0] != 0 ? 16'h7E00 : {x[31], 5'h1F, 10'd0};
			else if (x[30:23] == 8'd0)
				f2hr = {x[31], 15'd0};
			else
				f2hr = atg_su_hrnd(x[31], {2'd0, x[30:23]} - 10'sd112, {1'b1, x[22:13]},
					x[12], |x[11:0], r);
		end
	endfunction

	/* A packed fp16 operation o (atg_su_pk's half) on halves a, b, c: the
	 * FPU operation and its fp32 operands {op, a, b, c}. */
	function [100:0] pkin;
		input [3:0] o;
		input [15:0] a, b, c;
		reg [4:0] fo;
		reg [31:0] fa, fb;
		begin
			fa = atg_su_h2f(a);
			fb = atg_su_h2f(b);
			case (o)
			ATG_PK_FADD2[3:0]: fo = ATG_FPU_FADD[4:0];
			ATG_PK_FSUB2[3:0]: fo = ATG_FPU_FSUB[4:0];
			ATG_PK_FMUL2[3:0]: fo = ATG_FPU_FMUL[4:0];
			ATG_PK_FFMA2[3:0]: fo = ATG_FPU_FMADD[4:0];
			ATG_PK_FMIN2[3:0]: fo = ATG_FPU_FMIN[4:0];
			ATG_PK_FMAX2[3:0]: fo = ATG_FPU_FMAX[4:0];
			ATG_PK_FCMPLT2[3:0]: fo = ATG_FPU_FLT[4:0];
			ATG_PK_FCMPGE2[3:0]: begin	/* the swapped le */
				fo = ATG_FPU_FLE[4:0];
				fa = atg_su_h2f(b);
				fb = atg_su_h2f(a);
			end
			ATG_PK_FCMPEQ2[3:0]: fo = ATG_FPU_FEQ[4:0];
			default: fo = ATG_FPU_FNE[4:0];
			endcase
			pkin = {fo, fa, fb, atg_su_h2f(c)};
		end
	endfunction

	/* Its fp16 result from fpu()'s z (computed with rm 5, or 6 for RDN). */
	function [15:0] pkout;
		input [3:0] o;
		input [31:0] z;
		input [2:0] r;
		input st;
		reg [15:0] h;
		begin
			h = o >= ATG_PK_FCMPLT2[3:0] ? z[15:0] : f2hr(z, r);
			pkout = st && o < ATG_PK_FCMPLT2[3:0] ? atg_su_hsat(h) : h;
		end
	endfunction

	/* The lanes: this unit's operation, a packed group's low halves (the
	 * high ones from rs1 for hsel 10), or in the busy cycle the kept high
	 * halves (those of rs1 for hsel 01); each lane's one multiplier. */
	wire [DW-1:0] y;
	genvar gl;
	generate
	for (gl = 0; gl < NPHYS; gl = gl + 1) begin : g_lane
		reg [4:0] lo;
		reg [31:0] la, lb, lc;
		reg [2:0] lr;
		reg lst;
		reg [100:0] pi;
		reg [15:0] bsw;	/* the low half of rs2, its halves swapped for hsel 11 */
		wire [65:0] mo = mulops(lo, la, lb);
		wire [65:0] pr;
		am_mul #(.AW(33), .BW(33), .SIGNED(1)) mul (
			.clk(clk), .en(1'b1), .a(mo[32:0]), .b(mo[65:33]), .p(pr)
		);
		wire [31:0] res = fpu(lo, la, lb, lc, lr, lst, pr[63:0]);
		wire unused_pr = &{1'b0, pr[65:64]};
		always @(*) begin
			bsw = hsel == 2'd3 ? x_b[gl*32 + 16 +: 16] : x_b[gl*32 +: 16];
			if (SH && busy)
				pi = pkin(k_op, k_a[gl*16 +: 16], k_b[gl*16 +: 16], k_c[gl*16 +: 16]);
			else
				pi = pkin(pop, x_a[gl*32 +: 16], bsw, x_c[gl*32 +: 16]);
			if (SH && (busy || mine_pk)) begin
				{lo, la, lb, lc} = pi;
				lr = (busy ? k_rm : rm) == 3'd2 ? 3'd6 : 3'd5;
				lst = 1'b0;
			end else begin
				lo = op;
				la = x_a[gl*32 +: 32];
				lb = x_b[gl*32 +: 32];
				lc = x_c[gl*32 +: 32];
				lr = rm;
				lst = sat;
			end
		end
		assign y[gl*32 +: 32] = SH && busy ? {16'd0, k_hs == 2'd1 ? k_a[gl*16 +: 16] :
				pkout(k_op, res, k_rm, k_sat)} :
			mine_pk ? {16'd0, hsel == 2'd2 ? x_a[gl*32 +: 16] : pkout(pop, res, rm, sat)} :
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
