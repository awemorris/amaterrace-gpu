/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_bary: High-Performance Parallel Plane Evaluator & Barycentric Engine.
 *
 * Evaluates the four linear planes (Z, 1/W, B0/W, B1/W) across all 4 quad lanes
 * in parallel with pipelined arithmetic, eliminating the ~200 cycle serial bottleneck.
 * Features 4 parallel fp-div units and dedicated 4-lane 2-stage fp multiply/add pipelines.
 *
 * Fully compliant with Verilog-2005; zero raw arithmetic operators.
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
	reg [5:0] c;
	wire [5:0] c1;
	wire c1_co_unused;
	am_add #(.W(6)) u_c1 (.a(c), .b(6'd0), .ci(1'b1), .s(c1), .co(c1_co_unused));

	/* Lane coordinates (i, j) in eighths with offset, converted to fp32 */
	wire [31:0] fi [0:3];
	wire [31:0] fj [0:3];
	wire [23:0] ij_carry_unused;

	genvar gl;
	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_coord
		wire [2:0] os = (gl == 3) ? i_osel[11:9] : (gl == 2) ? i_osel[8:6] :
			(gl == 1) ? i_osel[5:3] : i_osel[2:0];
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

		wire [16:0] qi, qj, di, dj;
		wire [20:0] i8, j8;
		am_add #(.W(17)) u_qi (.a({1'b0, i_qx}), .b(17'd0), .ci(gl[0]), .s(qi), .co(ij_carry_unused[6 * gl + 0]));
		am_add #(.W(17)) u_qj (.a({1'b0, i_qy}), .b(17'd0), .ci(gl[1]), .s(qj), .co(ij_carry_unused[6 * gl + 1]));
		am_sub #(.W(17)) u_di (.a(qi), .b({1'b0, i_bx0}), .bi(1'b0), .d(di), .bo(ij_carry_unused[6 * gl + 2]));
		am_sub #(.W(17)) u_dj (.a(qj), .b({1'b0, i_by0}), .bi(1'b0), .d(dj), .bo(ij_carry_unused[6 * gl + 3]));
		am_add #(.W(21)) u_i8 (.a({{1{di[16]}}, di, 3'd0}), .b({{17{ox8[3]}}, ox8}), .ci(1'b0), .s(i8),
			.co(ij_carry_unused[6 * gl + 4]));
		am_add #(.W(21)) u_j8 (.a({{1{dj[16]}}, dj, 3'd0}), .b({{17{oy8[3]}}, oy8}), .ci(1'b0), .s(j8),
			.co(ij_carry_unused[6 * gl + 5]));
		am_fp_fix2f #(.W(21), .F(3), .SIGNED(1)) u_fi (.v(i8), .f(fi[gl]));
		am_fp_fix2f #(.W(21), .F(3), .SIGNED(1)) u_fj (.v(j8), .f(fj[gl]));
	end
	endgenerate

	/* Sample offsets for i_dz as fp32 */
	function [31:0] sdx;
		input [1:0] s;
		sdx = (s == 2'd0) ? 32'hBE000000 : (s == 2'd1) ? 32'h3EC00000 :
			(s == 2'd2) ? 32'hBEC00000 : 32'h3E000000;
	endfunction
	function [31:0] sdy;
		input [1:0] s;
		sdy = (s == 2'd0) ? 32'hBEC00000 : (s == 2'd1) ? 32'hBE000000 :
			(s == 2'd2) ? 32'h3E000000 : 32'h3EC00000;
	endfunction

	/* Storage registers */
	reg [31:0] v [0:3][0:3];	/* plane [0..3], lane [0..3] */
	reg [31:0] t1 [0:3][0:3];	/* temp multiply results */
	reg [31:0] rw [0:3];		/* reciprocal of 1/w */
	reg [31:0] b0 [0:3];
	reg [31:0] b1 [0:3];
	reg [31:0] b2 [0:3];
	reg [31:0] ds [0:3];

	/* Plane coefficients */
	wire [31:0] pl_a [0:3];
	wire [31:0] pl_b [0:3];
	wire [31:0] pl_c [0:3];
	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_pl_coeff
		assign pl_a[gl] = i_pl[32 * (3 * gl + 0) +: 32];
		assign pl_b[gl] = i_pl[32 * (3 * gl + 1) +: 32];
		assign pl_c[gl] = i_pl[32 * (3 * gl + 2) +: 32];
	end
	endgenerate

	wire [31:0] cur_pl_a = (c[2:1] == 2'd0) ? pl_a[0] : (c[2:1] == 2'd1) ? pl_a[1] : (c[2:1] == 2'd2) ? pl_a[2] : pl_a[3];
	wire [31:0] cur_pl_b = (c[2:1] == 2'd0) ? pl_b[0] : (c[2:1] == 2'd1) ? pl_b[1] : (c[2:1] == 2'd2) ? pl_b[2] : pl_b[3];
	wire [31:0] cur_pl_c = (c == 6'd9) ? pl_c[0] : (c == 6'd11) ? pl_c[1] : (c == 6'd13) ? pl_c[2] : pl_c[3];

	/* 4-Lane Parallel Multipliers, Stage 1 Adders, and Stage 2 Adders */
	wire [31:0] fm_a [0:3];
	wire [31:0] fm_b [0:3];
	wire fm_v [0:3];
	wire fm_o [0:3];
	wire [31:0] fm_r [0:3];

	wire [31:0] fa1_a [0:3];
	wire [31:0] fa1_b [0:3];
	wire fa1_sub [0:3];
	wire fa1_v [0:3];
	wire fa1_o [0:3];
	wire [31:0] fa1_r [0:3];

	wire [31:0] fa2_a [0:3];
	wire [31:0] fa2_b [0:3];
	wire fa2_sub [0:3];
	wire fa2_v [0:3];
	wire fa2_o [0:3];
	wire [31:0] fa2_r [0:3];

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_fp_units
		/* FP Multiplier */
		assign fm_v[gl] = (st == S_PL && c < 6'd8) ||
		                  (st == S_BC && c < 6'd2) ||
		                  (st == S_DZ && c < 6'd2);

		assign fm_a[gl] = (st == S_PL) ? (c[0] ? cur_pl_b : cur_pl_a) :
		                  (st == S_BC) ? (c[0] ? v[3][gl] : v[2][gl]) :
		                  (st == S_DZ) ? (c[0] ? pl_b[0] : pl_a[0]) : 32'd0;

		assign fm_b[gl] = (st == S_PL) ? (c[0] ? fj[gl] : fi[gl]) :
		                  (st == S_BC) ? rw[gl] :
		                  (st == S_DZ) ? (c[0] ? sdy(gl[1:0]) : sdx(gl[1:0])) : 32'd0;

		am_fp_mul #(.LAT(4)) u_fmul (
			.clk(clk), .rst_n(rst_n),
			.i_valid(fm_v[gl]), .i_a(fm_a[gl]), .i_b(fm_b[gl]),
			.o_valid(fm_o[gl]), .o_r(fm_r[gl])
		);

		/* Stage 1 FP Adder */
		wire [31:0] cur_t1_val = (c == 6'd5) ? t1[0][gl] :
		                         (c == 6'd7) ? t1[1][gl] :
		                         (c == 6'd9) ? t1[2][gl] : t1[3][gl];

		assign fa1_v[gl] = (st == S_PL && (c == 6'd5 || c == 6'd7 || c == 6'd9 || c == 6'd11)) ||
		                   (st == S_BC && c == 6'd4) ||
		                   (st == S_DZ && c == 6'd5);

		assign fa1_sub[gl] = (st == S_BC);

		assign fa1_a[gl] = (st == S_PL) ? cur_t1_val :
		                   (st == S_BC) ? ONE :
		                   (st == S_DZ) ? t1[0][gl] : 32'd0;

		assign fa1_b[gl] = fm_r[gl];

		am_fp_add #(.LAT(4)) u_fadd1 (
			.clk(clk), .rst_n(rst_n),
			.i_valid(fa1_v[gl]), .i_a(fa1_a[gl]), .i_b(fa1_b[gl]),
			.i_sub(fa1_sub[gl]), .o_valid(fa1_o[gl]), .o_r(fa1_r[gl])
		);

		/* Stage 2 FP Adder */
		assign fa2_v[gl] = (st == S_PL && (c == 6'd9 || c == 6'd11 || c == 6'd13 || c == 6'd15)) ||
		                   (st == S_BC && c == 6'd8);

		assign fa2_sub[gl] = (st == S_BC);

		assign fa2_a[gl] = fa1_r[gl];

		assign fa2_b[gl] = (st == S_PL) ? cur_pl_c :
		                   (st == S_BC) ? b1[gl] : 32'd0;

		am_fp_add #(.LAT(4)) u_fadd2 (
			.clk(clk), .rst_n(rst_n),
			.i_valid(fa2_v[gl]), .i_a(fa2_a[gl]), .i_b(fa2_b[gl]),
			.i_sub(fa2_sub[gl]), .o_valid(fa2_o[gl]), .o_r(fa2_r[gl])
		);
	end
	endgenerate

	/* 4-Lane Parallel FP Dividers */
	reg div_start;
	wire [3:0] fd_busy, fd_done;
	wire [31:0] fd_r [0:3];
	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_fdiv
		am_fp_div u_fdiv (
			.clk(clk), .rst_n(rst_n),
			.i_start(div_start), .i_a(ONE), .i_b(v[1][gl]),
			.busy(fd_busy[gl]), .o_done(fd_done[gl]), .o_r(fd_r[gl])
		);
	end
	endgenerate

	/* Outputs */
	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_out
		assign o_b0[32 * gl +: 32] = b0[gl];
		assign o_b1[32 * gl +: 32] = b1[gl];
		assign o_b2[32 * gl +: 32] = b2[gl];
		assign o_z[32 * gl +: 32] = v[0][gl];
		assign o_ds[32 * gl +: 32] = ds[gl];
	end
	endgenerate

	assign busy = (st != S_IDLE);

	integer p, lane_idx;
	always @(posedge clk) begin
		o_done <= 1'b0;
		div_start <= 1'b0;
		if (!rst_n) begin
			st <= S_IDLE;
			c <= 6'd0;
			for (p = 0; p < 4; p = p + 1)
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1) begin
					v[p][lane_idx] <= 32'd0;
					t1[p][lane_idx] <= 32'd0;
				end
			for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1) begin
				rw[lane_idx] <= 32'd0;
				b0[lane_idx] <= 32'd0;
				b1[lane_idx] <= 32'd0;
				b2[lane_idx] <= 32'd0;
				ds[lane_idx] <= 32'd0;
			end
		end else case (st)
		S_IDLE: begin
			c <= 6'd0;
			if (i_start)
				st <= S_PL;
			else if (i_dz)
				st <= S_DZ;
		end

		S_PL: begin
			c <= c1;
			/* Capture T0 = A*fi at c = 4, 6, 8, 10 */
			if (c == 6'd4) begin
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1)
					t1[0][lane_idx] <= fm_r[lane_idx];
			end
			if (c == 6'd6) begin
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1)
					t1[1][lane_idx] <= fm_r[lane_idx];
			end
			if (c == 6'd8) begin
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1)
					t1[2][lane_idx] <= fm_r[lane_idx];
			end
			if (c == 6'd10) begin
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1)
					t1[3][lane_idx] <= fm_r[lane_idx];
			end
			/* Capture final plane values at c = 13, 15, 17, 19 from fa2_r */
			if (c == 6'd13) begin
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1)
					v[0][lane_idx] <= fa2_r[lane_idx];
			end
			if (c == 6'd15) begin
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1)
					v[1][lane_idx] <= fa2_r[lane_idx];
			end
			if (c == 6'd17) begin
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1)
					v[2][lane_idx] <= fa2_r[lane_idx];
			end
			if (c == 6'd19) begin
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1)
					v[3][lane_idx] <= fa2_r[lane_idx];
				div_start <= 1'b1;
				c <= 6'd0;
				st <= S_DIV;
			end
		end

		S_DIV: begin
			/* 4 Parallel Dividers running */
			if (fd_done[0]) begin
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1)
					rw[lane_idx] <= fd_r[lane_idx];
				c <= 6'd0;
				st <= S_BC;
			end
		end

		S_BC: begin
			c <= c1;
			if (c == 6'd4) begin
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1)
					b0[lane_idx] <= fm_r[lane_idx];
			end
			if (c == 6'd5) begin
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1)
					b1[lane_idx] <= fm_r[lane_idx];
			end
			if (c == 6'd12) begin
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1)
					b2[lane_idx] <= fa2_r[lane_idx];
				o_done <= 1'b1;
				st <= S_IDLE;
			end
		end

		S_DZ: begin
			c <= c1;
			if (c == 6'd4) begin
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1)
					t1[0][lane_idx] <= fm_r[lane_idx];
			end
			if (c == 6'd9) begin
				for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1) begin
`ifdef MUT_DZ_SIGN
					ds[lane_idx] <= {~fa1_r[lane_idx][31], fa1_r[lane_idx][30:0]};
`else
					ds[lane_idx] <= fa1_r[lane_idx];
`endif
				end
				o_done <= 1'b1;
				st <= S_IDLE;
			end
		end

		default:
			st <= S_IDLE;
		endcase
	end

	wire unused_ok = &{1'b0,
		fm_o[0], fm_o[1], fm_o[2], fm_o[3],
		fa1_o[0], fa1_o[1], fa1_o[2], fa1_o[3],
		fa2_o[0], fa2_o[1], fa2_o[2], fa2_o[3],
		fd_busy[0], fd_busy[1], fd_busy[2], fd_busy[3],
		fd_done[1], fd_done[2], fd_done[3]
	};
endmodule

`default_nettype wire
