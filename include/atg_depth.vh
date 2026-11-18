/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_depth.vh: the depth compare shared by the ROP's depth test
 * (atg_rop_dtest) and the TU's compare samplers (atg_tu_fpre), included
 * inside a module.  tools/rxmodel.py (depth_pass) is the reference.  The
 * conversions are modules: atg_fmt_depth_u24 (fp32 to unorm24) and
 * atg_fmt_depth_key (the fp32 order key).
 *   atg_depth_pass(fn, a, b, nan)  VkCompareOp fn of a against b (signed
 *                     keys or unorm24); with nan only NOT_EQUAL and ALWAYS
 *                     pass.
 */

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
