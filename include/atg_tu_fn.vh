/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_fn.vh: the TU's number functions (atg_tu_addr, atg_tu_lod),
 * included inside a module body.  tools/tumodel.py has the same functions
 * (fx32, coord_t, unnorm_c, wrap_idx, rne_layer, l2, cube_texel).
 */

/* verilator lint_off UNUSEDSIGNAL */

/* floor(f × 2^sh), saturated to 32 bits; zero, denormal, NaN → 0. */
function [31:0] tu_fx32;
	input [31:0] f;
	input [4:0] sh;
	integer k;
	reg [31:0] q;
	reg st;
	begin
		k = {24'd0, f[30:23]} - 150 + {27'd0, sh};
		q = 32'd0;
		st = 1'b0;
		if (k >= 0 && k < 8)
			q = {8'd0, 1'b1, f[22:0]} << k;
		else if (k < 0 && k > -24) begin
			q = {8'd0, 1'b1, f[22:0]} >> (-k);
			st = |({1'b1, f[22:0]} & ((24'd1 << (-k)) - 24'd1));
		end else if (k < 0)
			st = 1'b1;
		if (f[30:23] == 8'd0 || (f[30:23] == 8'hFF && f[22:0] != 23'd0))
			tu_fx32 = 32'd0;
		else if (f[30:23] == 8'hFF || k >= 8)
			tu_fx32 = f[31] ? 32'h80000000 : 32'h7FFFFFFF;
		else
			tu_fx32 = f[31] ? -(q + {31'd0, st}) : q;
	end
endfunction

function signed [16:0] tu_sat16;
	input signed [32:0] tv;
	tu_sat16 = tv > 33'sd32767 ? 17'sd32767 : tv < -33'sd32768 ? -17'sd32768 : tv[16:0];
endfunction

/* The normalized coordinate with 24 fraction bits before the texel
 * coordinate: repeat floor(u × 2^24) mod 2^24, mirrored repeat mod 2^25,
 * clamp to edge and border floor(u × 2^24) clamped to [−16, 17] × 2^24. */
function signed [29:0] tu_coord;
	input [31:0] f;
	input [1:0] mode;
	integer k;
	reg [28:0] q;
	reg [24:0] t;
	reg st;
	reg signed [29:0] tv;
	begin
		k = {24'd0, f[30:23]} - 126;
		q = 29'd0;
		st = 1'b0;
		if (k >= 0 && k < 25)
			q = {5'd0, 1'b1, f[22:0]} << k;	/* repeat, mirror: bits 24:0 */
		else if (k < 0 && k > -24) begin
			q = {5'd0, 1'b1, f[22:0]} >> (-k);
			st = |({1'b1, f[22:0]} & ((24'd1 << (-k)) - 24'd1));
		end else if (k < 0)
			st = 1'b1;
		t = f[31] ? -(q[24:0] + {24'd0, st}) : q[24:0];
		tv = f[31] ? -$signed({1'b0, q} + {29'd0, st}) : $signed({1'b0, q});
		if (f[30:23] == 8'd0 || (f[30:23] == 8'hFF && f[22:0] != 23'd0))
			tu_coord = 30'sd0;
		else if (mode[1] && f[30:23] >= 8'd131)
			tu_coord = f[31] ? -30'sd268435456 : 30'sd285212672;
		else if (mode[1])
			tu_coord = tv < -30'sd268435456 ? -30'sd268435456 :
				tv > 30'sd285212672 ? 30'sd285212672 : tv;
		else if (f[30:23] == 8'hFF || k >= 25)
			tu_coord = 30'sd0;
		else if (mode[0])
			tu_coord = $signed({5'd0, t});
		else
			tu_coord = $signed({6'd0, t[23:0]});
	end
endfunction

/* An unnormalized coordinate: floor(u × 256) clamped to [−2^28, 2^28]. */
function signed [29:0] tu_unnorm;
	input [31:0] f;
	reg [31:0] tx;
	begin
		tx = tu_fx32(f, 5'd8);
		tu_unnorm = $signed(tx) < -32'sd268435456 ? -30'sd268435456 :
			$signed(tx) > 32'sd268435456 ? 30'sd268435456 : tx[29:0];
	end
endfunction

/* i mod p for i in [−9, p + 7] (one correction, or a 5-bit remainder for
 * p < 16). */
function [16:0] tu_mod;
	input signed [23:0] i;
	input [16:0] p;
	reg [4:0] tv, r, r9;
	begin
		tv = i[4:0] + 5'd9;
		r = tv % p[4:0];
		r9 = 5'd9 % p[4:0];
		if (p >= 17'd16)
			tu_mod = i < 0 ? i[16:0] + p : i >= $signed({7'd0, p}) ? i[16:0] - p : i[16:0];
		else
			tu_mod = r >= r9 ? {12'd0, r - r9} : {12'd0, r} + p - {12'd0, r9};
	end
endfunction

/* An integer texel coordinate into the level: {border texel, index}. */
function [16:0] tu_wrap;
	input signed [23:0] i;
	input [15:0] n;
	input [1:0] mode;
	reg [16:0] m;
	reg lt, ge;
	begin
		lt = i < 0;
		ge = i >= $signed({8'd0, n});
		m = tu_mod(i, mode[0] ? {n, 1'b0} : {1'b0, n});
		case (mode)
		2'd0: tu_wrap = {1'b0, m[15:0]};
		2'd1: tu_wrap = {1'b0, m < {1'b0, n} ? m[15:0] : {n[14:0], 1'b0} - 16'd1 - m[15:0]};
		default: tu_wrap = {mode[0] && (lt || ge), lt ? 16'd0 : ge ? n - 16'd1 : i[15:0]};
		endcase
	end
endfunction

/* An index clamped into [0, n − 1]. */
function [15:0] tu_clamp;
	input signed [23:0] i;
	input [15:0] n;
	tu_clamp = i < 0 ? 16'd0 : i >= $signed({8'd0, n}) ? n - 16'd1 : i[15:0];
endfunction

/* Vulkan's layer clamp(RNE(f), 0, cnt − 1); NaN, zeros, denormals and
 * negative values 0. */
function [15:0] tu_layer;
	input [31:0] f;
	input [15:0] cnt;
	integer k;
	reg [23:0] q, rem, half;
	reg [24:0] tv;
	begin
		k = 150 - {24'd0, f[30:23]};
		q = 24'd0;
		rem = 24'd0;
		half = 24'd0;
		if (k >= 1 && k <= 24) begin
			q = {1'b1, f[22:0]} >> k;
			rem = {1'b1, f[22:0]} & ((24'd1 << k) - 24'd1);
			half = 24'd1 << (k - 1);
		end
		tv = {1'b0, q} + {24'd0, rem > half || (rem == half && q[0])};
		if (f[30:23] == 8'd0 || (f[30:23] == 8'hFF && f[22:0] != 23'd0) || f[31])
			tu_layer = 16'd0;
		else if (k < 1 || tv >= {9'd0, cnt})
			tu_layer = cnt - 16'd1;
		else
			tu_layer = tv[15:0];
	end
endfunction

/* log2 with 8 fraction bits (tx != 0). */
function [13:0] tu_l2;
	input [32:0] tx;
	integer i;
	reg [5:0] p;
	reg [7:0] m;
	begin
		p = 6'd0;
		for (i = 0; i < 33; i = i + 1)
			if (tx[i])
				p = i[5:0];
		for (i = 0; i < 8; i = i + 1)
			m[7 - i] = {26'd0, p} > i ? tx[{26'd0, p} - 1 - i] : 1'b0;
		tu_l2 = {p, m};
	end
endfunction

/* A texel of a cube tface's bilinear footprint (i, j in [−1, n]):
 * {tface, i, j} on the tface; beyond one edge the adjacent tface's texel
 * (the table of tools/tumodel.py CUBE_ADJ: edge 0 i < 0, 1 i ≥ n, 2 j < 0,
 * 3 j ≥ n; i' and j' 0, n − 1, a or n − 1 − a with a the coordinate along
 * the edge); beyond two (a corner) the tface's own corner texel. */
function [34:0] tu_cube_texel;
	input [2:0] tface;
	input signed [23:0] i;
	input signed [23:0] j;
	input [15:0] n;
	reg oi, oj;
	reg [1:0] e, xi, xj;
	reg [2:0] g;
	reg [15:0] a, ri, rj;
	begin
		oi = i < 0 || i >= $signed({8'd0, n});
		oj = j < 0 || j >= $signed({8'd0, n});
		e = oi ? {1'b0, !(i < 0)} : {1'b1, !(j < 0)};
		a = oi ? j[15:0] : i[15:0];
		case ({tface, e})
		5'b000_00: {g, xi, xj} = {3'd4, 2'd1, 2'd2};
		5'b000_01: {g, xi, xj} = {3'd5, 2'd0, 2'd2};
		5'b000_10: {g, xi, xj} = {3'd2, 2'd1, 2'd3};
		5'b000_11: {g, xi, xj} = {3'd3, 2'd1, 2'd2};
		5'b001_00: {g, xi, xj} = {3'd5, 2'd1, 2'd2};
		5'b001_01: {g, xi, xj} = {3'd4, 2'd0, 2'd2};
		5'b001_10: {g, xi, xj} = {3'd2, 2'd0, 2'd2};
		5'b001_11: {g, xi, xj} = {3'd3, 2'd0, 2'd3};
		5'b010_00: {g, xi, xj} = {3'd1, 2'd2, 2'd0};
		5'b010_01: {g, xi, xj} = {3'd0, 2'd3, 2'd0};
		5'b010_10: {g, xi, xj} = {3'd5, 2'd3, 2'd0};
		5'b010_11: {g, xi, xj} = {3'd4, 2'd2, 2'd0};
		5'b011_00: {g, xi, xj} = {3'd1, 2'd3, 2'd1};
		5'b011_01: {g, xi, xj} = {3'd0, 2'd2, 2'd1};
		5'b011_10: {g, xi, xj} = {3'd4, 2'd2, 2'd1};
		5'b011_11: {g, xi, xj} = {3'd5, 2'd3, 2'd1};
		5'b100_00: {g, xi, xj} = {3'd1, 2'd1, 2'd2};
		5'b100_01: {g, xi, xj} = {3'd0, 2'd0, 2'd2};
		5'b100_10: {g, xi, xj} = {3'd2, 2'd2, 2'd1};
		5'b100_11: {g, xi, xj} = {3'd3, 2'd2, 2'd0};
		5'b101_00: {g, xi, xj} = {3'd0, 2'd1, 2'd2};
		5'b101_01: {g, xi, xj} = {3'd1, 2'd0, 2'd2};
		5'b101_10: {g, xi, xj} = {3'd2, 2'd3, 2'd0};
		default: {g, xi, xj} = {3'd3, 2'd3, 2'd1};
		endcase
		ri = xi == 2'd0 ? 16'd0 : xi == 2'd1 ? n - 16'd1 : xi == 2'd2 ? a : n - 16'd1 - a;
		rj = xj == 2'd0 ? 16'd0 : xj == 2'd1 ? n - 16'd1 : xj == 2'd2 ? a : n - 16'd1 - a;
		if (oi && oj)
			tu_cube_texel = {tface, tu_clamp(i, n), tu_clamp(j, n)};
		else if (!oi && !oj)
			tu_cube_texel = {tface, i[15:0], j[15:0]};
		else
			tu_cube_texel = {g, ri, rj};
	end
endfunction

/* verilator lint_on UNUSEDSIGNAL */
