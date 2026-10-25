/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fpu_op: one lane's operation of atg_su_fpu (o: ATG_FPU_*), given
 * the product pr of its multiplier (the significands of the fused
 * datapath's x * y, or the integer operands; atg_su_fpu's mulops).  The
 * operations share one rounding to an integer (atg_su_rint: fround,
 * fract, fcvt.w*), one integer to float (atg_su_i2f: fround, fract,
 * fcvt.s.w*) and the fused datapath (atg_su_ffma_p: fadd, fsub, fmul,
 * the fmadd family, fract = x - floor(x) with RNE).  ist: the sat bit
 * (float results clamped to [0, 1]).  The former function fpu of
 * atg_su_fpu (tools/gsi1fp.py).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_fpu_op (
	input wire [4:0] o,
	input wire [31:0] ia,
	input wire [31:0] ib,
	input wire [31:0] ic,
	input wire [2:0] irm,
	input wire ist,
	input wire [63:0] pr,	/* the product's low 64 bits */
	output wire [31:0] res
);
`include "atg_su_uop.vh"
`include "atg_su_fp.vh"

	/* Rounding to an integer and integer to float, shared. */
	wire [31:0] xf = atg_su_flush(ia);
	wire [24:0] n;
	atg_su_rint u_rint (.x(xf), .rm(o == ATG_FPU_FRACT[4:0] ? 3'd2 : irm), .n(n));
	wire [31:0] nega;
	wire carry_unused;
	am_sub #(.W(32)) u_neg (.a(32'd0), .b(ia), .bi(1'b0), .d(nega), .bo(carry_unused));
	wire cvsw = o == ATG_FPU_FCVTSW[4:0];
	wire cvswu = o == ATG_FPU_FCVTSWU[4:0];
	wire [31:0] iv;
	atg_su_i2f u_i2f (.s(cvsw ? ia[31] : cvswu ? 1'b0 : xf[31]),
		.n(cvsw ? (ia[31] ? nega : ia) : cvswu ? ia : {7'd0, n}),
		.rm(cvsw || cvswu ? irm : 3'd0), .r(iv));
	/* fround */
	wire [31:0] fl = xf[30:23] == 8'hFF && xf[22:0] != 0 ? 32'h7FC00000 :
		xf[30:23] >= 8'd150 || xf[30:23] == 8'd0 ? xf : iv;

	/* The fused datapath's operands. */
	reg [31:0] fx, fy, fz;
	reg [2:0] rr;
	reg noc;
	always @(*) begin
		fx = ia;
		fy = 32'h3F800000;
		fz = ib;
		noc = 1'b0;
		rr = irm;
		case (o)
		ATG_FPU_FSUB[4:0]: fz = {!ib[31], ib[30:0]};
		ATG_FPU_FMUL[4:0]: begin
			fy = ib;
			noc = 1'b1;
		end
		ATG_FPU_FMADD[4:0]: begin
			fy = ib;
			fz = ic;
		end
		ATG_FPU_FMSUB[4:0]: begin
			fy = ib;
			fz = {!ic[31], ic[30:0]};
		end
		ATG_FPU_FNMSUB[4:0]: begin
			fx = {!ia[31], ia[30:0]};
			fy = ib;
			fz = ic;
		end
		ATG_FPU_FNMADD[4:0]: begin
			fx = {!ia[31], ia[30:0]};
			fy = ib;
			fz = {!ic[31], ic[30:0]};
		end
		ATG_FPU_FRACT[4:0]: begin
			fz = {!fl[31], fl[30:0]};
			rr = 3'd0;
		end
		default: ;
		endcase
	end
	wire [31:0] fr, ri;
	atg_su_ffma_p u_fma (.a0(fx), .b0(fy), .c0(fz), .rm(rr), .noc(noc), .p(pr[47:0]), .r(fr));
	atg_su_f2i u_f2i (.x(xf), .n(n), .uns(o == ATG_FPU_FCVTWUS[4:0]), .r(ri));

	wire fma = o <= ATG_FPU_FNMADD[4:0] || o == ATG_FPU_FRACT[4:0];
	reg [31:0] rs;
	reg flt;
	always @(*) begin
		flt = 1'b1;
		rs = 32'd0;
		if (fma)
			rs = fr;
		else begin
			case (o)
			ATG_FPU_FSGNJ[4:0]: rs = {ib[31], ia[30:0]};
			ATG_FPU_FMIN[4:0]: rs = atg_su_fminmax(ia, ib, 1'b0);
			ATG_FPU_FMAX[4:0]: rs = atg_su_fminmax(ia, ib, 1'b1);
			ATG_FPU_FCVTWS[4:0], ATG_FPU_FCVTWUS[4:0]: rs = ri;
			ATG_FPU_FCVTSW[4:0], ATG_FPU_FCVTSWU[4:0]: rs = iv;
			ATG_FPU_FEQ[4:0]: rs = {32{atg_su_fcmp(ia, ib, 2'd0)}};
			ATG_FPU_FLT[4:0]: rs = {32{atg_su_fcmp(ia, ib, 2'd1)}};
			ATG_FPU_FLE[4:0]: rs = {32{atg_su_fcmp(ia, ib, 2'd2)}};
			ATG_FPU_FNE[4:0]: rs = {32{atg_su_fcmp(ia, ib, 2'd3)}};
			ATG_FPU_FROUND[4:0]: rs = fl;
			ATG_FPU_MUL[4:0]: rs = pr[31:0];
			ATG_FPU_MULH[4:0], ATG_FPU_MULHSU[4:0], ATG_FPU_MULHU[4:0]: rs = pr[63:32];
			default: ;
			endcase
		end
		case (o)
		ATG_FPU_FCVTWS[4:0], ATG_FPU_FCVTWUS[4:0], ATG_FPU_FEQ[4:0], ATG_FPU_FLT[4:0],
		ATG_FPU_FLE[4:0], ATG_FPU_FNE[4:0], ATG_FPU_MUL[4:0], ATG_FPU_MULH[4:0],
		ATG_FPU_MULHSU[4:0], ATG_FPU_MULHU[4:0]: flt = 1'b0;
		default: ;
		endcase
	end
	assign res = ist && flt ? atg_su_sat(rs) : rs;

	wire unused_ok = &{1'b0, carry_unused};
endmodule

`default_nettype wire
