/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fp.vh: combinational fp32 helpers of the SU (design §3.1
 * precision: IEEE single, round to nearest even, denormals flushed on
 * input and output, NaN results are the canonical 0x7FC00000).  Included
 * inside a module body.  atg_su_fadd(a, b) = a + b.
 */

function [31:0] atg_su_fadd;
	input [31:0] a, b;
	reg sa, sb, sx, sy, sr;
	reg [7:0] ea, eb, ex, ey;
	reg [23:0] ma, mb, mx, my;
	reg [7:0] d;
	reg [27:0] px, py, r;	/* {carry, 24 bits, guard, round, sticky} */
	reg [26:0] sh;
	reg [9:0] er;
	reg [24:0] mr;
	reg nan_a, nan_b, inf_a, inf_b;
	integer i;
	reg [9:0] lz;
	begin
		sa = a[31];
		sb = b[31];
		ea = a[30:23];
		eb = b[30:23];
		ma = ea == 8'd0 ? 24'd0 : {1'b1, a[22:0]};
		mb = eb == 8'd0 ? 24'd0 : {1'b1, b[22:0]};
		nan_a = ea == 8'hFF && a[22:0] != 0;
		nan_b = eb == 8'hFF && b[22:0] != 0;
		inf_a = ea == 8'hFF && a[22:0] == 0;
		inf_b = eb == 8'hFF && b[22:0] == 0;
		if (nan_a || nan_b || (inf_a && inf_b && sa != sb))
			atg_su_fadd = 32'h7FC00000;
		else if (inf_a)
			atg_su_fadd = {sa, 8'hFF, 23'd0};
		else if (inf_b)
			atg_su_fadd = {sb, 8'hFF, 23'd0};
		else if (ma == 24'd0 && mb == 24'd0)
			atg_su_fadd = {sa && sb, 31'd0};	/* (-0) + (-0) = -0, else +0 */
		else begin
			/* x is the larger magnitude. */
			if ({ea, ma} >= {eb, mb}) begin
				sx = sa; ex = ea; mx = ma; sy = sb; ey = eb; my = mb;
			end else begin
				sx = sb; ex = eb; mx = mb; sy = sa; ey = ea; my = ma;
			end
			if (my == 24'd0)
				ey = ex;
			d = ex - ey;
			px = {1'b0, mx, 3'b000};
			sh = {my, 3'b000};
			py = 28'd0;
			if (d >= 8'd27)
				py = {27'd0, my != 24'd0};
			else begin
				py[26:0] = sh >> d;
				for (i = 0; i < 27; i = i + 1)
					if (i < d && sh[i])
						py[0] = 1'b1;
			end
			sr = sx;
			er = {2'b00, ex};
			if (sx == sy) begin
				r = px + py;
				if (r[27]) begin
					r = {1'b0, r[27:2], r[1] | r[0]};
					er = er + 10'd1;
				end
			end else begin
				r = px - py;
				lz = 10'd0;
				for (i = 26; i >= 0; i = i - 1)
					if (r[i] && lz == 10'd0)
						lz = 10'd27 - i[9:0];
				if (lz == 10'd0)
					sr = 1'b0;	/* exact zero */
				else begin
					r = r << (lz - 10'd1);
					er = er - (lz - 10'd1);
				end
			end
			if (r[26:0] == 27'd0)
				atg_su_fadd = 32'd0;
			else begin
				/* r[26:3] the mantissa, [2] guard, [1] round, [0] sticky. */
				mr = {1'b0, r[26:3]};
				if (r[2] && (r[1] || r[0] || r[3]))
					mr = mr + 25'd1;
				if (mr[24]) begin
					mr = mr >> 1;
					er = er + 10'd1;
				end
				if (er[9] || er == 10'd0)
					atg_su_fadd = {sr, 31'd0};	/* underflow: flushed */
				else if (er >= 10'd255)
					atg_su_fadd = {sr, 8'hFF, 23'd0};
				else
					atg_su_fadd = {sr, er[7:0], mr[22:0]};
			end
		end
	end
endfunction

/*
 * The FPU's helpers (WS288 p008 part 2; reference: tools/gsi1fp.py).
 * rm: 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, 5-7 RNE (7 is "dynamic": there is
 * no CSR; 5 and 6 never reach here, atg_su_dec faults them).
 */

/* Denormals become zeros of their sign. */
function [31:0] atg_su_flush;
	input [31:0] x;
	atg_su_flush = x[30:23] == 8'd0 ? {x[31], 31'd0} : x;
endfunction

/* Round a normalised magnitude m (bit 23 set), guard g, sticky st, sign s
 * and biased exponent e (12-bit signed) to fp32 under rm. */
function [31:0] atg_su_rnd;
	input s;
	input signed [11:0] e;
	input [23:0] m;
	input g, st;
	input [2:0] rm;
	reg up;
	reg [24:0] mr;
	reg signed [11:0] er;
	begin
		case (rm)
		3'd1: up = 1'b0;
		3'd2: up = s && (g || st);
		3'd3: up = !s && (g || st);
		3'd4: up = g;
		default: up = g && (st || m[0]);
		endcase
		mr = {1'b0, m} + {24'd0, up};
		er = e;
		if (mr[24]) begin
			mr = mr >> 1;
			er = er + 12'sd1;
		end
		if (er >= 12'sd255) begin
			if (rm == 3'd1 || (rm == 3'd2 && !s) || (rm == 3'd3 && s))
				atg_su_rnd = {s, 8'hFE, 23'h7FFFFF};
			else
				atg_su_rnd = {s, 8'hFF, 23'd0};
		end else if (er <= 12'sd0)
			atg_su_rnd = {s, 31'd0};
		else
			atg_su_rnd = {s, er[7:0], mr[22:0]};
	end
endfunction

/* Fused a * b + c with one rounding; noc: there is no addend (fmul). */
function [31:0] atg_su_ffma;
	input [31:0] a0, b0, c0;
	input [2:0] rm;
	input noc;
	reg [31:0] a, b, c;
	reg sp, sc, nan_a, nan_b, nan_c, inf_a, inf_b, inf_c, za, zb, zc, rdn, sr;
	reg [23:0] ma, mb, mc;
	reg [47:0] p;
	reg signed [11:0] k, adj, er;
	reg [4:0] rs;
	reg [76:0] pw, cw, sum, nrm;
	reg [6:0] msb;
	integer i;
	begin
		a = atg_su_flush(a0);
		b = atg_su_flush(b0);
		c = atg_su_flush(c0);
		sp = a[31] ^ b[31];
		sc = c[31];
		rdn = rm == 3'd2;
		nan_a = a[30:23] == 8'hFF && a[22:0] != 0;
		nan_b = b[30:23] == 8'hFF && b[22:0] != 0;
		nan_c = !noc && c[30:23] == 8'hFF && c[22:0] != 0;
		inf_a = a[30:23] == 8'hFF && a[22:0] == 0;
		inf_b = b[30:23] == 8'hFF && b[22:0] == 0;
		inf_c = !noc && c[30:23] == 8'hFF && c[22:0] == 0;
		za = a[30:23] == 8'd0;
		zb = b[30:23] == 8'd0;
		zc = noc || c[30:23] == 8'd0;
		ma = {!za, a[22:0]};
		mb = {!zb, b[22:0]};
		mc = zc ? 24'd0 : {1'b1, c[22:0]};
		atg_su_ffma = 32'd0;
		if (nan_a || nan_b || nan_c || (inf_a && zb) || (inf_b && za))
			atg_su_ffma = 32'h7FC00000;
		else if (inf_a || inf_b)
			atg_su_ffma = inf_c && sc != sp ? 32'h7FC00000 : {sp, 8'hFF, 23'd0};
		else if (inf_c)
			atg_su_ffma = c;
		else if (za || zb) begin
			if (!zc)
				atg_su_ffma = c;
			else if (noc)
				atg_su_ffma = {sp, 31'd0};
			else
				atg_su_ffma = {rdn ? (sp | sc) : (sp & sc), 31'd0};
		end else begin
			p = ma * mb;
			/* C's LSB relative to P's (units of P's LSB), the window has
			 * two bits below P's LSB. */
			k = {4'd0, c[30:23]} - {4'd0, a[30:23]} - {4'd0, b[30:23]} + 12'sd150;
			adj = 12'sd0;
			pw = {27'd0, p, 2'b00};
			cw = 77'd0;
			if (!zc) begin
				if (k > 12'sd49) begin
					adj = k - 12'sd49;
					cw = {2'b00, mc, 51'd0};
					pw = {76'd0, 1'b1};
				end else if (k >= -12'sd2)
					cw = {53'd0, mc} << (k + 12'sd2);
				else if (k > -12'sd26) begin
					rs = 5'd0 - k[4:0] - 5'd2;	/* 1..23 */
					cw = {53'd0, mc} >> rs;
					cw[0] = cw[0] | |(mc & ~(24'hFFFFFF << rs));
				end else
					cw = 77'd1;
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
			if (sum == 77'd0)
				atg_su_ffma = {rdn, 31'd0};
			else begin
				msb = 7'd0;
				for (i = 0; i < 77; i = i + 1)
					if (sum[i])
						msb = i[6:0];
				nrm = sum << (7'd76 - msb);
				er = {5'd0, msb} + {4'd0, a[30:23]} + {4'd0, b[30:23]} + adj - 12'sd175;
				atg_su_ffma = atg_su_rnd(sr, er, nrm[76:53], nrm[52], |nrm[51:0], rm);
			end
		end
	end
endfunction

/* The integer nearest to |x| (x flushed, exponent below 150) under rm and
 * x's sign: returns {up, magnitude} as 25 bits plus the up bit not used. */
function [24:0] atg_su_rint;
	input [31:0] x;
	input [2:0] rm;
	reg [23:0] m, q;
	reg [7:0] f;
	reg [4:0] fm1;
	reg g, st, up;
	integer i;
	begin
		m = {x[30:23] != 8'd0, x[22:0]};
		f = 8'd150 - x[30:23];	/* fraction bits, 1..150 */
		q = f >= 8'd24 ? 24'd0 : m >> f;
		fm1 = f[4:0] - 5'd1;
		g = f > 8'd24 ? 1'b0 : m[fm1];
		st = 1'b0;
		for (i = 0; i < 24; i = i + 1)
			if (i + 1 < f && m[i])
				st = 1'b1;
		case (rm)
		3'd1: up = 1'b0;
		3'd2: up = x[31] && (g || st);
		3'd3: up = !x[31] && (g || st);
		3'd4: up = g;
		default: up = g && (st || q[0]);
		endcase
		atg_su_rint = {1'b0, q} + {24'd0, up};
	end
endfunction

/* An integer magnitude n (< 2^32) with sign s to fp32 under rm. */
function [31:0] atg_su_i2f;
	input s;
	input [31:0] n;
	input [2:0] rm;
	reg [4:0] msb;
	reg [31:0] w;
	integer i;
	begin
		msb = 5'd0;
		for (i = 0; i < 32; i = i + 1)
			if (n[i])
				msb = i[4:0];
		w = n << (5'd31 - msb);	/* MSB at bit 31 */
		if (n == 32'd0)
			atg_su_i2f = {s, 31'd0};
		else
			atg_su_i2f = atg_su_rnd(s, {7'd0, msb} + 12'sd127, w[31:8], w[7], |w[6:0], rm);
	end
endfunction

/* fround.s: round to an integral value under rm, keeping the sign. */
function [31:0] atg_su_fround;
	input [31:0] x0;
	input [2:0] rm;
	reg [31:0] x;
	reg [24:0] n;
	begin
		x = atg_su_flush(x0);
		n = atg_su_rint(x, rm);
		if (x[30:23] == 8'hFF && x[22:0] != 0)
			atg_su_fround = 32'h7FC00000;
		else if (x[30:23] >= 8'd150 || x[30:23] == 8'd0)
			atg_su_fround = x;
		else
			atg_su_fround = atg_su_i2f(x[31], {7'd0, n}, 3'd0);
	end
endfunction

/* fcvt.w.s / fcvt.wu.s (RISC-V saturation, NaN as +inf). */
function [31:0] atg_su_f2i;
	input [31:0] x0;
	input [2:0] rm;
	input uns;
	reg [31:0] x, mag;
	reg [24:0] n;
	reg s, nan, big;
	begin
		x = atg_su_flush(x0);
		nan = x[30:23] == 8'hFF && x[22:0] != 0;
		s = x[31] && !nan;
		big = x[30:23] >= 8'd159;
		n = atg_su_rint(x, rm);
		if (x[30:23] >= 8'd150)
			mag = {8'd0, 1'b1, x[22:0]} << (x[30:23] - 8'd150);
		else
			mag = {7'd0, n};
		if (uns)
			atg_su_f2i = s ? 32'd0 : big ? 32'hFFFFFFFF : mag;	/* negatives give 0 */
		else begin
			if (big || (!s && mag[31]) || (s && mag > 32'h80000000))
				atg_su_f2i = s ? 32'h80000000 : 32'h7FFFFFFF;
			else
				atg_su_f2i = s ? 32'd0 - mag : mag;
		end
	end
endfunction

/* fmin/fmax: a NaN operand gives the other, -0 < +0. */
function [31:0] atg_su_fminmax;
	input [31:0] a0, b0;
	input is_max;
	reg [31:0] a, b;
	reg na, nb, lt;
	begin
		a = atg_su_flush(a0);
		b = atg_su_flush(b0);
		na = a[30:23] == 8'hFF && a[22:0] != 0;
		nb = b[30:23] == 8'hFF && b[22:0] != 0;
		/* lt: a < b with -0 < +0. */
		lt = (a[31] && !b[31]) || (!a[31] && !b[31] && a[30:0] < b[30:0]) ||
			(a[31] && b[31] && a[30:0] > b[30:0]);
		if (na && nb)
			atg_su_fminmax = 32'h7FC00000;
		else if (na)
			atg_su_fminmax = b;
		else if (nb)
			atg_su_fminmax = a;
		else if (is_max)
			atg_su_fminmax = lt ? b : a;
		else begin
			/* min: b when b < a. */
			atg_su_fminmax = ((b[31] && !a[31]) || (!b[31] && !a[31] && b[30:0] < a[30:0]) ||
				(b[31] && a[31] && b[30:0] > a[30:0])) ? b : a;
		end
	end
endfunction

/* Compares: op 0 eq, 1 lt, 2 le, 3 ne (unordered: only ne is true). */
function atg_su_fcmp;
	input [31:0] a0, b0;
	input [1:0] op;
	reg [31:0] a, b;
	reg un, eq, lt;
	begin
		a = atg_su_flush(a0);
		b = atg_su_flush(b0);
		un = (a[30:23] == 8'hFF && a[22:0] != 0) || (b[30:23] == 8'hFF && b[22:0] != 0);
		eq = a == b || (a[30:0] == 31'd0 && b[30:0] == 31'd0);
		lt = !eq && ((a[31] && !b[31]) || (!a[31] && !b[31] && a[30:0] < b[30:0]) ||
			(a[31] && b[31] && a[30:0] > b[30:0]));
		case (op)
		2'd0: atg_su_fcmp = !un && eq;
		2'd1: atg_su_fcmp = !un && lt;
		2'd2: atg_su_fcmp = !un && (lt || eq);
		default: atg_su_fcmp = un || !eq;
		endcase
	end
endfunction

/* Saturate to [0, 1]: NaN, negatives and -0 give +0. */
function [31:0] atg_su_sat;
	input [31:0] x;
	if ((x[30:23] == 8'hFF && x[22:0] != 0) || x[31])
		atg_su_sat = 32'd0;
	else if (x[30:0] > 31'h3F800000)
		atg_su_sat = 32'h3F800000;
	else
		atg_su_sat = x;
endfunction
