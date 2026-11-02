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

module atg_su_fpu_core (
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

	function [31:0] f_flush;
		input [31:0] x;
		f_flush = (x[30:23] == 8'd0) ? {x[31], 31'd0} : x;
	endfunction

	function [47:0] f_sig;
		input [30:0] a_in, b_in;
		f_sig = {a_in[30:23] != 8'd0 ? {1'b1, a_in[22:0]} : 24'd0,
			b_in[30:23] != 8'd0 ? {1'b1, b_in[22:0]} : 24'd0};
	endfunction

	/* Pure-LUT float saturation to [0, 1] (0 CARRY4) */
	function [31:0] f_sat;
		input [31:0] x;
		reg is_nan, gt_one;
		begin
			is_nan = (x[30:23] == 8'hFF) && (x[22:0] != 23'd0);
			gt_one = x[30] || ((&x[29:23]) && (|x[22:0]));
			if (is_nan || x[31])
				f_sat = 32'd0;
			else if (gt_one)
				f_sat = 32'h3F800000;
			else
				f_sat = x;
		end
	endfunction

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

	/* Pure-LUT 5-bit functions (0 CARRY4) */
	function [4:0] f5_150;
		input [4:0] e5;
		case (e5)
		5'd0: f5_150 = 5'd22; 5'd1: f5_150 = 5'd21; 5'd2: f5_150 = 5'd20; 5'd3: f5_150 = 5'd19;
		5'd4: f5_150 = 5'd18; 5'd5: f5_150 = 5'd17; 5'd6: f5_150 = 5'd16; 5'd7: f5_150 = 5'd15;
		5'd8: f5_150 = 5'd14; 5'd9: f5_150 = 5'd13; 5'd10: f5_150 = 5'd12; 5'd11: f5_150 = 5'd11;
		5'd12: f5_150 = 5'd10; 5'd13: f5_150 = 5'd9; 5'd14: f5_150 = 5'd8; 5'd15: f5_150 = 5'd7;
		5'd16: f5_150 = 5'd6; 5'd17: f5_150 = 5'd5; 5'd18: f5_150 = 5'd4; 5'd19: f5_150 = 5'd3;
		5'd20: f5_150 = 5'd2; 5'd21: f5_150 = 5'd1; 5'd22: f5_150 = 5'd0; 5'd23: f5_150 = 5'd31;
		5'd24: f5_150 = 5'd30; 5'd25: f5_150 = 5'd29; 5'd26: f5_150 = 5'd28; 5'd27: f5_150 = 5'd27;
		5'd28: f5_150 = 5'd26; 5'd29: f5_150 = 5'd25; 5'd30: f5_150 = 5'd24; default: f5_150 = 5'd23;
		endcase
	endfunction

	function [4:0] f5_149;
		input [4:0] e5;
		case (e5)
		5'd0: f5_149 = 5'd21; 5'd1: f5_149 = 5'd20; 5'd2: f5_149 = 5'd19; 5'd3: f5_149 = 5'd18;
		5'd4: f5_149 = 5'd17; 5'd5: f5_149 = 5'd16; 5'd6: f5_149 = 5'd15; 5'd7: f5_149 = 5'd14;
		5'd8: f5_149 = 5'd13; 5'd9: f5_149 = 5'd12; 5'd10: f5_149 = 5'd11; 5'd11: f5_149 = 5'd10;
		5'd12: f5_149 = 5'd9; 5'd13: f5_149 = 5'd8; 5'd14: f5_149 = 5'd7; 5'd15: f5_149 = 5'd6;
		5'd16: f5_149 = 5'd5; 5'd17: f5_149 = 5'd4; 5'd18: f5_149 = 5'd3; 5'd19: f5_149 = 5'd2;
		5'd20: f5_149 = 5'd1; 5'd21: f5_149 = 5'd0; 5'd22: f5_149 = 5'd31; 5'd23: f5_149 = 5'd30;
		5'd24: f5_149 = 5'd29; 5'd25: f5_149 = 5'd28; 5'd26: f5_149 = 5'd27; 5'd27: f5_149 = 5'd26;
		5'd28: f5_149 = 5'd25; 5'd29: f5_149 = 5'd24; 5'd30: f5_149 = 5'd23; default: f5_149 = 5'd22;
		endcase
	endfunction

	function [4:0] sh5_22;
		input [4:0] e5;
		case (e5)
		5'd22: sh5_22 = 5'd0; 5'd23: sh5_22 = 5'd1; 5'd24: sh5_22 = 5'd2;
		5'd25: sh5_22 = 5'd3; 5'd26: sh5_22 = 5'd4; 5'd27: sh5_22 = 5'd5;
		5'd28: sh5_22 = 5'd6; 5'd29: sh5_22 = 5'd7; 5'd30: sh5_22 = 5'd8;
		default: sh5_22 = 5'd9;
		endcase
	endfunction

	function [4:0] sub5_1;
		input [4:0] x;
		begin
			sub5_1[0] = ~x[0];
			sub5_1[1] = x[1] ^ ~x[0];
			sub5_1[2] = x[2] ^ (&(~x[1:0]));
			sub5_1[3] = x[3] ^ (&(~x[2:0]));
			sub5_1[4] = x[4] ^ (&(~x[3:0]));
		end
	endfunction

	function [4:0] neg5;
		input [4:0] x;
		begin
			neg5[0] = x[0];
			neg5[1] = x[1] ^ x[0];
			neg5[2] = x[2] ^ (|x[1:0]);
			neg5[3] = x[3] ^ (|x[2:0]);
			neg5[4] = x[4] ^ (|x[3:0]);
		end
	endfunction

	function [4:0] add4_co;
		input [3:0] x;
		input [3:0] y;
		input ci;
		reg c1, c2, c3, c4;
		begin
			c1 = (x[0] & y[0]) | ((x[0] ^ y[0]) & ci);
			c2 = (x[1] & y[1]) | ((x[1] ^ y[1]) & c1);
			c3 = (x[2] & y[2]) | ((x[2] ^ y[2]) & c2);
			c4 = (x[3] & y[3]) | ((x[3] ^ y[3]) & c3);
			add4_co = {c4, x[3] ^ y[3] ^ c3, x[2] ^ y[2] ^ c2, x[1] ^ y[1] ^ c1, x[0] ^ y[0] ^ ci};
		end
	endfunction

	function [14:0] mask15_low;
		input [3:0] amt;
		case (amt)
		4'd0:  mask15_low = 15'h0000;
		4'd1:  mask15_low = 15'h0001;
		4'd2:  mask15_low = 15'h0003;
		4'd3:  mask15_low = 15'h0007;
		4'd4:  mask15_low = 15'h000F;
		4'd5:  mask15_low = 15'h001F;
		4'd6:  mask15_low = 15'h003F;
		4'd7:  mask15_low = 15'h007F;
		4'd8:  mask15_low = 15'h00FF;
		4'd9:  mask15_low = 15'h01FF;
		4'd10: mask15_low = 15'h03FF;
		4'd11: mask15_low = 15'h07FF;
		4'd12: mask15_low = 15'h0FFF;
		4'd13: mask15_low = 15'h1FFF;
		4'd14: mask15_low = 15'h3FFF;
		default: mask15_low = 15'h7FFF;
		endcase
	endfunction

	(* keep = "true" *) wire rst_p = !rst_n;

	/* --- Stage 0 -> Stage 1 --- */
	(* keep = "true", max_fanout = 12 *) wire mo_is_fma_a_lo = (op <= OP_FNMADD) || (op == OP_FRACT);
	(* keep = "true", max_fanout = 12 *) wire mo_is_fma_a_hi = (op <= OP_FNMADD) || (op == OP_FRACT);
	(* keep = "true", max_fanout = 12 *) wire mo_is_fma_b_lo = (op <= OP_FNMADD) || (op == OP_FRACT);
	(* keep = "true", max_fanout = 12 *) wire mo_is_fma_b_hi = (op <= OP_FNMADD) || (op == OP_FRACT);
	(* keep = "true", max_fanout = 12 *) wire mo_b_use_b_lo  = (op >= OP_FMUL) && (op <= OP_FNMADD);
	(* keep = "true", max_fanout = 12 *) wire mo_b_use_b_hi  = (op >= OP_FMUL) && (op <= OP_FNMADD);
	(* keep = "true", max_fanout = 12 *) wire mo_a_nz_lo = (a[30:23] != 8'd0);
	(* keep = "true", max_fanout = 12 *) wire mo_a_nz_hi = (a[30:23] != 8'd0);
	(* keep = "true", max_fanout = 12 *) wire mo_b_nz_lo = (b[30:23] != 8'd0);
	(* keep = "true", max_fanout = 12 *) wire mo_b_nz_hi = (b[30:23] != 8'd0);
	wire [15:0] mo_sg_a_lo = mo_a_nz_lo ? a[15:0] : 16'd0;
	wire [7:0]  mo_sg_a_hi = mo_a_nz_hi ? {1'b1, a[22:16]} : 8'd0;
	wire [15:0] mo_sg_b_lo = mo_b_use_b_lo ? (mo_b_nz_lo ? b[15:0] : 16'd0) : 16'd0;
	wire [7:0]  mo_sg_b_hi = mo_b_use_b_hi ? (mo_b_nz_hi ? {1'b1, b[22:16]} : 8'd0) : 8'h80;
	wire [32:0] mo_a_s0 = {
		mo_is_fma_a_hi ? {9'd0, mo_sg_a_hi} : {op != OP_MULHU && a[31], a[31:16]},
		mo_is_fma_a_lo ? mo_sg_a_lo : a[15:0]
	};
	wire [32:0] mo_b_s0 = {
		mo_is_fma_b_hi ? {9'd0, mo_sg_b_hi} : {(op == OP_MUL || op == OP_MULH) && b[31], b[31:16]},
		mo_is_fma_b_lo ? mo_sg_b_lo : b[15:0]
	};
	wire [65:0] mo_s0 = {mo_b_s0, mo_a_s0};

	wire [31:0] nega_s0;
	wire carry_unused0_neg;
	am_sub #(.W(32)) u_neg0 (.a(32'd0), .b(a), .bi(1'b0), .d(nega_s0), .bo(carry_unused0_neg));
	(* keep = "true", max_fanout = 12 *) wire cv_neg_lo_s0 = (op == OP_FCVTSW) && a[31];
	(* keep = "true", max_fanout = 12 *) wire cv_neg_hi_s0 = (op == OP_FCVTSW) && a[31];
	wire [31:0] cv_mag_s0 = {cv_neg_hi_s0 ? nega_s0[31:16] : a[31:16], cv_neg_lo_s0 ? nega_s0[15:0] : a[15:0]};
	wire is_cv_s0 = (op == OP_FCVTSW) || (op == OP_FCVTSWU);

	wire a_exp_nz_s0 = (a[30:23] != 8'd0);
	wire [23:0] m_s0 = {a_exp_nz_s0, a[22:0]};
	(* max_fanout = 16 *) wire [4:0] f5_s0 = f5_150(a[27:23]);
	(* max_fanout = 16 *) wire [4:0] fm1_s0 = f5_149(a[27:23]);
	wire [23:0] q0_s0;
	wire [23:0] smk_s0;
	am_shift #(.W(24), .SW(5)) u_q0 (.a(m_s0), .amt(f5_s0), .left(1'b0), .arith(1'b0), .y(q0_s0));
	am_shift #(.W(24), .SW(5)) u_smk0 (.a(24'hFFFFFF), .amt(fm1_s0), .left(1'b1), .arith(1'b0), .y(smk_s0));
	wire f_ge24_s0 = !a[30] && !(&a[29:23]);
	wire f_gt24_s0 = !a[30] && !(&a[29:24]);
	wire f_ne0_s0 = (a[30:23] != 8'd150);
	wire g_bit_s0 = m_s0[fm1_s0];
	wire st_raw_s0 = |(m_s0 & ~smk_s0);

	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s1_a, s1_b, s1_c;
	(* shreg_extract = "no", keep = "true", equivalent_register_removal = "no", max_fanout = 12 *) reg [4:0] s1_op;
	(* shreg_extract = "no", keep = "true", equivalent_register_removal = "no", max_fanout = 12 *) reg [2:0] s1_rm;
	(* shreg_extract = "no", max_fanout = 12 *) reg s1_sat;
	(* shreg_extract = "no", keep = "true", max_fanout = 12 *) reg [65:0] s1_mo;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s1_cv_mag;
	(* shreg_extract = "no", max_fanout = 12 *) reg s1_is_cv;
	(* shreg_extract = "no", max_fanout = 12 *) reg [23:0] s1_q;
	(* shreg_extract = "no", max_fanout = 12 *) reg s1_g_bit, s1_st_raw, s1_f_ge24, s1_f_gt24, s1_f_ne0, s1_m_nz;

	always @(posedge clk) begin
		if (rst_p) begin
			s1_a      <= 32'd0;
			s1_b      <= 32'd0;
			s1_c      <= 32'd0;
			s1_op     <= 5'd0;
			s1_rm     <= 3'd0;
			s1_sat    <= 1'b0;
			s1_mo     <= 66'd0;
			s1_cv_mag <= 32'd0;
			s1_is_cv  <= 1'b0;
			s1_q      <= 24'd0;
			s1_g_bit  <= 1'b0;
			s1_st_raw <= 1'b0;
			s1_f_ge24 <= 1'b0;
			s1_f_gt24 <= 1'b0;
			s1_f_ne0  <= 1'b0;
			s1_m_nz   <= 1'b0;
		end else if (en) begin
			s1_a      <= a;
			s1_b      <= b;
			s1_c      <= c;
			s1_op     <= op;
			s1_rm     <= rm;
			s1_sat    <= sat;
			s1_mo     <= mo_s0;
			s1_cv_mag <= cv_mag_s0;
			s1_is_cv  <= is_cv_s0;
			s1_q      <= q0_s0;
			s1_g_bit  <= g_bit_s0;
			s1_st_raw <= st_raw_s0;
			s1_f_ge24 <= f_ge24_s0;
			s1_f_gt24 <= f_gt24_s0;
			s1_f_ne0  <= f_ne0_s0;
			s1_m_nz   <= a_exp_nz_s0;
		end
	end

	/* 33x33 multiplier with LAT=2 */
	wire [65:0] pr_mul;
	am_mul #(.AW(33), .BW(33), .SIGNED(1), .LAT(2)) u_mul4 (
		.clk(clk),
		.en(en),
		.a(s1_mo[32:0]),
		.b(s1_mo[65:33]),
		.p(pr_mul)
	);

	reg [65:0] pr_s4;
	always @(posedge clk) begin
		if (rst_p)
			pr_s4 <= 66'd0;
		else if (en)
			pr_s4 <= pr_mul;
	end

	/* --- Stage 1 -> Stage 2 --- */
	wire [23:0] s1_q_eff = s1_f_ge24 ? 24'd0 : s1_q;
	wire s1_g = s1_f_gt24 ? 1'b0 : s1_g_bit;
	wire s1_st = s1_f_gt24 ? s1_m_nz : (s1_f_ne0 && s1_st_raw);
	wire [2:0] s1_rint_rm = (s1_op == OP_FRACT) ? 3'd2 : s1_rm;
	reg s1_up;
	always @(*) begin
		case (s1_rint_rm)
		3'd1: s1_up = 1'b0;
		3'd2: s1_up = s1_a[31] && (s1_g || s1_st);
		3'd3: s1_up = !s1_a[31] && (s1_g || s1_st);
		3'd4: s1_up = s1_g;
		default: s1_up = s1_g && (s1_st || s1_q_eff[0]);
		endcase
	end

	wire [24:0] s1_q_p1;
	wire carry_unused1_qp1;
	am_add #(.W(25)) u_q1_p1 (.a({1'b0, s1_q_eff}), .b(25'd1), .ci(1'b0), .s(s1_q_p1), .co(carry_unused1_qp1));
	wire s1_up_n_lo, s1_up_n_hi, s1_up_in_lo, s1_up_in_hi, s1_is_cv_lo, s1_is_cv_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s1up_n_lo  (.I0(s1_up), .O(s1_up_n_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s1up_n_hi  (.I0(s1_up), .O(s1_up_n_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s1up_in_lo (.I0(s1_up), .O(s1_up_in_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s1up_in_hi (.I0(s1_up), .O(s1_up_in_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s1cv_lo    (.I0(s1_is_cv), .O(s1_is_cv_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s1cv_hi    (.I0(s1_is_cv), .O(s1_is_cv_hi));
`else
	assign s1_up_n_lo  = s1_up;
	assign s1_up_n_hi  = s1_up;
	assign s1_up_in_lo = s1_up;
	assign s1_up_in_hi = s1_up;
	assign s1_is_cv_lo = s1_is_cv;
	assign s1_is_cv_hi = s1_is_cv;
`endif
	wire [24:0] s1_n = {
		s1_up_n_hi ? s1_q_p1[24:12] : {1'b0, s1_q_eff[23:12]},
		s1_up_n_lo ? s1_q_p1[11:0]  : s1_q_eff[11:0]
	};
	wire [31:0] s1_in_n = {
		s1_is_cv_hi ? s1_cv_mag[31:16] : (s1_up_in_hi ? {7'd0, s1_q_p1[24:16]} : {8'd0, s1_q_eff[23:16]}),
		s1_is_cv_lo ? s1_cv_mag[15:0]  : (s1_up_in_lo ? s1_q_p1[15:0]          : s1_q_eff[15:0])
	};

	(* keep = "true", max_fanout = 12 *) wire [4:0] s1_op_lo = s1_op;
	(* keep = "true", max_fanout = 12 *) wire [4:0] s1_op_hi = s1_op;
	(* keep = "true", max_fanout = 12 *) wire [4:0] s1_op_fz_lo = s1_op;
	(* keep = "true", max_fanout = 12 *) wire [4:0] s1_op_fz_hi = s1_op;
	(* keep = "true", max_fanout = 12 *) wire s1_a_ez_lo = (s1_a[30:23] == 8'd0);
	(* keep = "true", max_fanout = 12 *) wire s1_a_ez_hi = (s1_a[30:23] == 8'd0);
	(* keep = "true", max_fanout = 12 *) wire s1_b_ez_lo = (s1_b[30:23] == 8'd0);
	(* keep = "true", max_fanout = 12 *) wire s1_b_ez_hi = (s1_b[30:23] == 8'd0);
	(* keep = "true", max_fanout = 12 *) wire s1_b_ez_c_lo = (s1_b[30:23] == 8'd0);
	(* keep = "true", max_fanout = 12 *) wire s1_b_ez_c_hi = (s1_b[30:23] == 8'd0);
	(* keep = "true", max_fanout = 12 *) wire s1_c_ez_lo = (s1_c[30:23] == 8'd0);
	(* keep = "true", max_fanout = 12 *) wire s1_c_ez_hi = (s1_c[30:23] == 8'd0);

	reg [31:0] s1_fx, s1_fy;
	reg [15:0] s1_fz_lo, s1_fz_hi;
	reg [15:0] s1_fma_b_lo, s1_fma_b_hi, s1_fma_c_lo, s1_fma_c_hi;
	reg [2:0]  s1_rr;
	reg        s1_noc;
	always @(*) begin
		s1_fx = s1_a;
		s1_fy = 32'h3F800000;
		s1_noc = 1'b0;
		s1_rr = s1_rm;
		case (s1_op)
		OP_FMUL:   begin
			s1_fy = s1_b;
			s1_noc = 1'b1;
		end
		OP_FMADD, OP_FMSUB: begin
			s1_fy = s1_b;
		end
		OP_FNMSUB, OP_FNMADD: begin
			s1_fx = {!s1_a[31], s1_a[30:0]};
			s1_fy = s1_b;
		end
		OP_FRACT:  begin
			s1_rr = 3'd0;
		end
		default: ;
		endcase

		case (s1_op_fz_lo)
		OP_FMADD, OP_FMSUB, OP_FNMSUB, OP_FNMADD:
			s1_fz_lo = s1_c[15:0];
		OP_FRACT:
			s1_fz_lo = 16'd0;
		default:
			s1_fz_lo = s1_b[15:0];
		endcase
		case (s1_op_fz_hi)
		OP_FSUB:
			s1_fz_hi = {!s1_b[31], s1_b[30:16]};
		OP_FMADD, OP_FNMSUB:
			s1_fz_hi = s1_c[31:16];
		OP_FMSUB, OP_FNMADD:
			s1_fz_hi = {!s1_c[31], s1_c[30:16]};
		OP_FRACT:
			s1_fz_hi = 16'd0;
		default:
			s1_fz_hi = s1_b[31:16];
		endcase

		case (s1_op_lo)
		OP_FMUL, OP_FMADD, OP_FMSUB, OP_FNMSUB, OP_FNMADD:
			s1_fma_b_lo = s1_b_ez_lo ? 16'd0 : s1_b[15:0];
		default:
			s1_fma_b_lo = 16'd0;
		endcase
		case (s1_op_hi)
		OP_FMUL, OP_FMADD, OP_FMSUB, OP_FNMSUB, OP_FNMADD:
			s1_fma_b_hi = s1_b_ez_hi ? {s1_b[31], 15'd0} : s1_b[31:16];
		default:
			s1_fma_b_hi = 16'h3F80;
		endcase

		case (s1_op_lo)
		OP_FMADD, OP_FMSUB, OP_FNMSUB, OP_FNMADD:
			s1_fma_c_lo = s1_c_ez_lo ? 16'd0 : s1_c[15:0];
		OP_FRACT:
			s1_fma_c_lo = 16'd0;
		default:
			s1_fma_c_lo = s1_b_ez_c_lo ? 16'd0 : s1_b[15:0];
		endcase
		case (s1_op_hi)
		OP_FMADD, OP_FNMSUB:
			s1_fma_c_hi = s1_c_ez_hi ? {s1_c[31], 15'd0} : s1_c[31:16];
		OP_FMSUB, OP_FNMADD:
			s1_fma_c_hi = s1_c_ez_hi ? {!s1_c[31], 15'd0} : {!s1_c[31], s1_c[30:16]};
		OP_FRACT:
			s1_fma_c_hi = 16'd0;
		OP_FSUB:
			s1_fma_c_hi = s1_b_ez_c_hi ? {!s1_b[31], 15'd0} : {!s1_b[31], s1_b[30:16]};
		default:
			s1_fma_c_hi = s1_b_ez_c_hi ? {s1_b[31], 15'd0} : s1_b[31:16];
		endcase
	end
	wire [31:0] s1_fz = {s1_fz_hi, s1_fz_lo};

	wire [31:0] s1_fma_a = {s1_a_ez_hi ? {s1_fx[31], 15'd0} : s1_fx[31:16], s1_a_ez_lo ? 16'd0 : s1_fx[15:0]};
	wire [31:0] s1_fma_b = {s1_fma_b_hi, s1_fma_b_lo};
	wire [31:0] s1_fma_c = {s1_fma_c_hi, s1_fma_c_lo};
	wire [7:0]  s1_c_exp = (s1_op == OP_FRACT) ? 8'd127 : s1_fma_c[30:23];

	wire [11:0] s1_fma_ab, s1_fma_c150, s1_fma_c152, s1_fma_c101;
	wire [3:0]  s1_fma_carry_unused;
	am_add #(.W(12)) u_fma1_ab   (.a({4'd0, s1_fma_a[30:23]}), .b({4'd0, s1_fma_b[30:23]}), .ci(1'b0), .s(s1_fma_ab),   .co(s1_fma_carry_unused[0]));
	am_add #(.W(12)) u_fma1_c150 (.a({4'd0, s1_c_exp}),        .b(12'd150),                 .ci(1'b0), .s(s1_fma_c150), .co(s1_fma_carry_unused[1]));
	am_add #(.W(12)) u_fma1_c152 (.a({4'd0, s1_c_exp}),        .b(12'd152),                 .ci(1'b0), .s(s1_fma_c152), .co(s1_fma_carry_unused[2]));
	am_add #(.W(12)) u_fma1_c101 (.a({4'd0, s1_c_exp}),        .b(12'd101),                 .ci(1'b0), .s(s1_fma_c101), .co(s1_fma_carry_unused[3]));

	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s2_a, s2_b, s2_c;
	(* shreg_extract = "no", keep = "true", max_fanout = 12 *) reg [31:0] s2_xf_r, s2_bf_r;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s2_xf_ez_r, s2_bf_ez_r, s2_c_ez_r;
	(* shreg_extract = "no", keep = "true", equivalent_register_removal = "no", max_fanout = 12 *) reg [4:0] s2_op;
	(* shreg_extract = "no", keep = "true", equivalent_register_removal = "no", max_fanout = 12 *) reg [2:0] s2_rm;
	(* shreg_extract = "no", max_fanout = 12 *) reg s2_sat;
	(* shreg_extract = "no", max_fanout = 12 *) reg [24:0] s2_n;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s2_in_n;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s2_fx, s2_fy, s2_fz;
	(* shreg_extract = "no", max_fanout = 12 *) reg [2:0]  s2_rr;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s2_noc;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s2_fma_a, s2_fma_b, s2_fma_c;
	(* shreg_extract = "no", max_fanout = 12 *) reg [11:0] s2_fma_ab, s2_fma_c150, s2_fma_c152, s2_fma_c101;
	(* keep = "true", max_fanout = 12 *) wire rst_s2_xf_lo = rst_p || (en && s1_a_ez_lo);
	(* keep = "true", max_fanout = 12 *) wire rst_s2_xf_hi = rst_p || (en && s1_a_ez_hi);
	(* keep = "true", max_fanout = 12 *) wire rst_s2_bf_lo = rst_p || (en && s1_b_ez_lo);
	(* keep = "true", max_fanout = 12 *) wire rst_s2_bf_hi = rst_p || (en && s1_b_ez_hi);

	always @(posedge clk) begin
		if (rst_s2_xf_lo)
			s2_xf_r[15:0] <= 16'd0;
		else if (en)
			s2_xf_r[15:0] <= s1_a[15:0];
		if (rst_s2_xf_hi)
			s2_xf_r[30:16] <= 15'd0;
		else if (en)
			s2_xf_r[30:16] <= s1_a[30:16];
		if (rst_s2_bf_lo)
			s2_bf_r[15:0] <= 16'd0;
		else if (en)
			s2_bf_r[15:0] <= s1_b[15:0];
		if (rst_s2_bf_hi)
			s2_bf_r[30:16] <= 15'd0;
		else if (en)
			s2_bf_r[30:16] <= s1_b[30:16];

		if (rst_p) begin
			s2_a        <= 32'd0;
			s2_b        <= 32'd0;
			s2_c        <= 32'd0;
			s2_xf_r[31] <= 1'b0;
			s2_bf_r[31] <= 1'b0;
			s2_xf_ez_r  <= 1'b0;
			s2_bf_ez_r  <= 1'b0;
			s2_c_ez_r   <= 1'b0;
			s2_op       <= 5'd0;
			s2_rm       <= 3'd0;
			s2_sat      <= 1'b0;
			s2_n        <= 25'd0;
			s2_in_n     <= 32'd0;
			s2_fx       <= 32'd0;
			s2_fy       <= 32'd0;
			s2_fz       <= 32'd0;
			s2_rr       <= 3'd0;
			s2_noc      <= 1'b0;
			s2_fma_a    <= 32'd0;
			s2_fma_b    <= 32'd0;
			s2_fma_c    <= 32'd0;
			s2_fma_ab   <= 12'd0;
			s2_fma_c150 <= 12'd0;
			s2_fma_c152 <= 12'd0;
			s2_fma_c101 <= 12'd0;
		end else if (en) begin
			s2_a        <= s1_a;
			s2_b        <= s1_b;
			s2_c        <= s1_c;
			s2_xf_r[31] <= s1_a[31];
			s2_bf_r[31] <= s1_b[31];
			s2_xf_ez_r  <= s1_a_ez_lo;
			s2_bf_ez_r  <= s1_b_ez_lo;
			s2_c_ez_r   <= (s1_fz_hi[14:7] == 8'd0);
			s2_op       <= s1_op;
			s2_rm       <= s1_rm;
			s2_sat      <= s1_sat;
			s2_n        <= s1_n;
			s2_in_n     <= s1_in_n;
			s2_fx       <= s1_fx;
			s2_fy       <= s1_fy;
			s2_fz       <= s1_fz;
			s2_rr       <= s1_rr;
			s2_noc      <= s1_noc;
			s2_fma_a    <= s1_fma_a;
			s2_fma_b    <= s1_fma_b;
			s2_fma_c    <= s1_fma_c;
			s2_fma_ab   <= s1_fma_ab;
			s2_fma_c150 <= s1_fma_c150;
			s2_fma_c152 <= s1_fma_c152;
			s2_fma_c101 <= s1_fma_c101;
		end
	end

	/* --- Stage 2 -> Stage 3 --- */
	wire [31:0] s2_xf = s2_xf_r;
	wire [31:0] s2_bf = s2_bf_r;
	wire cvsw2 = (s2_op == OP_FCVTSW);
	wire cvswu2 = (s2_op == OP_FCVTSWU);
	wire s2_s = cvsw2 ? s2_a[31] : cvswu2 ? 1'b0 : s2_xf[31];

	/* Level-pinned 32-bit MSB & coarse shift (strictly <= 3 LUTs from s2_in_n) */
	(* keep = "true" *) wire s2_n_g7 = |s2_in_n[31:28];
	(* keep = "true" *) wire s2_n_g6 = |s2_in_n[27:24];
	(* keep = "true" *) wire s2_n_g5 = |s2_in_n[23:20];
	(* keep = "true" *) wire s2_n_g4 = |s2_in_n[19:16];
	(* keep = "true" *) wire s2_n_g3 = |s2_in_n[15:12];
	(* keep = "true" *) wire s2_n_g2 = |s2_in_n[11:8];
	(* keep = "true" *) wire s2_n_g1 = |s2_in_n[7:4];
	(* keep = "true" *) wire s2_n_g0 = |s2_in_n[3:0];

	(* keep = "true", max_fanout = 16 *) wire s2_msb4 = s2_n_g7 || s2_n_g6 || s2_n_g5 || s2_n_g4;
	(* keep = "true", max_fanout = 16 *) wire s2_msb3 = s2_n_g7 || s2_n_g6 || (!s2_n_g5 && !s2_n_g4 && (s2_n_g3 || s2_n_g2));
	(* keep = "true", max_fanout = 16 *) wire s2_msb2 = s2_n_g7 || (!s2_n_g6 && (s2_n_g5 || (!s2_n_g4 && (s2_n_g3 || (!s2_n_g2 && s2_n_g1)))));
	(* keep = "true", max_fanout = 16 *) wire s2_nz   = s2_msb4 || s2_n_g3 || s2_n_g2 || s2_n_g1 || s2_n_g0;

	wire [1:0] s2_m10_7 = s2_in_n[31] ? 2'd3 : s2_in_n[30] ? 2'd2 : s2_in_n[29] ? 2'd1 : 2'd0;
	wire [1:0] s2_m10_6 = s2_in_n[27] ? 2'd3 : s2_in_n[26] ? 2'd2 : s2_in_n[25] ? 2'd1 : 2'd0;
	wire [1:0] s2_m10_5 = s2_in_n[23] ? 2'd3 : s2_in_n[22] ? 2'd2 : s2_in_n[21] ? 2'd1 : 2'd0;
	wire [1:0] s2_m10_4 = s2_in_n[19] ? 2'd3 : s2_in_n[18] ? 2'd2 : s2_in_n[17] ? 2'd1 : 2'd0;
	wire [1:0] s2_m10_3 = s2_in_n[15] ? 2'd3 : s2_in_n[14] ? 2'd2 : s2_in_n[13] ? 2'd1 : 2'd0;
	wire [1:0] s2_m10_2 = s2_in_n[11] ? 2'd3 : s2_in_n[10] ? 2'd2 : s2_in_n[9]  ? 2'd1 : 2'd0;
	wire [1:0] s2_m10_1 = s2_in_n[7]  ? 2'd3 : s2_in_n[6]  ? 2'd2 : s2_in_n[5]  ? 2'd1 : 2'd0;
	wire [1:0] s2_m10_0 = s2_in_n[3]  ? 2'd3 : s2_in_n[2]  ? 2'd2 : s2_in_n[1]  ? 2'd1 : 2'd0;

	(* keep = "true" *) wire [1:0] s2_m10_hi = s2_n_g7 ? s2_m10_7 : s2_n_g6 ? s2_m10_6 : s2_n_g5 ? s2_m10_5 : s2_m10_4;
	(* keep = "true" *) wire [1:0] s2_m10_lo = s2_n_g3 ? s2_m10_3 : s2_n_g2 ? s2_m10_2 : s2_n_g1 ? s2_m10_1 : s2_m10_0;
	(* keep = "true", max_fanout = 16 *) wire [1:0] s2_msb10 = s2_msb4 ? s2_m10_hi : s2_m10_lo;
	wire [4:0] s2_msb = {s2_msb4, s2_msb3, s2_msb2, s2_msb10};

	/* Coarse shift by ~s2_msb[4:2] * 4 in Stage 2 (2 LUT levels from s2_msb4..2 and s2_in_n) */
	(* keep = "true" *) wire [31:0] s2_w_hi = s2_msb3 ? (s2_msb2 ? s2_in_n : {s2_in_n[27:0], 4'd0}) :
		(s2_msb2 ? {s2_in_n[23:0], 8'd0} : {s2_in_n[19:0], 12'd0});
	(* keep = "true" *) wire [31:0] s2_w_lo = s2_msb3 ? (s2_msb2 ? {s2_in_n[15:0], 16'd0} : {s2_in_n[11:0], 20'd0}) :
		(s2_msb2 ? {s2_in_n[7:0], 24'd0} : {s2_in_n[3:0], 28'd0});
	wire [31:0] s2_w_pre = s2_msb4 ? s2_w_hi : s2_w_lo;

	wire [11:0] s2_e = {4'd0, (s2_msb != 5'd0), {2{s2_msb == 5'd0}}, sub5_1(s2_msb)};
	wire [11:0] s2_e_p1 = {4'd0, 3'b100, s2_msb};

	wire s2_fl_nan = (s2_xf[30:23] == 8'hFF && s2_xf[22:0] != 23'd0);
	(* keep = "true" *) wire s2_exp_ge150_lo = s2_xf[30] && ((|s2_xf[29:28]) || (s2_xf[27] && (s2_xf[26] || (s2_xf[25] && s2_xf[24]))));
	(* keep = "true" *) wire s2_exp_ge150_hi = s2_xf[30] && ((|s2_xf[29:28]) || (s2_xf[27] && (s2_xf[26] || (s2_xf[25] && s2_xf[24]))));
	wire s2_fl_pass = s2_exp_ge150_lo || s2_xf_ez_r;
	wire s2_fract_ge1 = s2_xf[30] || (&s2_xf[29:23]);
	wire s2_fract_inc = !s2_fl_pass && (~s2_msb10[0] ^ s2_xf[23]);

	/* Stage 2: f2i barrel shift (negation in Stage 3) */
	(* max_fanout = 16 *) wire [4:0] s2_f2i_sh = sh5_22(s2_xf[27:23]);
	wire [31:0] s2_f2i_mw;
	am_shift #(.W(32), .SW(5)) u_f2i_mw2 (.a({8'd0, 1'b1, s2_xf[22:0]}), .amt(s2_f2i_sh), .left(1'b1), .arith(1'b0), .y(s2_f2i_mw));
	wire [31:0] s2_f2i_mag = {
		s2_exp_ge150_hi ? s2_f2i_mw[31:16] : {7'd0, s2_n[24:16]},
		s2_exp_ge150_lo ? s2_f2i_mw[15:0]  : s2_n[15:0]
	};
	wire s2_f2i_s = s2_xf[31] && !s2_fl_nan;
	wire s2_f2i_big = s2_xf[30] && ((|s2_xf[29:28]) || (&s2_xf[27:23]));
	wire s2_f2i_gt80 = (s2_xf[30:23] == 8'd158) && (s2_xf[22:0] != 23'd0);

	/* Stage 2: 31-bit magnitude comparators for fmin/fmax/fcmp (pre=0, post=0 around CARRY4) */
	wire [30:0] unused_ab_d2, unused_ba_d2;
	wire s2_ab_lt, s2_ba_lt;
	am_sub #(.W(31)) u_ab_lt2 (.a(s2_xf[30:0]), .b(s2_bf[30:0]), .bi(1'b0), .d(unused_ab_d2), .bo(s2_ab_lt));
	am_sub #(.W(31)) u_ba_lt2 (.a(s2_bf[30:0]), .b(s2_xf[30:0]), .bi(1'b0), .d(unused_ba_d2), .bo(s2_ba_lt));
	wire s2_af_nan = s2_fl_nan;
	wire s2_bf_nan = (s2_bf[30:23] == 8'hFF && s2_bf[22:0] != 23'd0);
	wire s2_ab_eq = (s2_xf == s2_bf) || (s2_xf_ez_r && s2_bf_ez_r);

	/* Stage 2: FMA exponent differences & precomputed special flags */
	wire [11:0] s2_fma_k, s2_fma_kp2;
	wire [1:0]  s2_fma_sub_carry_unused;
	am_sub #(.W(12)) u_fma2_k   (.a(s2_fma_c150), .b(s2_fma_ab), .bi(1'b0), .d(s2_fma_k),   .bo(s2_fma_sub_carry_unused[0]));
	am_sub #(.W(12)) u_fma2_kp2 (.a(s2_fma_c152), .b(s2_fma_ab), .bi(1'b0), .d(s2_fma_kp2), .bo(s2_fma_sub_carry_unused[1]));
	(* keep = "true", max_fanout = 12 *) wire s2_fr_ge1 = (s2_op == OP_FRACT) && s2_fract_ge1;
	wire [4:0] s2_fma_rs_raw = neg5(s2_fma_kp2[4:0]);
	wire [4:0] s2_fma_rs;
`ifdef SYNTH_KINTEX7
	genvar g_rs;
	for (g_rs = 0; g_rs < 5; g_rs = g_rs + 1) begin: g_buf_rs
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rs (.I0(s2_fma_rs_raw[g_rs]), .O(s2_fma_rs[g_rs]));
	end
`else
	assign s2_fma_rs = s2_fma_rs_raw;
`endif
	(* keep = "true", max_fanout = 12 *) wire [3:0] s2_cs_left_rep = {4{s2_fr_ge1 || !s2_fma_kp2[11]}};
	(* keep = "true", max_fanout = 12 *) wire [6:0] s2_cs_amt = s2_fma_kp2[6:0];
	(* keep = "true", max_fanout = 12 *) wire s2_mc_zero_lo = (s2_op == OP_FRACT) || s2_noc || s2_c_ez_r;
	(* keep = "true", max_fanout = 12 *) wire s2_mc_zero_hi = (s2_op == OP_FRACT) || s2_noc || s2_c_ez_r;
	wire [23:0] s2_fma_mc_sh = {
		(s2_op == OP_FRACT) ? 1'b1 : !s2_mc_zero_hi,
		s2_mc_zero_hi ? 7'd0  : s2_fma_c[22:16],
		s2_mc_zero_lo ? 16'd0 : s2_fma_c[15:0]
	};

	wire s2_nan_a = s2_fma_a[30:23] == 8'hFF && s2_fma_a[22:0] != 23'd0;
	wire s2_nan_b = s2_fma_b[30:23] == 8'hFF && s2_fma_b[22:0] != 23'd0;
	wire s2_nan_c = !s2_noc && ((s2_op == OP_FRACT) ? s2_fl_nan : (s2_fma_c[30:23] == 8'hFF && s2_fma_c[22:0] != 23'd0));
	wire s2_inf_a = s2_fma_a[30:23] == 8'hFF && s2_fma_a[22:0] == 23'd0;
	wire s2_inf_b = s2_fma_b[30:23] == 8'hFF && s2_fma_b[22:0] == 23'd0;
	wire s2_inf_c = !s2_noc && ((s2_op == OP_FRACT) ? (s2_xf[30:23] == 8'hFF && s2_xf[22:0] == 23'd0) : (s2_fma_c[30:23] == 8'hFF && s2_fma_c[22:0] == 23'd0));
	wire s2_za    = s2_fma_a[30:23] == 8'd0;
	wire s2_zb    = s2_fma_b[30:23] == 8'd0;
	wire s2_spec_nan    = s2_nan_a || s2_nan_b || s2_nan_c || (s2_inf_a && s2_zb) || (s2_inf_b && s2_za);
	wire s2_spec_inf_ab = (s2_inf_a || s2_inf_b) && !s2_spec_nan;
	wire s2_spec_inf_c  = s2_inf_c && !s2_spec_nan && !s2_spec_inf_ab;
	wire s2_spec_zero   = (s2_za || s2_zb) && !s2_spec_nan && !s2_spec_inf_ab && !s2_spec_inf_c;

	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s3_a, s3_b;
	(* shreg_extract = "no", keep = "true", equivalent_register_removal = "no", max_fanout = 12 *) reg [4:0] s3_op;
	(* shreg_extract = "no", keep = "true", equivalent_register_removal = "no", max_fanout = 12 *) reg [2:0] s3_rm;
	(* shreg_extract = "no", max_fanout = 12 *) reg s3_sat;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s3_s;
	(* shreg_extract = "no", max_fanout = 12 *) reg [11:0] s3_e, s3_e_p1;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s3_w_pre;
	(* shreg_extract = "no", max_fanout = 12 *) reg [1:0] s3_sh_lo;
	(* shreg_extract = "no", max_fanout = 12 *) reg s3_nz;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s3_fl_nan;
	(* shreg_extract = "no", max_fanout = 12 *) reg s3_fl_pass;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s3_xf_val, s3_bf_val;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s3_fract_ge1, s3_fract_inc;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s3_c_ez, s3_xf_ez, s3_is_fract;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s3_f2i_mag;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s3_f2i_s, s3_f2i_big, s3_f2i_gt80;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s3_ab_lt, s3_ba_lt, s3_af_nan, s3_bf_nan, s3_ab_eq;
	(* shreg_extract = "no", max_fanout = 12 *) reg [2:0]  s3_rr;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s3_noc;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s3_fma_a, s3_fma_b, s3_fma_c;
	(* shreg_extract = "no", max_fanout = 12 *) reg [11:0] s3_fma_ab, s3_fma_c101;
	(* shreg_extract = "no", max_fanout = 12 *) reg [11:0] s3_fma_k;
	(* shreg_extract = "no", max_fanout = 12 *) reg [4:0]  s3_fma_rs;
	(* shreg_extract = "no", keep = "true", equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] s3_cs_left_r;
	(* shreg_extract = "no", max_fanout = 12 *) reg [6:0]  s3_cs_amt;
	(* shreg_extract = "no", max_fanout = 12 *) reg [23:0] s3_fma_mc_sh;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s3_spec_nan, s3_spec_inf_ab, s3_spec_inf_c, s3_spec_zero, s3_inf_c;

	always @(posedge clk) begin
		if (rst_p) begin
			s3_a           <= 32'd0;
			s3_b           <= 32'd0;
			s3_op          <= 5'd0;
			s3_rm          <= 3'd0;
			s3_sat         <= 1'b0;
			s3_s           <= 1'b0;
			s3_e           <= 12'd0;
			s3_e_p1        <= 12'd0;
			s3_w_pre       <= 32'd0;
			s3_sh_lo       <= 2'd0;
			s3_nz          <= 1'b0;
			s3_fl_nan      <= 1'b0;
			s3_fl_pass     <= 1'b0;
			s3_xf_val      <= 32'd0;
			s3_bf_val      <= 32'd0;
			s3_fract_ge1   <= 1'b0;
			s3_fract_inc   <= 1'b0;
			s3_c_ez        <= 1'b0;
			s3_xf_ez       <= 1'b0;
			s3_is_fract    <= 1'b0;
			s3_f2i_mag     <= 32'd0;
			s3_f2i_s       <= 1'b0;
			s3_f2i_big     <= 1'b0;
			s3_f2i_gt80    <= 1'b0;
			s3_ab_lt       <= 1'b0;
			s3_ba_lt       <= 1'b0;
			s3_af_nan      <= 1'b0;
			s3_bf_nan      <= 1'b0;
			s3_ab_eq       <= 1'b0;
			s3_rr          <= 3'd0;
			s3_noc         <= 1'b0;
			s3_fma_a       <= 32'd0;
			s3_fma_b       <= 32'd0;
			s3_fma_c       <= 32'd0;
			s3_fma_ab      <= 12'd0;
			s3_fma_c101    <= 12'd0;
			s3_fma_k       <= 12'd0;
			s3_fma_rs      <= 5'd0;
			s3_cs_left_r   <= 4'd0;
			s3_cs_amt      <= 7'd0;
			s3_fma_mc_sh   <= 24'd0;
			s3_spec_nan    <= 1'b0;
			s3_spec_inf_ab <= 1'b0;
			s3_spec_inf_c  <= 1'b0;
			s3_spec_zero   <= 1'b0;
			s3_inf_c       <= 1'b0;
		end else if (en) begin
			s3_a           <= s2_a;
			s3_b           <= s2_b;
			s3_op          <= s2_op;
			s3_rm          <= s2_rm;
			s3_sat         <= s2_sat;
			s3_s           <= s2_s;
			s3_e           <= s2_e;
			s3_e_p1        <= s2_e_p1;
			s3_w_pre       <= s2_w_pre;
			s3_sh_lo       <= ~s2_msb10;
			s3_nz          <= s2_nz;
			s3_fl_nan      <= s2_fl_nan;
			s3_fl_pass     <= s2_fl_pass;
			s3_xf_val      <= s2_xf;
			s3_bf_val      <= s2_bf;
			s3_fract_ge1   <= s2_fract_ge1;
			s3_fract_inc   <= s2_fract_inc;
			s3_c_ez        <= s2_c_ez_r;
			s3_xf_ez       <= s2_xf_ez_r;
			s3_is_fract    <= (s2_op == OP_FRACT);
			s3_f2i_mag     <= s2_f2i_mag;
			s3_f2i_s       <= s2_f2i_s;
			s3_f2i_big     <= s2_f2i_big;
			s3_f2i_gt80    <= s2_f2i_gt80;
			s3_ab_lt       <= s2_ab_lt;
			s3_ba_lt       <= s2_ba_lt;
			s3_af_nan      <= s2_af_nan;
			s3_bf_nan      <= s2_bf_nan;
			s3_ab_eq       <= s2_ab_eq;
			s3_rr          <= s2_rr;
			s3_noc         <= s2_noc;
			s3_fma_a       <= s2_fma_a;
			s3_fma_b       <= s2_fma_b;
			s3_fma_c       <= s2_fma_c;
			s3_fma_ab      <= s2_fma_ab;
			s3_fma_c101    <= s2_fma_c101;
			s3_fma_k       <= s2_fma_k;
			s3_fma_rs      <= s2_fma_rs;
			s3_cs_left_r   <= s2_cs_left_rep;
			s3_cs_amt      <= s2_cs_amt;
			s3_fma_mc_sh   <= s2_fma_mc_sh;
			s3_spec_nan    <= s2_spec_nan;
			s3_spec_inf_ab <= s2_spec_inf_ab;
			s3_spec_inf_c  <= s2_spec_inf_c;
			s3_spec_zero   <= s2_spec_zero;
			s3_inf_c       <= s2_inf_c;
		end
	end

	/* --- Stage 3 -> Stage 4 --- */
	(* keep = "true" *) wire [1:0] s3_sh_lo_a  = s3_sh_lo;
	(* keep = "true" *) wire [1:0] s3_sh_lo_b0 = s3_sh_lo;
	(* keep = "true" *) wire [1:0] s3_sh_lo_b1 = s3_sh_lo;
	reg [15:0] s3_w_lo, s3_w_hi;
	always @(*) begin
		case (s3_sh_lo_a)
		2'd0: s3_w_lo = s3_w_pre[15:0];
		2'd1: s3_w_lo = {s3_w_pre[14:0], 1'b0};
		2'd2: s3_w_lo = {s3_w_pre[13:0], 2'b00};
		default: s3_w_lo = {s3_w_pre[12:0], 3'b000};
		endcase
		case (s3_sh_lo_b0)
		2'd0: s3_w_hi[7:0] = s3_w_pre[23:16];
		2'd1: s3_w_hi[7:0] = s3_w_pre[22:15];
		2'd2: s3_w_hi[7:0] = s3_w_pre[21:14];
		default: s3_w_hi[7:0] = s3_w_pre[20:13];
		endcase
		case (s3_sh_lo_b1)
		2'd0: s3_w_hi[15:8] = s3_w_pre[31:24];
		2'd1: s3_w_hi[15:8] = s3_w_pre[30:23];
		2'd2: s3_w_hi[15:8] = s3_w_pre[29:22];
		default: s3_w_hi[15:8] = s3_w_pre[28:21];
		endcase
	end
	wire [31:0] s3_w = {s3_w_hi, s3_w_lo};

	wire [31:0] s3_rint_rnd = {s3_s, s3_e[7:0], s3_w[30:8]};
	(* keep = "true" *) wire s3_rfl_z_lo = !s3_fl_nan && !s3_fl_pass && !s3_nz;
	(* keep = "true" *) wire s3_rfl_z_hi = !s3_fl_nan && !s3_fl_pass && !s3_nz;
	(* keep = "true" *) wire s3_rfl_p_lo = !s3_fl_nan && s3_fl_pass;
	(* keep = "true" *) wire s3_rfl_p_hi = !s3_fl_nan && s3_fl_pass;
	wire [31:0] s3_rint_fl = {
		s3_fl_nan ? 16'h7FC0 : s3_rfl_p_hi ? s3_xf_val[31:16] : s3_rfl_z_hi ? {s3_s, 15'd0} : s3_rint_rnd[31:16],
		s3_fl_nan ? 16'h0000 : s3_rfl_p_lo ? s3_xf_val[15:0]  : s3_rfl_z_lo ? 16'd0         : s3_rint_rnd[15:0]
	};

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

	/* Speculative +1 on s3_w[31:8] (pre=1, post=1 around CARRY4) */
	wire [24:0] s3_w_p1;
	wire carry_unused3_mr;
	am_add #(.W(25)) u_mr3_p1 (.a({1'b0, s3_w[31:8]}), .b(25'd1), .ci(1'b0), .s(s3_w_p1), .co(carry_unused3_mr));
	wire s3_w_b8 = s3_w[8] | (((s3_rm == 3'd5 || s3_rm == 3'd6) && (cvsw3 || cvswu3)) && (s3_g || s3_st));
	wire s3_up_lo0, s3_up_lo1, s3_up_hi0, s3_up_hi1;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3up_lo0 (.I0(s3_up), .O(s3_up_lo0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3up_lo1 (.I0(s3_up), .O(s3_up_lo1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3up_hi0 (.I0(s3_up), .O(s3_up_hi0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3up_hi1 (.I0(s3_up), .O(s3_up_hi1));
`else
	assign s3_up_lo0 = s3_up;
	assign s3_up_lo1 = s3_up;
	assign s3_up_hi0 = s3_up;
	assign s3_up_hi1 = s3_up;
`endif
	wire [24:0] s3_mr0 = {
		s3_up_hi1 ? s3_w_p1[24:19] : {1'b0, s3_w[31:27]},
		s3_up_hi0 ? s3_w_p1[18:12] : s3_w[26:20],
		s3_up_lo1 ? s3_w_p1[11:6]  : s3_w[19:14],
		s3_up_lo0 ? s3_w_p1[5:0]   : {s3_w[13:9], s3_w_b8}
	};
	wire s3_mr_ovf_lo0, s3_mr_ovf_lo1, s3_mr_ovf_e, s3_mr_ovf_m;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3ovf_lo0 (.I0(s3_mr0[24]), .O(s3_mr_ovf_lo0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3ovf_lo1 (.I0(s3_mr0[24]), .O(s3_mr_ovf_lo1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3ovf_e   (.I0(s3_mr0[24]), .O(s3_mr_ovf_e));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3ovf_m   (.I0(s3_mr0[24]), .O(s3_mr_ovf_m));
`else
	assign s3_mr_ovf_lo0 = s3_mr0[24];
	assign s3_mr_ovf_lo1 = s3_mr0[24];
	assign s3_mr_ovf_e   = s3_mr0[24];
	assign s3_mr_ovf_m   = s3_mr0[24];
`endif
	wire [7:0]  s3_er = s3_mr_ovf_e ? s3_e_p1[7:0] : s3_e[7:0];
	wire [22:0] s3_mr = {
		s3_mr_ovf_m   ? s3_mr0[23:16] : s3_mr0[22:15],
		s3_mr_ovf_lo1 ? s3_mr0[15:8]  : s3_mr0[14:7],
		s3_mr_ovf_lo0 ? s3_mr0[7:1]   : s3_mr0[6:0]
	};
	wire s3_nz_lo0, s3_nz_lo1, s3_nz_iv0, s3_nz_iv1, s3_nz_hi;
	wire s3_fl_nan_lo, s3_fl_nan_hi;
	wire s3_fl_pass_lo0, s3_fl_pass_lo1, s3_fl_pass_hi0, s3_fl_pass_hi1;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3nz_lo0  (.I0(s3_nz), .O(s3_nz_lo0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3nz_lo1  (.I0(s3_nz), .O(s3_nz_lo1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3nz_iv0  (.I0(s3_nz), .O(s3_nz_iv0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3nz_iv1  (.I0(s3_nz), .O(s3_nz_iv1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3nz_hi   (.I0(s3_nz), .O(s3_nz_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3nan_lo  (.I0(s3_fl_nan), .O(s3_fl_nan_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3nan_hi  (.I0(s3_fl_nan), .O(s3_fl_nan_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3pas_lo0 (.I0(s3_fl_pass), .O(s3_fl_pass_lo0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3pas_lo1 (.I0(s3_fl_pass), .O(s3_fl_pass_lo1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3pas_hi0 (.I0(s3_fl_pass), .O(s3_fl_pass_hi0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3pas_hi1 (.I0(s3_fl_pass), .O(s3_fl_pass_hi1));
`else
	assign s3_nz_lo0      = s3_nz;
	assign s3_nz_lo1      = s3_nz;
	assign s3_nz_iv0      = s3_nz;
	assign s3_nz_iv1      = s3_nz;
	assign s3_nz_hi       = s3_nz;
	assign s3_fl_nan_lo   = s3_fl_nan;
	assign s3_fl_nan_hi   = s3_fl_nan;
	assign s3_fl_pass_lo0 = s3_fl_pass;
	assign s3_fl_pass_lo1 = s3_fl_pass;
	assign s3_fl_pass_hi0 = s3_fl_pass;
	assign s3_fl_pass_hi1 = s3_fl_pass;
`endif
	wire [31:0] s3_iv = {
		!s3_nz_iv1 ? {s3_s, 7'd0} : {s3_s, s3_er[7:1]},
		!s3_nz_iv0 ? 8'd0         : {s3_er[0], s3_mr[22:16]},
		!s3_nz_lo1 ? 8'd0         : s3_mr[15:8],
		!s3_nz_lo0 ? 8'd0         : s3_mr[7:0]
	};
	wire [31:0] s3_fl = {
		s3_fl_nan_hi  ? 8'h7F : (s3_fl_pass_hi1 ? s3_xf_val[31:24] : s3_iv[31:24]),
		s3_fl_nan_hi  ? 8'hC0 : (s3_fl_pass_hi0 ? s3_xf_val[23:16] : s3_iv[23:16]),
		s3_fl_nan_lo  ? 8'h00 : (s3_fl_pass_lo1 ? s3_xf_val[15:8]  : s3_iv[15:8]),
		s3_fl_nan_lo  ? 8'h00 : (s3_fl_pass_lo0 ? s3_xf_val[7:0]   : s3_iv[7:0])
	};

	/* Stage 3: f2i negation & saturation (pre=0, post=1 around CARRY4) */
	wire [31:0] s3_f2i_neg;
	wire carry_unused3_f2i;
	am_sub #(.W(32)) u_f2i_neg3 (.a(32'd0), .b(s3_f2i_mag), .bi(1'b0), .d(s3_f2i_neg), .bo(carry_unused3_f2i));
	wire s3_f2i_uns = (s3_op == OP_FCVTWUS);
	wire s3_f2i_sat_s = s3_f2i_big || (!s3_f2i_s && s3_f2i_mag[31]) || (s3_f2i_s && s3_f2i_gt80);
	wire s3_ri_zero_lo, s3_ri_zero_hi;
	wire s3_ri_fmax_lo, s3_ri_fmax_hi;
	wire s3_ri_smin_lo, s3_ri_smin_hi;
	wire s3_ri_neg_lo,  s3_ri_neg_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3riz_lo (.I0(s3_f2i_uns && s3_f2i_s), .O(s3_ri_zero_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3riz_hi (.I0(s3_f2i_uns && s3_f2i_s), .O(s3_ri_zero_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3rif_lo (.I0(s3_f2i_uns ? (!s3_f2i_s && s3_f2i_big) : (s3_f2i_sat_s && !s3_f2i_s)), .O(s3_ri_fmax_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3rif_hi (.I0(s3_f2i_uns ? (!s3_f2i_s && s3_f2i_big) : (s3_f2i_sat_s && !s3_f2i_s)), .O(s3_ri_fmax_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3rim_lo (.I0(!s3_f2i_uns && s3_f2i_sat_s && s3_f2i_s), .O(s3_ri_smin_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3rim_hi (.I0(!s3_f2i_uns && s3_f2i_sat_s && s3_f2i_s), .O(s3_ri_smin_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3rin_lo (.I0(!s3_f2i_uns && !s3_f2i_sat_s && s3_f2i_s), .O(s3_ri_neg_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_s3rin_hi (.I0(!s3_f2i_uns && !s3_f2i_sat_s && s3_f2i_s), .O(s3_ri_neg_hi));
`else
	assign s3_ri_zero_lo = s3_f2i_uns && s3_f2i_s;
	assign s3_ri_zero_hi = s3_f2i_uns && s3_f2i_s;
	assign s3_ri_fmax_lo = s3_f2i_uns ? (!s3_f2i_s && s3_f2i_big) : (s3_f2i_sat_s && !s3_f2i_s);
	assign s3_ri_fmax_hi = s3_f2i_uns ? (!s3_f2i_s && s3_f2i_big) : (s3_f2i_sat_s && !s3_f2i_s);
	assign s3_ri_smin_lo = !s3_f2i_uns && s3_f2i_sat_s && s3_f2i_s;
	assign s3_ri_smin_hi = !s3_f2i_uns && s3_f2i_sat_s && s3_f2i_s;
	assign s3_ri_neg_lo  = !s3_f2i_uns && !s3_f2i_sat_s && s3_f2i_s;
	assign s3_ri_neg_hi  = !s3_f2i_uns && !s3_f2i_sat_s && s3_f2i_s;
`endif
	wire [31:0] s3_ri = {
		s3_ri_zero_hi ? 16'd0 : s3_ri_fmax_hi ? {s3_f2i_uns, 15'h7FFF} : s3_ri_smin_hi ? 16'h8000 : s3_ri_neg_hi ? s3_f2i_neg[31:16] : s3_f2i_mag[31:16],
		s3_ri_zero_lo ? 16'd0 : s3_ri_fmax_lo ? 16'hFFFF               : s3_ri_smin_lo ? 16'h0000 : s3_ri_neg_lo ? s3_f2i_neg[15:0]  : s3_f2i_mag[15:0]
	};

	/* Stage 3: FMA Alignment (0 CARRY4 on fma3_cw and fma3_t1 paths) */
	wire [31:0] s3_fract_c = {!s3_rint_fl[31], s3_rint_fl[30:0]};
	(* keep = "true" *) wire s3_fr_cz_lo = (s3_fract_c[30:23] == 8'd0);
	(* keep = "true" *) wire s3_fr_cz_hi = (s3_fract_c[30:23] == 8'd0);
	(* keep = "true" *) wire fract3_lo = s3_is_fract;
	(* keep = "true" *) wire fract3_hi = s3_is_fract;

	wire [31:0] fma3_a = s3_fma_a;
	wire [31:0] fma3_b = s3_fma_b;
	wire [31:0] fma3_c = {
		fract3_hi ? (s3_fr_cz_hi ? {s3_fract_c[31], 15'd0} : s3_fract_c[31:16]) : s3_fma_c[31:16],
		fract3_lo ? (s3_fr_cz_lo ? 16'd0                   : s3_fract_c[15:0])  : s3_fma_c[15:0]
	};
	wire fma3_sp = fma3_a[31] ^ fma3_b[31];
	wire fma3_sc = fma3_c[31];
	wire fma3_rdn = s3_rr == 3'd2 || s3_rr == 3'd6;
	wire fma3_zc = s3_noc || (s3_is_fract ? (!s3_fl_nan && (s3_fl_pass ? s3_xf_ez : !s3_nz)) : s3_c_ez);

	wire s3_mc_fr_pass_lo, s3_mc_fr_pass_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_mcfr_lo (.I0(s3_fl_pass), .O(s3_mc_fr_pass_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_mcfr_hi (.I0(s3_fl_pass), .O(s3_mc_fr_pass_hi));
`else
	assign s3_mc_fr_pass_lo = s3_fl_pass;
	assign s3_mc_fr_pass_hi = s3_fl_pass;
`endif
	wire [23:0] fma3_mc_fr = {
		1'b1,
		s3_mc_fr_pass_hi ? s3_xf_val[22:12] : s3_w[30:20],
		s3_mc_fr_pass_lo ? s3_xf_val[11:0]  : s3_w[19:8]
	};

	wire signed [11:0] s3_fma_ks = s3_fma_k;
	(* keep = "true" *) wire s3_ks_hi_pos = !s3_fma_ks[11] && (|s3_fma_ks[10:6]);
	(* keep = "true" *) wire s3_ks_gt49   = s3_ks_hi_pos || (!s3_fma_ks[11] && s3_fma_ks[5] && s3_fma_ks[4] && (|s3_fma_ks[3:1]));
	(* keep = "true" *) wire s3_ks_m26_hi = &s3_fma_ks[10:5];
	(* keep = "true" *) wire s3_ks_gtm26  = !s3_fma_ks[11] || (s3_ks_m26_hi && (s3_fma_ks[4] ? (|s3_fma_ks[3:1]) : (s3_fma_ks[3] && s3_fma_ks[2] && (|s3_fma_ks[1:0]))));
	wire fma3_kbig = !(s3_is_fract && s3_fract_ge1) && s3_ks_gt49;

	wire [76:0] fma3_csl;
	am_shift #(.W(77), .SW(7)) u_fma3_csl (.a({53'd0, s3_fma_mc_sh}), .amt(s3_cs_amt), .left(1'b1), .arith(1'b0), .y(fma3_csl));
	wire [23:0] fma3_csr;
	am_shift #(.W(24), .SW(5)) u_fma3_csr (.a(s3_fma_mc_sh), .amt(s3_fma_rs), .left(1'b0), .arith(1'b0), .y(fma3_csr));
	wire [23:0] fma3_cmk;
	am_shift #(.W(24), .SW(5)) u_fma3_cmk (.a(24'hFFFFFF), .amt(s3_fma_rs), .left(1'b1), .arith(1'b0), .y(fma3_cmk));
	wire fma3_cst = |(s3_fma_mc_sh & ~fma3_cmk);
	(* keep = "true" *) wire s3_fr_inc_lo = s3_fract_inc;
	(* keep = "true" *) wire s3_fr_inc_hi = s3_fract_inc;
	wire [76:0] fma3_cw_fract_ge1 = {
		27'd0,
		s3_fr_inc_hi ? fma3_mc_fr[23:12] : {1'b0, fma3_mc_fr[23:13]},
		s3_fr_inc_lo ? {fma3_mc_fr[11:0], 1'b0} : fma3_mc_fr[12:0],
		25'd0
	};
	wire [76:0] fma3_cw;
	genvar gc3;
	generate
	for (gc3 = 0; gc3 < 10; gc3 = gc3 + 1) begin : g_fma3_cw
		localparam CW_SL = (gc3 == 9) ? 5 : 8;
		(* dont_touch = "true" *) wire zc_sl = s3_noc || (s3_is_fract ? (!s3_fl_nan && (s3_fl_pass ? s3_xf_ez : !s3_nz)) : s3_c_ez);
		(* dont_touch = "true" *) wire fr_sl = !s3_noc && s3_is_fract && s3_fract_ge1 && (s3_fl_nan || (s3_fl_pass ? !s3_xf_ez : s3_nz));
		(* dont_touch = "true" *) wire kb_sl = !(s3_is_fract && s3_fract_ge1) && s3_ks_gt49;
		(* dont_touch = "true" *) wire kl_sl = s3_cs_left_r[gc3 / 3];
		(* dont_touch = "true" *) wire kr_sl = (s3_is_fract && s3_fract_ge1) || s3_ks_gtm26;
		wire [76:0] cw_kb = {2'b00, s3_fma_mc_sh, 51'd0};
		wire [76:0] cw_kr = {53'd0, fma3_csr[23:1], fma3_csr[0] | fma3_cst};
		wire [76:0] cw_one = 77'd1;
		assign fma3_cw[gc3*8 +: CW_SL] = zc_sl ? {CW_SL{1'b0}} :
			fr_sl ? fma3_cw_fract_ge1[gc3*8 +: CW_SL] :
			kb_sl ? cw_kb[gc3*8 +: CW_SL] :
			kl_sl ? fma3_csl[gc3*8 +: CW_SL] :
			kr_sl ? cw_kr[gc3*8 +: CW_SL] : cw_one[gc3*8 +: CW_SL];
	end
	endgenerate
	wire fma3_same = fma3_zc || (fma3_sp == fma3_sc);

	/* Exact 0-CARRY4 replacement: ab + (c101 - ab) == c101 */
	(* keep = "true" *) wire fma3_use_p1 = !fma3_zc && fma3_kbig;
	(* keep = "true" *) wire [3:0] fma3_use_p1_rep = {4{!fma3_zc && fma3_kbig}};
	wire [11:0] fma3_t1 = fma3_use_p1 ? s3_fma_c101 : s3_fma_ab;

	wire fma3_spec_hit = s3_spec_nan || s3_spec_inf_ab || s3_spec_inf_c || s3_spec_zero;
	(* keep = "true" *) wire fma3_sp_nan_lo = s3_spec_nan || (s3_spec_inf_ab && s3_inf_c && (fma3_sc != fma3_sp));
	(* keep = "true" *) wire fma3_sp_nan_hi = s3_spec_nan || (s3_spec_inf_ab && s3_inf_c && (fma3_sc != fma3_sp));
	(* keep = "true" *) wire fma3_sp_inf_lo = !s3_spec_nan && s3_spec_inf_ab && !(s3_inf_c && (fma3_sc != fma3_sp));
	(* keep = "true" *) wire fma3_sp_inf_hi = !s3_spec_nan && s3_spec_inf_ab && !(s3_inf_c && (fma3_sc != fma3_sp));
	(* keep = "true" *) wire fma3_sp_c_lo   = !s3_spec_nan && !s3_spec_inf_ab && (s3_spec_inf_c || !fma3_zc);
	(* keep = "true" *) wire fma3_sp_c_hi   = !s3_spec_nan && !s3_spec_inf_ab && (s3_spec_inf_c || !fma3_zc);
	wire fma3_zero_sign = s3_noc ? fma3_sp : (fma3_rdn ? (fma3_sp | fma3_sc) : (fma3_sp & fma3_sc));
	wire [31:0] fma3_spec_res = {
		fma3_sp_nan_hi ? 16'h7FC0 : fma3_sp_inf_hi ? {fma3_sp, 8'hFF, 7'd0} : fma3_sp_c_hi ? fma3_c[31:16] : {fma3_zero_sign, 15'd0},
		fma3_sp_nan_lo ? 16'h0000 : fma3_sp_inf_lo ? 16'd0                  : fma3_sp_c_lo ? fma3_c[15:0]  : 16'd0
	};

	/* Stage 3: Pure-LUT fmin/fmax/fcmp using Stage 2 comparators (0 CARRY4) */
	(* keep = "true" *) wire s3_flt_ab_lo = (s3_xf_val[31] && !s3_bf_val[31]) || (!s3_xf_val[31] && !s3_bf_val[31] && s3_ab_lt) ||
		(s3_xf_val[31] && s3_bf_val[31] && s3_ba_lt);
	(* keep = "true" *) wire s3_flt_ab_hi = (s3_xf_val[31] && !s3_bf_val[31]) || (!s3_xf_val[31] && !s3_bf_val[31] && s3_ab_lt) ||
		(s3_xf_val[31] && s3_bf_val[31] && s3_ba_lt);
	(* keep = "true" *) wire s3_flt_ba_lo = (s3_bf_val[31] && !s3_xf_val[31]) || (!s3_bf_val[31] && !s3_xf_val[31] && s3_ba_lt) ||
		(s3_bf_val[31] && !s3_af_nan && s3_xf_val[31] && s3_ab_lt);
	(* keep = "true" *) wire s3_flt_ba_hi = (s3_bf_val[31] && !s3_xf_val[31]) || (!s3_bf_val[31] && !s3_xf_val[31] && s3_ba_lt) ||
		(s3_bf_val[31] && !s3_af_nan && s3_xf_val[31] && s3_ab_lt);
	(* keep = "true" *) wire s3_both_nan_lo = s3_af_nan && s3_bf_nan;
	(* keep = "true" *) wire s3_both_nan_hi = s3_af_nan && s3_bf_nan;
	(* keep = "true" *) wire s3_both_nan_min_lo = s3_both_nan_lo;
	(* keep = "true" *) wire s3_both_nan_max_lo = s3_both_nan_lo;
	(* keep = "true" *) wire s3_both_nan_min_hi = s3_both_nan_hi;
	(* keep = "true" *) wire s3_both_nan_max_hi = s3_both_nan_hi;
	(* keep = "true" *) wire s3_pick_b_min_lo = !s3_both_nan_lo && (s3_af_nan || (!s3_bf_nan && s3_flt_ba_lo));
	(* keep = "true" *) wire s3_pick_b_min_hi = !s3_both_nan_hi && (s3_af_nan || (!s3_bf_nan && s3_flt_ba_hi));
	(* keep = "true" *) wire s3_pick_b_max_lo = !s3_both_nan_lo && (s3_af_nan || (!s3_bf_nan && s3_flt_ab_lo));
	(* keep = "true" *) wire s3_pick_b_max_hi = !s3_both_nan_hi && (s3_af_nan || (!s3_bf_nan && s3_flt_ab_hi));
	(* keep = "true" *) wire [15:0] s3_fmin_lo = s3_both_nan_min_lo ? 16'h0000 : (s3_pick_b_min_lo ? s3_bf_val[15:0]  : s3_xf_val[15:0]);
	(* keep = "true" *) wire [15:0] s3_fmin_hi = s3_both_nan_min_hi ? 16'h7FC0 : (s3_pick_b_min_hi ? s3_bf_val[31:16] : s3_xf_val[31:16]);
	(* keep = "true" *) wire [15:0] s3_fmax_lo = s3_both_nan_max_lo ? 16'h0000 : (s3_pick_b_max_lo ? s3_bf_val[15:0]  : s3_xf_val[15:0]);
	(* keep = "true" *) wire [15:0] s3_fmax_hi = s3_both_nan_max_hi ? 16'h7FC0 : (s3_pick_b_max_hi ? s3_bf_val[31:16] : s3_xf_val[31:16]);
	wire s3_un = s3_af_nan || s3_bf_nan;
	wire s3_lt_cmp = !s3_ab_eq && s3_flt_ab_lo;

	reg s3_cmp_bit;
	always @(*) begin
		case (s3_op)
		OP_FEQ:  s3_cmp_bit = !s3_un && s3_ab_eq;
		OP_FLT:  s3_cmp_bit = !s3_un && s3_lt_cmp;
		OP_FLE:  s3_cmp_bit = !s3_un && (s3_lt_cmp || s3_ab_eq);
		default: s3_cmp_bit = s3_un || !s3_ab_eq;
		endcase
	end
	wire [4:0] s3_op_b0, s3_op_b1, s3_op_b2, s3_op_b3;
	wire s3_cmp_b0, s3_cmp_b1, s3_cmp_b2, s3_cmp_b3;
`ifdef SYNTH_KINTEX7
	genvar g_b;
	for (g_b = 0; g_b < 5; g_b = g_b + 1) begin: g_buf_opb
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b0 (.I0(s3_op[g_b]), .O(s3_op_b0[g_b]));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b1 (.I0(s3_op[g_b]), .O(s3_op_b1[g_b]));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b2 (.I0(s3_op[g_b]), .O(s3_op_b2[g_b]));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b3 (.I0(s3_op[g_b]), .O(s3_op_b3[g_b]));
	end
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_cmp0 (.I0(s3_cmp_bit), .O(s3_cmp_b0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_cmp1 (.I0(s3_cmp_bit), .O(s3_cmp_b1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_cmp2 (.I0(s3_cmp_bit), .O(s3_cmp_b2));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_cmp3 (.I0(s3_cmp_bit), .O(s3_cmp_b3));
`else
	assign s3_op_b0 = s3_op;
	assign s3_op_b1 = s3_op;
	assign s3_op_b2 = s3_op;
	assign s3_op_b3 = s3_op;
	assign s3_cmp_b0 = s3_cmp_bit;
	assign s3_cmp_b1 = s3_cmp_bit;
	assign s3_cmp_b2 = s3_cmp_bit;
	assign s3_cmp_b3 = s3_cmp_bit;
`endif

	reg [7:0] s3_other_b0, s3_other_b1, s3_other_b2, s3_other_b3;
	reg s3_is_flt;
	always @(*) begin
		s3_other_b0 = 8'd0;
		case (s3_op_b0)
		OP_FSGNJ:              s3_other_b0 = s3_a[7:0];
		OP_FMIN:               s3_other_b0 = s3_fmin_lo[7:0];
		OP_FMAX:               s3_other_b0 = s3_fmax_lo[7:0];
		OP_FCVTWS, OP_FCVTWUS: s3_other_b0 = s3_ri[7:0];
		OP_FEQ, OP_FLT, OP_FLE, OP_FNE: s3_other_b0 = {8{s3_cmp_b0}};
		default: ;
		endcase
	end
	always @(*) begin
		s3_other_b1 = 8'd0;
		case (s3_op_b1)
		OP_FSGNJ:              s3_other_b1 = s3_a[15:8];
		OP_FMIN:               s3_other_b1 = s3_fmin_lo[15:8];
		OP_FMAX:               s3_other_b1 = s3_fmax_lo[15:8];
		OP_FCVTWS, OP_FCVTWUS: s3_other_b1 = s3_ri[15:8];
		OP_FEQ, OP_FLT, OP_FLE, OP_FNE: s3_other_b1 = {8{s3_cmp_b1}};
		default: ;
		endcase
	end
	always @(*) begin
		s3_other_b2 = 8'd0;
		case (s3_op_b2)
		OP_FSGNJ:              s3_other_b2 = s3_a[23:16];
		OP_FMIN:               s3_other_b2 = s3_fmin_hi[7:0];
		OP_FMAX:               s3_other_b2 = s3_fmax_hi[7:0];
		OP_FCVTWS, OP_FCVTWUS: s3_other_b2 = s3_ri[23:16];
		OP_FEQ, OP_FLT, OP_FLE, OP_FNE: s3_other_b2 = {8{s3_cmp_b2}};
		default: ;
		endcase
	end
	always @(*) begin
		s3_other_b3 = 8'd0;
		case (s3_op_b3)
		OP_FSGNJ:              s3_other_b3 = {s3_b[31], s3_a[30:24]};
		OP_FMIN:               s3_other_b3 = s3_fmin_hi[15:8];
		OP_FMAX:               s3_other_b3 = s3_fmax_hi[15:8];
		OP_FCVTWS, OP_FCVTWUS: s3_other_b3 = s3_ri[31:24];
		OP_FEQ, OP_FLT, OP_FLE, OP_FNE: s3_other_b3 = {8{s3_cmp_b3}};
		default: ;
		endcase
	end
	always @(*) begin
		s3_is_flt = 1'b1;
		case (s3_op)
		OP_FCVTWS, OP_FCVTWUS, OP_FEQ, OP_FLT, OP_FLE, OP_FNE,
		OP_MUL, OP_MULH, OP_MULHSU, OP_MULHU: s3_is_flt = 1'b0;
		default: ;
		endcase
	end
	wire [31:0] s3_other = {s3_other_b3, s3_other_b2, s3_other_b1, s3_other_b0};

	/* --- Stage 4 -> Stage 5 --- */
	(* shreg_extract = "no", keep = "true", equivalent_register_removal = "no", max_fanout = 12 *) reg [4:0] s4_op;
	(* shreg_extract = "no", keep = "true", equivalent_register_removal = "no", max_fanout = 12 *) reg [2:0] s4_rr;
	(* shreg_extract = "no", max_fanout = 12 *) reg s4_sat;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s4_other_pre;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s4_is_flt;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s4_iv;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s4_fl;
	(* shreg_extract = "no", max_fanout = 12 *) reg [76:0] s4_cw;
	(* shreg_extract = "no", max_fanout = 12 *) reg [11:0] s4_t1;
	(* shreg_extract = "no", max_fanout = 12 *) reg s4_same;
	(* shreg_extract = "no", max_fanout = 12 *) reg s4_sp;
	(* shreg_extract = "no", max_fanout = 12 *) reg s4_sc;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s4_rdn;
	(* shreg_extract = "no", keep = "true", equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] s4_use_p1_r;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s4_spec_hit;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s4_spec_res;

	always @(posedge clk) begin
		if (rst_p) begin
			s4_op        <= 5'd0;
			s4_sat       <= 1'b0;
			s4_rr        <= 3'd0;
			s4_other_pre <= 32'd0;
			s4_is_flt    <= 1'b0;
			s4_iv        <= 32'd0;
			s4_fl        <= 32'd0;
			s4_cw        <= 77'd0;
			s4_t1        <= 12'd0;
			s4_same      <= 1'b0;
			s4_sp        <= 1'b0;
			s4_sc        <= 1'b0;
			s4_rdn       <= 1'b0;
			s4_use_p1_r  <= 4'd0;
			s4_spec_hit  <= 1'b0;
			s4_spec_res  <= 32'd0;
		end else if (en) begin
			s4_op        <= s3_op;
			s4_sat       <= s3_sat;
			s4_rr        <= s3_rr;
			s4_other_pre <= s3_other;
			s4_is_flt    <= s3_is_flt;
			s4_iv        <= s3_iv;
			s4_fl        <= s3_fl;
			s4_cw        <= fma3_cw;
			s4_t1        <= fma3_t1;
			s4_same      <= fma3_same;
			s4_sp        <= fma3_sp;
			s4_sc        <= fma3_sc;
			s4_rdn       <= fma3_rdn;
			s4_use_p1_r  <= fma3_use_p1_rep;
			s4_spec_hit  <= fma3_spec_hit;
			s4_spec_res  <= fma3_spec_res;
		end
	end

	wire [76:0] s4_pw = {
		27'd0,
		s4_use_p1_r[3] ? 12'd0 : pr_s4[47:36],
		s4_use_p1_r[2] ? 12'd0 : pr_s4[35:24],
		s4_use_p1_r[1] ? 12'd0 : pr_s4[23:12],
		s4_use_p1_r[0] ? 14'd1 : {pr_s4[11:0], 2'b00}
	};
	wire [76:0] s4_sum_p_c, s4_sum_c_p;
	(* max_fanout = 16 *) wire s4_co_p_c;
	wire carry_unused_c_p;

	am_addsub #(.W(77)) u_fma_p_c (.a(s4_pw), .b(s4_cw), .sub(!s4_same), .s(s4_sum_p_c), .co(s4_co_p_c));
	am_sub #(.W(77))    u_fma_c_p (.a(s4_cw), .b(s4_pw), .bi(1'b0),       .d(s4_sum_c_p), .bo(carry_unused_c_p));

	(* max_fanout = 16 *) wire s4_pick_p_c = s4_same || s4_co_p_c;
	wire [76:0] s4_sum = s4_pick_p_c ? s4_sum_p_c : s4_sum_c_p;
	wire        s4_sr  = s4_pick_p_c ? s4_sp : s4_sc;
	wire        s4_fma = (s4_op <= OP_FNMADD) || (s4_op == OP_FRACT);

	wire [38:0] s4_or2;
	genvar gk2;
	generate
		for (gk2 = 0; gk2 < 38; gk2 = gk2 + 1) begin : g_s4_or2
			assign s4_or2[gk2] = s4_pick_p_c ? (|s4_sum_p_c[2*gk2+1:2*gk2]) : (|s4_sum_c_p[2*gk2+1:2*gk2]);
		end
	endgenerate
	assign s4_or2[38] = s4_pick_p_c ? s4_sum_p_c[76] : s4_sum_c_p[76];

	/* Split saturation helper for s4_spec_res (fanout <= 16) */
	(* keep = "true" *) wire s4_sp_m_nz_lo = |s4_spec_res[22:0];
	(* keep = "true" *) wire s4_sp_m_nz_hi = |s4_spec_res[22:0];
	(* keep = "true" *) wire s4_sp_e7f_lo  = &s4_spec_res[29:23];
	(* keep = "true" *) wire s4_sp_e7f_hi  = &s4_spec_res[29:23];
	(* keep = "true" *) wire s4_sp_nan_lo  = s4_spec_res[30] && s4_sp_e7f_lo && s4_sp_m_nz_lo;
	(* keep = "true" *) wire s4_sp_nan_hi  = s4_spec_res[30] && s4_sp_e7f_hi && s4_sp_m_nz_hi;
	(* keep = "true" *) wire s4_sp_gt1_lo  = s4_spec_res[30] || (s4_sp_e7f_lo && s4_sp_m_nz_lo);
	(* keep = "true" *) wire s4_sp_gt1_hi  = s4_spec_res[30] || (s4_sp_e7f_hi && s4_sp_m_nz_hi);
	(* keep = "true" *) wire s4_sp_z_lo = s4_sat && (s4_sp_nan_lo || s4_spec_res[31]);
	(* keep = "true" *) wire s4_sp_z_hi = s4_sat && (s4_sp_nan_hi || s4_spec_res[31]);
	(* keep = "true" *) wire s4_sp_o_lo = s4_sat && !s4_sp_nan_lo && !s4_spec_res[31] && s4_sp_gt1_lo;
	(* keep = "true" *) wire s4_sp_o_hi = s4_sat && !s4_sp_nan_hi && !s4_spec_res[31] && s4_sp_gt1_hi;
	wire [31:0] s4_spec_sat = {
		s4_sp_z_hi ? 16'd0 : (s4_sp_o_hi ? 16'h3F80 : s4_spec_res[31:16]),
		s4_sp_z_lo ? 16'd0 : (s4_sp_o_lo ? 16'h0000 : s4_spec_res[15:0])
	};

	/* Precompute block exponent bases eb0..eb5 in Stage 4 (pre=0, post=0 around CARRY4) */
	wire [11:0] s4_eb0, s4_eb1, s4_eb2, s4_eb3, s4_eb4, s4_eb5;
	wire [5:0]  carry_unused4_eb;
	am_sub #(.W(12)) u_eb0 (.a(s4_t1), .b(12'd175), .bi(1'b0), .d(s4_eb0), .bo(carry_unused4_eb[0]));
	am_sub #(.W(12)) u_eb1 (.a(s4_t1), .b(12'd159), .bi(1'b0), .d(s4_eb1), .bo(carry_unused4_eb[1]));
	am_sub #(.W(12)) u_eb2 (.a(s4_t1), .b(12'd143), .bi(1'b0), .d(s4_eb2), .bo(carry_unused4_eb[2]));
	am_sub #(.W(12)) u_eb3 (.a(s4_t1), .b(12'd127), .bi(1'b0), .d(s4_eb3), .bo(carry_unused4_eb[3]));
	am_sub #(.W(12)) u_eb4 (.a(s4_t1), .b(12'd111), .bi(1'b0), .d(s4_eb4), .bo(carry_unused4_eb[4]));
	am_sub #(.W(12)) u_eb5 (.a(s4_t1), .b(12'd95),  .bi(1'b0), .d(s4_eb5), .bo(carry_unused4_eb[5]));

	/* Stage 4: Non-multiplier other-result selection & float saturation (strictly <= 2 LUTs) */
	(* keep = "true" *) wire [4:0] s4_op_lo = s4_op;
	(* keep = "true" *) wire [4:0] s4_op_hi = s4_op;
	reg [15:0] s4_other_pre2_lo, s4_other_pre2_hi;
	always @(*) begin
		s4_other_pre2_lo = s4_other_pre[15:0];
		s4_other_pre2_hi = s4_other_pre[31:16];
		case (s4_op_lo)
		OP_FCVTSW, OP_FCVTSWU: s4_other_pre2_lo = s4_iv[15:0];
		OP_FROUND:             s4_other_pre2_lo = s4_fl[15:0];
		default: ;
		endcase
		case (s4_op_hi)
		OP_FCVTSW, OP_FCVTSWU: s4_other_pre2_hi = s4_iv[31:16];
		OP_FROUND:             s4_other_pre2_hi = s4_fl[31:16];
		default: ;
		endcase
	end
	wire [31:0] s4_other_pre2 = {s4_other_pre2_hi, s4_other_pre2_lo};

	(* keep = "true" *) wire s4_ot_m_nz_lo = |s4_other_pre2[22:0];
	(* keep = "true" *) wire s4_ot_m_nz_hi = |s4_other_pre2[22:0];
	(* keep = "true" *) wire s4_ot_e7f_lo  = &s4_other_pre2[29:23];
	(* keep = "true" *) wire s4_ot_e7f_hi  = &s4_other_pre2[29:23];
	(* keep = "true" *) wire s4_ot_nan_lo  = s4_other_pre2[30] && s4_ot_e7f_lo && s4_ot_m_nz_lo;
	(* keep = "true" *) wire s4_ot_nan_hi  = s4_other_pre2[30] && s4_ot_e7f_hi && s4_ot_m_nz_hi;
	(* keep = "true" *) wire s4_ot_gt1_lo  = s4_other_pre2[30] || (s4_ot_e7f_lo && s4_ot_m_nz_lo);
	(* keep = "true" *) wire s4_ot_gt1_hi  = s4_other_pre2[30] || (s4_ot_e7f_hi && s4_ot_m_nz_hi);
	(* keep = "true" *) wire s4_ot_z_lo = s4_sat && s4_is_flt && (s4_ot_nan_lo || s4_other_pre2[31]);
	(* keep = "true" *) wire s4_ot_z_hi = s4_sat && s4_is_flt && (s4_ot_nan_hi || s4_other_pre2[31]);
	(* keep = "true" *) wire s4_ot_o_lo = s4_sat && s4_is_flt && !s4_ot_nan_lo && !s4_other_pre2[31] && s4_ot_gt1_lo;
	(* keep = "true" *) wire s4_ot_o_hi = s4_sat && s4_is_flt && !s4_ot_nan_hi && !s4_other_pre2[31] && s4_ot_gt1_hi;
	(* keep = "true" *) wire [31:0] s4_other_sat = {
		s4_ot_z_hi ? 16'd0 : (s4_ot_o_hi ? 16'h3F80 : s4_other_pre2[31:16]),
		s4_ot_z_lo ? 16'd0 : (s4_ot_o_lo ? 16'h0000 : s4_other_pre2[15:0])
	};
	wire s4_is_mul  = (s4_op == OP_MUL);
	wire s4_is_mulh = (s4_op == OP_MULH) || (s4_op == OP_MULHSU) || (s4_op == OP_MULHU);

	/* --- Stage 5 -> Stage 6 --- */
	(* shreg_extract = "no", max_fanout = 12 *) reg [63:0] s5_pr;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s5_other_sat;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s5_is_mul;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s5_is_mulh;
	(* shreg_extract = "no", max_fanout = 12 *) reg [4:0]  s5_op;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s5_fma;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s5_sat;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s5_flt;
	(* shreg_extract = "no", max_fanout = 12 *) reg [76:0] s5_sum;
	(* shreg_extract = "no", max_fanout = 12 *) reg [38:0] s5_or2;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s5_sr;
	(* shreg_extract = "no", max_fanout = 12 *) reg [3:0]  s5_eb_lo;
	(* shreg_extract = "no", max_fanout = 12 *) reg [7:0]  s5_eb0_hi, s5_eb1_hi, s5_eb2_hi, s5_eb3_hi, s5_eb4_hi, s5_eb5_hi;
	(* shreg_extract = "no", max_fanout = 12 *) reg [2:0]  s5_rm;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s5_rdn;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s5_spec_hit;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s5_spec_res;

	always @(posedge clk) begin
		if (rst_p) begin
			s5_pr        <= 64'd0;
			s5_other_sat <= 32'd0;
			s5_is_mul    <= 1'b0;
			s5_is_mulh   <= 1'b0;
			s5_op        <= 5'd0;
			s5_fma       <= 1'b0;
			s5_sat       <= 1'b0;
			s5_flt       <= 1'b0;
			s5_sum       <= 77'd0;
			s5_or2       <= 39'd0;
			s5_sr        <= 1'b0;
			s5_eb_lo     <= 4'd0;
			s5_eb0_hi    <= 8'd0;
			s5_eb1_hi    <= 8'd0;
			s5_eb2_hi    <= 8'd0;
			s5_eb3_hi    <= 8'd0;
			s5_eb4_hi    <= 8'd0;
			s5_eb5_hi    <= 8'd0;
			s5_rm        <= 3'd0;
			s5_rdn       <= 1'b0;
			s5_spec_hit  <= 1'b0;
			s5_spec_res  <= 32'd0;
		end else if (en) begin
			s5_pr        <= pr_s4[63:0];
			s5_other_sat <= s4_other_sat;
			s5_is_mul    <= s4_is_mul;
			s5_is_mulh   <= s4_is_mulh;
			s5_op        <= s4_op;
			s5_fma       <= s4_fma;
			s5_sat       <= s4_sat;
			s5_flt       <= s4_is_flt;
			s5_sum       <= s4_sum;
			s5_or2       <= s4_or2;
			s5_sr        <= s4_sr;
			s5_eb_lo     <= s4_eb0[3:0];
			s5_eb0_hi    <= s4_eb0[11:4];
			s5_eb1_hi    <= s4_eb1[11:4];
			s5_eb2_hi    <= s4_eb2[11:4];
			s5_eb3_hi    <= s4_eb3[11:4];
			s5_eb4_hi    <= s4_eb4[11:4];
			s5_eb5_hi    <= s4_eb5[11:4];
			s5_rm        <= s4_rr;
			s5_rdn       <= s4_rdn;
			s5_spec_hit  <= s4_spec_hit;
			s5_spec_res  <= s4_spec_sat;
		end
	end

	/*
	 * Stage 5: Level-pinned parallel per-block LOD + local normalization (0 CARRY4, strictly <= 4 LUTs)
	 * Level 1: B_msb3, B_msb2, B_lo_nz, B_m1_hi/lo, B_m0_a/b/c, B_z_a/b, n_c2_0/1, p0..3_w, q0..6_w
	 * Level 2: B_msb1, B_msb0, b_sel1, b_sel0, SH_s1 (coarse shift by msb[3:2]), c2_0/1, c4_gen/prop, p/q_s1, st_base, B_nib
	 * Level 3: SH (fine shift by msb[1:0]), er0/er1, p/q_B, st_B
	 * Level 4: 4:1 mux over b4..b1 -> s5_m, s5_g, s5_st, s5_p0..3, s5_q0..6, s5_er, s5_er_p1, b0 flags
	 */
	function nib_c2;
		input [1:0] eb;
		input [2:0] x321;
		input ci;
		reg [1:0] m;
		reg c1;
		begin
			m = x321[2] ? 2'd3 : x321[1] ? 2'd2 : x321[0] ? 2'd1 : 2'd0;
			c1 = (eb[0] & m[0]) | ((eb[0] ^ m[0]) & ci);
			nib_c2 = (eb[1] & m[1]) | ((eb[1] ^ m[1]) & c1);
		end
	endfunction

	`define FPU_MSB16(B, X, H) \
		(* keep = "true" *) wire B``_msb3_a = |(H[7:4]); \
		(* keep = "true" *) wire B``_msb3_b = |(H[7:4]); \
		(* keep = "true" *) wire B``_msb3_c = |(H[7:4]); \
		(* keep = "true" *) wire B``_msb3_d = |(H[7:4]); \
		(* keep = "true" *) wire B``_msb3_e = |(H[7:4]); \
		(* keep = "true" *) wire B``_msb2_a = H[7] || H[6] || (!H[5] && !H[4] && (H[3] || H[2])); \
		(* keep = "true" *) wire B``_msb2_b = H[7] || H[6] || (!H[5] && !H[4] && (H[3] || H[2])); \
		(* keep = "true" *) wire B``_msb2_c = H[7] || H[6] || (!H[5] && !H[4] && (H[3] || H[2])); \
		(* keep = "true" *) wire B``_msb2_d = H[7] || H[6] || (!H[5] && !H[4] && (H[3] || H[2])); \
		(* keep = "true" *) wire B``_msb2_e = H[7] || H[6] || (!H[5] && !H[4] && (H[3] || H[2])); \
		(* keep = "true" *) wire B``_lo_nz  = |(H[3:0]); \
		(* keep = "true" *) wire B``_m1_hi  = (|X[15:14]) || (!(|X[13:12]) && (|X[11:10])); \
		(* keep = "true" *) wire B``_m1_lo  = (|X[7:6])   || (!(|X[5:4])   && (|X[3:2])); \
		(* keep = "true" *) wire B``_m0_a   = X[15] || (!X[14] && (X[13] || (!X[12] && X[11]))); \
		(* keep = "true" *) wire B``_z_a    = !(|X[15:11]); \
		(* keep = "true" *) wire B``_m0_b   = !X[10] && (X[9] || (!X[8] && (X[7] || (!X[6] && X[5])))); \
		(* keep = "true" *) wire B``_z_b    = !(|X[10:5]); \
		(* keep = "true" *) wire B``_m0_c   = !X[4] && (X[3] || (!X[2] && X[1])); \
		(* keep = "true" *) wire B``_msb1_a = B``_m1_hi || (!B``_msb3_c && B``_m1_lo); \
		(* keep = "true" *) wire B``_msb1_b = B``_m1_hi || (!B``_msb3_c && B``_m1_lo); \
		(* keep = "true" *) wire B``_msb1_c = B``_m1_hi || (!B``_msb3_c && B``_m1_lo); \
		(* keep = "true" *) wire B``_msb0_a = B``_m0_a || (B``_z_a && (B``_m0_b || (B``_z_b && B``_m0_c))); \
		(* keep = "true" *) wire B``_msb0_b = B``_m0_a || (B``_z_a && (B``_m0_b || (B``_z_b && B``_m0_c))); \
		(* keep = "true" *) wire B``_msb0_c = B``_m0_a || (B``_z_a && (B``_m0_b || (B``_z_b && B``_m0_c))); \
		(* keep = "true" *) wire nz_``B     = B``_msb3_c || B``_lo_nz; \
		(* keep = "true" *) wire [3:0] n_c2_0_``B = { \
			nib_c2(s5_eb_lo[1:0], X[15:13], 1'b0), \
			nib_c2(s5_eb_lo[1:0], X[11:9],  1'b0), \
			nib_c2(s5_eb_lo[1:0], X[7:5],   1'b0), \
			nib_c2(s5_eb_lo[1:0], X[3:1],   1'b0)  \
		}; \
		(* keep = "true" *) wire [3:0] n_c2_1_``B = { \
			nib_c2(s5_eb_lo[1:0], X[15:13], 1'b1), \
			nib_c2(s5_eb_lo[1:0], X[11:9],  1'b1), \
			nib_c2(s5_eb_lo[1:0], X[7:5],   1'b1), \
			nib_c2(s5_eb_lo[1:0], X[3:1],   1'b1)  \
		}; \
		(* keep = "true" *) wire c2_0_``B = B``_msb3_c ? (B``_msb2_c ? n_c2_0_``B[3] : n_c2_0_``B[2]) : (B``_msb2_c ? n_c2_0_``B[1] : n_c2_0_``B[0]); \
		(* keep = "true" *) wire c2_1_``B = B``_msb3_c ? (B``_msb2_c ? n_c2_1_``B[3] : n_c2_1_``B[2]) : (B``_msb2_c ? n_c2_1_``B[1] : n_c2_1_``B[0]); \
		(* keep = "true" *) wire c4_gen_``B  = (s5_eb_lo[3] & B``_msb3_c) | ((s5_eb_lo[3] ^ B``_msb3_c) & (s5_eb_lo[2] & B``_msb2_c)); \
		(* keep = "true" *) wire c4_prop_``B = (s5_eb_lo[3] ^ B``_msb3_c) & (s5_eb_lo[2] ^ B``_msb2_c);

	wire [15:0] blk4_in = {3'd0, s5_sum[76:64]};
	wire [15:0] blk3_in = s5_sum[63:48];
	wire [15:0] blk2_in = s5_sum[47:32];
	wire [15:0] blk1_in = s5_sum[31:16];
	wire [15:0] blk0_in = s5_sum[15:0];

	wire [7:0] blk4_h = {1'b0, s5_or2[38:32]};
	wire [7:0] blk3_h = s5_or2[31:24];
	wire [7:0] blk2_h = s5_or2[23:16];
	wire [7:0] blk1_h = s5_or2[15:8];
	wire [7:0] blk0_h = s5_or2[7:0];

	`FPU_MSB16(b4, blk4_in, blk4_h)
	`FPU_MSB16(b3, blk3_in, blk3_h)
	`FPU_MSB16(b2, blk2_in, blk2_h)
	`FPU_MSB16(b1, blk1_in, blk1_h)
	`FPU_MSB16(b0, blk0_in, blk0_h)
	`undef FPU_MSB16

	/* Replicated Level-2 block selects (fanout <= 16 each, 6 Level-1 inputs) */
	(* keep = "true" *) wire b_sel1_a = !b4_msb3_c && !b4_lo_nz && !b3_msb3_c && !b3_lo_nz;
	(* keep = "true" *) wire b_sel1_b = !b4_msb3_c && !b4_lo_nz && !b3_msb3_c && !b3_lo_nz;
	(* keep = "true" *) wire b_sel1_c = !b4_msb3_c && !b4_lo_nz && !b3_msb3_c && !b3_lo_nz;
	(* keep = "true" *) wire b_sel1_d = !b4_msb3_c && !b4_lo_nz && !b3_msb3_c && !b3_lo_nz;
	(* keep = "true" *) wire b_sel1_e = !b4_msb3_c && !b4_lo_nz && !b3_msb3_c && !b3_lo_nz;

	(* keep = "true" *) wire b_sel0_a = !b4_msb3_c && !b4_lo_nz && (b3_msb3_c || b3_lo_nz || (!b2_msb3_c && !b2_lo_nz));
	(* keep = "true" *) wire b_sel0_b = !b4_msb3_c && !b4_lo_nz && (b3_msb3_c || b3_lo_nz || (!b2_msb3_c && !b2_lo_nz));
	(* keep = "true" *) wire b_sel0_c = !b4_msb3_c && !b4_lo_nz && (b3_msb3_c || b3_lo_nz || (!b2_msb3_c && !b2_lo_nz));
	(* keep = "true" *) wire b_sel0_d = !b4_msb3_c && !b4_lo_nz && (b3_msb3_c || b3_lo_nz || (!b2_msb3_c && !b2_lo_nz));
	(* keep = "true" *) wire b_sel0_e = !b4_msb3_c && !b4_lo_nz && (b3_msb3_c || b3_lo_nz || (!b2_msb3_c && !b2_lo_nz));

	(* keep = "true" *) wire nz_b4321 = nz_b4 || nz_b3 || nz_b2 || nz_b1;

	wire [39:0] win4 = {3'b000, s5_sum[76:40]};
	wire [39:0] win3 = s5_sum[63:24];
	wire [39:0] win2 = s5_sum[47:8];
	wire [39:0] win1 = {s5_sum[31:0], 8'd0};
	wire [39:0] win0 = {s5_sum[15:0], 24'd0};

	/* Coarse shift by msb[3:2] at Level 2, fine shift by msb[1:0] at Level 3 */
	`define FPU_RSH40(SH, W, B) \
		(* keep = "true" *) wire [27:0] SH``_s1; \
		assign SH``_s1[13:0]  = B``_msb3_a ? (B``_msb2_a ? W[25:12] : W[21:8])  : (B``_msb2_a ? W[17:4]  : W[13:0]); \
		assign SH``_s1[27:14] = B``_msb3_b ? (B``_msb2_b ? W[39:26] : W[35:22]) : (B``_msb2_b ? W[31:18] : W[27:14]); \
		(* keep = "true" *) wire [24:0] SH; \
		assign SH[12:0]  = B``_msb1_a ? (B``_msb0_a ? SH``_s1[15:3]  : SH``_s1[14:2])  : (B``_msb0_a ? SH``_s1[13:1]  : SH``_s1[12:0]); \
		assign SH[24:13] = B``_msb1_b ? (B``_msb0_b ? SH``_s1[27:16] : SH``_s1[26:15]) : (B``_msb0_b ? SH``_s1[25:14] : SH``_s1[24:13]);

	`FPU_RSH40(win4_sh, win4, b4)
	`FPU_RSH40(win3_sh, win3, b3)
	`FPU_RSH40(win2_sh, win2, b2)
	`FPU_RSH40(win1_sh, win1, b1)
	`FPU_RSH40(win0_sh, win0, b0)
	`undef FPU_RSH40

	/* 4:1 mux over b4..b1 in Level 4 (1 LUT6 per bit) */
	wire [24:0] s5_mg;
	assign s5_mg[12:0]  = b_sel1_a ? (b_sel0_a ? win1_sh[12:0]  : win2_sh[12:0])  : (b_sel0_a ? win3_sh[12:0]  : win4_sh[12:0]);
	assign s5_mg[24:13] = b_sel1_b ? (b_sel0_b ? win1_sh[24:13] : win2_sh[24:13]) : (b_sel0_b ? win3_sh[24:13] : win4_sh[24:13]);
	wire [23:0] s5_m  = s5_mg[24:1];
	wire        s5_g  = s5_mg[0];

	/* Parallel per-block sticky bit (0 CARRY4, strictly <= 4 LUTs total) */
	(* keep = "true" *) wire st_t0 = |s5_or2[5:0];
	(* keep = "true" *) wire st_t1 = |s5_or2[11:6];
	(* keep = "true" *) wire st_t2 = |s5_or2[17:12];

	(* keep = "true" *) wire b4_sl_1 = s5_or2[19] || (s5_or2[38] && (|s5_or2[25:24] || |s5_or2[21:20]));
	(* keep = "true" *) wire b4_sl_2 = s5_or2[18] || ((|s5_or2[38:36]) && (|s5_or2[23:22]));
	(* keep = "true" *) wire b4_sl_3 = (|s5_or2[37:34]) && (|s5_or2[21:20]);
	(* keep = "true" *) wire b4_st_base = st_t0 || st_t1 || st_t2 || b4_sl_1 || b4_sl_2 || b4_sl_3;

	(* keep = "true" *) wire b3_sl_1 = (|s5_or2[31:30]) && (|s5_or2[17:16] || |s5_or2[13:12]);
	(* keep = "true" *) wire b3_sl_2 = (|s5_or2[31:28]) && (|s5_or2[15:14]);
	(* keep = "true" *) wire b3_sl_3 = (|s5_or2[29:26]) && (|s5_or2[13:12]);
	(* keep = "true" *) wire b3_st_base = st_t0 || st_t1 || b3_sl_1 || b3_sl_2 || b3_sl_3;

	(* keep = "true" *) wire b2_low12 = |s5_or2[9:4];
	(* keep = "true" *) wire b2_low8  = |s5_or2[7:4];
	(* keep = "true" *) wire b2_low4  = |s5_or2[5:4];
	(* keep = "true" *) wire b2_tail  = |s5_or2[3:0];
	(* keep = "true" *) wire b2_st_base = b2_tail || (b2_msb3_c ? (b2_msb2_c ? b2_low12 : b2_low8) : (b2_msb2_c ? b2_low4 : 1'b0));

	(* keep = "true" *) wire b1_low12 = |s5_or2[1:0];
	(* keep = "true" *) wire b1_st_base = b1_msb3_c && b1_msb2_c && b1_low12;

	`define FPU_ST_BLK(B, W) \
		(* keep = "true" *) wire [2:0] B``_nib = B``_msb3_c ? (B``_msb2_c ? W[14:12] : W[10:8]) : (B``_msb2_c ? W[6:4] : W[2:0]); \
		(* keep = "true" *) wire st_``B = B``_st_base || (B``_msb1_c ? (B``_msb0_c ? (|B``_nib[2:0]) : (|B``_nib[1:0])) : (B``_msb0_c ? B``_nib[0] : 1'b0));

	`FPU_ST_BLK(b4, win4)
	`FPU_ST_BLK(b3, win3)
	`FPU_ST_BLK(b2, win2)
	`FPU_ST_BLK(b1, win1)
	`undef FPU_ST_BLK

	wire s5_st = b_sel1_c ? (b_sel0_c ? st_b1 : st_b2) : (b_sel0_c ? st_b3 : st_b4);

	/* Parallel per-block exponent formation at Level 3 (0 CARRY4, 4 LUTs total) */
	`define FPU_EXP_BLK(B, HI1, HI0) \
		(* keep = "true" *) wire [11:0] er0_``B; \
		assign er0_``B[0]    = s5_eb_lo[0] ^ B``_msb0_c; \
		assign er0_``B[1]    = s5_eb_lo[1] ^ B``_msb1_c ^ (s5_eb_lo[0] & B``_msb0_c); \
		assign er0_``B[2]    = s5_eb_lo[2] ^ B``_msb2_c ^ c2_0_``B; \
		assign er0_``B[3]    = s5_eb_lo[3] ^ B``_msb3_c ^ ((s5_eb_lo[2] & B``_msb2_c) | ((s5_eb_lo[2] ^ B``_msb2_c) & c2_0_``B)); \
		assign er0_``B[11:4] = (c4_gen_``B || (c4_prop_``B && c2_0_``B)) ? HI1 : HI0; \
		(* keep = "true" *) wire [11:0] er1_``B; \
		assign er1_``B[0]    = ~(s5_eb_lo[0] ^ B``_msb0_c); \
		assign er1_``B[1]    = s5_eb_lo[1] ^ B``_msb1_c ^ (s5_eb_lo[0] | B``_msb0_c); \
		assign er1_``B[2]    = s5_eb_lo[2] ^ B``_msb2_c ^ c2_1_``B; \
		assign er1_``B[3]    = s5_eb_lo[3] ^ B``_msb3_c ^ ((s5_eb_lo[2] & B``_msb2_c) | ((s5_eb_lo[2] ^ B``_msb2_c) & c2_1_``B)); \
		assign er1_``B[11:4] = (c4_gen_``B || (c4_prop_``B && c2_1_``B)) ? HI1 : HI0;

	`FPU_EXP_BLK(b4, s5_eb5_hi, s5_eb4_hi)
	`FPU_EXP_BLK(b3, s5_eb4_hi, s5_eb3_hi)
	`FPU_EXP_BLK(b2, s5_eb3_hi, s5_eb2_hi)
	`FPU_EXP_BLK(b1, s5_eb2_hi, s5_eb1_hi)
	`undef FPU_EXP_BLK

	(* keep = "true" *) wire [7:0] er0_b0;
	assign er0_b0[0]   = s5_eb_lo[0] ^ b0_msb0_c;
	assign er0_b0[1]   = s5_eb_lo[1] ^ b0_msb1_c ^ (s5_eb_lo[0] & b0_msb0_c);
	assign er0_b0[2]   = s5_eb_lo[2] ^ b0_msb2_c ^ c2_0_b0;
	assign er0_b0[3]   = s5_eb_lo[3] ^ b0_msb3_c ^ ((s5_eb_lo[2] & b0_msb2_c) | ((s5_eb_lo[2] ^ b0_msb2_c) & c2_0_b0));
	assign er0_b0[7:4] = (c4_gen_b0 || (c4_prop_b0 && c2_0_b0)) ? s5_eb1_hi[3:0] : s5_eb0_hi[3:0];

	wire [11:0] s5_er, s5_er_p1;
	assign s5_er[3:0]     = b_sel1_c ? (b_sel0_c ? er0_b1[3:0]  : er0_b2[3:0])  : (b_sel0_c ? er0_b3[3:0]  : er0_b4[3:0]);
	assign s5_er[11:4]    = b_sel1_d ? (b_sel0_d ? er0_b1[11:4] : er0_b2[11:4]) : (b_sel0_d ? er0_b3[11:4] : er0_b4[11:4]);
	assign s5_er_p1[7:0]  = b_sel1_d ? (b_sel0_d ? er1_b1[7:0]  : er1_b2[7:0])  : (b_sel0_d ? er1_b3[7:0]  : er1_b4[7:0]);
	assign s5_er_p1[11:8] = b_sel1_e ? (b_sel0_e ? er1_b1[11:8] : er1_b2[11:8]) : (b_sel0_e ? er1_b3[11:8] : er1_b4[11:8]);

	/* Block 0 flags at Level 4 (strictly <= 4 LUTs) */
	wire b0_hi0_z1  = (s5_eb0_hi[3:0] == 4'd0), b0_hi0_z2  = (s5_eb0_hi[7:4] == 4'd0);
	wire b0_hi1_z1  = (s5_eb1_hi[3:0] == 4'd0), b0_hi1_z2  = (s5_eb1_hi[7:4] == 4'd0);
	wire b0_hi0_f1  = (&s5_eb0_hi[3:0]),        b0_hi0_71  = (&s5_eb0_hi[2:0]) && !s5_eb0_hi[3];
	wire b0_hi1_f1  = (&s5_eb1_hi[3:0]),        b0_hi1_71  = (&s5_eb1_hi[2:0]) && !s5_eb1_hi[3];
	(* keep = "true" *) wire b0_hi0_z   = b0_hi0_z1 && b0_hi0_z2;
	(* keep = "true" *) wire b0_hi1_z   = b0_hi1_z1 && b0_hi1_z2;
	(* keep = "true" *) wire b0_hi0_gt0 = !s5_eb0_hi[7] && (|s5_eb0_hi[6:4]);
	(* keep = "true" *) wire b0_hi1_gt0 = !s5_eb1_hi[7] && (|s5_eb1_hi[6:4]);
	(* keep = "true" *) wire b0_hi0_f   = b0_hi0_f1 && b0_hi0_z2;
	(* keep = "true" *) wire b0_hi1_f   = b0_hi1_f1 && b0_hi1_z2;
	(* keep = "true" *) wire b0_hi0_ge8 = !s5_eb0_hi[7] && (|s5_eb0_hi[6:3]);
	(* keep = "true" *) wire b0_hi1_ge8 = !s5_eb1_hi[7] && (|s5_eb1_hi[6:3]);
	(* keep = "true" *) wire b0_hi0_7   = b0_hi0_71 && b0_hi0_z2;
	(* keep = "true" *) wire b0_hi1_7   = b0_hi1_71 && b0_hi1_z2;

	(* keep = "true" *) wire b0_hi_neg = (c4_gen_b0 || (c4_prop_b0 && c2_0_b0)) ? s5_eb1_hi[7] : s5_eb0_hi[7];
	(* keep = "true" *) wire b0_hi_z   = (c4_gen_b0 || (c4_prop_b0 && c2_0_b0)) ? b0_hi1_z     : b0_hi0_z;
	(* keep = "true" *) wire b0_hi_gt0 = (c4_gen_b0 || (c4_prop_b0 && c2_0_b0)) ? b0_hi1_gt0   : b0_hi0_gt0;
	(* keep = "true" *) wire b0_hi_f   = (c4_gen_b0 || (c4_prop_b0 && c2_0_b0)) ? b0_hi1_f     : b0_hi0_f;
	(* keep = "true" *) wire b0_hi_ge8 = (c4_gen_b0 || (c4_prop_b0 && c2_0_b0)) ? b0_hi1_ge8   : b0_hi0_ge8;
	(* keep = "true" *) wire b0_hi_7   = (c4_gen_b0 || (c4_prop_b0 && c2_0_b0)) ? b0_hi1_7     : b0_hi0_7;

	wire b0_udf = b0_hi_neg || (b0_hi_z && (er0_b0[3:0] == 4'd0));
	wire b0_ovf = b0_hi_gt0 || (b0_hi_f && (&er0_b0[3:0]));
	wire b0_ge1 = b0_hi_ge8 || (b0_hi_7 && (&er0_b0[3:0]));
	wire b0_ovf_max = (s5_rm == 3'd1 || s5_rm == 3'd5 || s5_rm == 3'd6 || (s5_rm == 3'd2 && !s5_sr) || (s5_rm == 3'd3 && s5_sr));
	wire s5_use_b0  = s5_fma && !s5_spec_hit && !nz_b4321 && nz_b0;

	(* keep = "true" *) wire s5_fma_lo = s5_fma;
	(* keep = "true" *) wire s5_fma_hi = s5_fma;
	(* keep = "true" *) wire s5_sp_hit_lo = s5_spec_hit;
	(* keep = "true" *) wire s5_sp_hit_hi = s5_spec_hit;
	(* keep = "true" *) wire s5_is_mul_lo = s5_is_mul;
	(* keep = "true" *) wire s5_is_mul_hi = s5_is_mul;
	(* keep = "true" *) wire s5_is_mulh_lo = s5_is_mulh;
	(* keep = "true" *) wire s5_is_mulh_hi = s5_is_mulh;

	wire [15:0] s5_zero_res_lo = 16'd0;
	wire [15:0] s5_zero_res_hi = s5_sat ? 16'd0 : {s5_rdn, 15'd0};
	wire [15:0] s5_fma_res_lo  = s5_sp_hit_lo ? s5_spec_res[15:0]  : s5_zero_res_lo;
	wire [15:0] s5_fma_res_hi  = s5_sp_hit_hi ? s5_spec_res[31:16] : s5_zero_res_hi;

	wire [15:0] s5_mul_res_lo  = s5_is_mul_lo  ? s5_pr[15:0]  : s5_pr[47:32];
	wire [15:0] s5_mul_res_hi  = s5_is_mul_hi  ? s5_pr[31:16] : s5_pr[63:48];
	wire [15:0] s5_non_fma_lo  = (s5_is_mul_lo || s5_is_mulh_lo) ? s5_mul_res_lo : s5_other_sat[15:0];
	wire [15:0] s5_non_fma_hi  = (s5_is_mul_hi || s5_is_mulh_hi) ? s5_mul_res_hi : s5_other_sat[31:16];

	wire [31:0] s5_ovr_res = {
		s5_fma_hi ? s5_fma_res_hi : s5_non_fma_hi,
		s5_fma_lo ? s5_fma_res_lo : s5_non_fma_lo
	};
	wire s5_ovr_hit = !s5_fma || s5_spec_hit || !nz_b4321;

	/* Precompute 4-bit / 6-bit group ANDs at Level 1..4 (strictly 4 LUTs total) */
	`define FPU_PQ_BLK(B, W) \
		(* keep = "true" *) wire [15:0] p0_w_``B, p1_w_``B, p2_w_``B, p3_w_``B; \
		(* keep = "true" *) wire [15:0] q0_w_``B, q2_w_``B, q4_w_``B, q6_w_``B; \
		genvar gs_``B; \
		generate \
			for (gs_``B = 0; gs_``B < 16; gs_``B = gs_``B + 1) begin : g_pq_``B \
				assign p0_w_``B[gs_``B] = &W[gs_``B+6  : gs_``B+1];  \
				assign p1_w_``B[gs_``B] = &W[gs_``B+12 : gs_``B+7];  \
				assign p2_w_``B[gs_``B] = &W[gs_``B+18 : gs_``B+13]; \
				assign p3_w_``B[gs_``B] = &W[gs_``B+24 : gs_``B+19]; \
				assign q0_w_``B[gs_``B] = &W[gs_``B+4  : gs_``B+1];  \
				assign q2_w_``B[gs_``B] = &W[gs_``B+10 : gs_``B+7];  \
				assign q4_w_``B[gs_``B] = &W[gs_``B+16 : gs_``B+13]; \
				assign q6_w_``B[gs_``B] = &W[gs_``B+22 : gs_``B+19]; \
			end \
		endgenerate \
		(* keep = "true" *) wire [3:0] p0_s1_``B = B``_msb3_d ? (B``_msb2_d ? p0_w_``B[15:12] : p0_w_``B[11:8]) : (B``_msb2_d ? p0_w_``B[7:4] : p0_w_``B[3:0]); \
		(* keep = "true" *) wire [3:0] p1_s1_``B = B``_msb3_d ? (B``_msb2_d ? p1_w_``B[15:12] : p1_w_``B[11:8]) : (B``_msb2_d ? p1_w_``B[7:4] : p1_w_``B[3:0]); \
		(* keep = "true" *) wire [3:0] p2_s1_``B = B``_msb3_d ? (B``_msb2_d ? p2_w_``B[15:12] : p2_w_``B[11:8]) : (B``_msb2_d ? p2_w_``B[7:4] : p2_w_``B[3:0]); \
		(* keep = "true" *) wire [3:0] p3_s1_``B = B``_msb3_d ? (B``_msb2_d ? p3_w_``B[15:12] : p3_w_``B[11:8]) : (B``_msb2_d ? p3_w_``B[7:4] : p3_w_``B[3:0]); \
		(* keep = "true" *) wire [3:0] q0_s1_``B = B``_msb3_e ? (B``_msb2_e ? q0_w_``B[15:12] : q0_w_``B[11:8]) : (B``_msb2_e ? q0_w_``B[7:4] : q0_w_``B[3:0]); \
		(* keep = "true" *) wire [3:0] q2_s1_``B = B``_msb3_e ? (B``_msb2_e ? q2_w_``B[15:12] : q2_w_``B[11:8]) : (B``_msb2_e ? q2_w_``B[7:4] : q2_w_``B[3:0]); \
		(* keep = "true" *) wire [3:0] q4_s1_``B = B``_msb3_e ? (B``_msb2_e ? q4_w_``B[15:12] : q4_w_``B[11:8]) : (B``_msb2_e ? q4_w_``B[7:4] : q4_w_``B[3:0]); \
		(* keep = "true" *) wire [3:0] q6_s1_``B = B``_msb3_e ? (B``_msb2_e ? q6_w_``B[15:12] : q6_w_``B[11:8]) : (B``_msb2_e ? q6_w_``B[7:4] : q6_w_``B[3:0]); \
		(* keep = "true" *) wire p0_``B = B``_msb1_c ? (B``_msb0_c ? p0_s1_``B[3] : p0_s1_``B[2]) : (B``_msb0_c ? p0_s1_``B[1] : p0_s1_``B[0]); \
		(* keep = "true" *) wire p1_``B = B``_msb1_c ? (B``_msb0_c ? p1_s1_``B[3] : p1_s1_``B[2]) : (B``_msb0_c ? p1_s1_``B[1] : p1_s1_``B[0]); \
		(* keep = "true" *) wire p2_``B = B``_msb1_c ? (B``_msb0_c ? p2_s1_``B[3] : p2_s1_``B[2]) : (B``_msb0_c ? p2_s1_``B[1] : p2_s1_``B[0]); \
		(* keep = "true" *) wire p3_``B = B``_msb1_c ? (B``_msb0_c ? p3_s1_``B[3] : p3_s1_``B[2]) : (B``_msb0_c ? p3_s1_``B[1] : p3_s1_``B[0]); \
		(* keep = "true" *) wire q0_``B = B``_msb1_c ? (B``_msb0_c ? q0_s1_``B[3] : q0_s1_``B[2]) : (B``_msb0_c ? q0_s1_``B[1] : q0_s1_``B[0]); \
		(* keep = "true" *) wire q2_``B = B``_msb1_c ? (B``_msb0_c ? q2_s1_``B[3] : q2_s1_``B[2]) : (B``_msb0_c ? q2_s1_``B[1] : q2_s1_``B[0]); \
		(* keep = "true" *) wire q4_``B = B``_msb1_c ? (B``_msb0_c ? q4_s1_``B[3] : q4_s1_``B[2]) : (B``_msb0_c ? q4_s1_``B[1] : q4_s1_``B[0]); \
		(* keep = "true" *) wire q6_``B = B``_msb1_c ? (B``_msb0_c ? q6_s1_``B[3] : q6_s1_``B[2]) : (B``_msb0_c ? q6_s1_``B[1] : q6_s1_``B[0]);

	`FPU_PQ_BLK(b4, win4)
	`FPU_PQ_BLK(b3, win3)
	`FPU_PQ_BLK(b2, win2)
	`FPU_PQ_BLK(b1, win1)
	`undef FPU_PQ_BLK

	wire s5_p0 = b_sel1_c ? (b_sel0_c ? p0_b1 : p0_b2) : (b_sel0_c ? p0_b3 : p0_b4);
	wire s5_p1 = b_sel1_c ? (b_sel0_c ? p1_b1 : p1_b2) : (b_sel0_c ? p1_b3 : p1_b4);
	wire s5_p2 = b_sel1_c ? (b_sel0_c ? p2_b1 : p2_b2) : (b_sel0_c ? p2_b3 : p2_b4);
	wire s5_p3 = b_sel1_c ? (b_sel0_c ? p3_b1 : p3_b2) : (b_sel0_c ? p3_b3 : p3_b4);

	wire s5_q0 = b_sel1_c ? (b_sel0_c ? q0_b1 : q0_b2) : (b_sel0_c ? q0_b3 : q0_b4);
	wire s5_q2 = b_sel1_c ? (b_sel0_c ? q2_b1 : q2_b2) : (b_sel0_c ? q2_b3 : q2_b4);
	wire s5_q4 = b_sel1_c ? (b_sel0_c ? q4_b1 : q4_b2) : (b_sel0_c ? q4_b3 : q4_b4);
	wire s5_q6 = b_sel1_c ? (b_sel0_c ? q6_b1 : q6_b2) : (b_sel0_c ? q6_b3 : q6_b4);

	wire s5_rm_dir     = (s5_rm == 3'd2 && s5_sr) || (s5_rm == 3'd3 && !s5_sr);
	wire s5_rm_rne_rna = (s5_rm == 3'd0 || s5_rm == 3'd4 || s5_rm == 3'd7);

	/* --- Stage 6: <= 3-LUT Rounding & Final Mux (0 CARRY4) --- */
	(* shreg_extract = "no", max_fanout = 12 *) reg        s6_ovr_hit;
	(* shreg_extract = "no", max_fanout = 12 *) reg [31:0] s6_ovr_res;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s6_use_b0;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s6_b0_udf, s6_b0_ovf, s6_b0_ge1, s6_b0_ovf_max;
	(* shreg_extract = "no", max_fanout = 12 *) reg [7:0]  s6_b0_er;
	(* shreg_extract = "no", max_fanout = 12 *) reg [14:0] s6_b0_m;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s6_sat;
	(* shreg_extract = "no", max_fanout = 12 *) reg [23:0] s6_m;
	(* shreg_extract = "no", max_fanout = 12 *) reg [11:0] s6_er, s6_er_p1;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s6_sr;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s6_g;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s6_st;
	(* shreg_extract = "no", max_fanout = 12 *) reg [2:0]  s6_rm;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s6_p0, s6_p1, s6_p2, s6_p3;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s6_q0, s6_q2, s6_q4, s6_q6;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s6_rm_dir, s6_rm_rne_rna;

	always @(posedge clk) begin
		if (rst_p) begin
			s6_ovr_hit    <= 1'b0;
			s6_ovr_res    <= 32'd0;
			s6_use_b0     <= 1'b0;
			s6_b0_udf     <= 1'b0;
			s6_b0_ovf     <= 1'b0;
			s6_b0_ge1     <= 1'b0;
			s6_b0_ovf_max <= 1'b0;
			s6_b0_er      <= 8'd0;
			s6_b0_m       <= 15'd0;
			s6_sat        <= 1'b0;
			s6_m          <= 24'd0;
			s6_er         <= 12'd0;
			s6_er_p1      <= 12'd0;
			s6_sr         <= 1'b0;
			s6_g          <= 1'b0;
			s6_st         <= 1'b0;
			s6_rm         <= 3'd0;
			s6_p0         <= 1'b0;
			s6_p1         <= 1'b0;
			s6_p2         <= 1'b0;
			s6_p3         <= 1'b0;
			s6_q0         <= 1'b0;
			s6_q2         <= 1'b0;
			s6_q4         <= 1'b0;
			s6_q6         <= 1'b0;
			s6_rm_dir     <= 1'b0;
			s6_rm_rne_rna <= 1'b0;
		end else if (en) begin
			s6_ovr_hit    <= s5_ovr_hit;
			s6_ovr_res    <= s5_ovr_res;
			s6_use_b0     <= s5_use_b0;
			s6_b0_udf     <= b0_udf;
			s6_b0_ovf     <= b0_ovf;
			s6_b0_ge1     <= b0_ge1;
			s6_b0_ovf_max <= b0_ovf_max;
			s6_b0_er      <= er0_b0;
			s6_b0_m       <= win0_sh[23:9];
			s6_sat        <= s5_sat;
			s6_m          <= s5_m;
			s6_er         <= s5_er;
			s6_er_p1      <= s5_er_p1;
			s6_sr         <= s5_sr;
			s6_g          <= s5_g;
			s6_st         <= s5_st;
			s6_rm         <= s5_rm;
			s6_p0         <= s5_p0;
			s6_p1         <= s5_p1;
			s6_p2         <= s5_p2;
			s6_p3         <= s5_p3;
			s6_q0         <= s5_q0;
			s6_q2         <= s5_q2;
			s6_q4         <= s5_q4;
			s6_q6         <= s5_q6;
			s6_rm_dir     <= s5_rm_dir;
			s6_rm_rne_rna <= s5_rm_rne_rna;
		end
	end

	/* Stage 6 Level 1: all nodes depend on <= 6 FFs (strictly 1 LUT6) */
	wire s6_gst = s6_g || s6_st;
	reg s6_up_comb;
	always @(*) begin
		case (s6_rm)
		3'd1, 3'd5, 3'd6: s6_up_comb = 1'b0;
		3'd2: s6_up_comb = s6_sr && s6_gst;
		3'd3: s6_up_comb = !s6_sr && s6_gst;
		3'd4: s6_up_comb = s6_g;
		default: s6_up_comb = s6_g && (s6_st || s6_m[0]);
		endcase
	end
	(* keep = "true", max_fanout = 16 *) wire s6_up_l1 = s6_up_comb;

	(* keep = "true" *) wire s6_c1_l1 = s6_m[0] && ((s6_rm_dir && (s6_g || s6_st)) || (s6_rm_rne_rna && s6_g));

	reg s6_m0_comb;
	always @(*) begin
		case (s6_rm)
		3'd1: s6_m0_comb = s6_m[0];
		3'd5, 3'd6: s6_m0_comb = s6_m[0] | s6_g | s6_st;
		3'd2: s6_m0_comb = s6_m[0] ^ (s6_sr && (s6_g || s6_st));
		3'd3: s6_m0_comb = s6_m[0] ^ (!s6_sr && (s6_g || s6_st));
		3'd4: s6_m0_comb = s6_m[0] ^ s6_g;
		default: s6_m0_comb = s6_m[0] ^ (s6_g && (s6_st || s6_m[0]));
		endcase
	end
	(* keep = "true" *) wire s6_m0_l1 = s6_m0_comb;

	(* keep = "true" *) wire s6_c4_l1      = s6_up_l1 & s6_q0;
	(* keep = "true" *) wire s6_c7_l1      = s6_up_l1 & s6_p0 & s6_m[6];
	(* keep = "true" *) wire s6_c10_l1     = s6_up_l1 & s6_p0 & s6_q2;
	(* keep = "true" *) wire s6_c13_l1     = s6_up_l1 & s6_p0 & s6_p1 & s6_m[12];
	(* keep = "true" *) wire s6_c16_l1     = s6_up_l1 & s6_p0 & s6_p1 & s6_q4;
	(* keep = "true" *) wire s6_c19_l1     = s6_up_l1 & s6_p0 & s6_p1 & s6_p2 & s6_m[18];
	(* keep = "true" *) wire s6_c22_l1     = s6_up_l1 & s6_p0 & s6_p1 & s6_p2 & s6_q6;
	(* keep = "true", max_fanout = 16 *) wire s6_m_carry_l1 = s6_up_l1 & s6_p0 & s6_p1 & s6_p2 & s6_p3;

	/* Block 0 header & mantissa controls in Stage 6 Level 1 (<= 6 FFs each) */
	(* keep = "true" *) wire [8:0] s6_b0_hdr_l1 = s6_sat ?
		((s6_sr || s6_b0_udf) ? 9'd0 : (s6_b0_ovf || s6_b0_ge1) ? 9'h07F : {1'b0, s6_b0_er}) :
		(s6_b0_ovf ? (s6_b0_ovf_max ? {s6_sr, 8'hFE} : {s6_sr, 8'hFF}) : s6_b0_udf ? {s6_sr, 8'd0} : {s6_sr, s6_b0_er});
	(* keep = "true", max_fanout = 16 *) wire s6_b0_m_zero_l1 = s6_b0_udf || (s6_sat ? (s6_sr || s6_b0_ovf || s6_b0_ge1) : (s6_b0_ovf && !s6_b0_ovf_max));
	(* keep = "true", max_fanout = 16 *) wire s6_b0_m_ones_l1 = !s6_sat && s6_b0_ovf && s6_b0_ovf_max;

	(* keep = "true" *) wire [31:0] s6_ovr_l2 = {
		s6_use_b0 ? s6_b0_hdr_l1 : s6_ovr_res[31:23],
		s6_use_b0 ? (s6_b0_m_zero_l1 ? 15'd0 : s6_b0_m_ones_l1 ? 15'h7FFF : s6_b0_m) : s6_ovr_res[22:8],
		s6_use_b0 ? {8{s6_b0_m_ones_l1}} : s6_ovr_res[7:0]
	};

	/* Exponent flags for s6_m_carry_l1 == 0 and s6_m_carry_l1 == 1 in Level 1 */
	wire s6_ovf_0 = !s6_er[11]    && ((|s6_er[10:8])    || (&s6_er[7:0]));
	wire s6_ovf_1 = !s6_er_p1[11] && ((|s6_er_p1[10:8]) || (&s6_er_p1[7:0]));
	wire s6_udf_0 = s6_er[11]     || !(|s6_er[10:0]);
	wire s6_udf_1 = s6_er_p1[11]  || !(|s6_er_p1[10:0]);
	wire s6_ge1_0 = !s6_er[11]    && ((|s6_er[10:7])    || (&s6_er[6:0]));
	wire s6_ge1_1 = !s6_er_p1[11] && ((|s6_er_p1[10:7]) || (&s6_er_p1[6:0]));

	(* keep = "true" *) wire s6_e0_hi_f = s6_er[11]    || (|s6_er[10:7]);
	(* keep = "true" *) wire s6_e0_lo_f = s6_er[11]    || (|s6_er[10:8])    || (s6_er[6:0] == 7'h7F) || (!s6_er[7] && (s6_er[6:0] == 7'd0));
	(* keep = "true" *) wire s6_e1_hi_f = s6_er_p1[11] || (|s6_er_p1[10:7]);
	(* keep = "true" *) wire s6_e1_lo_f = s6_er_p1[11] || (|s6_er_p1[10:8]) || (s6_er_p1[6:0] == 7'h7F) || (!s6_er_p1[7] && (s6_er_p1[6:0] == 7'd0));

	wire s6_ovf_max = (s6_rm == 3'd1 || s6_rm == 3'd5 || s6_rm == 3'd6 || (s6_rm == 3'd2 && !s6_sr) || (s6_rm == 3'd3 && s6_sr));
	wire [8:0] s6_ovf_hdr0 = s6_ovf_max ? {s6_sr, 8'hFE} : {s6_sr, 8'hFF};

	(* keep = "true" *) wire [8:0] s6_hdr_0_l1 = s6_sat ?
		((s6_sr || s6_udf_0) ? 9'd0 : (s6_ovf_0 || s6_ge1_0) ? 9'h07F : {1'b0, s6_er[7:0]}) :
		(s6_ovf_0 ? s6_ovf_hdr0 : s6_udf_0 ? {s6_sr, 8'd0} : {s6_sr, s6_er[7:0]});

	/* Note: when s6_m_carry_l1 == 1, s6_up_l1 == 1 so s6_ovf_max is ALWAYS 0 */
	(* keep = "true" *) wire [8:0] s6_hdr_1_l1 = s6_sat ?
		((s6_sr || s6_udf_1) ? 9'd0 : (s6_ovf_1 || s6_ge1_1) ? 9'h07F : {1'b0, s6_er_p1[7:0]}) :
		(s6_ovf_1 ? {s6_sr, 8'hFF} : s6_udf_1 ? {s6_sr, 8'd0} : {s6_sr, s6_er_p1[7:0]});

	/* Mantissa control decoded into 2 bits: 00 = m_rnd, 01 = 0, 10 = all-1s (ovf_max) */
	wire s6_zero_m0 = s6_sat ? (s6_sr || s6_udf_0 || s6_ovf_0 || s6_ge1_0) : (s6_udf_0 || (s6_ovf_0 && !s6_ovf_max));
	wire s6_ones_m0 = !s6_sat && s6_ovf_0 && s6_ovf_max;
	(* keep = "true", max_fanout = 16 *) wire s6_mc_zero_l1 = !s6_ovr_hit && s6_zero_m0;
	(* keep = "true", max_fanout = 16 *) wire s6_mc_ovr_l1  = s6_ovr_hit || s6_ones_m0;

	/* Stage 6 Level 2: final 32-bit output (strictly <= 6 Level-1 inputs per bit = 1 LUT6) */
	wire [22:0] s6_m_rnd;
	assign s6_m_rnd[0]  = s6_m0_l1;
	assign s6_m_rnd[1]  = s6_m[1]  ^ s6_c1_l1;
	assign s6_m_rnd[2]  = s6_m[2]  ^ (s6_c1_l1  & s6_m[1]);
	assign s6_m_rnd[3]  = s6_m[3]  ^ (s6_c1_l1  & s6_m[1]  & s6_m[2]);
	assign s6_m_rnd[4]  = s6_m[4]  ^ s6_c4_l1;
	assign s6_m_rnd[5]  = s6_m[5]  ^ (s6_c4_l1  & s6_m[4]);
	assign s6_m_rnd[6]  = s6_m[6]  ^ (s6_c4_l1  & s6_m[4]  & s6_m[5]);
	assign s6_m_rnd[7]  = s6_m[7]  ^ s6_c7_l1;
	assign s6_m_rnd[8]  = s6_m[8]  ^ (s6_c7_l1  & s6_m[7]);
	assign s6_m_rnd[9]  = s6_m[9]  ^ (s6_c7_l1  & s6_m[7]  & s6_m[8]);
	assign s6_m_rnd[10] = s6_m[10] ^ s6_c10_l1;
	assign s6_m_rnd[11] = s6_m[11] ^ (s6_c10_l1 & s6_m[10]);
	assign s6_m_rnd[12] = s6_m[12] ^ (s6_c10_l1 & s6_m[10] & s6_m[11]);
	assign s6_m_rnd[13] = s6_m[13] ^ s6_c13_l1;
	assign s6_m_rnd[14] = s6_m[14] ^ (s6_c13_l1 & s6_m[13]);
	assign s6_m_rnd[15] = s6_m[15] ^ (s6_c13_l1 & s6_m[13] & s6_m[14]);
	assign s6_m_rnd[16] = s6_m[16] ^ s6_c16_l1;
	assign s6_m_rnd[17] = s6_m[17] ^ (s6_c16_l1 & s6_m[16]);
	assign s6_m_rnd[18] = s6_m[18] ^ (s6_c16_l1 & s6_m[16] & s6_m[17]);
	assign s6_m_rnd[19] = s6_m[19] ^ s6_c19_l1;
	assign s6_m_rnd[20] = s6_m[20] ^ (s6_c19_l1 & s6_m[19]);
	assign s6_m_rnd[21] = s6_m[21] ^ (s6_c19_l1 & s6_m[19] & s6_m[20]);
	assign s6_m_rnd[22] = s6_m[22] ^ s6_c22_l1;

	wire [8:0]  res_hdr = s6_ovr_hit ? s6_ovr_l2[31:23] : (s6_m_carry_l1 ? s6_hdr_1_l1 : s6_hdr_0_l1);
	wire [22:0] res_man = s6_mc_zero_l1 ? 23'd0 :
		(s6_mc_ovr_l1 ? (s6_ovr_hit ? s6_ovr_l2[22:0] : 23'h7FFFFF) : s6_m_rnd);
	assign res = {res_hdr, res_man};

	wire unused_core_ok = &{1'b0, carry_unused0_neg, carry_unused1_qp1, s1_fma_carry_unused,
		unused_ab_d2, unused_ba_d2, s2_fma_sub_carry_unused,
		carry_unused3_mr, carry_unused3_f2i,
		carry_unused_c_p, carry_unused4_eb,
		s3_e[11:8], s3_e_p1[11:8], pr_s4[65:64],
		s5_or2[31:26], c2_1_b0,
		win0_sh[24], win0_sh[8:0],
		s6_e0_hi_f, s6_e0_lo_f, s6_e1_hi_f, s6_e1_lo_f};
endmodule

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

	(* dont_touch = "true" *) wire rst_p = !rst_n;

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
			am_fpu_core #(.LAT(4)) u_core (
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
			wire [4:0]  sim_op  = op;
			wire [2:0]  sim_rm  = rm;
			wire        sim_sat = sat;
			wire [31:0] sim_a   = x_a[gl*32 +: 32];
			wire [31:0] sim_b   = x_b[gl*32 +: 32];
			wire [31:0] sim_c   = x_c[gl*32 +: 32];
`endif
			atg_su_fpu_core u_core (
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
