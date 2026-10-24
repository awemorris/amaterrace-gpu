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

	/* fp32 to 15.8 fixed point, RNE, saturated to +-(2^22 - 1), NaN 0. */
	function [23:0] f2fix;
		input [31:0] f;
		reg [47:0] v;
		reg [23:0] q;
		reg [7:0] s;
		begin
			s = 8'd142 - f[30:23];
			v = {1'b1, f[22:0], 24'd0} >> s;
			q = v[47:24] + {23'd0, v[23] && (v[22:0] != 23'd0 || v[24])};
			if (f[30:23] < 8'd94 || (f[30:23] == 8'hFF && f[22:0] != 23'd0))
				f2fix = 24'd0;
			else if (f[30:23] >= 8'd142 || q > 24'h3FFFFF)
				f2fix = f[31] ? 24'hC00001 : 24'h3FFFFF;
			else
				f2fix = f[31] ? -q : q;
		end
	endfunction

	wire [23:0] snap = f2fix(r_rd);

	/* The registers read, in order: 31 32 34 35 37 38, then 76-79. */
	function [6:0] rreg;
		input [3:0] i;
		rreg = i < 4'd6 ? 7'd31 + {3'd0, i} + {4'd0, i[3:1]} : 7'd70 + {3'd0, i};
	endfunction

	reg signed [23:0] sv [0:9];	/* snapped: x0 y0 x1 y1 x2 y2 rx0 rx1 ry0 ry1 */
	wire signed [23:0] ax = sv[0], ay = sv[1], bx = sv[2], by = sv[3];
	wire signed [23:0] ddx = bx - ax, ddy = by - ay;
	wire [23:0] adx = ddx[23] ? -ddx : ddx;
	wire [23:0] ady = ddy[23] ? -ddy : ddy;
`ifdef MUT_LINE_MAJOR
	wire xmaj = adx > ady;	/* the TB's mutation check: y-major when equal */
`else
	wire xmaj = adx >= ady;
