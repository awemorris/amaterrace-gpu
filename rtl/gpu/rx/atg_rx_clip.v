/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_clip: RX primitive input and near-plane clipping: reads the three
 * vertices' clip-space positions from the PT (or DRAW_RAW's screen-space
 * vertices from STATE 0x1E0-0x1E8), clips against the near plane (one
 * triangle → 0, 1 or 2), and passes triangles with weights relative to the
 * original vertices.
 *
 * A vertex is 7 fp32 words {x, y, z, w, w0, w1, w2} (position and its
 * weights of the original vertices).  Inside is z >= 0 (Vulkan).  The
 * intersection of an edge from an is_in vertex p to an outside one q is
 * p + (q - p) t, t = p.z / (p.z - q.z), on one fadd, one fmul and one
 * fdiv, one operation at a time.  See spec/gpu/rx/atg_rx_clip.md.
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
	input wire [23:0] prim_vtx,
	input wire [2:0] prim_free,
	input wire prim_last,
	/* PT read (shared with atg_rx_scan in atg_rx: scan has priority) */
	output wire pt_rd,
	output wire [7:0] pt_idx,
	output wire [5:0] pt_word,
	input wire [31:0] pt_rdata,
	input wire pt_busy,
	/* Triangles to atg_rx_setup */
	output reg cl_valid,
	input wire cl_ready,
	output wire [699:0] cl_tri,
	output reg cl_last,
	output wire busy
);
	localparam [31:0] ONE = 32'h3F800000;

	/* DRAW_RAW's words, STATE 0x1E0-0x1E8 (x, y, z of each vertex). */
	reg [31:0] rw [0:8];
	always @(posedge clk)
		if (st_we && st_idx >= 9'h1E0 && st_idx <= 9'h1E8)
			rw[st_idx[3:0]] <= st_wdata;

	localparam [2:0] S_IDLE = 3'd0, S_READ = 3'd1, S_CLIP = 3'd2, S_GO = 3'd3, S_WAIT = 3'd4,
		S_OUT = 3'd5;
	reg [2:0] st;
	reg [23:0] ent;
	reg [2:0] fl;
	reg last, raw;
	reg [223:0] vv [0:2];	/* the vertices in PT order, word c at [32c +: 32] */
	reg [223:0] xi [0:1];	/* the intersections */
	reg [3:0] rd_n;	/* PT words requested */
	reg rd_v;	/* a word arrives this cycle */
	reg [3:0] rd_k;	/* which */
	reg [1:0] r;	/* rotation: A = vv[r] */
	reg [1:0] n;	/* is_in vertices */
	reg ii;	/* intersection */
	reg [2:0] c;	/* word of the intersection */
	reg [1:0] sub;	/* 0 q - p, 1 x t, 2 p + ; with c = 7: 0 p.z - q.z, 1 p.z / d */
	reg [31:0] dt, tt, u;
	reg oi;	/* output triangle of two */
	integer k;

	wire [223:0] vv0 = vv[0], vv1 = vv[1], vv2 = vv[2], xi0 = xi[0], xi1 = xi[1];

	function [1:0] add3;
		input [1:0] a;
		input [1:0] b;
		add3 = (a + b) >= 2'd3 || a + b < a ? a + b - 2'd3 : a + b;
	endfunction

	/* Vertex s of the rotated triangle (A, B, C). */
	function [223:0] rot;
		input [1:0] s;
		input [1:0] rr;
		input [223:0] a0, a1, a2;
		reg [1:0] i;
		begin
			i = add3(rr, s);
			rot = i == 2'd0 ? a0 : i == 2'd1 ? a1 : a2;
		end
	endfunction

	function is_in;	/* z >= 0, -0 and denormals included, NaN out */
		input [31:0] z;
		is_in = !(z[30:23] == 8'hFF && z[22:0] != 23'd0) && !(z[31] && z[30:23] != 8'd0);
	endfunction

	wire [2:0] ins = {is_in(vv2[95:64]), is_in(vv1[95:64]), is_in(vv0[95:64])};
	wire [1:0] nin = {1'b0, ins[0]} + {1'b0, ins[1]} + {1'b0, ins[2]};
	reg [1:0] rsel;
	always @(*) begin
		rsel = 2'd0;
		for (k = 2; k >= 0; k = k - 1)
			if ((nin == 2'd1 && ins[k]) || (nin == 2'd2 && ins[k] && ins[(k + 1) % 3]))
				rsel = k[1:0];
	end

	/* The edge of intersection ii: from p (is_in) to q. */
	wire [223:0] va = rot(2'd0, r, vv0, vv1, vv2);
	wire [223:0] vb = rot(2'd1, r, vv0, vv1, vv2);
	wire [223:0] vc = rot(2'd2, r, vv0, vv1, vv2);
	wire [223:0] pv = n == 2'd2 && !ii ? vb : va;
	wire [223:0] qv = !ii && n == 2'd1 ? vb : vc;
	wire [31:0] p_c = pv[32 * c +: 32];
	wire [31:0] q_c = qv[32 * c +: 32];

	/* The fp units and the operation of (c, sub). */
	reg fa_v, fm_v, fd_v;
	wire fa_o, fm_o, fd_o, fd_busy;
	wire [31:0] fa_r, fm_r, fd_r;
	wire pre = c == 3'd7;
	wire [31:0] fa_a = pre ? pv[95:64] : sub == 2'd0 ? q_c : p_c;
	wire [31:0] fa_b = pre ? qv[95:64] : sub == 2'd0 ? p_c : u;
	atg_rx_fadd fadd (.clk(clk), .rst_n(rst_n), .i_valid(fa_v), .i_a(fa_a), .i_b(fa_b),
		.i_sub(pre || sub == 2'd0), .o_valid(fa_o), .o_r(fa_r));
	atg_rx_fmul fmul (.clk(clk), .rst_n(rst_n), .i_valid(fm_v), .i_a(u), .i_b(tt),
		.o_valid(fm_o), .o_r(fm_r));
	atg_rx_fdiv fdiv (.clk(clk), .rst_n(rst_n), .i_start(fd_v), .i_a(pv[95:64]), .i_b(dt),
		.busy(fd_busy), .o_done(fd_o), .o_r(fd_r));
	wire [31:0] res = fa_o ? fa_r : fm_o ? fm_r : fd_r;

	/* The output triangle (spec §4). */
	reg [223:0] o0, o1, o2;
	always @(*) begin
		o0 = va;
		o1 = vb;
		o2 = vc;
		if (n == 2'd0) begin
			o0 = {96'd0, ONE, 96'd0};
			o1 = o0;
			o2 = o0;
		end else if (n == 2'd1) begin
			o1 = xi0;
			o2 = xi1;
		end else if (n == 2'd2) begin
			o2 = xi0;
			if (oi) begin
				o1 = xi0;
				o2 = xi1;
			end
		end
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
	assign cl_tri[699:672] = {raw, n == 2'd2 && !oi ? 3'd0 : fl, ent};

	/* PT reads: vertex rd_n / 4, word rd_n % 4, data the next cycle. */
	assign pt_rd = st == S_READ && rd_n < 4'd12 && !pt_busy;
	assign pt_idx = rd_n[3:2] == 2'd0 ? ent[7:0] : rd_n[3:2] == 2'd1 ? ent[15:8] : ent[23:16];
	assign pt_word = {4'd0, rd_n[1:0]};
	assign prim_ready = st == S_IDLE && !raw_kick;
	assign busy = st != S_IDLE;

	always @(posedge clk) begin
		fa_v <= 1'b0;
		fm_v <= 1'b0;
		fd_v <= 1'b0;
		rd_v <= pt_rd;
		rd_k <= rd_n;
		if (!rst_n) begin
			st <= S_IDLE;
			cl_valid <= 1'b0;
		end else case (st)
		S_IDLE: begin
			oi <= 1'b0;
			if (raw_kick) begin
				for (k = 0; k < 3; k = k + 1)
					vv[k] <= {(k == 2) ? ONE : 32'd0, (k == 1) ? ONE : 32'd0,
						(k == 0) ? ONE : 32'd0, ONE, rw[3 * k + 2], rw[3 * k + 1], rw[3 * k]};
				ent <= 24'd0;
				fl <= 3'd0;
				last <= 1'b1;
				raw <= 1'b1;
				r <= 2'd0;
				n <= 2'd3;
				st <= S_OUT;
			end else if (prim_valid) begin
				for (k = 0; k < 3; k = k + 1)
					vv[k] <= {(k == 2) ? ONE : 32'd0, (k == 1) ? ONE : 32'd0,
						(k == 0) ? ONE : 32'd0, 128'd0};
				ent <= prim_vtx;
				fl <= prim_free;
				last <= prim_last;
				raw <= 1'b0;
				rd_n <= 4'd0;
				st <= S_READ;
			end
		end
		S_READ: begin
			if (pt_rd)
				rd_n <= rd_n + 4'd1;
			if (rd_v)
				vv[rd_k[3:2]][32 * rd_k[1:0] +: 32] <= pt_rdata;
			if (rd_v && rd_k == 4'd11)
				st <= S_CLIP;
		end
		S_CLIP: begin
			n <= nin == 2'd3 ? 2'd3 : nin;
			r <= nin == 2'd3 ? 2'd0 : rsel;
			ii <= 1'b0;
			c <= 3'd7;
			sub <= 2'd0;
			st <= nin == 2'd3 || nin == 2'd0 ? S_OUT : S_GO;
		end
		S_GO: begin
			fa_v <= !pre ? sub != 2'd1 : sub == 2'd0;
			fm_v <= !pre && sub == 2'd1;
			fd_v <= pre && sub == 2'd1;
			st <= S_WAIT;
		end
		S_WAIT:
			if (fa_o || fm_o || fd_o) begin
				st <= S_GO;
				if (pre) begin
					if (sub == 2'd0)
						dt <= res;
					else
						tt <= res;
					sub <= sub + 2'd1;
					if (sub == 2'd1) begin
						c <= 3'd0;
						sub <= 2'd0;
					end
				end else begin
					if (sub == 2'd2)
						xi[ii][32 * c +: 32] <= res;
					else
						u <= res;
					sub <= sub == 2'd2 ? 2'd0 : sub + 2'd1;
					if (sub == 2'd2) begin
						c <= c + 3'd1;
						if (c == 3'd6) begin
							c <= 3'd7;
							ii <= 1'b1;
							if (ii)
								st <= S_OUT;
						end
					end
				end
			end
		default: begin	/* S_OUT: one or two triangles */
			cl_valid <= 1'b1;
			cl_last <= last && !(n == 2'd2 && !oi);
			if (cl_valid && cl_ready) begin
				cl_valid <= 1'b0;
				if (n == 2'd2 && !oi)
					oi <= 1'b1;
				else
					st <= S_IDLE;
			end
		end
		endcase
	end

	wire unused_ok = &{1'b0, fd_busy};
endmodule

`default_nettype wire
