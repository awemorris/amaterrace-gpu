/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_edge: the integer part of the RX setup: snaps the window
 * coordinates to 15.8 fixed point, builds the triangle that the scan
 * converter walks (a triangle, or one of the two sub-triangles of a line's
 * parallelogram or of a point's square), its edges with the top-left rule,
 * its bounding box (the pixels of the whole primitive) ∩ scissor ∩ render
 * target (∩ the viewport's rectangle), its facing and culling, and writes
 * the integer deltas of the triangle that defines the planes back to
 * atg_rx_setup's fp registers as fp32.
 *
 * start runs it; it reads fp registers 31, 32, 34, 35, 37, 38 (the window
 * x, y of vertices 0-2) and 76-79 (the viewport's rectangle x0, x1, y0,
 * y1) through r_ra / r_rd (data the next cycle), and writes DX1, DY1, DX2,
 * DY2, DF, OX, OY to registers 40-46 through r_we / r_wa / r_wd, then
 * pulses done; edges, bbox, front and empty hold until the next start.
 * Line (vertices 0 = a, 1 = b): x-major when |dx| >= |dy|; corners a and b
 * -+ (0, 128) (x-major) or -+ (128, 0) subpixels; sub-triangle 0 (a-, b-,
 * b+), 1 (a-, b+, a+); planes of (a, b, a + one pixel along the minor
 * axis).  Point (vertex 0 = p): corners p -+ (128, 128); sub-triangle 0
 * (p--, p+-, p++), 1 (p--, p++, p-+); planes of (p, p + (1, 0), p + (0,
 * 1)).  Lines and points are front and never culled.  An empty result
 * (zero area, culled, empty bbox) zeroes the edges and the bbox and writes
 * no register.  See spec/gpu/rx/atg_rx_edge.md.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_rx_edge (
	input wire clk,
	input wire rst_n,
	input wire start,
	input wire [3:0] mode,	/* [1:0] kind, [2] sub-triangle, [3] raw */
	input wire [31:0] smin,
	input wire [31:0] smax,
	input wire [31:0] rts,
	input wire [2:0] cull,
	input wire vprect,
	input wire [15:0] line_width,
	input wire [15:0] point_size,
	output reg [6:0] r_ra,
	input wire [31:0] r_rd,
	output reg r_we,
	output reg [6:0] r_wa,
	output reg [31:0] r_wd,
	output reg done,
	output wire [287:0] edges,
	output wire [63:0] bbox,
	output reg front,
	output reg empty
);
	wire rst_sync = !rst_n;
	(* max_fanout = 16 *) reg run;
	(* extract_reset = "no", extract_enable = "no", max_fanout = 16 *) reg [5:0] cnt;
	(* extract_enable = "no", max_fanout = 16 *) reg [3:0] md;
	wire [1:0] kind = md[1:0];
	wire is_tri = kind[1] || md[3];
	integer k;
	genvar gi, gs;

	wire [55:0] carry_unused;	/* the adders' carries */

	/* Pipelined f2fix stage 1: exponent and shift (coarse byte shift + fine bit shift for fanout <= 15) */
	localparam [23:0] SAT_POS = 24'h3FFFFF;
	localparam [23:0] SAT_NEG = 24'hC00001;

	wire [7:0] snap_exp = r_rd[30:23];
	wire [22:0] snap_mant = r_rd[22:0];
	assign carry_unused[49] = 1'b0;

	/* Exponent subtraction in 1 LUT level (no arithmetic operators) */
	reg [3:0] sub14;
	always @(*) begin
		case (snap_exp[3:0])
			4'd0: sub14 = 4'd14;
			4'd1: sub14 = 4'd13;
			4'd2: sub14 = 4'd12;
			4'd3: sub14 = 4'd11;
			4'd4: sub14 = 4'd10;
			4'd5: sub14 = 4'd9;
			4'd6: sub14 = 4'd8;
			4'd7: sub14 = 4'd7;
			4'd8: sub14 = 4'd6;
			4'd9: sub14 = 4'd5;
			4'd10: sub14 = 4'd4;
			4'd11: sub14 = 4'd3;
			4'd12: sub14 = 4'd2;
			4'd13: sub14 = 4'd1;
			4'd14: sub14 = 4'd0;
			4'd15: sub14 = 4'd15;
		endcase
	end
	wire snap_amt5_hi = !snap_exp[7] && (snap_exp[3:0] != 4'd15);
	wire [4:0] snap_amt5 = {snap_amt5_hi, sub14};
	wire [47:0] snap_in = {1'b1, snap_mant, 24'd0};

	wire snap_c16_s2_sn2, snap_c16_s2_sn1;
	wire snap_c16_s1_sn1, snap_c16_s1_sn0;
	wire snap_c16_s0_sn0;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sc16_2_2 (.I0(snap_amt5[4]), .O(snap_c16_s2_sn2));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sc16_2_1 (.I0(snap_amt5[4]), .O(snap_c16_s2_sn1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sc16_1_1 (.I0(snap_amt5[4]), .O(snap_c16_s1_sn1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sc16_1_0 (.I0(snap_amt5[4]), .O(snap_c16_s1_sn0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sc16_0_0 (.I0(snap_amt5[4]), .O(snap_c16_s0_sn0));
`else
	assign snap_c16_s2_sn2 = snap_amt5[4];
	assign snap_c16_s2_sn1 = snap_amt5[4];
	assign snap_c16_s1_sn1 = snap_amt5[4];
	assign snap_c16_s1_sn0 = snap_amt5[4];
	assign snap_c16_s0_sn0 = snap_amt5[4];
`endif

	wire [15:0] snap_s1_sn2 = snap_c16_s2_sn2 ? 16'd0 : snap_in[47:32];
	wire [31:0] snap_s1_sn1 = {snap_c16_s2_sn1 ? 16'd0 : snap_in[47:32], snap_c16_s1_sn1 ? snap_in[47:32] : snap_in[31:16]};
	wire [31:0] snap_s1_sn0 = {snap_c16_s1_sn0 ? snap_in[47:32] : snap_in[31:16], snap_c16_s0_sn0 ? snap_in[31:16] : snap_in[15:0]};

	wire [3:0] snap_amt_s2, snap_amt_s1, snap_amt_s0;
`ifdef SYNTH_KINTEX7
	wire [3:0] snap_amt_s1_l;
	wire snap_amt_s1_h_lo, snap_amt_s1_h_hi;
	genvar gsa;
	generate
		for (gsa = 0; gsa < 4; gsa = gsa + 1) begin : g_snap_amt_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sa2 (.I0(snap_amt5[gsa]), .O(snap_amt_s2[gsa]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sa1l (.I0(snap_amt5[gsa]), .O(snap_amt_s1_l[gsa]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sa0 (.I0(snap_amt5[gsa]), .O(snap_amt_s0[gsa]));
		end
	endgenerate
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sa1h_lo (.I0(snap_amt5[3]), .O(snap_amt_s1_h_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sa1h_hi (.I0(snap_amt5[3]), .O(snap_amt_s1_h_hi));
	wire [23:0] sn1_st1 = {
		snap_amt_s1_h_hi ? snap_s1_sn1[31:20] : snap_s1_sn1[23:12],
		snap_amt_s1_h_lo ? snap_s1_sn1[19:8]  : snap_s1_sn1[11:0]
	};
	wire [23:0] snap_sh1_24;
	am_shift #(.W(24), .SW(3)) u_sn1 (.a(sn1_st1), .amt(snap_amt_s1_l[2:0]), .left(1'b0), .arith(1'b0), .y(snap_sh1_24));
	wire [15:0] snap_sh1 = snap_sh1_24[15:0];
	assign snap_amt_s1 = snap_amt_s1_l;
`else
	assign snap_amt_s2 = snap_amt5[3:0];
	assign snap_amt_s1 = snap_amt5[3:0];
	assign snap_amt_s0 = snap_amt5[3:0];
	wire [31:0] snap_sh1_full;
	am_shift #(.W(32), .SW(4)) u_sn1 (.a(snap_s1_sn1), .amt(snap_amt_s1), .left(1'b0), .arith(1'b0), .y(snap_sh1_full));
	wire [15:0] snap_sh1 = snap_sh1_full[15:0];
`endif

	wire [15:0] snap_sh2;
	wire [31:0] snap_sh0_full;
	am_shift #(.W(16), .SW(4)) u_sn2 (.a(snap_s1_sn2), .amt(snap_amt_s2), .left(1'b0), .arith(1'b0), .y(snap_sh2));
	am_shift #(.W(32), .SW(4)) u_sn0 (.a(snap_s1_sn0), .amt(snap_amt_s0), .left(1'b0), .arith(1'b0), .y(snap_sh0_full));

	wire [47:0] snap_shifted = {snap_sh2, snap_sh1, snap_sh0_full[15:0]};

	(* dont_touch = "true", extract_enable = "no", extract_reset = "no", max_fanout = 16 *) reg [47:0] r_snap_shifted;
	(* extract_enable = "no", max_fanout = 16 *) reg r_snap_sign;
	(* extract_enable = "no", max_fanout = 16 *) reg r_snap_ovf;
	(* extract_enable = "no", max_fanout = 16 *) reg r_snap_zero_out;
	(* extract_enable = "no", max_fanout = 16 *) reg [3:0] r_snap_tsn;
	(* extract_enable = "no", max_fanout = 16 *) reg r_snap_v;

	/* Pipelined f2fix stage 2: combined signed round + saturate in 1 CARRY4 chain */
	wire [23:0] s2_unrounded = r_snap_shifted[47:24];
	wire s2_guard = r_snap_shifted[23];
	wire s2_lsb = s2_unrounded[0];
	wire s2_sticky_lo = (r_snap_shifted[11:0] != 12'd0);
	wire s2_sticky_hi = (r_snap_shifted[22:12] != 11'd0);
	wire [23:0] s2_base = r_snap_sign ? ~s2_unrounded : s2_unrounded;
	wire s2_cin = r_snap_sign ^ (s2_guard && (s2_lsb || s2_sticky_lo || s2_sticky_hi));

	wire [23:0] s2_signed_rnd;
	am_add #(.W(24)) u_s2_rnd (
		.a(s2_base),
		.b(24'd0),
		.ci(s2_cin),
		.s(s2_signed_rnd),
		.co(carry_unused[50])
	);
	assign carry_unused[51] = 1'b0;

	wire [23:0] snap_out;
	generate
	for (gs = 0; gs < 2; gs = gs + 1) begin : g_snap_out
		wire sgn_s, z_s, ov_s;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sgn (.I0(r_snap_sign),     .O(sgn_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_zs  (.I0(r_snap_zero_out), .O(z_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ovs (.I0(r_snap_ovf),      .O(ov_s));
`else
		assign sgn_s = r_snap_sign;
		assign z_s   = r_snap_zero_out;
		assign ov_s  = r_snap_ovf;
`endif
		wire [11:0] sat_s = sgn_s ? SAT_NEG[12 * gs +: 12] : SAT_POS[12 * gs +: 12];
		(* keep = "true" *) wire [11:0] out_s = z_s ? 12'd0 : (ov_s ? sat_s : s2_signed_rnd[12 * gs +: 12]);
		assign snap_out[12 * gs +: 12] = out_s;
	end
	endgenerate

	/* The registers read, in order: 31 32 34 35 37 38, then 76-79: register i + 1 is
	 * 31 + i + i / 2 below 6, else 70 + i. */
	wire [3:0] rri;
	wire [6:0] rrt, rrv;
	am_add #(.W(4)) u_rri (.a(cnt[3:0]), .b(4'd0), .ci(1'b1), .s(rri), .co(carry_unused[0]));
	am_add #(.W(7)) u_rrt (.a({3'd0, rri}), .b({4'd0, rri[3:1]}), .ci(1'b0), .s(rrt),
		.co(carry_unused[1]));
	am_add #(.W(7)) u_rrv (.a(rri < 4'd6 ? rrt : {3'd0, rri}), .b(rri < 4'd6 ? 7'd31 : 7'd70), .ci(1'b0),
		.s(rrv), .co(carry_unused[2]));

	/* Packed snapped coordinates sv[0..9] with 12-bit sliced write enables */
	(* dont_touch = "true", extract_reset = "no" *) reg [239:0] sv_pk;
	wire signed [23:0] sv [0:9];
	wire snap_v_act_raw = !rst_sync && !start && run && r_snap_v;
	wire [1:0] snap_v_act;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_snva0 (.I0(snap_v_act_raw), .O(snap_v_act[0]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_snva1 (.I0(snap_v_act_raw), .O(snap_v_act[1]));
`else
	assign snap_v_act = {2{snap_v_act_raw}};
`endif
	generate
	for (gi = 0; gi < 10; gi = gi + 1) begin : g_sv_reg
		assign sv[gi] = sv_pk[24 * gi +: 24];
		wire sv_we_raw = snap_v_act[gi / 5] && (r_snap_tsn == gi[3:0]);
		wire sv_we_lo, sv_we_hi;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_svl (.I0(sv_we_raw), .O(sv_we_lo));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_svh (.I0(sv_we_raw), .O(sv_we_hi));
`else
		assign sv_we_lo = sv_we_raw;
		assign sv_we_hi = sv_we_raw;
`endif
		always @(posedge clk) begin
			if (sv_we_lo) sv_pk[24 * gi +: 12]      <= snap_out[11:0];
			if (sv_we_hi) sv_pk[24 * gi + 12 +: 12] <= snap_out[23:12];
		end
	end
	endgenerate

	wire signed [23:0] ax = sv[0], ay = sv[1], bx = sv[2], by = sv[3];
	wire signed [23:0] ddx, ddy;
	wire [23:0] neg_ddx, neg_ddy;
	wire [23:0] adx, ady;
	(* dont_touch = "true", extract_enable = "no", extract_reset = "no", max_fanout = 16 *) reg signed [23:0] r_ddx, r_ddy;
	(* dont_touch = "true", extract_enable = "no", extract_reset = "no", max_fanout = 16 *) reg [23:0] r_adx, r_ady;
	(* dont_touch = "true", extract_enable = "no", extract_reset = "no", max_fanout = 16 *) reg signed [23:0] r_hx, r_hy;
	(* extract_enable = "no", max_fanout = 16 *) reg r_xmaj;
	am_sub #(.W(24)) u_ddx (.a(bx), .b(ax), .bi(1'b0), .d(ddx), .bo(carry_unused[3]));
	am_sub #(.W(24)) u_ddy (.a(by), .b(ay), .bi(1'b0), .d(ddy), .bo(carry_unused[4]));
	am_sub #(.W(24)) u_adx (.a(24'd0), .b(r_ddx), .bi(1'b0), .d(neg_ddx), .bo(carry_unused[5]));
	am_sub #(.W(24)) u_ady (.a(24'd0), .b(r_ddy), .bi(1'b0), .d(neg_ddy), .bo(carry_unused[6]));
	generate
	for (gs = 0; gs < 2; gs = gs + 1) begin : g_abs_dxy
		wire sx_s, sy_s;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sxs (.I0(r_ddx[23]), .O(sx_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sys (.I0(r_ddy[23]), .O(sy_s));
`else
		assign sx_s = r_ddx[23];
		assign sy_s = r_ddy[23];
`endif
		assign adx[12 * gs +: 12] = sx_s ? neg_ddx[12 * gs +: 12] : r_ddx[12 * gs +: 12];
		assign ady[12 * gs +: 12] = sy_s ? neg_ddy[12 * gs +: 12] : r_ddy[12 * gs +: 12];
	end
	endgenerate

`ifdef MUT_LINE_MAJOR
	wire xmaj = r_adx > r_ady;	/* the TB's mutation check: y-major when equal */
`else
	wire xmaj = r_adx >= r_ady;
`endif
	wire [15:0] eff_line_w = line_width == 16'd0 ? 16'h0100 : line_width;
	wire [15:0] eff_point_s = point_size == 16'd0 ? 16'h0100 : point_size;
	wire signed [23:0] half_line_w = {9'd0, eff_line_w[15:1]};
	wire signed [23:0] half_point_s = {9'd0, eff_point_s[15:1]};

	wire is_line = !is_tri && kind == 2'd1;
`ifdef SYNTH_KINTEX7
	wire is_line_hx, is_line_hy, is_line_w;
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ln_hx (.I0(is_line), .O(is_line_hx));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ln_hy (.I0(is_line), .O(is_line_hy));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ln_w  (.I0(is_line), .O(is_line_w));
`else
	wire is_line_hx = is_line;
	wire is_line_hy = is_line;
	wire is_line_w  = is_line;
`endif

	/* The corners: a triangle's vertices (and v0 again); a line's a-, a+,
	 * b-, b+; a point's p--, p+-, p++, p-+.  The walked triangle is corners
	 * (0, w1, w2). */
	wire signed [23:0] vx2 = sv[4], vy2 = sv[5];
	wire signed [23:0] hx = r_hx;
	wire signed [23:0] hy = r_hy;
	/* a -+ h and b -+ h */
	wire signed [23:0] axm, axp, aym, ayp, bxm, bxp, bym, byp;
	am_sub #(.W(24)) u_axm (.a(ax), .b(hx), .bi(1'b0), .d(axm), .bo(carry_unused[7]));
	am_add #(.W(24)) u_axp (.a(ax), .b(hx), .ci(1'b0), .s(axp), .co(carry_unused[8]));
	am_sub #(.W(24)) u_aym (.a(ay), .b(hy), .bi(1'b0), .d(aym), .bo(carry_unused[9]));
	am_add #(.W(24)) u_ayp (.a(ay), .b(hy), .ci(1'b0), .s(ayp), .co(carry_unused[10]));
	am_sub #(.W(24)) u_bxm (.a(bx), .b(hx), .bi(1'b0), .d(bxm), .bo(carry_unused[11]));
	am_add #(.W(24)) u_bxp (.a(bx), .b(hx), .ci(1'b0), .s(bxp), .co(carry_unused[12]));
	am_sub #(.W(24)) u_bym (.a(by), .b(hy), .bi(1'b0), .d(bym), .bo(carry_unused[13]));
	am_add #(.W(24)) u_byp (.a(by), .b(hy), .ci(1'b0), .s(byp), .co(carry_unused[14]));

	(* dont_touch = "true", extract_reset = "no" *) reg [191:0] r_c_pk;
	wire signed [23:0] r_c0x = r_c_pk[0   +: 24];
	wire signed [23:0] r_c0y = r_c_pk[24  +: 24];
	wire signed [23:0] r_c1x = r_c_pk[48  +: 24];
	wire signed [23:0] r_c1y = r_c_pk[72  +: 24];
	wire signed [23:0] r_c2x = r_c_pk[96  +: 24];
	wire signed [23:0] r_c2y = r_c_pk[120 +: 24];
	wire signed [23:0] r_c3x = r_c_pk[144 +: 24];
	wire signed [23:0] r_c3y = r_c_pk[168 +: 24];

	wire c9_raw = !rst_sync && !start && run && (cnt == 6'd9);
	wire [1:0] c9_mid, tri_c_mid, line_c_mid;
	generate
	for (gi = 0; gi < 2; gi = gi + 1) begin : g_c9_mid
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_c9m (.I0(c9_raw),  .O(c9_mid[gi]));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_trm (.I0(is_tri),  .O(tri_c_mid[gi]));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lnm (.I0(is_line), .O(line_c_mid[gi]));
`else
		assign c9_mid[gi]     = c9_raw;
		assign tri_c_mid[gi]  = is_tri;
		assign line_c_mid[gi] = is_line;
`endif
	end
	for (gs = 0; gs < 2; gs = gs + 1) begin : g_c_half
		localparam integer HI = 12 * gs;
		wire [7:0] we_c, tri_c, line_c;
		for (gi = 0; gi < 8; gi = gi + 1) begin : g_c_buf
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wc (.I0(c9_mid[gs]),     .O(we_c[gi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_tc (.I0(tri_c_mid[gs]),  .O(tri_c[gi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lc (.I0(line_c_mid[gs]), .O(line_c[gi]));
`else
			assign we_c[gi]   = c9_mid[gs];
			assign tri_c[gi]  = tri_c_mid[gs];
			assign line_c[gi] = line_c_mid[gs];
`endif
		end
		always @(posedge clk) begin
			if (we_c[0]) r_c_pk[0   + HI +: 12] <= tri_c[0] ? ax[HI +: 12]  : axm[HI +: 12];
			if (we_c[1]) r_c_pk[24  + HI +: 12] <= tri_c[1] ? ay[HI +: 12]  : aym[HI +: 12];
			if (we_c[2]) r_c_pk[48  + HI +: 12] <= tri_c[2] ? bx[HI +: 12]  : axp[HI +: 12];
			if (we_c[3]) r_c_pk[72  + HI +: 12] <= tri_c[3] ? by[HI +: 12]  : (line_c[3] ? ayp[HI +: 12] : aym[HI +: 12]);
			if (we_c[4]) r_c_pk[96  + HI +: 12] <= tri_c[4] ? vx2[HI +: 12] : (line_c[4] ? bxm[HI +: 12] : axp[HI +: 12]);
			if (we_c[5]) r_c_pk[120 + HI +: 12] <= tri_c[5] ? vy2[HI +: 12] : (line_c[5] ? bym[HI +: 12] : ayp[HI +: 12]);
			if (we_c[6]) r_c_pk[144 + HI +: 12] <= tri_c[6] ? ax[HI +: 12]  : (line_c[6] ? bxp[HI +: 12] : axm[HI +: 12]);
			if (we_c[7]) r_c_pk[168 + HI +: 12] <= tri_c[7] ? ay[HI +: 12]  : (line_c[7] ? byp[HI +: 12] : ayp[HI +: 12]);
		end
	end
	endgenerate

	wire [1:0] w1 = is_tri ? 2'd1 : is_line_w ? (md[2] ? 2'd3 : 2'd2) : (md[2] ? 2'd2 : 2'd1);
	wire [1:0] w2 = is_tri ? 2'd2 : is_line_w ? (md[2] ? 2'd1 : 2'd3) : (md[2] ? 2'd3 : 2'd2);

	/* The walked triangle, the four corners (bbox) and the plane triangle. */
	(* dont_touch = "true", extract_reset = "no" *) reg [71:0] fx_pk;
	(* dont_touch = "true", extract_reset = "no" *) reg [71:0] fy_pk;
	wire signed [23:0] fx [0:2];
	wire signed [23:0] fy [0:2];
	assign fx[0] = fx_pk[0  +: 24];
	assign fx[1] = fx_pk[24 +: 24];
	assign fx[2] = fx_pk[48 +: 24];
	assign fy[0] = fy_pk[0  +: 24];
	assign fy[1] = fy_pk[24 +: 24];
	assign fy[2] = fy_pk[48 +: 24];

	(* dont_touch = "true", extract_reset = "no" *) reg signed [23:0] pdx1, pdy1, pdx2, pdy2, p0x, p0y;
	(* dont_touch = "true", extract_reset = "no" *) reg signed [47:0] pdd;	/* the plane triangle's D (lines and points) */
	wire signed [23:0] fx0 = fx[0], fx1 = fx[1], fx2 = fx[2];
	wire signed [23:0] fy0 = fy[0], fy1 = fy[1], fy2 = fy[2];
	wire signed [23:0] dx1, dy1, dx2, dy2;
	am_sub #(.W(24)) u_dx1 (.a(fx1), .b(fx0), .bi(1'b0), .d(dx1), .bo(carry_unused[15]));
	am_sub #(.W(24)) u_dy1 (.a(fy1), .b(fy0), .bi(1'b0), .d(dy1), .bo(carry_unused[16]));
	am_sub #(.W(24)) u_dx2 (.a(fx2), .b(fx0), .bi(1'b0), .d(dx2), .bo(carry_unused[17]));
	am_sub #(.W(24)) u_dy2 (.a(fy2), .b(fy0), .bi(1'b0), .d(dy2), .bo(carry_unused[18]));

	/* bbox: the corners' pixels, max exclusive, ∩ scissor (when SCISSOR_MAX
	 * != 0) ∩ the viewport's rectangle (vprect, not raw) ∩ RT. */
	function signed [17:0] pix;
		input [15:0] v;	/* a 15.8 value's integer bits */
		pix = {{2{v[15]}}, v};
	endfunction
	wire signed [23:0] q0x = r_c0x, q1x = r_c1x, q2x = r_c2x, q3x = r_c3x;
	wire signed [23:0] q0y = r_c0y, q1y = r_c1y, q2y = r_c2y, q3y = r_c3y;
	wire signed [23:0] s6 = sv[6], s7 = sv[7], s8 = sv[8], s9 = sv[9];
	wire signed [17:0] rx0 = pix(s6[23:8]), rx1 = pix(s7[23:8]);
	wire signed [17:0] ry0 = pix(s8[23:8]), ry1 = pix(s9[23:8]);
	(* dont_touch = "true", extract_reset = "no" *) reg signed [17:0] r_min01_x, r_max01_x, r_min23_x, r_max23_x;
	(* dont_touch = "true", extract_reset = "no" *) reg signed [17:0] r_min01_y, r_max01_y, r_min23_y, r_max23_y;
	(* dont_touch = "true", extract_reset = "no" *) reg signed [17:0] r_lx, r_ly, r_mx, r_my;
	(* dont_touch = "true", extract_reset = "no" *) reg signed [17:0] r_mx1, r_my1;
	(* dont_touch = "true", extract_reset = "no" *) reg signed [17:0] r_clx, r_cly, r_cmx, r_cmy;
	(* dont_touch = "true", extract_reset = "no" *) reg signed [17:0] bx0, by0, bx1, by1;
	wire [17:0] m_x1, m_y1;	/* the largest pixel + 1 (calculated in Stage 2) */
	am_add #(.W(18)) u_m_x1 (.a(r_mx), .b(18'd0), .ci(1'b1), .s(m_x1), .co(carry_unused[19]));
	am_add #(.W(18)) u_m_y1 (.a(r_my), .b(18'd0), .ci(1'b1), .s(m_y1), .co(carry_unused[20]));

	/* Stage 3 of bbox: scissor, viewport, and RT clamping */
	(* max_fanout = 16 *) reg r_scis_en;
	(* dont_touch = "true", extract_reset = "no" *) reg signed [17:0] r_scis_rt_min_x, r_scis_rt_max_x;
	(* dont_touch = "true", extract_reset = "no" *) reg signed [17:0] r_scis_rt_min_y, r_scis_rt_max_y;

	(* dont_touch = "true", extract_reset = "no" *) reg signed [17:0] r_win_min_x, r_win_max_x, r_win_min_y, r_win_max_y;
	(* keep = "true" *) wire win_min_x_sel = vprect && !md[3] && (rx0 > r_scis_rt_min_x);
	(* keep = "true" *) wire win_max_x_sel = vprect && !md[3] && (rx1 < r_scis_rt_max_x);
	(* keep = "true" *) wire win_min_y_sel = vprect && !md[3] && (ry0 > r_scis_rt_min_y);
	(* keep = "true" *) wire win_max_y_sel = vprect && !md[3] && (ry1 < r_scis_rt_max_y);

	(* keep = "true" *) wire lo_scis_x_sel = (r_lx < r_win_min_x);
	(* keep = "true" *) wire hi_scis_x_sel = (r_mx1 > r_win_max_x);
	(* keep = "true" *) wire lo_scis_y_sel = (r_ly < r_win_min_y);
	(* keep = "true" *) wire hi_scis_y_sel = (r_my1 > r_win_max_y);

	/* The sample at the bbox origin, in subpixels. */
	wire signed [24:0] sx = {bx0[16:0], 8'd128};
	wire signed [24:0] sy = {by0[16:0], 8'd128};

	(* dont_touch = "true", extract_reset = "no" *) reg signed [47:0] dd;	/* D = dx1 dy2 - dx2 dy1 (subpixel^2); area2 = -D */
	(* dont_touch = "true", extract_reset = "no" *) reg signed [47:0] r_dx1_dy2;
	wire ccw = dd[47];
	(* dont_touch = "true", extract_reset = "no" *) reg [71:0] eA_pk;
	(* dont_touch = "true", extract_reset = "no" *) reg [71:0] eB_pk;
	(* dont_touch = "true", extract_reset = "no" *) reg [74:0] oX_pk;
	(* dont_touch = "true", extract_reset = "no" *) reg [74:0] oY_pk;
	wire signed [23:0] eA [0:2];
	wire signed [23:0] eB [0:2];
	wire signed [24:0] oX [0:2];
	wire signed [24:0] oY [0:2];
	assign eA[0] = eA_pk[0  +: 24];
	assign eA[1] = eA_pk[24 +: 24];
	assign eA[2] = eA_pk[48 +: 24];
	assign eB[0] = eB_pk[0  +: 24];
	assign eB[1] = eB_pk[24 +: 24];
	assign eB[2] = eB_pk[48 +: 24];
	assign oX[0] = oX_pk[0  +: 25];
	assign oX[1] = oX_pk[25 +: 25];
	assign oX[2] = oX_pk[50 +: 25];
	assign oY[0] = oY_pk[0  +: 25];
	assign oY[1] = oY_pk[25 +: 25];
	assign oY[2] = oY_pk[50 +: 25];

	reg [2:0] tl;
	(* dont_touch = "true", extract_reset = "no" *) reg [143:0] eE_pk;
	wire [47:0] eE [0:2];
	wire empty_buf [0:2][0:2];
`ifdef SYNTH_KINTEX7
	genvar geb, gsb_e;
	generate
		for (geb = 0; geb < 3; geb = geb + 1) begin : g_eb_edge
			for (gsb_e = 0; gsb_e < 3; gsb_e = gsb_e + 1) begin : g_eb_slice
				(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_eb (.I0(empty), .O(empty_buf[geb][gsb_e]));
			end
		end
	endgenerate
`else
	genvar geb_s, gsb_s;
	generate
		for (geb_s = 0; geb_s < 3; geb_s = geb_s + 1) begin : g_eb_sim
			for (gsb_s = 0; gsb_s < 3; gsb_s = gsb_s + 1) begin : g_eb_slice_sim
				assign empty_buf[geb_s][gsb_s] = empty;
			end
		end
	endgenerate
`endif
	assign eE[0] = {empty_buf[0][2] ? 16'd0 : eE_pk[32 +: 16],
	                empty_buf[0][1] ? 16'd0 : eE_pk[16 +: 16],
	                empty_buf[0][0] ? 16'd0 : eE_pk[0  +: 16]};
	assign eE[1] = {empty_buf[1][2] ? 16'd0 : eE_pk[80 +: 16],
	                empty_buf[1][1] ? 16'd0 : eE_pk[64 +: 16],
	                empty_buf[1][0] ? 16'd0 : eE_pk[48 +: 16]};
	assign eE[2] = {empty_buf[2][2] ? 16'd0 : eE_pk[128 +: 16],
	                empty_buf[2][1] ? 16'd0 : eE_pk[112 +: 16],
	                empty_buf[2][0] ? 16'd0 : eE_pk[96  +: 16]};
	(* dont_touch = "true", extract_reset = "no" *) reg [49:0] acc;

	/* Vertex of the ordered (area2 > 0) triangle's corner i: (0,1,2) or (0,2,1). */
	function [1:0] vtx;
		input [1:0] i;
		input c;
		vtx = c ? i : (i == 2'd0 ? 2'd0 : 2'd3 - i);
	endfunction

	/* Steps 23-29 select DX1 DY1 DX2 DY2 DF OX OY of the plane triangle (OX, OY:
	 * dedicated subtracters calculated at cnt 16-17). */
	(* dont_touch = "true", extract_reset = "no" *) reg [47:0] r_cox_d, r_coy_d;
	wire [47:0] cox_d, coy_d;
	wire sx_s_lo, sx_s_hi, sy_s_lo, sy_s_hi;
	wire p0x_s_lo, p0x_s_hi, p0y_s_lo, p0y_s_hi;
	wire pdx1_s_lo, pdx1_s_hi, pdy1_s_lo, pdy1_s_hi, pdx2_s_lo, pdx2_s_hi, pdy2_s_lo, pdy2_s_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sxl  (.I0(sx[24]),   .O(sx_s_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sxh  (.I0(sx[24]),   .O(sx_s_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_syl  (.I0(sy[24]),   .O(sy_s_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_syh  (.I0(sy[24]),   .O(sy_s_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_p0xl (.I0(p0x[23]),  .O(p0x_s_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_p0xh (.I0(p0x[23]),  .O(p0x_s_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_p0yl (.I0(p0y[23]),  .O(p0y_s_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_p0yh (.I0(p0y[23]),  .O(p0y_s_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_px1l (.I0(pdx1[23]), .O(pdx1_s_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_px1h (.I0(pdx1[23]), .O(pdx1_s_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_py1l (.I0(pdy1[23]), .O(pdy1_s_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_py1h (.I0(pdy1[23]), .O(pdy1_s_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_px2l (.I0(pdx2[23]), .O(pdx2_s_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_px2h (.I0(pdx2[23]), .O(pdx2_s_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_py2l (.I0(pdy2[23]), .O(pdy2_s_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_py2h (.I0(pdy2[23]), .O(pdy2_s_hi));
`else
	assign sx_s_lo   = sx[24];
	assign sx_s_hi   = sx[24];
	assign sy_s_lo   = sy[24];
	assign sy_s_hi   = sy[24];
	assign p0x_s_lo  = p0x[23];
	assign p0x_s_hi  = p0x[23];
	assign p0y_s_lo  = p0y[23];
	assign p0y_s_hi  = p0y[23];
	assign pdx1_s_lo = pdx1[23];
	assign pdx1_s_hi = pdx1[23];
	assign pdy1_s_lo = pdy1[23];
	assign pdy1_s_hi = pdy1[23];
	assign pdx2_s_lo = pdx2[23];
	assign pdx2_s_hi = pdx2[23];
	assign pdy2_s_lo = pdy2[23];
	assign pdy2_s_hi = pdy2[23];
`endif
	wire [47:0] sx_ext   = {{12{sx_s_hi}},   {11{sx_s_lo}},   sx};
	wire [47:0] sy_ext   = {{12{sy_s_hi}},   {11{sy_s_lo}},   sy};
	wire [47:0] p0x_ext  = {{12{p0x_s_hi}},  {12{p0x_s_lo}},  p0x};
	wire [47:0] p0y_ext  = {{12{p0y_s_hi}},  {12{p0y_s_lo}},  p0y};
	wire [47:0] pdx1_ext = {{12{pdx1_s_hi}}, {12{pdx1_s_lo}}, pdx1};
	wire [47:0] pdy1_ext = {{12{pdy1_s_hi}}, {12{pdy1_s_lo}}, pdy1};
	wire [47:0] pdx2_ext = {{12{pdx2_s_hi}}, {12{pdx2_s_lo}}, pdx2};
	wire [47:0] pdy2_ext = {{12{pdy2_s_hi}}, {12{pdy2_s_lo}}, pdy2};

	am_sub #(.W(48)) u_cox_sub (.a(sx_ext), .b(p0x_ext), .bi(1'b0), .d(cox_d), .bo(carry_unused[25]));
	am_sub #(.W(48)) u_coy_sub (.a(sy_ext), .b(p0y_ext), .bi(1'b0), .d(coy_d), .bo(carry_unused[47]));

	/* int2f: a 48-bit signed integer times 2^-sh to fp32, four stages:
	 * Stage 1 (cnt 23-29): absolute value & leading zeros
	 * Stage 2 (cnt 24-30): latch abs & shift amount
	 * Stage 3 (cnt 25-31): barrel shifter and exponent addition
	 * Stage 4 (cnt 26-32): rounding increment, exponent subtract, and pack into fp registers 40-46 */
	(* dont_touch = "true", extract_enable = "no", extract_reset = "no", max_fanout = 16 *) reg [47:0] r_cabs;
	(* extract_enable = "no", max_fanout = 16 *) reg r_cs;
	(* extract_enable = "no", max_fanout = 16 *) reg [4:0] r_csh;
	(* dont_touch = "true", extract_enable = "no", extract_reset = "no", max_fanout = 16 *) reg [47:0] ca;
	reg [2:0] r_cabs_nz;
	(* extract_enable = "no", max_fanout = 16 *) reg cs;
	(* extract_enable = "no", max_fanout = 16 *) reg [5:0] clz;
	(* extract_enable = "no", max_fanout = 16 *) reg [4:0] csh;
	(* dont_touch = "true", extract_enable = "no", extract_reset = "no", max_fanout = 16 *) reg [47:0] r_ci;
	(* extract_enable = "no", max_fanout = 16 *) reg [4:0] r_ci_sh;
	(* extract_enable = "no", max_fanout = 16 *) reg r_ci_sgn;

	wire [47:0] neg_ci, cabs;
	am_sub #(.W(48)) u_cabs (.a(48'd0), .b(r_ci), .bi(1'b0), .d(neg_ci), .bo(carry_unused[21]));
	generate
	for (gs = 0; gs < 3; gs = gs + 1) begin : g_cabs_sel
		wire ci_sgn_s;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cis (.I0(r_ci_sgn), .O(ci_sgn_s));
`else
		assign ci_sgn_s = r_ci_sgn;
`endif
		assign cabs[16 * gs +: 16] = ci_sgn_s ? neg_ci[16 * gs +: 16] : r_ci[16 * gs +: 16];
	end
	endgenerate

	reg [5:0] cl;
	always @(*) begin
		cl = 6'd48;
		for (k = 0; k < 48; k = k + 1)
			if (r_cabs[k])
				cl = 6'd47 - k[5:0];
	end

	/* Stage 3: normalised, exponent 174 - clz - csh */
	wire [47:0] ca_s1 =
		(clz[5:4] == 2'd0) ? ca :
		(clz[5:4] == 2'd1) ? {ca[31:0], 16'd0} :
		{ca[15:0], 32'd0};

	wire [3:0] clz_sh0_lo, clz_sh0_hi, clz_sh1_lo, clz_sh1_hi, clz_sh2_lo, clz_sh2_hi;
`ifdef SYNTH_KINTEX7
	genvar gca;
	generate
		for (gca = 0; gca < 4; gca = gca + 1) begin : g_clz_amt_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ca0_l (.I0(clz[gca]), .O(clz_sh0_lo[gca]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ca0_h (.I0(clz[gca]), .O(clz_sh0_hi[gca]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ca1_l (.I0(clz[gca]), .O(clz_sh1_lo[gca]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ca1_h (.I0(clz[gca]), .O(clz_sh1_hi[gca]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ca2_l (.I0(clz[gca]), .O(clz_sh2_lo[gca]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ca2_h (.I0(clz[gca]), .O(clz_sh2_hi[gca]));
		end
	endgenerate
`else
	assign clz_sh0_lo = clz[3:0];
	assign clz_sh0_hi = clz[3:0];
	assign clz_sh1_lo = clz[3:0];
	assign clz_sh1_hi = clz[3:0];
	assign clz_sh2_lo = clz[3:0];
	assign clz_sh2_hi = clz[3:0];
`endif

	wire [7:0] cn_sh0_lo;
	wire [15:0] cn_sh0_hi;
	am_shift #(.W(8),  .SW(4)) u_cn0_l (.a(ca_s1[7:0]),  .amt(clz_sh0_lo), .left(1'b1), .arith(1'b0), .y(cn_sh0_lo));
	am_shift #(.W(16), .SW(4)) u_cn0_h (.a(ca_s1[15:0]), .amt(clz_sh0_hi), .left(1'b1), .arith(1'b0), .y(cn_sh0_hi));
	wire [15:0] cn_sh0 = {cn_sh0_hi[15:8], cn_sh0_lo};

	wire [31:0] ca_s1_sh8 = {clz_sh1_hi[3] ? ca_s1[23:8] : ca_s1[31:16],
	                         clz_sh1_lo[3] ? {ca_s1[7:0], 8'd0} : ca_s1[15:0]};
	wire [15:0] cn_sh1_l, cn_sh1_h;
	am_shift #(.W(16), .SW(3)) u_cn1_l (.a(ca_s1_sh8[23:8]),  .amt(clz_sh1_lo[2:0]), .left(1'b1), .arith(1'b0), .y(cn_sh1_l));
	am_shift #(.W(16), .SW(3)) u_cn1_h (.a(ca_s1_sh8[31:16]), .amt(clz_sh1_hi[2:0]), .left(1'b1), .arith(1'b0), .y(cn_sh1_h));
	wire [15:0] cn_sh1_mid = {cn_sh1_h[15:8], cn_sh1_l[15:8]};

	wire [31:0] ca_s2_sh8 = {clz_sh2_hi[3] ? ca_s1[39:24] : ca_s1[47:32],
	                         clz_sh2_lo[3] ? {ca_s1[23:16], 8'd0} : ca_s1[31:16]};
	wire [15:0] cn_sh2_l, cn_sh2_h;
	am_shift #(.W(16), .SW(3)) u_cn2_l (.a(ca_s2_sh8[23:8]),  .amt(clz_sh2_lo[2:0]), .left(1'b1), .arith(1'b0), .y(cn_sh2_l));
	am_shift #(.W(16), .SW(3)) u_cn2_h (.a(ca_s2_sh8[31:16]), .amt(clz_sh2_hi[2:0]), .left(1'b1), .arith(1'b0), .y(cn_sh2_h));
	wire [15:0] cn_sh2_mid = {cn_sh2_h[15:8], cn_sh2_l[15:8]};

	wire [47:0] cn = {cn_sh2_mid, cn_sh1_mid, cn_sh0};
	wire [15:0] cn_sh_unused = {cn_sh2_l[7:0], cn_sh1_l[7:0]};

	wire [8:0] czs;
	am_add #(.W(9)) u_czs (.a({3'd0, clz}), .b({4'd0, csh}), .ci(1'b0), .s(czs),
		.co(carry_unused[23]));

	(* dont_touch = "true", extract_reset = "no" *) reg [47:0] r_cn;
	(* dont_touch = "true", extract_reset = "no" *) reg r_cn_guard;
	(* dont_touch = "true", extract_reset = "no" *) reg r_cn_stk0;
	(* dont_touch = "true", extract_reset = "no" *) reg r_cn_stk1;
	(* max_fanout = 16 *) reg r_cs2;
	reg [8:0] r_czs;
	(* max_fanout = 16 *) reg r_ca_zero;

	/* Stage 4: CARRY4 rounding incrementer with registered sticky/guard bits */
	wire [23:0] cm_in = r_cn[47:24];
	wire cm_inc = r_cn_guard && (r_cn_stk0 || r_cn_stk1 || r_cn[24]);
	wire [24:0] cm;
	am_add #(.W(25)) u_cm (
		.a({1'b0, cm_in}),
		.b(25'd0),
		.ci(cm_inc),
		.s(cm),
		.co(carry_unused[52])
	);

	wire [8:0] ce0, ce1;
	am_sub #(.W(9)) u_ce0 (.a(9'd174), .b(r_czs), .bi(1'b0), .d(ce0), .bo(carry_unused[24]));
	am_sub #(.W(9)) u_ce1 (.a(9'd175), .b(r_czs), .bi(1'b0), .d(ce1), .bo(carry_unused[22]));

	wire caz_lo, caz_hi, cm24_lo, cm24_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cazl  (.I0(r_ca_zero), .O(caz_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cazh  (.I0(r_ca_zero), .O(caz_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cm24l (.I0(cm[24]),    .O(cm24_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cm24h (.I0(cm[24]),    .O(cm24_hi));
`else
	assign caz_lo  = r_ca_zero;
	assign caz_hi  = r_ca_zero;
	assign cm24_lo = cm[24];
	assign cm24_hi = cm[24];
`endif
	wire [7:0] ce = cm24_hi ? ce1[7:0] : ce0[7:0];
	wire [22:0] cm_mant = {cm24_hi ? cm[23:13] : cm[22:12], cm24_lo ? cm[12:1] : cm[11:0]};
	wire [31:0] c_out = {caz_hi ? 16'd0 : {r_cs2, ce[7:0], cm_mant[22:16]},
	                     caz_lo ? 16'd0 : cm_mant[15:0]};

	/* steps 17-22: products of edge ce_e / 2 (cnt - 17); 19-24: their results (cnt
	 * - 19); steps 1-10: the snapped value (cnt - 1); cnt + 1; the register written */
	wire [2:0] ce_e, ce_p;
	wire [3:0] tsn;
	wire [5:0] cnt1;
	wire [6:0] wa_n;
	am_sub #(.W(3)) u_ce_e (.a(cnt[2:0]), .b(3'd1), .bi(1'b0), .d(ce_e), .bo(carry_unused[26]));
	am_sub #(.W(3)) u_ce_p (.a(cnt[2:0]), .b(3'd3), .bi(1'b0), .d(ce_p), .bo(carry_unused[27]));
	am_sub #(.W(4)) u_tsn (.a(cnt[3:0]), .b(4'd1), .bi(1'b0), .d(tsn), .bo(carry_unused[28]));
	am_add #(.W(6)) u_cnt1 (.a(cnt), .b(6'd0), .ci(1'b1), .s(cnt1), .co(carry_unused[29]));
	am_add #(.W(7)) u_wa_n (.a({1'b0, cnt}), .b(7'd14), .ci(1'b0), .s(wa_n),
		.co(carry_unused[30]));	/* 40 + cnt - 26 */
	wire [1:0] ej = ce_e[2:1];
	wire [1:0] ek = ce_p[2:1];
	/* the plane triangle's second delta; D's line form; D = dx1 dy2 - dx2 dy1 */
	wire signed [23:0] vdx2, vdy2;
	wire [47:0] ndy, dd_n;
	wire r_ddy_s_ndy;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ddysn (.I0(r_ddy[23]), .O(r_ddy_s_ndy));
`else
	assign r_ddy_s_ndy = r_ddy[23];
`endif
	am_sub #(.W(24)) u_vdx2 (.a(vx2), .b(ax), .bi(1'b0), .d(vdx2), .bo(carry_unused[31]));
	am_sub #(.W(24)) u_vdy2 (.a(vy2), .b(ay), .bi(1'b0), .d(vdy2), .bo(carry_unused[32]));
	am_sub #(.W(48)) u_ndy (.a(48'd0), .b({{16{r_ddy_s_ndy}}, r_ddy, 8'd0}), .bi(1'b0), .d(ndy),
		.bo(carry_unused[33]));

	/* The multiplier: DSP48E1 internal MREG and PREG (LAT = 2), sliced muxes for fanout <= 13 */
	wire signed [24:0] ma_comb, mb_comb;
	wire [24:0] eA_ext [0:2];
	wire [24:0] eB_ext [0:2];
	assign eA_ext[0] = {eA[0][23], eA[0]};
	assign eA_ext[1] = {eA[1][23], eA[1]};
	assign eA_ext[2] = {eA[2][23], eA[2]};
	assign eB_ext[0] = {eB[0][23], eB[0]};
	assign eB_ext[1] = {eB[1][23], eB[1]};
	assign eB_ext[2] = {eB[2][23], eB[2]};
	wire [24:0] dx1_25 = {dx1[23], dx1};
	wire [24:0] dx2_25 = {dx2[23], dx2};
	wire [24:0] dy1_25 = {dy1[23], dy1};
	wire [24:0] dy2_25 = {dy2[23], dy2};
	generate
	for (gs = 0; gs < 4; gs = gs + 1) begin : g_mp_mux
		localparam integer LO = (gs == 0) ? 0  : (gs == 1) ? 6 : (gs == 2) ? 12 : 18;
		localparam integer W  = (gs == 3) ? 7 : 6;
		wire m_c12_r = (cnt == 6'd12);
		wire m_c13_r = (cnt == 6'd13);
		wire m_c12_a, m_c13_a, m_cee_a, m_ej0_a, m_ej1_a;
		wire m_c12_b, m_c13_b, m_cee_b, m_ej0_b, m_ej1_b;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mc12a (.I0(m_c12_r), .O(m_c12_a));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mc13a (.I0(m_c13_r), .O(m_c13_a));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mceea (.I0(ce_e[0]), .O(m_cee_a));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mej0a (.I0(ej[0]),   .O(m_ej0_a));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mej1a (.I0(ej[1]),   .O(m_ej1_a));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mc12b (.I0(m_c12_r), .O(m_c12_b));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mc13b (.I0(m_c13_r), .O(m_c13_b));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mceeb (.I0(ce_e[0]), .O(m_cee_b));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mej0b (.I0(ej[0]),   .O(m_ej0_b));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mej1b (.I0(ej[1]),   .O(m_ej1_b));
`else
		assign m_c12_a = m_c12_r;
		assign m_c13_a = m_c13_r;
		assign m_cee_a = ce_e[0];
		assign m_ej0_a = ej[0];
		assign m_ej1_a = ej[1];
		assign m_c12_b = m_c12_r;
		assign m_c13_b = m_c13_r;
		assign m_cee_b = ce_e[0];
		assign m_ej0_b = ej[0];
		assign m_ej1_b = ej[1];
`endif
		(* keep = "true" *) wire [W-1:0] ea_s = m_ej1_a ? eA_ext[2][LO +: W] : (m_ej0_a ? eA_ext[1][LO +: W] : eA_ext[0][LO +: W]);
		(* keep = "true" *) wire [W-1:0] eb_s = m_ej1_a ? eB_ext[2][LO +: W] : (m_ej0_a ? eB_ext[1][LO +: W] : eB_ext[0][LO +: W]);
		(* keep = "true" *) wire [W-1:0] ox_s = m_ej1_b ? oX[2][LO +: W]     : (m_ej0_b ? oX[1][LO +: W]     : oX[0][LO +: W]);
		(* keep = "true" *) wire [W-1:0] oy_s = m_ej1_b ? oY[2][LO +: W]     : (m_ej0_b ? oY[1][LO +: W]     : oY[0][LO +: W]);
		assign ma_comb[LO +: W] = m_c12_a ? dx1_25[LO +: W] : (m_c13_a ? dx2_25[LO +: W] : (m_cee_a ? eb_s : ea_s));
		assign mb_comb[LO +: W] = m_c12_b ? dy2_25[LO +: W] : (m_c13_b ? dy1_25[LO +: W] : (m_cee_b ? oy_s : ox_s));
	end
	endgenerate

	wire signed [49:0] mp;
	am_mul #(.AW(25), .BW(25), .SIGNED(1), .LAT(2)) u_mp (.clk(clk), .en(1'b1), .a(ma_comb), .b(mb_comb), .p(mp));

	am_sub #(.W(48)) u_dd_n (.a(r_dx1_dy2), .b(mp[47:0]), .bi(1'b0), .d(dd_n), .bo(carry_unused[34]));
	/* the edges of the ordered triangle: A = y1 - y0, B = x0 - x1, oX = sx - x0, oY = sy - y0 */
	wire [23:0] eA_n [0:2];
	wire [23:0] eB_n [0:2];
	wire [24:0] oX_n [0:2];
	wire [24:0] oY_n [0:2];
	wire [47:0] eE_n;
	wire ccw_edge [0:2];
`ifdef SYNTH_KINTEX7
	genvar gce;
	generate
		for (gce = 0; gce < 3; gce = gce + 1) begin : g_ccw_e
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ccw_e (.I0(ccw), .O(ccw_edge[gce]));
		end
	endgenerate
`else
	assign ccw_edge[0] = ccw;
	assign ccw_edge[1] = ccw;
	assign ccw_edge[2] = ccw;
`endif

	genvar ge;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_e
		localparam [1:0] K0 = ge, K1 = ge == 2 ? 0 : ge + 1;
		wire [23:0] fy_v0, fy_v0_oy, fy_v1, fx_v0, fx_v0_ox, fx_v1;
		for (gs = 0; gs < 2; gs = gs + 1) begin : g_vtx_s
			localparam integer HI = 12 * gs;
			wire ccw_ya, ccw_yo, ccw_yb;
			wire ccw_xa, ccw_xo, ccw_xb;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ccw_ya (.I0(ccw_edge[ge]), .O(ccw_ya));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ccw_yo (.I0(ccw_edge[ge]), .O(ccw_yo));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ccw_yb (.I0(ccw_edge[ge]), .O(ccw_yb));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ccw_xa (.I0(ccw_edge[ge]), .O(ccw_xa));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ccw_xo (.I0(ccw_edge[ge]), .O(ccw_xo));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ccw_xb (.I0(ccw_edge[ge]), .O(ccw_xb));
`else
			assign ccw_ya = ccw_edge[ge];
			assign ccw_yo = ccw_edge[ge];
			assign ccw_yb = ccw_edge[ge];
			assign ccw_xa = ccw_edge[ge];
			assign ccw_xo = ccw_edge[ge];
			assign ccw_xb = ccw_edge[ge];
`endif
			wire [1:0] v0_a    = vtx(K0, ccw_ya);
			wire [1:0] v0_a_oy = vtx(K0, ccw_yo);
			wire [1:0] v1_a    = vtx(K1, ccw_yb);
			wire [1:0] v0_b    = vtx(K0, ccw_xa);
			wire [1:0] v0_b_ox = vtx(K0, ccw_xo);
			wire [1:0] v1_b    = vtx(K1, ccw_xb);
			assign fy_v0[HI +: 12]    = fy[v0_a][HI +: 12];
			assign fy_v0_oy[HI +: 12] = fy[v0_a_oy][HI +: 12];
			assign fy_v1[HI +: 12]    = fy[v1_a][HI +: 12];
			assign fx_v0[HI +: 12]    = fx[v0_b][HI +: 12];
			assign fx_v0_ox[HI +: 12] = fx[v0_b_ox][HI +: 12];
			assign fx_v1[HI +: 12]    = fx[v1_b][HI +: 12];
		end
		am_sub #(.W(24)) u_eA (.a(fy_v1), .b(fy_v0), .bi(1'b0), .d(eA_n[ge]),
			.bo(carry_unused[35 + 4 * ge]));
		am_sub #(.W(24)) u_eB (.a(fx_v0), .b(fx_v1), .bi(1'b0), .d(eB_n[ge]),
			.bo(carry_unused[36 + 4 * ge]));
		am_sub #(.W(25)) u_oX (.a(sx), .b({fx_v0_ox[23], fx_v0_ox}), .bi(1'b0), .d(oX_n[ge]),
			.bo(carry_unused[37 + 4 * ge]));
		am_sub #(.W(25)) u_oY (.a(sy), .b({fy_v0_oy[23], fy_v0_oy}), .bi(1'b0), .d(oY_n[ge]),
			.bo(carry_unused[38 + 4 * ge]));
	end
	endgenerate
	/* E_k = (A_k oX_k - !tl_k) + B_k oY_k */
	wire [47:0] acc_n;
	am_sub #(.W(48)) u_acc_n (.a(mp[47:0]), .b(48'd0), .bi(!tl[ek]), .d(acc_n), .bo(carry_unused[48]));
	am_add #(.W(48)) u_eE_n (.a(acc[47:0]), .b(mp[47:0]), .ci(1'b0), .s(eE_n),
		.co(carry_unused[47]));

	/* Sliced datapath register updates to keep every write-enable and mux select fanout <= 16 */
	wire c_act = !rst_sync && !start && run;

	/* cnt == 1..10: r_snap_shifted (3 x 16-bit) */
	wire we_snap_raw = c_act && (cnt >= 6'd1 && cnt <= 6'd10);
	generate
	for (gs = 0; gs < 3; gs = gs + 1) begin : g_snap_reg
		wire we_s;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wsn (.I0(we_snap_raw), .O(we_s));
`else
		assign we_s = we_snap_raw;
`endif
		always @(posedge clk) begin
			if (we_s) r_snap_shifted[16 * gs +: 16] <= snap_shifted[16 * gs +: 16];
		end
	end
	endgenerate

	/* cnt == 1, 2: 2-stage pipelined scissor/viewport calculation */
	wire we_c1_raw   = c_act && (cnt == 6'd1);
	wire we_c2_raw   = c_act && (cnt == 6'd2);
	reg [31:0] r_smin, r_smax, r_rts;
	reg r_sc_minx, r_sc_maxx, r_sc_miny, r_sc_maxy;
	wire [3:0] we_c2_s;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wc2_0 (.I0(we_c2_raw), .O(we_c2_s[0]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wc2_1 (.I0(we_c2_raw), .O(we_c2_s[1]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wc2_2 (.I0(we_c2_raw), .O(we_c2_s[2]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wc2_3 (.I0(we_c2_raw), .O(we_c2_s[3]));
`else
	assign we_c2_s = {4{we_c2_raw}};
`endif
	always @(posedge clk) begin
		if (we_c1_raw) begin
			r_sc_minx <= r_scis_en && ($signed({2'b00, r_smin[15:0]})  > 18'sd0);
			r_sc_maxx <= r_scis_en && ($signed({2'b00, r_smax[15:0]})  < $signed({2'b00, r_rts[15:0]}));
			r_sc_miny <= r_scis_en && ($signed({2'b00, r_smin[31:16]}) > 18'sd0);
			r_sc_maxy <= r_scis_en && ($signed({2'b00, r_smax[31:16]}) < $signed({2'b00, r_rts[31:16]}));
		end
		if (we_c2_s[0]) r_scis_rt_min_x <= r_sc_minx ? $signed({2'b00, r_smin[15:0]})  : 18'sd0;
		if (we_c2_s[1]) r_scis_rt_max_x <= r_sc_maxx ? $signed({2'b00, r_smax[15:0]})  : $signed({2'b00, r_rts[15:0]});
		if (we_c2_s[2]) r_scis_rt_min_y <= r_sc_miny ? $signed({2'b00, r_smin[31:16]}) : 18'sd0;
		if (we_c2_s[3]) r_scis_rt_max_y <= r_sc_maxy ? $signed({2'b00, r_smax[31:16]}) : $signed({2'b00, r_rts[31:16]});
	end

	/* cnt == 6, 7: r_ddx, r_ddy, r_adx, r_ady (2 x 12-bit slices) */
	wire we_c6_raw = c_act && (cnt == 6'd6);
	wire we_c7_raw = c_act && (cnt == 6'd7);
	generate
	for (gs = 0; gs < 2; gs = gs + 1) begin : g_c67_reg
		localparam integer HI = 12 * gs;
		wire wc6_x, wc6_y, wc7_x, wc7_y;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wc6x (.I0(we_c6_raw), .O(wc6_x));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wc6y (.I0(we_c6_raw), .O(wc6_y));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wc7x (.I0(we_c7_raw), .O(wc7_x));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wc7y (.I0(we_c7_raw), .O(wc7_y));
`else
		assign wc6_x = we_c6_raw;
		assign wc6_y = we_c6_raw;
		assign wc7_x = we_c7_raw;
		assign wc7_y = we_c7_raw;
`endif
		always @(posedge clk) begin
			if (wc6_x) r_ddx[HI +: 12] <= ddx[HI +: 12];
			if (wc6_y) r_ddy[HI +: 12] <= ddy[HI +: 12];
			if (wc7_x) r_adx[HI +: 12] <= adx[HI +: 12];
			if (wc7_y) r_ady[HI +: 12] <= ady[HI +: 12];
		end
	end
	endgenerate

	/* cnt == 10: r_min01_x..r_max23_y (2 x 9-bit slices) */
	wire we_c10_raw = c_act && (cnt == 6'd10);
	(* keep = "true" *) wire cmp_min01_x = pix(q0x[23:8]) < pix(q1x[23:8]);
	(* keep = "true" *) wire cmp_max01_x = pix(q0x[23:8]) > pix(q1x[23:8]);
	(* keep = "true" *) wire cmp_min23_x = pix(q2x[23:8]) < pix(q3x[23:8]);
	(* keep = "true" *) wire cmp_max23_x = pix(q2x[23:8]) > pix(q3x[23:8]);
	(* keep = "true" *) wire cmp_min01_y = pix(q0y[23:8]) < pix(q1y[23:8]);
	(* keep = "true" *) wire cmp_max01_y = pix(q0y[23:8]) > pix(q1y[23:8]);
	(* keep = "true" *) wire cmp_min23_y = pix(q2y[23:8]) < pix(q3y[23:8]);
	(* keep = "true" *) wire cmp_max23_y = pix(q2y[23:8]) > pix(q3y[23:8]);
	wire signed [17:0] p_q0x = pix(q0x[23:8]), p_q1x = pix(q1x[23:8]), p_q2x = pix(q2x[23:8]), p_q3x = pix(q3x[23:8]);
	wire signed [17:0] p_q0y = pix(q0y[23:8]), p_q1y = pix(q1y[23:8]), p_q2y = pix(q2y[23:8]), p_q3y = pix(q3y[23:8]);
	generate
	for (gs = 0; gs < 2; gs = gs + 1) begin : g_c10_reg
		localparam integer HI = 9 * gs;
		wire wc10_m;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wc10m (.I0(we_c10_raw), .O(wc10_m));
`else
		assign wc10_m = we_c10_raw;
`endif
		wire [7:0] wc10;
		wire s_mn01x, s_mx01x, s_mn23x, s_mx23x, s_mn01y, s_mx01y, s_mn23y, s_mx23y;
		for (gi = 0; gi < 8; gi = gi + 1) begin : g_wc10_b
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wc (.I0(wc10_m), .O(wc10[gi]));
`else
			assign wc10[gi] = wc10_m;
`endif
		end
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cm0 (.I0(cmp_min01_x), .O(s_mn01x));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cm1 (.I0(cmp_max01_x), .O(s_mx01x));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cm2 (.I0(cmp_min23_x), .O(s_mn23x));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cm3 (.I0(cmp_max23_x), .O(s_mx23x));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cm4 (.I0(cmp_min01_y), .O(s_mn01y));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cm5 (.I0(cmp_max01_y), .O(s_mx01y));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cm6 (.I0(cmp_min23_y), .O(s_mn23y));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cm7 (.I0(cmp_max23_y), .O(s_mx23y));
`else
		assign s_mn01x = cmp_min01_x;
		assign s_mx01x = cmp_max01_x;
		assign s_mn23x = cmp_min23_x;
		assign s_mx23x = cmp_max23_x;
		assign s_mn01y = cmp_min01_y;
		assign s_mx01y = cmp_max01_y;
		assign s_mn23y = cmp_min23_y;
		assign s_mx23y = cmp_max23_y;
`endif
		always @(posedge clk) begin
			if (wc10[0]) r_min01_x[HI +: 9] <= s_mn01x ? p_q0x[HI +: 9] : p_q1x[HI +: 9];
			if (wc10[1]) r_max01_x[HI +: 9] <= s_mx01x ? p_q0x[HI +: 9] : p_q1x[HI +: 9];
			if (wc10[2]) r_min23_x[HI +: 9] <= s_mn23x ? p_q2x[HI +: 9] : p_q3x[HI +: 9];
			if (wc10[3]) r_max23_x[HI +: 9] <= s_mx23x ? p_q2x[HI +: 9] : p_q3x[HI +: 9];
			if (wc10[4]) r_min01_y[HI +: 9] <= s_mn01y ? p_q0y[HI +: 9] : p_q1y[HI +: 9];
			if (wc10[5]) r_max01_y[HI +: 9] <= s_mx01y ? p_q0y[HI +: 9] : p_q1y[HI +: 9];
			if (wc10[6]) r_min23_y[HI +: 9] <= s_mn23y ? p_q2y[HI +: 9] : p_q3y[HI +: 9];
			if (wc10[7]) r_max23_y[HI +: 9] <= s_mx23y ? p_q2y[HI +: 9] : p_q3y[HI +: 9];
		end
	end
	endgenerate

	/* cnt == 11: fx, fy, pdx1..p0y, pdd, r_lx..r_my */
	wire we_c11_raw = c_act && (cnt == 6'd11);
	wire [2:0] c11_mid;
	generate
	for (gi = 0; gi < 3; gi = gi + 1) begin : g_c11_mid
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_c11m (.I0(we_c11_raw), .O(c11_mid[gi]));
`else
		assign c11_mid[gi] = we_c11_raw;
`endif
	end
	for (gs = 0; gs < 2; gs = gs + 1) begin : g_c11_fxy
		localparam integer HI = 12 * gs;
		wire [11:0] wc11;
		for (gi = 0; gi < 12; gi = gi + 1) begin : g_wc11_b
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wc (.I0(c11_mid[gs]), .O(wc11[gi]));
`else
			assign wc11[gi] = c11_mid[gs];
`endif
		end
		wire w1_0x, w1_1x, w1_0y, w1_1y, w2_0x, w2_1x, w2_0y, w2_1y;
		wire tl_s, tr_x, tr_y, lnx_s, lny_s;
		wire [23:0] pdx2_c = is_tri ? vdx2 : (is_line && !r_xmaj ? 24'sd256 : 24'sd0);
		wire [23:0] pdy2_c = is_tri ? vdy2 : (is_line && !r_xmaj ? 24'sd0   : 24'sd256);
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w10x (.I0(w1[0]),             .O(w1_0x));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w11x (.I0(w1[1]),             .O(w1_1x));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w10y (.I0(w1[0]),             .O(w1_0y));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w11y (.I0(w1[1]),             .O(w1_1y));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w20x (.I0(w2[0]),             .O(w2_0x));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w21x (.I0(w2[1]),             .O(w2_1x));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w20y (.I0(w2[0]),             .O(w2_0y));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w21y (.I0(w2[1]),             .O(w2_1y));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_tls  (.I0(is_tri || is_line), .O(tl_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_trx  (.I0(is_tri),            .O(tr_x));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_try  (.I0(is_tri),            .O(tr_y));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lnx  (.I0(is_line && !r_xmaj),.O(lnx_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lny  (.I0(is_line && !r_xmaj),.O(lny_s));
`else
		assign w1_0x = w1[0];
		assign w1_1x = w1[1];
		assign w1_0y = w1[0];
		assign w1_1y = w1[1];
		assign w2_0x = w2[0];
		assign w2_1x = w2[1];
		assign w2_0y = w2[0];
		assign w2_1y = w2[1];
		assign tl_s  = is_tri || is_line;
		assign tr_x  = is_tri;
		assign tr_y  = is_tri;
		assign lnx_s = is_line && !r_xmaj;
		assign lny_s = is_line && !r_xmaj;
`endif
		wire [23:0] c256 = 24'sd256;
		wire [11:0] pdx2_s = tr_x ? vdx2[HI +: 12] : (lnx_s ? c256[HI +: 12] : 12'd0);
		wire [11:0] pdy2_s = tr_y ? vdy2[HI +: 12] : (lny_s ? 12'd0          : c256[HI +: 12]);
		wire unused_pd2 = &{1'b0, pdx2_c, pdy2_c};
		always @(posedge clk) begin
			if (wc11[0])  fx_pk[0  + HI +: 12] <= r_c0x[HI +: 12];
			if (wc11[1])  fy_pk[0  + HI +: 12] <= r_c0y[HI +: 12];
			if (wc11[2])  fx_pk[24 + HI +: 12] <= w1_1x ? (w1_0x ? r_c3x[HI +: 12] : r_c2x[HI +: 12]) : r_c1x[HI +: 12];
			if (wc11[3])  fy_pk[24 + HI +: 12] <= w1_1y ? (w1_0y ? r_c3y[HI +: 12] : r_c2y[HI +: 12]) : r_c1y[HI +: 12];
			if (wc11[4])  fx_pk[48 + HI +: 12] <= w2_1x ? (w2_0x ? r_c3x[HI +: 12] : r_c2x[HI +: 12]) : r_c1x[HI +: 12];
			if (wc11[5])  fy_pk[48 + HI +: 12] <= w2_1y ? (w2_0y ? r_c3y[HI +: 12] : r_c2y[HI +: 12]) : r_c1y[HI +: 12];
			if (wc11[6])  pdx1[HI +: 12] <= tl_s ? r_ddx[HI +: 12] : c256[HI +: 12];
			if (wc11[7])  pdy1[HI +: 12] <= tl_s ? r_ddy[HI +: 12] : 12'd0;
			if (wc11[8])  pdx2[HI +: 12] <= pdx2_s;
			if (wc11[9])  pdy2[HI +: 12] <= pdy2_s;
			if (wc11[10]) p0x[HI +: 12]  <= ax[HI +: 12];
			if (wc11[11]) p0y[HI +: 12]  <= ay[HI +: 12];
		end
	end
	endgenerate

	/* pdd (3 x 16-bit slices, written at cnt == 11 or cnt == 15 && is_tri) */
	wire ddx_s_pdd;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ddxsp (.I0(r_ddx[23]), .O(ddx_s_pdd));
`else
	assign ddx_s_pdd = r_ddx[23];
`endif
	wire [47:0] ddx_pdd_ext = {{16{ddx_s_pdd}}, r_ddx, 8'd0};
	wire [47:0] pdd_c65536  = 48'sd65536;
	generate
	for (gs = 0; gs < 3; gs = gs + 1) begin : g_pdd_reg
		localparam integer HI = 16 * gs;
		wire we_pdd_r = c_act && (cnt == 6'd11);
		wire we_pdd_s, is_ln_s, xmaj_s;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wpdd (.I0(we_pdd_r), .O(we_pdd_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_piln (.I0(is_line),  .O(is_ln_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pxmj (.I0(r_xmaj),   .O(xmaj_s));
`else
		assign we_pdd_s = we_pdd_r;
		assign is_ln_s  = is_line;
		assign xmaj_s   = r_xmaj;
`endif
		(* keep = "true" *) wire [15:0] pdd_11_s = !is_ln_s ? pdd_c65536[HI +: 16] :
			(xmaj_s ? ddx_pdd_ext[HI +: 16] : ndy[HI +: 16]);
		always @(posedge clk) begin
			if (we_pdd_s)
				pdd[HI +: 16] <= pdd_11_s;
		end
	end
	endgenerate

	/* cnt == 11: r_lx, r_ly, r_mx, r_my (2 x 9-bit slices) */
	(* keep = "true" *) wire cmp_lx = r_min01_x < r_min23_x;
	(* keep = "true" *) wire cmp_ly = r_min01_y < r_min23_y;
	(* keep = "true" *) wire cmp_mx = r_max01_x > r_max23_x;
	(* keep = "true" *) wire cmp_my = r_max01_y > r_max23_y;
	generate
	for (gs = 0; gs < 2; gs = gs + 1) begin : g_lmxy_reg
		localparam integer HI = 9 * gs;
		wire [3:0] wl11;
		wire s_lx, s_ly, s_mx, s_my;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wl0 (.I0(c11_mid[2]), .O(wl11[0]));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wl1 (.I0(c11_mid[2]), .O(wl11[1]));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wl2 (.I0(c11_mid[2]), .O(wl11[2]));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wl3 (.I0(c11_mid[2]), .O(wl11[3]));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_slx (.I0(cmp_lx),     .O(s_lx));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sly (.I0(cmp_ly),     .O(s_ly));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_smx (.I0(cmp_mx),     .O(s_mx));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_smy (.I0(cmp_my),     .O(s_my));
`else
		assign wl11 = {4{c11_mid[2]}};
		assign s_lx = cmp_lx;
		assign s_ly = cmp_ly;
		assign s_mx = cmp_mx;
		assign s_my = cmp_my;
`endif
		always @(posedge clk) begin
			if (wl11[0]) r_lx[HI +: 9] <= s_lx ? r_min01_x[HI +: 9] : r_min23_x[HI +: 9];
			if (wl11[1]) r_ly[HI +: 9] <= s_ly ? r_min01_y[HI +: 9] : r_min23_y[HI +: 9];
			if (wl11[2]) r_mx[HI +: 9] <= s_mx ? r_max01_x[HI +: 9] : r_max23_x[HI +: 9];
			if (wl11[3]) r_my[HI +: 9] <= s_my ? r_max01_y[HI +: 9] : r_max23_y[HI +: 9];
		end
	end
	endgenerate

	/* cnt == 12, 13, 14/17: r_mx1..r_win_max_y, r_clx..r_cmy, bx0..by1 (2 x 9-bit slices) */
	wire we_c12_raw = c_act && (cnt == 6'd12);
	wire we_c13_raw = c_act && (cnt == 6'd13);
	wire we_bx_raw  = c_act && ((cnt == 6'd14) || (cnt == 6'd17 && empty));
	wire is_c14_raw = (cnt == 6'd14);
	generate
	for (gs = 0; gs < 2; gs = gs + 1) begin : g_bbox_pipe
		localparam integer HI = 9 * gs;
		wire [5:0] wc12;
		wire [3:0] wc13, wbx, sc14;
		wire sw_mnx, sw_mxx, sw_mny, sw_mxy;
		wire sl_x, sh_x, sl_y, sh_y;
		for (gi = 0; gi < 6; gi = gi + 1) begin : g_wc12_b
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w12 (.I0(we_c12_raw), .O(wc12[gi]));
`else
			assign wc12[gi] = we_c12_raw;
`endif
		end
		for (gi = 0; gi < 4; gi = gi + 1) begin : g_wc13_b
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w13 (.I0(we_c13_raw), .O(wc13[gi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wbx (.I0(we_bx_raw),  .O(wbx[gi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_s14 (.I0(is_c14_raw), .O(sc14[gi]));
`else
			assign wc13[gi] = we_c13_raw;
			assign wbx[gi]  = we_bx_raw;
			assign sc14[gi] = is_c14_raw;
`endif
		end
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wmnx (.I0(win_min_x_sel), .O(sw_mnx));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wmxx (.I0(win_max_x_sel), .O(sw_mxx));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wmny (.I0(win_min_y_sel), .O(sw_mny));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wmxy (.I0(win_max_y_sel), .O(sw_mxy));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_slx  (.I0(lo_scis_x_sel), .O(sl_x));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_shx  (.I0(hi_scis_x_sel), .O(sh_x));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sly  (.I0(lo_scis_y_sel), .O(sl_y));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_shy  (.I0(hi_scis_y_sel), .O(sh_y));
`else
		assign sw_mnx = win_min_x_sel;
		assign sw_mxx = win_max_x_sel;
		assign sw_mny = win_min_y_sel;
		assign sw_mxy = win_max_y_sel;
		assign sl_x   = lo_scis_x_sel;
		assign sh_x   = hi_scis_x_sel;
		assign sl_y   = lo_scis_y_sel;
		assign sh_y   = hi_scis_y_sel;
`endif
		always @(posedge clk) begin
			if (wc12[0]) r_mx1[HI +: 9]       <= m_x1[HI +: 9];
			if (wc12[1]) r_my1[HI +: 9]       <= m_y1[HI +: 9];
			if (wc12[2]) r_win_min_x[HI +: 9] <= sw_mnx ? rx0[HI +: 9] : r_scis_rt_min_x[HI +: 9];
			if (wc12[3]) r_win_max_x[HI +: 9] <= sw_mxx ? rx1[HI +: 9] : r_scis_rt_max_x[HI +: 9];
			if (wc12[4]) r_win_min_y[HI +: 9] <= sw_mny ? ry0[HI +: 9] : r_scis_rt_min_y[HI +: 9];
			if (wc12[5]) r_win_max_y[HI +: 9] <= sw_mxy ? ry1[HI +: 9] : r_scis_rt_max_y[HI +: 9];
			if (wc13[0]) r_clx[HI +: 9]       <= sl_x ? r_win_min_x[HI +: 9] : r_lx[HI +: 9];
			if (wc13[1]) r_cly[HI +: 9]       <= sl_y ? r_win_min_y[HI +: 9] : r_ly[HI +: 9];
			if (wc13[2]) r_cmx[HI +: 9]       <= sh_x ? r_win_max_x[HI +: 9] : r_mx1[HI +: 9];
			if (wc13[3]) r_cmy[HI +: 9]       <= sh_y ? r_win_max_y[HI +: 9] : r_my1[HI +: 9];
			if (wbx[0])  bx0[HI +: 9]         <= sc14[0] ? r_clx[HI +: 9] : 9'd0;
			if (wbx[1])  by0[HI +: 9]         <= sc14[1] ? r_cly[HI +: 9] : 9'd0;
			if (wbx[2])  bx1[HI +: 9]         <= sc14[2] ? r_cmx[HI +: 9] : 9'd0;
			if (wbx[3])  by1[HI +: 9]         <= sc14[3] ? r_cmy[HI +: 9] : 9'd0;
		end
	end
	endgenerate

	/* dd (3 x 16-bit slices), r_dx1_dy2, r_cox_d, r_coy_d, acc, r_cabs, ca, r_cn (3 x 16-bit slices) */
	wire we_dx1dy2_raw = c_act && (cnt == 6'd14);
	wire we_dd_raw     = c_act && (cnt == 6'd15);
	wire we_cox_raw    = c_act && (cnt == 6'd16);
	wire we_coy_raw    = c_act && (cnt == 6'd17);
	wire we_acc_raw    = c_act && (cnt >= 6'd19 && cnt <= 6'd24) && !ce_p[0];
	wire we_cabs_raw   = c_act && (cnt >= 6'd23 && cnt <= 6'd29);
	wire we_ca_raw     = c_act && (cnt >= 6'd24 && cnt <= 6'd30);
	wire we_cn_raw     = c_act && (cnt >= 6'd25 && cnt <= 6'd31);
	generate
	for (gs = 0; gs < 3; gs = gs + 1) begin : g_48b_regs
		localparam integer HI = 16 * gs;
		wire wdx1dy2, wdd, wcox, wcoy, wacc, wcabs, wca, wcn;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wdx1  (.I0(we_dx1dy2_raw), .O(wdx1dy2));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wdd   (.I0(we_dd_raw),     .O(wdd));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wcox  (.I0(we_cox_raw),    .O(wcox));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wcoy  (.I0(we_coy_raw),    .O(wcoy));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wacc  (.I0(we_acc_raw),    .O(wacc));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wcabs (.I0(we_cabs_raw),   .O(wcabs));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wca   (.I0(we_ca_raw),     .O(wca));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wcn   (.I0(we_cn_raw),     .O(wcn));
`else
		assign wdx1dy2 = we_dx1dy2_raw;
		assign wdd   = we_dd_raw;
		assign wcox  = we_cox_raw;
		assign wcoy  = we_coy_raw;
		assign wacc  = we_acc_raw;
		assign wcabs = we_cabs_raw;
		assign wca   = we_ca_raw;
		assign wcn   = we_cn_raw;
`endif
		always @(posedge clk) begin
			if (wdx1dy2) r_dx1_dy2[HI +: 16] <= mp[HI +: 16];
			if (wdd)     dd[HI +: 16]        <= dd_n[HI +: 16];
			if (wcox)    r_cox_d[HI +: 16]   <= cox_d[HI +: 16];
			if (wcoy)    r_coy_d[HI +: 16]   <= coy_d[HI +: 16];
			if (wacc)    acc[HI +: 16]       <= acc_n[HI +: 16];
			if (wcabs)   r_cabs[HI +: 16]    <= cabs[HI +: 16];
			if (wca) begin
				ca[HI +: 16]   <= r_cabs[HI +: 16];
				r_cabs_nz[gs]  <= (r_cabs[HI +: 16] != 16'd0);
			end
			if (wcn) begin
				r_cn[HI +: 16] <= cn[HI +: 16];
				if (gs == 0) r_cn_stk0 <= (cn[15:0] != 16'd0);
				if (gs == 1) begin
					r_cn_guard <= cn[23];
					r_cn_stk1  <= (cn[22:16] != 7'd0);
				end
			end
		end
	end
	endgenerate
	always @(posedge clk) begin
		if (we_acc_raw) acc[49:48] <= 2'b00;
	end

	/* eA, eB, oX, oY, eE (sliced <= 16-bit write enables) */
	wire we_eab_raw = c_act && ((cnt == 6'd16) || (cnt == 6'd17 && empty));
	wire is_c16_eab = (cnt == 6'd16);
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_edge_regs
		for (gs = 0; gs < 2; gs = gs + 1) begin : g_eab_s
			localparam integer HI = 12 * gs;
			localparam integer O_LO = (gs == 0) ? 0  : 13;
			localparam integer O_W  = (gs == 0) ? 13 : 12;
			wire wea, web, sc16a, sc16b, wox, woy;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wea (.I0(we_eab_raw), .O(wea));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_web (.I0(we_eab_raw), .O(web));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sa  (.I0(is_c16_eab), .O(sc16a));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sb  (.I0(is_c16_eab), .O(sc16b));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wox (.I0(we_cox_raw), .O(wox));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_woy (.I0(we_cox_raw), .O(woy));
`else
			assign wea   = we_eab_raw;
			assign web   = we_eab_raw;
			assign sc16a = is_c16_eab;
			assign sc16b = is_c16_eab;
			assign wox   = we_cox_raw;
			assign woy   = we_cox_raw;
`endif
			always @(posedge clk) begin
				if (wea) eA_pk[24 * ge + HI +: 12]   <= sc16a ? eA_n[ge][HI +: 12] : 12'd0;
				if (web) eB_pk[24 * ge + HI +: 12]   <= sc16b ? eB_n[ge][HI +: 12] : 12'd0;
				if (wox) oX_pk[25 * ge + O_LO +: O_W] <= oX_n[ge][O_LO +: O_W];
				if (woy) oY_pk[25 * ge + O_LO +: O_W] <= oY_n[ge][O_LO +: O_W];
			end
		end
		for (gs = 0; gs < 3; gs = gs + 1) begin : g_ee_s
			localparam integer HI = 16 * gs;
			wire wee_raw = !rst_sync && (run && (cnt >= 6'd19 && cnt <= 6'd24) && ce_p[0] && (ek == ge[1:0]));
			wire wee_s;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wee (.I0(wee_raw), .O(wee_s));
`else
			assign wee_s = wee_raw;
`endif
			always @(posedge clk) begin
				if (wee_s)
					eE_pk[48 * ge + HI +: 16] <= eE_n[HI +: 16];
			end
		end
	end
	endgenerate

	/* r_wd (2 x 16-bit slices) */
	wire we_wd_raw = c_act && (cnt >= 6'd26 && cnt <= 6'd32);
	wire we_wd_lo, we_wd_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wwdl (.I0(we_wd_raw), .O(we_wd_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wwdh (.I0(we_wd_raw), .O(we_wd_hi));
`else
	assign we_wd_lo = we_wd_raw;
	assign we_wd_hi = we_wd_raw;
`endif
	always @(posedge clk) begin
		if (we_wd_lo) r_wd[15:0]  <= c_out[15:0];
		if (we_wd_hi) r_wd[31:16] <= c_out[31:16];
	end

	/* Pre-computed dd == 0 in 3 x 16-bit chunks for empty check */
	wire [2:0] dd_nz = {dd[47:32] != 16'd0, dd[31:16] != 16'd0, dd[15:0] != 16'd0};

	wire xmaj_hx, xmaj_hy;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xmhx (.I0(xmaj), .O(xmaj_hx));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xmhy (.I0(xmaj), .O(xmaj_hy));
`else
	assign xmaj_hx = xmaj;
	assign xmaj_hy = xmaj;
`endif

	wire we_h_raw = run && (cnt == 6'd8);
	wire we_hx_lo, we_hx_hi, we_hy_lo, we_hy_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_whxl (.I0(we_h_raw), .O(we_hx_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_whxh (.I0(we_h_raw), .O(we_hx_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_whyl (.I0(we_h_raw), .O(we_hy_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_whyh (.I0(we_h_raw), .O(we_hy_hi));
`else
	assign we_hx_lo = we_h_raw;
	assign we_hx_hi = we_h_raw;
	assign we_hy_lo = we_h_raw;
	assign we_hy_hi = we_h_raw;
`endif
	wire [23:0] hx_next = is_line_hx ? (xmaj_hx ? 24'sd0 : half_line_w) : half_point_s;
	wire [23:0] hy_next = is_line_hy ? (xmaj_hy ? half_line_w : 24'sd0) : half_point_s;

	always @(posedge clk) begin
		if (rst_sync) begin
			r_xmaj <= 1'b0;
		end else if (we_h_raw) begin
			r_xmaj <= xmaj;
		end
		if (we_hx_lo) r_hx[11:0]  <= hx_next[11:0];
		if (we_hx_hi) r_hx[23:12] <= hx_next[23:12];
		if (we_hy_lo) r_hy[11:0]  <= hy_next[11:0];
		if (we_hy_hi) r_hy[23:12] <= hy_next[23:12];
	end

	always @(posedge clk) begin
		if (rst_sync) begin
			front <= 1'b0;
			empty <= 1'b0;
		end else if (run && (cnt == 6'd16)) begin
			front <= !is_tri || (cull[2] ? ccw : !ccw);
			empty <= (dd_nz == 3'b000) || (is_tri && cull[0] && (cull[2] ? ccw : !ccw)) ||
				(is_tri && cull[1] && !(cull[2] ? ccw : !ccw)) || bx1 <= bx0 || by1 <= by0;
		end
	end

	reg [47:0] ci_next;
	reg [4:0] ci_sh_next;
	reg ci_sgn_next;
	always @(*) begin
		case (cnt)
		6'd22: begin ci_next = pdx1_ext; ci_sh_next = 5'd8;  ci_sgn_next = pdx1[23]; end
		6'd23: begin ci_next = pdy1_ext; ci_sh_next = 5'd8;  ci_sgn_next = pdy1[23]; end
		6'd24: begin ci_next = pdx2_ext; ci_sh_next = 5'd8;  ci_sgn_next = pdx2[23]; end
		6'd25: begin ci_next = pdy2_ext; ci_sh_next = 5'd8;  ci_sgn_next = pdy2[23]; end
		6'd26: begin ci_next = is_tri ? dd : pdd; ci_sh_next = 5'd16; ci_sgn_next = is_tri ? dd[47] : pdd[47]; end
		6'd27: begin ci_next = r_cox_d;  ci_sh_next = 5'd8;  ci_sgn_next = r_cox_d[47]; end
		default: begin ci_next = r_coy_d; ci_sh_next = 5'd8; ci_sgn_next = r_coy_d[47]; end
		endcase
	end

	wire we_ci_raw = run && (cnt >= 6'd22 && cnt <= 6'd28);
	wire we_ci_s0, we_ci_s1, we_ci_s2, we_ci_ctrl;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wci0 (.I0(we_ci_raw), .O(we_ci_s0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wci1 (.I0(we_ci_raw), .O(we_ci_s1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wci2 (.I0(we_ci_raw), .O(we_ci_s2));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wcit (.I0(we_ci_raw), .O(we_ci_ctrl));
`else
	assign we_ci_s0 = we_ci_raw;
	assign we_ci_s1 = we_ci_raw;
	assign we_ci_s2 = we_ci_raw;
	assign we_ci_ctrl = we_ci_raw;
`endif

	always @(posedge clk) begin
		if (we_ci_s0) r_ci[15:0]  <= ci_next[15:0];
		if (we_ci_s1) r_ci[31:16] <= ci_next[31:16];
		if (we_ci_s2) r_ci[47:32] <= ci_next[47:32];
		if (we_ci_ctrl) begin
			r_ci_sh  <= ci_sh_next;
			r_ci_sgn <= ci_sgn_next;
		end
	end

	always @(posedge clk) begin
		r_we <= 1'b0;
		if (rst_sync) begin
			r_cs <= 1'b0;
			r_csh <= 5'd0;
			cs <= 1'b0;
			clz <= 6'd0;
			csh <= 5'd0;
			r_cs2 <= 1'b0;
			r_czs <= 9'd0;
			r_ca_zero <= 1'b1;
			r_wa <= 7'd0;
		end else if (run) begin
			/* 23-29: int2f stage 1; 24-30: stage 2; 25-31: stage 3; 26-32: stage 4 into fp registers 40-46 */
			if (cnt >= 6'd23 && cnt <= 6'd29) begin
				r_cs <= r_ci_sgn;
				r_csh <= r_ci_sh;
			end
			if (cnt >= 6'd24 && cnt <= 6'd30) begin
				cs <= r_cs;
				clz <= cl;
				csh <= r_csh;
			end
			if (cnt >= 6'd25 && cnt <= 6'd31) begin
				r_cs2 <= cs;
				r_czs <= czs;
				r_ca_zero <= (r_cabs_nz == 3'b000);
			end
			if (cnt >= 6'd26 && cnt <= 6'd32) begin
				r_we <= 1'b1;
				r_wa <= wa_n;
			end
		end
	end

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire [7:0] start_leaf;
	LUT1 #(.INIT(2'h2)) u_st_smin0 (.I0(start), .O(start_leaf[0]));
	LUT1 #(.INIT(2'h2)) u_st_smin1 (.I0(start), .O(start_leaf[1]));
	LUT1 #(.INIT(2'h2)) u_st_smax0 (.I0(start), .O(start_leaf[2]));
	LUT1 #(.INIT(2'h2)) u_st_smax1 (.I0(start), .O(start_leaf[3]));
	LUT1 #(.INIT(2'h2)) u_st_rts0  (.I0(start), .O(start_leaf[4]));
	LUT1 #(.INIT(2'h2)) u_st_rts1  (.I0(start), .O(start_leaf[5]));
	LUT1 #(.INIT(2'h2)) u_st_ctrl0 (.I0(start), .O(start_leaf[6]));
	LUT1 #(.INIT(2'h2)) u_st_ctrl1 (.I0(start), .O(start_leaf[7]));

	always @(posedge clk) begin
		if (rst_sync) begin
			r_smin <= 32'd0;
		end else if (start_leaf[0] || start_leaf[1]) begin
			if (start_leaf[0]) r_smin[15:0]  <= smin[15:0];
			if (start_leaf[1]) r_smin[31:16] <= smin[31:16];
		end
	end
	always @(posedge clk) begin
		if (rst_sync) begin
			r_smax <= 32'd0;
		end else if (start_leaf[2] || start_leaf[3]) begin
			if (start_leaf[2]) r_smax[15:0]  <= smax[15:0];
			if (start_leaf[3]) r_smax[31:16] <= smax[31:16];
		end
	end
	always @(posedge clk) begin
		if (rst_sync) begin
			r_rts <= 32'd0;
		end else if (start_leaf[4] || start_leaf[5]) begin
			if (start_leaf[4]) r_rts[15:0]  <= rts[15:0];
			if (start_leaf[5]) r_rts[31:16] <= rts[31:16];
		end
	end
`endif

	always @(posedge clk) begin
		done <= 1'b0;
		if (rst_sync) begin
			run <= 1'b0;
			cnt <= 6'd0;
			r_snap_v <= 1'b0;
			r_snap_sign <= 1'b0;
			r_snap_ovf <= 1'b0;
			r_snap_zero_out <= 1'b0;
			r_snap_tsn <= 4'd0;
			r_scis_en <= 1'b0;
`ifndef SYNTH_KINTEX7
			r_smin <= 32'd0;
			r_smax <= 32'd0;
			r_rts  <= 32'd0;
`endif
		end else if (
`ifdef SYNTH_KINTEX7
			start_leaf[6]
`else
			start
`endif
		) begin
			run <= 1'b1;
			cnt <= 6'd0;
			r_scis_en <= (smax != 32'd0);
`ifndef SYNTH_KINTEX7
			r_smin <= smin;
			r_smax <= smax;
			r_rts  <= rts;
`endif
			r_snap_v <= 1'b0;
			md <= mode;
			r_ra <= 7'd31;
		end else if (run) begin
			cnt <= cnt1;
			/* 0-9 read, 1-10 snap stage 1, 2-11 snap stage 2 */
			if (cnt < 6'd9)
				r_ra <= rrv;
			r_snap_v <= (cnt >= 6'd1 && cnt <= 6'd10);
			if (cnt >= 6'd1 && cnt <= 6'd10) begin
				r_snap_sign <= r_rd[31];
				r_snap_ovf <= (snap_exp >= 8'd141) || ((snap_exp == 8'd140) && (&snap_mant[22:1]));
				r_snap_zero_out <= (snap_exp == 8'hFF && snap_mant != 23'd0) || (snap_exp < 8'd118);
				r_snap_tsn <= tsn;
			end
			if (cnt == 6'd17) begin
				for (k = 0; k < 3; k = k + 1)
					tl[k] <= eA[k] > 24'sd0 || (eA[k] == 24'sd0 && eB[k] > 24'sd0);
				if (empty) begin
					run <= 1'b0;
					done <= 1'b1;
				end
			end
			if (cnt == 6'd32) begin
				run <= 1'b0;
				done <= 1'b1;
			end
		end
	end

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire [5:0] edges_sgn_leaf;
	LUT1 #(.INIT(2'b10)) u_esgn0 (.I0(eA[0][23]), .O(edges_sgn_leaf[0]));
	LUT1 #(.INIT(2'b10)) u_esgn1 (.I0(eB[0][23]), .O(edges_sgn_leaf[1]));
	LUT1 #(.INIT(2'b10)) u_esgn2 (.I0(eA[1][23]), .O(edges_sgn_leaf[2]));
	LUT1 #(.INIT(2'b10)) u_esgn3 (.I0(eB[1][23]), .O(edges_sgn_leaf[3]));
	LUT1 #(.INIT(2'b10)) u_esgn4 (.I0(eA[2][23]), .O(edges_sgn_leaf[4]));
	LUT1 #(.INIT(2'b10)) u_esgn5 (.I0(eB[2][23]), .O(edges_sgn_leaf[5]));
	assign edges[0 +: 23]   = eA[0][22:0];
	assign edges[23]        = edges_sgn_leaf[0];
	assign edges[24 +: 23]  = eB[0][22:0];
	assign edges[47]        = edges_sgn_leaf[1];
	assign edges[48 +: 48]  = eE[0];
	assign edges[96 +: 23]  = eA[1][22:0];
	assign edges[119]       = edges_sgn_leaf[2];
	assign edges[120 +: 23] = eB[1][22:0];
	assign edges[143]       = edges_sgn_leaf[3];
	assign edges[144 +: 48] = eE[1];
	assign edges[192 +: 23] = eA[2][22:0];
	assign edges[215]       = edges_sgn_leaf[4];
	assign edges[216 +: 23] = eB[2][22:0];
	assign edges[239]       = edges_sgn_leaf[5];
	assign edges[240 +: 48] = eE[2];
`else
	genvar g;
	generate
	for (g = 0; g < 3; g = g + 1) begin : g_edge
		assign edges[96 * g +: 96] = {eE[g], eB[g], eA[g]};
	end
	endgenerate
`endif
	assign bbox = {by1[15:0], bx1[15:0], by0[15:0], bx0[15:0]};

	wire unused_ok = &{1'b0, carry_unused, cn_sh_unused,
		acc[49:48], ce0[8], ce1[8], bx0[17:16], by0[17:16], bx1[17:16],
		by1[17:16], adx[23], ady[23], q0x[7:0], q1x[7:0],
		q2x[7:0], q3x[7:0], q0y[7:0], q1y[7:0], q2y[7:0], q3y[7:0], s6[7:0], s7[7:0],
		s8[7:0], s9[7:0], eff_line_w[0], eff_point_s[0]};
endmodule

`default_nettype wire
