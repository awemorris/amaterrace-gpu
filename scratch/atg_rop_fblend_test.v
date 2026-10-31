/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_fblend: the fp32 blend path of the render output: blending, the
 * write mask and the packing of one beat (four pixels of one attachment)
 * for the colour formats that the 8-bit path does not take: the sRGB
 * formats (VkFormat 43, 50, 57), A2B10G10R10_UNORM (64) and R16, R16G16,
 * R16G16B16A16_SFLOAT (76, 83, 97).
 *
 * 5-stage stream pipeline (throughput: 1 beat per cycle, latency: 5 cycles):
 *   Stage 1 (DEC): Unpack destination (atg_fmt_comp) and clamp inputs to [0, 1]
 *   Stage 2 (FAC): Factor generation (fval, 1.0 - x via am_fp_add)
 *   Stage 3A (MUL): Parallel fp32 multiplications P = s * Fs, Q = d * Fd
 *   Stage 3B (ALU): Parallel fp32 combine (P +/- Q, fmin, fmax)
 *   Stage 4 (ENC): sRGB encode (unrolled decision tree) & pack (atg_fmt_pack)
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_fblend (
	input wire clk,
	input wire rst_n,
	input wire i_valid,
	output wire i_ready,
	input wire [3:0] i_lanes,
	input wire [511:0] i_src,
	input wire [255:0] i_dst,
	input wire [7:0] i_fmt,
	input wire [22:0] i_blend,
	input wire [127:0] i_const,
	input wire [3:0] i_wm,
	output wire o_valid,
	input wire o_ready,
	output wire [255:0] o_raw,
	output wire [255:0] o_keep
);
	`include "atg_fmt_info.vh"
	`include "atg_srgb.vh"
	`include "atg_rop_fdec.vh"

	localparam [31:0] ONE = 32'h3F800000;
	localparam [55:0] PFF = {8'd97, 8'd83, 8'd76, 8'd64, 8'd57, 8'd50, 8'd43};

	/* Pipeline control: stall when output valid and downstream not ready */
	wire pipe_stall = o_valid && !o_ready;
	wire pipe_en = !pipe_stall;

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire rst_sync;
	LUT1 #(.INIT(2'b01)) u_rst_inv (.I0(rst_n), .O(rst_sync));
	(* keep = "true", dont_touch = "true" *) wire rst_n_net;
	LUT1 #(.INIT(2'b10)) u_rst_buf (.I0(rst_n), .O(rst_n_net));

	wire [7:0] pe_grp;
	genvar g_pe;
	generate
	for (g_pe = 0; g_pe < 8; g_pe = g_pe + 1) begin : g_pe_top
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_g (.I0(pipe_en), .O(pe_grp[g_pe]));
	end
	endgenerate

	/* Multipliers: 32 instances split across pe_grp[0] and pe_grp[1] */
	wire [3:0] pe_mul [0:3];
	genvar g_mull, g_mulc;
	generate
	for (g_mull = 0; g_mull < 4; g_mull = g_mull + 1) begin : g_pe_mull
		for (g_mulc = 0; g_mulc < 4; g_mulc = g_mulc + 1) begin : g_pe_mulc
			localparam G_IDX = g_mull / 2;
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_m (
				.I0(pe_grp[G_IDX]), .O(pe_mul[g_mull][g_mulc])
			);
		end
	end
	endgenerate

	wire pe_s0_ctrl, pe_s1_ctrl, pe_s2_ctrl, pe_s3_ctrl, pe_s4_ctrl;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c0 (.I0(pe_grp[2]), .O(pe_s0_ctrl));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c1 (.I0(pe_grp[2]), .O(pe_s1_ctrl));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c2 (.I0(pe_grp[2]), .O(pe_s2_ctrl));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c3 (.I0(pe_grp[2]), .O(pe_s3_ctrl));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c4 (.I0(pe_grp[2]), .O(pe_s4_ctrl));

	wire [3:0] pe_s0_lane;
	wire [3:0] pe_s1_lane;
	wire [3:0] pe_s2_lane;
	wire [3:0] pe_s3_lane;
	wire [3:0] pe_s4_lane;
	genvar g_pe_l;
	generate
	for (g_pe_l = 0; g_pe_l < 4; g_pe_l = g_pe_l + 1) begin : g_pe_lane_buf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_l0 (.I0(pe_grp[3]), .O(pe_s0_lane[g_pe_l]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_l1 (.I0(pe_grp[4]), .O(pe_s1_lane[g_pe_l]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_l2 (.I0(pe_grp[5]), .O(pe_s2_lane[g_pe_l]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_l3 (.I0(pe_grp[6]), .O(pe_s3_lane[g_pe_l]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_l4 (.I0(pe_grp[7]), .O(pe_s4_lane[g_pe_l]));
	end
	endgenerate
`else
	wire rst_sync = !rst_n;
	wire rst_n_net = rst_n;
	wire [3:0] pe_mul [0:3];
	genvar g_mull, g_mulc;
	generate
	for (g_mull = 0; g_mull < 4; g_mull = g_mull + 1) begin : g_pe_mull
		for (g_mulc = 0; g_mulc < 4; g_mulc = g_mulc + 1) begin : g_pe_mulc
			assign pe_mul[g_mull][g_mulc] = pipe_en;
		end
	end
	endgenerate

	wire pe_s0_ctrl = pipe_en;
	wire pe_s1_ctrl = pipe_en;
	wire pe_s2_ctrl = pipe_en;
	wire pe_s3_ctrl = pipe_en;
	wire pe_s4_ctrl = pipe_en;
	wire [3:0] pe_s0_lane = {4{pipe_en}};
	wire [3:0] pe_s1_lane = {4{pipe_en}};
	wire [3:0] pe_s2_lane = {4{pipe_en}};
	wire [3:0] pe_s3_lane = {4{pipe_en}};
	wire [3:0] pe_s4_lane = {4{pipe_en}};
