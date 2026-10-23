/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fp16.vh: the fp16 (binary16) helpers of atg_su_pk, with the rules
 * of include/atg_su_fp.vh (one rounding under rm, denormals flushed on
 * input and output, canonical NaN 0x7E00) and the fp32 <-> fp16
 * conversions of packh/unpackh (RNE).  Reference: tools/gsi1fp.py.
 * Included inside a module body after atg_su_fp.vh.
 */

function [15:0] atg_su_hflush;
	input [15:0] x;
	atg_su_hflush = x[14:10] == 5'd0 ? {x[15], 15'd0} : x;
endfunction

/* Round a normalised magnitude m (bit 10 set), guard, sticky, sign and
 * biased exponent e to fp16. */
function [15:0] atg_su_hrnd;
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
				atg_su_hrnd = {s, 5'h1E, 10'h3FF};
			else
				atg_su_hrnd = {s, 5'h1F, 10'd0};
		end else if (er <= 10'sd0)
			atg_su_hrnd = {s, 15'd0};
		else
			atg_su_hrnd = {s, er[4:0], mr[9:0]};
	end
endfunction

/* Fused a * b + c in fp16 with one rounding; noc: no addend. */
function [15:0] atg_su_hfma;
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
		atg_su_hfma = 16'd0;
		if (nan_a || nan_b || nan_c || (inf_a && zb) || (inf_b && za))
			atg_su_hfma = 16'h7E00;
		else if (inf_a || inf_b)
			atg_su_hfma = inf_c && sc != sp ? 16'h7E00 : {sp, 5'h1F, 10'd0};
		else if (inf_c)
			atg_su_hfma = c;
		else if (za || zb) begin
			if (!zc)
				atg_su_hfma = c;
			else if (noc)
				atg_su_hfma = {sp, 15'd0};
			else
				atg_su_hfma = {rdn ? (sp | sc) : (sp & sc), 15'd0};
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
				atg_su_hfma = {rdn, 15'd0};
			else begin
				msb = 6'd0;
				for (i = 0; i < 37; i = i + 1)
					if (sum[i])
						msb = i[5:0];
				nrm = sum << (6'd36 - msb);
				er = {4'd0, msb} + {5'd0, a[14:10]} + {5'd0, b[14:10]} + adj - 10'sd37;
				atg_su_hfma = atg_su_hrnd(sr, er, nrm[36:26], nrm[25], |nrm[24:0], rm);
			end
		end
	end
endfunction

function [15:0] atg_su_hminmax;
	input [15:0] a0, b0;
	input is_max;
	reg [15:0] a, b;
	reg na, nb, alt, blt;
	begin
		a = atg_su_hflush(a0);
		b = atg_su_hflush(b0);
		na = a[14:10] == 5'h1F && a[9:0] != 0;
		nb = b[14:10] == 5'h1F && b[9:0] != 0;
		alt = (a[15] && !b[15]) || (!a[15] && !b[15] && a[14:0] < b[14:0]) ||
			(a[15] && b[15] && a[14:0] > b[14:0]);
		blt = (b[15] && !a[15]) || (!b[15] && !a[15] && b[14:0] < a[14:0]) ||
			(b[15] && a[15] && b[14:0] > a[14:0]);
		if (na && nb)
			atg_su_hminmax = 16'h7E00;
		else if (na)
			atg_su_hminmax = b;
		else if (nb)
			atg_su_hminmax = a;
		else if (is_max)
			atg_su_hminmax = alt ? b : a;
		else
			atg_su_hminmax = blt ? b : a;
	end
endfunction

/* op 0 eq, 1 lt, 2 le, 3 ne. */
function atg_su_hcmp;
	input [15:0] a0, b0;
	input [1:0] op;
	reg [15:0] a, b;
	reg un, eq, lt;
	begin
		a = atg_su_hflush(a0);
		b = atg_su_hflush(b0);
		un = (a[14:10] == 5'h1F && a[9:0] != 0) || (b[14:10] == 5'h1F && b[9:0] != 0);
		eq = a == b || (a[14:0] == 15'd0 && b[14:0] == 15'd0);
		lt = !eq && ((a[15] && !b[15]) || (!a[15] && !b[15] && a[14:0] < b[14:0]) ||
			(a[15] && b[15] && a[14:0] > b[14:0]));
		case (op)
		2'd0: atg_su_hcmp = !un && eq;
		2'd1: atg_su_hcmp = !un && lt;
		2'd2: atg_su_hcmp = !un && (lt || eq);
		default: atg_su_hcmp = un || !eq;
		endcase
	end
endfunction

function [15:0] atg_su_hsat;
	input [15:0] x;
	if ((x[14:10] == 5'h1F && x[9:0] != 0) || x[15])
		atg_su_hsat = 16'd0;
	else if (x[14:0] > 15'h3C00)
		atg_su_hsat = 16'h3C00;
	else
		atg_su_hsat = x;
endfunction

/* fp32 -> fp16, RNE, flushed; NaN -> 0x7E00. */
function [15:0] atg_su_f2h;
	input [31:0] x0;
	reg [31:0] x;
	begin
		x = atg_su_flush(x0);
		if (x[30:23] == 8'hFF)
			atg_su_f2h = x[22:0] != 0 ? 16'h7E00 : {x[31], 5'h1F, 10'd0};
		else if (x[30:23] == 8'd0)
			atg_su_f2h = {x[31], 15'd0};
		else
			atg_su_f2h = atg_su_hrnd(x[31], {2'd0, x[30:23]} - 10'sd112, {1'b1, x[22:13]},
				x[12], |x[11:0], 3'd0);
	end
endfunction

/* fp16 -> fp32 (exact), flushed; NaN -> 0x7FC00000. */
function [31:0] atg_su_h2f;
	input [15:0] h0;
	reg [15:0] h;
	begin
		h = atg_su_hflush(h0);
		if (h[14:10] == 5'h1F)
			atg_su_h2f = h[9:0] != 0 ? 32'h7FC00000 : {h[15], 8'hFF, 23'd0};
		else if (h[14:10] == 5'd0)
			atg_su_h2f = {h[15], 31'd0};
		else
			atg_su_h2f = {h[15], {3'd0, h[14:10]} + 8'd112, h[9:0], 13'd0};
	end
endfunction
