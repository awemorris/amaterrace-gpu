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
	reg run;
	reg [5:0] cnt;
	reg [3:0] md;
	wire [1:0] kind = md[1:0];
	wire is_tri = kind[1] || md[3];
	integer k;

	wire [23:0] snap;
	wire [48:0] carry_unused;	/* the adders' carries */
	am_fp_f2fix #(
		.W(24),
		.F(8),
		.SIGNED(1),
		.ROUND(1),
		.SATURATE(1),
		.SAT_BITS(22)
	) u_snap (.f(r_rd), .q(snap));

	/* The registers read, in order: 31 32 34 35 37 38, then 76-79: register i + 1 is
	 * 31 + i + i / 2 below 6, else 70 + i. */
	wire [3:0] rri;
	wire [6:0] rrt, rrv;
	am_add #(.W(4)) u_rri (.a(cnt[3:0]), .b(4'd0), .ci(1'b1), .s(rri), .co(carry_unused[0]));
	am_add #(.W(7)) u_rrt (.a({3'd0, rri}), .b({4'd0, rri[3:1]}), .ci(1'b0), .s(rrt),
		.co(carry_unused[1]));
	am_add #(.W(7)) u_rrv (.a(rri < 4'd6 ? rrt : {3'd0, rri}), .b(rri < 4'd6 ? 7'd31 : 7'd70), .ci(1'b0),
		.s(rrv), .co(carry_unused[2]));

	reg signed [23:0] sv [0:9];	/* snapped: x0 y0 x1 y1 x2 y2 rx0 rx1 ry0 ry1 */
	wire signed [23:0] ax = sv[0], ay = sv[1], bx = sv[2], by = sv[3];
	wire signed [23:0] ddx, ddy;
	wire [23:0] adx, ady;
	am_sub #(.W(24)) u_ddx (.a(bx), .b(ax), .bi(1'b0), .d(ddx), .bo(carry_unused[3]));
	am_sub #(.W(24)) u_ddy (.a(by), .b(ay), .bi(1'b0), .d(ddy), .bo(carry_unused[4]));
	am_addsub #(.W(24)) u_adx (.a(24'd0), .b(ddx), .sub(ddx[23]), .s(adx), .co(carry_unused[5]));
	am_addsub #(.W(24)) u_ady (.a(24'd0), .b(ddy), .sub(ddy[23]), .s(ady), .co(carry_unused[6]));
`ifdef MUT_LINE_MAJOR
	wire xmaj = adx > ady;	/* the TB's mutation check: y-major when equal */
`else
	wire xmaj = adx >= ady;
