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
	(* max_fanout = 16 *) reg [2:0] st;

	reg [31:0] pb [0:6][0:19];	/* seven 32-bit slices of two halves of 10 vertices */
	reg [31:0] dd [0:9];	/* the distances */
	reg half;	/* the current polygon's half */
	reg [3:0] n;	/* its vertex count */
	reg line;
	reg [2:0] plane;
	reg [3:0] i;	/* DIST: vertex */
	reg [2:0] ph;	/* operation of a sequence */
	reg [31:0] t0, t1;
	reg [3:0] j, k, m;	/* CUT: start, edge, vertices written */
	reg [1:0] cdone;	/* CUT: edge k's vertex handled */
	reg [9:0] r_ins;
	reg [223:0] r_pbp;
	reg [3:0] ia, ib;	/* the edge's inside and outside vertices */
	reg [2:0] c;	/* ISECT: word */
	reg [223:0] xi;
	integer q, gs_idx;

	/* The entry of vertex x of half h: x + 10 h (one adder an address). */
	wire [4:0] a_vd, a_va, a_vb, a_ld, a_new, a_p, a_rd;

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
	reg [9:0] vmask;	/* (1 << n) - 1: the vertices below n */
	integer vq;
	always @(*)
		for (vq = 0; vq < 10; vq = vq + 1)
			vmask[vq] = vq < {28'd0, n};
	/* n - 1; CUT's p and its successor q; the counters + 1 */
	wire [3:0] nm1, i1, m1, k1;
	reg [3:0] pi, qi;
	wire [2:0] ph1, c1;
	wire [8:0] cp_carry_unused;
	wire [6:0] adr_carry_unused;
	am_add #(.W(5)) u_a_vd (.a({1'b0, i}), .b(half ? 5'd10 : 5'd0), .ci(1'b0), .s(a_vd),
		.co(adr_carry_unused[0]));
	am_add #(.W(5)) u_a_va (.a({1'b0, ia}), .b(half ? 5'd10 : 5'd0), .ci(1'b0), .s(a_va),
		.co(adr_carry_unused[1]));
	am_add #(.W(5)) u_a_vb (.a({1'b0, ib}), .b(half ? 5'd10 : 5'd0), .ci(1'b0), .s(a_vb),
		.co(adr_carry_unused[2]));
	am_add #(.W(5)) u_a_ld (.a({1'b0, ld_idx}), .b(half ? 5'd10 : 5'd0), .ci(1'b0), .s(a_ld),
		.co(adr_carry_unused[3]));
	am_add #(.W(5)) u_a_new (.a({1'b0, m}), .b(half ? 5'd0 : 5'd10), .ci(1'b0), .s(a_new),
		.co(adr_carry_unused[4]));
	am_add #(.W(5)) u_a_p (.a({1'b0, pi}), .b(half ? 5'd10 : 5'd0), .ci(1'b0), .s(a_p),
		.co(adr_carry_unused[5]));
	am_add #(.W(5)) u_a_rd (.a({1'b0, rd_idx}), .b(half ? 5'd10 : 5'd0), .ci(1'b0), .s(a_rd),
		.co(adr_carry_unused[6]));

	/* Address tree buffers for the 7 word slices of pb to limit fanout to 16 */
	(* keep = "true" *) wire [4:0] a_vd_b [0:6];
	(* keep = "true" *) wire [4:0] a_rd_b [0:6];
	(* keep = "true" *) wire [4:0] a_ld_b [0:6];
	(* keep = "true" *) wire [4:0] a_p_b  [0:6];
	(* keep = "true" *) wire [4:0] a_new_b[0:6];
	(* keep = "true" *) wire [4:0] a_va_b [0:6];
	(* keep = "true" *) wire [4:0] a_vb_b [0:6];

