/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_pk_half_tb: atg_su_pk_half (ARITH 1 FP 1, ARITH 1 FP 0 and
 * ARITH 0) against the testbench's own reference: the former functions
 * atg_su_hrnd, atg_su_hfma and atg_su_f2h of include/atg_su_fp16.vh and
 * atg_su_pk's former function half (tools/gsi1fp.py).  Every operation
 * and rounding mode on random halves whose exponents are chosen to reach
 * every alignment of the fma (the addend far above, near, below and far
 * below the product), cancellations (a - a, a * b - a * b's neighbours),
 * zeros, denormals, infinities and NaNs, and random fp32 for packh.
 * Prints PASS atg_su_pk_half.fma (the fused operations), .other (the
 * rest) and PASS atg_su_pk_half; the seed is +seed, +n=N the vectors
 * (default 100,000).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_pk_half_tb;
`include "atg_su_uop.vh"
`include "atg_su_fp.vh"
`include "atg_su_fp16.vh"

	integer seed = 1;
	integer n = 100000;
	integer i, err_f = 0, err_o = 0;
	reg [3:0] o;
	reg [15:0] a, b, c;
	reg [2:0] r;
	reg st;
	reg [31:0] x;
	wire [15:0] y11, y10, y0;

	atg_su_pk_half #(.ARITH(1), .FP(1)) d11 (.o(o), .ha(a), .hb(b), .hc(c), .r(r), .sat(st), .xw(x), .y(y11));
	atg_su_pk_half #(.ARITH(1), .FP(0)) d10 (.o(o), .ha(a), .hb(b), .hc(c), .r(r), .sat(st), .xw(x), .y(y10));
	atg_su_pk_half #(.ARITH(0), .FP(1)) d0 (.o(o), .ha(a), .hb(b), .hc(c), .r(r), .sat(st), .xw(x), .y(y0));

	/* ---- the reference: the former functions */
	function [15:0] ref_hrnd;
		input s;
		input signed [9:0] e;
		input [10:0] m;
		input g, st;
		input [2:0] rm;
		reg up;
		reg [11:0] mr;
		reg signed [9:0] er;
		begin
			case (rm)
			3'd1: up = 1'b0;
			3'd2: up = s && (g || st);
			3'd3: up = !s && (g || st);
			3'd4: up = g;
			default: up = g && (st || m[0]);
			endcase
			mr = {1'b0, m} + {11'd0, up};
			er = e;
			if (mr[11]) begin
				mr = mr >> 1;
				er = er + 10'sd1;
			end
			if (er >= 10'sd31) begin
				if (rm == 3'd1 || (rm == 3'd2 && !s) || (rm == 3'd3 && s))
					ref_hrnd = {s, 5'h1E, 10'h3FF};
				else
					ref_hrnd = {s, 5'h1F, 10'd0};
			end else if (er <= 10'sd0)
				ref_hrnd = {s, 15'd0};
			else
				ref_hrnd = {s, er[4:0], mr[9:0]};
		end
	endfunction
	function [15:0] ref_hfma;
		input [15:0] a0, b0, c0;
		input [2:0] rm;
		input noc;
		reg [15:0] a, b, c;
		reg sp, sc, nan_a, nan_b, nan_c, inf_a, inf_b, inf_c, za, zb, zc, rdn, sr;
		reg [10:0] ma, mb, mc;
		reg [21:0] p;
		reg signed [9:0] k, adj, er;
		reg [3:0] rs;
		reg [36:0] pw, cw, sum, nrm;
		reg [5:0] msb;
		integer i;
		begin
			a = atg_su_hflush(a0);
			b = atg_su_hflush(b0);
			c = atg_su_hflush(c0);
			sp = a[15] ^ b[15];
			sc = c[15];
			rdn = rm == 3'd2;
			nan_a = a[14:10] == 5'h1F && a[9:0] != 0;
			nan_b = b[14:10] == 5'h1F && b[9:0] != 0;
			nan_c = !noc && c[14:10] == 5'h1F && c[9:0] != 0;
			inf_a = a[14:10] == 5'h1F && a[9:0] == 0;
			inf_b = b[14:10] == 5'h1F && b[9:0] == 0;
			inf_c = !noc && c[14:10] == 5'h1F && c[9:0] == 0;
			za = a[14:10] == 5'd0;
			zb = b[14:10] == 5'd0;
			zc = noc || c[14:10] == 5'd0;
			ma = {!za, a[9:0]};
			mb = {!zb, b[9:0]};
			mc = zc ? 11'd0 : {1'b1, c[9:0]};
			ref_hfma = 16'd0;
			if (nan_a || nan_b || nan_c || (inf_a && zb) || (inf_b && za))
				ref_hfma = 16'h7E00;
			else if (inf_a || inf_b)
				ref_hfma = inf_c && sc != sp ? 16'h7E00 : {sp, 5'h1F, 10'd0};
			else if (inf_c)
				ref_hfma = c;
			else if (za || zb) begin
				if (!zc)
					ref_hfma = c;
				else if (noc)
					ref_hfma = {sp, 15'd0};
				else
					ref_hfma = {rdn ? (sp | sc) : (sp & sc), 15'd0};
			end else begin
				p = ma * mb;
				k = {5'd0, c[14:10]} - {5'd0, a[14:10]} - {5'd0, b[14:10]} + 10'sd25;
				adj = 10'sd0;
				pw = {13'd0, p, 2'b00};
				cw = 37'd0;
				if (!zc) begin
					if (k > 10'sd23) begin
						adj = k - 10'sd23;
						cw = {1'b0, mc, 25'd0};
						pw = {36'd0, 1'b1};
					end else if (k >= -10'sd2)
						cw = {26'd0, mc} << (k + 10'sd2);
					else if (k > -10'sd13) begin
						rs = 4'd0 - k[3:0] - 4'd2;	/* 1..10 */
						cw = {26'd0, mc} >> rs;
						cw[0] = cw[0] | |(mc & ~(11'h7FF << rs));
					end else
						cw = 37'd1;
				end
				sr = sp;
				if (zc || sp == sc)
					sum = pw + cw;
				else if (pw >= cw)
					sum = pw - cw;
				else begin
					sum = cw - pw;
					sr = sc;
				end
				if (sum == 37'd0)
					ref_hfma = {rdn, 15'd0};
				else begin
					msb = 6'd0;
					for (i = 0; i < 37; i = i + 1)
						if (sum[i])
							msb = i[5:0];
					nrm = sum << (6'd36 - msb);
					er = {4'd0, msb} + {5'd0, a[14:10]} + {5'd0, b[14:10]} + adj - 10'sd37;
					ref_hfma = ref_hrnd(sr, er, nrm[36:26], nrm[25], |nrm[24:0], rm);
				end
			end
		end
	endfunction
	function [15:0] ref_f2h;
		input [31:0] x0;
		reg [31:0] x;
		begin
			x = atg_su_flush(x0);
			if (x[30:23] == 8'hFF)
				ref_f2h = x[22:0] != 0 ? 16'h7E00 : {x[31], 5'h1F, 10'd0};
			else if (x[30:23] == 8'd0)
				ref_f2h = {x[31], 15'd0};
			else
				ref_f2h = ref_hrnd(x[31], {2'd0, x[30:23]} - 10'sd112, {1'b1, x[22:13]},
					x[12], |x[11:0], 3'd0);
		end
	endfunction

	function [15:0] ref_half;
		input [3:0] o;
		input [15:0] a, b, c;
		input [2:0] r;
		input st;
		input sh;
		reg [15:0] y, fy, fz, ca, cb;
		reg fnoc;
		reg [1:0] cop;
		begin
			fy = 16'h3C00;
			fz = b;
			fnoc = 1'b0;
			case (o)
			ATG_PK_FSUB2[3:0]: fz = {!b[15], b[14:0]};
			ATG_PK_FMUL2[3:0]: begin
				fy = b;
				fz = 16'd0;
				fnoc = 1'b1;
			end
			ATG_PK_FFMA2[3:0]: begin
				fy = b;
				fz = c;
			end
			default: ;
			endcase
			ca = a;
			cb = b;
			case (o)
			ATG_PK_FCMPLT2[3:0]: cop = 2'd1;
			ATG_PK_FCMPGE2[3:0]: begin
				ca = b;
				cb = a;
				cop = 2'd2;
			end
			ATG_PK_FCMPEQ2[3:0]: cop = 2'd0;
			default: cop = 2'd3;
			endcase
			case (o)
			ATG_PK_FADD2[3:0], ATG_PK_FSUB2[3:0], ATG_PK_FMUL2[3:0], ATG_PK_FFMA2[3:0]:
				y = sh ? 16'd0 : ref_hfma(a, fy, fz, r, fnoc);
			ATG_PK_FMIN2[3:0]: y = sh ? 16'd0 : atg_su_hminmax(a, b, 1'b0);
			ATG_PK_FMAX2[3:0]: y = sh ? 16'd0 : atg_su_hminmax(a, b, 1'b1);
			ATG_PK_IADD2[3:0]: y = a + b;
			ATG_PK_ISUB2[3:0]: y = a - b;
			ATG_PK_IMUL2[3:0]: y = a * b;
			ATG_PK_FCMPLT2[3:0], ATG_PK_FCMPGE2[3:0], ATG_PK_FCMPEQ2[3:0], ATG_PK_FCMPNE2[3:0]:
				y = sh ? 16'd0 : {16{atg_su_hcmp(ca, cb, cop)}};
			default: y = 16'd0;
			endcase
			ref_half = st && o <= ATG_PK_FMAX2[3:0] ? atg_su_hsat(y) : y;
		end
	endfunction

	/* ---- the inputs */

	/* A half with exponent e: mantissa random, 0, all ones, or one or two
	 * bits (exact products, addends whose shifted-out bits alone are set). */
	function [15:0] mk;
		input s;
		input [4:0] e;
		input [9:0] m;
		input [2:0] mk_m;
		input [3:0] i0, i1;
		mk = {s, e, mk_m == 3'd0 ? 10'd0 : mk_m == 3'd1 ? 10'h3FF :
			mk_m == 3'd2 ? 10'd1 << i0 : mk_m == 3'd3 ? (10'd1 << i0) | (10'd1 << i1) : m};
	endfunction

	reg [4:0] ea, eb, ec;
	integer kd, kk;
	task pick;
		begin
			o = $random(seed);
			if (($random(seed) & 3) != 0)
				o = $unsigned($random(seed)) % 4;	/* mostly the fma */
			r = $random(seed);
			st = ($random(seed) & 7) == 0;
			kk = $unsigned($random(seed)) % 16;
			ea = kk == 0 ? 5'd0 : kk == 1 ? 5'h1F : 5'd1 + $unsigned($random(seed)) % 30;
			kk = $unsigned($random(seed)) % 16;
			eb = kk == 0 ? 5'd0 : kk == 1 ? 5'h1F : 5'd1 + $unsigned($random(seed)) % 30;
			kk = $unsigned($random(seed)) % 16;
			/* the addend's exponent: ea + eb - 15 + kd, kd from -40 to 40 */
			kd = $signed($unsigned($random(seed)) % 81) - 40;
			if (($random(seed) & 1) != 0)
				kd = $signed($unsigned($random(seed)) % 9) - 4;
			kd = ea + eb - 15 + kd;
			ec = kk == 0 ? 5'd0 : kk == 1 ? 5'h1F : kd < 1 ? 5'd1 + $unsigned($random(seed)) % 4 :
				kd > 30 ? 5'd30 - $unsigned($random(seed)) % 4 : kd;
			a = mk($random(seed), ea, $random(seed), $random(seed), $unsigned($random(seed)) % 10,
				$unsigned($random(seed)) % 10);
			b = mk($random(seed), eb, $random(seed), $random(seed), $unsigned($random(seed)) % 10,
				$unsigned($random(seed)) % 10);
			c = mk($random(seed), ec, $random(seed), $random(seed), $unsigned($random(seed)) % 10,
				$unsigned($random(seed)) % 10);
			kk = $unsigned($random(seed)) % 32;
			x = $random(seed);
			if (kk == 0) begin
				/* a * (+-1) + (-+a): an exact zero */
				b = {x[0], 15'h3C00};
				c = {!(a[15] ^ b[15]), a[14:0]};
			end
			if (kk == 1)
				c = {!c[15], a[14:0]};
			if (kk == 2)
				b = a;
			if (kk == 3)
				a = $random(seed);
			if (kk == 4)
				b = $random(seed);
			if (kk == 5)
				c = $random(seed);
			x = $random(seed);
			kk = $unsigned($random(seed)) % 8;
			if (kk < 5)
				x[30:23] = 8'd112 + ($signed($unsigned($random(seed)) % 41) - 20);
			else if (kk == 5)
				x[30:23] = 8'hFF;
			else if (kk == 6)
				x[30:23] = 8'd0;
			if (($random(seed) & 7) == 0)
				x[12:0] = ($random(seed) & 1) ? 13'h1000 : 13'h0FFF;	/* ties and their neighbours */
		end
	endtask

	reg [15:0] e11, e10, e0;
	task check;
		begin
			#1;
			e11 = o == ATG_PK_PACKH[3:0] ? ref_f2h(x) : ref_half(o, a, b, c, r, st, 1'b0);
			e10 = o == ATG_PK_PACKH[3:0] ? ref_f2h(x) : ref_half(o, a, b, c, r, st, 1'b1);
			e0 = o == ATG_PK_PACKH[3:0] ? ref_f2h(x) : 16'd0;
			if (y11 !== e11 || y10 !== e10 || y0 !== e0) begin
				if (o <= ATG_PK_FFMA2[3:0])
					err_f = err_f + 1;
				else
					err_o = err_o + 1;
				if (err_f + err_o <= 10)
					$display("FAIL atg_su_pk_half o %0d r %0d st %0d a %h b %h c %h x %h: %h %h %h, expected %h %h %h",
						o, r, st, a, b, c, x, y11, y10, y0, e11, e10, e0);
			end
		end
	endtask

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;
		if ($value$plusargs("n=%d", n))
			;
		for (i = 0; i < n; i = i + 1) begin
			pick;
			check;
		end
		if (err_f == 0)
			$display("PASS atg_su_pk_half.fma");
		else
			$display("FAIL atg_su_pk_half.fma %0d", err_f);
		if (err_o == 0)
			$display("PASS atg_su_pk_half.other");
		else
			$display("FAIL atg_su_pk_half.other %0d", err_o);
		if (err_f + err_o == 0)
			$display("PASS atg_su_pk_half");
		$finish;
	end
endmodule

`default_nettype wire
