/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_fmt.vh: the class of a texture slot's format (docs/ghci.md
 * sections 8.4 and 8.5), included inside a module after atg_fmt_info.vh.
 * tools/tumodel.py (fclass, gather_word) is the reference.
 *   tu_fcls(tf, lfmt)  tf: the slot's TEX_FORMAT (21 bits), lfmt:
 *       TEX_IMAGE[7:4].  [2:0] log2 of a texel's bytes; [3] legacy
 *       (TEX_FORMAT[7:0] = 0: TEX_IMAGE's format, as before CAPS[30]);
 *       [4] none (a value without the sampled feature: read as (0, 0, 0,
 *       1)); [5] a colour format of the 8-bit path (R8, R8G8, R8G8B8A8,
 *       B8G8R8A8, A8B8G8R8 UNORM); [6] linear filtering (the format's
 *       FILTER_LINEAR feature; not the stencil aspect); [7] depth (a depth
 *       format read for its depth); [8] the stencil aspect (TEX_FORMAT[8]
 *       of D24_UNORM_S8_UINT); [9] the 8-bit path's format bit (BGRA8 or
 *       D32_SFLOAT); [10] D16_UNORM; [11] integer (UINT, SINT, the stencil
 *       aspect).  Legacy: [2:0] 1 for RGB565 (code 4) and 2 otherwise, [7]
 *       and [9] the codes' (2 D24, 3 D32F; 5-15 read as 0), the rest 0.
 *   tu_gwi(tf, comp)  gather of component comp: the 32-bit word of the
 *       texel that holds the component after the swizzle (8- and 16-byte
 *       texels; 0 for a constant or missing component).
 */

/* verilator lint_off UNUSEDSIGNAL */

function [11:0] tu_fcls;
	input [20:0] tf_f;
	input [3:0] tf_l;
	reg [67:0] tf_i;
	reg [25:0] tf_ft;
	reg [7:0] tf_v;
	reg [1:0] tf_lc;
	reg [2:0] tf_p;
	reg tf_s;
	begin
		tf_v = tf_f[7:0];
		tf_i = atg_fmt_info(tf_v);
		tf_ft = atg_fmt_feat(tf_v, 1'b0);
		tf_lc = tf_l[3:2] != 2'd0 ? 2'd0 : tf_l[1:0];
		tf_p = tf_i[5:1] == 5'd1 ? 3'd0 : tf_i[5:1] == 5'd2 ? 3'd1 : tf_i[5:1] == 5'd8 ? 3'd3 :
			tf_i[5:1] == 5'd16 ? 3'd4 : 3'd2;
		tf_s = tf_f[GHCI_TFMT_STENCIL] && tf_i[13];
		if (tf_v == 8'd0)
			tu_fcls = {2'b00, tf_lc[0], 1'b0, tf_lc[1], 4'b0001, tf_l == 4'd4 ? 3'd1 : 3'd2};
		else if (!tf_ft[0])
			tu_fcls = {7'd0, 2'b10, 3'd2};
		else
			tu_fcls = {tf_s || tf_i[11:9] == ATG_FMT_UINT || tf_i[11:9] == ATG_FMT_SINT,
				tf_v == 8'd124, tf_v == 8'd44 || tf_v == 8'd126, tf_s, tf_i[12] && !tf_s,
				tf_ft[12] && !tf_s,
				tf_v == 8'd9 || tf_v == 8'd16 || tf_v == 8'd37 || tf_v == 8'd44 || tf_v == 8'd51,
				2'b00, tf_p};
	end
endfunction

function [1:0] tu_gwi;
	input [20:0] tg_f;
	input [1:0] tg_c;
	reg [67:0] tg_i;
	reg [2:0] tg_s;
	reg [1:0] tg_src;
	reg [6:0] tg_pos;
	begin
		tg_i = atg_fmt_info(tg_f[7:0]);
		tg_s = tg_f[GHCI_TFMT_SWIZZLE + 3 * tg_c +: 3];
		tg_src = tg_s == 3'd0 || tg_s == 3'd7 ? tg_c : tg_s[1:0] + 2'd1;
		tg_pos = tg_i[16 + 13 * tg_src +: 7];
		tu_gwi = tg_s == 3'd1 || tg_s == 3'd2 || {1'b0, tg_src} >= tg_i[8:6] ? 2'd0 :
			tg_pos[6:5];
	end
endfunction

/* verilator lint_on UNUSEDSIGNAL */
