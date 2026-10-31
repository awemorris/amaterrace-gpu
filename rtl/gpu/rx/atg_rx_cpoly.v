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

(* keep_hierarchy = "yes" *)
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
		S_IOP = 3'd5, S_IW = 3'd6, S_DFETCH = 3'd7;
	(* max_fanout = 16 *) reg [2:0] st;
	wire rst_sync = !rst_n;

	/* Two 10-vertex buffers sliced into 14 x 16-bit words (224 bits total) */
	reg [15:0] pb0 [0:13][0:9];
	reg [15:0] pb1 [0:13][0:9];
	reg [31:0] dd [0:9];	/* the distances */
	reg [127:0] r_vd;	/* registered vertex {x, y, z, w} for S_DOP */
	reg half;	/* the current polygon's half */
	(* dont_touch = "true" *) reg [9:0] r_half_v;
	(* dont_touch = "true" *) reg [13:0] r_half_w0;
	(* dont_touch = "true" *) reg [13:0] r_half_w1;
	(* dont_touch = "true" *) reg [13:0] r_half_d0;
	(* dont_touch = "true" *) reg [13:0] r_half_d1;
	(* max_fanout = 16 *) reg [3:0] n;	/* its vertex count */
	(* max_fanout = 16 *) reg line;
	(* max_fanout = 16 *) reg r_cut_end;
	(* max_fanout = 16 *) reg [2:0] plane;
	(* dont_touch = "true" *) reg [2:0] r_plane_a [0:7];
	(* dont_touch = "true" *) reg [2:0] r_plane_b [0:7];
	(* dont_touch = "true" *) reg [1:0] r_gy_c;
	(* dont_touch = "true" *) reg [1:0] r_gy_sc;
	(* dont_touch = "true" *) reg [1:0] r_gy_of;
	(* max_fanout = 16 *) reg [3:0] i;	/* DIST: vertex */
	(* dont_touch = "true", extract_reset = "no" *) reg [3:0] r_i_rep [0:3];
	(* max_fanout = 16 *) reg [2:0] ph;	/* operation of a sequence */
	(* dont_touch = "true", extract_reset = "no" *) reg [2:0] r_ph_a [0:7];
	(* dont_touch = "true", extract_reset = "no" *) reg [2:0] r_ph_b [0:7];
	(* dont_touch = "true", extract_reset = "no" *) reg [7:0] r_st_dop_a, r_st_dop_b;
	(* dont_touch = "true", extract_reset = "no" *) reg [9:0] r_st_dop_dd_lo, r_st_dop_dd_hi;
	(* dont_touch = "true", extract_reset = "no" *) reg r_st_dop_ins;
	reg r_d_last;
	reg [31:0] t0, t1;
	reg [3:0] j, k, m;	/* CUT: start, edge, vertices written */
	(* dont_touch = "true" *) reg [3:0] r_m_w0 [0:13];
	(* dont_touch = "true" *) reg [3:0] r_m_w1 [0:13];
	(* max_fanout = 16 *) reg [1:0] cdone;	/* CUT: edge k's vertex handled (1: copy p, 3: write isect) */
	reg [9:0] r_ins;
	(* extract_reset = "no" *) reg [9:0] r_ins_succ;
	(* dont_touch = "true", extract_reset = "no" *) reg r_ins_pi, r_ins_pbp, r_ins_qi;
	(* extract_reset = "no" *) reg [3:0] r_nm1;
	reg [223:0] r_pbp;
	(* max_fanout = 16 *) reg dec_step;
	reg [3:0] r_jsel;
	(* max_fanout = 16 *) reg r_all_in, r_none_in;
	reg iop_rdy;
	(* max_fanout = 16 *) reg [3:0] ia, ib;	/* the edge's inside and outside vertices */
	(* dont_touch = "true", extract_reset = "no" *) reg [3:0] r_pi_rep [0:3];
	(* dont_touch = "true" *) reg [3:0] r_ia_rep [0:3];
	(* dont_touch = "true" *) reg [3:0] r_ib_rep [0:3];
	(* dont_touch = "true" *) reg [3:0] r_ia_da [0:3];
	(* dont_touch = "true" *) reg [3:0] r_ib_db [0:3];
	(* max_fanout = 16 *) reg [2:0] c;	/* ISECT: word */
	(* dont_touch = "true" *) reg [2:0] r_c_va [0:3];
	(* dont_touch = "true" *) reg [2:0] r_c_vb [0:3];
	reg [191:0] xi;
	integer q, gs_idx;

	/* Inside: dist >= 0, -0 and denormals included, NaN outside. */
	function cin;
		input [31:0] d;
		cin = !(d[30:23] == 8'hFF && d[22:0] != 23'd0) && !(d[31] && d[30:23] != 8'd0);
	endfunction

	/* n - 1; CUT's p and its successor q; the counters + 1 */
	wire [3:0] nm1, i1, m1, k1;
	(* max_fanout = 16 *) reg [3:0] pi, qi;
	wire [2:0] ph1, c1;
	wire [8:0] cp_carry_unused;
	am_sub #(.W(4)) u_nm1 (.a(n), .b(4'd0), .bi(1'b1), .d(nm1), .bo(cp_carry_unused[0]));

	/* 0-CARRY4 3-LUT all_in / none_in reduction */
	(* keep = "true" *) wire [9:0] v_out_in, v_in_in;
	genvar gi_v0;
	generate
	for (gi_v0 = 0; gi_v0 < 10; gi_v0 = gi_v0 + 1) begin : g_vin_chk
		assign v_out_in[gi_v0] = (gi_v0[3:0] < n) && !r_ins[gi_v0];
		assign v_in_in[gi_v0]  = (gi_v0[3:0] < n) &&  r_ins[gi_v0];
	end
	endgenerate
	(* keep = "true" *) wire all_in_lo  = (v_out_in[4:0] == 5'd0);
	(* keep = "true" *) wire all_in_hi  = (v_out_in[9:5] == 5'd0);
	(* keep = "true" *) wire none_in_lo = (v_in_in[4:0]  == 5'd0);
	(* keep = "true" *) wire none_in_hi = (v_in_in[9:5]  == 5'd0);
	wire all_in  = all_in_lo  && all_in_hi;
	wire none_in = none_in_lo && none_in_hi;
	/* The first inside vertex after an outside one (a triangle). */
	wire [15:0] ins16 = {6'd0, r_ins};
	wire [9:0] prv = {r_ins[8:0], ins16[nm1]};	/* the vertex before is inside */
	reg [3:0] jsel;
	always @(*) begin
		jsel = 4'd0;
		for (q = 9; q >= 0; q = q - 1)
			if (q < n && r_ins[q] && !prv[q])
				/* verilator lint_off WIDTHTRUNC */
				jsel = q;
				/* verilator lint_on WIDTHTRUNC */
	end

	wire [3:0] j1;
	am_add #(.W(4)) u_j1 (.a(r_jsel), .b(4'd0), .ci(1'b1), .s(j1), .co(cp_carry_unused[1]));
	(* keep = "true" *) wire j_wrap = (r_jsel == r_nm1);
	(* keep = "true" *) wire [3:0] q_init = j_wrap ? 4'd0 : j1;
	wire [3:0] qi1;
	am_add #(.W(4)) u_qi1 (.a(qi), .b(4'd0), .ci(1'b1), .s(qi1), .co(cp_carry_unused[2]));
	(* keep = "true" *) wire qi_wrap = (qi == r_nm1);
	(* keep = "true" *) wire [3:0] next_qi = qi_wrap ? 4'd0 : qi1;
	assign cp_carry_unused[3] = 1'b0;
	am_add #(.W(4)) u_i1 (.a(i), .b(4'd0), .ci(1'b1), .s(i1), .co(cp_carry_unused[4]));
	am_add #(.W(4)) u_m1 (.a(m), .b(4'd0), .ci(1'b1), .s(m1), .co(cp_carry_unused[5]));
	am_add #(.W(4)) u_k1 (.a(k), .b(4'd0), .ci(1'b1), .s(k1), .co(cp_carry_unused[6]));
	am_add #(.W(3)) u_ph1 (.a(ph), .b(3'd0), .ci(1'b1), .s(ph1), .co(cp_carry_unused[7]));
	am_add #(.W(3)) u_c1 (.a(c), .b(3'd0), .ci(1'b1), .s(c1), .co(cp_carry_unused[8]));

	/* Pre-computed inside bit of each vertex's successor (1 LUT6 per vertex) */
	wire [9:0] ins_succ_w;
	genvar gi_s, gi_v, gi_sub, gi_b;
	generate
	for (gi_v = 0; gi_v < 10; gi_v = gi_v + 1) begin : g_ins_succ
		localparam integer SUCC_V = (gi_v + 1) % 10;
		assign ins_succ_w[gi_v] = (r_nm1 == gi_v[3:0]) ? r_ins[0] : r_ins[SUCC_V];
	end
	endgenerate

	/* 2-LUT 10:1 lookups into r_ins and r_ins_succ */
	(* keep = "true" *) wire cj_lo  = r_ins[{2'b00, r_jsel[1:0]}];
	(* keep = "true" *) wire cj_mid = r_ins[{2'b01, r_jsel[1:0]}];
	(* keep = "true" *) wire cj_hi  = r_jsel[0] ? r_ins[9] : r_ins[8];
	(* keep = "true" *) wire ins_cur_jsel = r_jsel[3] ? cj_hi : (r_jsel[2] ? cj_mid : cj_lo);

	(* keep = "true" *) wire cp_lo  = r_ins[{2'b00, pi[1:0]}];
	(* keep = "true" *) wire cp_mid = r_ins[{2'b01, pi[1:0]}];
	(* keep = "true" *) wire cp_hi  = pi[0] ? r_ins[9] : r_ins[8];
	(* keep = "true" *) wire ins_cur_pi = pi[3] ? cp_hi : (pi[2] ? cp_mid : cp_lo);

	(* keep = "true" *) wire cq_lo  = r_ins[{2'b00, qi[1:0]}];
	(* keep = "true" *) wire cq_mid = r_ins[{2'b01, qi[1:0]}];
	(* keep = "true" *) wire cq_hi  = qi[0] ? r_ins[9] : r_ins[8];
	(* keep = "true" *) wire ins_cur_qi = qi[3] ? cq_hi : (qi[2] ? cq_mid : cq_lo);

	(* keep = "true" *) wire sj_lo  = r_ins_succ[{2'b00, r_jsel[1:0]}];
	(* keep = "true" *) wire sj_mid = r_ins_succ[{2'b01, r_jsel[1:0]}];
	(* keep = "true" *) wire sj_hi  = r_jsel[0] ? r_ins_succ[9] : r_ins_succ[8];
	(* keep = "true" *) wire ins_succ_jsel = r_jsel[3] ? sj_hi : (r_jsel[2] ? sj_mid : sj_lo);

	(* keep = "true" *) wire sq_lo  = r_ins_succ[{2'b00, qi[1:0]}];
	(* keep = "true" *) wire sq_mid = r_ins_succ[{2'b01, qi[1:0]}];
	(* keep = "true" *) wire sq_hi  = qi[0] ? r_ins_succ[9] : r_ins_succ[8];
	(* keep = "true" *) wire ins_succ_qi = qi[3] ? sq_hi : (qi[2] ? sq_mid : sq_lo);

	/* CUT: edge k from vertex pi to its successor qi */
	(* keep = "true" *) wire xing = (r_ins_pi != r_ins_qi) && (!line || k == 4'd0);

	/* Active half selection and fanout-bounded read/write trees for pb0/pb1 */
	(* keep = "true" *) wire [15:0] pb_cur [0:13][0:9];
	wire [3:0] ld_idx_l1 [0:3];
	wire [3:0] rd_idx_l1 [0:3];
	generate
	for (gi_s = 0; gi_s < 4; gi_s = gi_s + 1) begin : g_idx_l1
		for (gi_b = 0; gi_b < 4; gi_b = gi_b + 1) begin : g_b
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ld_l1 (.I0(ld_idx[gi_b]), .O(ld_idx_l1[gi_s][gi_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rd_l1 (.I0(rd_idx[gi_b]), .O(rd_idx_l1[gi_s][gi_b]));
`else
			assign ld_idx_l1[gi_s][gi_b] = ld_idx[gi_b];
			assign rd_idx_l1[gi_s][gi_b] = rd_idx[gi_b];
`endif
		end
	end

	wire ld_we_0, ld_we_1;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ld_we0 (.I0(ld_we), .O(ld_we_0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ld_we1 (.I0(ld_we), .O(ld_we_1));
`else
	assign ld_we_0 = ld_we;
	assign ld_we_1 = ld_we;
`endif

	for (gi_s = 0; gi_s < 14; gi_s = gi_s + 1) begin : g_pb_slice
		wire [3:0] ld_idx_w0, ld_idx_w1;
		for (gi_b = 0; gi_b < 4; gi_b = gi_b + 1) begin : g_ldb
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ld0 (.I0(ld_idx_l1[gi_s / 4][gi_b]), .O(ld_idx_w0[gi_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ld1 (.I0(ld_idx_l1[gi_s / 4][gi_b]), .O(ld_idx_w1[gi_b]));
`else
			assign ld_idx_w0[gi_b] = ld_idx_l1[gi_s / 4][gi_b];
			assign ld_idx_w1[gi_b] = ld_idx_l1[gi_s / 4][gi_b];
`endif
		end

		(* dont_touch = "true" *) wire en_ld0  = !r_half_w0[gi_s] && (st == S_IDLE) && ld_we_0;
		(* dont_touch = "true" *) wire en_cut0 =  r_half_w0[gi_s] && (st == S_CUT)  && cdone[0];
		(* dont_touch = "true" *) wire en_ld1  =  r_half_w1[gi_s] && (st == S_IDLE) && ld_we_1;
		(* dont_touch = "true" *) wire en_cut1 = !r_half_w1[gi_s] && (st == S_CUT)  && cdone[0];

		(* dont_touch = "true" *) wire [15:0] wdata0 = r_half_d0[gi_s] ? r_pbp[16 * gi_s +: 16] : ld_data[16 * gi_s +: 16];
		(* dont_touch = "true" *) wire [15:0] wdata1 = r_half_d1[gi_s] ? ld_data[16 * gi_s +: 16] : r_pbp[16 * gi_s +: 16];

		for (gi_v = 0; gi_v < 10; gi_v = gi_v + 1) begin : g_vtx
			wire half_rv;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_hr (.I0(r_half_v[gi_v]), .O(half_rv));
`else
			assign half_rv = r_half_v[gi_v];
`endif
			assign pb_cur[gi_s][gi_v] = half_rv ? pb1[gi_s][gi_v] : pb0[gi_s][gi_v];

			(* dont_touch = "true" *) wire we0 = (en_ld0 && ld_idx_w0 == gi_v[3:0]) ||
				(en_cut0 && r_m_w0[gi_s] == gi_v[3:0]);
			(* dont_touch = "true" *) wire we1 = (en_ld1 && ld_idx_w1 == gi_v[3:0]) ||
				(en_cut1 && r_m_w1[gi_s] == gi_v[3:0]);

			always @(posedge clk) begin
				if (we0)
					pb0[gi_s][gi_v] <= wdata0;
				if (we1)
					pb1[gi_s][gi_v] <= wdata1;
			end
		end
	end
	endgenerate

	/* Read index tree buffers (4 bits per sub-slice of 4 data bits -> fanout 12) */
	wire [3:0] rd_idx_b [0:55];
	wire [3:0] pi_b [0:55];
	wire [3:0] ia_b [0:55];
	wire [3:0] ib_b [0:55];
	wire [3:0] i_b [0:31];
	wire [223:0] pb_rd_data, pb_p_data, pb_va_data, pb_vb_data;
	wire [127:0] pb_vd_data;
	(* dont_touch = "true" *) wire [31:0] res, res_dd;
	wire [223:0] iw_full_w = {res, xi};

	generate
	for (gi_sub = 0; gi_sub < 56; gi_sub = gi_sub + 1) begin : g_pb_read
		localparam integer SL = gi_sub / 4;
		localparam integer OF = (gi_sub % 4) * 4;
		for (gi_b = 0; gi_b < 4; gi_b = gi_b + 1) begin : g_rb
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rd (.I0(rd_idx_l1[gi_sub / 14][gi_b]), .O(rd_idx_b[gi_sub][gi_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pi (.I0(r_pi_rep[gi_sub / 14][gi_b]),  .O(pi_b[gi_sub][gi_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ia (.I0(r_ia_rep[gi_sub / 14][gi_b]),  .O(ia_b[gi_sub][gi_b]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ib (.I0(r_ib_rep[gi_sub / 14][gi_b]),  .O(ib_b[gi_sub][gi_b]));
`else
			assign rd_idx_b[gi_sub][gi_b] = rd_idx_l1[gi_sub / 14][gi_b];
			assign pi_b[gi_sub][gi_b]     = r_pi_rep[gi_sub / 14][gi_b];
			assign ia_b[gi_sub][gi_b]     = r_ia_rep[gi_sub / 14][gi_b];
			assign ib_b[gi_sub][gi_b]     = r_ib_rep[gi_sub / 14][gi_b];
`endif
		end

		assign pb_rd_data[4 * gi_sub +: 4] = pb_cur[SL][rd_idx_b[gi_sub]][OF +: 4];
		assign pb_va_data[4 * gi_sub +: 4] = pb_cur[SL][ia_b[gi_sub]][OF +: 4];
		assign pb_vb_data[4 * gi_sub +: 4] = pb_cur[SL][ib_b[gi_sub]][OF +: 4];
		for (gi_b = 0; gi_b < 4; gi_b = gi_b + 1) begin : g_p_mux
			localparam integer BIT_IDX = 4 * gi_sub + gi_b;
			wire [9:0] pv = {
				pb_cur[SL][9][OF + gi_b], pb_cur[SL][8][OF + gi_b],
				pb_cur[SL][7][OF + gi_b], pb_cur[SL][6][OF + gi_b],
				pb_cur[SL][5][OF + gi_b], pb_cur[SL][4][OF + gi_b],
				pb_cur[SL][3][OF + gi_b], pb_cur[SL][2][OF + gi_b],
				pb_cur[SL][1][OF + gi_b], pb_cur[SL][0][OF + gi_b]
			};
			(* keep = "true" *) wire p_lo4  = pv[{2'b00, pi_b[gi_sub][1:0]}];
			(* keep = "true" *) wire p_mid4 = pv[{2'b01, pi_b[gi_sub][1:0]}];
			(* keep = "true" *) wire p_hi2  = pi_b[gi_sub][0] ? pv[9] : pv[8];
			assign pb_p_data[BIT_IDX] = (pi_b[gi_sub][3:2] == 2'b11) ? iw_full_w[BIT_IDX] :
				(pi_b[gi_sub][3] ? p_hi2 : (pi_b[gi_sub][2] ? p_mid4 : p_lo4));
		end
	end
	for (gi_sub = 0; gi_sub < 32; gi_sub = gi_sub + 1) begin : g_vd_read
		localparam integer SL = gi_sub / 4;
		localparam integer OF = (gi_sub % 4) * 4;
		for (gi_b = 0; gi_b < 4; gi_b = gi_b + 1) begin : g_vb
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_i (.I0(r_i_rep[gi_sub / 8][gi_b]), .O(i_b[gi_sub][gi_b]));
`else
			assign i_b[gi_sub][gi_b] = r_i_rep[gi_sub / 8][gi_b];
`endif
		end
		assign pb_vd_data[4 * gi_sub +: 4] = pb_cur[SL][i_b[gi_sub]][OF +: 4];
	end
	endgenerate

	/* Buffered edge vertices for intersection */
	reg [223:0] r_va, r_vb;
	wire [127:0] vd = r_vd;
	wire [31:0] g_c, g_sc, g_of;
	wire gy_raw = (plane == 3'd5) || (plane == 3'd6);
	generate
	for (gi_s = 0; gi_s < 2; gi_s = gi_s + 1) begin : g_gy_mux
		assign g_c[16 * gi_s +: 16]  = r_gy_c[gi_s]  ? vd[32 + 16 * gi_s +: 16] : vd[16 * gi_s +: 16];
		assign g_sc[16 * gi_s +: 16] = r_gy_sc[gi_s] ? vp[32 + 16 * gi_s +: 16] : vp[16 * gi_s +: 16];
		assign g_of[16 * gi_s +: 16] = r_gy_of[gi_s] ? vp[96 + 16 * gi_s +: 16] : vp[64 + 16 * gi_s +: 16];
	end
	endgenerate

	wire [31:0] a_c, b_c, d_a, d_b;
	generate
	for (gi_s = 0; gi_s < 4; gi_s = gi_s + 1) begin : g_ab_mux
		wire [7:0] va_w [0:6];
		wire [7:0] vb_w [0:6];
		for (gi_v = 0; gi_v < 7; gi_v = gi_v + 1) begin : g_ab_w
			assign va_w[gi_v] = r_va[32 * gi_v + 8 * gi_s +: 8];
			assign vb_w[gi_v] = r_vb[32 * gi_v + 8 * gi_s +: 8];
		end
		assign a_c[8 * gi_s +: 8] = va_w[r_c_va[gi_s]];
		assign b_c[8 * gi_s +: 8] = vb_w[r_c_vb[gi_s]];
		assign d_a[8 * gi_s +: 8] = dd[r_ia_da[gi_s]][8 * gi_s +: 8];
		assign d_b[8 * gi_s +: 8] = dd[r_ib_db[gi_s]][8 * gi_s +: 8];
	end
	endgenerate

	reg [1:0] op;	/* 0 fadd, 1 fmul, 2 fdiv */
	wire [31:0] op_a, op_b;
	reg op_sub;

	always @(*) begin
		op = 2'd0;
		op_sub = 1'b0;
		if (st == S_DOP) begin
			case (plane)
			3'd0: op_sub = 1'b1;
			3'd2: op_sub = 1'b1;
			default:
				case (ph)
				3'd0, 3'd1, 3'd3: op = 2'd1;
				3'd2: op = 2'd0;
				default: op_sub = plane == 3'd3 || plane == 3'd5;
				endcase
			endcase
		end else begin
			case (ph)
			3'd0: op_sub = 1'b1;
			3'd1: op = 2'd2;
			3'd2: op_sub = 1'b1;
			3'd3: op = 2'd1;
			default: op = 2'd0;
			endcase
		end
	end

	generate
	for (gi_s = 0; gi_s < 8; gi_s = gi_s + 1) begin : g_op_slice
		wire st_dop_a = r_st_dop_a[gi_s];
		wire st_dop_b = r_st_dop_b[gi_s];
		wire [2:0] pl_a  = r_plane_a[gi_s];
		wire [2:0] ph_sa = r_ph_a[gi_s];
		wire [2:0] pl_b  = r_plane_b[gi_s];
		wire [2:0] ph_sb = r_ph_b[gi_s];
		(* keep = "true" *) reg [3:0] sl_a_dop, sl_b_dop;
		always @(*) begin
			case (pl_a)
			3'd0: sl_a_dop = vd[96 + 4 * gi_s +: 4];
			3'd2: sl_a_dop = vd[96 + 4 * gi_s +: 4];
			default:
				case (ph_sa)
				3'd0: sl_a_dop = g_of[4 * gi_s +: 4];
				3'd1: sl_a_dop = g_sc[4 * gi_s +: 4];
				3'd2: sl_a_dop = t0[4 * gi_s +: 4];
				3'd3: sl_a_dop = GUARD[4 * gi_s +: 4];
				default: sl_a_dop = t1[4 * gi_s +: 4];
				endcase
			endcase

			case (pl_b)
			3'd0: sl_b_dop = EPS[4 * gi_s +: 4];
			3'd2: sl_b_dop = vd[64 + 4 * gi_s +: 4];
			default:
				case (ph_sb)
				3'd0: sl_b_dop = vd[96 + 4 * gi_s +: 4];
				3'd1: sl_b_dop = g_c[4 * gi_s +: 4];
				3'd2: sl_b_dop = t1[4 * gi_s +: 4];
				3'd3: sl_b_dop = vd[96 + 4 * gi_s +: 4];
				default: sl_b_dop = t0[4 * gi_s +: 4];
				endcase
			endcase
		end
		(* keep = "true" *) wire [3:0] sl_a_dba = ph_sa[2] ? a_c[4 * gi_s +: 4] :
			(ph_sa[1] ? b_c[4 * gi_s +: 4] : d_a[4 * gi_s +: 4]);
		(* keep = "true" *) wire iop_t0_a = !st_dop_a && (ph_sa == 3'd3);
		assign op_a[4 * gi_s +: 4] = st_dop_a ? sl_a_dop :
			(iop_t0_a ? t0[4 * gi_s +: 4] : sl_a_dba);

		(* keep = "true" *) wire [3:0] sl_b_even = ph_sb[2] ? t0[4 * gi_s +: 4] :
			(ph_sb[1] ? a_c[4 * gi_s +: 4] : d_b[4 * gi_s +: 4]);
		(* keep = "true" *) wire [3:0] sl_b_odd = ph_sb[1] ? t1[4 * gi_s +: 4] : t0[4 * gi_s +: 4];
		assign op_b[4 * gi_s +: 4] = st_dop_b ? sl_b_dop :
			(ph_sb[0] ? sl_b_odd : sl_b_even);
	end
	endgenerate

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

	wire res_v_raw = fa_o || fm_o || fd_o;
	wire [6:0] res_v_b;
	wire [2:0] cmd_valid_b;
	generate
	for (gi_b = 0; gi_b < 7; gi_b = gi_b + 1) begin : g_res_vb
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rv (.I0(res_v_raw), .O(res_v_b[gi_b]));
`else
		assign res_v_b[gi_b] = res_v_raw;
`endif
	end
	for (gi_b = 0; gi_b < 3; gi_b = gi_b + 1) begin : g_cmd_vb
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cv (.I0(cmd_valid), .O(cmd_valid_b[gi_b]));
`else
		assign cmd_valid_b[gi_b] = cmd_valid;
`endif
	end
	endgenerate

	generate
	for (gi_s = 0; gi_s < 2; gi_s = gi_s + 1) begin : g_res_mux
		wire fa_s, fm_s, fa_d, fm_d;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_fa  (.I0(fa_o), .O(fa_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_fm  (.I0(fm_o), .O(fm_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_fad (.I0(fa_o), .O(fa_d));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_fmd (.I0(fm_o), .O(fm_d));
`else
		assign fa_s = fa_o;
		assign fm_s = fm_o;
		assign fa_d = fa_o;
		assign fm_d = fm_o;
`endif
		assign res[16 * gi_s +: 16] = fa_s ? fa_r[16 * gi_s +: 16] :
			fm_s ? fm_r[16 * gi_s +: 16] : fd_r[16 * gi_s +: 16];
		assign res_dd[16 * gi_s +: 16] = fa_d ? fa_r[16 * gi_s +: 16] :
			fm_d ? fm_r[16 * gi_s +: 16] : fd_r[16 * gi_s +: 16];
	end
	endgenerate

	/* the last operation of a distance: planes 0 and 2 have one, 3-6 five */
	wire d_last = plane == 3'd0 || plane == 3'd2 || ph == 3'd4;

	assign cmd_ready = st == S_IDLE;

	/* Split clock enables for 32-bit, 128-bit, and 224-bit datapath registers (max 16 FFs per CE) */
	wire op_we_raw = ((st == S_DOP) && (plane != 3'd1)) || ((st == S_IOP) && iop_rdy);
	wire opa_we_lo, opa_we_hi, opb_we_lo, opb_we_hi;
	wire op_we_sub = op_we_raw;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_opa_lo (.I0(op_we_raw), .O(opa_we_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_opa_hi (.I0(op_we_raw), .O(opa_we_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_opb_lo (.I0(op_we_raw), .O(opb_we_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_opb_hi (.I0(op_we_raw), .O(opb_we_hi));
`else
	assign opa_we_lo = op_we_raw;
	assign opa_we_hi = op_we_raw;
	assign opb_we_lo = op_we_raw;
	assign opb_we_hi = op_we_raw;
`endif

	(* keep = "true" *) wire t0_en = ((st == S_DW) && !r_d_last && (ph == 3'd0 || ph == 3'd2)) ||
		((st == S_IW) && (ph == 3'd0 || ph == 3'd2 || ph == 3'd3));
	(* keep = "true" *) wire t1_en = ((st == S_DW) && !r_d_last && !(ph == 3'd0 || ph == 3'd2)) ||
		((st == S_IW) && (ph == 3'd1));
	wire t0_we_lo, t0_we_hi, t1_we_lo, t1_we_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT2 #(.INIT(4'h8)) u_t0_lo (.I0(t0_en), .I1(res_v_b[0]), .O(t0_we_lo));
	(* dont_touch = "true" *) LUT2 #(.INIT(4'h8)) u_t0_hi (.I0(t0_en), .I1(res_v_b[0]), .O(t0_we_hi));
	(* dont_touch = "true" *) LUT2 #(.INIT(4'h8)) u_t1_lo (.I0(t1_en), .I1(res_v_b[0]), .O(t1_we_lo));
	(* dont_touch = "true" *) LUT2 #(.INIT(4'h8)) u_t1_hi (.I0(t1_en), .I1(res_v_b[0]), .O(t1_we_hi));
`else
	assign t0_we_lo = t0_en && res_v_b[0];
	assign t0_we_hi = t0_en && res_v_b[0];
	assign t1_we_lo = t1_en && res_v_b[0];
	assign t1_we_hi = t1_en && res_v_b[0];
`endif

	wire vd_we_raw  = (st == S_DFETCH);
	wire vab_we_raw = (st == S_IOP) && iop_rdy && (ph == 3'd0);
	(* keep = "true" *) wire pbp_cut_en = (st == S_CUT) && !cdone[0] && !r_cut_end && (cdone == 2'd0);
	(* keep = "true" *) wire pbp_iw_en  = (st == S_IW) && (ph == 3'd4) && (c == 3'd6);

	wire vab_we_l1_a, vab_we_l1_b;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_vab_l1_a  (.I0(vab_we_raw), .O(vab_we_l1_a));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_vab_l1_b  (.I0(vab_we_raw), .O(vab_we_l1_b));
`else
	assign vab_we_l1_a = vab_we_raw;
	assign vab_we_l1_b = vab_we_raw;
`endif

	/* 2-LUT explicit tree for cin(fa_r) and cin(r_vd[95:64]) + 1-LUT mux into r_ins (<= 3-4 LUTs total) */
	(* keep = "true" *) wire fa_m0 = (&fa_r[30:29]) && (fa_r[3:0]   != 4'd0);
	(* keep = "true" *) wire fa_m1 = (&fa_r[30:29]) && (fa_r[7:4]   != 4'd0);
	(* keep = "true" *) wire fa_m2 = (&fa_r[30:29]) && (fa_r[11:8]  != 4'd0);
	(* keep = "true" *) wire fa_m3 = (&fa_r[30:29]) && (fa_r[15:12] != 4'd0);
	(* keep = "true" *) wire fa_m4 = (&fa_r[30:29]) && (fa_r[19:16] != 4'd0);
	(* keep = "true" *) wire fa_m5 = (&fa_r[30:29]) && (fa_r[22:20] != 3'd0);
	(* keep = "true" *) wire fa_ef = (&fa_r[28:23]);
	(* keep = "true" *) wire fa_nh = fa_r[31] && (fa_r[30:26] != 5'd0);
	(* keep = "true" *) wire fa_nl = fa_r[31] && (fa_r[25:23] != 3'd0);
	(* keep = "true" *) wire fa_bad0 = fa_ef && (fa_m0 || fa_m1 || fa_m2 || fa_m3 || fa_m4);
	(* keep = "true" *) wire fa_bad1 = (fa_ef && fa_m5) || fa_nh || fa_nl;

	(* keep = "true" *) wire vd_m0 = (&r_vd[94:93]) && (r_vd[67:64] != 4'd0);
	(* keep = "true" *) wire vd_m1 = (&r_vd[94:93]) && (r_vd[71:68] != 4'd0);
	(* keep = "true" *) wire vd_m2 = (&r_vd[94:93]) && (r_vd[75:72] != 4'd0);
	(* keep = "true" *) wire vd_m3 = (&r_vd[94:93]) && (r_vd[79:76] != 4'd0);
	(* keep = "true" *) wire vd_m4 = (&r_vd[94:93]) && (r_vd[83:80] != 4'd0);
	(* keep = "true" *) wire vd_m5 = (&r_vd[94:93]) && (r_vd[86:84] != 3'd0);
	(* keep = "true" *) wire vd_ef = (&r_vd[92:87]);
	(* keep = "true" *) wire vd_nh = r_vd[95] && (r_vd[94:90] != 5'd0);
	(* keep = "true" *) wire vd_nl = r_vd[95] && (r_vd[89:87] != 3'd0);
	(* keep = "true" *) wire vd_bad0 = vd_ef && (vd_m0 || vd_m1 || vd_m2 || vd_m3 || vd_m4);
	(* keep = "true" *) wire vd_bad1 = (vd_ef && vd_m5) || vd_nh || vd_nl;

	(* dont_touch = "true" *) wire ins_wdata = r_st_dop_ins ? (!vd_bad0 && !vd_bad1) : (!fa_bad0 && !fa_bad1);

	generate
	for (gi_s = 0; gi_s < 8; gi_s = gi_s + 1) begin : g_vd_reg
		wire vd_we;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_vd_we (.I0(vd_we_raw), .O(vd_we));
`else
		assign vd_we = vd_we_raw;
`endif
		always @(posedge clk) begin
			if (vd_we)
				r_vd[16 * gi_s +: 16] <= pb_vd_data[16 * gi_s +: 16];
		end
	end
	for (gi_v = 0; gi_v < 10; gi_v = gi_v + 1) begin : g_dd_reg
		wire sel_dop_lo = r_st_dop_dd_lo[gi_v];
		wire sel_dop_hi = r_st_dop_dd_hi[gi_v];
		(* keep = "true" *) wire dd_dop = (st == S_DOP) && (plane == 3'd1) && (i == gi_v[3:0]);
		(* keep = "true" *) wire dd_dw  = (st == S_DW)  && r_d_last        && (i == gi_v[3:0]);
		(* dont_touch = "true" *) wire dd_we_lo = dd_dop || (dd_dw && res_v_b[0]);
		(* dont_touch = "true" *) wire dd_we_hi = dd_dop || (dd_dw && res_v_b[1]);
		(* dont_touch = "true" *) wire ins_we   = dd_dop || (dd_dw && res_v_b[4]);
		always @(posedge clk) begin
			if (dd_we_lo)
				dd[gi_v][15:0] <= sel_dop_lo ? r_vd[79:64] : res_dd[15:0];
			if (dd_we_hi)
				dd[gi_v][31:16] <= sel_dop_hi ? r_vd[95:80] : res_dd[31:16];
			if (rst_sync)
				r_ins[gi_v] <= 1'b0;
			else if (ins_we)
				r_ins[gi_v] <= ins_wdata;
		end
	end
	for (gi_v = 0; gi_v < 6; gi_v = gi_v + 1) begin : g_xi_reg
		(* keep = "true" *) wire xi_en = (st == S_IW) && (ph == 3'd4) && (c == gi_v[2:0]);
		wire xi_we_lo, xi_we_hi;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT2 #(.INIT(4'h8)) u_xi_lo (.I0(xi_en), .I1(res_v_b[2]), .O(xi_we_lo));
		(* dont_touch = "true" *) LUT2 #(.INIT(4'h8)) u_xi_hi (.I0(xi_en), .I1(res_v_b[2]), .O(xi_we_hi));
`else
		assign xi_we_lo = xi_en && res_v_b[2];
		assign xi_we_hi = xi_en && res_v_b[2];
`endif
		always @(posedge clk) begin
			if (xi_we_lo)
				xi[32 * gi_v +: 16] <= res[15:0];
			if (xi_we_hi)
				xi[32 * gi_v + 16 +: 16] <= res[31:16];
		end
	end
	for (gi_s = 0; gi_s < 14; gi_s = gi_s + 1) begin : g_wide_regs
		wire va_we, vb_we, pbp_we;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2))    u_va_we (.I0(vab_we_l1_a), .O(va_we));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2))    u_vb_we (.I0(vab_we_l1_b), .O(vb_we));
		(* dont_touch = "true" *) LUT4 #(.INIT(16'hF888)) u_pb_we (.I0(r_ins_pbp), .I1(pbp_cut_en), .I2(res_v_b[3]), .I3(pbp_iw_en), .O(pbp_we));
`else
		assign va_we  = vab_we_l1_a;
		assign vb_we  = vab_we_l1_b;
		assign pbp_we = (pbp_cut_en && r_ins_pbp) || (pbp_iw_en && res_v_b[3]);
`endif

		always @(posedge clk) begin
			if (va_we)
				r_va[16 * gi_s +: 16] <= pb_va_data[16 * gi_s +: 16];
			if (vb_we)
				r_vb[16 * gi_s +: 16] <= pb_vb_data[16 * gi_s +: 16];
			if (pbp_we)
				r_pbp[16 * gi_s +: 16] <= pb_p_data[16 * gi_s +: 16];
		end
	end
	endgenerate

	/* Single-cycle shadow copies (CE = 1, R = 0 -> zero control fanout, fanout <= 14) */
	(* dont_touch = "true" *) wire nh_v  = rst_sync ? 1'b0 : ((st == S_CUT && !cdone[0] && r_cut_end) ? !half : half);
	(* dont_touch = "true" *) wire nh_w0 = rst_sync ? 1'b0 : ((st == S_CUT && !cdone[0] && r_cut_end) ? !half : half);
	(* dont_touch = "true" *) wire nh_w1 = rst_sync ? 1'b0 : ((st == S_CUT && !cdone[0] && r_cut_end) ? !half : half);
	(* dont_touch = "true" *) wire nh_d0 = rst_sync ? 1'b0 : ((st == S_CUT && !cdone[0] && r_cut_end) ? !half : half);
	(* dont_touch = "true" *) wire nh_d1 = rst_sync ? 1'b0 : ((st == S_CUT && !cdone[0] && r_cut_end) ? !half : half);
	wire [3:0] m_b0, m_b1;
	generate
	for (gi_b = 0; gi_b < 4; gi_b = gi_b + 1) begin : g_mbuf
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mb0 (.I0(m[gi_b]), .O(m_b0[gi_b]));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mb1 (.I0(m[gi_b]), .O(m_b1[gi_b]));
`else
		assign m_b0[gi_b] = m[gi_b];
		assign m_b1[gi_b] = m[gi_b];
`endif
	end
	endgenerate

	/* Unconditional shadow copies (CE = 1, R = 0 -> zero CE fanout, <= 3 LUT levels) */
	wire [3:0] pi_nxt = (st == S_DEC) ? r_jsel :
		((st == S_CUT) ? (cdone[1] ? qi : pi) : 4'hC);
	wire ins_pi_nxt = (st == S_DEC) ? ins_cur_jsel :
		((st == S_CUT) ? (cdone[1] ? r_ins_qi : r_ins_pi) : ins_cur_pi);
	wire ins_qi_nxt = (st == S_DEC) ? ins_succ_jsel :
		((st == S_CUT) ? (cdone[1] ? ins_succ_qi : r_ins_qi) : ins_cur_qi);
	wire i_adv = (st == S_DOP && plane == 3'd1) || (st == S_DW && res_v_b[5] && r_d_last);
	wire [3:0] i_nxt = (st == S_IDLE) ? 4'd0 : (i_adv ? i1 : i);
	wire [2:0] ph_nxt = (st == S_IDLE || st == S_CUT) ? 3'd0 :
		((st == S_DW && res_v_b[5]) ? (r_d_last ? 3'd0 : ph1) :
		((st == S_IW && res_v_b[5]) ? (ph == 3'd4 ? 3'd2 : ph1) : ph));
	(* dont_touch = "true" *) wire st_dop_nxt_a = !rst_sync && ((st == S_DFETCH) || (st == S_DW && res_v_b[5] && !r_d_last));
	(* dont_touch = "true" *) wire st_dop_nxt_b = !rst_sync && ((st == S_DFETCH) || (st == S_DW && res_v_b[5] && !r_d_last));
	(* dont_touch = "true" *) wire st_dop_nxt_c = !rst_sync && ((st == S_DFETCH) || (st == S_DW && res_v_b[5] && !r_d_last));
	(* dont_touch = "true" *) wire st_dop_nxt_d = !rst_sync && ((st == S_DFETCH) || (st == S_DW && res_v_b[5] && !r_d_last));

	always @(posedge clk) begin
		r_nm1          <= nm1;
		r_ins_succ     <= ins_succ_w;
		r_ins_pi       <= ins_pi_nxt;
		r_ins_pbp      <= ins_pi_nxt;
		r_ins_qi       <= ins_qi_nxt;
		r_st_dop_a     <= {8{st_dop_nxt_a}};
		r_st_dop_b     <= {8{st_dop_nxt_b}};
		r_st_dop_dd_lo <= {10{st_dop_nxt_c}};
		r_st_dop_dd_hi <= {10{st_dop_nxt_d}};
		r_st_dop_ins   <= st_dop_nxt_b;
		r_half_v  <= {10{nh_v}};
		r_half_w0 <= {14{nh_w0}};
		r_half_w1 <= {14{nh_w1}};
		r_half_d0 <= {14{nh_d0}};
		r_half_d1 <= {14{nh_d1}};
		r_gy_c    <= {2{gy_raw}};
		r_gy_sc   <= {2{gy_raw}};
		r_gy_of   <= {2{gy_raw}};
		for (gs_idx = 0; gs_idx < 14; gs_idx = gs_idx + 1) begin
			r_m_w0[gs_idx] <= m_b0;
			r_m_w1[gs_idx] <= m_b1;
		end
		for (gs_idx = 0; gs_idx < 4; gs_idx = gs_idx + 1) begin
			r_ia_rep[gs_idx] <= ia;
			r_ib_rep[gs_idx] <= ib;
			r_ia_da[gs_idx]  <= ia;
			r_ib_db[gs_idx]  <= ib;
			r_c_va[gs_idx]   <= c;
			r_c_vb[gs_idx]   <= c;
			r_pi_rep[gs_idx] <= pi_nxt;
			r_i_rep[gs_idx]  <= i_nxt;
		end
		for (gs_idx = 0; gs_idx < 8; gs_idx = gs_idx + 1) begin
			r_plane_a[gs_idx] <= plane;
			r_plane_b[gs_idx] <= plane;
			r_ph_a[gs_idx]    <= ph_nxt;
			r_ph_b[gs_idx]    <= ph_nxt;
		end
	end

	always @(posedge clk) begin
		rd_data <= pb_rd_data;
		done <= 1'b0;
		r_fa_v <= 1'b0;
		r_fm_v <= 1'b0;
		r_fd_v <= 1'b0;

		if (opa_we_lo)
			r_op_a[15:0] <= op_a[15:0];
		if (opa_we_hi)
			r_op_a[31:16] <= op_a[31:16];
		if (opb_we_lo)
			r_op_b[15:0] <= op_b[15:0];
		if (opb_we_hi)
			r_op_b[31:16] <= op_b[31:16];
		if (op_we_sub)
			r_op_sub <= op_sub;

		if (t0_we_lo)
			t0[15:0] <= res[15:0];
		if (t0_we_hi)
			t0[31:16] <= res[31:16];
		if (t1_we_lo)
			t1[15:0] <= res[15:0];
		if (t1_we_hi)
			t1[31:16] <= res[31:16];

		if (rst_sync) begin
			st <= S_IDLE;
			half <= 1'b0;
			n <= 4'd0;
			line <= 1'b0;
			r_cut_end <= 1'b0;
			n_out <= 4'd0;
			pi <= 4'd0;
			qi <= 4'd0;
			cdone <= 2'd0;
			dec_step <= 1'b0;
			r_jsel <= 4'd0;
			r_all_in <= 1'b0;
			r_none_in <= 1'b0;
			r_d_last <= 1'b0;
			iop_rdy <= 1'b0;
		end else case (st)
		S_IDLE: begin
			if (cmd_valid_b[0]) begin
				plane <= cmd_plane;
				if (cmd_first) begin
					n <= ld_n;
					line <= ld_line;
				end
				i <= 4'd0;
				ph <= 3'd0;
				st <= S_DFETCH;
			end
		end
		S_DFETCH: begin
			st <= S_DOP;
		end
		S_DOP: begin
			r_d_last <= d_last;
			if (plane == 3'd1) begin
				i <= i1;
				dec_step <= 1'b0;
				if (i1 == n)
					st <= S_DEC;
				else
					st <= S_DFETCH;
			end else begin
				r_fa_v <= op == 2'd0;
				r_fm_v <= op == 2'd1;
				r_fd_v <= op == 2'd2;
				st <= S_DW;
			end
		end
		S_DW:
			if (res_v_b[6]) begin
				if (r_d_last) begin
					ph <= 3'd0;
					i <= i1;
					dec_step <= 1'b0;
					st <= i1 == n ? S_DEC : S_DFETCH;
				end else begin
					ph <= ph1;
					st <= S_DOP;
				end
			end
		S_DEC: begin
			if (!dec_step) begin
				r_jsel <= line ? 4'd0 : jsel;
				r_all_in <= all_in;
				r_none_in <= none_in;
				dec_step <= 1'b1;
			end else begin
				dec_step <= 1'b0;
				if (r_all_in || r_none_in) begin
					done <= 1'b1;
					n_out <= r_none_in ? 4'd0 : n;
					if (r_none_in)
						n <= 4'd0;
					st <= S_IDLE;
				end else begin
					j <= r_jsel;
					pi <= r_jsel;
					qi <= q_init;
					k <= 4'd0;
					m <= 4'd0;
					cdone <= 2'd0;
					r_cut_end <= 1'b0;
					st <= S_CUT;
				end
			end
		end
		S_CUT:
			if (cdone[0]) begin
				m <= m1;
				if (cdone[1]) begin
					k <= k1;
					pi <= qi;
					qi <= next_qi;
					cdone <= 2'd0;
					r_cut_end <= line ? k1 == 4'd2 : k1 == n;
				end else begin
					cdone <= 2'd2;
				end
			end else if (r_cut_end) begin
				half <= !half;
				n <= m;
				n_out <= m;
				done <= 1'b1;
				st <= S_IDLE;
			end else if (cdone == 2'd0) begin
				if (r_ins_pi)
					cdone <= 2'd1;
				else
					cdone <= 2'd2;
			end else if (xing) begin
				ia <= r_ins_pi ? pi : qi;
				ib <= r_ins_pi ? qi : pi;
				ph <= 3'd0;
				c <= 3'd0;
				iop_rdy <= 1'b0;
				st <= S_IOP;
			end else begin
				k <= k1;
				pi <= qi;
				qi <= next_qi;
				cdone <= 2'd0;
				r_cut_end <= line ? k1 == 4'd2 : k1 == n;
			end
		S_IOP: begin
			if (!iop_rdy) begin
				iop_rdy <= 1'b1;
			end else begin
				r_fa_v <= op == 2'd0;
				r_fm_v <= op == 2'd1;
				r_fd_v <= op == 2'd2;
				st <= S_IW;
			end
		end
		default:	/* S_IW */
			if (res_v_b[6]) begin
				st <= S_IOP;
				ph <= ph == 3'd4 ? 3'd2 : ph1;
				if (ph == 3'd4) begin
					c <= c1;
					iop_rdy <= 1'b0;
					if (c == 3'd6) begin
						cdone <= 2'd3;
						st <= S_CUT;
					end
				end
			end
		endcase
	end

	wire unused_ok = &{1'b0, fd_busy, j, ins16[15:10], cmd_valid_b[2:1]};
endmodule

`default_nettype wire