`endif

	(* max_fanout = 16 *) reg r_ready;
	always @(posedge clk) begin
		if (rst_sync)
			r_ready <= 1'b1;
		else
			r_ready <= !pipe_stall;
	end
	assign i_ready = r_ready;

	/* Functions for fp32 classification and clamping */
	function [31:0] c01;
		input [31:0] x;
		c01 = (x[30:23] == 8'hFF && x[22:0] != 23'd0) || x[31] ? 32'd0 :
			x > ONE ? ONE : x;
	endfunction

	function fle;	/* a <= b, -0 = +0; 0 with a NaN */
		input [31:0] a, b;
		reg [32:0] ka, kb;
		begin
			ka = {2'd0, a[30:0]};
			kb = {2'd0, b[30:0]};
			fle = !(a[30:23] == 8'hFF && a[22:0] != 23'd0) &&
				!(b[30:23] == 8'hFF && b[22:0] != 23'd0) &&
				(a[31] ? (b[31] ? ka >= kb : 1'b1) : (b[31] ? ka == 0 && kb == 0 : ka <= kb));
		end
	endfunction

	function isnan;
		input [30:0] a;
		isnan = a[30:23] == 8'hFF && a[22:0] != 23'd0;
	endfunction

	function [31:0] fmin;
		input [31:0] a, b;
		fmin = isnan(a[30:0]) || isnan(b[30:0]) ? 32'h7FC00000 : fle(a, b) ? a : b;
	endfunction

	function [31:0] fmax;
		input [31:0] a, b;
		fmax = isnan(a[30:0]) || isnan(b[30:0]) ? 32'h7FC00000 : fle(b, a) ? a : b;
	endfunction

	function [31:0] fval;
		input [3:0] f;
		input alpha;
		input [31:0] sc, dc, sa, da, kcc, ka;
		case (f)
		4'd1: fval = ONE;
		4'd2, 4'd3: fval = sc;
		4'd4, 4'd5: fval = dc;
		4'd6, 4'd7: fval = sa;
		4'd8, 4'd9, 4'd14: fval = alpha && f == 4'd14 ? ONE : da;
		4'd10, 4'd11: fval = kcc;
		4'd12, 4'd13: fval = ka;
		default: fval = 32'd0;
		endcase
	endfunction

	function needs_sub;
		input [3:0] f;
		input alpha;
		needs_sub = (f[0] && f >= 4'd3 && f <= 4'd13) || (f == 4'd14 && !alpha);
	endfunction

	/* =========================================================================
	 * STAGE 1: Unpack Destination & Clamp Inputs (Latency: 1 cycle)
	 * ========================================================================= */
	wire is_srgb0 = i_fmt == 8'd43 || i_fmt == 8'd50 || i_fmt == 8'd57;
	wire fixed0 = is_srgb0 || i_fmt == 8'd64;

	wire [127:0] d_unpacked0 [0:3];
	reg d_known0;
	genvar gl, gc;

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_dec_l
		wire [63:0] d_raw_l = i_dst[64 * gl +: 64];
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_dec_c
			assign d_unpacked0[gl][32 * gc +: 32] = atg_rop_fblend_unpack_ch(i_fmt, gc[1:0], d_raw_l);
		end
	end
	endgenerate

	integer uf_k;
	always @(*) begin
		d_known0 = 1'b0;
		for (uf_k = 0; uf_k < 7; uf_k = uf_k + 1)
			if (i_fmt == PFF[8 * uf_k +: 8])
				d_known0 = 1'b1;
	end

	/* =========================================================================
	 * STAGE 0: Unpack Destination & Clamp Inputs (Latency: 1 cycle)
	 * Registers destination, source, and state to isolate input CARRY4 chains
	 * ========================================================================= */
	wire [127:0] s_unclamped_w [0:3];
	wire [127:0] d_unpacked_w [0:3];
	wire [127:0] kc_w;

	genvar gl_in, gc_in;
	generate
	for (gl_in = 0; gl_in < 4; gl_in = gl_in + 1) begin : g_in_l
		for (gc_in = 0; gc_in < 4; gc_in = gc_in + 1) begin : g_in_c
			assign s_unclamped_w[gl_in][32 * gc_in +: 32] = fixed0 ?
				c01(i_src[128 * gl_in + 32 * gc_in +: 32]) :
				i_src[128 * gl_in + 32 * gc_in +: 32];
			assign d_unpacked_w[gl_in][32 * gc_in +: 32] = d_known0 ?
				d_unpacked0[gl_in][32 * gc_in +: 32] : 32'd0;
		end
	end
	for (gc_in = 0; gc_in < 4; gc_in = gc_in + 1) begin : g_in_kc
		assign kc_w[32 * gc_in +: 32] = fixed0 ? c01(i_const[32 * gc_in +: 32]) : i_const[32 * gc_in +: 32];
	end
	endgenerate

	reg [127:0] s0 [0:3];
	reg [127:0] d0 [0:3];
	reg [127:0] kc0;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt0_r;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm0_r, lanes0_r;
	reg v0_r, known0_r;

`ifdef SYNTH_KINTEX7
	(* equivalent_register_removal = "no" *) reg [22:0] blend0_l [0:3];
	genvar g_bl0;
	generate
	for (g_bl0 = 0; g_bl0 < 4; g_bl0 = g_bl0 + 1) begin : g_pipe_bl0
		always @(posedge clk) begin
			if (rst_sync)
				blend0_l[g_bl0] <= 23'd0;
			else if (pe_s0_lane[g_bl0])
				blend0_l[g_bl0] <= i_blend;
		end
	end
	endgenerate
	wire [22:0] blend0 = blend0_l[0];

	wire pe_s0_ctrl_a, pe_s0_ctrl_b, pe_s0_ctrl_c, pe_s0_ctrl_d;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c0a (.I0(pe_s0_ctrl), .O(pe_s0_ctrl_a));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c0b (.I0(pe_s0_ctrl), .O(pe_s0_ctrl_b));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c0c (.I0(pe_s0_ctrl), .O(pe_s0_ctrl_c));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c0d (.I0(pe_s0_ctrl), .O(pe_s0_ctrl_d));

	wire [7:0] pe_s0_kc_leaf;
	genvar g_kc;
	generate
	for (g_kc = 0; g_kc < 8; g_kc = g_kc + 1) begin : g_buf_kc
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_kc_b (
			.I0(pe_s0_ctrl_c), .O(pe_s0_kc_leaf[g_kc])
		);
		always @(posedge clk) begin
			if (rst_sync)
				kc0[16 * g_kc +: 16] <= 16'd0;
			else if (pe_s0_kc_leaf[g_kc])
				kc0[16 * g_kc +: 16] <= kc_w[16 * g_kc +: 16];
		end
	end
	endgenerate

	always @(posedge clk) begin
		if (rst_sync) begin
			wm0_r <= 4'd0;
			lanes0_r <= 4'd0;
		end else if (pe_s0_ctrl_b) begin
			wm0_r <= i_wm;
			lanes0_r <= i_lanes;
		end
	end

	always @(posedge clk) begin
		if (rst_sync) begin
			v0_r <= 1'b0;
			known0_r <= 1'b0;
			fmt0_r <= 8'd0;
		end else if (pe_s0_ctrl_d) begin
			v0_r <= i_valid;
			known0_r <= d_known0;
			fmt0_r <= i_fmt;
		end
	end
