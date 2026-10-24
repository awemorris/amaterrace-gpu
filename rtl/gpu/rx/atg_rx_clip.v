/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_clip: RX primitive input and clipping: reads the vertices'
 * clip-space positions from the PT (or DRAW_RAW's screen-space vertices
 * from STATE 0x1E0-0x1E8), clips points, lines and triangles against the
 * w, near, far and guard-band planes (atg_rx_cpoly), and passes the
 * results to atg_rx_setup with weights relative to the original vertices.
 *
 * A vertex is 7 fp32 words {x, y, z, w, w0, w1, w2}.  prim_vtx[25:24] is
 * the kind (0 point (p, p, p), 1 line (a, b, b), 2 or 3 triangle); 4, 8 or
 * 12 PT words are read.  Planes in order: 0 w >= 2^-16 (always), 1 z >= 0
 * (DEPTH_CLAMP[1] = 0, or [1] without [0]), 2 z <= w ([1] without [0]),
 * 3-6 the guard band (x_off w + x_scale x within +-16383 w, the same in
 * y) when a vertex is not inside the trivial bound below.  Trivial accept
 * (fp32 compares only): every vertex has w >= 2^-16, is inside the depth
 * planes that apply, and has |x|, |y| <= 4 w with |x_off|, |y_off| <= 6144
 * and |x_scale|, |y_scale| <= 2048 (then it lies inside the guard band):
 * the primitive passes unchanged.  Otherwise atg_rx_cpoly cuts by each
 * plane that applies; a triangle comes out as a fan (v0, v_i, v_i+1), a
 * line as one line (a', b', b'); a point is passed when inside planes 0-2
 * as they apply and dropped otherwise (x and y are not clipped).  Nothing
 * left, or RAST_MODE[6] (rasterizer discard, without reading the PT): one
 * empty triangle (positions (0, 0, 0, 1)) with the last-use flags.  Only
 * the last output of a primitive carries prim_free; cl_last is on the last
 * output of the draw's last primitive.  A line's third vertex is its
 * second, a point's three are the vertex.  See spec/gpu/rx/atg_rx_clip.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_clip (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire raw_kick,
	/* Primitives to the RX */
	input wire prim_valid,
	output wire prim_ready,
	input wire [25:0] prim_vtx,
	input wire [2:0] prim_free,
	input wire prim_last,
	/* PT read (shared with atg_rx_scan in atg_rx: scan has priority) */
	output wire pt_rd,
	output wire [7:0] pt_idx,
	output wire [5:0] pt_word,
	input wire [31:0] pt_rdata,
	input wire pt_busy,
	/* To atg_rx_setup */
	output reg cl_valid,
	input wire cl_ready,
	output wire [701:0] cl_tri,
	output reg cl_last,
	output wire busy
);
	`include "ghci_regs.vh"
	localparam [31:0] ONE = 32'h3F800000;
	localparam [31:0] EPS = 32'h37800000;	/* 2^-16 */
	localparam [223:0] EMPTY = {96'd0, ONE, 96'd0};	/* (0, 0, 0, 1), weights 0 */

	/* STATE: VIEWPORT 0x050-0x053, DEPTH_CLAMP 0x059, RAST_MODE[6], and
	 * DRAW_RAW's words 0x1E0-0x1E8 (x, y, z of each vertex). */
	reg [31:0] rw [0:8];
	reg [127:0] vp;
	reg [1:0] dc;
	reg discard;
	always @(posedge clk)
		if (st_we && st_idx >= GHCI_S_RAW && st_idx <= GHCI_S_RAW + 9'd8)
			rw[st_idx[3:0]] <= st_wdata;
	always @(posedge clk)
		if (!rst_n) begin
			vp <= 128'd0;
			dc <= 2'd0;
			discard <= 1'b0;
		end else if (st_we) begin
			if (st_idx >= GHCI_S_VIEWPORT && st_idx < GHCI_S_VIEWPORT + 9'd4)
				vp[32 * st_idx[1:0] +: 32] <= st_wdata;
			if (st_idx == GHCI_S_DEPTH_CLAMP)
				dc <= st_wdata[1:0];
			if (st_idx == GHCI_S_RAST_MODE)
				discard <= st_wdata[6];
		end
	wire p_near = !dc[1] || !dc[0];
`ifdef MUT_FARCLIP
	localparam [6:0] PL_MUT = 7'b1111011;	/* the TB's mutation check: no far plane */
