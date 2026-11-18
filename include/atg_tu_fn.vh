/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_fn.vh: the TU's number functions without arithmetic of their
 * own (atg_tu_lsel, atg_tu_lod), included inside a module body;
 * tools/tumodel.py has the same functions (l2).  The ones with arithmetic
 * are modules: atg_tu_fx32, atg_tu_coord, atg_tu_unnorm, atg_tu_wrap,
 * atg_tu_layer, atg_tu_cube_texel (rtl/gpu/tu).
 */

/* verilator lint_off UNUSEDSIGNAL */

function signed [16:0] tu_sat16;
	input signed [32:0] tv;
	tu_sat16 = tv > 33'sd32767 ? 17'sd32767 : tv < -33'sd32768 ? -17'sd32768 : tv[16:0];
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


/* verilator lint_on UNUSEDSIGNAL */