`endif
	wire signed [23:0] ox = xmaj ? 24'sd0 : 24'sd128;
	wire signed [23:0] oy = xmaj ? 24'sd128 : 24'sd0;

	/* The corners: a triangle's vertices (and v0 again); a line's a-, a+,
	 * b-, b+; a point's p--, p+-, p++, p-+.  The walked triangle is corners
	 * (0, w1, w2). */
	wire is_line = !is_tri && kind == 2'd1;
	wire signed [23:0] vx2 = sv[4], vy2 = sv[5];
	wire signed [23:0] hx = is_line ? ox : 24'sd128;
	wire signed [23:0] hy = is_line ? oy : 24'sd128;
	wire signed [23:0] c0x = is_tri ? ax : ax - hx;
	wire signed [23:0] c0y = is_tri ? ay : ay - hy;
	wire signed [23:0] c1x = is_tri ? bx : ax + hx;
	wire signed [23:0] c1y = is_tri ? by : is_line ? ay + hy : ay - hy;
	wire signed [23:0] c2x = is_tri ? vx2 : is_line ? bx - hx : ax + hx;
	wire signed [23:0] c2y = is_tri ? vy2 : is_line ? by - hy : ay + hy;
	wire signed [23:0] c3x = is_tri ? ax : is_line ? bx + hx : ax - hx;
	wire signed [23:0] c3y = is_tri ? ay : is_line ? by + hy : ay + hy;
	wire [1:0] w1 = is_tri ? 2'd1 : is_line ? (md[2] ? 2'd3 : 2'd2) : (md[2] ? 2'd2 : 2'd1);
	wire [1:0] w2 = is_tri ? 2'd2 : is_line ? (md[2] ? 2'd1 : 2'd3) : (md[2] ? 2'd3 : 2'd2);

	/* The walked triangle, the four corners (bbox) and the plane triangle. */
	reg signed [23:0] fx [0:2];
	reg signed [23:0] fy [0:2];
	reg signed [23:0] pdx1, pdy1, pdx2, pdy2, p0x, p0y;
	reg signed [47:0] pdd;	/* the plane triangle's D (lines and points) */
	wire signed [23:0] fx0 = fx[0], fx1 = fx[1], fx2 = fx[2];
	wire signed [23:0] fy0 = fy[0], fy1 = fy[1], fy2 = fy[2];
	wire signed [23:0] dx1 = fx1 - fx0;
	wire signed [23:0] dy1 = fy1 - fy0;
	wire signed [23:0] dx2 = fx2 - fx0;
	wire signed [23:0] dy2 = fy2 - fy0;

	/* The multiplier: operands registered, product one cycle later. */
	reg signed [24:0] ma, mb;
	reg signed [49:0] mp;
	always @(posedge clk)
		mp <= ma * mb;

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
	reg signed [17:0] lo_x, lo_y, hi_x, hi_y, t_x, t_y;
	reg signed [17:0] bx0, by0, bx1, by1;
	always @(*) begin
		lo_x = pix(q0x[23:8]);
		hi_x = lo_x;
		lo_y = pix(q0y[23:8]);
		hi_y = lo_y;
		for (k = 1; k < 4; k = k + 1) begin
			t_x = pix(k == 1 ? q1x[23:8] : k == 2 ? q2x[23:8] : q3x[23:8]);
			t_y = pix(k == 1 ? q1y[23:8] : k == 2 ? q2y[23:8] : q3y[23:8]);
			if (t_x < lo_x)
				lo_x = t_x;
			if (t_x > hi_x)
				hi_x = t_x;
			if (t_y < lo_y)
				lo_y = t_y;
			if (t_y > hi_y)
				hi_y = t_y;
		end
		hi_x = hi_x + 18'sd1;
		hi_y = hi_y + 18'sd1;
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
	reg [47:0] cabs;
	reg [5:0] cl;
	always @(*) begin
		cabs = ci[47] ? -ci : ci;
		cl = 6'd48;
		for (k = 0; k < 48; k = k + 1)
			if (cabs[k])
				cl = 6'd47 - k[5:0];
	end
	reg [47:0] cn;
	reg [24:0] cm;
	reg [8:0] ce;
	always @(*) begin
		cn = ca << clz;
		cm = {1'b0, cn[47:24]} + {24'd0, cn[23] && (cn[22:0] != 23'd0 || cn[24])};
		ce = 9'd174 - {3'd0, clz} - {4'd0, csh} + {8'd0, cm[24]};
	end
	wire [31:0] c_out = ca == 48'd0 ? 32'd0 : {cs, ce[7:0], cm[24] ? cm[23:1] : cm[22:0]};

	/* Steps 25-31 convert DX1 DY1 DX2 DY2 DF OX OY of the plane triangle. */
	wire [5:0] ck = cnt - 6'd25;
	always @(*) begin
		case (ck)
		6'd0: begin ci = {{24{pdx1[23]}}, pdx1}; ci_sh = 5'd8; end
		6'd1: begin ci = {{24{pdy1[23]}}, pdy1}; ci_sh = 5'd8; end
		6'd2: begin ci = {{24{pdx2[23]}}, pdx2}; ci_sh = 5'd8; end
		6'd3: begin ci = {{24{pdy2[23]}}, pdy2}; ci_sh = 5'd8; end
		6'd4: begin ci = pdd; ci_sh = 5'd16; end
		6'd5: begin ci = {{23{sx[24]}}, sx} - {{24{p0x[23]}}, p0x}; ci_sh = 5'd8; end
		default: begin ci = {{23{sy[24]}}, sy} - {{24{p0y[23]}}, p0y}; ci_sh = 5'd8; end
		endcase
	end

	wire [5:0] ce_e = cnt - 6'd17;	/* steps 17-22: products of edge ce_e / 2 */
	wire [5:0] ce_p = cnt - 6'd19;	/* steps 19-24: their results */
	wire [1:0] ej = ce_e[2:1];
	wire [1:0] ek = ce_p[2:1];
	wire [3:0] tsn = cnt[3:0] - 4'd1;	/* steps 1-10: the snapped value */

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
			r_ra <= rreg(4'd0);
			for (k = 0; k < 3; k = k + 1)
				eE[k] <= 48'd0;
		end else if (run) begin
			cnt <= cnt + 6'd1;
			/* 0-9 read, 1-10 snap */
			if (cnt < 6'd9)
				r_ra <= rreg(cnt[3:0] + 4'd1);
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
				pdx2 <= is_tri ? vx2 - ax : is_line && xmaj ? 24'sd0 : is_line ? 24'sd256 : 24'sd0;
				pdy2 <= is_tri ? vy2 - ay : is_line && !xmaj ? 24'sd0 : 24'sd256;
				pdd <= !is_line ? 48'sd65536 : xmaj ? {{16{ddx[23]}}, ddx, 8'd0} :
					48'sd0 - {{16{ddy[23]}}, ddy, 8'd0};
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
				dd <= dd - mp[47:0];
				ccw <= $signed(dd - mp[47:0]) < 0;
				if (is_tri)
					pdd <= dd - mp[47:0];
			end
			/* 16: facing, cull, empty; the edges of the ordered triangle */
			if (cnt == 6'd16) begin
				front <= !is_tri || (cull[2] ? ccw : !ccw);
				empty <= dd == 48'sd0 || (is_tri && cull[0] && (cull[2] ? ccw : !ccw)) ||
					(is_tri && cull[1] && !(cull[2] ? ccw : !ccw)) || bx1 <= bx0 || by1 <= by0;
				for (k = 0; k < 3; k = k + 1) begin
					eA[k] <= fy[vtx(k == 2 ? 2'd0 : k[1:0] + 2'd1, ccw)] - fy[vtx(k[1:0], ccw)];
					eB[k] <= fx[vtx(k[1:0], ccw)] - fx[vtx(k == 2 ? 2'd0 : k[1:0] + 2'd1, ccw)];
					oX[k] <= sx - {fx[vtx(k[1:0], ccw)][23], fx[vtx(k[1:0], ccw)]};
					oY[k] <= sy - {fy[vtx(k[1:0], ccw)][23], fy[vtx(k[1:0], ccw)]};
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
					eE[ek] <= acc[47:0] + mp[47:0] - {47'd0, !tl[ek]};
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
				r_wa <= 7'd40 + {1'b0, cnt} - 7'd26;
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
		by1[17:16], ck, ce_e[5:3], ce_p[5:3], adx[23], ady[23], q0x[7:0], q1x[7:0],
		q2x[7:0], q3x[7:0], q0y[7:0], q1y[7:0], q2y[7:0], q3y[7:0], s6[7:0], s7[7:0],
		s8[7:0], s9[7:0]};
endmodule

`default_nettype wire
