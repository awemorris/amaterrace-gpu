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
