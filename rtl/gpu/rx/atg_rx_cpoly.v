/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_cpoly: the clipping polygon of one primitive: a buffer of up to
 * 10 vertices of 7 fp32 words {x, y, z, w, w0, w1, w2} (clip-space
 * position and the weights of the original vertices) and the cut of the
 * polygon, or of a line segment, by one plane at a time (Sutherland-Hodgman).
 *
 * atg_rx_clip loads the vertices (ld_*, while idle), then sends one cmd per
 * plane (cmd_first on the first: ld_n and ld_line apply); done pulses when
 * the cut is finished, with n_out the vertex count now (0: nothing left),
 * and the vertices are read back on rd_* (the next cycle, while idle).
 * Planes (inside is dist >= 0, -0 and denormals included, NaN outside):
 * 0 w - 2^-16, 1 z, 2 w - z, 3 G w - (x_off w + x_scale x), 4 G w +
 * (x_off w + x_scale x), 5 and 6 the same in y, G = 16383.  All inside:
 * the polygon is unchanged; none: n_out = 0.  Otherwise each edge (p, q)
 * from the first inside vertex after an outside one (a line: its one edge,
 * from vertex 0) gives p when p is inside and, when exactly one of p and q
 * is inside, the intersection a + (b - a) t, t = d_a / (d_a - d_b), from
 * the inside vertex a to the outside one b, on every one of the 7 words.
 * The new polygon goes to the other half of a two-polygon buffer.  One
 * fadd, fmul or fdiv at a time (the RX's fp32: round to nearest even,
 * denormals flushed).  See spec/gpu/rx/atg_rx_cpoly.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_cpoly (
	input wire clk,
	input wire rst_n,
	input wire [127:0] vp,	/* x scale, y scale, x offset, y offset */
	input wire ld_we,
	input wire [3:0] ld_idx,
	input wire [223:0] ld_data,
	input wire [3:0] ld_n,
	input wire ld_line,
	input wire cmd_valid,
	output wire cmd_ready,
	input wire [2:0] cmd_plane,
	input wire cmd_first,
	output reg done,
	output reg [3:0] n_out,
	input wire [3:0] rd_idx,
	output reg [223:0] rd_data
);
	localparam [31:0] EPS = 32'h37800000;	/* 2^-16 */
	localparam [31:0] GUARD = 32'h467FFC00;	/* 16383.0 */

	localparam [2:0] S_IDLE = 3'd0, S_DOP = 3'd1, S_DW = 3'd2, S_DEC = 3'd3, S_CUT = 3'd4,
		S_IOP = 3'd5, S_IW = 3'd6;
	reg [2:0] st;

	reg [223:0] pb [0:19];	/* two halves of 10 vertices */
	reg [31:0] dd [0:9];	/* the distances */
	reg half;	/* the current polygon's half */
	reg [3:0] n;	/* its vertex count */
	reg line;
	reg [2:0] plane;
	reg [3:0] i;	/* DIST: vertex */
	reg [2:0] ph;	/* operation of a sequence */
	reg [31:0] t0, t1;
	reg [3:0] j, k, m;	/* CUT: start, edge, vertices written */
	reg cdone;	/* CUT: edge k's vertex handled */
	reg [3:0] ia, ib;	/* the edge's inside and outside vertices */
	reg [2:0] c;	/* ISECT: word */
	reg [223:0] xi;
	integer q;

	function [4:0] adr;
		input h;
		input [3:0] x;
		adr = h ? {1'b0, x} + 5'd10 : {1'b0, x};
	endfunction

	/* Inside: dist >= 0, -0 and denormals included, NaN outside. */
	function cin;
		input [31:0] d;
		cin = !(d[30:23] == 8'hFF && d[22:0] != 23'd0) && !(d[31] && d[30:23] != 8'd0);
	endfunction

	wire [9:0] ins;
	genvar g;
	generate
	for (g = 0; g < 10; g = g + 1) begin : g_in
		assign ins[g] = cin(dd[g]);
	end
	endgenerate
	wire [9:0] vmask = (10'd1 << n) - 10'd1;
	wire all_in = (ins & vmask) == vmask;
	wire none_in = (ins & vmask) == 10'd0;
	/* The first inside vertex after an outside one (a triangle). */
	wire [15:0] ins16 = {6'd0, ins};
	wire [9:0] prv = {ins[8:0], ins16[n - 4'd1]};	/* the vertex before is inside */
	reg [3:0] jsel;
	always @(*) begin
		jsel = 4'd0;
		for (q = 9; q >= 0; q = q - 1)
			if (q < n && ins[q] && !prv[q])
				/* verilator lint_off WIDTHTRUNC */
				jsel = q;
				/* verilator lint_on WIDTHTRUNC */
	end

	/* CUT: edge k from p = (j + k) mod n to its successor. */
	wire [4:0] psum = {1'b0, j} + {1'b0, k};
	wire [3:0] pi = psum >= {1'b0, n} ? psum[3:0] - n : psum[3:0];
	wire [3:0] qi = pi + 4'd1 == n ? 4'd0 : pi + 4'd1;
	wire cut_end = line ? k == 4'd2 : k == n;
	wire xing = ins[pi] != ins[qi] && (!line || k == 4'd0);

	/* The operands of the sequences. */
	wire [223:0] vd = pb[adr(half, i)];
	wire [223:0] va = pb[adr(half, ia)];
	wire [223:0] vb = pb[adr(half, ib)];
	wire gy = plane == 3'd5 || plane == 3'd6;
	wire [31:0] g_c = gy ? vd[63:32] : vd[31:0];
	wire [31:0] g_sc = gy ? vp[63:32] : vp[31:0];
	wire [31:0] g_of = gy ? vp[127:96] : vp[95:64];
	wire [31:0] a_c = va[32 * c +: 32];
	wire [31:0] b_c = vb[32 * c +: 32];
	wire [31:0] d_a = dd[ia];
	wire [31:0] d_b = dd[ib];
	reg [1:0] op;	/* 0 fadd, 1 fmul, 2 fdiv */
	reg [31:0] op_a, op_b;
	reg op_sub;
	always @(*) begin
		op = 2'd0;
		op_a = 32'd0;
		op_b = 32'd0;
		op_sub = 1'b0;
		if (st == S_DOP)
			case (plane)
			3'd0: begin
				op_a = vd[127:96];
				op_b = EPS;
				op_sub = 1'b1;
			end
			3'd2: begin
				op_a = vd[127:96];
				op_b = vd[95:64];
				op_sub = 1'b1;
			end
			default:
				case (ph)
				3'd0: begin
					op = 2'd1;
					op_a = g_of;
					op_b = vd[127:96];
				end
				3'd1: begin
					op = 2'd1;
					op_a = g_sc;
					op_b = g_c;
				end
				3'd2: begin
					op_a = t0;
					op_b = t1;
				end
				3'd3: begin
					op = 2'd1;
					op_a = GUARD;
					op_b = vd[127:96];
				end
				default: begin
					op_a = t1;
					op_b = t0;
					op_sub = plane == 3'd3 || plane == 3'd5;
				end
				endcase
			endcase
		else
			case (ph)
			3'd0: begin
				op_a = d_a;
				op_b = d_b;
				op_sub = 1'b1;
			end
			3'd1: begin
				op = 2'd2;
				op_a = d_a;
				op_b = t0;
			end
			3'd2: begin
				op_a = b_c;
				op_b = a_c;
				op_sub = 1'b1;
			end
			3'd3: begin
				op = 2'd1;
				op_a = t0;
				op_b = t1;
			end
			default: begin
				op_a = a_c;
				op_b = t0;
			end
			endcase
	end

	wire issue = st == S_DOP || st == S_IOP;
	wire [4:0] a_ld = adr(half, ld_idx);
	wire [4:0] a_new = adr(!half, m);
	wire [4:0] a_p = adr(half, pi);
	wire [4:0] a_rd = adr(half, rd_idx);
	wire fa_o, fm_o, fd_o, fd_busy;
	wire [31:0] fa_r, fm_r, fd_r;
	atg_rx_fadd fadd (.clk(clk), .rst_n(rst_n), .i_valid(issue && op == 2'd0), .i_a(op_a),
		.i_b(op_b), .i_sub(op_sub), .o_valid(fa_o), .o_r(fa_r));
	atg_rx_fmul fmul (.clk(clk), .rst_n(rst_n), .i_valid(issue && op == 2'd1), .i_a(op_a),
		.i_b(op_b), .o_valid(fm_o), .o_r(fm_r));
	atg_rx_fdiv fdiv (.clk(clk), .rst_n(rst_n), .i_start(issue && op == 2'd2), .i_a(op_a),
		.i_b(op_b), .busy(fd_busy), .o_done(fd_o), .o_r(fd_r));
	wire res_v = fa_o || fm_o || fd_o;
	wire [31:0] res = fa_o ? fa_r : fm_o ? fm_r : fd_r;
	/* the last operation of a distance: planes 0 and 2 have one, 3-6 five */
	wire d_last = plane == 3'd0 || plane == 3'd2 || ph == 3'd4;

	assign cmd_ready = st == S_IDLE;

	always @(posedge clk) begin
		rd_data <= pb[a_rd];
		done <= 1'b0;
		if (!rst_n) begin
			st <= S_IDLE;
			half <= 1'b0;
			n <= 4'd0;
			line <= 1'b0;
			n_out <= 4'd0;
		end else case (st)
		S_IDLE: begin
			if (ld_we)
				pb[a_ld] <= ld_data;
			if (cmd_valid) begin
				plane <= cmd_plane;
				if (cmd_first) begin
					n <= ld_n;
					line <= ld_line;
				end
				i <= 4'd0;
				ph <= 3'd0;
				st <= S_DOP;
			end
		end
		S_DOP:
			if (plane == 3'd1) begin
				dd[i] <= vd[95:64];
				i <= i + 4'd1;
				if (i + 4'd1 == n)
					st <= S_DEC;
			end else
				st <= S_DW;
		S_DW:
			if (res_v) begin
				if (d_last) begin
					dd[i] <= res;
					ph <= 3'd0;
					i <= i + 4'd1;
					st <= i + 4'd1 == n ? S_DEC : S_DOP;
				end else begin
					if (ph == 3'd0 || ph == 3'd2)
						t0 <= res;
					else
						t1 <= res;
					ph <= ph + 3'd1;
					st <= S_DOP;
				end
			end
		S_DEC:
			if (all_in || none_in) begin
				done <= 1'b1;
				n_out <= none_in ? 4'd0 : n;
				if (none_in)
					n <= 4'd0;
				st <= S_IDLE;
			end else begin
				j <= line ? 4'd0 : jsel;
				k <= 4'd0;
				m <= 4'd0;
				cdone <= 1'b0;
				st <= S_CUT;
			end
		S_CUT:
			if (cut_end) begin
				half <= !half;
				n <= m;
				n_out <= m;
				done <= 1'b1;
				st <= S_IDLE;
			end else if (!cdone) begin
				if (ins[pi]) begin
					pb[a_new] <= pb[a_p];
					m <= m + 4'd1;
				end
				cdone <= 1'b1;
			end else if (xing) begin
				ia <= ins[pi] ? pi : qi;
				ib <= ins[pi] ? qi : pi;
				ph <= 3'd0;
				c <= 3'd0;
				st <= S_IOP;
			end else begin
				k <= k + 4'd1;
				cdone <= 1'b0;
			end
		S_IOP:
			st <= S_IW;
		default:	/* S_IW */
			if (res_v) begin
				st <= S_IOP;
				case (ph)
				3'd0: t0 <= res;
				3'd1: t1 <= res;	/* t */
				3'd2, 3'd3: t0 <= res;	/* u */
				default: xi[32 * c +: 32] <= res;
				endcase
				ph <= ph == 3'd4 ? 3'd2 : ph + 3'd1;
				if (ph == 3'd4) begin
					c <= c + 3'd1;
					if (c == 3'd6) begin
						pb[a_new] <= {res, xi[191:0]};
						m <= m + 4'd1;
						k <= k + 4'd1;
						cdone <= 1'b0;
						st <= S_CUT;
					end
				end
			end
		endcase
	end

	wire unused_ok = &{1'b0, fd_busy, xi[223:192], vd[223:128], ins16[15:10]};
endmodule

`default_nettype wire