`ifdef SYNTH_KINTEX7
	genvar gi_s, gi_b;
	generate
	for (gi_s = 0; gi_s < 7; gi_s = gi_s + 1) begin : g_addr_buf
		for (gi_b = 0; gi_b < 5; gi_b = gi_b + 1) begin : g_bits
			LUT1 #(.INIT(2'h2)) u_b_vd (.I0(a_vd[gi_b]),  .O(a_vd_b[gi_s][gi_b]));
			LUT1 #(.INIT(2'h2)) u_b_rd (.I0(a_rd[gi_b]),  .O(a_rd_b[gi_s][gi_b]));
			LUT1 #(.INIT(2'h2)) u_b_ld (.I0(a_ld[gi_b]),  .O(a_ld_b[gi_s][gi_b]));
			LUT1 #(.INIT(2'h2)) u_b_p  (.I0(a_p[gi_b]),   .O(a_p_b[gi_s][gi_b]));
			LUT1 #(.INIT(2'h2)) u_b_nw (.I0(a_new[gi_b]), .O(a_new_b[gi_s][gi_b]));
			LUT1 #(.INIT(2'h2)) u_b_va (.I0(a_va[gi_b]),  .O(a_va_b[gi_s][gi_b]));
			LUT1 #(.INIT(2'h2)) u_b_vb (.I0(a_vb[gi_b]),  .O(a_vb_b[gi_s][gi_b]));
		end
	end
	endgenerate
`else
	genvar gi_s;
	generate
	for (gi_s = 0; gi_s < 7; gi_s = gi_s + 1) begin : g_addr_direct
		assign a_vd_b[gi_s]  = a_vd;
		assign a_rd_b[gi_s]  = a_rd;
		assign a_ld_b[gi_s]  = a_ld;
		assign a_p_b[gi_s]   = a_p;
		assign a_new_b[gi_s] = a_new;
		assign a_va_b[gi_s]  = a_va;
		assign a_vb_b[gi_s]  = a_vb;
	end
	endgenerate
