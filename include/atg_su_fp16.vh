/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fp16.vh: the fp16 (binary16) helpers of atg_su_pk_half and
 * atg_su_fpu, with the rules of include/atg_su_fp.vh (one rounding under
 * rm, denormals flushed on input and output, canonical NaN 0x7E00).  The
 * fused fma and packh's fp32 -> fp16 are the module atg_su_pk_half (the
 * shared arithmetic, docs/style.md "Arithmetic").  Reference:
 * tools/gsi1fp.py.  Included inside a module body after atg_su_fp.vh.
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