`else
	reg [22:0] blend0;
	wire [22:0] blend0_l [0:3];
	genvar g_bl0;
	generate
	for (g_bl0 = 0; g_bl0 < 4; g_bl0 = g_bl0 + 1) begin : g_pipe_bl0
		assign blend0_l[g_bl0] = blend0;
	end
	endgenerate

	always @(posedge clk) begin
		if (rst_sync) begin
			v0_r <= 1'b0;
			known0_r <= 1'b0;
			blend0 <= 23'd0;
			fmt0_r <= 8'd0;
			wm0_r <= 4'd0;
			lanes0_r <= 4'd0;
			kc0 <= 128'd0;
		end else if (pe_s0_ctrl) begin
			v0_r <= i_valid;
			known0_r <= d_known0;
			blend0 <= i_blend;
			fmt0_r <= i_fmt;
			wm0_r <= i_wm;
			lanes0_r <= i_lanes;
			kc0 <= kc_w;
		end
	end
`endif

`ifdef SYNTH_KINTEX7
	wire [15:0] pe_s0_leaf [0:3];
	genvar g_s0, g_s0_c;
	generate
	for (g_s0 = 0; g_s0 < 4; g_s0 = g_s0 + 1) begin : g_pipe_s0
		for (g_s0_c = 0; g_s0_c < 16; g_s0_c = g_s0_c + 1) begin : g_buf_s0
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_s0_b (
				.I0(pe_s0_lane[g_s0]), .O(pe_s0_leaf[g_s0][g_s0_c])
			);
		end
		for (g_s0_c = 0; g_s0_c < 8; g_s0_c = g_s0_c + 1) begin : g_reg_s0
			always @(posedge clk) begin
				if (rst_sync) begin
					s0[g_s0][16 * g_s0_c +: 16] <= 16'd0;
					d0[g_s0][16 * g_s0_c +: 16] <= 16'd0;
				end else begin
					if (pe_s0_leaf[g_s0][g_s0_c])
						s0[g_s0][16 * g_s0_c +: 16] <= s_unclamped_w[g_s0][16 * g_s0_c +: 16];
					if (pe_s0_leaf[g_s0][8 + g_s0_c])
						d0[g_s0][16 * g_s0_c +: 16] <= d_unpacked_w[g_s0][16 * g_s0_c +: 16];
				end
			end
		end
	end
	endgenerate
`else
	genvar g_s0;
	generate
	for (g_s0 = 0; g_s0 < 4; g_s0 = g_s0 + 1) begin : g_pipe_s0
		always @(posedge clk) begin
			if (rst_sync) begin
				s0[g_s0] <= 128'd0;
				d0[g_s0] <= 128'd0;
			end else if (pe_s0_lane[g_s0]) begin
				s0[g_s0] <= s_unclamped_w[g_s0];
				d0[g_s0] <= d_unpacked_w[g_s0];
			end
		end
	end
	endgenerate
