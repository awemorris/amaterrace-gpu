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

(* keep_hierarchy = "yes" *)
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
	localparam [2:0] S_IDLE = 3'd0, S_PREP1 = 3'd1, S_PREP2 = 3'd2,
		S_PL = 3'd3, S_DIV = 3'd4, S_BC = 3'd5, S_DZ = 3'd6, S_PREP0 = 3'd7;
	localparam [31:0] ONE = 32'h3F800000;

	wire rst_sync = !rst_n;
	(* max_fanout = 16 *) reg [2:0] st;
	(* max_fanout = 16 *) reg [5:0] c;
	wire [5:0] c1;
	wire c1_co_unused;
	am_add #(.W(6)) u_c1 (.a(c), .b(6'd0), .ci(1'b1), .s(c1), .co(c1_co_unused));

	/* Registered inputs to isolate RX/Frag logic from Bary arithmetic */
	(* extract_reset = "no" *) reg [383:0] r_pl;
	(* extract_reset = "no" *) reg [15:0] r_qx_l [0:3];
	(* extract_reset = "no" *) reg [15:0] r_qy_l [0:3];
	(* extract_reset = "no" *) reg [15:0] r_bx0_l [0:3];
	(* extract_reset = "no" *) reg [15:0] r_by0_l [0:3];
	reg [11:0] r_osel;

	/* Stage 0->1: Lane coordinates (i, j) in eighths with offset */
	(* extract_reset = "no" *) reg [16:0] r_di [0:3];
	(* extract_reset = "no" *) reg [16:0] r_dj [0:3];
	(* extract_reset = "no" *) reg signed [4:0] r_ox8 [0:3];
	(* extract_reset = "no" *) reg signed [4:0] r_oy8 [0:3];
	(* extract_reset = "no" *) reg [20:0] r_i8 [0:3];
	(* extract_reset = "no" *) reg [20:0] r_j8 [0:3];
	wire [16:0] di_comb [0:3];
	wire [16:0] dj_comb [0:3];
	wire [20:0] i8_comb [0:3];
	wire [20:0] j8_comb [0:3];
	wire [23:0] ij_carry_unused;

	/* Stage 2: Converted to fp32 via 5-stage pipeline */
	(* extract_reset = "no" *) reg [31:0] r_fi [0:3];
	(* extract_reset = "no" *) reg [31:0] r_fj [0:3];
	wire [31:0] fi_comb [0:3];
	wire [31:0] fj_comb [0:3];

	genvar gl, gs, gh, gp;
	generate
	for (gs = 0; gs < 24; gs = gs + 1) begin : g_pl_reg
		wire pl_we_raw = !rst_sync && (st == S_IDLE) && (i_start || i_dz);
		wire pl_we_s = pl_we_raw;
		always @(posedge clk) begin
			if (pl_we_s)
				r_pl[16 * gs +: 16] <= i_pl[16 * gs +: 16];
		end
	end

	for (gl = 0; gl < 4; gl = gl + 1) begin : g_coord
		wire idle_start_raw = !rst_sync && (st == S_IDLE) && i_start;
		wire we_qx  = idle_start_raw;
		wire we_qy  = idle_start_raw;
		wire we_bx0 = idle_start_raw;
		wire we_by0 = idle_start_raw;

		always @(posedge clk) begin
			if (we_qx)  r_qx_l[gl]  <= i_qx;
			if (we_qy)  r_qy_l[gl]  <= i_qy;
			if (we_bx0) r_bx0_l[gl] <= i_bx0;
			if (we_by0) r_by0_l[gl] <= i_by0;
		end

		wire [2:0] os = (gl == 3) ? r_osel[11:9] : (gl == 2) ? r_osel[8:6] :
			(gl == 1) ? r_osel[5:3] : r_osel[2:0];
		reg signed [4:0] ox8, oy8;
		always @(*) begin
			case (os)
			3'd1: begin
				ox8 = gl[0] ? 5'sd7  : -5'sd1;
				oy8 = gl[1] ? 5'sd5  : -5'sd3;
			end
			3'd2: begin
				ox8 = gl[0] ? 5'sd11 : 5'sd3;
				oy8 = gl[1] ? 5'sd7  : -5'sd1;
			end
			3'd3: begin
				ox8 = gl[0] ? 5'sd5  : -5'sd3;
				oy8 = gl[1] ? 5'sd9  : 5'sd1;
			end
			3'd4: begin
				ox8 = gl[0] ? 5'sd9  : 5'sd1;
				oy8 = gl[1] ? 5'sd11 : 5'sd3;
			end
			default: begin
				ox8 = gl[0] ? 5'sd8  : 5'sd0;
				oy8 = gl[1] ? 5'sd8  : 5'sd0;
			end
			endcase
		end

		assign ij_carry_unused[6 * gl + 0] = 1'b0;
		assign ij_carry_unused[6 * gl + 1] = 1'b0;
		am_sub #(.W(17)) u_di (.a({1'b0, r_qx_l[gl]}), .b({1'b0, r_bx0_l[gl]}), .bi(1'b0), .d(di_comb[gl]), .bo(ij_carry_unused[6 * gl + 2]));
		am_sub #(.W(17)) u_dj (.a({1'b0, r_qy_l[gl]}), .b({1'b0, r_by0_l[gl]}), .bi(1'b0), .d(dj_comb[gl]), .bo(ij_carry_unused[6 * gl + 3]));
		am_add #(.W(21)) u_i8 (.a({{1{r_di[gl][16]}}, r_di[gl], 3'd0}), .b({{16{r_ox8[gl][4]}}, r_ox8[gl]}), .ci(1'b0), .s(i8_comb[gl]),
			.co(ij_carry_unused[6 * gl + 4]));
		am_add #(.W(21)) u_j8 (.a({{1{r_dj[gl][16]}}, r_dj[gl], 3'd0}), .b({{16{r_oy8[gl][4]}}, r_oy8[gl]}), .ci(1'b0), .s(j8_comb[gl]),
			.co(ij_carry_unused[6 * gl + 5]));

		atg_rx_fix2f_pipe #(.W(21), .F(3), .SIGNED(1)) u_fi (.clk(clk), .i_v(r_i8[gl]), .o_f(fi_comb[gl]));
		atg_rx_fix2f_pipe #(.W(21), .F(3), .SIGNED(1)) u_fj (.clk(clk), .i_v(r_j8[gl]), .o_f(fj_comb[gl]));

		wire prep0_raw = !rst_sync && (st == S_PREP0);
		wire prep1_raw = !rst_sync && (st == S_PREP1);
		wire prep2_raw = !rst_sync && (st == S_PREP2) && (c == 6'd5);
		wire we_di_lo, we_dj_lo, we_didj_hi;
		wire we_i8_lo, we_j8_lo, we_i8j8_hi;
		wire we_fi_lo, we_fi_hi, we_fj_lo, we_fj_hi;
		assign we_di_lo   = prep0_raw;
		assign we_dj_lo   = prep0_raw;
		assign we_didj_hi = prep0_raw;
		assign we_i8_lo   = prep1_raw;
		assign we_j8_lo   = prep1_raw;
		assign we_i8j8_hi = prep1_raw;
		assign we_fi_lo   = prep2_raw;
		assign we_fi_hi   = prep2_raw;
		assign we_fj_lo   = prep2_raw;
		assign we_fj_hi   = prep2_raw;

		always @(posedge clk) begin
			if (we_di_lo) r_di[gl][15:0] <= di_comb[gl][15:0];
			if (we_dj_lo) r_dj[gl][15:0] <= dj_comb[gl][15:0];
			if (we_didj_hi) begin
				r_di[gl][16] <= di_comb[gl][16];
				r_dj[gl][16] <= dj_comb[gl][16];
				r_ox8[gl]    <= ox8;
				r_oy8[gl]    <= oy8;
			end
			if (we_i8_lo) r_i8[gl][15:0] <= i8_comb[gl][15:0];
			if (we_j8_lo) r_j8[gl][15:0] <= j8_comb[gl][15:0];
			if (we_i8j8_hi) begin
				r_i8[gl][20:16] <= i8_comb[gl][20:16];
				r_j8[gl][20:16] <= j8_comb[gl][20:16];
			end
			if (we_fi_lo) r_fi[gl][15:0]  <= fi_comb[gl][15:0];
			if (we_fi_hi) r_fi[gl][31:16] <= fi_comb[gl][31:16];
			if (we_fj_lo) r_fj[gl][15:0]  <= fj_comb[gl][15:0];
			if (we_fj_hi) r_fj[gl][31:16] <= fj_comb[gl][31:16];
		end
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
	(* extract_reset = "no" *) reg [31:0] v [0:3][0:3];	/* plane [0..3], lane [0..3] */
	(* extract_reset = "no" *) reg [31:0] rw [0:3];		/* reciprocal of 1/w */
	(* extract_reset = "no" *) reg [31:0] b0 [0:3];
	(* extract_reset = "no" *) reg [31:0] b1 [0:3];
	(* extract_reset = "no" *) reg [31:0] b2 [0:3];
	(* extract_reset = "no" *) reg [31:0] ds [0:3];
	(* extract_reset = "no" *) reg [31:0] r_t1_curr [0:3];
	(* extract_reset = "no" *) reg [31:0] r_fa2_b [0:3];

	/* 4-Lane Parallel FP Dividers */
	reg div_start;
	wire [3:0] fd_busy, fd_done;
	wire [31:0] fd_r [0:3];

	/* Plane coefficients */
	wire [31:0] pl_a [0:3];
	wire [31:0] pl_b [0:3];
	wire [31:0] pl_c [0:3];
	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_pl_coeff
		assign pl_a[gl] = r_pl[32 * (3 * gl + 0) +: 32];
		assign pl_b[gl] = r_pl[32 * (3 * gl + 1) +: 32];
		assign pl_c[gl] = r_pl[32 * (3 * gl + 2) +: 32];
	end
	endgenerate

	(* extract_reset = "no" *) reg [31:0] r_fm_a [0:3];
	(* extract_reset = "no" *) reg [31:0] r_fm_b [0:3];
	reg [3:0] r_fm_v;
	wire fm_o [0:3];
	wire [31:0] fm_r [0:3];

	(* extract_reset = "no" *) reg [31:0] r_fa1_a [0:3];
	(* extract_reset = "no" *) reg [31:0] r_fa1_b [0:3];
	reg [3:0] r_fa1_sub;
	reg [3:0] r_fa1_v;
	wire fa1_o [0:3];
	wire [31:0] fa1_r [0:3];

	(* extract_reset = "no" *) reg [31:0] r_fa2_a [0:3];
	reg [3:0] r_fa2_sub;
	reg [3:0] r_fa2_v;
	wire fa2_o [0:3];
	wire [31:0] fa2_r [0:3];

	/* Pre-computed multiplier & adder inputs (registered 1 cycle ahead for 0-LUT input to fmul/fadd) */
	wire fm_v_nxt = !rst_sync && (
		(st == S_PL && c < 6'd8) ||
		(st == S_BC && c < 6'd2) ||
		(st == S_DZ && c < 6'd2));
	wire fa1_v_nxt = !rst_sync && (
		(st == S_PL && (c == 6'd6 || c == 6'd8 || c == 6'd10 || c == 6'd12)) ||
		(st == S_BC && c == 6'd5) ||
		(st == S_DZ && c == 6'd6));
	wire fa2_v_nxt = !rst_sync && (
		(st == S_PL && (c == 6'd11 || c == 6'd13 || c == 6'd15 || c == 6'd17)) ||
		(st == S_BC && c == 6'd10));
	wire is_bc_raw = (st == S_BC);

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_fp_units
		wire [31:0] sdx_c = sdx(gl[1:0]);
		wire [31:0] sdy_c = sdy(gl[1:0]);
`ifdef MUT_DZ_SIGN
		wire [31:0] ds_nxt = {~fa1_r[gl][31], fa1_r[gl][30:0]};
`else
		wire [31:0] ds_nxt = fa1_r[gl];
`endif

		wire is_bc_l = is_bc_raw;
		wire c0_l    = c[0];
		wire c1_l    = c[1];
		wire c2_l    = c[2];

		for (gh = 0; gh < 2; gh = gh + 1) begin : g_half
			wire is_pl_raw_h = (st == S_PL);
			wire pl_c0_raw_h = (st == S_PL) && c[0];
			wire dz_c0_raw_h = (st != S_PL) && (st != S_BC) && c[0];
			wire is_pl_fmb = is_pl_raw_h;
			wire is_bc_fma = is_bc_l;
			wire is_bc_fmb = is_bc_l;
			wire is_bc_fa1 = is_bc_l;
			wire c0_fma    = c0_l;
			wire c1_a      = c1_l;
			wire c2_a      = c2_l;
			wire c1_b      = c1_l;
			wire c2_b      = c2_l;
			wire pl_c0_fmb = pl_c0_raw_h;
			wire dz_c0_fmb = dz_c0_raw_h;

			(* keep = "true" *) wire [15:0] cur_pl_a_s = c2_a ?
				(c1_a ? pl_a[3][16 * gh +: 16] : pl_a[2][16 * gh +: 16]) :
				(c1_a ? pl_a[1][16 * gh +: 16] : pl_a[0][16 * gh +: 16]);
			(* keep = "true" *) wire [15:0] cur_pl_b_s = c2_b ?
				(c1_b ? pl_b[3][16 * gh +: 16] : pl_b[2][16 * gh +: 16]) :
				(c1_b ? pl_b[1][16 * gh +: 16] : pl_b[0][16 * gh +: 16]);

			wire [15:0] fm_a_s = is_bc_fma ? (c0_fma ? v[3][gl][16 * gh +: 16] : v[2][gl][16 * gh +: 16]) :
				(c0_fma ? cur_pl_b_s : cur_pl_a_s);
			wire [15:0] fm_b_s = is_pl_fmb ? (pl_c0_fmb ? r_fj[gl][16 * gh +: 16] : r_fi[gl][16 * gh +: 16]) :
				(is_bc_fmb ? rw[gl][16 * gh +: 16] :
				(dz_c0_fmb ? sdy_c[16 * gh +: 16] : sdx_c[16 * gh +: 16]));
			wire [15:0] fa1_a_s = is_bc_fa1 ? ONE[16 * gh +: 16] : r_t1_curr[gl][16 * gh +: 16];

			wire we_t1_s = !rst_sync && (
				(st == S_PL && (c == 6'd5 || c == 6'd7 || c == 6'd9 || c == 6'd11)) ||
				(st == S_DZ && c == 6'd5));
			wire we_fa2b_s = !rst_sync && (
				(st == S_PL && (c == 6'd11 || c == 6'd13 || c == 6'd15 || c == 6'd17)) ||
				(st == S_BC && c == 6'd9));
			wire fa2b_c0_raw = (c == 6'd11);
			wire fa2b_c1_raw = (c == 6'd13);
			wire fa2b_c2_raw = (c == 6'd15);
			wire fa2b_bc_s = is_bc_l;
			wire fa2b_c0_s = fa2b_c0_raw;
			wire fa2b_c1_s = fa2b_c1_raw;
			wire fa2b_c2_s = fa2b_c2_raw;

			wire [15:0] fa2b_plc_s = fa2b_c0_s ? pl_c[0][16 * gh +: 16] :
				fa2b_c1_s ? pl_c[1][16 * gh +: 16] :
				fa2b_c2_s ? pl_c[2][16 * gh +: 16] : pl_c[3][16 * gh +: 16];
			wire [15:0] fa2b_nxt_s = fa2b_bc_s ? b1[gl][16 * gh +: 16] : fa2b_plc_s;

			wire we_rw_s = !rst_sync && (st == S_DIV) && fd_done[0];
			wire we_b0_s = !rst_sync && (st == S_BC) && (c == 6'd5);
			wire we_b1_s = !rst_sync && (st == S_BC) && (c == 6'd6);
			wire we_b2_s = !rst_sync && (st == S_BC) && (c == 6'd15);
			wire we_ds_s = !rst_sync && (st == S_DZ) && (c == 6'd11);

			always @(posedge clk) begin
				r_fm_a[gl][16 * gh +: 16]  <= fm_a_s;
				r_fm_b[gl][16 * gh +: 16]  <= fm_b_s;
				r_fa1_a[gl][16 * gh +: 16] <= fa1_a_s;
				r_fa1_b[gl][16 * gh +: 16] <= fm_r[gl][16 * gh +: 16];
				r_fa2_a[gl][16 * gh +: 16] <= fa1_r[gl][16 * gh +: 16];
				if (we_t1_s)   r_t1_curr[gl][16 * gh +: 16] <= fm_r[gl][16 * gh +: 16];
				if (we_fa2b_s) r_fa2_b[gl][16 * gh +: 16]   <= fa2b_nxt_s;
				if (we_rw_s)   rw[gl][16 * gh +: 16]        <= fd_r[gl][16 * gh +: 16];
				if (we_b0_s)   b0[gl][16 * gh +: 16]        <= fm_r[gl][16 * gh +: 16];
				if (we_b1_s)   b1[gl][16 * gh +: 16]        <= fm_r[gl][16 * gh +: 16];
				if (we_b2_s)   b2[gl][16 * gh +: 16]        <= fa2_r[gl][16 * gh +: 16];
				if (we_ds_s)   ds[gl][16 * gh +: 16]        <= ds_nxt[16 * gh +: 16];
			end

			for (gp = 0; gp < 4; gp = gp + 1) begin : g_v_plane
				localparam [5:0] V_CYC = 6'd16 + 2 * gp;
				wire we_v_s = !rst_sync && (st == S_PL) && (c == V_CYC);
				always @(posedge clk) begin
					if (we_v_s)
						v[gp][gl][16 * gh +: 16] <= fa2_r[gl][16 * gh +: 16];
				end
			end
		end

		always @(posedge clk) begin
			r_fm_v[gl]    <= fm_v_nxt;
			r_fa1_v[gl]   <= fa1_v_nxt;
			r_fa1_sub[gl] <= is_bc_raw;
			r_fa2_v[gl]   <= fa2_v_nxt;
			r_fa2_sub[gl] <= is_bc_raw;
		end

		am_fp_mul #(.LAT(4)) u_fmul (
			.clk(clk), .rst_n(rst_n),
			.i_valid(r_fm_v[gl]), .i_a(r_fm_a[gl]), .i_b(r_fm_b[gl]),
			.o_valid(fm_o[gl]), .o_r(fm_r[gl])
		);

		am_fp_add #(.LAT(4)) u_fadd1 (
			.clk(clk), .rst_n(rst_n),
			.i_valid(r_fa1_v[gl]), .i_a(r_fa1_a[gl]), .i_b(r_fa1_b[gl]),
			.i_sub(r_fa1_sub[gl]), .o_valid(fa1_o[gl]), .o_r(fa1_r[gl])
		);

		am_fp_add #(.LAT(4)) u_fadd2 (
			.clk(clk), .rst_n(rst_n),
			.i_valid(r_fa2_v[gl]), .i_a(r_fa2_a[gl]), .i_b(r_fa2_b[gl]),
			.i_sub(r_fa2_sub[gl]), .o_valid(fa2_o[gl]), .o_r(fa2_r[gl])
		);
	end
	endgenerate

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

	always @(posedge clk) begin
		o_done <= 1'b0;
		div_start <= 1'b0;
		if (rst_sync) begin
			st <= S_IDLE;
			c <= 6'd0;
			r_osel <= 12'd0;
		end else case (st)
		S_IDLE: begin
			c <= 6'd0;
			if (i_start) begin
				r_osel <= i_osel;
				st <= S_PREP0;
			end else if (i_dz) begin
				st <= S_DZ;
			end
		end

		S_PREP0: begin
			st <= S_PREP1;
		end

		S_PREP1: begin
			c <= 6'd0;
			st <= S_PREP2;
		end

		S_PREP2: begin
			if (c == 6'd5) begin
				c <= 6'd0;
				st <= S_PL;
			end else begin
				c <= c1;
			end
		end

		S_PL: begin
			c <= c1;
			if (c == 6'd22) begin
				div_start <= 1'b1;
				c <= 6'd0;
				st <= S_DIV;
			end
		end

		S_DIV: begin
			/* 4 Parallel Dividers running */
			if (fd_done[0]) begin
				c <= 6'd0;
				st <= S_BC;
			end
		end

		S_BC: begin
			c <= c1;
			if (c == 6'd15) begin
				o_done <= 1'b1;
				st <= S_IDLE;
			end
		end

		S_DZ: begin
			c <= c1;
			if (c == 6'd11) begin
				o_done <= 1'b1;
				st <= S_IDLE;
			end
		end

		default:
			st <= S_IDLE;
		endcase
	end

	wire unused_ok = &{1'b0,
		c1_co_unused, ij_carry_unused,
		fm_o[0], fm_o[1], fm_o[2], fm_o[3],
		fa1_o[0], fa1_o[1], fa1_o[2], fa1_o[3],
		fa2_o[0], fa2_o[1], fa2_o[2], fa2_o[3],
		fd_busy[0], fd_busy[1], fd_busy[2], fd_busy[3],
		fd_done[1], fd_done[2], fd_done[3]
	};
endmodule

`default_nettype wire
