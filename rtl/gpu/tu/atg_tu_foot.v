/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_foot: one lane's footprint (combinational; stage B of
 * atg_tu_addr, tools/tumodel.py lane_addr is the reference, bit for bit).
 *
 * From the lane's texel coordinates of stage A (cu, cv, cw: 8 fraction
 * bits, floor) and the texel offsets (off: du, dv, dw, signed 4 bits;
 * 0 for a cube): nearest i = (cu >> 8) + du; bilinear i0 = ((cu − 128) >>
 * 8) + du, i1 = i0 + 1, the weight fu the low 8 bits of cu − 128; j and v
 * alike.  A 3D level's slice: nearest k = (cw >> 8) + dw, or (linear, not
 * gather) ((cw − 128) >> 8) + dw plus 1 in the pass's second slice (p0),
 * fw the low 8 bits.  Each index is wrapped by its address mode into the
 * level (repeat, mirrored repeat: Vulkan's integer formulas; clamp to
 * edge; clamp to border: outside is a border texel, bit 0 of the
 * address).  A cube's indices are not wrapped: nearest clamps them,
 * bilinear takes a texel beyond one edge from the adjacent face and a
 * corner texel from the face itself (include/atg_tu_fn.vh tu_cube_texel).
 * texf: x + du, y + dv (and z + dw of a 3D level) clamped into the level.
 * Address = lbase + k × plane (+ face × stride for a cube) + the texel in
 * the plane (linear rows of wl texels of 2^psl bytes, wl rounded up to a
 * multiple of 2^ra (TEX_ROW; atg_tu_desc gives 0 for the tiled,
 * compressed and multisampled images), or 4×4 tiles of 64
 * bytes, a row of tiles ceil(wl / 4) × 64 bytes; psl 1 tiled, the earlier
 * RGB565: 32-byte tiles); bord says which are border texels.  ms (a
 * multisampled image, texf only): texel 4 i + smp of rows of roundup(wl,
 * 2) × 4 texels.  Texels 0-3 = (i0, j0), (i1, j0), (i0, j1), (i1, j1)
 * (nearest and texf: four times the same).  The four slots of the lane
 * are these texels for 1- to 4-byte texels and for gather (gather: the
 * word gwi of each texel); for 8-byte texels the two words of (i0, j) and
 * of (i1, j), j = j0 or (row) j1; for 16-byte texels the four words of
 * texel 0.  Compressed blocks (blk): the block of a texel at (j / 4) x
 * ceil(wl / 4) + i / 4 blocks of 2^psl bytes (8 or 16), its words as the
 * 8- and 16-byte texels' (16-byte blocks: the footprint's texel {row,
 * col}), and the texel's column and row in the block in address bits 1:0
 * of its first and second word.
 * See spec/gpu/tu/atg_tu_foot.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_foot (
	input wire [1:0] op,	/* 0 texl, 1 texb, 2 texf, 3 texsz */
	input wire gather,
	input wire cube,
	input wire is3d,
	input wire tiled,
	input wire lin,	/* bilinear */
	input wire ms,	/* multisampled (4 samples, linear) */
	input wire [1:0] smp,	/* texf: the sample */
	input wire [2:0] psl,	/* log2 of the texel's bytes */
	input wire [1:0] ra,	/* linear rows: log2 of the texel multiple of a row */
	input wire blk,	/* compressed 4 x 4 blocks */
	input wire row,	/* 8-byte texels: the pass's second row */
	input wire col,	/* 16-byte blocks: the pass's second column */
	input wire [1:0] gwi,	/* gather: the word of the texel */
	input wire p0,	/* the pass's second slice */
	input wire [1:0] mu,
	input wire [1:0] mv,
	input wire [1:0] mw,
	input wire [11:0] off,
	input wire [31:0] x,	/* texf: the integer coordinates */
	input wire [31:0] y,
	input wire [31:0] z,
	input wire signed [30:0] cu,
	input wire signed [30:0] cv,
	input wire signed [30:0] cw,
	input wire [15:0] wl,
	input wire [15:0] hl,
	input wire [15:0] dl,
	input wire [2:0] face,
	input wire [31:0] lbase,
	input wire [31:0] plane,
	input wire [31:0] stride,
	output wire [127:0] addr,
	output wire [3:0] bord,	/* border texels */
	output wire [15:0] fuv,	/* {fv, fu} */
	output wire [7:0] fw
);
	`include "atg_tu_fn.vh"

	wire signed [23:0] du = {{20{off[3]}}, off[3:0]};
	wire signed [23:0] dv = {{20{off[7]}}, off[7:4]};
	wire signed [23:0] dw = {{20{off[11]}}, off[11:8]};
	wire texf = op == 2'd2;
	/* The slice. */
	wire dlin = is3d && lin && !gather;
	wire [13:0] carry_unused;	/* the adders' carries */
	wire signed [30:0] cwm;
	wire signed [23:0] ki;
	wire signed [32:0] zd, xd, yd;
	wire [15:0] kf;
	am_sub #(.W(31)) u_cwm (.a(cw), .b(dlin ? 31'd128 : 31'd0), .bi(1'b0), .d(cwm),
		.bo(carry_unused[0]));
	am_add #(.W(24)) u_ki (.a({cwm[30], cwm[30:8]}), .b(dw), .ci(dlin && p0), .s(ki),
		.co(carry_unused[1]));
	wire [16:0] kw = tu_wrap(ki, dl, mw);
	am_add #(.W(33)) u_zd (.a({z[31], z}), .b({{9{dw[23]}}, dw}), .ci(1'b0), .s(zd),
		.co(carry_unused[2]));
	atg_tu_iclamp u_kf (.v(zd), .n(dl), .c(kf));
	wire [15:0] k = !is3d ? 16'd0 : texf ? kf : kw[15:0];
	wire bk = is3d && !texf && kw[16];
	assign fw = dlin ? cwm[7:0] : 8'd0;
	wire [47:0] kp;
	am_mul #(.AW(32), .BW(16)) u_kp (.clk(1'b0), .en(1'b1), .a(plane), .b(k), .p(kp));
	/* The footprint. */
	wire signed [30:0] cu2, cv2;
	wire signed [23:0] i0, j0, i1, j1;
	am_sub #(.W(31)) u_cu2 (.a(cu), .b(lin ? 31'd128 : 31'd0), .bi(1'b0), .d(cu2),
		.bo(carry_unused[3]));
	am_sub #(.W(31)) u_cv2 (.a(cv), .b(lin ? 31'd128 : 31'd0), .bi(1'b0), .d(cv2),
		.bo(carry_unused[4]));
	am_add #(.W(24)) u_i0 (.a({cu2[30], cu2[30:8]}), .b(du), .ci(1'b0), .s(i0),
		.co(carry_unused[5]));
	am_add #(.W(24)) u_j0 (.a({cv2[30], cv2[30:8]}), .b(dv), .ci(1'b0), .s(j0),
		.co(carry_unused[6]));
	am_add #(.W(24)) u_i1 (.a(i0), .b(24'd0), .ci(lin), .s(i1), .co(carry_unused[7]));
	am_add #(.W(24)) u_j1 (.a(j0), .b(24'd0), .ci(lin), .s(j1), .co(carry_unused[8]));
	assign fuv = {cv2[7:0], cu2[7:0]};
	wire [16:0] wi0 = tu_wrap(i0, wl, mu), wi1 = tu_wrap(i1, wl, mu);
	wire [16:0] wj0 = tu_wrap(j0, hl, mv), wj1 = tu_wrap(j1, hl, mv);
	wire [15:0] fi, fj;
	am_add #(.W(33)) u_xd (.a({x[31], x}), .b({{9{du[23]}}, du}), .ci(1'b0), .s(xd),
		.co(carry_unused[9]));
	am_add #(.W(33)) u_yd (.a({y[31], y}), .b({{9{dv[23]}}, dv}), .ci(1'b0), .s(yd),
		.co(carry_unused[10]));
	atg_tu_iclamp u_fi (.v(xd), .n(wl), .c(fi));
	atg_tu_iclamp u_fj (.v(yd), .n(hl), .c(fj));
	/* A multisampled texf: texel 4 i + s of rows of roundup(wl, 2) × 4. */
	wire msf = ms && texf;
`ifdef MUT_TU_MSROW
	wire [15:0] wms = {wl[13:0], 2'b00};	/* rows of w x 4: odd widths go wrong */
`else
	wire [12:0] wl2;	/* roundup(wl, 2) / 2 */
	am_add #(.W(13)) u_wl2 (.a(wl[13:1]), .b(13'd0), .ci(wl[0]), .s(wl2), .co(carry_unused[11]));
	wire [15:0] wms = {wl2, 3'b000};
`endif
	wire [15:0] fim = {fi[13:0], smp};
	/* The row of a linear level: wl rounded up to a multiple of 2^ra. */
	wire [16:0] rm = ra == 2'd0 ? 17'd0 : ra == 2'd1 ? 17'd1 : ra == 2'd2 ? 17'd3 : 17'd7;	/* 2^ra - 1 */
	wire [16:0] wrm;
	am_add #(.W(17)) u_wrm (.a({1'b0, wl}), .b(rm), .ci(1'b0), .s(wrm), .co(carry_unused[12]));
`ifdef MUT_TU_PITCH
	wire [16:0] wr = {1'b0, wl} | (rm & 17'd0);	/* packed rows whatever TEX_ROW says */
	wire unused_wrm = &{1'b0, wrm};
`else
	wire [16:0] wr = wrm & ~rm;
`endif
	/* Cube: clamped (nearest) or across the faces (bilinear). */
	wire [34:0] c00 = lin ? tu_cube_texel(face, i0, j0, wl) :
		{face, tu_clamp(i0, wl), tu_clamp(j0, wl)};
	wire [34:0] c10 = tu_cube_texel(face, i1, j0, wl);
	wire [34:0] c01 = tu_cube_texel(face, i0, j1, wl);
	wire [34:0] c11 = tu_cube_texel(face, i1, j1, wl);

	/* Slot t: its texel ft of the footprint and the word in the texel; its address
	 * lbase + k plane (+ face stride) + the texel's offset + the word's byte. */
	wire [31:0] lbk;
	am_add #(.W(32)) u_lbk (.a(lbase), .b(kp[31:0]), .ci(1'b0), .s(lbk), .co(carry_unused[13]));
	wire [127:0] a;
	wire [3:0] bd;
	genvar gt;
	generate
	for (gt = 0; gt < 4; gt = gt + 1) begin : g_slot
		localparam [1:0] T = gt;
		reg [34:0] ct;
		reg [15:0] ti, tj;
		reg [2:0] tf;
		reg [1:0] ft, part;
		reg tb;
		always @(*) begin
`ifdef MUT_TU_ROW
			ft = (gather && !blk) || psl <= 3'd2 ? T : psl == 3'd3 ? {1'b0, T[1]} : {1'b0, col};
`else
			ft = (gather && !blk) || psl <= 3'd2 ? T : psl == 3'd3 ? {row, T[1]} : {row, col};
`endif
			part = gather && !blk ? gwi : psl == 3'd3 ? {1'b0, T[0]} : psl == 3'd4 ? T : 2'd0;
			ct = !lin || ft == 2'd0 ? c00 : ft == 2'd1 ? c10 : ft == 2'd2 ? c01 : c11;
			if (texf) begin
				tf = 3'd0;
				ti = msf ? fim : fi;
				tj = fj;
				tb = 1'b0;
			end else if (cube) begin
				tf = ct[34:32];
				ti = ct[31:16];
				tj = ct[15:0];
				tb = 1'b0;
			end else begin
				tf = 3'd0;
				ti = ft[0] ? wi1[15:0] : wi0[15:0];
				tj = ft[1] ? wj1[15:0] : wj0[15:0];
				tb = (ft[0] ? wi1[16] : wi0[16]) | (ft[1] ? wj1[16] : wj0[16]) | bk;
			end
		end
		wire [34:0] fs;
		wire [31:0] to, a1, a2;
		wire [2:0] cu_t;
		am_mul #(.AW(32), .BW(3)) u_fs (.clk(1'b0), .en(1'b1), .a(stride), .b(tf), .p(fs));
		atg_tu_toff u_to (.i(ti), .j(tj), .w(msf ? {1'b0, wms} : wr), .tl(tiled), .pl(psl), .bk(blk),
			.off(to));
		am_add #(.W(32)) u_a1 (.a(lbk), .b(cube && !texf ? fs[31:0] : 32'd0), .ci(1'b0), .s(a1),
			.co(cu_t[0]));
		am_add #(.W(32)) u_a2 (.a(a1), .b(to), .ci(1'b0), .s(a2), .co(cu_t[1]));
		/* the word's byte, and a block's column (word 0) or row (word 1) in bits 1:0 */
		am_add #(.W(32)) u_a (.a(a2), .b({28'd0, part, blk && part == 2'd0 ? ti[1:0] :
			blk && part == 2'd1 ? tj[1:0] : 2'd0}), .ci(1'b0), .s(a[gt*32 +: 32]), .co(cu_t[2]));
		assign bd[gt] = tb;
		wire unused_t = &{1'b0, fs[34:32], cu_t};
	end
	endgenerate
	assign addr = a;
	assign bord = bd;

	wire unused_ok = &{1'b0, kp[47:32], wl[15:14], fi[15:14]};
endmodule

`default_nettype wire
