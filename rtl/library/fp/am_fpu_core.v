/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fpu_core: unified single-lane floating-point / integer FPU core.
 * Computes FMA (a * b + c), FADD, FSUB, FMUL, FMSUB, FNMSUB, FNMADD,
 * FSGNJ, FMIN, FMAX, FROUND, FRACT, FCMP (FEQ, FLT, FLE, FNE),
 * conversions (FCVTWS, FCVTWUS, FCVTSW, FCVTSWU), and RISC-V M integer
 * multiplies (MUL, MULH, MULHSU, MULHU).
 *
 * Reuses one 33x33 signed multiplier (4 DSP48E1 slices under SYNTH_KINTEX7)
 * via front-end operand multiplexing, eliminating duplicate DSP slice
 * allocation across disparate execution pipelines.
 *
 * Supports LAT = 0 (combinational) and LAT = 4 (balanced 4-stage pipeline).
 * See spec/library/fp/am_fpu_core.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_fpu_core #(
	parameter LAT = 0	/* latency: 0 = combinational, 4 = 4-stage pipelined */
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [4:0] op,
	input wire [2:0] rm,
	input wire sat,
	input wire [31:0] a,
	input wire [31:0] b,
	input wire [31:0] c,
	output wire [31:0] res
);
	/* Operation codes (matching ATG_FPU_* 1:1) */
	localparam [4:0] OP_FADD    = 5'd0;
	localparam [4:0] OP_FSUB    = 5'd1;
	localparam [4:0] OP_FMUL    = 5'd2;
	localparam [4:0] OP_FMADD   = 5'd3;
	localparam [4:0] OP_FMSUB   = 5'd4;
	localparam [4:0] OP_FNMSUB  = 5'd5;
	localparam [4:0] OP_FNMADD  = 5'd6;
	localparam [4:0] OP_FSGNJ   = 5'd7;
	localparam [4:0] OP_FMIN    = 5'd8;
	localparam [4:0] OP_FMAX    = 5'd9;
	localparam [4:0] OP_FCVTWS  = 5'd10;
	localparam [4:0] OP_FCVTWUS = 5'd11;
	localparam [4:0] OP_FCVTSW  = 5'd12;
	localparam [4:0] OP_FCVTSWU = 5'd13;
	localparam [4:0] OP_FEQ     = 5'd14;
	localparam [4:0] OP_FLT     = 5'd15;
	localparam [4:0] OP_FLE     = 5'd16;
	localparam [4:0] OP_FNE     = 5'd17;
	localparam [4:0] OP_FROUND  = 5'd18;
	localparam [4:0] OP_FRACT   = 5'd19;
	localparam [4:0] OP_MUL     = 5'd20;
	localparam [4:0] OP_MULH    = 5'd21;
	localparam [4:0] OP_MULHSU  = 5'd22;
	localparam [4:0] OP_MULHU   = 5'd23;

	/* Denormals flushed to zero with preserved sign */
	function [31:0] f_flush;
		input [31:0] x;
		f_flush = (x[30:23] == 8'd0) ? {x[31], 31'd0} : x;
	endfunction

	/* Extract 24-bit significands for FP multiplication */
	function [47:0] f_sig;
		input [30:0] a_in, b_in;
		f_sig = {a_in[30:23] != 8'd0 ? {1'b1, a_in[22:0]} : 24'd0,
			b_in[30:23] != 8'd0 ? {1'b1, b_in[22:0]} : 24'd0};
	endfunction

	/* fmin / fmax: NaN operand gives the other, -0 < +0 */
	function [31:0] f_minmax;
		input [31:0] a0, b0;
		input is_max;
		reg [31:0] af, bf;
		reg na, nb, lt;
		begin
			af = f_flush(a0);
			bf = f_flush(b0);
			na = (af[30:23] == 8'hFF) && (af[22:0] != 23'd0);
			nb = (bf[30:23] == 8'hFF) && (bf[22:0] != 23'd0);
			lt = (af[31] && !bf[31]) || (!af[31] && !bf[31] && af[30:0] < bf[30:0]) ||
				(af[31] && bf[31] && af[30:0] > bf[30:0]);
			if (na && nb)
				f_minmax = 32'h7FC00000;
			else if (na)
				f_minmax = bf;
			else if (nb)
				f_minmax = af;
			else if (is_max)
				f_minmax = lt ? bf : af;
			else begin
				f_minmax = ((bf[31] && !af[31]) || (!bf[31] && !af[31] && bf[30:0] < af[30:0]) ||
					(bf[31] && af[31] && bf[30:0] > af[30:0])) ? bf : af;
			end
		end
	endfunction

	/* Floating point comparisons: 0: EQ, 1: LT, 2: LE, 3: NE */
	function f_cmp;
		input [31:0] a0, b0;
		input [1:0] c_op;
		reg [31:0] af, bf;
		reg un, eq, lt;
		begin
			af = f_flush(a0);
			bf = f_flush(b0);
			un = ((af[30:23] == 8'hFF) && (af[22:0] != 23'd0)) ||
			     ((bf[30:23] == 8'hFF) && (bf[22:0] != 23'd0));
			eq = (af == bf) || (af[30:0] == 31'd0 && bf[30:0] == 31'd0);
			lt = !eq && ((af[31] && !bf[31]) || (!af[31] && !bf[31] && af[30:0] < bf[30:0]) ||
				(af[31] && bf[31] && af[30:0] > bf[30:0]));
			case (c_op)
			2'd0: f_cmp = !un && eq;
			2'd1: f_cmp = !un && lt;
			2'd2: f_cmp = !un && (lt || eq);
			default: f_cmp = un || !eq;
			endcase
		end
	endfunction

	/* Saturate float to [0, 1] */
	function [31:0] f_sat;
		input [31:0] x;
		if (((x[30:23] == 8'hFF) && (x[22:0] != 23'd0)) || x[31])
			f_sat = 32'd0;
		else if (x[30:0] > 31'h3F800000)
			f_sat = 32'h3F800000;
		else
			f_sat = x;
	endfunction

	/* 33x33 Multiplier operand multiplexing */
	function [65:0] mulops;
		input [4:0] o;
		input [31:0] a_in, b_in;
		reg [47:0] sg;
		begin
			case (o)
			OP_FMUL, OP_FMADD, OP_FMSUB, OP_FNMSUB, OP_FNMADD:
				sg = f_sig(a_in[30:0], b_in[30:0]);
			default:
				sg = f_sig(a_in[30:0], 31'h3F800000);
			endcase
			if (o <= OP_FNMADD || o == OP_FRACT)
				mulops = {9'd0, sg[23:0], 9'd0, sg[47:24]};
			else
				mulops = {(o == OP_MUL || o == OP_MULH) && b_in[31], b_in,
					o != OP_MULHU && a_in[31], a_in};
		end
	endfunction

	generate
	if (LAT == 0) begin : g_lat0
		/* 33x33 signed multiplier: exactly 4 DSP48E1 slices */
		wire [65:0] mo = mulops(op, a, b);
		wire [65:0] pr;
		am_mul #(.AW(33), .BW(33), .SIGNED(1), .LAT(0)) u_mul (
			.clk(clk),
			.en(en),
			.a(mo[32:0]),
			.b(mo[65:33]),
			.p(pr)
		);

		/* Integer rounding and integer-to-float conversions */
		wire [31:0] xf = f_flush(a);
		wire [24:0] n;
		am_fp_rint #(.LAT(0)) u_rint (
			.x(xf),
			.rm(op == OP_FRACT ? 3'd2 : rm),
			.n(n)
		);

		wire [31:0] nega;
		wire carry_unused;
		am_sub #(.W(32)) u_neg (
			.a(32'd0),
			.b(a),
			.bi(1'b0),
			.d(nega),
			.bo(carry_unused)
		);

		wire cvsw = (op == OP_FCVTSW);
		wire cvswu = (op == OP_FCVTSWU);
		wire [31:0] iv;
		am_fp_i2f #(.LAT(0)) u_i2f (
			.s(cvsw ? a[31] : cvswu ? 1'b0 : xf[31]),
			.n(cvsw ? (a[31] ? nega : a) : cvswu ? a : {7'd0, n}),
			.rm((cvsw || cvswu) ? rm : 3'd0),
			.r(iv)
		);

		/* fround */
		wire [31:0] fl = (xf[30:23] == 8'hFF && xf[22:0] != 23'd0) ? 32'h7FC00000 :
			(xf[30:23] >= 8'd150 || xf[30:23] == 8'd0) ? xf : iv;

		/* Fused datapath operands */
		reg [31:0] fx, fy, fz;
		reg [2:0] rr;
		reg noc;
		always @(*) begin
			fx = a;
			fy = 32'h3F800000;
			fz = b;
			noc = 1'b0;
			rr = rm;
			case (op)
			OP_FADD:   ;
			OP_FSUB:   fz = {!b[31], b[30:0]};
			OP_FMUL:   begin
				fy = b;
				noc = 1'b1;
			end
			OP_FMADD:  begin
				fy = b;
				fz = c;
			end
			OP_FMSUB:  begin
				fy = b;
				fz = {!c[31], c[30:0]};
			end
			OP_FNMSUB: begin
				fx = {!a[31], a[30:0]};
				fy = b;
				fz = c;
			end
			OP_FNMADD: begin
				fx = {!a[31], a[30:0]};
				fy = b;
				fz = {!c[31], c[30:0]};
			end
			OP_FRACT:  begin
				fz = {!fl[31], fl[30:0]};
				rr = 3'd0;
			end
			default: ;
			endcase
		end

		wire [31:0] fr, ri;
		am_fp_fma_p #(.LAT(0)) u_fma (
			.clk(1'b0),
			.rst_n(1'b1),
			.en(1'b1),
			.a0(fx),
			.b0(fy),
			.c0(fz),
			.rm(rr),
			.noc(noc),
			.p(pr[47:0]),
			.r(fr)
		);

		am_fp_f2i #(.LAT(0)) u_f2i (
			.clk(clk),
			.rst_n(rst_n),
			.en(en),
			.x(xf),
			.n(n),
			.uns(op == OP_FCVTWUS),
			.r(ri)
		);

		/* Operation result multiplexing */
		wire fma = (op <= OP_FNMADD) || (op == OP_FRACT);
		reg [31:0] rs;
		reg flt;
		always @(*) begin
			flt = 1'b1;
			rs = 32'd0;
			if (fma)
				rs = fr;
			else begin
				case (op)
				OP_FSGNJ:   rs = {b[31], a[30:0]};
				OP_FMIN:    rs = f_minmax(a, b, 1'b0);
				OP_FMAX:    rs = f_minmax(a, b, 1'b1);
				OP_FCVTWS, OP_FCVTWUS: rs = ri;
				OP_FCVTSW, OP_FCVTSWU: rs = iv;
				OP_FEQ:     rs = {32{f_cmp(a, b, 2'd0)}};
				OP_FLT:     rs = {32{f_cmp(a, b, 2'd1)}};
				OP_FLE:     rs = {32{f_cmp(a, b, 2'd2)}};
				OP_FNE:     rs = {32{f_cmp(a, b, 2'd3)}};
				OP_FROUND:  rs = fl;
				OP_MUL:     rs = pr[31:0];
				OP_MULH, OP_MULHSU, OP_MULHU: rs = pr[63:32];
				default: ;
				endcase
			end
			case (op)
			OP_FCVTWS, OP_FCVTWUS, OP_FEQ, OP_FLT, OP_FLE, OP_FNE,
			OP_MUL, OP_MULH, OP_MULHSU, OP_MULHU: flt = 1'b0;
			default: ;
			endcase
		end

		assign res = (sat && flt) ? f_sat(rs) : rs;
		wire unused_c0 = &{1'b0, carry_unused, pr[65:64], clk, rst_n};
	end else begin : g_lat4
		/*
		 * Real 4-Stage Physical Pipeline:
		 * Stage 1 (Cycle 1): Front-End Operands (Register 1)
		 * Stage 2 (Cycle 2): Multiplier AREG/BREG (Register 2)
		 * Stage 3 (Cycle 3): Multiplier MREG Cascade (Register 3)
		 * Stage 4 (Cycle 4): Multiplier PREG Output arrives, Post-Addition, Normalization, Rounding (Register 4)
		 */

		/* --- Stage 1: Front-end operands (Register 1) --- */
		wire [65:0] mo_s0 = mulops(op, a, b);

		reg [31:0] s1_a, s1_b, s1_c;
		(* keep = "true", equivalent_register_removal = "no" *) reg [4:0]  s1_op;
		(* keep = "true", equivalent_register_removal = "no" *) reg [2:0]  s1_rm;
		reg        s1_sat;
		(* keep = "true" *) reg [65:0] s1_mo;

		always @(posedge clk or negedge rst_n) begin
			if (!rst_n) begin
				s1_a   <= 32'd0;
				s1_b   <= 32'd0;
				s1_c   <= 32'd0;
				s1_op  <= 5'd0;
				s1_rm  <= 3'd0;
				s1_sat <= 1'b0;
				s1_mo  <= 66'd0;
			end else if (en) begin
				s1_a   <= a;
				s1_b   <= b;
				s1_c   <= c;
				s1_op  <= op;
				s1_rm  <= rm;
				s1_sat <= sat;
				s1_mo  <= mo_s0;
			end
		end

`ifdef SYNTH_ASIC
		/* 33x33 multiplier with LAT=3 (CSA split across Stage 1/2 + CPA Stage 3, 3 edges total) */
		wire [65:0] pr_mul;
		am_mul #(.AW(33), .BW(33), .SIGNED(1), .LAT(3)) u_mul4 (
			.clk(clk),
			.en(en),
			.a(s1_mo[32:0]),
			.b(s1_mo[65:33]),
			.p(pr_mul)
		);
		wire [65:0] pr_s4 = pr_mul;
`else
		/* 33x33 multiplier with LAT=2: 2 internal DSP48E1 pipeline registers */
		wire [65:0] pr_mul;
		am_mul #(.AW(33), .BW(33), .SIGNED(1), .LAT(2)) u_mul4 (
			.clk(clk),
			.en(en),
			.a(s1_mo[32:0]),
			.b(s1_mo[65:33]),
			.p(pr_mul)
		);

		/* Multiplier pipeline register (Stage 4) */
		reg [65:0] pr_s4;
		always @(posedge clk or negedge rst_n) begin
			if (!rst_n)
				pr_s4 <= 66'd0;
			else if (en)
				pr_s4 <= pr_mul;
		end
`endif

		/* Early rounding & negation in Stage 1 -> latched into Stage 2 */
		wire [31:0] s1_xf = f_flush(s1_a);
		wire [24:0] s1_n;
		am_fp_rint #(.LAT(0)) u_rint1 (
			.x(s1_xf),
			.rm(s1_op == OP_FRACT ? 3'd2 : s1_rm),
			.n(s1_n)
		);

		wire [31:0] s1_nega;
		wire carry_unused1_neg;
		am_sub #(.W(32)) u_neg1 (
			.a(32'd0),
			.b(s1_a),
			.bi(1'b0),
			.d(s1_nega),
			.bo(carry_unused1_neg)
		);

		wire cvsw1 = (s1_op == OP_FCVTSW);
		wire cvswu1 = (s1_op == OP_FCVTSWU);
		wire s1_is_i2f = cvsw1 || cvswu1;
		wire s1_s_val = cvsw1 ? s1_a[31] : cvswu1 ? 1'b0 : s1_xf[31];
		wire [31:0] s1_i2f_in = cvsw1 ? (s1_a[31] ? s1_nega : s1_a) : s1_a;
		wire s1_fl_nan = (s1_xf[30:23] == 8'hFF && s1_xf[22:0] != 23'd0);
		wire s1_fl_pass = (s1_xf[30:23] >= 8'd150 || s1_xf[30:23] == 8'd0);
		wire s1_fl_exp0 = (s1_xf[30:23] == 8'd0);
		wire s1_fl_direct = s1_fl_nan || s1_fl_pass;
		wire [11:0] s1_exp_a = {4'd0, s1_xf[30:23]};
		wire [11:0] s1_off150_raw, s1_off152_raw, s1_off101_raw;
		wire [11:0] s1_z150_raw,   s1_z152_raw,   s1_z101_raw;
		wire [5:0]  s1_fract_bo_unused;
		am_sub #(.W(12)) u_f1_o150 (.a(12'd150), .b(s1_exp_a), .bi(1'b0), .d(s1_off150_raw), .bo(s1_fract_bo_unused[0]));
		am_sub #(.W(12)) u_f1_o152 (.a(12'd152), .b(s1_exp_a), .bi(1'b0), .d(s1_off152_raw), .bo(s1_fract_bo_unused[1]));
		am_sub #(.W(12)) u_f1_o101 (.a(12'd101), .b(s1_exp_a), .bi(1'b0), .d(s1_off101_raw), .bo(s1_fract_bo_unused[2]));
		am_sub #(.W(12)) u_f1_z150 (.a(12'd23),  .b(s1_exp_a), .bi(1'b0), .d(s1_z150_raw),   .bo(s1_fract_bo_unused[3]));
		am_sub #(.W(12)) u_f1_z152 (.a(12'd25),  .b(s1_exp_a), .bi(1'b0), .d(s1_z152_raw),   .bo(s1_fract_bo_unused[4]));
		am_sub #(.W(12)) u_f1_z101 (.a(12'hFE6), .b(s1_exp_a), .bi(1'b0), .d(s1_z101_raw),   .bo(s1_fract_bo_unused[5]));
		wire [11:0] s1_f_off150 = s1_fl_direct ? 12'd23   : s1_off150_raw;
		wire [11:0] s1_f_off152 = s1_fl_direct ? 12'd25   : s1_off152_raw;
		wire [11:0] s1_f_off101 = s1_fl_direct ? 12'hFE6  : s1_off101_raw;
		wire [11:0] s1_f_z150   = s1_fl_direct ? 12'd23   : s1_z150_raw;
		wire [11:0] s1_f_z152   = s1_fl_direct ? 12'd25   : s1_z152_raw;
		wire [11:0] s1_f_z101   = s1_fl_direct ? 12'hFE6  : s1_z101_raw;

		/* Precompute FMA exponent sums in Stage 1 from s1_op, s1_a, s1_b, s1_c */
		wire [7:0] s1_ey = (s1_op == OP_FMUL || s1_op == OP_FMADD || s1_op == OP_FMSUB ||
		                    s1_op == OP_FNMSUB || s1_op == OP_FNMADD) ? s1_b[30:23] : 8'd127;
		wire [7:0] s1_ez = (s1_op == OP_FMUL) ? 8'd0 :
		                   (s1_op == OP_FMADD || s1_op == OP_FMSUB ||
		                    s1_op == OP_FNMSUB || s1_op == OP_FNMADD) ? s1_c[30:23] : s1_b[30:23];
		wire [11:0] s1_fma_ab, s1_fma_c150, s1_fma_c152, s1_fma_c101;
		wire [3:0]  s1_fma_carry_unused;
		am_add #(.W(12)) u_fma1_ab   (.a({4'd0, s1_a[30:23]}), .b({4'd0, s1_ey}), .ci(1'b0), .s(s1_fma_ab),   .co(s1_fma_carry_unused[0]));
		am_add #(.W(12)) u_fma1_c150 (.a({4'd0, s1_ez}),      .b(12'd150),        .ci(1'b0), .s(s1_fma_c150), .co(s1_fma_carry_unused[1]));
		am_add #(.W(12)) u_fma1_c152 (.a({4'd0, s1_ez}),      .b(12'd152),        .ci(1'b0), .s(s1_fma_c152), .co(s1_fma_carry_unused[2]));
		am_add #(.W(12)) u_fma1_c101 (.a({4'd0, s1_ez}),      .b(12'd101),        .ci(1'b0), .s(s1_fma_c101), .co(s1_fma_carry_unused[3]));

		/* --- Stage 2: Pipeline match & LOD/Shift (Register 2) --- */
		reg [31:0] s2_a, s2_b, s2_c;
		(* keep = "true", equivalent_register_removal = "no" *) reg [4:0]  s2_op;
		(* keep = "true", equivalent_register_removal = "no" *) reg [2:0]  s2_rm;
		reg        s2_sat;
		reg [24:0] s2_n;
		reg [31:0] s2_i2f_in;
		reg        s2_is_i2f;
		reg        s2_s_val;
		reg        s2_fl_nan_r;
		reg        s2_fl_pass_r;
		reg        s2_fl_exp0_r;
		reg [11:0] s2_f_off150, s2_f_off152, s2_f_off101;
		reg [11:0] s2_f_z150,   s2_f_z152,   s2_f_z101;
		reg [11:0] s2_fma_ab,   s2_fma_c150, s2_fma_c152, s2_fma_c101;

		always @(posedge clk or negedge rst_n) begin
			if (!rst_n) begin
				s2_a         <= 32'd0;
				s2_b         <= 32'd0;
				s2_c         <= 32'd0;
				s2_op        <= 5'd0;
				s2_rm        <= 3'd0;
				s2_sat       <= 1'b0;
				s2_n         <= 25'd0;
				s2_i2f_in    <= 32'd0;
				s2_is_i2f    <= 1'b0;
				s2_s_val     <= 1'b0;
				s2_fl_nan_r  <= 1'b0;
				s2_fl_pass_r <= 1'b0;
				s2_fl_exp0_r <= 1'b0;
				s2_f_off150  <= 12'd0;
				s2_f_off152  <= 12'd0;
				s2_f_off101  <= 12'd0;
				s2_f_z150    <= 12'd0;
				s2_f_z152    <= 12'd0;
				s2_f_z101    <= 12'd0;
				s2_fma_ab    <= 12'd0;
				s2_fma_c150  <= 12'd0;
				s2_fma_c152  <= 12'd0;
				s2_fma_c101  <= 12'd0;
			end else if (en) begin
				s2_a         <= s1_a;
				s2_b         <= s1_b;
				s2_c         <= s1_c;
				s2_op        <= s1_op;
				s2_rm        <= s1_rm;
				s2_sat       <= s1_sat;
				s2_n         <= s1_n;
				s2_i2f_in    <= s1_i2f_in;
				s2_is_i2f    <= s1_is_i2f;
				s2_s_val     <= s1_s_val;
				s2_fl_nan_r  <= s1_fl_nan;
				s2_fl_pass_r <= s1_fl_pass;
				s2_fl_exp0_r <= s1_fl_exp0;
				s2_f_off150  <= s1_f_off150;
				s2_f_off152  <= s1_f_off152;
				s2_f_off101  <= s1_f_off101;
				s2_f_z150    <= s1_f_z150;
				s2_f_z152    <= s1_f_z152;
				s2_f_z101    <= s1_f_z101;
				s2_fma_ab    <= s1_fma_ab;
				s2_fma_c150  <= s1_fma_c150;
				s2_fma_c152  <= s1_fma_c152;
				s2_fma_c101  <= s1_fma_c101;
			end
		end

		/* Stage 2: parallel-prefix leading-1 LOD + 1-hot factored shift (replaces am_msb + am_shift) */
		wire [31:0] s2_xf = f_flush(s2_a);
		wire s2_s = s2_s_val;

		/* i2f 32-bit parallel prefix OR (i2f_pre[k] = |s2_i2f_in[31:k]) */
		wire [31:0] i2f_p1 = s2_i2f_in | {1'b0,  s2_i2f_in[31:1]};
		wire [31:0] i2f_p2 = i2f_p1    | {2'd0,  i2f_p1[31:2]};
		wire [31:0] i2f_p3 = i2f_p2    | {4'd0,  i2f_p2[31:4]};
		wire [31:0] i2f_p4 = i2f_p3    | {8'd0,  i2f_p3[31:8]};
		wire [31:0] i2f_p5 = i2f_p4    | {16'd0, i2f_p4[31:16]};
		wire [31:0] l1h_i2f = {i2f_p5[31], i2f_p5[30:0] & ~i2f_p5[31:1]};
		wire s2_i2f_nz = i2f_p5[0];
		wire [4:0] s2_i2f_msb = {
			|l1h_i2f[31:16],
			(|l1h_i2f[15:8])  | (|l1h_i2f[31:24]),
			(|l1h_i2f[7:4])   | (|l1h_i2f[15:12]) | (|l1h_i2f[23:20]) | (|l1h_i2f[31:28]),
			l1h_i2f[2]  | l1h_i2f[3]  | l1h_i2f[6]  | l1h_i2f[7]  |
			l1h_i2f[10] | l1h_i2f[11] | l1h_i2f[14] | l1h_i2f[15] |
			l1h_i2f[18] | l1h_i2f[19] | l1h_i2f[22] | l1h_i2f[23] |
			l1h_i2f[26] | l1h_i2f[27] | l1h_i2f[30] | l1h_i2f[31],
			l1h_i2f[1]  | l1h_i2f[3]  | l1h_i2f[5]  | l1h_i2f[7]  |
			l1h_i2f[9]  | l1h_i2f[11] | l1h_i2f[13] | l1h_i2f[15] |
			l1h_i2f[17] | l1h_i2f[19] | l1h_i2f[21] | l1h_i2f[23] |
			l1h_i2f[25] | l1h_i2f[27] | l1h_i2f[29] | l1h_i2f[31]
		};
		/* Factored left-shift amt = 31 - pos: mod-4 and div-4 1-hot */
		wire [3:0] i2f_sh_lo = {
			l1h_i2f[28] | l1h_i2f[24] | l1h_i2f[20] | l1h_i2f[16] | l1h_i2f[12] | l1h_i2f[8]  | l1h_i2f[4] | l1h_i2f[0],
			l1h_i2f[29] | l1h_i2f[25] | l1h_i2f[21] | l1h_i2f[17] | l1h_i2f[13] | l1h_i2f[9]  | l1h_i2f[5] | l1h_i2f[1],
			l1h_i2f[30] | l1h_i2f[26] | l1h_i2f[22] | l1h_i2f[18] | l1h_i2f[14] | l1h_i2f[10] | l1h_i2f[6] | l1h_i2f[2],
			l1h_i2f[31] | l1h_i2f[27] | l1h_i2f[23] | l1h_i2f[19] | l1h_i2f[15] | l1h_i2f[11] | l1h_i2f[7] | l1h_i2f[3]
		};
		wire [7:0] i2f_sh_hi = {
			|l1h_i2f[3:0],   |l1h_i2f[7:4],   |l1h_i2f[11:8],  |l1h_i2f[15:12],
			|l1h_i2f[19:16], |l1h_i2f[23:20], |l1h_i2f[27:24], |l1h_i2f[31:28]
		};
		wire [34:0] i2f_in_p = {s2_i2f_in, 3'd0};
		wire [31:0] i2f_sh1, s2_w_i2f;
		wire [59:0] i2f_sh1_p = {i2f_sh1, 28'd0};
		genvar gi2f;
		for (gi2f = 0; gi2f < 32; gi2f = gi2f + 1) begin : g_i2f_sh1
			assign i2f_sh1[gi2f] =
				(i2f_sh_lo[0] & i2f_in_p[gi2f + 3]) | (i2f_sh_lo[1] & i2f_in_p[gi2f + 2]) |
				(i2f_sh_lo[2] & i2f_in_p[gi2f + 1]) | (i2f_sh_lo[3] & i2f_in_p[gi2f]);
		end
		for (gi2f = 0; gi2f < 32; gi2f = gi2f + 1) begin : g_i2f_sh2
			assign s2_w_i2f[gi2f] =
				(i2f_sh_hi[0] & i2f_sh1_p[gi2f + 28]) | (i2f_sh_hi[1] & i2f_sh1_p[gi2f + 24]) |
				(i2f_sh_hi[2] & i2f_sh1_p[gi2f + 20]) | (i2f_sh_hi[3] & i2f_sh1_p[gi2f + 16]) |
				(i2f_sh_hi[4] & i2f_sh1_p[gi2f + 12]) | (i2f_sh_hi[5] & i2f_sh1_p[gi2f + 8])  |
				(i2f_sh_hi[6] & i2f_sh1_p[gi2f + 4])  | (i2f_sh_hi[7] & i2f_sh1_p[gi2f]);
		end

		/* rint 25-bit 3-chunk parallel LOD (max 3 OR levels per chunk) */
		wire [7:0]  rn0 = s2_n[7:0], rn1 = s2_n[15:8];
		wire [8:0]  rn2 = s2_n[24:16];
		wire [7:0]  rn0_p1 = rn0 | {1'b0, rn0[7:1]};
		wire [7:0]  rn0_p2 = rn0_p1 | {2'd0, rn0_p1[7:2]};
		wire [7:0]  rn0_p3 = rn0_p2 | {4'd0, rn0_p2[7:4]};
		wire [7:0]  rn0_l1h = {rn0_p3[7], rn0_p3[6:0] & ~rn0_p3[7:1]};
		wire [7:0]  rn1_p1 = rn1 | {1'b0, rn1[7:1]};
		wire [7:0]  rn1_p2 = rn1_p1 | {2'd0, rn1_p1[7:2]};
		wire [7:0]  rn1_p3 = rn1_p2 | {4'd0, rn1_p2[7:4]};
		wire [7:0]  rn1_l1h = {rn1_p3[7], rn1_p3[6:0] & ~rn1_p3[7:1]};
		wire [8:0]  rn2_p1 = rn2 | {1'b0, rn2[8:1]};
		wire [8:0]  rn2_p2 = rn2_p1 | {2'd0, rn2_p1[8:2]};
		wire [8:0]  rn2_p3 = rn2_p2 | {4'd0, rn2_p2[8:4]};
		wire [8:0]  rn2_p4 = rn2_p3 | {8'd0, rn2_p3[8]};
		wire [8:0]  rn2_l1h = {rn2_p4[8], rn2_p4[7:0] & ~rn2_p4[8:1]};
		wire rn0_nz = rn0_p3[0], rn1_nz = rn1_p3[0], rn2_nz = rn2_p4[0];
		wire [2:0] rn_blk_1h = {rn2_nz, rn1_nz & ~rn2_nz, rn0_nz & ~rn1_nz & ~rn2_nz};
		wire [24:0] l1h_rint = {
			{9{rn_blk_1h[2]}} & rn2_l1h,
			{8{rn_blk_1h[1]}} & rn1_l1h,
			{8{rn_blk_1h[0]}} & rn0_l1h
		};
		wire s2_rint_nz = rn2_nz | rn1_nz | rn0_nz;
		wire [4:0] s2_rint_msb = {
			rn_blk_1h[2],
			rn_blk_1h[1],
			rn_blk_1h[2] ? (|rn2_l1h[7:4]) : (rn_blk_1h[1] ? (|rn1_l1h[7:4]) : (|rn0_l1h[7:4])),
			(rn_blk_1h[2] & (|rn2_l1h[3:2] | |rn2_l1h[7:6])) |
			(rn_blk_1h[1] & (|rn1_l1h[3:2] | |rn1_l1h[7:6])) |
			(rn_blk_1h[0] & (|rn0_l1h[3:2] | |rn0_l1h[7:6])),
			(rn_blk_1h[2] & (rn2_l1h[1] | rn2_l1h[3] | rn2_l1h[5] | rn2_l1h[7])) |
			(rn_blk_1h[1] & (rn1_l1h[1] | rn1_l1h[3] | rn1_l1h[5] | rn1_l1h[7])) |
			(rn_blk_1h[0] & (rn0_l1h[1] | rn0_l1h[3] | rn0_l1h[5] | rn0_l1h[7]))
		};
		wire [3:0] rint_sh_lo = {
			l1h_rint[24] | l1h_rint[20] | l1h_rint[16] | l1h_rint[12] | l1h_rint[8]  | l1h_rint[4] | l1h_rint[0],
			l1h_rint[21] | l1h_rint[17] | l1h_rint[13] | l1h_rint[9]  | l1h_rint[5]  | l1h_rint[1],
			l1h_rint[22] | l1h_rint[18] | l1h_rint[14] | l1h_rint[10] | l1h_rint[6]  | l1h_rint[2],
			l1h_rint[23] | l1h_rint[19] | l1h_rint[15] | l1h_rint[11] | l1h_rint[7]  | l1h_rint[3]
		};
		wire [7:0] rint_sh_hi = {
			|l1h_rint[3:0],   |l1h_rint[7:4],   |l1h_rint[11:8],  |l1h_rint[15:12],
			|l1h_rint[19:16], |l1h_rint[23:20], l1h_rint[24],     1'b0
		};
		wire [34:0] rint_vec_p = {7'd0, s2_n, 3'd0};
		wire [31:0] rint_sh1, s2_w_rint;
		wire [59:0] rint_sh1_p = {rint_sh1, 28'd0};
		for (gi2f = 0; gi2f < 32; gi2f = gi2f + 1) begin : g_rint_sh1
			assign rint_sh1[gi2f] =
				(rint_sh_lo[0] & rint_vec_p[gi2f + 3]) | (rint_sh_lo[1] & rint_vec_p[gi2f + 2]) |
				(rint_sh_lo[2] & rint_vec_p[gi2f + 1]) | (rint_sh_lo[3] & rint_vec_p[gi2f]);
		end
		for (gi2f = 0; gi2f < 32; gi2f = gi2f + 1) begin : g_rint_sh2
			assign s2_w_rint[gi2f] =
				(rint_sh_hi[1] & rint_sh1_p[gi2f + 24]) | (rint_sh_hi[2] & rint_sh1_p[gi2f + 20]) |
				(rint_sh_hi[3] & rint_sh1_p[gi2f + 16]) | (rint_sh_hi[4] & rint_sh1_p[gi2f + 12]) |
				(rint_sh_hi[5] & rint_sh1_p[gi2f + 8])  | (rint_sh_hi[6] & rint_sh1_p[gi2f + 4])  |
				(rint_sh_hi[7] & rint_sh1_p[gi2f]);
		end

		wire [4:0] s2_msb = s2_is_i2f ? s2_i2f_msb : s2_rint_msb;
		wire s2_nz = s2_is_i2f ? s2_i2f_nz : s2_rint_nz;

		/* Exponent = 127 + msb: 5-bit dec instead of 12b ripple add cuts i2f_in_p -> s2_e by ~10 cmos3 */
		wire [4:0] s2_msb_m1, s2_rmsb_m1;
		wire carry_unused2_e, carry_unused2_er;
		am_sub #(.W(5)) u_e2_m1  (.a(s2_msb),      .b(5'd1), .bi(1'b0), .d(s2_msb_m1),  .bo(carry_unused2_e));
		am_sub #(.W(5)) u_e2_rm1 (.a(s2_rint_msb), .b(5'd1), .bi(1'b0), .d(s2_rmsb_m1), .bo(carry_unused2_er));
		wire [11:0] s2_e      = (|s2_msb)      ? {5'd1, 2'd0, s2_msb_m1}  : 12'd127;
		wire [7:0]  s2_e_rint = (|s2_rint_msb) ? {1'b1, 2'd0, s2_rmsb_m1} : 8'd127;
		wire [31:0] s2_w = s2_is_i2f ? s2_w_i2f : s2_w_rint;

		wire [31:0] s3_ri;
		am_fp_f2i #(.LAT(1)) u_f2i2 (
			.clk(clk),
			.rst_n(rst_n),
			.en(en),
			.x(s2_xf),
			.n(s2_n),
			.uns(s2_op == OP_FCVTWUS),
			.r(s3_ri)
		);

		wire s2_fl_nan = s2_fl_nan_r;
		wire s2_fl_pass = s2_fl_pass_r;

		/* Precompute FMA operands & exponents in Stage 2 -> latched into Stage 3 */
		reg [31:0] s2_fx, s2_fy, s2_fz;
		reg [2:0]  s2_rr;
		reg        s2_noc;
		always @(*) begin
			s2_fx = s2_a;
			s2_fy = 32'h3F800000;
			s2_fz = s2_b;
			s2_noc = 1'b0;
			s2_rr = s2_rm;
			case (s2_op)
			OP_FADD:   ;
			OP_FSUB:   s2_fz = {!s2_b[31], s2_b[30:0]};
			OP_FMUL:   begin
				s2_fy = s2_b;
				s2_noc = 1'b1;
			end
			OP_FMADD:  begin
				s2_fy = s2_b;
				s2_fz = s2_c;
			end
			OP_FMSUB:  begin
				s2_fy = s2_b;
				s2_fz = {!s2_c[31], s2_c[30:0]};
			end
			OP_FNMSUB: begin
				s2_fx = {!s2_a[31], s2_a[30:0]};
				s2_fy = s2_b;
				s2_fz = s2_c;
			end
			OP_FNMADD: begin
				s2_fx = {!s2_a[31], s2_a[30:0]};
				s2_fy = s2_b;
				s2_fz = {!s2_c[31], s2_c[30:0]};
			end
			OP_FRACT:  begin
				s2_fz = 32'd0;
				s2_rr = 3'd0;
			end
			default: ;
			endcase
		end

		wire [31:0] s2_fma_a = s2_fx[30:23] == 8'd0 ? {s2_fx[31], 31'd0} : s2_fx;
		wire [31:0] s2_fma_b = s2_fy[30:23] == 8'd0 ? {s2_fy[31], 31'd0} : s2_fy;
		wire [31:0] s2_fma_c = s2_fz[30:23] == 8'd0 ? {s2_fz[31], 31'd0} : s2_fz;

		wire [11:0] s2_fma_k, s2_fma_kadj, s2_fma_kp2;
		wire [2:0]  s2_fma_sub_carry_unused;
		am_sub #(.W(12)) u_fma2_k    (.a(s2_fma_c150), .b(s2_fma_ab), .bi(1'b0), .d(s2_fma_k),    .bo(s2_fma_sub_carry_unused[0]));
		am_sub #(.W(12)) u_fma2_kadj (.a(s2_fma_c101), .b(s2_fma_ab), .bi(1'b0), .d(s2_fma_kadj), .bo(s2_fma_sub_carry_unused[1]));
		am_sub #(.W(12)) u_fma2_kp2  (.a(s2_fma_c152), .b(s2_fma_ab), .bi(1'b0), .d(s2_fma_kp2),  .bo(s2_fma_sub_carry_unused[2]));

		/* Precompute Stage 2 f_minmax / f_cmp / fract C-operand to eliminate Stage 3 comparator & mux depth */
		wire [31:0] s2_fmin_w = f_minmax(s2_a, s2_b, 1'b0);
		wire [31:0] s2_fmax_w = f_minmax(s2_a, s2_b, 1'b1);
		wire [3:0]  s2_fcmp_w = {
			f_cmp(s2_a, s2_b, 2'd3),
			f_cmp(s2_a, s2_b, 2'd2),
			f_cmp(s2_a, s2_b, 2'd1),
			f_cmp(s2_a, s2_b, 2'd0)
		};
		wire [30:0] s2_fract_mag = s2_fl_nan_r ? 31'h7FC00000 :
		                           s2_fl_pass_r ? s2_xf[30:0] :
		                           s2_rint_nz ? {s2_e_rint, s2_w_rint[30:8]} : 31'd0;
		wire        s2_fract_sgn = s2_fl_nan_r ? 1'b1 : !s2_s;
		wire [31:0] s2_fract_c = {s2_fract_sgn, s2_fract_mag};
		wire [31:0] s2_fract_fma_c = s2_fl_exp0_r ? {s2_fract_sgn, 31'd0} : s2_fract_c;
		wire [23:0] s2_fract_mc = (s2_fl_nan_r || s2_fl_pass_r) ? {1'b1, s2_xf[22:0]} : {1'b1, s2_w_rint[30:8]};

		/* FRACT exponent and shift precomputation in Stage 2 (exp_a offset precomputed in Stage 1) */
		wire s2_fract_use_msb = !s2_fl_nan_r && !s2_fl_pass_r && s2_rint_nz;
		wire [4:0] s2_fract_msb_lo = s2_fract_use_msb ? s2_rint_msb : 5'd0;
		wire [11:0] s2_fract_b150  = s2_fract_use_msb ? s2_f_off150 : s2_f_z150;
		wire [11:0] s2_fract_b152  = s2_fract_use_msb ? s2_f_off152 : s2_f_z152;
		wire [11:0] s2_fract_b101  = s2_fract_use_msb ? s2_f_off101 : s2_f_z101;
		wire [6:0] s2_b150_hp1, s2_b101_hp1, s2_b152_hp1;
		wire [4:0] s2_fk_lo, s2_fka_lo, s2_fkp_lo;
		wire [2:0] s2_fk_co, s2_fhp_unused;
		am_add #(.W(7)) u_f2_hp0 (.a(s2_fract_b150[11:5]), .b(7'd1), .ci(1'b0), .s(s2_b150_hp1), .co(s2_fhp_unused[0]));
		am_add #(.W(7)) u_f2_hp1 (.a(s2_fract_b101[11:5]), .b(7'd1), .ci(1'b0), .s(s2_b101_hp1), .co(s2_fhp_unused[1]));
		am_add #(.W(7)) u_f2_hp2 (.a(s2_fract_b152[11:5]), .b(7'd1), .ci(1'b0), .s(s2_b152_hp1), .co(s2_fhp_unused[2]));
		am_add #(.W(5)) u_fract2_k    (.a(s2_fract_b150[4:0]), .b(s2_fract_msb_lo), .ci(1'b0), .s(s2_fk_lo),  .co(s2_fk_co[0]));
		am_add #(.W(5)) u_fract2_kadj (.a(s2_fract_b101[4:0]), .b(s2_fract_msb_lo), .ci(1'b0), .s(s2_fka_lo), .co(s2_fk_co[1]));
		am_add #(.W(5)) u_fract2_kp2  (.a(s2_fract_b152[4:0]), .b(s2_fract_msb_lo), .ci(1'b0), .s(s2_fkp_lo), .co(s2_fk_co[2]));
		wire [11:0] s2_fract_k    = {s2_fk_co[0] ? s2_b150_hp1 : s2_fract_b150[11:5], s2_fk_lo};
		wire [11:0] s2_fract_kadj = {s2_fk_co[1] ? s2_b101_hp1 : s2_fract_b101[11:5], s2_fka_lo};
		wire [11:0] s2_fract_kp2  = {s2_fk_co[2] ? s2_b152_hp1 : s2_fract_b152[11:5], s2_fkp_lo};
		wire [2:0]  s2_fract_carry_unused = s2_fhp_unused;

		wire s2_is_fract = (s2_op == OP_FRACT);
		wire [11:0] s2_sel_k    = s2_is_fract ? s2_fract_k    : s2_fma_k;
		wire [11:0] s2_sel_kadj = s2_is_fract ? s2_fract_kadj : s2_fma_kadj;
		wire [11:0] s2_sel_kp2  = s2_is_fract ? s2_fract_kp2  : s2_fma_kp2;
		wire s2_fma_zc   = s2_noc || (s2_fz[30:23] == 8'd0);
		wire s2_fract_zc = s2_fl_exp0_r || (!s2_fl_nan_r && !s2_fl_pass_r && !s2_rint_nz);
		wire s2_sel_zc   = s2_is_fract ? s2_fract_zc : s2_fma_zc;

		/* --- Stage 3: Rounding, operand & other formation (Register 3) --- */
		reg [31:0] s3_a, s3_b, s3_c;
		(* keep = "true", equivalent_register_removal = "no" *) reg [4:0]  s3_op;
		(* keep = "true", equivalent_register_removal = "no" *) reg [2:0]  s3_rm;
		reg        s3_sat;
		reg        s3_s;
		reg [11:0] s3_e;
		reg [31:0] s3_w;
		reg        s3_nz;
		reg        s3_fl_nan;
		reg        s3_fl_pass;
		reg [31:0] s3_xf_val;

		/* Precomputed FMA operands latched into Stage 3 */
		reg [31:0] s3_fx, s3_fy, s3_fz;
		reg [2:0]  s3_rr;
		reg        s3_noc;
		reg [31:0] s3_fma_a, s3_fma_b, s3_fma_c;
		reg [11:0] s3_fma_ab, s3_fma_c150, s3_fma_c152, s3_fma_c101;
		reg [11:0] s3_fma_k, s3_fma_kadj, s3_fma_kp2;
		reg        s3_zc;
		reg [23:0] s3_fma_mc;
		reg        s3_fma_sc;
		reg [31:0] s3_fmin, s3_fmax;
		reg [3:0]  s3_fcmp;

		always @(posedge clk or negedge rst_n) begin
			if (!rst_n) begin
				s3_a          <= 32'd0;
				s3_b          <= 32'd0;
				s3_c          <= 32'd0;
				s3_op         <= 5'd0;
				s3_rm         <= 3'd0;
				s3_sat        <= 1'b0;
				s3_s          <= 1'b0;
				s3_e          <= 12'd0;
				s3_w          <= 32'd0;
				s3_nz         <= 1'b0;
				s3_fl_nan     <= 1'b0;
				s3_fl_pass    <= 1'b0;
				s3_xf_val     <= 32'd0;
				s3_fx         <= 32'd0;
				s3_fy         <= 32'd0;
				s3_fz         <= 32'd0;
				s3_rr         <= 3'd0;
				s3_noc        <= 1'b0;
				s3_fma_a      <= 32'd0;
				s3_fma_b      <= 32'd0;
				s3_fma_c      <= 32'd0;
				s3_fma_ab     <= 12'd0;
				s3_fma_c150   <= 12'd0;
				s3_fma_c152   <= 12'd0;
				s3_fma_c101   <= 12'd0;
				s3_fma_k      <= 12'd0;
				s3_fma_kadj   <= 12'd0;
				s3_fma_kp2    <= 12'd0;
				s3_zc         <= 1'b0;
				s3_fma_mc     <= 24'd0;
				s3_fma_sc     <= 1'b0;
				s3_fmin       <= 32'd0;
				s3_fmax       <= 32'd0;
				s3_fcmp       <= 4'd0;
			end else if (en) begin
				s3_a          <= s2_a;
				s3_b          <= s2_b;
				s3_c          <= s2_c;
				s3_op         <= s2_op;
				s3_rm         <= s2_rm;
				s3_sat        <= s2_sat;
				s3_s          <= s2_s;
				s3_e          <= s2_e;
				s3_w          <= s2_w;
				s3_nz         <= s2_nz;
				s3_fl_nan     <= s2_fl_nan;
				s3_fl_pass    <= s2_fl_pass;
				s3_xf_val     <= s2_xf;
				s3_fx         <= s2_fx;
				s3_fy         <= s2_fy;
				s3_fz         <= s2_is_fract ? s2_fract_c : s2_fz;
				s3_rr         <= s2_rr;
				s3_noc        <= s2_noc;
				s3_fma_a      <= s2_fma_a;
				s3_fma_b      <= s2_fma_b;
				s3_fma_c      <= s2_is_fract ? s2_fract_fma_c : s2_fma_c;
				s3_fma_ab     <= s2_fma_ab;
				s3_fma_c150   <= s2_fma_c150;
				s3_fma_c152   <= s2_fma_c152;
				s3_fma_c101   <= s2_fma_c101;
				s3_fma_k      <= s2_sel_k;
				s3_fma_kadj   <= s2_sel_kadj;
				s3_fma_kp2    <= s2_sel_kp2;
				s3_zc         <= s2_sel_zc;
				s3_fma_mc     <= s2_is_fract ? s2_fract_mc : {1'b1, s2_fma_c[22:0]};
				s3_fma_sc     <= s2_is_fract ? !s2_s : s2_fma_c[31];
				s3_fmin       <= s2_fmin_w;
				s3_fmax       <= s2_fmax_w;
				s3_fcmp       <= s2_fcmp_w;
			end
		end

		/* Stage 3: Rounding for i2f */
		wire cvsw3 = (s3_op == OP_FCVTSW);
		wire cvswu3 = (s3_op == OP_FCVTSWU);
		wire s3_g = s3_w[7];
		wire s3_st = |s3_w[6:0];
		reg s3_up;
		always @(*) begin
			case ((cvsw3 || cvswu3) ? s3_rm : 3'd0)
			3'd1, 3'd5, 3'd6: s3_up = 1'b0;
			3'd2: s3_up = s3_s && (s3_g || s3_st);
			3'd3: s3_up = !s3_s && (s3_g || s3_st);
			3'd4: s3_up = s3_g;
			default: s3_up = s3_g && (s3_st || s3_w[8]);
			endcase
		end

		wire [24:0] mr3_in = {1'b0, s3_w[31:9], s3_w[8] | (((s3_rm == 3'd5 || s3_rm == 3'd6) && (cvsw3 || cvswu3)) && (s3_g || s3_st))};
		wire [8:0]  mr3_lo;
		wire [7:0]  mr3_m0, mr3_m1, mr3_h0, mr3_h1;
		wire        mr3_c0, mr3_cm0, mr3_cm1, mr3_ch0, mr3_ch1;
		am_add #(.W(9)) u_mr3_lo  (.a(mr3_in[8:0]),   .b(9'd0), .ci(s3_up), .s(mr3_lo), .co(mr3_c0));
		am_add #(.W(8)) u_mr3_m0  (.a(mr3_in[16:9]),  .b(8'd0), .ci(1'b0),  .s(mr3_m0), .co(mr3_cm0));
		am_add #(.W(8)) u_mr3_m1  (.a(mr3_in[16:9]),  .b(8'd0), .ci(1'b1),  .s(mr3_m1), .co(mr3_cm1));
		am_add #(.W(8)) u_mr3_h0  (.a(mr3_in[24:17]), .b(8'd0), .ci(1'b0),  .s(mr3_h0), .co(mr3_ch0));
		am_add #(.W(8)) u_mr3_h1  (.a(mr3_in[24:17]), .b(8'd0), .ci(1'b1),  .s(mr3_h1), .co(mr3_ch1));
		wire mr3_c1 = mr3_c0 ? mr3_cm1 : mr3_cm0;
		wire [24:0] s3_mr0 = {mr3_c1 ? mr3_h1 : mr3_h0, mr3_c0 ? mr3_m1 : mr3_m0, mr3_lo};
		wire carry_unused3_mr = &{1'b0, mr3_cm0, mr3_ch0, mr3_ch1};

		wire [11:0] s3_e_p1;
		wire carry_unused3_ep;
		am_add #(.W(12)) u_ep3 (.a(s3_e), .b(12'd1), .ci(1'b0), .s(s3_e_p1), .co(carry_unused3_ep));

		wire [7:0] s3_er = s3_mr0[24] ? s3_e_p1[7:0] : s3_e[7:0];
		wire [22:0] s3_mr = s3_mr0[24] ? s3_mr0[23:1] : s3_mr0[22:0];
		wire [31:0] s3_rnd = {s3_s, s3_er, s3_mr};

		wire [31:0] s3_iv = !s3_nz ? {s3_s, 31'd0} : s3_rnd;
		wire [31:0] s3_fl = s3_fl_nan ? 32'h7FC00000 : s3_fl_pass ? s3_xf_val : s3_iv;

		/* --- Stage 3: FMA Alignment Precomputation for LAT >= 6 --- */
		wire [31:0] fma3_a = s3_fma_a;
		wire [31:0] fma3_b = s3_fma_b;
		wire [31:0] fma3_c = s3_fma_c;
		wire fma3_sp = fma3_a[31] ^ fma3_b[31];
		wire fma3_sc = s3_fma_sc;
		wire fma3_rdn = s3_rr == 3'd2 || s3_rr == 3'd6;
		wire fma3_nan_a = fma3_a[30:23] == 8'hFF && fma3_a[22:0] != 0;
		wire fma3_nan_b = fma3_b[30:23] == 8'hFF && fma3_b[22:0] != 0;
		wire fma3_nan_c = !s3_noc && fma3_c[30:23] == 8'hFF && fma3_c[22:0] != 0;
		wire fma3_inf_a = fma3_a[30:23] == 8'hFF && fma3_a[22:0] == 0;
		wire fma3_inf_b = fma3_b[30:23] == 8'hFF && fma3_b[22:0] == 0;
		wire fma3_inf_c = !s3_noc && fma3_c[30:23] == 8'hFF && fma3_c[22:0] == 0;
		wire fma3_za = fma3_a[30:23] == 8'd0;
		wire fma3_zb = fma3_b[30:23] == 8'd0;
		wire fma3_zc = s3_zc;
		wire [23:0] fma3_mc = fma3_zc ? 24'd0 : s3_fma_mc;
		wire [0:0] fma3_carry_unused;

		wire [11:0] fma3_ab   = s3_fma_ab;
		wire [11:0] fma3_k    = s3_fma_k;
		wire [11:0] fma3_kadj = s3_fma_kadj;
		wire [11:0] fma3_kp2  = s3_fma_kp2;

		wire [4:0] fma3_rs = 5'd0;
		assign fma3_carry_unused = 1'b0;
		wire signed [11:0] fma3_ks = fma3_k;
		wire fma3_kbig = fma3_ks > 12'sd49;
		wire fma3_kleft = !fma3_kp2[11];
		wire fma3_kright = fma3_ks > -12'sd26;

		/* Factored 2-stage byte+bit shifter on 24-bit fma3_mc using two's complement
		 * identity: kp2 = 8 * signed'(kp2[6:3]) + kp2[2:0] (kp2 in [-23..+51]).
		 * Avoids 5-bit am_sub and 77-bit barrel shifter. */
		reg [30:0] fma3_pre;
		always @(*) begin
			case (fma3_kp2[2:0])
			3'd0: fma3_pre = {7'd0, fma3_mc};
			3'd1: fma3_pre = {6'd0, fma3_mc, 1'b0};
			3'd2: fma3_pre = {5'd0, fma3_mc, 2'b0};
			3'd3: fma3_pre = {4'd0, fma3_mc, 3'b0};
			3'd4: fma3_pre = {3'd0, fma3_mc, 4'b0};
			3'd5: fma3_pre = {2'd0, fma3_mc, 5'b0};
			3'd6: fma3_pre = {1'b0, fma3_mc, 6'b0};
			default: fma3_pre = {fma3_mc, 7'b0};
			endcase
		end
		/* Compute pre-shift sticky flags directly from fma3_mc prefix OR in parallel with fma3_pre */
		wire [23:0] mc_p1 = fma3_mc | {fma3_mc[22:0], 1'b0};
		wire [23:0] mc_p2 = mc_p1   | {mc_p1[21:0],   2'd0};
		wire [23:0] mc_p3 = mc_p2   | {mc_p2[19:0],   4'd0};
		wire [23:0] mc_p4 = mc_p3   | {mc_p3[15:0],   8'd0};
		wire [23:0] mc_pfx = mc_p4  | {mc_p4[7:0],   16'd0};
		wire [2:0] kp2_inv = ~fma3_kp2[2:0];
		wire fma3_st8  = mc_pfx[{2'b00, kp2_inv}];
		wire fma3_st16 = mc_pfx[{2'b01, kp2_inv}];
		wire fma3_st24 = mc_pfx[{2'b10, kp2_inv}];
		reg [76:0] fma3_cs_w;
		reg        fma3_cst_w;
		always @(*) begin
			fma3_cst_w = 1'b0;
			case (fma3_kp2[6:3])
			4'b1101: begin /* -3 -> >>24 */
				fma3_cs_w  = {70'd0, fma3_pre[30:24]};
				fma3_cst_w = fma3_st8 | fma3_st16 | fma3_st24;
			end
			4'b1110: begin /* -2 -> >>16 */
				fma3_cs_w  = {62'd0, fma3_pre[30:16]};
				fma3_cst_w = fma3_st8 | fma3_st16;
			end
			4'b1111: begin /* -1 -> >>8 */
				fma3_cs_w  = {54'd0, fma3_pre[30:8]};
				fma3_cst_w = fma3_st8;
			end
			4'b0000: fma3_cs_w = {46'd0, fma3_pre};
			4'b0001: fma3_cs_w = {38'd0, fma3_pre, 8'd0};
			4'b0010: fma3_cs_w = {30'd0, fma3_pre, 16'd0};
			4'b0011: fma3_cs_w = {22'd0, fma3_pre, 24'd0};
			4'b0100: fma3_cs_w = {14'd0, fma3_pre, 32'd0};
			4'b0101: fma3_cs_w = {6'd0,  fma3_pre, 40'd0};
			4'b0110: fma3_cs_w = {fma3_pre[28:0], 48'd0};
			default: fma3_cs_w = 77'd0;
			endcase
		end
		wire [76:0] fma3_cs = fma3_cs_w;
		wire fma3_cst = fma3_cst_w;

		wire [11:0] fma3_adj = !fma3_zc && fma3_kbig ? fma3_kadj : 12'd0;
		wire [76:0] fma3_cw = fma3_zc ? 77'd0 : fma3_kbig ? {2'b00, fma3_mc, 51'd0} : fma3_kleft ? fma3_cs : fma3_kright ? {fma3_cs[76:1], fma3_cs[0] | fma3_cst} : 77'd1;
		wire fma3_same = fma3_zc || fma3_sp == fma3_sc;

		wire fma3_spec_nan = fma3_nan_a || fma3_nan_b || fma3_nan_c || (fma3_inf_a && fma3_zb) || (fma3_inf_b && fma3_za);
		wire fma3_spec_inf_ab = (fma3_inf_a || fma3_inf_b) && !fma3_spec_nan;
		wire fma3_spec_inf_c = fma3_inf_c && !fma3_spec_nan && !fma3_spec_inf_ab;
		wire fma3_spec_zero = (fma3_za || fma3_zb) && !fma3_spec_nan && !fma3_spec_inf_ab && !fma3_spec_inf_c;
		wire fma3_spec_hit = fma3_spec_nan || fma3_spec_inf_ab || fma3_spec_inf_c || fma3_spec_zero;
		wire [31:0] fma3_spec_res =
			fma3_spec_nan ? 32'h7FC00000 :
			fma3_spec_inf_ab ? (fma3_inf_c && fma3_sc != fma3_sp ? 32'h7FC00000 : {fma3_sp, 8'hFF, 23'd0}) :
			fma3_spec_inf_c ? fma3_c :
			(!fma3_zc ? fma3_c : s3_noc ? {fma3_sp, 31'd0} : {fma3_rdn ? (fma3_sp | fma3_sc) : (fma3_sp & fma3_sc), 31'd0});

		reg [31:0] s3_other;
		reg s3_is_flt;
		always @(*) begin
			s3_is_flt = 1'b1;
			s3_other = 32'd0;
			case (s3_op)
			OP_FSGNJ:   s3_other = {s3_b[31], s3_a[30:0]};
			OP_FMIN:    s3_other = s3_fmin;
			OP_FMAX:    s3_other = s3_fmax;
			OP_FCVTWS, OP_FCVTWUS: s3_other = s3_ri;
			OP_FEQ:     s3_other = {32{s3_fcmp[0]}};
			OP_FLT:     s3_other = {32{s3_fcmp[1]}};
			OP_FLE:     s3_other = {32{s3_fcmp[2]}};
			OP_FNE:     s3_other = {32{s3_fcmp[3]}};
			default: ;
			endcase
			case (s3_op)
			OP_FCVTWS, OP_FCVTWUS, OP_FEQ, OP_FLT, OP_FLE, OP_FNE,
			OP_MUL, OP_MULH, OP_MULHSU, OP_MULHU: s3_is_flt = 1'b0;
			default: ;
			endcase
		end

		/* --- Stage 4: Multiplier PREG Output arrives in sync with Register 4 --- */
		(* keep = "true", equivalent_register_removal = "no" *) reg [4:0]  s4_op;
		(* keep = "true", equivalent_register_removal = "no" *) reg [2:0]  s4_rr;
		reg        s4_sat;
		reg [31:0] s4_fx, s4_fy, s4_fz;
		reg        s4_noc;
		reg [31:0] s4_other_pre;
		reg        s4_is_flt;
		reg [31:0] s4_iv;
		reg [31:0] s4_fl;

		/* FMA alignment registers for LAT >= 6 */
		reg [76:0] s4_cw;
		reg [11:0] s4_ab;
		reg [11:0] s4_adj;
		reg        s4_same;
		reg        s4_sp;
		reg        s4_sc;
		reg        s4_rdn;
		reg        s4_zc;
		reg        s4_kbig;
		reg        s4_spec_hit;
		reg [31:0] s4_spec_res;

		always @(posedge clk or negedge rst_n) begin
			if (!rst_n) begin
				s4_op        <= 5'd0;
				s4_sat       <= 1'b0;
				s4_fx        <= 32'd0;
				s4_fy        <= 32'd0;
				s4_fz        <= 32'd0;
				s4_rr        <= 3'd0;
				s4_noc       <= 1'b0;
				s4_other_pre <= 32'd0;
				s4_is_flt    <= 1'b0;
				s4_iv        <= 32'd0;
				s4_fl        <= 32'd0;
				s4_cw        <= 77'd0;
				s4_ab        <= 12'd0;
				s4_adj       <= 12'd0;
				s4_same      <= 1'b0;
				s4_sp        <= 1'b0;
				s4_sc        <= 1'b0;
				s4_rdn       <= 1'b0;
				s4_zc        <= 1'b0;
				s4_kbig      <= 1'b0;
				s4_spec_hit  <= 1'b0;
				s4_spec_res  <= 32'd0;
			end else if (en) begin
				s4_op        <= s3_op;
				s4_sat       <= s3_sat;
				s4_fx        <= s3_fx;
				s4_fy        <= s3_fy;
				s4_fz        <= s3_fz;
				s4_rr        <= s3_rr;
				s4_noc       <= s3_noc;
				s4_other_pre <= s3_other;
				s4_is_flt    <= s3_is_flt;
				s4_iv        <= s3_iv;
				s4_fl        <= s3_fl;
				s4_cw        <= fma3_cw;
				s4_ab        <= fma3_ab;
				s4_adj       <= fma3_adj;
				s4_same      <= fma3_same;
				s4_sp        <= fma3_sp;
				s4_sc        <= fma3_sc;
				s4_rdn       <= fma3_rdn;
				s4_zc        <= fma3_zc;
				s4_kbig      <= fma3_kbig;
				s4_spec_hit  <= fma3_spec_hit;
				s4_spec_res  <= fma3_spec_res;
			end
		end

		/* Legacy FMA instance for LAT < 6 */
		wire [31:0] fma_r;
		if (LAT < 6) begin : g_legacy_fma
			am_fp_fma_p #(.LAT(LAT >= 5 ? 1 : 0)) u_fma4 (
				.clk(clk),
				.rst_n(rst_n),
				.en(en),
				.a0(s4_fx),
				.b0(s4_fy),
				.c0(s4_fz),
				.rm(s4_rr),
				.noc(s4_noc),
				.p(pr_s4[47:0]),
				.r(fma_r)
			);
		end else begin : g_no_legacy_fma
			assign fma_r = 32'd0;
		end

		/* Stage 4: Speculative Parallel 77-bit add/sub (eliminates serial 77-bit comparator) */
		wire [76:0] s4_pw = !s4_zc && s4_kbig ? {76'd0, 1'b1} : {27'd0, pr_s4[47:0], 2'b00};
		wire [76:0] s4_sum_p_c, s4_sum_c_p;
		wire s4_co_p_c, carry_unused_c_p;

		am_addsub #(.W(77)) u_fma_p_c (
			.a(s4_pw), .b(s4_cw), .sub(!s4_same), .s(s4_sum_p_c),
			.co(s4_co_p_c)
		);
		am_sub #(.W(77)) u_fma_c_p (
			.a(s4_cw), .b(s4_pw), .bi(1'b0), .d(s4_sum_c_p),
			.bo(carry_unused_c_p)
		);

		wire s4_pick_p_c = s4_same || s4_co_p_c;
		wire [76:0] s4_sum = s4_pick_p_c ? s4_sum_p_c : s4_sum_c_p;
		wire        s4_sr  = s4_pick_p_c ? s4_sp : s4_sc;

		wire s4_fma = (s4_op <= OP_FNMADD) || (s4_op == OP_FRACT);
		reg [31:0] s4_other;
		always @(*) begin
			s4_other = s4_other_pre;
			case (s4_op)
			OP_FCVTSW, OP_FCVTSWU: s4_other = s4_iv;
			OP_FROUND:  s4_other = s4_fl;
			OP_MUL:     s4_other = pr_s4[31:0];
			OP_MULH, OP_MULHSU, OP_MULHU: s4_other = pr_s4[63:32];
			default: ;
			endcase
		end

		/* Precompute exponent base (ab + adj - 175) and 16-bit block non-zero in Stage 4 for LAT >= 6 */
		wire [11:0] s4_t1, s4_exp_base;
		wire [1:0] fma_carry_unused4_exp;
		am_add #(.W(12)) u_fma_s4_t1 (.a(s4_ab), .b(s4_adj), .ci(1'b0), .s(s4_t1), .co(fma_carry_unused4_exp[0]));
		am_sub #(.W(12)) u_fma_s4_base (.a(s4_t1), .b(12'd175), .bi(1'b0), .d(s4_exp_base), .bo(fma_carry_unused4_exp[1]));

		/* Stage 4: Precompute s5_msb thresholds in parallel with u_fma_s4_base so Stage 5 comparisons avoid waiting for u_fma_er.
		 * s5_er = s5_exp_base + s5_msb >= K  <=>  s5_msb >= K - s5_exp_base = (K + 175) - s4_t1. */
		wire [11:0] s4_thr_ge1_0_w, s4_thr_ge1_1_w, s4_thr_ovf_0_w, s4_thr_ovf_1_w, s4_thr_udf_0_w, s4_thr_udf_1_w;
		wire [5:0]  fma_thr_bo_unused;
		am_sub #(.W(12)) u_fma_t_ge1_0 (.a(12'd302), .b(s4_t1), .bi(1'b0), .d(s4_thr_ge1_0_w), .bo(fma_thr_bo_unused[0]));
		am_sub #(.W(12)) u_fma_t_ge1_1 (.a(12'd301), .b(s4_t1), .bi(1'b0), .d(s4_thr_ge1_1_w), .bo(fma_thr_bo_unused[1]));
		am_sub #(.W(12)) u_fma_t_ovf_0 (.a(12'd430), .b(s4_t1), .bi(1'b0), .d(s4_thr_ovf_0_w), .bo(fma_thr_bo_unused[2]));
		am_sub #(.W(12)) u_fma_t_ovf_1 (.a(12'd429), .b(s4_t1), .bi(1'b0), .d(s4_thr_ovf_1_w), .bo(fma_thr_bo_unused[3]));
		am_sub #(.W(12)) u_fma_t_udf_0 (.a(12'd175), .b(s4_t1), .bi(1'b0), .d(s4_thr_udf_0_w), .bo(fma_thr_bo_unused[4]));
		am_sub #(.W(12)) u_fma_t_udf_1 (.a(12'd174), .b(s4_t1), .bi(1'b0), .d(s4_thr_udf_1_w), .bo(fma_thr_bo_unused[5]));

		/* --- Stage 5: Pipeline match & LOD/Norm for LAT >= 6 --- */
		reg [31:0] s5_rs_other;
		reg [63:0] s5_pr;
		reg [31:0] s5_other_pre;
		reg [31:0] s5_iv;
		reg [31:0] s5_fl;
		reg [4:0]  s5_op;
		reg        s5_fma;
		reg        s5_sat;
		reg        s5_flt;

		reg [76:0] s5_sum;
		reg        s5_sr;
		reg [7:0]  s5_exp_base;
		reg signed [11:0] s5_thr_ge1_0, s5_thr_ge1_1, s5_thr_ovf_0, s5_thr_ovf_1, s5_thr_udf_0, s5_thr_udf_1;
		reg [2:0]  s5_rm;
		reg        s5_rdn;
		reg        s5_spec_hit;
		reg [31:0] s5_spec_res;

		always @(posedge clk or negedge rst_n) begin
			if (!rst_n) begin
				s5_rs_other  <= 32'd0;
				s5_pr        <= 64'd0;
				s5_other_pre <= 32'd0;
				s5_iv        <= 32'd0;
				s5_fl        <= 32'd0;
				s5_op        <= 5'd0;
				s5_fma       <= 1'b0;
				s5_sat       <= 1'b0;
				s5_flt       <= 1'b0;
				s5_sum       <= 77'd0;
				s5_sr        <= 1'b0;
				s5_exp_base  <= 8'd0;
				s5_thr_ge1_0 <= 12'sd0;
				s5_thr_ge1_1 <= 12'sd0;
				s5_thr_ovf_0 <= 12'sd0;
				s5_thr_ovf_1 <= 12'sd0;
				s5_thr_udf_0 <= 12'sd0;
				s5_thr_udf_1 <= 12'sd0;
				s5_rm        <= 3'd0;
				s5_rdn       <= 1'b0;
				s5_spec_hit  <= 1'b0;
				s5_spec_res  <= 32'd0;
			end else if (en) begin
				s5_rs_other  <= (s4_sat && s4_is_flt) ? f_sat(s4_other) : s4_other;
				s5_pr        <= pr_s4[63:0];
				s5_other_pre <= s4_other_pre;
				s5_iv        <= s4_iv;
				s5_fl        <= s4_fl;
				s5_op        <= s4_op;
				s5_fma       <= s4_fma;
				s5_sat       <= s4_sat;
				s5_flt       <= s4_is_flt;
				s5_sum       <= s4_sum;
				s5_sr        <= s4_sr;
				s5_exp_base  <= s4_exp_base[7:0];
				s5_thr_ge1_0 <= s4_thr_ge1_0_w;
				s5_thr_ge1_1 <= s4_thr_ge1_1_w;
				s5_thr_ovf_0 <= s4_thr_ovf_0_w;
				s5_thr_ovf_1 <= s4_thr_ovf_1_w;
				s5_thr_udf_0 <= s4_thr_udf_0_w;
				s5_thr_udf_1 <= s4_thr_udf_1_w;
				s5_rm        <= s4_rr;
				s5_rdn       <= s4_rdn;
				s5_spec_hit  <= s4_spec_hit;
				s5_spec_res  <= s4_sat ? f_sat(s4_spec_res) : s4_spec_res;
			end
		end

		/* Stage 5: Hierarchical LOD, Normalization, Exponent for LAT >= 6 */

		/* Parallel 16-bit prefix LOD per block + factored 1-hot window normalizer & prefix sticky */
		wire [15:0] blk_in4 = {3'd0, s5_sum[76:64]};
		wire [15:0] blk_in3 = s5_sum[63:48];
		wire [15:0] blk_in2 = s5_sum[47:32];
		wire [15:0] blk_in1 = s5_sum[31:16];
		wire [15:0] blk_in0 = s5_sum[15:0];
		wire [79:0] blk_all = {blk_in4, blk_in3, blk_in2, blk_in1, blk_in0};

		wire [79:0] blk_l1h;
		wire [4:0]  s5_blk_nz;
		wire [19:0] blk_sub_msb;
		genvar gb5, gk5;
		for (gb5 = 0; gb5 < 5; gb5 = gb5 + 1) begin : g_blk5
			wire [15:0] bin = blk_all[gb5*16 +: 16];
			wire [15:0] bp1 = bin | {1'b0, bin[15:1]};
			wire [15:0] bp2 = bp1 | {2'd0, bp1[15:2]};
			wire [15:0] bp3 = bp2 | {4'd0, bp2[15:4]};
			wire [15:0] bp4 = bp3 | {8'd0, bp3[15:8]};
			wire [15:0] bl1h = {bp4[15], bp4[14:0] & ~bp4[15:1]};
			assign blk_l1h[gb5*16 +: 16] = bl1h;
			assign s5_blk_nz[gb5] = bp4[0];
			/* Fast direct 4-bit MSB index per 16-bit block (runs in parallel with bp1..bp4) */
			wire [3:0] nib_nz = {|bin[15:12], |bin[11:8], |bin[7:4], |bin[3:0]};
			wire [1:0] nib_m3 = {|bin[15:14], bin[15] | (!bin[14] & bin[13])};
			wire [1:0] nib_m2 = {|bin[11:10], bin[11] | (!bin[10] & bin[9])};
			wire [1:0] nib_m1 = {|bin[7:6],   bin[7]  | (!bin[6]  & bin[5])};
			wire [1:0] nib_m0 = {|bin[3:2],   bin[3]  | (!bin[2]  & bin[1])};
			wire [1:0] sms_hi = {nib_nz[3] | nib_nz[2], nib_nz[3] | (!nib_nz[2] & nib_nz[1])};
			wire [1:0] sms_lo = nib_nz[3] ? nib_m3 : nib_nz[2] ? nib_m2 : nib_nz[1] ? nib_m1 : nib_m0;
			assign blk_sub_msb[gb5*4 +: 4] = {sms_hi, sms_lo};
		end

		wire [4:0] top_blk_1h = {
			s5_blk_nz[4],
			s5_blk_nz[3] & ~s5_blk_nz[4],
			s5_blk_nz[2] & ~|s5_blk_nz[4:3],
			s5_blk_nz[1] & ~|s5_blk_nz[4:2],
			~|s5_blk_nz[4:1]
		};
		wire [2:0] s5_top_blk = {
			top_blk_1h[4],
			top_blk_1h[3] | top_blk_1h[2],
			top_blk_1h[3] | top_blk_1h[1]
		};
		wire s5_sum_nz = |s5_blk_nz;

		wire [3:0] s5_sub_msb =
			({4{top_blk_1h[4]}} & blk_sub_msb[19:16]) |
			({4{top_blk_1h[3]}} & blk_sub_msb[15:12]) |
			({4{top_blk_1h[2]}} & blk_sub_msb[11:8])  |
			({4{top_blk_1h[1]}} & blk_sub_msb[7:4])   |
			({4{top_blk_1h[0]}} & blk_sub_msb[3:0]);

		wire [6:0] s5_msb = {s5_top_blk, s5_sub_msb};

		/* Per-block 16:1 1-hot window shift in parallel with top_blk selection */
		wire [39:0] win_blk [0:4];
		assign win_blk[4] = {3'b000, s5_sum[76:40]};
		assign win_blk[3] = s5_sum[63:24];
		assign win_blk[2] = s5_sum[47:8];
		assign win_blk[1] = {s5_sum[31:0], 8'd0};
		assign win_blk[0] = {s5_sum[15:0], 24'd0};

		wire [24:0] blk_sh25 [0:4];
		for (gb5 = 0; gb5 < 5; gb5 = gb5 + 1) begin : g_wsh5
			wire [15:0] sl1h = blk_l1h[gb5*16 +: 16];
			wire [39:0] wcur = win_blk[gb5];
			wire [3:0] s_lo = {
				sl1h[3] | sl1h[7] | sl1h[11] | sl1h[15],
				sl1h[2] | sl1h[6] | sl1h[10] | sl1h[14],
				sl1h[1] | sl1h[5] | sl1h[9]  | sl1h[13],
				sl1h[0] | sl1h[4] | sl1h[8]  | sl1h[12]
			};
			wire [3:0] s_hi = {|sl1h[15:12], |sl1h[11:8], |sl1h[7:4], |sl1h[3:0]};
			wire [36:0] w_s1;
			for (gk5 = 0; gk5 < 37; gk5 = gk5 + 1) begin : g_ws1
				assign w_s1[gk5] =
					(s_lo[0] & wcur[gk5])     | (s_lo[1] & wcur[gk5 + 1]) |
					(s_lo[2] & wcur[gk5 + 2]) | (s_lo[3] & wcur[gk5 + 3]);
			end
			for (gk5 = 0; gk5 < 25; gk5 = gk5 + 1) begin : g_ws2
				assign blk_sh25[gb5][gk5] =
					(s_hi[0] & w_s1[gk5])     | (s_hi[1] & w_s1[gk5 + 4]) |
					(s_hi[2] & w_s1[gk5 + 8]) | (s_hi[3] & w_s1[gk5 + 12]);
			end
		end

		wire [24:0] s5_win_top =
			({25{top_blk_1h[4]}} & blk_sh25[4]) |
			({25{top_blk_1h[3]}} & blk_sh25[3]) |
			({25{top_blk_1h[2]}} & blk_sh25[2]) |
			({25{top_blk_1h[1]}} & blk_sh25[1]) |
			({25{top_blk_1h[0]}} & blk_sh25[0]);

		wire [23:0] s5_m = s5_win_top[24:1];
		wire s5_g = s5_win_top[0];

		/* Speculative per-block exponent addition in parallel with top_blk_1h selection */
		wire [7:0] blk_er [0:4];
		wire [7:0] blk_er_p1 [0:4];
		wire [4:0] er_hi_co_unused0, er_hi_co_unused1;
		for (gb5 = 0; gb5 < 5; gb5 = gb5 + 1) begin : g_er5
			wire [3:0] er_lo0_b, er_lo1_b, er_hi_k, er_hi_kp1;
			wire er_c0_b, er_c1_b;
			am_add #(.W(4)) u_fma_er_lo0 (.a(s5_exp_base[3:0]), .b(blk_sub_msb[gb5*4 +: 4]), .ci(1'b0), .s(er_lo0_b), .co(er_c0_b));
			am_add #(.W(4)) u_fma_er_lo1 (.a(s5_exp_base[3:0]), .b(blk_sub_msb[gb5*4 +: 4]), .ci(1'b1), .s(er_lo1_b), .co(er_c1_b));
			am_add #(.W(4)) u_fma_er_hk  (.a(s5_exp_base[7:4]), .b(gb5[3:0]),     .ci(1'b0), .s(er_hi_k),   .co(er_hi_co_unused0[gb5]));
			am_add #(.W(4)) u_fma_er_hkp (.a(s5_exp_base[7:4]), .b(gb5[3:0]),     .ci(1'b1), .s(er_hi_kp1), .co(er_hi_co_unused1[gb5]));
			assign blk_er[gb5]    = {er_c0_b ? er_hi_kp1 : er_hi_k, er_lo0_b};
			assign blk_er_p1[gb5] = {er_c1_b ? er_hi_kp1 : er_hi_k, er_lo1_b};
		end
		wire [7:0] s5_er =
			({8{top_blk_1h[4]}} & blk_er[4]) |
			({8{top_blk_1h[3]}} & blk_er[3]) |
			({8{top_blk_1h[2]}} & blk_er[2]) |
			({8{top_blk_1h[1]}} & blk_er[1]) |
			({8{top_blk_1h[0]}} & blk_er[0]);
		wire [7:0] s5_er_p1 =
			({8{top_blk_1h[4]}} & blk_er_p1[4]) |
			({8{top_blk_1h[3]}} & blk_er_p1[3]) |
			({8{top_blk_1h[2]}} & blk_er_p1[2]) |
			({8{top_blk_1h[1]}} & blk_er_p1[1]) |
			({8{top_blk_1h[0]}} & blk_er_p1[0]);
		wire [9:0] fma_carry_unused5 = {er_hi_co_unused1, er_hi_co_unused0};

		/* Fast per-block prefix OR sticky computation in parallel with top_blk_1h */
		wire [15:0] st_pfx [0:3];
		for (gb5 = 0; gb5 < 4; gb5 = gb5 + 1) begin : g_st_pfx5
			wire [15:0] sin = blk_all[gb5*16 +: 16];
			wire [15:0] sp1 = sin | {sin[14:0], 1'b0};
			wire [15:0] sp2 = sp1 | {sp1[13:0], 2'd0};
			wire [15:0] sp3 = sp2 | {sp2[11:0], 4'd0};
			assign st_pfx[gb5] = sp3 | {sp3[7:0], 8'd0};
		end
		wire [4:0] blk_st;
		assign blk_st[0] = 1'b0;
		assign blk_st[1] = |(blk_l1h[1*16+9 +: 7] & st_pfx[0][6:0]);
		assign blk_st[2] = (|(blk_l1h[2*16+0 +: 9] & st_pfx[0][15:7])) |
			(|blk_l1h[2*16+9 +: 7] & (s5_blk_nz[0] | (|(blk_l1h[2*16+9 +: 7] & st_pfx[1][6:0]))));
		assign blk_st[3] = (|blk_l1h[3*16+0 +: 9] & (s5_blk_nz[0] | (|(blk_l1h[3*16+0 +: 9] & st_pfx[1][15:7])))) |
			(|blk_l1h[3*16+9 +: 7] & (|s5_blk_nz[1:0] | (|(blk_l1h[3*16+9 +: 7] & st_pfx[2][6:0]))));
		assign blk_st[4] = (|blk_l1h[4*16+0 +: 9] & (|s5_blk_nz[1:0] | (|(blk_l1h[4*16+0 +: 9] & st_pfx[2][15:7])))) |
			(|blk_l1h[4*16+9 +: 4] & (|s5_blk_nz[2:0] | (|(blk_l1h[4*16+9 +: 4] & st_pfx[3][3:0]))));
		wire s5_st = |(top_blk_1h & blk_st);

		/* --- Stage 6: Pipeline match & Rounding for LAT >= 6 --- */
		/* Precompute early/FF-only bypass and rounding controls in Stage 5 (keeps Stage 5 sum->m/st crisp) */
		reg        s6_bypass_rnd;
		reg [31:0] s6_bypass_val;
		reg        s6_sat;

		reg [23:0] s6_m;
		reg        s6_g;
		reg        s6_st;
		reg [7:0]  s6_er8, s6_er_p1;
		reg        s6_sr;
		reg        s6_up_need_gst;
		reg        s6_up_need_g;
		reg        s6_up_rne;
		reg        s6_odd;
		reg        s6_ovf_inf;
		reg        s6_ge1_0, s6_ge1_1;
		reg        s6_ovf_0, s6_ovf_1;
		reg        s6_udf_0, s6_udf_1;

		wire signed [11:0] s5_msbs = {5'd0, s5_msb};

		reg [31:0] s5_other_lat6;
		always @(*) begin
			s5_other_lat6 = s5_other_pre;
			case (s5_op)
			OP_FCVTSW, OP_FCVTSWU: s5_other_lat6 = s5_iv;
			OP_FROUND:             s5_other_lat6 = s5_fl;
			OP_MUL:                s5_other_lat6 = s5_pr[31:0];
			OP_MULH, OP_MULHSU, OP_MULHU: s5_other_lat6 = s5_pr[63:32];
			default: ;
			endcase
		end

		wire [31:0] s5_rs_other_w = (s5_sat && s5_flt) ? f_sat(s5_other_lat6) : s5_other_lat6;
		wire        s5_bypass_rnd = !s5_fma || s5_spec_hit || !s5_sum_nz;
		wire [31:0] s5_bypass_val = !s5_fma ? s5_rs_other_w :
		                            s5_spec_hit ? s5_spec_res :
		                            (s5_sat ? 32'd0 : {s5_rdn, 31'd0});
		wire s5_up_need_gst = (s5_rm == 3'd2 && s5_sr) || (s5_rm == 3'd3 && !s5_sr);
		wire s5_up_need_g   = (s5_rm == 3'd4);
		wire s5_up_rne      = (s5_rm == 3'd0) || (s5_rm == 3'd7);
		wire s5_odd         = (s5_rm == 3'd5 || s5_rm == 3'd6);
		wire s5_ovf_inf     = (s5_rm == 3'd1 || s5_rm == 3'd5 || s5_rm == 3'd6 ||
		                       (s5_rm == 3'd2 && !s5_sr) || (s5_rm == 3'd3 && s5_sr));

		always @(posedge clk or negedge rst_n) begin
			if (!rst_n) begin
				s6_bypass_rnd  <= 1'b0;
				s6_bypass_val  <= 32'd0;
				s6_sat         <= 1'b0;
				s6_m           <= 24'd0;
				s6_g           <= 1'b0;
				s6_st          <= 1'b0;
				s6_er8         <= 8'd0;
				s6_er_p1       <= 8'd0;
				s6_sr          <= 1'b0;
				s6_up_need_gst <= 1'b0;
				s6_up_need_g   <= 1'b0;
				s6_up_rne      <= 1'b0;
				s6_odd         <= 1'b0;
				s6_ovf_inf     <= 1'b0;
				s6_ge1_0       <= 1'b0;
				s6_ge1_1       <= 1'b0;
				s6_ovf_0       <= 1'b0;
				s6_ovf_1       <= 1'b0;
				s6_udf_0       <= 1'b0;
				s6_udf_1       <= 1'b0;
			end else if (en) begin
				s6_bypass_rnd  <= s5_bypass_rnd;
				s6_bypass_val  <= s5_bypass_val;
				s6_sat         <= s5_sat;
				s6_m           <= s5_m;
				s6_g           <= s5_g;
				s6_st          <= s5_st;
				s6_er8         <= s5_er[7:0];
				s6_er_p1       <= s5_er_p1[7:0];
				s6_sr          <= s5_sr;
				s6_up_need_gst <= s5_up_need_gst;
				s6_up_need_g   <= s5_up_need_g;
				s6_up_rne      <= s5_up_rne;
				s6_odd         <= s5_odd;
				s6_ovf_inf     <= s5_ovf_inf;
				s6_ge1_0       <= (s5_msbs >= s5_thr_ge1_0);
				s6_ge1_1       <= (s5_msbs >= s5_thr_ge1_1);
				s6_ovf_0       <= (s5_msbs >= s5_thr_ovf_0);
				s6_ovf_1       <= (s5_msbs >= s5_thr_ovf_1);
				s6_udf_0       <= (s5_msbs <= s5_thr_udf_0);
				s6_udf_1       <= (s5_msbs <= s5_thr_udf_1);
			end
		end

		/* Stage 6: Speculative Parallel Rounding for LAT >= 6 */
		wire s6_m_all1 = &s6_m;
		wire [24:0] s6_m_p1;
		wire s6_rnd_carry_unused;
		am_add #(.W(25)) u_fma_m_p1 (
			.a({1'b0, s6_m}),
			.b(25'd1),
			.ci(1'b0),
			.s(s6_m_p1),
			.co(s6_rnd_carry_unused)
		);

		wire s6_gst = s6_g || s6_st;
		wire s6_up  = (s6_up_need_gst && s6_gst) ||
		              (s6_up_need_g && s6_g) ||
		              (s6_up_rne && s6_g && (s6_st || s6_m[0]));
		wire [23:0] s6_m_odd = {s6_m[23:1], s6_m[0] | s6_gst};
		wire s6_m_carry = s6_m_all1 && s6_up;

		wire s6_ovf = s6_m_carry ? s6_ovf_1 : s6_ovf_0;
		wire s6_udf = s6_m_carry ? s6_udf_1 : s6_udf_0;
		wire [7:0] s6_exp = s6_m_carry ? s6_er_p1 : s6_er8;

		wire [24:0] s6_mr0 = s6_odd ? {1'b0, s6_m_odd} : s6_up ? s6_m_p1 : {1'b0, s6_m};
		wire [24:0] s6_mr = s6_m_carry ? {1'b0, 1'b1, 23'd0} : s6_mr0;

		/* Inlined early saturation logic without post-addition comparator or OR tree */
		wire s6_ge_1 = s6_m_carry ? s6_ge1_1 : s6_ge1_0;
		wire [31:0] s6_rnd_sat = s6_sr ? 32'd0 :
		                         s6_udf ? 32'd0 :
		                         (s6_ovf || s6_ge_1) ? 32'h3F800000 :
		                         {1'b0, s6_exp, s6_mr[22:0]};

		wire [31:0] s6_rnd_norm = s6_ovf ?
			(s6_ovf_inf ? {s6_sr, 8'hFE, 23'h7FFFFF} : {s6_sr, 8'hFF, 23'd0}) :
			s6_udf ? {s6_sr, 31'd0} : {s6_sr, s6_exp, s6_mr[22:0]};

		wire [31:0] s6_rnd = s6_sat ? s6_rnd_sat : s6_rnd_norm;

		wire [31:0] cur_rs = (LAT >= 6) ? (s6_bypass_rnd ? s6_bypass_val : s6_rnd) :
		                     (LAT >= 5) ? (s5_fma ? fma_r : s5_rs_other) :
		                     s4_fma ? fma_r : s4_other;
		wire        cur_sat = (LAT >= 5) ? s5_sat : s4_sat;
		wire        cur_flt = (LAT >= 5) ? s5_flt : s4_is_flt;

		assign res = (LAT >= 6) ? cur_rs : ((cur_sat && cur_flt) ? f_sat(cur_rs) : cur_rs);
		wire unused_c4 = &{1'b0, carry_unused1_neg, carry_unused2_e, carry_unused2_er, s1_fract_bo_unused, s1_fma_carry_unused, carry_unused3_mr, carry_unused3_ep,
			fma3_carry_unused, carry_unused_c_p, fma_carry_unused5, fma_thr_bo_unused, s4_exp_base[11:8],
			s2_fma_sub_carry_unused, s2_fract_carry_unused,
			s3_e_p1[11:8], pr_s4[65:64], s6_rnd_carry_unused, s6_mr[24:23], s6_m_p1[24], fma3_rs};
	end
	endgenerate

endmodule

`default_nettype wire
