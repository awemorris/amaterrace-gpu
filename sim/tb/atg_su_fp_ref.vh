/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fp_ref.vh: the fp32 fused multiply-add of the SU as functions, a
 * reference model for the testbenches (the former functions of
 * include/atg_su_fp.vh; the RTL has the modules atg_su_ffma,
 * atg_su_ffma_p and atg_su_rnd).  Included inside a testbench module.
 * ref_su_ffma(a, b, c, rm, noc) = a * b + c with one rounding.
 */

/* Denormals become zeros of their sign. */
function [31:0] ref_su_flush;
	input [31:0] x;
	ref_su_flush = x[30:23] == 8'd0 ? {x[31], 31'd0} : x;
endfunction

/* Round a normalised magnitude m (bit 23 set), guard g, sticky st, sign s
 * and biased exponent e (12-bit signed) to fp32 under rm. */
function [31:0] ref_su_rnd;
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
		3'd1, 3'd5, 3'd6: up = 1'b0;
		3'd2: up = s && (g || st);
		3'd3: up = !s && (g || st);
		3'd4: up = g;
		default: up = g && (st || m[0]);
		endcase
		mr = {1'b0, m[23:1], m[0] | ((rm == 3'd5 || rm == 3'd6) && (g || st))} + {24'd0, up};
		er = e;
		if (mr[24]) begin
			mr = mr >> 1;
			er = er + 12'sd1;
		end
		if (er >= 12'sd255) begin
			if (rm == 3'd1 || rm == 3'd5 || rm == 3'd6 || (rm == 3'd2 && !s) || (rm == 3'd3 && s))
				ref_su_rnd = {s, 8'hFE, 23'h7FFFFF};
			else
				ref_su_rnd = {s, 8'hFF, 23'd0};
		end else if (er <= 12'sd0)
			ref_su_rnd = {s, 31'd0};
		else
			ref_su_rnd = {s, er[7:0], mr[22:0]};
	end
endfunction

/* The significands of a * b in ref_su_ffma: {!z, m} of the flushed
 * operands, 24 bits each (a multiplier shared with other operations takes
 * them, atg_su_fpu). */
function [47:0] ref_su_fsig;
	input [30:0] a, b;	/* (the signs are not needed) */
	ref_su_fsig = {a[30:23] != 8'd0 ? {1'b1, a[22:0]} : 24'd0,
		b[30:23] != 8'd0 ? {1'b1, b[22:0]} : 24'd0};
endfunction

/* Fused a * b + c with one rounding; noc: there is no addend (fmul). */
function [31:0] ref_su_ffma;
	input [31:0] a0, b0, c0;
	input [2:0] rm;
	input noc;
	reg [47:0] sg, pp;
	begin
		sg = ref_su_fsig(a0[30:0], b0[30:0]);
		pp = sg[47:24] * sg[23:0];
		ref_su_ffma = ref_su_ffma_p(a0, b0, c0, rm, noc, pp);
	end
endfunction

/* ref_su_ffma with the product of the significands (ref_su_fsig) given. */
function [31:0] ref_su_ffma_p;
	input [31:0] a0, b0, c0;
	input [2:0] rm;
	input noc;
	input [47:0] p;
	reg [31:0] a, b, c;
	reg sp, sc, nan_a, nan_b, nan_c, inf_a, inf_b, inf_c, za, zb, zc, rdn, sr;
	reg [23:0] mc;
	reg signed [11:0] k, adj, er;
	reg [4:0] rs;
	reg [76:0] pw, cw, sum, nrm;
	reg [6:0] msb;
	integer i;
	begin
		a = ref_su_flush(a0);
		b = ref_su_flush(b0);
		c = ref_su_flush(c0);
		sp = a[31] ^ b[31];
		sc = c[31];
		rdn = rm == 3'd2 || rm == 3'd6;
		nan_a = a[30:23] == 8'hFF && a[22:0] != 0;
		nan_b = b[30:23] == 8'hFF && b[22:0] != 0;
		nan_c = !noc && c[30:23] == 8'hFF && c[22:0] != 0;
		inf_a = a[30:23] == 8'hFF && a[22:0] == 0;
		inf_b = b[30:23] == 8'hFF && b[22:0] == 0;
		inf_c = !noc && c[30:23] == 8'hFF && c[22:0] == 0;
		za = a[30:23] == 8'd0;
		zb = b[30:23] == 8'd0;
		zc = noc || c[30:23] == 8'd0;
		mc = zc ? 24'd0 : {1'b1, c[22:0]};
		ref_su_ffma_p = 32'd0;
		if (nan_a || nan_b || nan_c || (inf_a && zb) || (inf_b && za))
			ref_su_ffma_p = 32'h7FC00000;
		else if (inf_a || inf_b)
			ref_su_ffma_p = inf_c && sc != sp ? 32'h7FC00000 : {sp, 8'hFF, 23'd0};
		else if (inf_c)
			ref_su_ffma_p = c;
		else if (za || zb) begin
			if (!zc)
				ref_su_ffma_p = c;
			else if (noc)
				ref_su_ffma_p = {sp, 31'd0};
			else
				ref_su_ffma_p = {rdn ? (sp | sc) : (sp & sc), 31'd0};
		end else begin
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
				ref_su_ffma_p = {rdn, 31'd0};
			else begin
				msb = 7'd0;
				for (i = 0; i < 77; i = i + 1)
					if (sum[i])
						msb = i[6:0];
				nrm = sum << (7'd76 - msb);
				er = {5'd0, msb} + {4'd0, a[30:23]} + {4'd0, b[30:23]} + adj - 12'sd175;
				ref_su_ffma_p = ref_su_rnd(sr, er, nrm[76:53], nrm[52], |nrm[51:0], rm);
			end
		end
	end
endfunction