`endif
	wire [15:0] eff_line_w = line_width == 16'd0 ? 16'h0100 : line_width;
	wire [15:0] eff_point_s = point_size == 16'd0 ? 16'h0100 : point_size;
	wire signed [23:0] half_line_w = {9'd0, eff_line_w[15:1]};
	wire signed [23:0] half_point_s = {9'd0, eff_point_s[15:1]};
	wire signed [23:0] ox = xmaj ? 24'sd0 : half_line_w;
	wire signed [23:0] oy = xmaj ? half_line_w : 24'sd0;

	/* The corners: a triangle's vertices (and v0 again); a line's a-, a+,
	 * b-, b+; a point's p--, p+-, p++, p-+.  The walked triangle is corners
	 * (0, w1, w2). */
	wire is_line = !is_tri && kind == 2'd1;
	wire signed [23:0] vx2 = sv[4], vy2 = sv[5];
	wire signed [23:0] hx = is_line ? ox : half_point_s;
	wire signed [23:0] hy = is_line ? oy : half_point_s;
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
	wire signed [23:0] c0x = is_tri ? ax : axm;
	wire signed [23:0] c0y = is_tri ? ay : aym;
	wire signed [23:0] c1x = is_tri ? bx : axp;
	wire signed [23:0] c1y = is_tri ? by : is_line ? ayp : aym;
	wire signed [23:0] c2x = is_tri ? vx2 : is_line ? bxm : axp;
	wire signed [23:0] c2y = is_tri ? vy2 : is_line ? bym : ayp;
	wire signed [23:0] c3x = is_tri ? ax : is_line ? bxp : axm;
	wire signed [23:0] c3y = is_tri ? ay : is_line ? byp : ayp;
	wire [1:0] w1 = is_tri ? 2'd1 : is_line ? (md[2] ? 2'd3 : 2'd2) : (md[2] ? 2'd2 : 2'd1);
	wire [1:0] w2 = is_tri ? 2'd2 : is_line ? (md[2] ? 2'd1 : 2'd3) : (md[2] ? 2'd3 : 2'd2);

	/* The walked triangle, the four corners (bbox) and the plane triangle. */
	reg signed [23:0] fx [0:2];
	reg signed [23:0] fy [0:2];
	reg signed [23:0] pdx1, pdy1, pdx2, pdy2, p0x, p0y;
	reg signed [47:0] pdd;	/* the plane triangle's D (lines and points) */
	wire signed [23:0] fx0 = fx[0], fx1 = fx[1], fx2 = fx[2];
	wire signed [23:0] fy0 = fy[0], fy1 = fy[1], fy2 = fy[2];
	wire signed [23:0] dx1, dy1, dx2, dy2;
	am_sub #(.W(24)) u_dx1 (.a(fx1), .b(fx0), .bi(1'b0), .d(dx1), .bo(carry_unused[15]));
	am_sub #(.W(24)) u_dy1 (.a(fy1), .b(fy0), .bi(1'b0), .d(dy1), .bo(carry_unused[16]));
	am_sub #(.W(24)) u_dx2 (.a(fx2), .b(fx0), .bi(1'b0), .d(dx2), .bo(carry_unused[17]));
	am_sub #(.W(24)) u_dy2 (.a(fy2), .b(fy0), .bi(1'b0), .d(dy2), .bo(carry_unused[18]));

	/* The multiplier: operands registered, product one cycle later. */
	reg signed [24:0] ma, mb;
	reg signed [49:0] mp;
	wire [49:0] mpn;
	am_mul #(.AW(25), .BW(25), .SIGNED(1)) u_mp (.clk(clk), .en(1'b1), .a(ma), .b(mb), .p(mpn));
	always @(posedge clk)
		mp <= mpn;

	/* bbox: the corners' pixels, max exclusive, ∩ scissor (when SCISSOR_MAX
	 * != 0) ∩ the viewport's rectangle (vprect, not raw) ∩ RT. */
	function signed [17:0] pix;
		input [15:0] v;	/* a 15.8 value's integer bits */
		pix = {{2{v[15]}}, v};
	endfunction
	wire signed [23:0] q0x = c0x, q1x = c1x, q2x = c2x, q3x = c3x;
	wire signed [23:0] q0y = c0y, q1y = c1y, q2y = c2y, q3y = c3y;
	wire signed [23:0] s6 = sv[6], s7 = sv[7], s8 = sv[8], s9 = sv[9];
	wire signed [17:0] rx0 = pix(s6[23:8]), rx1 = pix(s7[23:8]);
	wire signed [17:0] ry0 = pix(s8[23:8]), ry1 = pix(s9[23:8]);
	reg signed [17:0] lo_x, lo_y, hi_x, hi_y, t_x, t_y, l_x, l_y, m_x, m_y;
	reg signed [17:0] bx0, by0, bx1, by1;
	always @(*) begin
		l_x = pix(q0x[23:8]);
		m_x = l_x;
		l_y = pix(q0y[23:8]);
		m_y = l_y;
		for (k = 1; k < 4; k = k + 1) begin
			t_x = pix(k == 1 ? q1x[23:8] : k == 2 ? q2x[23:8] : q3x[23:8]);
			t_y = pix(k == 1 ? q1y[23:8] : k == 2 ? q2y[23:8] : q3y[23:8]);
			if (t_x < l_x)
				l_x = t_x;
			if (t_x > m_x)
				m_x = t_x;
			if (t_y < l_y)
				l_y = t_y;
			if (t_y > m_y)
				m_y = t_y;
		end
	end
	wire [17:0] m_x1, m_y1;	/* the largest pixel + 1 */
	am_add #(.W(18)) u_m_x1 (.a(m_x), .b(18'd0), .ci(1'b1), .s(m_x1), .co(carry_unused[19]));
	am_add #(.W(18)) u_m_y1 (.a(m_y), .b(18'd0), .ci(1'b1), .s(m_y1), .co(carry_unused[20]));
	always @(*) begin
		lo_x = l_x;
		lo_y = l_y;
		hi_x = m_x1;
		hi_y = m_y1;
		if (smax != 32'd0) begin
			if (lo_x < $signed({2'b00, smin[15:0]}))
				lo_x = {2'b00, smin[15:0]};
			if (lo_y < $signed({2'b00, smin[31:16]}))
				lo_y = {2'b00, smin[31:16]};
			if (hi_x > $signed({2'b00, smax[15:0]}))
				hi_x = {2'b00, smax[15:0]};
			if (hi_y > $signed({2'b00, smax[31:16]}))
				hi_y = {2'b00, smax[31:16]};
		end
		if (vprect && !md[3]) begin
			if (lo_x < rx0)
				lo_x = rx0;
			if (hi_x > rx1)
				hi_x = rx1;
			if (lo_y < ry0)
				lo_y = ry0;
			if (hi_y > ry1)
				hi_y = ry1;
		end
		if (lo_x < 18'sd0)
			lo_x = 18'sd0;
		if (lo_y < 18'sd0)
			lo_y = 18'sd0;
		if (hi_x > $signed({2'b00, rts[15:0]}))
			hi_x = {2'b00, rts[15:0]};
		if (hi_y > $signed({2'b00, rts[31:16]}))
			hi_y = {2'b00, rts[31:16]};
	end

	/* The sample at the bbox origin, in subpixels. */
	wire signed [24:0] sx = {bx0[16:0], 8'd128};
	wire signed [24:0] sy = {by0[16:0], 8'd128};

	reg signed [47:0] dd;	/* D = dx1 dy2 - dx2 dy1 (subpixel^2); area2 = -D */
	reg ccw;
	reg signed [23:0] eA [0:2];
	reg signed [23:0] eB [0:2];
	reg signed [24:0] oX [0:2];
	reg signed [24:0] oY [0:2];
	reg [2:0] tl;
	reg [47:0] eE [0:2];
	reg [49:0] acc;

	/* Vertex of the ordered (area2 > 0) triangle's corner i: (0,1,2) or (0,2,1). */
	function [1:0] vtx;
		input [1:0] i;
		input c;
		vtx = c ? i : (i == 2'd0 ? 2'd0 : 2'd3 - i);
	endfunction

	/* int2f: a 48-bit signed integer times 2^-sh to fp32, two stages. */
	reg [47:0] ca;
	reg cs;
	reg [5:0] clz;
	reg [4:0] csh;
	reg [47:0] ci;	/* the input of stage A */
	reg [4:0] ci_sh;
	wire [47:0] cabs;
	reg [5:0] cl;
	am_addsub #(.W(48)) u_cabs (.a(48'd0), .b(ci), .sub(ci[47]), .s(cabs), .co(carry_unused[21]));
	always @(*) begin
		cl = 6'd48;
		for (k = 0; k < 48; k = k + 1)
			if (cabs[k])
				cl = 6'd47 - k[5:0];
	end
	/* normalised, RNE; the exponent 174 - clz - csh (+ 1 when the rounding carries) */
	wire [47:0] cn;
	wire [24:0] cm;
	wire [8:0] czs, ce;
	am_shift #(.W(48), .SW(6)) u_cn (.a(ca), .amt(clz), .left(1'b1), .arith(1'b0), .y(cn));
	am_add #(.W(25)) u_cm (.a({1'b0, cn[47:24]}), .b(25'd0), .ci(cn[23] && (cn[22:0] != 23'd0 || cn[24])),
		.s(cm), .co(carry_unused[22]));
	am_add #(.W(9)) u_czs (.a({3'd0, clz}), .b({4'd0, csh}), .ci(1'b0), .s(czs),
		.co(carry_unused[23]));
	am_sub #(.W(9)) u_ce (.a(cm[24] ? 9'd175 : 9'd174), .b(czs), .bi(1'b0), .d(ce),
		.bo(carry_unused[24]));
	wire [31:0] c_out = ca == 48'd0 ? 32'd0 : {cs, ce[7:0], cm[24] ? cm[23:1] : cm[22:0]};

	/* Steps 25-31 convert DX1 DY1 DX2 DY2 DF OX OY of the plane triangle (OX, OY:
	 * one subtracter). */
	wire [47:0] co_d;
	am_sub #(.W(48)) u_co_d (.a(cnt == 6'd30 ? {{23{sx[24]}}, sx} : {{23{sy[24]}}, sy}),
		.b(cnt == 6'd30 ? {{24{p0x[23]}}, p0x} : {{24{p0y[23]}}, p0y}), .bi(1'b0), .d(co_d),
		.bo(carry_unused[25]));
	always @(*) begin
		case (cnt)
		6'd25: begin ci = {{24{pdx1[23]}}, pdx1}; ci_sh = 5'd8; end
		6'd26: begin ci = {{24{pdy1[23]}}, pdy1}; ci_sh = 5'd8; end
		6'd27: begin ci = {{24{pdx2[23]}}, pdx2}; ci_sh = 5'd8; end
		6'd28: begin ci = {{24{pdy2[23]}}, pdy2}; ci_sh = 5'd8; end
		6'd29: begin ci = pdd; ci_sh = 5'd16; end
		default: begin ci = co_d; ci_sh = 5'd8; end
		endcase
	end

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
	am_sub #(.W(24)) u_vdx2 (.a(vx2), .b(ax), .bi(1'b0), .d(vdx2), .bo(carry_unused[31]));
	am_sub #(.W(24)) u_vdy2 (.a(vy2), .b(ay), .bi(1'b0), .d(vdy2), .bo(carry_unused[32]));
	am_sub #(.W(48)) u_ndy (.a(48'd0), .b({{16{ddy[23]}}, ddy, 8'd0}), .bi(1'b0), .d(ndy),
		.bo(carry_unused[33]));
	am_sub #(.W(48)) u_dd_n (.a(dd), .b(mp[47:0]), .bi(1'b0), .d(dd_n), .bo(carry_unused[34]));
	/* the edges of the ordered triangle: A = y1 - y0, B = x0 - x1, oX = sx - x0, oY = sy - y0 */
	wire [23:0] eA_n [0:2];
	wire [23:0] eB_n [0:2];
	wire [24:0] oX_n [0:2];
	wire [24:0] oY_n [0:2];
	wire [47:0] eE_n;
	genvar ge;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_e
		localparam [1:0] K0 = ge, K1 = ge == 2 ? 0 : ge + 1;
		wire [1:0] v0 = vtx(K0, ccw), v1 = vtx(K1, ccw);
		am_sub #(.W(24)) u_eA (.a(fy[v1]), .b(fy[v0]), .bi(1'b0), .d(eA_n[ge]),
			.bo(carry_unused[35 + 4 * ge]));
		am_sub #(.W(24)) u_eB (.a(fx[v0]), .b(fx[v1]), .bi(1'b0), .d(eB_n[ge]),
			.bo(carry_unused[36 + 4 * ge]));
		am_sub #(.W(25)) u_oX (.a(sx), .b({fx[v0][23], fx[v0]}), .bi(1'b0), .d(oX_n[ge]),
			.bo(carry_unused[37 + 4 * ge]));
		am_sub #(.W(25)) u_oY (.a(sy), .b({fy[v0][23], fy[v0]}), .bi(1'b0), .d(oY_n[ge]),
			.bo(carry_unused[38 + 4 * ge]));
	end
	endgenerate
	/* E_k = A_k oX_k + B_k oY_k - !tl_k */
	wire [47:0] eE_s;
	am_add #(.W(48)) u_eE_s (.a(acc[47:0]), .b(mp[47:0]), .ci(1'b0), .s(eE_s),
		.co(carry_unused[47]));
	am_sub #(.W(48)) u_eE_n (.a(eE_s), .b(48'd0), .bi(!tl[ek]), .d(eE_n), .bo(carry_unused[48]));

	always @(posedge clk) begin
		r_we <= 1'b0;
		done <= 1'b0;
		if (!rst_n) begin
			run <= 1'b0;
			cnt <= 6'd0;
		end else if (start) begin
			run <= 1'b1;
			cnt <= 6'd0;
			md <= mode;
			r_ra <= 7'd31;
			for (k = 0; k < 3; k = k + 1)
				eE[k] <= 48'd0;
		end else if (run) begin
			cnt <= cnt1;
			/* 0-9 read, 1-10 snap */
			if (cnt < 6'd9)
				r_ra <= rrv;
			if (cnt >= 6'd1 && cnt <= 6'd10)
				sv[tsn] <= snap;
			/* 11: the walked triangle, the corners, the plane triangle */
			if (cnt == 6'd11) begin
				fx[0] <= c0x;
				fy[0] <= c0y;
				fx[1] <= w1[1] ? (w1[0] ? c3x : c2x) : c1x;
				fy[1] <= w1[1] ? (w1[0] ? c3y : c2y) : c1y;
				fx[2] <= w2[1] ? (w2[0] ? c3x : c2x) : c1x;
				fy[2] <= w2[1] ? (w2[0] ? c3y : c2y) : c1y;
				pdx1 <= is_tri || is_line ? ddx : 24'sd256;
				pdy1 <= is_tri || is_line ? ddy : 24'sd0;
				pdx2 <= is_tri ? vdx2 : is_line && xmaj ? 24'sd0 : is_line ? 24'sd256 : 24'sd0;
				pdy2 <= is_tri ? vdy2 : is_line && !xmaj ? 24'sd0 : 24'sd256;
				pdd <= !is_line ? 48'sd65536 : xmaj ? {{16{ddx[23]}}, ddx, 8'd0} : ndy;
				p0x <= ax;
				p0y <= ay;
			end
			/* 12: bbox; 12-15: D */
			if (cnt == 6'd12) begin
				bx0 <= lo_x;
				by0 <= lo_y;
				bx1 <= hi_x;
				by1 <= hi_y;
				ma <= {dx1[23], dx1};
				mb <= {dy2[23], dy2};
			end
			if (cnt == 6'd13) begin
				ma <= {dx2[23], dx2};
				mb <= {dy1[23], dy1};
			end
			if (cnt == 6'd14)
				dd <= mp[47:0];
			if (cnt == 6'd15) begin
				dd <= dd_n;
				ccw <= dd_n[47];
				if (is_tri)
					pdd <= dd_n;
			end
			/* 16: facing, cull, empty; the edges of the ordered triangle */
			if (cnt == 6'd16) begin
				front <= !is_tri || (cull[2] ? ccw : !ccw);
				empty <= dd == 48'sd0 || (is_tri && cull[0] && (cull[2] ? ccw : !ccw)) ||
					(is_tri && cull[1] && !(cull[2] ? ccw : !ccw)) || bx1 <= bx0 || by1 <= by0;
				for (k = 0; k < 3; k = k + 1) begin
					eA[k] <= eA_n[k];
					eB[k] <= eB_n[k];
					oX[k] <= oX_n[k];
					oY[k] <= oY_n[k];
				end
			end
			if (cnt == 6'd17) begin
				for (k = 0; k < 3; k = k + 1)
					tl[k] <= eA[k] > 24'sd0 || (eA[k] == 24'sd0 && eB[k] > 24'sd0);
				if (empty) begin
					for (k = 0; k < 3; k = k + 1) begin
						eA[k] <= 24'sd0;
						eB[k] <= 24'sd0;
					end
					bx0 <= 18'sd0;
					by0 <= 18'sd0;
					bx1 <= 18'sd0;
					by1 <= 18'sd0;
					run <= 1'b0;
					done <= 1'b1;
				end
			end
			/* 17-22: E_k = A_k oX_k + B_k oY_k - !tl_k (products read at 19-24) */
			if (cnt >= 6'd17 && cnt <= 6'd22) begin
				ma <= ce_e[0] ? {eB[ej][23], eB[ej]} : {eA[ej][23], eA[ej]};
				mb <= ce_e[0] ? oY[ej] : oX[ej];
			end
			if (cnt >= 6'd19 && cnt <= 6'd24) begin
				if (!ce_p[0])
					acc <= mp;
				else
					eE[ek] <= eE_n;
			end
			/* 25-31: int2f stage A; 26-32: stage B into fp registers 40-46 */
			if (cnt >= 6'd25 && cnt <= 6'd31) begin
				ca <= cabs;
				cs <= ci[47];
				clz <= cl;
				csh <= ci_sh;
			end
			if (cnt >= 6'd26 && cnt <= 6'd32) begin
				r_we <= 1'b1;
				r_wa <= wa_n;
				r_wd <= c_out;
			end
			if (cnt == 6'd32) begin
				run <= 1'b0;
				done <= 1'b1;
			end
		end
	end

	genvar g;
	generate
	for (g = 0; g < 3; g = g + 1) begin : g_edge
		assign edges[96 * g +: 96] = {eE[g], eB[g], eA[g]};
	end
	endgenerate
	assign bbox = {by1[15:0], bx1[15:0], by0[15:0], bx0[15:0]};

	wire unused_ok = &{1'b0, acc[49:48], ce[8], bx0[17:16], by0[17:16], bx1[17:16],
		by1[17:16], adx[23], ady[23], q0x[7:0], q1x[7:0],
		q2x[7:0], q3x[7:0], q0y[7:0], q1y[7:0], q2y[7:0], q3y[7:0], s6[7:0], s7[7:0],
		s8[7:0], s9[7:0]};
endmodule

`default_nettype wire