`endif

	/* =========================================================================
	 * STAGE 1: Factor Subtraction Term Launch (Latency: 1 cycle inside atg_rop_sub1)
	 * Operates from Stage 0 registered values (s0, d0, kc0, blend0_l), registering at Edge 2
	 * ========================================================================= */
	wire [31:0] sub_s_res [0:3][0:3];
	wire [31:0] sub_d_res [0:3][0:3];

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_fac_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_fac_c
			wire is_alpha = (gc == 3);
			wire [3:0] f_s1 = is_alpha ? blend0_l[gl][15:12] : blend0_l[gl][4:1];
			wire [3:0] f_d1 = is_alpha ? blend0_l[gl][19:16] : blend0_l[gl][8:5];

			wire [31:0] sc1 = s0[gl][32 * gc +: 32];
			wire [31:0] dc1 = d0[gl][32 * gc +: 32];
			wire [31:0] sa1 = s0[gl][127:96];
			wire [31:0] da1 = d0[gl][127:96];
			wire [31:0] kcc1 = kc0[32 * gc +: 32];
			wire [31:0] ka1 = kc0[127:96];

			wire [31:0] xs1 = fval(f_s1, is_alpha, sc1, dc1, sa1, da1, kcc1, ka1);
			wire [31:0] xd1 = fval(f_d1, is_alpha, sc1, dc1, sa1, da1, kcc1, ka1);

			atg_rop_sub1 #(.LAT(1)) u_sub_s (.clk(clk), .rst_n(rst_n_net), .en(pe_s1_lane[gl]), .i_x(xs1), .o_r(sub_s_res[gl][gc]));
			atg_rop_sub1 #(.LAT(1)) u_sub_d (.clk(clk), .rst_n(rst_n_net), .en(pe_s1_lane[gl]), .i_x(xd1), .o_r(sub_d_res[gl][gc]));
		end
	end
	endgenerate

	/* =========================================================================
	 * STAGE 1 -> 2: Pipeline Registers (Latency: 1 cycle, aligns with sub_s/d_res)
	 * ========================================================================= */
	reg [127:0] s2 [0:3];
	reg [127:0] d2 [0:3];
	reg [127:0] kc2;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt2;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm2, lanes2;
	reg v2, known2;

`ifdef SYNTH_KINTEX7
	(* equivalent_register_removal = "no" *) reg [22:0] blend2_l [0:3];
	genvar g_bl2;
	generate
	for (g_bl2 = 0; g_bl2 < 4; g_bl2 = g_bl2 + 1) begin : g_pipe_bl2
		always @(posedge clk) begin
			if (rst_sync)
				blend2_l[g_bl2] <= 23'd0;
			else if (pe_s1_lane[g_bl2])
				blend2_l[g_bl2] <= blend0_l[g_bl2];
		end
	end
	endgenerate

	wire pe_s2a_ctrl_a, pe_s2a_ctrl_b;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c2aa (.I0(pe_s1_ctrl), .O(pe_s2a_ctrl_a));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c2ab (.I0(pe_s1_ctrl), .O(pe_s2a_ctrl_b));

	always @(posedge clk) begin
		if (rst_sync) begin
			v2 <= 1'b0;
			known2 <= 1'b0;
			fmt2 <= 8'd0;
			kc2 <= 128'd0;
		end else if (pe_s2a_ctrl_a) begin
			v2 <= v0_r;
			known2 <= known0_r;
			fmt2 <= fmt0_r;
			kc2 <= kc0;
		end
	end

	always @(posedge clk) begin
		if (rst_sync) begin
			wm2 <= 4'd0;
			lanes2 <= 4'd0;
		end else if (pe_s2a_ctrl_b) begin
			wm2 <= wm0_r;
			lanes2 <= lanes0_r;
		end
	end

	wire [15:0] pe_s2a_leaf [0:3];
	genvar g_s2a, g_s2a_b, g_s2a_k;
	generate
	for (g_s2a = 0; g_s2a < 4; g_s2a = g_s2a + 1) begin : g_pipe_s2a
		for (g_s2a_b = 0; g_s2a_b < 16; g_s2a_b = g_s2a_b + 1) begin : g_leaf_s2a
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_l2a (
				.I0(pe_s1_lane[g_s2a]), .O(pe_s2a_leaf[g_s2a][g_s2a_b])
			);
		end
		for (g_s2a_k = 0; g_s2a_k < 8; g_s2a_k = g_s2a_k + 1) begin : g_reg_s2a
			always @(posedge clk) begin
				if (rst_sync) begin
					s2[g_s2a][16 * g_s2a_k +: 16] <= 16'd0;
					d2[g_s2a][16 * g_s2a_k +: 16] <= 16'd0;
				end else begin
					if (pe_s2a_leaf[g_s2a][g_s2a_k])
						s2[g_s2a][16 * g_s2a_k +: 16] <= s0[g_s2a][16 * g_s2a_k +: 16];
					if (pe_s2a_leaf[g_s2a][8 + g_s2a_k])
						d2[g_s2a][16 * g_s2a_k +: 16] <= d0[g_s2a][16 * g_s2a_k +: 16];
				end
			end
		end
	end
	endgenerate
