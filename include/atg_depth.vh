/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_depth.vh: the depth conversion and compare shared by the ROP's
 * depth test (atg_rop_ds) and the TU's compare samplers (atg_tu_filter),
 * included inside a module.  tools/rxmodel.py (f2u24, depth_pass) is the
 * reference.
 *   atg_depth_u24(f)  fp32 in [0, 1] to unorm24: RNE(f × (2^24 − 1));
 *                     NaN, ≤ 0 and denormals to 0, ≥ 1 to all ones.
 *   atg_depth_key(f)  an fp32 order key (−0 = +0, denormals are 0).
 *   atg_depth_pass(fn, a, b, nan)  VkCompareOp fn of a against b (signed
 *                     keys or unorm24); with nan only NOT_EQUAL and ALWAYS
 *                     pass.
 */

function [23:0] atg_depth_u24;
	input [31:0] f;
	reg [47:0] p;
	reg [71:0] z;
	reg [4:0] t;
	begin
		p = {1'b1, f[22:0], 24'd0} - {24'd0, 1'b1, f[22:0]};
		t = 5'd30 - f[27:23];	/* 126 - e for e in 102..126 */
		z = {p, 24'd0} >> t;
		if (f[30:23] == 8'd0 || f[31] || (f[30:23] == 8'hFF && f[22:0] != 23'd0) ||
		    f[30:23] < 8'd102)
			atg_depth_u24 = 24'd0;
		else if (f[30:23] >= 8'd127)
			atg_depth_u24 = 24'hFFFFFF;
		else
			atg_depth_u24 = z[71:48] + {23'd0, z[47] && (z[46:0] != 47'd0 || z[48])};
	end
endfunction

function [32:0] atg_depth_key;
	input [31:0] f;
	atg_depth_key = f[30:23] == 8'd0 ? 33'd0 : f[31] ? -{2'b00, f[30:0]} : {2'b00, f[30:0]};
endfunction

function atg_depth_pass;
	input [2:0] fn;
	input [32:0] a, b;
	input nan;
	reg lt, eq;
	begin
		lt = $signed(a) < $signed(b);
		eq = a == b;
		case (fn)
		3'd0: atg_depth_pass = 1'b0;
		3'd1: atg_depth_pass = !nan && lt;
		3'd2: atg_depth_pass = !nan && eq;
		3'd3: atg_depth_pass = !nan && (lt || eq);
		3'd4: atg_depth_pass = !nan && !lt && !eq;
		3'd5: atg_depth_pass = nan || !eq;
		3'd6: atg_depth_pass = !nan && !lt;
		default: atg_depth_pass = 1'b1;
		endcase
	end
endfunction
