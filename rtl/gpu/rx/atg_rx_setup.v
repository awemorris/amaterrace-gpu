/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_setup: RX triangle setup: perspective divide and viewport
 * (VIEWPORT 0-5), cull (CULL), edge functions in 15.8 fixed point,
 * bounding box ∩ scissor ∩ RT_SIZE, depth and perspective-barycentric
 * planes.
 *
 * A micro-programmed fp32 datapath (include/atg_rx_setup_uc.vh: one fadd,
 * one fmul, one fdiv, 128 fp registers in distributed RAM) does the
 * floating-point steps; an integer step sequence between them (micro-op
 * INT) snaps the vertices, computes the edges, the bbox and the facing
 * and converts the integer deltas back to fp32.  One triangle at a time.
 * See spec/gpu/rx/atg_rx_setup.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_setup (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* Triangles from atg_rx_clip */
	input wire cl_valid,
	output wire cl_ready,
	input wire [699:0] cl_tri,
	input wire cl_last,
	/* To atg_rx_scan */
	output reg sp_valid,
	input wire sp_ready,
	output wire [767:0] sp_tri,
	output reg sp_last,
	output wire busy
);
	`include "atg_rx_setup_uc.vh"
	`include "ghci_regs.vh"

	localparam [31:0] ONE = 32'h3F800000;

	/* STATE: VIEWPORT 0x050-0x055, SCISSOR 0x056-0x057, CULL 0x058, RT_SIZE 0x073. */
	reg [31:0] vp [0:5];
	reg [31:0] smin, smax, rts;
	reg [2:0] cull;

	always @(posedge clk)
		if (!rst_n) begin
			smin <= 32'd0;
			smax <= 32'd0;
			rts <= 32'd0;
			cull <= 3'd0;
		end else if (st_we) begin
			if (st_idx >= GHCI_S_VIEWPORT && st_idx <= GHCI_S_VIEWPORT + 9'd5)
				vp[st_idx[2:0]] <= st_wdata;
			if (st_idx == GHCI_S_SCISSOR_MIN)
				smin <= st_wdata;
			if (st_idx == GHCI_S_SCISSOR_MAX)
				smax <= st_wdata;
			if (st_idx == GHCI_S_CULL)
				cull <= st_wdata[2:0];
			if (st_idx == GHCI_S_RT_SIZE)
				rts <= st_wdata;
		end

	localparam [2:0] S_IDLE = 3'd0, S_LOAD = 3'd1, S_DEC = 3'd2, S_RD = 3'd3, S_GO = 3'd4,
		S_WAIT = 3'd5, S_INT = 3'd6, S_OUT = 3'd7;
	reg [2:0] st;
	reg [5:0] cnt;	/* S_LOAD word, S_INT step */
	reg [6:0] pc;
	reg [24:0] uc;
	wire [3:0] u_op = uc[24:21];
	wire [6:0] u_d = uc[20:14];
	wire [6:0] u_a = uc[13:7];
	wire [6:0] u_b = uc[6:0];
	reg raw;
	reg [26:0] keep;	/* PT entries [23:0], last-use flags [26:24] */

	/* The fp registers (spec §4 lists the numbers). */
	reg [31:0] R [0:127];
	reg [31:0] pl [0:11];	/* the planes z, 1/w, b0/w, b1/w (registers 64-75) */
	reg [31:0] opa, opb;
	reg r_we;
	reg [6:0] r_wa;
	reg [31:0] r_wd;
	integer k;

	always @(posedge clk)
		if (r_we)
			R[r_wa] <= r_wd;

	/* The fp units. */
	reg fa_v, fm_v, fd_v;
	wire fa_o, fm_o, fd_o, fd_busy;
	wire [31:0] fa_r, fm_r, fd_r;
	atg_rx_fadd fadd (.clk(clk), .rst_n(rst_n), .i_valid(fa_v), .i_a(opa), .i_b(opb),
		.i_sub(u_op == 4'd2), .o_valid(fa_o), .o_r(fa_r));
	atg_rx_fmul fmul (.clk(clk), .rst_n(rst_n), .i_valid(fm_v), .i_a(opa), .i_b(opb),
		.o_valid(fm_o), .o_r(fm_r));
	atg_rx_fdiv fdiv (.clk(clk), .rst_n(rst_n), .i_start(fd_v), .i_a(opa), .i_b(opb),
		.busy(fd_busy), .o_done(fd_o), .o_r(fd_r));

	/* ---- The integer steps ---- */
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

	reg [31:0] rv;
	wire [23:0] snap = f2fix(rv);
	reg signed [23:0] fx [0:2];
	reg signed [23:0] fy [0:2];
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

	/* bbox: vertices' pixels, max exclusive, ∩ scissor (when SCISSOR_MAX != 0) ∩ RT. */
	reg signed [17:0] lo_x, lo_y, hi_x, hi_y, t_x, t_y;
	reg signed [17:0] bx0, by0, bx1, by1;
	always @(*) begin
		lo_x = {{2{fx0[23]}}, fx0[23:8]};
		hi_x = lo_x;
		lo_y = {{2{fy0[23]}}, fy0[23:8]};
		hi_y = lo_y;
		for (k = 1; k < 3; k = k + 1) begin
			t_x = k == 1 ? {{2{fx1[23]}}, fx1[23:8]} : {{2{fx2[23]}}, fx2[23:8]};
			t_y = k == 1 ? {{2{fy1[23]}}, fy1[23:8]} : {{2{fy2[23]}}, fy2[23:8]};
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
	reg ccw, front, empty;
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

	/* Steps 20-26 convert DX1 DY1 DX2 DY2 DF OX OY (fp registers 40-46). */
	wire [5:0] ck = cnt - 6'd20;
	always @(*) begin
		case (ck)
		6'd0: begin ci = {{24{dx1[23]}}, dx1}; ci_sh = 5'd8; end
		6'd1: begin ci = {{24{dy1[23]}}, dy1}; ci_sh = 5'd8; end
		6'd2: begin ci = {{24{dx2[23]}}, dx2}; ci_sh = 5'd8; end
		6'd3: begin ci = {{24{dy2[23]}}, dy2}; ci_sh = 5'd8; end
		6'd4: begin ci = dd; ci_sh = 5'd16; end
		6'd5: begin ci = {{23{sx[24]}}, sx} - {{24{fx0[23]}}, fx0}; ci_sh = 5'd8; end
		default: begin ci = {{23{sy[24]}}, sy} - {{24{fy0[23]}}, fy0}; ci_sh = 5'd8; end
		endcase
	end

	wire [1:0] ej = cnt[2:1] - 2'd2;	/* edge of steps 12-17 (cnt 12 = 0b001100) */
	wire [1:0] ek = cnt[2:1] - 2'd3;	/* edge of steps 14-19 */
	wire [2:0] tsnap = cnt[2:0] - 3'd1;	/* steps 1-6: the snapped coordinate */

	assign cl_ready = st == S_LOAD && cnt == 6'd27;
	assign busy = st != S_IDLE;

	always @(posedge clk) begin
		uc <= atg_rx_uc(pc);
		r_we <= 1'b0;
		fa_v <= 1'b0;
		fm_v <= 1'b0;
		fd_v <= 1'b0;
		if (!rst_n) begin
			st <= S_IDLE;
			sp_valid <= 1'b0;
		end else case (st)
		S_IDLE:
			if (cl_valid) begin
				st <= S_LOAD;
				cnt <= 6'd0;
				raw <= cl_tri[699];
				keep <= cl_tri[698:672];
				sp_last <= cl_last;
				for (k = 0; k < 12; k = k + 1)
					pl[k] <= 32'd0;
				for (k = 0; k < 3; k = k + 1)
					eE[k] <= 48'd0;
			end
		S_LOAD: begin
			/* fp registers 0-20 from cl_tri, 21-26 VIEWPORT, 27 1.0 */
			r_we <= 1'b1;
			r_wa <= {1'b0, cnt};
			r_wd <= cnt < 6'd21 ? cl_tri[cnt * 32 +: 32] : cnt < 6'd27 ? vp[cnt[2:0] - 3'd5] : ONE;
			cnt <= cnt + 6'd1;
			if (cnt == 6'd27) begin
				pc <= raw ? 7'd0 : ATG_RX_UC_PERSP;
				st <= S_DEC;
			end
		end
		S_DEC:
			st <= S_RD;	/* uc follows pc */
		S_RD: begin
			opa <= R[u_a];
			opb <= R[u_b];
			case (u_op)
			4'd0: st <= S_OUT;
			4'd8: if (raw) st <= S_OUT; else begin pc <= pc + 7'd1; st <= S_DEC; end
			4'd7: begin pc <= u_d; st <= S_DEC; end
			4'd6: begin cnt <= 6'd0; st <= S_INT; end
			default: st <= S_GO;
			endcase
		end
		S_GO:
			if (u_op == 4'd5) begin
				r_we <= 1'b1;
				r_wa <= u_d;
				r_wd <= opa;
				pc <= pc + 7'd1;
				st <= S_DEC;
			end else begin
				fa_v <= u_op == 4'd1 || u_op == 4'd2;
				fm_v <= u_op == 4'd3;
				fd_v <= u_op == 4'd4;
				st <= S_WAIT;
			end
		S_WAIT:
			if (fa_o || fm_o || fd_o) begin
				r_we <= 1'b1;
				r_wa <= u_d;
				r_wd <= fa_o ? fa_r : fm_o ? fm_r : fd_r;
				if (u_d >= 7'd64 && u_d < 7'd76)
					pl[u_d[3:0]] <= fa_o ? fa_r : fm_o ? fm_r : fd_r;
				pc <= pc + 7'd1;
				st <= S_DEC;
			end
		S_INT: begin
			cnt <= cnt + 6'd1;
			/* 0-5 read X0 Y0 X1 Y1 X2 Y2 (registers 31 32 34 35 37 38), 1-6 snap them */
			if (cnt < 6'd6)
				rv <= R[7'd31 + {cnt[5:1], 1'b0} + {1'b0, cnt[5:1]} + {6'd0, cnt[0]}];
			if (cnt >= 6'd1 && cnt <= 6'd6) begin
				if (!tsnap[0])
					fx[tsnap[2:1]] <= snap;
				else
					fy[tsnap[2:1]] <= snap;
			end
			/* 7: bbox; 7-10: D */
			if (cnt == 6'd7) begin
				bx0 <= lo_x;
				by0 <= lo_y;
				bx1 <= hi_x;
				by1 <= hi_y;
				ma <= {dx1[23], dx1};
				mb <= {dy2[23], dy2};
			end
			if (cnt == 6'd8) begin
				ma <= {dx2[23], dx2};
				mb <= {dy1[23], dy1};
			end
			if (cnt == 6'd9)
				dd <= mp[47:0];
			if (cnt == 6'd10) begin
				dd <= dd - mp[47:0];
				ccw <= $signed(dd - mp[47:0]) < 0;
			end
			/* 11: facing, cull, empty; the edges of the ordered triangle */
			if (cnt == 6'd11) begin
				front <= cull[2] ? ccw : !ccw;
				empty <= dd == 48'sd0 || (cull[0] && (cull[2] ? ccw : !ccw)) ||
					(cull[1] && !(cull[2] ? ccw : !ccw)) || bx1 <= bx0 || by1 <= by0;
				for (k = 0; k < 3; k = k + 1) begin
					eA[k] <= fy[vtx(k == 2 ? 2'd0 : k[1:0] + 2'd1, ccw)] - fy[vtx(k[1:0], ccw)];
					eB[k] <= fx[vtx(k[1:0], ccw)] - fx[vtx(k == 2 ? 2'd0 : k[1:0] + 2'd1, ccw)];
					oX[k] <= sx - {fx[vtx(k[1:0], ccw)][23], fx[vtx(k[1:0], ccw)]};
					oY[k] <= sy - {fy[vtx(k[1:0], ccw)][23], fy[vtx(k[1:0], ccw)]};
				end
			end
			if (cnt == 6'd12) begin
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
					st <= S_OUT;
				end
			end
			/* 12-17: E_k = A_k oX_k + B_k oY_k - !tl_k (products read at 14-19) */
			if (cnt >= 6'd12 && cnt <= 6'd17) begin
				ma <= cnt[0] ? {eB[ej][23], eB[ej]} : {eA[ej][23], eA[ej]};
				mb <= cnt[0] ? oY[ej] : oX[ej];
			end
			if (cnt >= 6'd14 && cnt <= 6'd19) begin
				if (!cnt[0])
					acc <= mp;
				else
					eE[ek] <= acc[47:0] + mp[47:0] - {47'd0, !tl[ek]};
			end
			/* 20-26: int2f stage A; 21-27: stage B into fp registers 40-46 */
			if (cnt >= 6'd20 && cnt <= 6'd26) begin
				ca <= cabs;
				cs <= ci[47];
				clz <= cl;
				csh <= ci_sh;
			end
			if (cnt >= 6'd21 && cnt <= 6'd27) begin
				r_we <= 1'b1;
				r_wa <= 7'd40 + {1'b0, cnt} - 7'd21;
				r_wd <= c_out;
			end
			if (cnt == 6'd27) begin
				pc <= pc + 7'd1;
				st <= S_DEC;
			end
		end
		default: begin	/* S_OUT */
			sp_valid <= 1'b1;
			if (sp_valid && sp_ready) begin
				sp_valid <= 1'b0;
				st <= S_IDLE;
			end
		end
		endcase
	end

	genvar g;
	generate
	for (g = 0; g < 3; g = g + 1) begin : g_edge
		assign sp_tri[96 * g +: 96] = {eE[g], eB[g], eA[g]};
	end
	for (g = 0; g < 12; g = g + 1) begin : g_plane
		assign sp_tri[352 + 32 * g +: 32] = pl[g];
	end
	endgenerate
	assign sp_tri[351:288] = {by1[15:0], bx1[15:0], by0[15:0], bx0[15:0]};
	assign sp_tri[767:736] = {3'd0, raw, front, keep};

	wire unused_ok = &{1'b0, fd_busy, acc[49:48], ce[8], bx0[17:16], by0[17:16],
		bx1[17:16], by1[17:16], ck, ej, ek};
endmodule

`default_nettype wire