`else
	reg [22:0] blend2;
	wire [22:0] blend2_l [0:3];
	genvar g_bl2;
	generate
	for (g_bl2 = 0; g_bl2 < 4; g_bl2 = g_bl2 + 1) begin : g_pipe_bl2
		assign blend2_l[g_bl2] = blend2;
	end
	endgenerate

	always @(posedge clk) begin
		if (rst_sync) begin
			v2 <= 1'b0;
			known2 <= 1'b0;
			blend2 <= 23'd0;
			fmt2 <= 8'd0;
			wm2 <= 4'd0;
			lanes2 <= 4'd0;
			kc2 <= 128'd0;
		end else if (pe_s1_ctrl) begin
			v2 <= v0_r;
			known2 <= known0_r;
			blend2 <= blend0;
			fmt2 <= fmt0_r;
			wm2 <= wm0_r;
			lanes2 <= lanes0_r;
			kc2 <= kc0;
		end
	end

	genvar g_s2a;
	generate
	for (g_s2a = 0; g_s2a < 4; g_s2a = g_s2a + 1) begin : g_pipe_s2a
		always @(posedge clk) begin
			if (rst_sync) begin
				s2[g_s2a] <= 128'd0;
				d2[g_s2a] <= 128'd0;
			end else if (pe_s1_lane[g_s2a]) begin
				s2[g_s2a] <= s0[g_s2a];
				d2[g_s2a] <= d0[g_s2a];
			end
		end
	end
	endgenerate
`endif

	/* =========================================================================
	 * STAGE 2: Factor Combination, Operand Selection & Multiplier Launch (Latency: 2 cycles)
	 * Operates on aligned sub_s_res / sub_d_res and registered Stage 1 values (s2, d2, kc2, blend2_l)
	 * Launches directly into 2-cycle multipliers u_mul_p and u_mul_q
	 * ========================================================================= */
	wire [127:0] fs_w [0:3];
	wire [127:0] fd_w [0:3];
	wire [127:0] p_in_a_w [0:3];
	wire [127:0] p_in_b_w [0:3];
	wire [127:0] q_in_a_w [0:3];
	wire [127:0] q_in_b_w [0:3];
	wire [127:0] bypass2_w [0:3];
	wire [3:0] sub_sel2_w;
	wire [3:0] use_pq2_w;

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_fac2_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_fac2_c
			wire is_alpha = (gc == 3);
			wire [3:0] f_s2 = is_alpha ? blend2_l[gl][15:12] : blend2_l[gl][4:1];
			wire [3:0] f_d2 = is_alpha ? blend2_l[gl][19:16] : blend2_l[gl][8:5];
			wire [2:0] op2_c = is_alpha ? blend2_l[gl][22:20] : blend2_l[gl][11:9];

			wire [31:0] sc2 = s2[gl][32 * gc +: 32];
			wire [31:0] dc2 = d2[gl][32 * gc +: 32];
			wire [31:0] sa2 = s2[gl][127:96];
			wire [31:0] da2 = d2[gl][127:96];
			wire [31:0] kcc2 = kc2[32 * gc +: 32];
			wire [31:0] ka2 = kc2[127:96];

			wire [31:0] xs2 = fval(f_s2, is_alpha, sc2, dc2, sa2, da2, kcc2, ka2);
			wire [31:0] xd2 = fval(f_d2, is_alpha, sc2, dc2, sa2, da2, kcc2, ka2);

			wire [31:0] fsc2 = needs_sub(f_s2, is_alpha) ?
				(f_s2 == 4'd14 ? fmin(sa2, sub_s_res[gl][gc]) : sub_s_res[gl][gc]) : xs2;
			wire [31:0] fdc2 = needs_sub(f_d2, is_alpha) ?
				(f_d2 == 4'd14 ? fmin(sa2, sub_d_res[gl][gc]) : sub_d_res[gl][gc]) : xd2;

			assign fs_w[gl][32 * gc +: 32] = fsc2;
			assign fd_w[gl][32 * gc +: 32] = fdc2;

			wire is_rev = (op2_c == 3'd2);
			assign p_in_a_w[gl][32 * gc +: 32] = is_rev ? dc2 : sc2;
			assign p_in_b_w[gl][32 * gc +: 32] = is_rev ? fdc2 : fsc2;
			assign q_in_a_w[gl][32 * gc +: 32] = is_rev ? sc2 : dc2;
			assign q_in_b_w[gl][32 * gc +: 32] = is_rev ? fsc2 : fdc2;

			wire [31:0] min_v = fmin(sc2, dc2);
			wire [31:0] max_v = fmax(sc2, dc2);
			assign bypass2_w[gl][32 * gc +: 32] = (!blend2_l[gl][0]) ? sc2 :
				(op2_c == 3'd3) ? min_v : max_v;
		end
	end
	for (gc = 0; gc < 4; gc = gc + 1) begin : g_sub_sel
		wire is_alpha = (gc == 3);
		wire [2:0] op2_c = is_alpha ? blend2_l[0][22:20] : blend2_l[0][11:9];
		assign sub_sel2_w[gc] = (op2_c == 3'd1 || op2_c == 3'd2);
		assign use_pq2_w[gc] = blend2_l[0][0] && (op2_c != 3'd3 && op2_c != 3'd4);
	end
	endgenerate

	wire [127:0] p_w [0:3];
	wire [127:0] q_w [0:3];

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_mul_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_mul_c
			wire [31:0] p_res, q_res;
			atg_rop_fmul u_mul_p (.clk(clk), .rst_n(rst_n_net), .en(pe_mul[gl][gc]),
				.i_a(p_in_a_w[gl][32 * gc +: 32]), .i_b(p_in_b_w[gl][32 * gc +: 32]),
				.o_r(p_res));
			atg_rop_fmul u_mul_q (.clk(clk), .rst_n(rst_n_net), .en(pe_mul[gl][gc]),
				.i_a(q_in_a_w[gl][32 * gc +: 32]), .i_b(q_in_b_w[gl][32 * gc +: 32]),
				.o_r(q_res));
			assign p_w[gl][32 * gc +: 32] = p_res;
			assign q_w[gl][32 * gc +: 32] = q_res;
		end
	end
	endgenerate

	/* Pipeline matching registers (2 cycles delay matching multiplier) */
	reg [127:0] bypass1_m [0:3];
	reg [3:0] sub_sel1_m;
	reg [3:0] use_pq1_m;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt1_m;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm1_m, lanes1_m;
	reg v1_m, known1_m;

	reg [127:0] p3 [0:3];
	reg [127:0] q3 [0:3];
	reg [127:0] bypass3 [0:3];
	reg [3:0] sub_sel3;
	(* equivalent_register_removal = "no" *) reg [3:0] use_pq3_lo [0:3];
	(* equivalent_register_removal = "no" *) reg [3:0] use_pq3_hi [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt3;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm3, lanes3;
	reg v3, known3;

`ifdef SYNTH_KINTEX7
	wire pe_s2_ctrl_a, pe_s2_ctrl_b, pe_s2_ctrl_c, pe_s2_ctrl_d;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c2a (.I0(pe_s2_ctrl), .O(pe_s2_ctrl_a));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c2b (.I0(pe_s2_ctrl), .O(pe_s2_ctrl_b));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c2c (.I0(pe_s2_ctrl), .O(pe_s2_ctrl_c));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c2d (.I0(pe_s2_ctrl), .O(pe_s2_ctrl_d));

	always @(posedge clk) begin
		if (rst_sync) begin
			v1_m <= 1'b0;
			known1_m <= 1'b0;
			fmt1_m <= 8'd0;
			wm1_m <= 4'd0;
		end else if (pe_s2_ctrl_a) begin
			v1_m <= v2;
			known1_m <= known2;
			fmt1_m <= fmt2;
			wm1_m <= wm2;
		end
	end

	always @(posedge clk) begin
		if (rst_sync) begin
			lanes1_m <= 4'd0;
			sub_sel1_m <= 4'd0;
			use_pq1_m <= 4'd0;
		end else if (pe_s2_ctrl_b) begin
			lanes1_m <= lanes2;
			sub_sel1_m <= sub_sel2_w;
			use_pq1_m <= use_pq2_w;
		end
	end

	always @(posedge clk) begin
		if (rst_sync) begin
			v3 <= 1'b0;
			known3 <= 1'b0;
			fmt3 <= 8'd0;
			wm3 <= 4'd0;
		end else if (pe_s2_ctrl_c) begin
			v3 <= v1_m;
			known3 <= known1_m;
			fmt3 <= fmt1_m;
			wm3 <= wm1_m;
		end
	end

	always @(posedge clk) begin
		if (rst_sync) begin
			lanes3 <= 4'd0;
			sub_sel3 <= 4'd0;
		end else if (pe_s2_ctrl_d) begin
			lanes3 <= lanes1_m;
			sub_sel3 <= sub_sel1_m;
		end
	end

	wire [2:0] pe_s2_mid [0:3];
	wire [32:0] pe_s2_leaf [0:3];
	genvar g_s2, g_s2_m, g_s2_b, g_s2_k;
	generate
	for (g_s2 = 0; g_s2 < 4; g_s2 = g_s2 + 1) begin : g_pipe_s2
		for (g_s2_m = 0; g_s2_m < 3; g_s2_m = g_s2_m + 1) begin : g_mid_s2
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_m2 (
				.I0(pe_s2_lane[g_s2]), .O(pe_s2_mid[g_s2][g_s2_m])
			);
		end
		for (g_s2_b = 0; g_s2_b < 33; g_s2_b = g_s2_b + 1) begin : g_leaf_s2
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_l2 (
				.I0(pe_s2_mid[g_s2][g_s2_b / 11]), .O(pe_s2_leaf[g_s2][g_s2_b])
			);
		end
		always @(posedge clk) begin
			if (rst_sync) begin
				use_pq3_lo[g_s2] <= 4'd0;
				use_pq3_hi[g_s2] <= 4'd0;
			end else if (pe_s2_leaf[g_s2][32]) begin
				use_pq3_lo[g_s2] <= use_pq1_m;
				use_pq3_hi[g_s2] <= use_pq1_m;
			end
		end
		for (g_s2_k = 0; g_s2_k < 8; g_s2_k = g_s2_k + 1) begin : g_reg_s2
			always @(posedge clk) begin
				if (rst_sync) begin
					bypass1_m[g_s2][16 * g_s2_k +: 16] <= 16'd0;
					p3[g_s2][16 * g_s2_k +: 16] <= 16'd0;
					q3[g_s2][16 * g_s2_k +: 16] <= 16'd0;
					bypass3[g_s2][16 * g_s2_k +: 16] <= 16'd0;
				end else begin
					if (pe_s2_leaf[g_s2][g_s2_k])
						bypass1_m[g_s2][16 * g_s2_k +: 16] <= bypass2_w[g_s2][16 * g_s2_k +: 16];
					if (pe_s2_leaf[g_s2][8 + g_s2_k])
						p3[g_s2][16 * g_s2_k +: 16] <= p_w[g_s2][16 * g_s2_k +: 16];
					if (pe_s2_leaf[g_s2][16 + g_s2_k])
						q3[g_s2][16 * g_s2_k +: 16] <= q_w[g_s2][16 * g_s2_k +: 16];
					if (pe_s2_leaf[g_s2][24 + g_s2_k])
						bypass3[g_s2][16 * g_s2_k +: 16] <= bypass1_m[g_s2][16 * g_s2_k +: 16];
				end
			end
		end
	end
	endgenerate
`else
	always @(posedge clk) begin
		if (rst_sync) begin
			v1_m <= 1'b0;
			known1_m <= 1'b0;
			fmt1_m <= 8'd0;
			wm1_m <= 4'd0;
			lanes1_m <= 4'd0;
			sub_sel1_m <= 4'd0;
			use_pq1_m <= 4'd0;
			v3 <= 1'b0;
			known3 <= 1'b0;
			fmt3 <= 8'd0;
			wm3 <= 4'd0;
			lanes3 <= 4'd0;
			sub_sel3 <= 4'd0;
		end else if (pe_s2_ctrl) begin
			v1_m <= v2;
			known1_m <= known2;
			fmt1_m <= fmt2;
			wm1_m <= wm2;
			lanes1_m <= lanes2;
			sub_sel1_m <= sub_sel2_w;
			use_pq1_m <= use_pq2_w;

			v3 <= v1_m;
			known3 <= known1_m;
			fmt3 <= fmt1_m;
			wm3 <= wm1_m;
			lanes3 <= lanes1_m;
			sub_sel3 <= sub_sel1_m;
		end
	end

	genvar g_s2;
	generate
	for (g_s2 = 0; g_s2 < 4; g_s2 = g_s2 + 1) begin : g_pipe_s2
		always @(posedge clk) begin
			if (rst_sync) begin
				use_pq3_lo[g_s2] <= 4'd0;
				use_pq3_hi[g_s2] <= 4'd0;
				bypass1_m[g_s2] <= 128'd0;
				p3[g_s2] <= 128'd0;
				q3[g_s2] <= 128'd0;
				bypass3[g_s2] <= 128'd0;
			end else if (pe_s2_lane[g_s2]) begin
				bypass1_m[g_s2] <= bypass2_w[g_s2];
				use_pq3_lo[g_s2] <= use_pq1_m;
				use_pq3_hi[g_s2] <= use_pq1_m;
				p3[g_s2] <= p_w[g_s2];
				q3[g_s2] <= q_w[g_s2];
				bypass3[g_s2] <= bypass1_m[g_s2];
			end
		end
	end
	endgenerate
`endif
	/* =========================================================================
	 * STAGE 3B: fp32 Combine P +/- Q, Min/Max (Latency: 1 cycle)
	 * ========================================================================= */
	wire [127:0] res_w [0:3];

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_alu_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_alu_c
			wire [31:0] pq_res;
			wire add_ov_unused;
			atg_rop_fadd #(.LAT(0)) u_add_pq (.clk(clk), .rst_n(rst_n_net), .i_valid(1'b1),
				.i_a(p3[gl][32 * gc +: 32]), .i_b(q3[gl][32 * gc +: 32]), .i_sub(sub_sel3[gc]),
				.o_valid(add_ov_unused), .o_r(pq_res));

			assign res_w[gl][32 * gc +: 16] = use_pq3_lo[gl][gc] ? pq_res[15:0] : bypass3[gl][32 * gc +: 16];
			assign res_w[gl][32 * gc + 16 +: 16] = use_pq3_hi[gl][gc] ? pq_res[31:16] : bypass3[gl][32 * gc + 16 +: 16];
		end
	end
	endgenerate

	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [127:0] res4 [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt4_l [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm4_l [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] lanes4;
	reg v4, known4;

	always @(posedge clk) begin
		if (rst_sync) begin
			v4 <= 1'b0;
			known4 <= 1'b0;
			lanes4 <= 4'd0;
		end else if (pe_s3_ctrl) begin
			v4 <= v3;
			known4 <= known3;
			lanes4 <= lanes3;
		end
	end

`ifdef SYNTH_KINTEX7
	wire [8:0] pe_s3_leaf [0:3];
	genvar g_s3, g_s3_b, g_s3_k;
	generate
	for (g_s3 = 0; g_s3 < 4; g_s3 = g_s3 + 1) begin : g_pipe_s3
		for (g_s3_b = 0; g_s3_b < 9; g_s3_b = g_s3_b + 1) begin : g_leaf_s3
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_l3 (
				.I0(pe_s3_lane[g_s3]), .O(pe_s3_leaf[g_s3][g_s3_b])
			);
		end
		always @(posedge clk) begin
			if (rst_sync) begin
				fmt4_l[g_s3] <= 8'd0;
				wm4_l[g_s3] <= 4'd0;
			end else if (pe_s3_leaf[g_s3][8]) begin
				fmt4_l[g_s3] <= fmt3;
				wm4_l[g_s3] <= wm3;
			end
		end
		for (g_s3_k = 0; g_s3_k < 8; g_s3_k = g_s3_k + 1) begin : g_reg_s3
			always @(posedge clk) begin
				if (rst_sync) begin
					res4[g_s3][16 * g_s3_k +: 16] <= 16'd0;
				end else if (pe_s3_leaf[g_s3][g_s3_k]) begin
					res4[g_s3][16 * g_s3_k +: 16] <= res_w[g_s3][16 * g_s3_k +: 16];
				end
			end
		end
	end
	endgenerate
`else
	genvar g_s3;
	generate
	for (g_s3 = 0; g_s3 < 4; g_s3 = g_s3 + 1) begin : g_pipe_s3
		always @(posedge clk) begin
			if (rst_sync) begin
				fmt4_l[g_s3] <= 8'd0;
				wm4_l[g_s3] <= 4'd0;
				res4[g_s3] <= 128'd0;
			end else if (pe_s3_lane[g_s3]) begin
				fmt4_l[g_s3] <= fmt3;
				wm4_l[g_s3] <= wm3;
				res4[g_s3] <= res_w[g_s3];
			end
		end
	end
	endgenerate
`endif

	/* =========================================================================
	 * STAGE 4: sRGB Encode & Pack (Latency: 1 cycle)
	 * ========================================================================= */
	wire [255:0] raw_out_w, keep_out_w;

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_pack_l
		wire [31:0] f0 = res4[gl][31:0];
		wire [31:0] f1 = res4[gl][63:32];
		wire [31:0] f2 = res4[gl][95:64];
		wire [31:0] f3 = res4[gl][127:96];

		wire [7:0] fmt4_gl = fmt4_l[gl];
		wire [3:0] wm4_gl = wm4_l[gl];

		wire [7:0] srgb0, srgb1, srgb2;
		atg_srgb_enc u_enc0 (.b(f0), .srgb(srgb0));
		atg_srgb_enc u_enc1 (.b(f1), .srgb(srgb1));
		atg_srgb_enc u_enc2 (.b(f2), .srgb(srgb2));

		wire [15:0] un0, un1, un2, un3;
		atg_rop_f2unorm u_un0 (.f(f0), .w(6'd10), .u(un0));
		atg_rop_f2unorm u_un1 (.f(f1), .w(6'd10), .u(un1));
		atg_rop_f2unorm u_un2 (.f(f2), .w(6'd10), .u(un2));
		atg_rop_f2unorm u_un3 (.f(f3), .w(fmt4_gl == 8'd64 ? 6'd2 : 6'd8), .u(un3));

		wire [15:0] hf0, hf1, hf2, hf3;
		am_fp_f2h #(.LAT(0)) u_hf0 (.f(f0), .h(hf0));
		am_fp_f2h #(.LAT(0)) u_hf1 (.f(f1), .h(hf1));
		am_fp_f2h #(.LAT(0)) u_hf2 (.f(f2), .h(hf2));
		am_fp_f2h #(.LAT(0)) u_hf3 (.f(f3), .h(hf3));

		reg [63:0] pk_raw;
		reg [63:0] pk_keep;

		always @(*) begin
			pk_raw = 64'd0;
			pk_keep = {64{1'b1}};
			case (fmt4_gl)
			8'd43: begin /* R8G8B8A8_SRGB */
				pk_raw[31:0] = {wm4_gl[3] ? un3[7:0] : 8'd0, wm4_gl[2] ? srgb2 : 8'd0, wm4_gl[1] ? srgb1 : 8'd0, wm4_gl[0] ? srgb0 : 8'd0};
				pk_keep[31:0] = {wm4_gl[3] ? 8'd0 : 8'hFF, wm4_gl[2] ? 8'd0 : 8'hFF, wm4_gl[1] ? 8'd0 : 8'hFF, wm4_gl[0] ? 8'd0 : 8'hFF};
			end
			8'd50: begin /* B8G8R8A8_SRGB */
				pk_raw[31:0] = {wm4_gl[3] ? un3[7:0] : 8'd0, wm4_gl[0] ? srgb0 : 8'd0, wm4_gl[1] ? srgb1 : 8'd0, wm4_gl[2] ? srgb2 : 8'd0};
				pk_keep[31:0] = {wm4_gl[3] ? 8'd0 : 8'hFF, wm4_gl[0] ? 8'd0 : 8'hFF, wm4_gl[1] ? 8'd0 : 8'hFF, wm4_gl[2] ? 8'd0 : 8'hFF};
			end
			8'd57: begin /* A8B8G8R8_SRGB_PACK32 */
				pk_raw[31:0] = {wm4_gl[3] ? un3[7:0] : 8'd0, wm4_gl[2] ? srgb2 : 8'd0, wm4_gl[1] ? srgb1 : 8'd0, wm4_gl[0] ? srgb0 : 8'd0};
				pk_keep[31:0] = {wm4_gl[3] ? 8'd0 : 8'hFF, wm4_gl[2] ? 8'd0 : 8'hFF, wm4_gl[1] ? 8'd0 : 8'hFF, wm4_gl[0] ? 8'd0 : 8'hFF};
			end
			8'd64: begin /* A2B10G10R10_UNORM_PACK32 */
				pk_raw[31:0] = {wm4_gl[3] ? un3[1:0] : 2'd0, wm4_gl[2] ? un2[9:0] : 10'd0, wm4_gl[1] ? un1[9:0] : 10'd0, wm4_gl[0] ? un0[9:0] : 10'd0};
				pk_keep[31:0] = {wm4_gl[3] ? 2'd0 : 2'b11, wm4_gl[2] ? 10'd0 : 10'h3FF, wm4_gl[1] ? 10'd0 : 10'h3FF, wm4_gl[0] ? 10'd0 : 10'h3FF};
			end
			8'd76: begin /* R16_SFLOAT */
				pk_raw = {48'd0, wm4_gl[0] ? hf0 : 16'd0};
				pk_keep = {48'hFFFF_FFFF_FFFF, wm4_gl[0] ? 16'd0 : 16'hFFFF};
			end
			8'd83: begin /* R16G16_SFLOAT */
				pk_raw = {32'd0, wm4_gl[1] ? hf1 : 16'd0, wm4_gl[0] ? hf0 : 16'd0};
				pk_keep = {32'hFFFF_FFFF, wm4_gl[1] ? 16'd0 : 16'hFFFF, wm4_gl[0] ? 16'd0 : 16'hFFFF};
			end
			8'd97: begin /* R16G16B16A16_SFLOAT */
				pk_raw = {wm4_gl[3] ? hf3 : 16'd0, wm4_gl[2] ? hf2 : 16'd0, wm4_gl[1] ? hf1 : 16'd0, wm4_gl[0] ? hf0 : 16'd0};
				pk_keep = {wm4_gl[3] ? 16'd0 : 16'hFFFF, wm4_gl[2] ? 16'd0 : 16'hFFFF, wm4_gl[1] ? 16'd0 : 16'hFFFF, wm4_gl[0] ? 16'd0 : 16'hFFFF};
			end
			default: begin
				pk_raw = 64'd0;
				pk_keep = {64{1'b1}};
			end
			endcase
		end

		assign raw_out_w[64 * gl +: 64] = (known4 && lanes4[gl]) ? pk_raw : 64'd0;
		assign keep_out_w[64 * gl +: 64] = (known4 && lanes4[gl]) ? pk_keep : {64{1'b1}};

	end
	endgenerate

	/* =========================================================================
	 * STAGE 5: Output Registers (Latency: 1 cycle)
	 * Fully registers raw and keep to eliminate cross-module CARRY4 ripple
	 * ========================================================================= */
	(* max_fanout = 16 *) reg [255:0] r_raw, r_keep;
	reg r_valid;

	always @(posedge clk) begin
		if (rst_sync) begin
			r_valid <= 1'b0;
		end else if (pe_s4_ctrl) begin
			r_valid <= v4;
		end
	end

`ifdef SYNTH_KINTEX7
	wire [7:0] pe_s4_leaf [0:3];
	genvar g_s4, g_s4_b, g_s4_k;
	generate
	for (g_s4 = 0; g_s4 < 4; g_s4 = g_s4 + 1) begin : g_pipe_s4
		for (g_s4_b = 0; g_s4_b < 8; g_s4_b = g_s4_b + 1) begin : g_leaf_s4
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_l4 (
				.I0(pe_s4_lane[g_s4]), .O(pe_s4_leaf[g_s4][g_s4_b])
			);
		end
		for (g_s4_k = 0; g_s4_k < 4; g_s4_k = g_s4_k + 1) begin : g_reg_s4
			always @(posedge clk) begin
				if (rst_sync) begin
					r_raw[64 * g_s4 + 16 * g_s4_k +: 16] <= 16'd0;
					r_keep[64 * g_s4 + 16 * g_s4_k +: 16] <= 16'hFFFF;
				end else begin
					if (pe_s4_leaf[g_s4][g_s4_k])
						r_raw[64 * g_s4 + 16 * g_s4_k +: 16] <= raw_out_w[64 * g_s4 + 16 * g_s4_k +: 16];
					if (pe_s4_leaf[g_s4][4 + g_s4_k])
						r_keep[64 * g_s4 + 16 * g_s4_k +: 16] <= keep_out_w[64 * g_s4 + 16 * g_s4_k +: 16];
				end
			end
		end
	end
	endgenerate
`else
	always @(posedge clk) begin
		if (rst_sync) begin
			r_raw <= 256'd0;
			r_keep <= {256{1'b1}};
		end else if (pe_s4_ctrl) begin
			r_raw <= raw_out_w;
			r_keep <= keep_out_w;
		end
	end
`endif

	assign o_valid = r_valid;
	assign o_raw = r_raw;
	assign o_keep = r_keep;

endmodule

`default_nettype wire
