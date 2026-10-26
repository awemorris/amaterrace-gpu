/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_bary: the lane arithmetic of atg_rx_frag, with the RX's fmul,
 * fadd and fdiv.
 *
 * i_start (idle only): for the four lanes of the quad at (i_qx, i_qy), at
 * the pixel centre or at a sample (i_osel, 3 bits per lane: 0 the centre,
 * 1 + s sample s), i = x - bx0 + dx and j = y - by0 + dy (fp32, exact:
 * the offsets are multiples of 1/8), then per lane
 *   P = (A i + B j) + C for the planes z, 1/w, b0/w, b1/w of atg_rx_setup
 *   (the four lanes interleaved, the planes 8 cycles apart: 44 cycles);
 *   r = 1 / (1/w) (fdiv, per lane); b0 = (b0/w) r, b1 = (b1/w) r,
 *   b2 = (1 - b0) - b1.
 * o_z is P of the plane z, not clamped.  About 200 cycles.
 * i_dz (idle only): d_s = Az dx_s + Bz dy_s for the four samples (fmul,
 * fmul, fadd; 16 cycles): the depth of sample s minus the centre's.
 * o_done pulses at the end of either; the outputs hold until the next.
 * The offsets: the standard sample locations (Values referenced: Vulkan
 * specification, Multisampling, VK_SAMPLE_COUNT_4_BIT): (dx, dy) =
 * (-1/8, -3/8), (3/8, -1/8), (-3/8, 1/8), (1/8, 3/8).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_bary (
	input wire clk,
	input wire rst_n,
	input wire i_start,
	input wire i_dz,
	input wire [383:0] i_pl,	/* (z, 1/w, b0/w, b1/w) x (A, B, C) */
	input wire [15:0] i_qx,
	input wire [15:0] i_qy,
	input wire [15:0] i_bx0,
	input wire [15:0] i_by0,
	input wire [11:0] i_osel,
	output wire busy,
	output reg o_done,
	output wire [127:0] o_b0,
	output wire [127:0] o_b1,
	output wire [127:0] o_b2,
	output wire [127:0] o_z,
	output wire [127:0] o_ds
);
	localparam [2:0] S_IDLE = 3'd0, S_PL = 3'd1, S_DIV = 3'd2, S_BC = 3'd3, S_DZ = 3'd4;
	localparam [31:0] ONE = 32'h3F800000;
	reg [2:0] st;
	reg [5:0] c;	/* step counter */
	wire [1:0] l = c[1:0];

	/* The lane's i and j in eighths, with its offset. */
	wire [2:0] os = l[1] ? (l[0] ? i_osel[11:9] : i_osel[8:6]) : (l[0] ? i_osel[5:3] : i_osel[2:0]);
	reg signed [3:0] ox8, oy8;
	always @(*) begin
		case (os)
		3'd1: begin ox8 = -4'sd1; oy8 = -4'sd3; end
		3'd2: begin ox8 = 4'sd3; oy8 = -4'sd1; end
		3'd3: begin ox8 = -4'sd3; oy8 = 4'sd1; end
		3'd4: begin ox8 = 4'sd1; oy8 = 4'sd3; end
		default: begin ox8 = 4'sd0; oy8 = 4'sd0; end
		endcase
	end
	/* i = qx + l[0] - bx0, j = qy + l[1] - by0, in eighths with the offset, to fp32 */
	wire [16:0] qi, qj, di, dj;
	wire [20:0] i8, j8;
	wire [31:0] fi, fj;
	wire [5:0] ij_carry_unused;
	am_add #(.W(17)) u_qi (.a({1'b0, i_qx}), .b(17'd0), .ci(l[0]), .s(qi), .co(ij_carry_unused[0]));
	am_add #(.W(17)) u_qj (.a({1'b0, i_qy}), .b(17'd0), .ci(l[1]), .s(qj), .co(ij_carry_unused[1]));
	am_sub #(.W(17)) u_di (.a(qi), .b({1'b0, i_bx0}), .bi(1'b0), .d(di), .bo(ij_carry_unused[2]));
	am_sub #(.W(17)) u_dj (.a(qj), .b({1'b0, i_by0}), .bi(1'b0), .d(dj), .bo(ij_carry_unused[3]));
	am_add #(.W(21)) u_i8 (.a({{1{di[16]}}, di, 3'd0}), .b({{17{ox8[3]}}, ox8}), .ci(1'b0), .s(i8),
		.co(ij_carry_unused[4]));
	am_add #(.W(21)) u_j8 (.a({{1{dj[16]}}, dj, 3'd0}), .b({{17{oy8[3]}}, oy8}), .ci(1'b0), .s(j8),
		.co(ij_carry_unused[5]));
	atg_rx_i2f #(.W(21), .F(3)) u_fi (.v(i8), .f(fi));
	atg_rx_i2f #(.W(21), .F(3)) u_fj (.v(j8), .f(fj));

	/* The sample offsets as fp32: dx_s, dy_s. */
	function [31:0] sdx;
		input [1:0] s;
		sdx = s == 2'd0 ? 32'hBE000000 : s == 2'd1 ? 32'h3EC00000 :
			s == 2'd2 ? 32'hBEC00000 : 32'h3E000000;
	endfunction
	function [31:0] sdy;
		input [1:0] s;
		sdy = s == 2'd0 ? 32'hBEC00000 : s == 2'd1 ? 32'hBE000000 :
			s == 2'd2 ? 32'h3E000000 : 32'h3EC00000;
	endfunction

	/* Per-lane values: v[p*4+l] for the planes p (z, 1/w, b0/w, b1/w); t1; r; b0, b1, b2. */
	reg [31:0] v [0:15];
	reg [31:0] t1 [0:3];
	reg [31:0] rw [0:3];
	reg [31:0] b0 [0:3];
	reg [31:0] b1 [0:3];
	reg [31:0] b2 [0:3];
	reg [31:0] ds [0:3];

	/* The fp units. */
	wire [1:0] pm = c[4:3];	/* the plane of a multiply in PL */
	wire [1:0] pa;	/* of an add: pm - 1 */
	wire pa_bo_unused;
	am_sub #(.W(2)) u_pa (.a(c[4:3]), .b(2'd0), .bi(1'b1), .d(pa), .bo(pa_bo_unused));
	/* the planes' coefficients A (0), B (1), C (2) of plane p at 32 (3 p + k) */
	reg [31:0] pl_m, pl_c;
	integer pp;
	always @(*) begin
		pl_m = 32'd0;
		pl_c = 32'd0;
		for (pp = 0; pp < 4; pp = pp + 1) begin
			if (pm == pp[1:0])
				pl_m = c[2] ? i_pl[32 * (3 * pp + 1) +: 32] : i_pl[32 * (3 * pp) +: 32];
			if (pa == pp[1:0])
				pl_c = i_pl[32 * (3 * pp + 2) +: 32];
		end
	end
	wire [5:0] c1;	/* c + 1 */
	wire c1_co_unused;
	am_add #(.W(6)) u_c1 (.a(c), .b(6'd0), .ci(1'b1), .s(c1), .co(c1_co_unused));
	wire dz = st == S_DZ;
	wire fm_v = (st == S_PL && c < 6'd32) || (st == S_BC && c < 6'd8) || (dz && c < 6'd8);
	wire [31:0] fm_a = dz ? (c[2] ? i_pl[32 +: 32] : i_pl[0 +: 32]) :
		st == S_BC ? (c[2] ? v[{2'd3, l}] : v[{2'd2, l}]) :
		pl_m;
	wire [31:0] fm_b = dz ? (c[2] ? sdy(l) : sdx(l)) : st == S_BC ? rw[l] : c[2] ? fj : fi;
	wire fm_o, fa_o;
	wire [31:0] fm_r, fa_r;
	am_fp_mul #(.LAT(4)) fmul (.clk(clk), .rst_n(rst_n), .i_valid(fm_v), .i_a(fm_a), .i_b(fm_b),
		.o_valid(fm_o), .o_r(fm_r));
	wire fa_v = (st == S_PL && c >= 6'd8 && c < 6'd40) || (st == S_BC && c >= 6'd4 && c < 6'd12) ||
		(dz && c >= 6'd8 && c < 6'd12);
	wire [31:0] fa_a = dz ? t1[l] : st == S_BC ? (c < 6'd8 ? ONE : fa_r) : c[2] ? fa_r : t1[l];
	wire [31:0] fa_b = dz ? fm_r : st == S_BC ? fm_r : c[2] ? pl_c : fm_r;
	am_fp_add #(.LAT(4)) fadd (.clk(clk), .rst_n(rst_n), .i_valid(fa_v), .i_a(fa_a), .i_b(fa_b),
		.i_sub(st == S_BC), .o_valid(fa_o), .o_r(fa_r));
	reg dgo;
	wire fd_busy, fd_done;
	wire [31:0] fd_r;
	atg_rx_fdiv fdiv (.clk(clk), .rst_n(rst_n), .i_start(st == S_DIV && !dgo), .i_a(ONE),
		.i_b(v[{2'd1, l}]), .busy(fd_busy), .o_done(fd_done), .o_r(fd_r));

	assign busy = st != S_IDLE;
	genvar g;
	generate
		for (g = 0; g < 4; g = g + 1) begin : g_out
			assign o_b0[32 * g +: 32] = b0[g];
			assign o_b1[32 * g +: 32] = b1[g];
			assign o_b2[32 * g +: 32] = b2[g];
			assign o_z[32 * g +: 32] = v[g];
			assign o_ds[32 * g +: 32] = ds[g];
		end
	endgenerate

	always @(posedge clk) begin
		o_done <= 1'b0;
		if (!rst_n) begin
			st <= S_IDLE;
			c <= 6'd0;
			dgo <= 1'b0;
		end else case (st)
		S_IDLE: begin
			c <= 6'd0;
			dgo <= 1'b0;
			if (i_start)
				st <= S_PL;
			else if (i_dz)
				st <= S_DZ;
		end
		S_PL: begin
			c <= c1;
			if (c >= 6'd4 && c < 6'd36 && c[2])
				t1[l] <= fm_r;
			if (c >= 6'd16 && !c[2])
				v[{~c[4], c[3], l}] <= fa_r;	/* plane c[4:3] - 2 */
			if (c == 6'd43) begin
				c <= 6'd0;
				dgo <= 1'b0;
				st <= S_DIV;
			end
		end
		S_DIV:
			if (!dgo)
				dgo <= 1'b1;
			else if (fd_done) begin
				rw[l] <= fd_r;
				dgo <= 1'b0;
				c <= c1;
				if (l == 2'd3) begin
					c <= 6'd0;
					st <= S_BC;
				end
			end
		S_BC: begin
			c <= c1;
			if (c >= 6'd4 && c < 6'd8)
				b0[l] <= fm_r;
			if (c >= 6'd8 && c < 6'd12)
				b1[l] <= fm_r;
			if (c >= 6'd12)
				b2[l] <= fa_r;
			if (c == 6'd15) begin
				o_done <= 1'b1;
				st <= S_IDLE;
			end
		end
		S_DZ: begin
			c <= c1;
			if (c >= 6'd4 && c < 6'd8)
				t1[l] <= fm_r;
`ifdef MUT_DZ_SIGN
			if (c >= 6'd12)
				ds[l] <= {~fa_r[31], fa_r[30:0]};
`else
			if (c >= 6'd12)
				ds[l] <= fa_r;
`endif
			if (c == 6'd15) begin
				o_done <= 1'b1;
				st <= S_IDLE;
			end
		end
		default:
			st <= S_IDLE;
		endcase
	end

	wire unused_ok = &{1'b0, fm_o, fa_o, fd_busy, di[16], dj[16]};
endmodule

`default_nettype wire
