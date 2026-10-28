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
		reg [4:0]  s1_op;
		reg [2:0]  s1_rm;
		reg        s1_sat;
		reg [65:0] s1_mo;

		always @(posedge clk) begin
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

		/* 33x33 multiplier with LAT=3: exactly 3 internal DSP48E1 pipeline registers */
		wire [65:0] pr_s4;
		am_mul #(.AW(33), .BW(33), .SIGNED(1), .LAT(3)) u_mul4 (
			.clk(clk),
			.en(en),
			.a(s1_mo[32:0]),
			.b(s1_mo[65:33]),
			.p(pr_s4)
		);

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

		/* --- Stage 2: Pipeline match & LOD/Shift (Register 2) --- */
		reg [31:0] s2_a, s2_b, s2_c;
		reg [4:0]  s2_op;
		reg [2:0]  s2_rm;
		reg        s2_sat;
		reg [24:0] s2_n;
		reg [31:0] s2_nega;

		always @(posedge clk) begin
			if (!rst_n) begin
				s2_a    <= 32'd0;
				s2_b    <= 32'd0;
				s2_c    <= 32'd0;
				s2_op   <= 5'd0;
				s2_rm   <= 3'd0;
				s2_sat  <= 1'b0;
				s2_n    <= 25'd0;
				s2_nega <= 32'd0;
			end else if (en) begin
				s2_a    <= s1_a;
				s2_b    <= s1_b;
				s2_c    <= s1_c;
				s2_op   <= s1_op;
				s2_rm   <= s1_rm;
				s2_sat  <= s1_sat;
				s2_n    <= s1_n;
				s2_nega <= s1_nega;
			end
		end

		/* Stage 2: i2f LOD and shift, f2i -> latched into Stage 3 */
		wire [31:0] s2_xf = f_flush(s2_a);
		wire cvsw2 = (s2_op == OP_FCVTSW);
		wire cvswu2 = (s2_op == OP_FCVTSWU);
		wire s2_s = cvsw2 ? s2_a[31] : cvswu2 ? 1'b0 : s2_xf[31];
		wire [31:0] s2_in_n = cvsw2 ? (s2_a[31] ? s2_nega : s2_a) : cvswu2 ? s2_a : {7'd0, s2_n};

		wire [4:0] s2_msb;
		wire s2_nz;
		am_msb #(.W(32), .SW(5)) u_msb2 (.a(s2_in_n), .n(s2_msb), .nz(s2_nz));

		wire [31:0] s2_w;
		wire [11:0] s2_e;
		wire carry_unused2_e;
		am_shift #(.W(32), .SW(5)) u_w2 (.a(s2_in_n), .amt(~s2_msb), .left(1'b1), .arith(1'b0), .y(s2_w));
		am_add #(.W(12)) u_e2 (.a({7'd0, s2_msb}), .b(12'd127), .ci(1'b0), .s(s2_e), .co(carry_unused2_e));

		wire [31:0] s2_ri;
		am_fp_f2i #(.LAT(0)) u_f2i2 (
			.x(s2_xf),
			.n(s2_n),
			.uns(s2_op == OP_FCVTWUS),
			.r(s2_ri)
		);

		wire s2_fl_nan = (s2_xf[30:23] == 8'hFF && s2_xf[22:0] != 23'd0);
		wire s2_fl_pass = (s2_xf[30:23] >= 8'd150 || s2_xf[30:23] == 8'd0);

		/* --- Stage 3: Rounding, operand & other formation (Register 3) --- */
		reg [31:0] s3_a, s3_b, s3_c;
		reg [4:0]  s3_op;
		reg [2:0]  s3_rm;
		reg        s3_sat;
		reg        s3_s;
		reg [11:0] s3_e;
		reg [31:0] s3_w;
		reg        s3_nz;
		reg [31:0] s3_ri;
		reg        s3_fl_nan;
		reg        s3_fl_pass;
		reg [31:0] s3_xf_val;

		always @(posedge clk) begin
			if (!rst_n) begin
				s3_a       <= 32'd0;
				s3_b       <= 32'd0;
				s3_c       <= 32'd0;
				s3_op      <= 5'd0;
				s3_rm      <= 3'd0;
				s3_sat     <= 1'b0;
				s3_s       <= 1'b0;
				s3_e       <= 12'd0;
				s3_w       <= 32'd0;
				s3_nz      <= 1'b0;
				s3_ri      <= 32'd0;
				s3_fl_nan  <= 1'b0;
				s3_fl_pass <= 1'b0;
				s3_xf_val  <= 32'd0;
			end else if (en) begin
				s3_a       <= s2_a;
				s3_b       <= s2_b;
				s3_c       <= s2_c;
				s3_op      <= s2_op;
				s3_rm      <= s2_rm;
				s3_sat     <= s2_sat;
				s3_s       <= s2_s;
				s3_e       <= s2_e;
				s3_w       <= s2_w;
				s3_nz      <= s2_nz;
				s3_ri      <= s2_ri;
				s3_fl_nan  <= s2_fl_nan;
				s3_fl_pass <= s2_fl_pass;
				s3_xf_val  <= s2_xf;
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

		wire [24:0] s3_mr0;
		wire carry_unused3_mr;
		am_add #(.W(25)) u_mr3 (
			.a({1'b0, s3_w[31:9], s3_w[8] | (((s3_rm == 3'd5 || s3_rm == 3'd6) && (cvsw3 || cvswu3)) && (s3_g || s3_st))}),
			.b(25'd0),
			.ci(s3_up),
			.s(s3_mr0),
			.co(carry_unused3_mr)
		);

		wire [11:0] s3_e_p1;
		wire carry_unused3_ep;
		am_add #(.W(12)) u_ep3 (.a(s3_e), .b(12'd1), .ci(1'b0), .s(s3_e_p1), .co(carry_unused3_ep));

		wire [7:0] s3_er = s3_mr0[24] ? s3_e_p1[7:0] : s3_e[7:0];
		wire [22:0] s3_mr = s3_mr0[24] ? s3_mr0[23:1] : s3_mr0[22:0];
		wire [31:0] s3_rnd = {s3_s, s3_er, s3_mr};

		wire [31:0] s3_iv = !s3_nz ? {s3_s, 31'd0} : s3_rnd;
		wire [31:0] s3_fl = s3_fl_nan ? 32'h7FC00000 : s3_fl_pass ? s3_xf_val : s3_iv;

		/* Precompute FMA operands & other results in Stage 3 -> latched into Stage 4 */
		reg [31:0] s3_fx, s3_fy, s3_fz;
		reg [2:0]  s3_rr;
		reg        s3_noc;
		always @(*) begin
			s3_fx = s3_a;
			s3_fy = 32'h3F800000;
			s3_fz = s3_b;
			s3_noc = 1'b0;
			s3_rr = s3_rm;
			case (s3_op)
			OP_FADD:   ;
			OP_FSUB:   s3_fz = {!s3_b[31], s3_b[30:0]};
			OP_FMUL:   begin
				s3_fy = s3_b;
				s3_noc = 1'b1;
			end
			OP_FMADD:  begin
				s3_fy = s3_b;
				s3_fz = s3_c;
			end
			OP_FMSUB:  begin
				s3_fy = s3_b;
				s3_fz = {!s3_c[31], s3_c[30:0]};
			end
			OP_FNMSUB: begin
				s3_fx = {!s3_a[31], s3_a[30:0]};
				s3_fy = s3_b;
				s3_fz = s3_c;
			end
			OP_FNMADD: begin
				s3_fx = {!s3_a[31], s3_a[30:0]};
				s3_fy = s3_b;
				s3_fz = {!s3_c[31], s3_c[30:0]};
			end
			OP_FRACT:  begin
				s3_fz = {!s3_fl[31], s3_fl[30:0]};
				s3_rr = 3'd0;
			end
			default: ;
			endcase
		end

		reg [31:0] s3_other;
		reg s3_is_flt;
		always @(*) begin
			s3_is_flt = 1'b1;
			s3_other = 32'd0;
			case (s3_op)
			OP_FSGNJ:   s3_other = {s3_b[31], s3_a[30:0]};
			OP_FMIN:    s3_other = f_minmax(s3_a, s3_b, 1'b0);
			OP_FMAX:    s3_other = f_minmax(s3_a, s3_b, 1'b1);
			OP_FCVTWS, OP_FCVTWUS: s3_other = s3_ri;
			OP_FEQ:     s3_other = {32{f_cmp(s3_a, s3_b, 2'd0)}};
			OP_FLT:     s3_other = {32{f_cmp(s3_a, s3_b, 2'd1)}};
			OP_FLE:     s3_other = {32{f_cmp(s3_a, s3_b, 2'd2)}};
			OP_FNE:     s3_other = {32{f_cmp(s3_a, s3_b, 2'd3)}};
			default: ;
			endcase
			case (s3_op)
			OP_FCVTWS, OP_FCVTWUS, OP_FEQ, OP_FLT, OP_FLE, OP_FNE,
			OP_MUL, OP_MULH, OP_MULHSU, OP_MULHU: s3_is_flt = 1'b0;
			default: ;
			endcase
		end

		/* --- Stage 4: Multiplier PREG Output arrives in sync with Register 4 --- */
		reg [4:0]  s4_op;
		reg        s4_sat;
		reg [31:0] s4_fx, s4_fy, s4_fz;
		reg [2:0]  s4_rr;
		reg        s4_noc;
		reg [31:0] s4_other_pre;
		reg        s4_is_flt;
		reg [31:0] s4_iv;
		reg [31:0] s4_fl;

		always @(posedge clk) begin
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
			end
		end

		wire [31:0] fma_r;
		am_fp_fma_p #(.LAT(LAT >= 6 ? 2 : LAT >= 5 ? 1 : 0)) u_fma4 (
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

		/* --- Stage 5: Pipeline match (LAT >= 5) --- */
		reg [31:0] s5_rs_other;
		reg        s5_fma;
		reg        s5_sat;
		reg        s5_flt;

		always @(posedge clk) begin
			if (!rst_n) begin
				s5_rs_other <= 32'd0;
				s5_fma      <= 1'b0;
				s5_sat      <= 1'b0;
				s5_flt      <= 1'b0;
			end else if (en) begin
				s5_rs_other <= s4_other;
				s5_fma      <= s4_fma;
				s5_sat      <= s4_sat;
				s5_flt      <= s4_is_flt;
			end
		end

		/* --- Stage 6: Pipeline match (LAT >= 6) --- */
		reg [31:0] s6_rs_other;
		reg        s6_fma;
		reg        s6_sat;
		reg        s6_flt;

		always @(posedge clk) begin
			if (!rst_n) begin
				s6_rs_other <= 32'd0;
				s6_fma      <= 1'b0;
				s6_sat      <= 1'b0;
				s6_flt      <= 1'b0;
			end else if (en) begin
				s6_rs_other <= s5_rs_other;
				s6_fma      <= s5_fma;
				s6_sat      <= s5_sat;
				s6_flt      <= s5_flt;
			end
		end

		wire [31:0] cur_rs_other = (LAT >= 6) ? s6_rs_other :
		                           (LAT >= 5) ? s5_rs_other : s4_other;
		wire        cur_fma      = (LAT >= 6) ? s6_fma :
		                           (LAT >= 5) ? s5_fma : s4_fma;
		wire        cur_sat      = (LAT >= 6) ? s6_sat :
		                           (LAT >= 5) ? s5_sat : s4_sat;
		wire        cur_flt      = (LAT >= 6) ? s6_flt :
		                           (LAT >= 5) ? s5_flt : s4_is_flt;

		wire [31:0] cur_rs = cur_fma ? fma_r : cur_rs_other;

		assign res = (cur_sat && cur_flt) ? f_sat(cur_rs) : cur_rs;
		wire unused_c4 = &{1'b0, carry_unused1_neg, carry_unused2_e, carry_unused3_mr, carry_unused3_ep, s3_e_p1[11:8], pr_s4[65:64]};
	end
	endgenerate

endmodule

`default_nettype wire