`endif
	am_sub #(.W(4)) u_nm1 (.a(n), .b(4'd0), .bi(1'b1), .d(nm1), .bo(cp_carry_unused[0]));
	wire [3:0] j_init = line ? 4'd0 : jsel;
	wire [3:0] j1;
	am_add #(.W(4)) u_j1 (.a(j_init), .b(4'd0), .ci(1'b1), .s(j1), .co(cp_carry_unused[1]));
	wire [3:0] q_init = (j1 == n) ? 4'd0 : j1;
	wire [3:0] qi1;
	am_add #(.W(4)) u_qi1 (.a(qi), .b(4'd0), .ci(1'b1), .s(qi1), .co(cp_carry_unused[2]));
	wire [3:0] next_qi = (qi1 == n) ? 4'd0 : qi1;
	assign cp_carry_unused[3] = 1'b0;
	am_add #(.W(4)) u_i1 (.a(i), .b(4'd0), .ci(1'b1), .s(i1), .co(cp_carry_unused[4]));
	am_add #(.W(4)) u_m1 (.a(m), .b(4'd0), .ci(1'b1), .s(m1), .co(cp_carry_unused[5]));
	am_add #(.W(4)) u_k1 (.a(k), .b(4'd0), .ci(1'b1), .s(k1), .co(cp_carry_unused[6]));
	am_add #(.W(3)) u_ph1 (.a(ph), .b(3'd0), .ci(1'b1), .s(ph1), .co(cp_carry_unused[7]));
	am_add #(.W(3)) u_c1 (.a(c), .b(3'd0), .ci(1'b1), .s(c1), .co(cp_carry_unused[8]));
	wire all_in = (ins & vmask) == vmask;
	wire none_in = (ins & vmask) == 10'd0;
	/* The first inside vertex after an outside one (a triangle). */
	wire [15:0] ins16 = {6'd0, ins};
	wire [9:0] prv = {ins[8:0], ins16[nm1]};	/* the vertex before is inside */
	reg [3:0] jsel;
	always @(*) begin
		jsel = 4'd0;
		for (q = 9; q >= 0; q = q - 1)
			if (q < n && ins[q] && !prv[q])
				/* verilator lint_off WIDTHTRUNC */
				jsel = q;
				/* verilator lint_on WIDTHTRUNC */
	end

	/* CUT: edge k from vertex pi to its successor qi */
	wire cut_end = line ? k == 4'd2 : k == n;
	wire xing = r_ins[pi] != r_ins[qi] && (!line || k == 4'd0);

	/* The operands of the sequences. */
	wire [223:0] vd;
	generate
	for (gi_s = 0; gi_s < 7; gi_s = gi_s + 1) begin : g_vd_slice
		assign vd[32 * gi_s +: 32] = pb[gi_s][a_vd_b[gi_s]];
	end
	endgenerate
	/* Buffered edge vertices for intersection */
	reg [223:0] r_va, r_vb;
	wire gy = plane == 3'd5 || plane == 3'd6;
	wire [31:0] g_c = gy ? vd[63:32] : vd[31:0];
	wire [31:0] g_sc = gy ? vp[63:32] : vp[31:0];
	wire [31:0] g_of = gy ? vp[127:96] : vp[95:64];
	wire [31:0] a_c = r_va[32 * c +: 32];
	wire [31:0] b_c = r_vb[32 * c +: 32];
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

	wire fa_o, fm_o, fd_o, fd_busy;
	wire [31:0] fa_r, fm_r, fd_r;
	reg r_fa_v, r_fm_v, r_fd_v;
	reg [31:0] r_op_a, r_op_b;
	reg r_op_sub;
	atg_rx_fadd #(.LAT(4)) fadd (.clk(clk), .rst_n(rst_n), .i_valid(r_fa_v), .i_a(r_op_a),
		.i_b(r_op_b), .i_sub(r_op_sub), .o_valid(fa_o), .o_r(fa_r));
	atg_rx_fmul #(.LAT(4)) fmul (.clk(clk), .rst_n(rst_n), .i_valid(r_fm_v), .i_a(r_op_a),
		.i_b(r_op_b), .o_valid(fm_o), .o_r(fm_r));
	atg_rx_fdiv fdiv (.clk(clk), .rst_n(rst_n), .i_start(r_fd_v), .i_a(r_op_a),
		.i_b(r_op_b), .busy(fd_busy), .o_done(fd_o), .o_r(fd_r));
	wire res_v = fa_o || fm_o || fd_o;
	wire [31:0] res = fa_o ? fa_r : fm_o ? fm_r : fd_r;
	/* the last operation of a distance: planes 0 and 2 have one, 3-6 five */
	wire d_last = plane == 3'd0 || plane == 3'd2 || ph == 3'd4;

	assign cmd_ready = st == S_IDLE;

	always @(posedge clk) begin
		for (gs_idx = 0; gs_idx < 7; gs_idx = gs_idx + 1)
			rd_data[32 * gs_idx +: 32] <= pb[gs_idx][a_rd_b[gs_idx]];
		done <= 1'b0;
		r_fa_v <= 1'b0;
		r_fm_v <= 1'b0;
		r_fd_v <= 1'b0;
		if (!rst_n) begin
			st <= S_IDLE;
			half <= 1'b0;
			n <= 4'd0;
			line <= 1'b0;
			n_out <= 4'd0;
			pi <= 4'd0;
			qi <= 4'd0;
			cdone <= 2'd0;
			r_ins <= 10'd0;
			r_pbp <= 224'd0;
			r_va <= 224'd0;
			r_vb <= 224'd0;
			r_op_a <= 32'd0;
			r_op_b <= 32'd0;
			r_op_sub <= 1'b0;
		end else case (st)
		S_IDLE: begin
			if (ld_we)
				for (gs_idx = 0; gs_idx < 7; gs_idx = gs_idx + 1)
					pb[gs_idx][a_ld_b[gs_idx]] <= ld_data[32 * gs_idx +: 32];
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
				i <= i1;
				if (i1 == n)
					st <= S_DEC;
			end else begin
				r_op_a <= op_a;
				r_op_b <= op_b;
				r_op_sub <= op_sub;
				r_fa_v <= op == 2'd0;
				r_fm_v <= op == 2'd1;
				r_fd_v <= op == 2'd2;
				st <= S_DW;
			end
		S_DW:
			if (res_v) begin
				if (d_last) begin
					dd[i] <= res;
					ph <= 3'd0;
					i <= i1;
					st <= i1 == n ? S_DEC : S_DOP;
				end else begin
					if (ph == 3'd0 || ph == 3'd2)
						t0 <= res;
					else
						t1 <= res;
					ph <= ph1;
					st <= S_DOP;
				end
			end
		S_DEC: begin
			r_ins <= ins;
			if (all_in || none_in) begin
				done <= 1'b1;
				n_out <= none_in ? 4'd0 : n;
				if (none_in)
					n <= 4'd0;
				st <= S_IDLE;
			end else begin
				j <= line ? 4'd0 : jsel;
				pi <= line ? 4'd0 : jsel;
				qi <= q_init;
				k <= 4'd0;
				m <= 4'd0;
				cdone <= 2'd0;
				st <= S_CUT;
			end
		end
		S_CUT:
			if (cut_end) begin
				half <= !half;
				n <= m;
				n_out <= m;
				done <= 1'b1;
				st <= S_IDLE;
			end else if (cdone == 2'd0) begin
				if (r_ins[pi]) begin
					for (gs_idx = 0; gs_idx < 7; gs_idx = gs_idx + 1)
						r_pbp[32 * gs_idx +: 32] <= pb[gs_idx][a_p_b[gs_idx]];
					cdone <= 2'd1;
				end else begin
					cdone <= 2'd2;
				end
			end else if (cdone == 2'd1) begin
				for (gs_idx = 0; gs_idx < 7; gs_idx = gs_idx + 1)
					pb[gs_idx][a_new_b[gs_idx]] <= r_pbp[32 * gs_idx +: 32];
				m <= m1;
				cdone <= 2'd2;
			end else if (xing) begin
				ia <= r_ins[pi] ? pi : qi;
				ib <= r_ins[pi] ? qi : pi;
				ph <= 3'd0;
				c <= 3'd0;
				st <= S_IOP;
			end else begin
				k <= k1;
				pi <= qi;
				qi <= next_qi;
				cdone <= 2'd0;
			end
		S_IOP: begin
			if (ph == 3'd0) begin
				for (gs_idx = 0; gs_idx < 7; gs_idx = gs_idx + 1) begin
					r_va[32 * gs_idx +: 32] <= pb[gs_idx][a_va_b[gs_idx]];
					r_vb[32 * gs_idx +: 32] <= pb[gs_idx][a_vb_b[gs_idx]];
				end
			end
			r_op_a <= op_a;
			r_op_b <= op_b;
			r_op_sub <= op_sub;
			r_fa_v <= op == 2'd0;
			r_fm_v <= op == 2'd1;
			r_fd_v <= op == 2'd2;
			st <= S_IW;
		end
		default:	/* S_IW */
			if (res_v) begin
				st <= S_IOP;
				case (ph)
				3'd0: t0 <= res;
				3'd1: t1 <= res;	/* t */
				3'd2, 3'd3: t0 <= res;	/* u */
				default: xi[32 * c +: 32] <= res;
				endcase
				ph <= ph == 3'd4 ? 3'd2 : ph1;
				if (ph == 3'd4) begin
					c <= c1;
					if (c == 3'd6) begin
						for (gs_idx = 0; gs_idx < 7; gs_idx = gs_idx + 1)
							pb[gs_idx][a_new_b[gs_idx]] <= (gs_idx == 6) ? res : xi[32 * gs_idx +: 32];
						m <= m1;
						k <= k1;
						pi <= qi;
						qi <= next_qi;
						cdone <= 2'd0;
						st <= S_CUT;
					end
				end
			end
		endcase
	end

	wire unused_ok = &{1'b0, fd_busy, xi[223:192], vd[223:128], ins16[15:10]};
endmodule

`default_nettype wire