`elsif MUT_WCLIP
	localparam [6:0] PL_MUT = 7'b1111110;	/* no w plane */
`else
	localparam [6:0] PL_MUT = 7'b1111111;
`endif
	wire p_far = dc[1] && !dc[0];

	localparam [2:0] S_IDLE = 3'd0, S_READ = 3'd1, S_TRIV = 3'd2, S_LOAD = 3'd3,
		S_CMD = 3'd4, S_CWAIT = 3'd5, S_EMIT = 3'd6, S_OUT = 3'd7;
	reg [2:0] st;
	reg [23:0] ent;
	reg [2:0] fl;
	reg [1:0] kind;	/* 0 point, 1 line, 2 triangle */
	reg last, raw;
	reg [223:0] vv [0:2];	/* the vertices in PT order, word c at [32c +: 32] */
	reg [3:0] rd_n;	/* PT words requested */
	reg rd_v;	/* a word arrives this cycle */
	reg [3:0] rd_k;	/* which */
	reg [223:0] o0, o1, o2;	/* the output primitive */
	reg ofl;	/* it is the primitive's last output (it carries the flags) */
	reg [6:0] pl;	/* planes still to cut */
	reg first;
	reg [3:0] np;	/* the polygon's vertex count */
	reg [3:0] ti;	/* EMIT: the fan triangle (v0, v_ti, v_ti+1) */
	reg [2:0] es;	/* EMIT: read step */
	integer k;

	wire [223:0] vv0 = vv[0], vv1 = vv[1], vv2 = vv[2];
	wire [3:0] rd_lim = kind == 2'd0 ? 4'd4 : kind == 2'd1 ? 4'd8 : 4'd12;
	wire [1:0] nv = kind == 2'd0 ? 2'd1 : kind == 2'd1 ? 2'd2 : 2'd3;

	/* a <= b for fp32, -0 = +0, denormals by value; 0 when either is NaN. */
	function fle;
		input [31:0] a, b;
		reg [32:0] ka, kb;
		reg nan;
		begin
			nan = (a[30:23] == 8'hFF && a[22:0] != 23'd0) ||
				(b[30:23] == 8'hFF && b[22:0] != 23'd0);
			ka = a[31] ? 33'd0 - {2'd0, a[30:0]} : {2'd0, a[30:0]};
			kb = b[31] ? 33'd0 - {2'd0, b[30:0]} : {2'd0, b[30:0]};
			fle = !nan && $signed(ka) <= $signed(kb);
		end
	endfunction

	function cin;	/* z >= 0, -0 and denormals included, NaN out */
		input [31:0] z;
		cin = !(z[30:23] == 8'hFF && z[22:0] != 23'd0) && !(z[31] && z[30:23] != 8'd0);
	endfunction

	/* The trivial tests of one vertex: {x and y within 4 w, the depth
	 * planes, the w plane}.  4 w: w's exponent + 2 (w >= 2^-16 is normal). */
	wire okx = fle({1'b0, vp[94:64]}, 32'h45C00000) && fle({1'b0, vp[30:0]}, 32'h45000000);
	wire oky = fle({1'b0, vp[126:96]}, 32'h45C00000) && fle({1'b0, vp[62:32]}, 32'h45000000);
	function [2:0] vtest;
		input [30:0] ax, ay;	/* |x|, |y| */
		input [31:0] z, w;
		input pn, pf, ox, oy;
		reg [31:0] w4;
		reg wi;
		begin
			wi = fle(EPS, w);
			w4 = w[30:23] >= 8'd253 ? 32'h7F800000 : w + {9'd2, 23'd0};
			vtest = {wi && ox && oy && fle({1'b0, ax}, w4) && fle({1'b0, ay}, w4),
				(!pn || cin(z)) && (!pf || fle(z, w)), wi};
		end
	endfunction
	wire [2:0] t0 = vtest(vv0[30:0], vv0[62:32], vv0[95:64], vv0[127:96], p_near, p_far,
		okx, oky);
	wire [2:0] t1 = vtest(vv1[30:0], vv1[62:32], vv1[95:64], vv1[127:96], p_near, p_far,
		okx, oky);
	wire [2:0] t2 = vtest(vv2[30:0], vv2[62:32], vv2[95:64], vv2[127:96], p_near, p_far,
		okx, oky);
	wire [2:0] ta = t0 & (nv == 2'd1 ? 3'b111 : t1) & (nv == 2'd3 ? t2 : 3'b111);
	wire accept = &ta;
	wire guard = !ta[2];

	/* The polygon. */
	reg ld_we;
	reg [3:0] ld_idx;
	reg [223:0] ld_data;
	reg cmd_valid;
	reg [2:0] cmd_plane;
	wire cmd_ready, cp_done;
	wire [3:0] n_out;
	reg [3:0] rd_idx;
	wire [223:0] rd_data;
	atg_rx_cpoly cpoly (.clk(clk), .rst_n(rst_n), .vp(vp), .ld_we(ld_we), .ld_idx(ld_idx),
		.ld_data(ld_data), .ld_n({2'd0, nv}), .ld_line(kind == 2'd1),
		.cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_plane(cmd_plane),
		.cmd_first(first), .done(cp_done), .n_out(n_out), .rd_idx(rd_idx),
		.rd_data(rd_data));
	/* the lowest plane still to cut */
	reg [2:0] pnext;
	always @(*) begin
		pnext = 3'd0;
		for (k = 6; k >= 0; k = k - 1)
			if (pl[k])
				pnext = k[2:0];
	end

	genvar g;
	generate
	for (g = 0; g < 4; g = g + 1) begin : g_pos
		assign cl_tri[32 * g +: 32] = o0[32 * g +: 32];
		assign cl_tri[128 + 32 * g +: 32] = o1[32 * g +: 32];
		assign cl_tri[256 + 32 * g +: 32] = o2[32 * g +: 32];
	end
	for (g = 0; g < 3; g = g + 1) begin : g_wt
		assign cl_tri[384 + 32 * g +: 32] = o0[128 + 32 * g +: 32];
		assign cl_tri[480 + 32 * g +: 32] = o1[128 + 32 * g +: 32];
		assign cl_tri[576 + 32 * g +: 32] = o2[128 + 32 * g +: 32];
	end
	endgenerate
	assign cl_tri[701:672] = {kind, raw, ofl ? fl : 3'd0, ent};

	/* PT reads: vertex rd_n / 4, word rd_n % 4, data the next cycle. */
	assign pt_rd = st == S_READ && rd_n < rd_lim && !pt_busy;
	assign pt_idx = rd_n[3:2] == 2'd0 ? ent[7:0] : rd_n[3:2] == 2'd1 ? ent[15:8] : ent[23:16];
	assign pt_word = {4'd0, rd_n[1:0]};
	assign prim_ready = st == S_IDLE && !raw_kick;
	assign busy = st != S_IDLE;

	always @(posedge clk) begin
		rd_v <= pt_rd;
		rd_k <= rd_n;
		ld_we <= 1'b0;
		if (!rst_n) begin
			st <= S_IDLE;
			cl_valid <= 1'b0;
			cmd_valid <= 1'b0;
		end else case (st)
		S_IDLE:
			if (raw_kick) begin
				o0 <= {64'd0, ONE, ONE, rw[2], rw[1], rw[0]};
				o1 <= {32'd0, ONE, 32'd0, ONE, rw[5], rw[4], rw[3]};
				o2 <= {ONE, 64'd0, ONE, rw[8], rw[7], rw[6]};
				ent <= 24'd0;
				fl <= 3'd0;
				ofl <= 1'b1;
				last <= 1'b1;
				raw <= 1'b1;
				kind <= 2'd2;
				st <= S_OUT;
			end else if (prim_valid) begin
				for (k = 0; k < 3; k = k + 1)
					vv[k] <= {(k == 2) ? ONE : 32'd0, (k == 1) ? ONE : 32'd0,
						(k == 0) ? ONE : 32'd0, 128'd0};
				ent <= prim_vtx[23:0];
				fl <= prim_free;
				ofl <= 1'b1;
				last <= prim_last;
				raw <= 1'b0;
				kind <= prim_vtx[25:24] == 2'd3 ? 2'd2 : prim_vtx[25:24];
				rd_n <= 4'd0;
				if (discard) begin
					o0 <= EMPTY;
					o1 <= EMPTY;
					o2 <= EMPTY;
					kind <= 2'd2;
					st <= S_OUT;
				end else
					st <= S_READ;
			end
		S_READ: begin
			if (pt_rd)
				rd_n <= rd_n + 4'd1;
			if (rd_v)
				vv[rd_k[3:2]][32 * rd_k[1:0] +: 32] <= pt_rdata;
			if (rd_v && rd_k == rd_lim - 4'd1)
				st <= S_TRIV;
		end
		S_TRIV:
			if (kind == 2'd0) begin
				/* a point: planes 0-2 only */
				o0 <= t0[1:0] == 2'b11 ? vv0 : EMPTY;
				o1 <= t0[1:0] == 2'b11 ? vv0 : EMPTY;
				o2 <= t0[1:0] == 2'b11 ? vv0 : EMPTY;
				if (t0[1:0] != 2'b11)
					kind <= 2'd2;
				st <= S_OUT;
			end else if (accept) begin
				o0 <= vv0;
				o1 <= vv1;
				o2 <= kind == 2'd1 ? vv1 : vv2;
				st <= S_OUT;
			end else begin
				pl <= {{4{guard}}, p_far, p_near, 1'b1} & PL_MUT;
				first <= 1'b1;
				ld_we <= 1'b1;
				ld_idx <= 4'd0;
				ld_data <= vv0;
				st <= S_LOAD;
			end
		S_LOAD:
			/* vertex 1 and (a triangle) vertex 2 */
			if (ld_idx + 4'd1 < {2'd0, nv}) begin
				ld_we <= 1'b1;
				ld_idx <= ld_idx + 4'd1;
				ld_data <= ld_idx == 4'd0 ? vv1 : vv2;
			end else
				st <= S_CMD;
		S_CMD:
			if (cmd_valid) begin
				if (cmd_ready) begin
					cmd_valid <= 1'b0;
					first <= 1'b0;
					pl[cmd_plane] <= 1'b0;
					st <= S_CWAIT;
				end
			end else if (pl == 7'd0) begin
				np <= n_out;
				ti <= 4'd1;
				es <= 3'd0;
				st <= S_EMIT;
			end else begin
				cmd_valid <= 1'b1;
				cmd_plane <= pnext;
			end
		S_CWAIT:
			if (cp_done) begin
				if (n_out == 4'd0) begin
					o0 <= EMPTY;
					o1 <= EMPTY;
					o2 <= EMPTY;
					kind <= 2'd2;
					ofl <= 1'b1;
					st <= S_OUT;
				end else
					st <= S_CMD;
			end
		S_EMIT: begin
			/* read v0, v_ti, v_ti+1 (a line: v0, v1, v1); rd_data is the
			 * word of rd_idx two cycles later */
			es <= es + 3'd1;
			rd_idx <= es == 3'd0 ? 4'd0 : es == 3'd1 || kind == 2'd1 ? ti : ti + 4'd1;
			if (es == 3'd2)
				o0 <= rd_data;
			if (es == 3'd3)
				o1 <= rd_data;
			if (es == 3'd4) begin
				o2 <= rd_data;
				ofl <= kind == 2'd1 || ti + 4'd2 == np;
				st <= S_OUT;
			end
		end
		default:	/* S_OUT */
			if (cl_valid && cl_ready) begin
				cl_valid <= 1'b0;
				if (ofl)
					st <= S_IDLE;
				else begin
					ti <= ti + 4'd1;
					es <= 3'd0;
					st <= S_EMIT;
				end
			end else begin
				cl_valid <= 1'b1;
				cl_last <= last && ofl;
			end
		endcase
	end
endmodule

`default_nettype wire
