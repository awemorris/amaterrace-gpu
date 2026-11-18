/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fp.vh: combinational fp32 helpers of the SU without arithmetic
 * (design §3.1 precision: IEEE single, denormals flushed on input and
 * output, NaN results are the canonical 0x7FC00000; reference:
 * tools/gsi1fp.py).  Included inside a module body.  The arithmetic is in
 * modules (docs/style.md, "Arithmetic"): atg_su_fadd, atg_su_ffma,
 * atg_su_ffma_p, atg_su_rnd, atg_su_rint, atg_su_i2f and atg_su_f2i.
 */

/* Denormals become zeros of their sign. */
function [31:0] atg_su_flush;
	input [31:0] x;
	atg_su_flush = x[30:23] == 8'd0 ? {x[31], 31'd0} : x;
endfunction

/* The significands of a * b in atg_su_ffma_p: {!z, m} of the flushed
 * operands, 24 bits each (a multiplier shared with other operations takes
 * them, atg_su_fpu). */
function [47:0] atg_su_fsig;
	input [30:0] a, b;	/* (the signs are not needed) */
	atg_su_fsig = {a[30:23] != 8'd0 ? {1'b1, a[22:0]} : 24'd0,
		b[30:23] != 8'd0 ? {1'b1, b[22:0]} : 24'd0};
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
