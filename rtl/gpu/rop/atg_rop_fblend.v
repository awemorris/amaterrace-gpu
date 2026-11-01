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
 * Deep-pipelined stream architecture (throughput: 1 beat/cycle, latency: 23 cycles)
 * compliant with ASIC 5nm 1.5 GHz timing, primitive budget (<= 4 LUTs/stage,
 * Pre/Post-CARRY4 <= 1, Pre/Post-DSP <= 1), and fanout limits (<= 24).
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
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

	/* Pipeline control: output stage holds when o_valid && !o_ready */
	wire pipe_stall = o_valid && !o_ready;
	wire pipe_en = !pipe_stall;

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire rst_sync;
	LUT1 #(.INIT(2'b01)) u_rst_inv (.I0(rst_n), .O(rst_sync));
	(* keep = "true", dont_touch = "true" *) wire [15:0] rst_n_sub;
	genvar g_rn;
	generate
	for (g_rn = 0; g_rn < 16; g_rn = g_rn + 1) begin : g_rstn_buf
		LUT1 #(.INIT(2'b10)) u_rn (.I0(rst_n), .O(rst_n_sub[g_rn]));
	end
	endgenerate

	/* Buffered enable tree for output registers (fanout <= 16, <= 3 LUTs) */
	(* keep = "true", dont_touch = "true" *) wire [2:0]  out_en_root;
	(* keep = "true", dont_touch = "true" *) wire [31:0] out_en_leaf;
	genvar gor, gol;
	generate
	for (gor = 0; gor < 3; gor = gor + 1) begin : g_oe_r
		LUT1 #(.INIT(2'h2)) u_oer (.I0(pipe_en), .O(out_en_root[gor]));
	end
	for (gor = 0; gor < 2; gor = gor + 1) begin : g_oe_l_grp
		for (gol = 0; gol < 16; gol = gol + 1) begin : g_oe_l
			LUT1 #(.INIT(2'h2)) u_oel (.I0(out_en_root[gor]), .O(out_en_leaf[gor * 16 + gol]));
		end
	end
	endgenerate

	/* Buffered i_fmt input port tree (fanout <= 12 everywhere) */
	(* keep = "true", dont_touch = "true" *) wire [7:0] i_fmt_ctrl_b;
	(* keep = "true", dont_touch = "true" *) wire [7:0] i_fmt_b0 [0:3];
	(* keep = "true", dont_touch = "true" *) wire [7:0] i_fmt_b1 [0:3];
	genvar gfb, gfl;
	generate
	for (gfb = 0; gfb < 8; gfb = gfb + 1) begin : g_fmt_buf
		LUT1 #(.INIT(2'h2)) u_fc (.I0(i_fmt[gfb]), .O(i_fmt_ctrl_b[gfb]));
		for (gfl = 0; gfl < 4; gfl = gfl + 1) begin : g_fmt_l
			LUT1 #(.INIT(2'h2)) u_fb0 (.I0(i_fmt[gfb]), .O(i_fmt_b0[gfl][gfb]));
			LUT1 #(.INIT(2'h2)) u_fb1 (.I0(i_fmt[gfb]), .O(i_fmt_b1[gfl][gfb]));
		end
	end
	endgenerate

	wire [2495:0] pe_leaf = {2496{1'b1}};
`else
	wire rst_sync = !rst_n;
	wire [15:0] rst_n_sub = {16{rst_n}};
	wire [2:0]  out_en_root = {3{pipe_en}};
	wire [31:0] out_en_leaf = {32{pipe_en}};
	wire [7:0]  i_fmt_ctrl_b = i_fmt;
	wire [7:0]  i_fmt_b0 [0:3];
	wire [7:0]  i_fmt_b1 [0:3];
	genvar gfl_sim;
	generate
	for (gfl_sim = 0; gfl_sim < 4; gfl_sim = gfl_sim + 1) begin : g_fmt_sim
		assign i_fmt_b0[gfl_sim] = i_fmt;
		assign i_fmt_b1[gfl_sim] = i_fmt;
	end
	endgenerate
	wire [2495:0] pe_leaf;
`endif

	(* max_fanout = 16 *) reg r_ready;
	always @(posedge clk) begin
		if (rst_sync)
			r_ready <= 1'b1;
		else
			r_ready <= out_en_root[2];
	end
	assign i_ready = r_ready;

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
		needs_sub = (f == 4'd3) || (f == 4'd5) || (f == 4'd7) || (f == 4'd9) ||
			(f == 4'd11) || (f == 4'd13) || ((f == 4'd14) && !alpha);
	endfunction

	genvar gl, gc, gb;

	/* =========================================================================
	 * STAGE IN: Input Registration & Format Pre-Decode (Latency: 1 cycle)
	 * Isolates all module input ports (fanout <= 14 on all ports, <= 3 LUTs)
	 * ========================================================================= */
	reg r_in_valid, r_in_known;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] r_in_lanes, r_in_wm;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] r_in_fmt_ctrl;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [22:0] r_in_blend_l [0:3];
	reg [127:0] r_in_const;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] r_in_srgb_b0 [0:3][0:7];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] r_in_srgb_b1 [0:3][0:7];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] r_in_srgb_b2 [0:3][0:7];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] r_in_u8      [0:3][0:7];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [255:0] r_in_dst_u10_a;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [255:0] r_in_dst_u10_b;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [255:0] r_in_dst_u10_c;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [255:0] r_in_dst_u10_d;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [255:0] r_in_dst_hf_a;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [255:0] r_in_dst_hf_b;
	reg [511:0] r_in_src;

	/* Pre-decoded format flags per lane & channel (<= 3 LUTs from i_fmt, fanout <= 16) */
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] r_in_fixed_s  [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] r_in_fixed_sa [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] r_in_fixed_kc [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] r_in_fixed_ka [0:3];
	(* keep = "true", dont_touch = "true" *) reg [3:0] r_in_s_z  [0:3][0:3];
	(* keep = "true", dont_touch = "true" *) reg [3:0] r_in_s_o  [0:3][0:3];
	(* keep = "true", dont_touch = "true" *) reg [3:0] r_in_sa_z [0:3];
	(* keep = "true", dont_touch = "true" *) reg [3:0] r_in_sa_o [0:3];
	(* keep = "true", dont_touch = "true" *) reg [3:0] r_in_k_z  [0:3][0:3];
	(* keep = "true", dont_touch = "true" *) reg [3:0] r_in_k_o  [0:3][0:3];
	(* keep = "true", dont_touch = "true" *) reg [3:0] r_in_ka_z [0:3];
	(* keep = "true", dont_touch = "true" *) reg [3:0] r_in_ka_o [0:3];
	(* keep = "true", dont_touch = "true" *) reg [3:0] r_in_hf_lz   [0:3][0:3];
	(* keep = "true", dont_touch = "true" *) reg       r_in_hf_subn [0:3][0:3];
	(* keep = "true", dont_touch = "true" *) reg       r_in_hf_zero [0:3][0:3];
	(* keep = "true", dont_touch = "true" *) reg       r_in_hf_nan  [0:3][0:3];
	(* keep = "true", dont_touch = "true" *) reg       r_in_hf_eff  [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] r_in_sel0     [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] r_in_sel1     [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] r_in_sel2     [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] r_in_sel3     [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] r_in_da_sel0  [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] r_in_da_sel1  [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] r_in_da_sel2  [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] r_in_da_sel3  [0:3];

	wire in_known_w = (i_fmt_ctrl_b == 8'd43) || (i_fmt_ctrl_b == 8'd50) || (i_fmt_ctrl_b == 8'd57) ||
	                  (i_fmt_ctrl_b == 8'd64) || (i_fmt_ctrl_b == 8'd76) || (i_fmt_ctrl_b == 8'd83) || (i_fmt_ctrl_b == 8'd97);

	/* Precompute constant & source clamp flags in STAGE IN (<= 3 LUT levels from i_src / i_const) */
	(* keep = "true" *) wire [3:0] in_k_many;
	(* keep = "true" *) wire [3:0] in_k_elo;
	generate
	for (gc = 0; gc < 4; gc = gc + 1) begin : g_in_k_pre
		wire [31:0] k_raw = i_const[32 * gc +: 32];
		(* keep = "true" *) wire [3:0] km;
		assign km[0] = (k_raw[5:0]   != 6'd0);
		assign km[1] = (k_raw[11:6]  != 6'd0);
		assign km[2] = (k_raw[17:12] != 6'd0);
		assign km[3] = (k_raw[22:18] != 5'd0);
		assign in_k_many[gc] = |km;
		assign in_k_elo[gc]  = &k_raw[28:23];
	end
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_in_sk_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_in_sk_c
			wire [31:0] s_raw = i_src[128 * gl + 32 * gc +: 32];
			wire [31:0] k_raw = i_const[32 * gc +: 32];
			(* keep = "true" *) wire [3:0] sm;
			assign sm[0] = (s_raw[5:0]   != 6'd0);
			assign sm[1] = (s_raw[11:6]  != 6'd0);
			assign sm[2] = (s_raw[17:12] != 6'd0);
			assign sm[3] = (s_raw[22:18] != 5'd0);
			(* keep = "true" *) wire s_many_in = |sm;
			(* keep = "true" *) wire s_elo_in  = &s_raw[28:23];
			wire s_nan_in = s_raw[30] && s_raw[29] && s_elo_in && s_many_in;
			wire s_gt1_in = s_raw[30] || (s_raw[29] && s_elo_in && s_many_in);
			(* keep = "true", dont_touch = "true" *) wire s_z_in = s_raw[31] || s_nan_in;
			(* keep = "true", dont_touch = "true" *) wire s_o_in = (!s_raw[31]) && (!s_nan_in) && s_gt1_in;

			wire k_nan_in = k_raw[30] && k_raw[29] && in_k_elo[gc] && in_k_many[gc];
			wire k_gt1_in = k_raw[30] || (k_raw[29] && in_k_elo[gc] && in_k_many[gc]);
			(* keep = "true", dont_touch = "true" *) wire k_z_in = k_raw[31] || k_nan_in;
			(* keep = "true", dont_touch = "true" *) wire k_o_in = (!k_raw[31]) && (!k_nan_in) && k_gt1_in;

			wire [15:0] h_raw = i_dst[64 * gl + 16 * gc +: 16];
			(* keep = "true", dont_touch = "true" *) wire h_ez  = (h_raw[14:10] == 5'd0);
			(* keep = "true", dont_touch = "true" *) wire h_eff = (&h_raw[14:10]);
			(* keep = "true", dont_touch = "true" *) wire h_mhi = (h_raw[9:5] != 5'd0);
			(* keep = "true", dont_touch = "true" *) wire h_mlo = (h_raw[4:0] != 5'd0);
			(* keep = "true", dont_touch = "true" *) wire [3:0] h_lz_hi =
				h_raw[9] ? 4'd0 : h_raw[8] ? 4'd1 : h_raw[7] ? 4'd2 : h_raw[6] ? 4'd3 : 4'd4;
			(* keep = "true", dont_touch = "true" *) wire [3:0] h_lz_lo =
				h_raw[4] ? 4'd5 : h_raw[3] ? 4'd6 : h_raw[2] ? 4'd7 : h_raw[1] ? 4'd8 : 4'd9;
			(* keep = "true", dont_touch = "true" *) wire [3:0] h_lz_in = h_mhi ? h_lz_hi : h_lz_lo;
			(* keep = "true", dont_touch = "true" *) wire h_subn_in = h_ez && (h_mhi || h_mlo);
			(* keep = "true", dont_touch = "true" *) wire h_zero_in = h_ez && !h_mhi && !h_mlo;
			(* keep = "true", dont_touch = "true" *) wire h_nan_in  = h_eff && (h_mhi || h_mlo);

			always @(posedge clk) begin
				if (pe_leaf[1 + gl]) begin
					r_in_s_z[gl][gc] <= {4{s_z_in}};
					r_in_s_o[gl][gc] <= {4{s_o_in}};
					r_in_k_z[gl][gc] <= {4{k_z_in}};
					r_in_k_o[gl][gc] <= {4{k_o_in}};
					r_in_hf_lz[gl][gc]   <= h_lz_in;
					r_in_hf_subn[gl][gc] <= h_subn_in;
					r_in_hf_zero[gl][gc] <= h_zero_in;
					r_in_hf_nan[gl][gc]  <= h_nan_in;
					r_in_hf_eff[gl][gc]  <= h_eff;
					if (gc == 3) begin
						r_in_sa_z[gl] <= {4{s_z_in}};
						r_in_sa_o[gl] <= {4{s_o_in}};
						r_in_ka_z[gl] <= {4{k_z_in}};
						r_in_ka_o[gl] <= {4{k_o_in}};
					end
				end
			end
		end
	end
	endgenerate

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_in_fdec_l
		wire [7:0] fb0 = i_fmt_b0[gl];
		wire [7:0] fb1 = i_fmt_b1[gl];
		(* keep = "true" *) wire f_fixed_a = (fb0 == 8'd43) || (fb0 == 8'd50) || (fb0 == 8'd57) || (fb0 == 8'd64);
		(* keep = "true" *) wire f_fixed_b = (fb1 == 8'd43) || (fb1 == 8'd50) || (fb1 == 8'd57) || (fb1 == 8'd64);
		(* keep = "true" *) wire f_43_57   = (fb0 == 8'd43) || (fb0 == 8'd57);
		(* keep = "true" *) wire f_50      = (fb0 == 8'd50);
		(* keep = "true" *) wire f_srgb    = (fb0 == 8'd43) || (fb0 == 8'd50) || (fb0 == 8'd57);
		(* keep = "true" *) wire f_64_a    = (fb0 == 8'd64);
		(* keep = "true" *) wire f_64_b    = (fb1 == 8'd64);
		(* keep = "true" *) wire f_hf0     = (fb1 == 8'd76) || (fb1 == 8'd83) || (fb1 == 8'd97);
		(* keep = "true" *) wire f_hf1     = (fb1 == 8'd83) || (fb1 == 8'd97);
		(* keep = "true" *) wire f_97      = (fb1 == 8'd97);
		(* keep = "true" *) wire f_76_83   = (fb1 == 8'd76) || (fb1 == 8'd83);
		integer ic_f;
		always @(posedge clk) begin
			if (rst_sync) begin
				r_in_fixed_sa[gl] <= 4'd0;
				r_in_fixed_ka[gl] <= 4'd0;
				r_in_da_sel0[gl]  <= 4'd0;
				r_in_da_sel1[gl]  <= 4'd0;
				r_in_da_sel2[gl]  <= 4'd0;
				r_in_da_sel3[gl]  <= 4'd0;
				for (ic_f = 0; ic_f < 4; ic_f = ic_f + 1) begin
					r_in_fixed_s[gl][ic_f]  <= 4'd0;
					r_in_fixed_kc[gl][ic_f] <= 4'd0;
					r_in_sel0[gl][ic_f]     <= 4'd0;
					r_in_sel1[gl][ic_f]     <= 4'd0;
					r_in_sel2[gl][ic_f]     <= 4'd0;
					r_in_sel3[gl][ic_f]     <= 4'd0;
				end
			end else if (pe_leaf[1 + gl]) begin
				r_in_fixed_sa[gl] <= {4{f_fixed_a}};
				r_in_fixed_ka[gl] <= {4{f_fixed_b}};
				for (ic_f = 0; ic_f < 4; ic_f = ic_f + 1) begin
					r_in_fixed_s[gl][ic_f]  <= {4{f_fixed_a}};
					r_in_fixed_kc[gl][ic_f] <= {4{f_fixed_b}};
				end
				/* Channel 0: sel0=b0(43,57), sel1=b2(50), sel2=u10(64), sel3=hf(76,83,97) */
				r_in_sel0[gl][0] <= {4{f_43_57}};
				r_in_sel1[gl][0] <= {4{f_50}};
				r_in_sel2[gl][0] <= {4{f_64_a}};
				r_in_sel3[gl][0] <= {4{f_hf0}};
				/* Channel 1: sel0=b1(43,50,57), sel1=0, sel2=u10(64), sel3=hf(83,97) */
				r_in_sel0[gl][1] <= {4{f_srgb}};
				r_in_sel1[gl][1] <= 4'd0;
				r_in_sel2[gl][1] <= {4{f_64_a}};
				r_in_sel3[gl][1] <= {4{f_hf1}};
				/* Channel 2: sel0=b0(50), sel1=b2(43,57), sel2=u10(64), sel3=hf(97) */
				r_in_sel0[gl][2] <= {4{f_50}};
				r_in_sel1[gl][2] <= {4{f_43_57}};
				r_in_sel2[gl][2] <= {4{f_64_b}};
				r_in_sel3[gl][2] <= {4{f_97}};
				/* Channel 3 & da: sel0=u8(43,50,57), sel1=ONE(76,83), sel2=u2(64), sel3=hf(97) */
				r_in_sel0[gl][3] <= {4{f_srgb}};
				r_in_sel1[gl][3] <= {4{f_76_83}};
				r_in_sel2[gl][3] <= {4{f_64_b}};
				r_in_sel3[gl][3] <= {4{f_97}};
				r_in_da_sel0[gl] <= {4{f_srgb}};
				r_in_da_sel1[gl] <= {4{f_76_83}};
				r_in_da_sel2[gl] <= {4{f_64_b}};
				r_in_da_sel3[gl] <= {4{f_97}};
			end
		end
	end
	endgenerate

	integer i_in, i_l, i_c, i_st;
	always @(posedge clk) begin
		if (rst_sync) begin
			r_in_valid    <= 1'b0;
			r_in_known    <= 1'b0;
			r_in_lanes    <= 4'd0;
			r_in_wm       <= 4'd0;
			r_in_fmt_ctrl <= 8'd0;
			for (i_l = 0; i_l < 4; i_l = i_l + 1)
				r_in_blend_l[i_l] <= 23'd0;
		end else begin
			if (pe_leaf[0]) begin
				r_in_valid    <= i_valid;
				r_in_known    <= in_known_w;
				r_in_lanes    <= i_lanes;
				r_in_wm       <= i_wm;
				r_in_fmt_ctrl <= i_fmt_ctrl_b;
			end
			for (i_l = 0; i_l < 4; i_l = i_l + 1) begin
				if (pe_leaf[5 + i_l * 2])
					r_in_blend_l[i_l][11:0]  <= i_blend[11:0];
				if (pe_leaf[5 + i_l * 2 + 1])
					r_in_blend_l[i_l][22:12] <= i_blend[22:12];
			end
		end
		for (i_in = 0; i_in < 8; i_in = i_in + 1)
			if (pe_leaf[17 + i_in])
				r_in_const[16 * i_in +: 16] <= i_const[16 * i_in +: 16];
		for (i_l = 0; i_l < 4; i_l = i_l + 1) begin
			for (i_c = 0; i_c < 8; i_c = i_c + 1) begin
				if (pe_leaf[25 + i_l * 8 + i_c]) begin
					r_in_srgb_b0[i_l][i_c] <= i_dst[64 * i_l + 0  +: 8];
					r_in_srgb_b1[i_l][i_c] <= i_dst[64 * i_l + 8  +: 8];
					r_in_srgb_b2[i_l][i_c] <= i_dst[64 * i_l + 16 +: 8];
					r_in_u8[i_l][i_c]      <= i_dst[64 * i_l + 24 +: 8];
				end
			end
		end
		for (i_in = 0; i_in < 16; i_in = i_in + 1) begin
			if (pe_leaf[25 + i_in * 7 + 1]) r_in_dst_u10_a[16 * i_in +: 16] <= i_dst[16 * i_in +: 16];
			if (pe_leaf[25 + i_in * 7 + 2]) r_in_dst_u10_b[16 * i_in +: 16] <= i_dst[16 * i_in +: 16];
			if (pe_leaf[25 + i_in * 7 + 3]) r_in_dst_u10_c[16 * i_in +: 16] <= i_dst[16 * i_in +: 16];
			if (pe_leaf[25 + i_in * 7 + 4]) r_in_dst_u10_d[16 * i_in +: 16] <= i_dst[16 * i_in +: 16];
			if (pe_leaf[25 + i_in * 7 + 5]) r_in_dst_hf_a[16 * i_in +: 16]  <= i_dst[16 * i_in +: 16];
			if (pe_leaf[25 + i_in * 7 + 6]) r_in_dst_hf_b[16 * i_in +: 16]  <= i_dst[16 * i_in +: 16];
		end
		for (i_in = 0; i_in < 32; i_in = i_in + 1)
			if (pe_leaf[137 + i_in])
				r_in_src[16 * i_in +: 16] <= i_src[16 * i_in +: 16];
	end

	/* =========================================================================
	 * STAGE 0: Unpack Destination & Clamp Inputs (Latency: 1 cycle)
	 * Byte-sliced (8 bits/slice) muxes & clamps keep all nets <= 16 fanout, <= 3 LUTs
	 * ========================================================================= */
	(* keep = "true", dont_touch = "true" *) wire [127:0] s_clamped_w   [0:3];
	(* keep = "true", dont_touch = "true" *) wire [31:0]  sa_clamped_w  [0:3];
	(* keep = "true", dont_touch = "true" *) wire [127:0] d_unpacked_w  [0:3];
	(* keep = "true", dont_touch = "true" *) wire [31:0]  da_unpacked_w [0:3];
	(* keep = "true", dont_touch = "true" *) wire [127:0] kc_clamped_w  [0:3];
	(* keep = "true", dont_touch = "true" *) wire [31:0]  ka_clamped_w  [0:3];

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_s0_comb_l
		wire [63:0] d_u10_a_l = r_in_dst_u10_a[64 * gl +: 64];
		wire [63:0] d_u10_b_l = r_in_dst_u10_b[64 * gl +: 64];
		wire [63:0] d_u10_c_l = r_in_dst_u10_c[64 * gl +: 64];
		wire [63:0] d_u10_d_l = r_in_dst_u10_d[64 * gl +: 64];
		wire [63:0] d_hf_a_l  = r_in_dst_hf_a[64 * gl +: 64];
		wire [63:0] d_hf_b_l  = r_in_dst_hf_b[64 * gl +: 64];

		/* Partitioned 8-bit ROM decoders: each input register copy drives only 4 output bits (<= 16 LUTs) */
		wire [31:0] srgb_b0_val, srgb_b1_val, srgb_b2_val, u8_val;
		genvar gk;
		for (gk = 0; gk < 8; gk = gk + 1) begin : g_srgb_sl
			wire [31:0] dec_b0 = atg_srgb_dec(r_in_srgb_b0[gl][gk]);
			wire [31:0] dec_b1 = atg_srgb_dec(r_in_srgb_b1[gl][gk]);
			wire [31:0] dec_b2 = atg_srgb_dec(r_in_srgb_b2[gl][gk]);
			wire [31:0] dec_u8 = atg_unorm8(r_in_u8[gl][gk]);
			assign srgb_b0_val[4 * gk +: 4] = dec_b0[4 * gk +: 4];
			assign srgb_b1_val[4 * gk +: 4] = dec_b1[4 * gk +: 4];
			assign srgb_b2_val[4 * gk +: 4] = dec_b2[4 * gk +: 4];
			assign u8_val[4 * gk +: 4]      = dec_u8[4 * gk +: 4];
			wire unused_srgb_sl = &{1'b0, dec_b0, dec_b1, dec_b2, dec_u8};
		end
		wire [31:0] u2_val = atg_unorm2(d_u10_a_l[31:30]);

		for (gc = 0; gc < 4; gc = gc + 1) begin : g_s0_comb_c
			wire [31:0] s_in_ch  = r_in_src[128 * gl + 32 * gc +: 32];
			wire [31:0] kc_in_ch = r_in_const[32 * gc +: 32];

			wire [9:0] u10_in_a = (gc == 0) ? d_u10_a_l[9:0] : (gc == 1) ? d_u10_a_l[19:10] : (gc == 2) ? d_u10_a_l[29:20] : 10'd0;
			wire [9:0] u10_in_b = (gc == 0) ? d_u10_b_l[9:0] : (gc == 1) ? d_u10_b_l[19:10] : (gc == 2) ? d_u10_b_l[29:20] : 10'd0;
			wire [9:0] u10_in_c = (gc == 0) ? d_u10_c_l[9:0] : (gc == 1) ? d_u10_c_l[19:10] : (gc == 2) ? d_u10_c_l[29:20] : 10'd0;
			wire [9:0] u10_in_d = (gc == 0) ? d_u10_d_l[9:0] : (gc == 1) ? d_u10_d_l[19:10] : (gc == 2) ? d_u10_d_l[29:20] : 10'd0;
			wire [15:0] hf_in_a = d_hf_a_l[16 * gc +: 16];
			wire [15:0] hf_in_b = d_hf_b_l[16 * gc +: 16];

			wire [31:0] u10_val_a = atg_unorm10(u10_in_a);
			wire [31:0] u10_val_b = atg_unorm10(u10_in_b);
			wire [31:0] u10_val_c = atg_unorm10(u10_in_c);
			wire [31:0] u10_val_d = atg_unorm10(u10_in_d);
			wire [31:0] u10_val   = {u10_val_d[31:24], u10_val_c[23:16], u10_val_b[15:8], u10_val_a[7:0]};

			wire [3:0] h_lz = r_in_hf_lz[gl][gc];
			(* keep = "true", dont_touch = "true" *) wire [7:0] hf_el_subn =
				(h_lz == 4'd0) ? 8'd112 : (h_lz == 4'd1) ? 8'd111 :
				(h_lz == 4'd2) ? 8'd110 : (h_lz == 4'd3) ? 8'd109 :
				(h_lz == 4'd4) ? 8'd108 : (h_lz == 4'd5) ? 8'd107 :
				(h_lz == 4'd6) ? 8'd106 : (h_lz == 4'd7) ? 8'd105 :
				(h_lz == 4'd8) ? 8'd104 : 8'd103;
			wire [9:0] hf_m_pad = {hf_in_a[8:0], 1'b0};
			(* keep = "true", dont_touch = "true" *) wire [9:0] hf_m_s1 =
				(h_lz[1:0] == 2'd0) ? hf_m_pad :
				(h_lz[1:0] == 2'd1) ? {hf_m_pad[8:0], 1'b0} :
				(h_lz[1:0] == 2'd2) ? {hf_m_pad[7:0], 2'b0} : {hf_m_pad[6:0], 3'b0};
			(* keep = "true", dont_touch = "true" *) wire [9:0] hf_m_sh =
				(h_lz[3:2] == 2'd0) ? hf_m_s1 :
				(h_lz[3:2] == 2'd1) ? {hf_m_s1[5:0], 4'b0} :
				(h_lz[3:2] == 2'd2) ? {hf_m_s1[1:0], 8'b0} : 10'd0;
			wire [7:0] hf_exp_norm = {hf_in_b[14], ~hf_in_b[14], ~hf_in_b[14], ~hf_in_b[14], hf_in_b[13:10]};
			(* keep = "true", dont_touch = "true" *) wire [7:0] hf_exp32 =
				r_in_hf_eff[gl][gc]  ? 8'hFF :
				r_in_hf_zero[gl][gc] ? 8'h00 :
				r_in_hf_subn[gl][gc] ? hf_el_subn : hf_exp_norm;
			(* keep = "true", dont_touch = "true" *) wire [9:0] hf_mant32;
			assign hf_mant32[8:0] = (r_in_hf_eff[gl][gc] || r_in_hf_zero[gl][gc]) ? 9'd0 :
				(r_in_hf_subn[gl][gc] ? hf_m_sh[8:0] : hf_in_a[8:0]);
			assign hf_mant32[9]   = r_in_hf_nan[gl][gc] ||
				((!r_in_hf_eff[gl][gc] && !r_in_hf_zero[gl][gc]) &&
				 (r_in_hf_subn[gl][gc] ? hf_m_sh[9] : hf_in_b[9]));
			(* keep = "true", dont_touch = "true" *) wire hf_sign32 = (!r_in_hf_nan[gl][gc]) && hf_in_b[15];
			wire [31:0] hf_val = {hf_sign32, hf_exp32, hf_mant32, 13'd0};

			wire [31:0] v0_ch = (gc == 0) ? srgb_b0_val : (gc == 1) ? srgb_b1_val : (gc == 2) ? srgb_b0_val : u8_val;
			wire [31:0] v1_ch = (gc == 0) ? srgb_b2_val : (gc == 1) ? 32'd0       : (gc == 2) ? srgb_b2_val : ONE;
			wire [31:0] v2_ch = (gc == 3) ? u2_val : u10_val;
			wire [31:0] v3_ch = hf_val;

			for (gb = 0; gb < 4; gb = gb + 1) begin : g_s0_byte
				localparam [7:0] ONE_B = ONE[8 * gb +: 8];
				assign s_clamped_w[gl][32 * gc + 8 * gb +: 8] =
					(!r_in_fixed_s[gl][gc][gb]) ? s_in_ch[8 * gb +: 8] :
					(r_in_s_z[gl][gc][gb] ? 8'd0 : (r_in_s_o[gl][gc][gb] ? ONE_B : s_in_ch[8 * gb +: 8]));

				assign kc_clamped_w[gl][32 * gc + 8 * gb +: 8] =
					(!r_in_fixed_kc[gl][gc][gb]) ? kc_in_ch[8 * gb +: 8] :
					(r_in_k_z[gl][gc][gb] ? 8'd0 : (r_in_k_o[gl][gc][gb] ? ONE_B : kc_in_ch[8 * gb +: 8]));

				(* keep = "true", dont_touch = "true" *) wire sel0_b = r_in_sel0[gl][gc][gb];
				(* keep = "true", dont_touch = "true" *) wire sel1_b = r_in_sel1[gl][gc][gb];
				(* keep = "true", dont_touch = "true" *) wire sel2_b = r_in_sel2[gl][gc][gb];
				(* keep = "true", dont_touch = "true" *) wire sel3_b = r_in_sel3[gl][gc][gb];
				assign d_unpacked_w[gl][32 * gc + 8 * gb +: 8] =
					(sel0_b ? v0_ch[8 * gb +: 8] : 8'd0) |
					(sel1_b ? v1_ch[8 * gb +: 8] : 8'd0) |
					(sel2_b ? v2_ch[8 * gb +: 8] : 8'd0) |
					(sel3_b ? v3_ch[8 * gb +: 8] : 8'd0);
			end

			if (gc == 3) begin : g_s0_alpha_rep
				for (gb = 0; gb < 4; gb = gb + 1) begin : g_s0_alpha_byte
					localparam [7:0] ONE_B = ONE[8 * gb +: 8];
					assign sa_clamped_w[gl][8 * gb +: 8] =
						(!r_in_fixed_sa[gl][gb]) ? s_in_ch[8 * gb +: 8] :
						(r_in_sa_z[gl][gb] ? 8'd0 : (r_in_sa_o[gl][gb] ? ONE_B : s_in_ch[8 * gb +: 8]));

					assign ka_clamped_w[gl][8 * gb +: 8] =
						(!r_in_fixed_ka[gl][gb]) ? kc_in_ch[8 * gb +: 8] :
						(r_in_ka_z[gl][gb] ? 8'd0 : (r_in_ka_o[gl][gb] ? ONE_B : kc_in_ch[8 * gb +: 8]));

					(* keep = "true", dont_touch = "true" *) wire da_s0_b = r_in_da_sel0[gl][gb];
					(* keep = "true", dont_touch = "true" *) wire da_s1_b = r_in_da_sel1[gl][gb];
					(* keep = "true", dont_touch = "true" *) wire da_s2_b = r_in_da_sel2[gl][gb];
					(* keep = "true", dont_touch = "true" *) wire da_s3_b = r_in_da_sel3[gl][gb];
					assign da_unpacked_w[gl][8 * gb +: 8] =
						(da_s0_b ? v0_ch[8 * gb +: 8] : 8'd0) |
						(da_s1_b ? v1_ch[8 * gb +: 8] : 8'd0) |
						(da_s2_b ? v2_ch[8 * gb +: 8] : 8'd0) |
						(da_s3_b ? v3_ch[8 * gb +: 8] : 8'd0);
				end
			end

			wire unused_dec = &{1'b0, d_u10_a_l[63:32], d_u10_b_l[63:30],
				d_u10_c_l[63:30], d_u10_d_l[63:30], u10_val_a[31:8], u10_val_b[31:16], u10_val_b[7:0],
				u10_val_c[31:24], u10_val_c[15:0], u10_val_d[23:0], hf_in_a[15:9], hf_in_b[8:0]};
		end
	end
	endgenerate

	reg [127:0] s0 [0:3];
	reg [127:0] d0 [0:3];
	/* Dedicated alpha & constant copies per lane so fanout <= 10 everywhere */
	(* equivalent_register_removal = "no", max_fanout = 12 *) reg [31:0] sa0_l [0:3];
	(* equivalent_register_removal = "no", max_fanout = 12 *) reg [31:0] da0_l [0:3];
	(* equivalent_register_removal = "no", max_fanout = 12 *) reg [127:0] kc0_l [0:3];
	(* equivalent_register_removal = "no", max_fanout = 12 *) reg [31:0] ka0_l [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [22:0] blend0_c [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt0_r;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm0_r, lanes0_r;
	reg v0_r, known0_r;

	always @(posedge clk) begin
		if (rst_sync) begin
			v0_r     <= 1'b0;
			known0_r <= 1'b0;
			fmt0_r   <= 8'd0;
			wm0_r    <= 4'd0;
			lanes0_r <= 4'd0;
		end else if (pe_leaf[169]) begin
			v0_r     <= r_in_valid;
			known0_r <= r_in_known;
			fmt0_r   <= r_in_fmt_ctrl;
			wm0_r    <= r_in_wm;
			lanes0_r <= r_in_lanes;
		end
	end

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_s0_reg_l
		localparam integer B_BASE = 170 + gl * 38;
		integer c0_i;
		always @(posedge clk) begin
			for (c0_i = 0; c0_i < 4; c0_i = c0_i + 1) begin
				if (pe_leaf[B_BASE + c0_i * 2])     blend0_c[gl][c0_i][11:0]  <= r_in_blend_l[gl][11:0];
				if (pe_leaf[B_BASE + c0_i * 2 + 1]) blend0_c[gl][c0_i][22:12] <= r_in_blend_l[gl][22:12];
			end
			if (pe_leaf[B_BASE + 8])  sa0_l[gl][15:0]  <= sa_clamped_w[gl][15:0];
			if (pe_leaf[B_BASE + 9])  sa0_l[gl][31:16] <= sa_clamped_w[gl][31:16];
			if (pe_leaf[B_BASE + 10]) da0_l[gl][15:0]  <= da_unpacked_w[gl][15:0];
			if (pe_leaf[B_BASE + 11]) da0_l[gl][31:16] <= da_unpacked_w[gl][31:16];
			if (pe_leaf[B_BASE + 12]) ka0_l[gl][15:0]  <= ka_clamped_w[gl][15:0];
			if (pe_leaf[B_BASE + 13]) ka0_l[gl][31:16] <= ka_clamped_w[gl][31:16];
			for (c0_i = 0; c0_i < 8; c0_i = c0_i + 1) begin
				if (pe_leaf[B_BASE + 14 + c0_i])
					s0[gl][16 * c0_i +: 16] <= s_clamped_w[gl][16 * c0_i +: 16];
				if (pe_leaf[B_BASE + 22 + c0_i])
					d0[gl][16 * c0_i +: 16] <= d_unpacked_w[gl][16 * c0_i +: 16];
				if (pe_leaf[B_BASE + 30 + c0_i])
					kc0_l[gl][16 * c0_i +: 16] <= kc_clamped_w[gl][16 * c0_i +: 16];
			end
		end
	end
	endgenerate

	/* =========================================================================
	 * STAGE 1A: Factor Input Mux Registration (Latency: 1 cycle)
	 * Registers xs1 and xd1 so atg_rop_sub1 receives registered inputs directly
	 * ========================================================================= */
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] r1a_xs      [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0]  r1a_xs_eb   [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] r1a_xd      [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0]  r1a_xd_eb   [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] r1a_xs_pipe [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] r1a_xd_pipe [0:3][0:3];
	reg [127:0] s1a [0:3];
	reg [127:0] d1a [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [22:0] blend1a_l [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt1a_r;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm1a_r, lanes1a_r;
	reg v1a_r, known1a_r;

	always @(posedge clk) begin
		if (rst_sync) begin
			v1a_r     <= 1'b0;
			known1a_r <= 1'b0;
			fmt1a_r   <= 8'd0;
			wm1a_r    <= 4'd0;
			lanes1a_r <= 4'd0;
		end else if (pe_leaf[322]) begin
			v1a_r     <= v0_r;
			known1a_r <= known0_r;
			fmt1a_r   <= fmt0_r;
			wm1a_r    <= wm0_r;
			lanes1a_r <= lanes0_r;
		end
	end

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_s1a_l
		localparam integer B_S1A = 323 + gl * 50;
		integer c1a_i;
		always @(posedge clk) begin
			if (pe_leaf[B_S1A])     blend1a_l[gl][11:0]  <= blend0_c[gl][0][11:0];
			if (pe_leaf[B_S1A + 1]) blend1a_l[gl][22:12] <= blend0_c[gl][0][22:12];
			for (c1a_i = 0; c1a_i < 8; c1a_i = c1a_i + 1) begin
				if (pe_leaf[B_S1A + 34 + c1a_i]) s1a[gl][16 * c1a_i +: 16] <= s0[gl][16 * c1a_i +: 16];
				if (pe_leaf[B_S1A + 42 + c1a_i]) d1a[gl][16 * c1a_i +: 16] <= d0[gl][16 * c1a_i +: 16];
			end
		end
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_s1a_c
			wire is_alpha = (gc == 3);
			wire [22:0] bl0_c = blend0_c[gl][gc];
			wire [31:0] sc1  = s0[gl][32 * gc +: 32];
			wire [31:0] dc1  = d0[gl][32 * gc +: 32];
			wire [31:0] sa1  = sa0_l[gl];
			wire [31:0] da1  = da0_l[gl];
			wire [31:0] kcc1 = kc0_l[gl][32 * gc +: 32];
			wire [31:0] ka1  = ka0_l[gl];
			wire [31:0] xs1_w, xd1_w;
			for (gb = 0; gb < 4; gb = gb + 1) begin : g_fval_b
				(* keep = "true", dont_touch = "true" *) wire [3:0] f_s1_b = is_alpha ? bl0_c[15:12] : bl0_c[4:1];
				(* keep = "true", dont_touch = "true" *) wire [3:0] f_d1_b = is_alpha ? bl0_c[19:16] : bl0_c[8:5];
				wire [31:0] xs_b_full = fval(f_s1_b, is_alpha, sc1, dc1, sa1, da1, kcc1, ka1);
				wire [31:0] xd_b_full = fval(f_d1_b, is_alpha, sc1, dc1, sa1, da1, kcc1, ka1);
				assign xs1_w[8 * gb +: 8] = xs_b_full[8 * gb +: 8];
				assign xd1_w[8 * gb +: 8] = xd_b_full[8 * gb +: 8];
				wire unused_fb = &{1'b0, xs_b_full, xd_b_full};
			end

			always @(posedge clk) begin
				if (pe_leaf[B_S1A + 2 + gc * 8 + 0]) r1a_xs[gl][gc][15:0]       <= xs1_w[15:0];
				if (pe_leaf[B_S1A + 2 + gc * 8 + 1]) begin
					r1a_xs[gl][gc][31:16] <= xs1_w[31:16];
					r1a_xs_eb[gl][gc]     <= xs1_w[30:23];
				end
				if (pe_leaf[B_S1A + 2 + gc * 8 + 2]) r1a_xd[gl][gc][15:0]       <= xd1_w[15:0];
				if (pe_leaf[B_S1A + 2 + gc * 8 + 3]) begin
					r1a_xd[gl][gc][31:16] <= xd1_w[31:16];
					r1a_xd_eb[gl][gc]     <= xd1_w[30:23];
				end
				if (pe_leaf[B_S1A + 2 + gc * 8 + 4]) r1a_xs_pipe[gl][gc][15:0]  <= xs1_w[15:0];
				if (pe_leaf[B_S1A + 2 + gc * 8 + 5]) r1a_xs_pipe[gl][gc][31:16] <= xs1_w[31:16];
				if (pe_leaf[B_S1A + 2 + gc * 8 + 6]) r1a_xd_pipe[gl][gc][15:0]  <= xd1_w[15:0];
				if (pe_leaf[B_S1A + 2 + gc * 8 + 7]) r1a_xd_pipe[gl][gc][31:16] <= xd1_w[31:16];
			end
		end
	end
	endgenerate

	/* =========================================================================
	 * STAGE 1B: 5-Stage 1.0f - x Units (Latency: 5 cycles)
	 * ========================================================================= */
	wire [31:0] sub_s_res [0:3][0:3];
	wire [31:0] sub_d_res [0:3][0:3];
	reg v1b_pipe [0:4];
`ifdef SYNTH_KINTEX7
	wire sub1_clk = clk;
`else
	reg sub1_icg_en;
	always @(negedge clk) begin
		if (rst_sync)
			sub1_icg_en <= 1'b1;
		else
			sub1_icg_en <= v1a_r || v1b_pipe[0] || v1b_pipe[1] || v1b_pipe[2] || v1b_pipe[3];
	end
	wire sub1_clk = clk & sub1_icg_en;
`endif

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_sub1_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_sub1_c
			localparam integer R_IDX = gl * 4 + gc;
			localparam integer P_IDX = 523 + (gl * 4 + gc) * 2;
			atg_rop_sub1 #(.LAT(5)) u_sub_s (
				.clk(sub1_clk), .rst_n(rst_n_sub[R_IDX]), .en(pe_leaf[P_IDX]),
				.i_x(r1a_xs[gl][gc]), .i_x_eb(r1a_xs_eb[gl][gc]), .o_r(sub_s_res[gl][gc])
			);
			atg_rop_sub1 #(.LAT(5)) u_sub_d (
				.clk(sub1_clk), .rst_n(rst_n_sub[R_IDX]), .en(pe_leaf[P_IDX + 1]),
				.i_x(r1a_xd[gl][gc]), .i_x_eb(r1a_xd_eb[gl][gc]), .o_r(sub_d_res[gl][gc])
			);
		end
	end
	endgenerate

	/* 5-stage matching delay pipeline for s, d, xs, xd, blend, fmt, wm, lanes, v, known */
	reg [127:0] s1b_pipe [0:4][0:3];
	reg [127:0] d1b_pipe [0:4][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] sa2_fle [0:3][0:2];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] sa2_mux [0:3][0:2];
	reg [31:0]  xs1b_pipe [0:4][0:3][0:3];
	reg [31:0]  xd1b_pipe [0:4][0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [22:0] blend1b_pipe [0:4][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [22:0] blend2a_c [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0]  fmt1b_pipe [0:4];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0]  wm1b_pipe [0:4];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0]  lanes1b_pipe [0:4];
	reg known1b_pipe [0:4];

	genvar gst;
	generate
	for (gst = 0; gst < 5; gst = gst + 1) begin : g_s1b_st
		localparam integer E_BASE = 555 + gst * 137;
		localparam integer PREV = (gst > 0) ? (gst - 1) : 0;
		integer l1b_i, c1b_i;
		always @(posedge clk) begin
			if (rst_sync) begin
				v1b_pipe[gst]     <= 1'b0;
				known1b_pipe[gst] <= 1'b0;
				fmt1b_pipe[gst]   <= 8'd0;
				wm1b_pipe[gst]    <= 4'd0;
				lanes1b_pipe[gst] <= 4'd0;
			end else if (pe_leaf[E_BASE]) begin
				v1b_pipe[gst]     <= (gst == 0) ? v1a_r     : v1b_pipe[PREV];
				known1b_pipe[gst] <= (gst == 0) ? known1a_r : known1b_pipe[PREV];
				fmt1b_pipe[gst]   <= (gst == 0) ? fmt1a_r   : fmt1b_pipe[PREV];
				wm1b_pipe[gst]    <= (gst == 0) ? wm1a_r    : wm1b_pipe[PREV];
				lanes1b_pipe[gst] <= (gst == 0) ? lanes1a_r : lanes1b_pipe[PREV];
			end
			for (l1b_i = 0; l1b_i < 4; l1b_i = l1b_i + 1) begin
				if (pe_leaf[E_BASE + 1 + l1b_i * 34 + 0])
					blend1b_pipe[gst][l1b_i][11:0]  <= (gst == 0) ? blend1a_l[l1b_i][11:0]  : blend1b_pipe[PREV][l1b_i][11:0];
				if (pe_leaf[E_BASE + 1 + l1b_i * 34 + 1])
					blend1b_pipe[gst][l1b_i][22:12] <= (gst == 0) ? blend1a_l[l1b_i][22:12] : blend1b_pipe[PREV][l1b_i][22:12];
				for (c1b_i = 0; c1b_i < 4; c1b_i = c1b_i + 1) begin
					if (pe_leaf[E_BASE + 1 + l1b_i * 34 + 2 + c1b_i * 8 + 0])
						s1b_pipe[gst][l1b_i][32 * c1b_i +: 16] <= (gst == 0) ? s1a[l1b_i][32 * c1b_i +: 16] : s1b_pipe[PREV][l1b_i][32 * c1b_i +: 16];
					if (pe_leaf[E_BASE + 1 + l1b_i * 34 + 2 + c1b_i * 8 + 1])
						s1b_pipe[gst][l1b_i][32 * c1b_i + 16 +: 16] <= (gst == 0) ? s1a[l1b_i][32 * c1b_i + 16 +: 16] : s1b_pipe[PREV][l1b_i][32 * c1b_i + 16 +: 16];
					if (pe_leaf[E_BASE + 1 + l1b_i * 34 + 2 + c1b_i * 8 + 2])
						d1b_pipe[gst][l1b_i][32 * c1b_i +: 16] <= (gst == 0) ? d1a[l1b_i][32 * c1b_i +: 16] : d1b_pipe[PREV][l1b_i][32 * c1b_i +: 16];
					if (pe_leaf[E_BASE + 1 + l1b_i * 34 + 2 + c1b_i * 8 + 3])
						d1b_pipe[gst][l1b_i][32 * c1b_i + 16 +: 16] <= (gst == 0) ? d1a[l1b_i][32 * c1b_i + 16 +: 16] : d1b_pipe[PREV][l1b_i][32 * c1b_i + 16 +: 16];
					if (pe_leaf[E_BASE + 1 + l1b_i * 34 + 2 + c1b_i * 8 + 4])
						xs1b_pipe[gst][l1b_i][c1b_i][15:0] <= (gst == 0) ? r1a_xs_pipe[l1b_i][c1b_i][15:0] : xs1b_pipe[PREV][l1b_i][c1b_i][15:0];
					if (pe_leaf[E_BASE + 1 + l1b_i * 34 + 2 + c1b_i * 8 + 5])
						xs1b_pipe[gst][l1b_i][c1b_i][31:16] <= (gst == 0) ? r1a_xs_pipe[l1b_i][c1b_i][31:16] : xs1b_pipe[PREV][l1b_i][c1b_i][31:16];
					if (pe_leaf[E_BASE + 1 + l1b_i * 34 + 2 + c1b_i * 8 + 6])
						xd1b_pipe[gst][l1b_i][c1b_i][15:0] <= (gst == 0) ? r1a_xd_pipe[l1b_i][c1b_i][15:0] : xd1b_pipe[PREV][l1b_i][c1b_i][15:0];
					if (pe_leaf[E_BASE + 1 + l1b_i * 34 + 2 + c1b_i * 8 + 7])
						xd1b_pipe[gst][l1b_i][c1b_i][31:16] <= (gst == 0) ? r1a_xd_pipe[l1b_i][c1b_i][31:16] : xd1b_pipe[PREV][l1b_i][c1b_i][31:16];
				end
			end
		end
	end
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_s1b_st4_rep
		localparam integer E_REP = 1240 + gl * 14;
		integer crep_i;
		always @(posedge clk) begin
			for (crep_i = 0; crep_i < 3; crep_i = crep_i + 1) begin
				if (pe_leaf[E_REP + crep_i * 4 + 0]) sa2_fle[gl][crep_i][15:0]  <= s1b_pipe[3][gl][111:96];
				if (pe_leaf[E_REP + crep_i * 4 + 1]) sa2_fle[gl][crep_i][31:16] <= s1b_pipe[3][gl][127:112];
				if (pe_leaf[E_REP + crep_i * 4 + 2]) sa2_mux[gl][crep_i][15:0]  <= s1b_pipe[3][gl][111:96];
				if (pe_leaf[E_REP + crep_i * 4 + 3]) sa2_mux[gl][crep_i][31:16] <= s1b_pipe[3][gl][127:112];
			end
			for (crep_i = 0; crep_i < 4; crep_i = crep_i + 1) begin
				if (pe_leaf[E_REP + 12]) blend2a_c[gl][crep_i][11:0]  <= blend1b_pipe[3][gl][11:0];
				if (pe_leaf[E_REP + 13]) blend2a_c[gl][crep_i][22:12] <= blend1b_pipe[3][gl][22:12];
			end
		end
	end
	endgenerate

	/* =========================================================================
	 * STAGE 2A: Pure-LUT fle Comparisons & Non-Saturate Factor Select (1 cycle)
	 * 0 CARRY4s, <= 3 LUT levels
	 * ========================================================================= */
	reg [31:0] r2a_xs_ns [0:3][0:3];
	reg [31:0] r2a_xd_ns [0:3][0:3];
	reg [31:0] r2a_sub_s [0:3][0:3];
	reg [31:0] r2a_sub_d [0:3][0:3];
	reg [31:0] r2a_sc    [0:3][0:3];
	reg [31:0] r2a_dc    [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0] r2a_le_sats  [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0] r2a_le_satd  [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0] r2a_nan_sats [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0] r2a_nan_satd [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0] r2a_sat_s    [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0] r2a_sat_d    [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0] r2a_le_sd    [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0] r2a_le_ds    [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0] r2a_nan_sd   [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [2:0] r2a_op_lo    [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [2:0] r2a_op_hi    [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [2:0] r2a_op_ctrl  [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0] r2a_bl_en    [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg       r2a_bl_en_ctrl [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt2a;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm2a, lanes2a;
	reg v2a, known2a;

	always @(posedge clk) begin
		if (rst_sync) begin
			v2a     <= 1'b0;
			known2a <= 1'b0;
			fmt2a   <= 8'd0;
			wm2a    <= 4'd0;
			lanes2a <= 4'd0;
		end else if (pe_leaf[1296]) begin
			v2a     <= v1b_pipe[4];
			known2a <= known1b_pipe[4];
			fmt2a   <= fmt1b_pipe[4];
			wm2a    <= wm1b_pipe[4];
			lanes2a <= lanes1b_pipe[4];
		end
	end

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_s2a_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_s2a_c
			localparam integer E2A = 1297 + (gl * 4 + gc) * 14;
			wire is_alpha = (gc == 3);
			wire [22:0] bl_w = blend2a_c[gl][gc];
			wire [3:0] f_s2 = is_alpha ? bl_w[15:12] : bl_w[4:1];
			wire [3:0] f_d2 = is_alpha ? bl_w[19:16] : bl_w[8:5];
			wire [2:0] op2_c = is_alpha ? bl_w[22:20] : bl_w[11:9];

			localparam integer GC_SA = (gc < 3) ? gc : 0;
			wire [31:0] sc2  = s1b_pipe[4][gl][32 * gc +: 32];
			wire [31:0] dc2  = d1b_pipe[4][gl][32 * gc +: 32];
			wire [31:0] sa2_f = (gc < 3) ? sa2_fle[gl][GC_SA] : s1b_pipe[4][gl][127:96];
			wire [31:0] sa2_m = (gc < 3) ? sa2_mux[gl][GC_SA] : s1b_pipe[4][gl][127:96];
			wire [31:0] xs2  = xs1b_pipe[4][gl][gc];
			wire [31:0] xd2  = xd1b_pipe[4][gl][gc];
			wire [31:0] ss2  = sub_s_res[gl][gc];
			wire [31:0] sd2  = sub_d_res[gl][gc];

			(* keep = "true", dont_touch = "true" *) wire sat_s_lo = (f_s2 == 4'd14) && !is_alpha;
			(* keep = "true", dont_touch = "true" *) wire sat_s_hi = (f_s2 == 4'd14) && !is_alpha;
			(* keep = "true", dont_touch = "true" *) wire sat_d_lo = (f_d2 == 4'd14) && !is_alpha;
			(* keep = "true", dont_touch = "true" *) wire sat_d_hi = (f_d2 == 4'd14) && !is_alpha;
			(* keep = "true", dont_touch = "true" *) wire nsub_s_lo = needs_sub(f_s2, is_alpha);
			(* keep = "true", dont_touch = "true" *) wire nsub_s_hi = needs_sub(f_s2, is_alpha);
			(* keep = "true", dont_touch = "true" *) wire nsub_d_lo = needs_sub(f_d2, is_alpha);
			(* keep = "true", dont_touch = "true" *) wire nsub_d_hi = needs_sub(f_d2, is_alpha);

			wire [31:0] xs_ns_w = {
				sat_s_hi ? sa2_m[31:16] : (nsub_s_hi ? ss2[31:16] : xs2[31:16]),
				sat_s_lo ? sa2_m[15:0]  : (nsub_s_lo ? ss2[15:0]  : xs2[15:0])
			};
			wire [31:0] xd_ns_w = {
				sat_d_hi ? sa2_m[31:16] : (nsub_d_hi ? sd2[31:16] : xd2[31:16]),
				sat_d_lo ? sa2_m[15:0]  : (nsub_d_lo ? sd2[15:0]  : xd2[15:0])
			};

			wire le_sats_w, nan_sats_w;
			wire le_satd_w, nan_satd_w;
			wire le_sd_w, le_ds_w, nan_sd_w, nan_ds_unused;

			atg_rop_fblend_fle u_fle_sats (.a(sa2_f), .b(ss2), .le(le_sats_w), .has_nan(nan_sats_w));
			atg_rop_fblend_fle u_fle_satd (.a(sa2_f), .b(sd2), .le(le_satd_w), .has_nan(nan_satd_w));
			atg_rop_fblend_fle u_fle_sd   (.a(sc2),   .b(dc2), .le(le_sd_w),   .has_nan(nan_sd_w));
			atg_rop_fblend_fle u_fle_ds   (.a(dc2),   .b(sc2), .le(le_ds_w),   .has_nan(nan_ds_unused));

			always @(posedge clk) begin
				if (pe_leaf[E2A + 0])  r2a_xs_ns[gl][gc][15:0]  <= xs_ns_w[15:0];
				if (pe_leaf[E2A + 1])  r2a_xs_ns[gl][gc][31:16] <= xs_ns_w[31:16];
				if (pe_leaf[E2A + 2])  r2a_xd_ns[gl][gc][15:0]  <= xd_ns_w[15:0];
				if (pe_leaf[E2A + 3])  r2a_xd_ns[gl][gc][31:16] <= xd_ns_w[31:16];
				if (pe_leaf[E2A + 4])  r2a_sub_s[gl][gc][15:0]  <= ss2[15:0];
				if (pe_leaf[E2A + 5])  r2a_sub_s[gl][gc][31:16] <= ss2[31:16];
				if (pe_leaf[E2A + 6])  r2a_sub_d[gl][gc][15:0]  <= sd2[15:0];
				if (pe_leaf[E2A + 7])  r2a_sub_d[gl][gc][31:16] <= sd2[31:16];
				if (pe_leaf[E2A + 8])  r2a_sc[gl][gc][15:0]     <= sc2[15:0];
				if (pe_leaf[E2A + 9])  r2a_sc[gl][gc][31:16]    <= sc2[31:16];
				if (pe_leaf[E2A + 10]) r2a_dc[gl][gc][15:0]     <= dc2[15:0];
				if (pe_leaf[E2A + 11]) r2a_dc[gl][gc][31:16]    <= dc2[31:16];
				if (pe_leaf[E2A + 12]) begin
					r2a_le_sats[gl][gc]  <= {2{le_sats_w}};
					r2a_le_satd[gl][gc]  <= {2{le_satd_w}};
					r2a_nan_sats[gl][gc] <= {2{nan_sats_w}};
					r2a_nan_satd[gl][gc] <= {2{nan_satd_w}};
					r2a_sat_s[gl][gc]    <= {sat_s_hi, sat_s_lo};
					r2a_sat_d[gl][gc]    <= {sat_d_hi, sat_d_lo};
				end
				if (pe_leaf[E2A + 13]) begin
					r2a_le_sd[gl][gc]  <= {2{le_sd_w}};
					r2a_le_ds[gl][gc]  <= {2{le_ds_w}};
					r2a_nan_sd[gl][gc] <= {2{nan_sd_w}};
					r2a_op_lo[gl][gc]  <= op2_c;
					r2a_op_hi[gl][gc]  <= op2_c;
					r2a_bl_en[gl][gc]  <= {2{bl_w[0]}};
					if (gl == 0) begin
						r2a_op_ctrl[gc]    <= op2_c;
						r2a_bl_en_ctrl[gc] <= bl_w[0];
					end
				end
			end
		end
	end
	endgenerate

	/* =========================================================================
	 * STAGE 2B: Multiplier Operand Mux & Registration (1 cycle)
	 * Registers p_in_a, p_in_b, q_in_a, q_in_b so atg_rop_fmul has Pre-DSP LUTs = 0!
	 * ========================================================================= */
	reg [31:0] r2b_pa [0:3][0:3];
	reg [31:0] r2b_pb [0:3][0:3];
	reg [31:0] r2b_qa [0:3][0:3];
	reg [31:0] r2b_qb [0:3][0:3];
	reg [127:0] r2b_bypass [0:3];
	reg [3:0] r2b_sub_sel;
	reg [3:0] r2b_use_pq;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt2b;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm2b, lanes2b;
	reg v2b, known2b;

	wire [3:0] sub_sel2b_w, use_pq2b_w;
	generate
	for (gc = 0; gc < 4; gc = gc + 1) begin : g_s2b_ctrl
		wire [2:0] op_c = r2a_op_ctrl[gc];
		assign sub_sel2b_w[gc] = (op_c == 3'd1) || (op_c == 3'd2);
		assign use_pq2b_w[gc]  = r2a_bl_en_ctrl[gc] && (op_c != 3'd3) && (op_c != 3'd4);
	end
	endgenerate

	always @(posedge clk) begin
		if (rst_sync) begin
			v2b         <= 1'b0;
			known2b     <= 1'b0;
			fmt2b       <= 8'd0;
			wm2b        <= 4'd0;
			lanes2b     <= 4'd0;
			r2b_sub_sel <= 4'd0;
			r2b_use_pq  <= 4'd0;
		end else if (pe_leaf[1521]) begin
			v2b         <= v2a;
			known2b     <= known2a;
			fmt2b       <= fmt2a;
			wm2b        <= wm2a;
			lanes2b     <= lanes2a;
			r2b_sub_sel <= sub_sel2b_w;
			r2b_use_pq  <= use_pq2b_w;
		end
	end

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_s2b_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_s2b_c
			localparam integer E2B = 1522 + (gl * 4 + gc) * 10;
			(* keep = "true", dont_touch = "true" *) wire [15:0] fsc_lo = r2a_sat_s[gl][gc][0] ?
				(r2a_nan_sats[gl][gc][0] ? 16'h0000 : (r2a_le_sats[gl][gc][0] ? r2a_xs_ns[gl][gc][15:0]  : r2a_sub_s[gl][gc][15:0]))  : r2a_xs_ns[gl][gc][15:0];
			(* keep = "true", dont_touch = "true" *) wire [15:0] fsc_hi = r2a_sat_s[gl][gc][1] ?
				(r2a_nan_sats[gl][gc][1] ? 16'h7FC0 : (r2a_le_sats[gl][gc][1] ? r2a_xs_ns[gl][gc][31:16] : r2a_sub_s[gl][gc][31:16])) : r2a_xs_ns[gl][gc][31:16];
			(* keep = "true", dont_touch = "true" *) wire [15:0] fdc_lo = r2a_sat_d[gl][gc][0] ?
				(r2a_nan_satd[gl][gc][0] ? 16'h0000 : (r2a_le_satd[gl][gc][0] ? r2a_xd_ns[gl][gc][15:0]  : r2a_sub_d[gl][gc][15:0]))  : r2a_xd_ns[gl][gc][15:0];
			(* keep = "true", dont_touch = "true" *) wire [15:0] fdc_hi = r2a_sat_d[gl][gc][1] ?
				(r2a_nan_satd[gl][gc][1] ? 16'h7FC0 : (r2a_le_satd[gl][gc][1] ? r2a_xd_ns[gl][gc][31:16] : r2a_sub_d[gl][gc][31:16])) : r2a_xd_ns[gl][gc][31:16];

			(* keep = "true", dont_touch = "true" *) wire is_rev_pa_lo = (r2a_op_lo[gl][gc] == 3'd2);
			(* keep = "true", dont_touch = "true" *) wire is_rev_pa_hi = (r2a_op_hi[gl][gc] == 3'd2);
			(* keep = "true", dont_touch = "true" *) wire is_rev_pb_lo = (r2a_op_lo[gl][gc] == 3'd2);
			(* keep = "true", dont_touch = "true" *) wire is_rev_pb_hi = (r2a_op_hi[gl][gc] == 3'd2);
			(* keep = "true", dont_touch = "true" *) wire is_rev_qa_lo = (r2a_op_lo[gl][gc] == 3'd2);
			(* keep = "true", dont_touch = "true" *) wire is_rev_qa_hi = (r2a_op_hi[gl][gc] == 3'd2);
			(* keep = "true", dont_touch = "true" *) wire is_rev_qb_lo = (r2a_op_lo[gl][gc] == 3'd2);
			(* keep = "true", dont_touch = "true" *) wire is_rev_qb_hi = (r2a_op_hi[gl][gc] == 3'd2);
			(* keep = "true", dont_touch = "true" *) wire is_min_lo    = (r2a_op_lo[gl][gc] == 3'd3);
			(* keep = "true", dont_touch = "true" *) wire is_min_hi    = (r2a_op_hi[gl][gc] == 3'd3);

			(* keep = "true", dont_touch = "true" *) wire [31:0] pa_w = {is_rev_pa_hi ? r2a_dc[gl][gc][31:16] : r2a_sc[gl][gc][31:16], is_rev_pa_lo ? r2a_dc[gl][gc][15:0] : r2a_sc[gl][gc][15:0]};
			(* keep = "true", dont_touch = "true" *) wire [31:0] pb_w = {is_rev_pb_hi ? fdc_hi : fsc_hi, is_rev_pb_lo ? fdc_lo : fsc_lo};
			(* keep = "true", dont_touch = "true" *) wire [31:0] qa_w = {is_rev_qa_hi ? r2a_sc[gl][gc][31:16] : r2a_dc[gl][gc][31:16], is_rev_qa_lo ? r2a_sc[gl][gc][15:0] : r2a_dc[gl][gc][15:0]};
			(* keep = "true", dont_touch = "true" *) wire [31:0] qb_w = {is_rev_qb_hi ? fsc_hi : fdc_hi, is_rev_qb_lo ? fsc_lo : fdc_lo};

			(* keep = "true", dont_touch = "true" *) wire [15:0] minmax_lo = r2a_nan_sd[gl][gc][0] ? 16'h0000 :
				is_min_lo ? (r2a_le_sd[gl][gc][0] ? r2a_sc[gl][gc][15:0]  : r2a_dc[gl][gc][15:0]) :
				            (r2a_le_ds[gl][gc][0] ? r2a_sc[gl][gc][15:0]  : r2a_dc[gl][gc][15:0]);
			(* keep = "true", dont_touch = "true" *) wire [15:0] minmax_hi = r2a_nan_sd[gl][gc][1] ? 16'h7FC0 :
				is_min_hi ? (r2a_le_sd[gl][gc][1] ? r2a_sc[gl][gc][31:16] : r2a_dc[gl][gc][31:16]) :
				            (r2a_le_ds[gl][gc][1] ? r2a_sc[gl][gc][31:16] : r2a_dc[gl][gc][31:16]);
			(* keep = "true", dont_touch = "true" *) wire [31:0] byp_w = {
				(!r2a_bl_en[gl][gc][1]) ? r2a_sc[gl][gc][31:16] : minmax_hi,
				(!r2a_bl_en[gl][gc][0]) ? r2a_sc[gl][gc][15:0]  : minmax_lo
			};

			always @(posedge clk) begin
				if (pe_leaf[E2B + 0]) r2b_pa[gl][gc][15:0]              <= pa_w[15:0];
				if (pe_leaf[E2B + 1]) r2b_pa[gl][gc][31:16]             <= pa_w[31:16];
				if (pe_leaf[E2B + 2]) r2b_pb[gl][gc][15:0]              <= pb_w[15:0];
				if (pe_leaf[E2B + 3]) r2b_pb[gl][gc][31:16]             <= pb_w[31:16];
				if (pe_leaf[E2B + 4]) r2b_qa[gl][gc][15:0]              <= qa_w[15:0];
				if (pe_leaf[E2B + 5]) r2b_qa[gl][gc][31:16]             <= qa_w[31:16];
				if (pe_leaf[E2B + 6]) r2b_qb[gl][gc][15:0]              <= qb_w[15:0];
				if (pe_leaf[E2B + 7]) r2b_qb[gl][gc][31:16]             <= qb_w[31:16];
				if (pe_leaf[E2B + 8]) r2b_bypass[gl][32 * gc +: 16]     <= byp_w[15:0];
				if (pe_leaf[E2B + 9]) r2b_bypass[gl][32 * gc + 16 +: 16] <= byp_w[31:16];
			end
		end
	end
	endgenerate

	/* =========================================================================
	 * STAGE 2C: 5-Stage fp32 Multipliers P = s * Fs, Q = d * Fd (Latency: 5 cycles)
	 * ========================================================================= */
	wire [31:0] p_mul_out [0:3][0:3];
	wire [31:0] q_mul_out [0:3][0:3];
	reg v2c_pipe [0:4];
`ifdef SYNTH_KINTEX7
	wire mul_clk = clk;
`else
	reg mul_icg_en;
	always @(negedge clk) begin
		if (rst_sync)
			mul_icg_en <= 1'b1;
		else
			mul_icg_en <= v2b || v2c_pipe[0] || v2c_pipe[1] || v2c_pipe[2] || v2c_pipe[3];
	end
	wire mul_clk = clk & mul_icg_en;
`endif

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_mul_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_mul_c
			localparam integer R_IDX = gl * 4 + gc;
			localparam integer EMUL = 1682 + (gl * 4 + gc) * 2;
			atg_rop_fmul #(.LAT(5)) u_mul_p (
				.clk(mul_clk), .rst_n(rst_n_sub[R_IDX]), .en(pe_leaf[EMUL]),
				.i_a(r2b_pa[gl][gc]), .i_b(r2b_pb[gl][gc]), .o_r(p_mul_out[gl][gc])
			);
			atg_rop_fmul #(.LAT(5)) u_mul_q (
				.clk(mul_clk), .rst_n(rst_n_sub[R_IDX]), .en(pe_leaf[EMUL + 1]),
				.i_a(r2b_qa[gl][gc]), .i_b(r2b_qb[gl][gc]), .o_r(q_mul_out[gl][gc])
			);
		end
	end
	endgenerate

	/* 5-stage matching pipeline for bypass, sub_sel, use_pq, fmt, wm, lanes, v, known */
	reg [127:0] bypass2c_pipe [0:4][0:3];
	reg [3:0]   sub_sel2c_pipe [0:4];
	reg [3:0]   use_pq2c_pipe [0:4];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] sub_sel2c_l [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt2c_pipe [0:4];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm2c_pipe [0:4];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] lanes2c_pipe [0:4];
	reg known2c_pipe [0:4];

	generate
	for (gst = 0; gst < 5; gst = gst + 1) begin : g_s2c_st
		localparam integer E2C = 1714 + gst * 33;
		localparam integer PREV = (gst > 0) ? (gst - 1) : 0;
		integer l2c_i, s2c_i;
		always @(posedge clk) begin
			if (rst_sync) begin
				v2c_pipe[gst]       <= 1'b0;
				known2c_pipe[gst]   <= 1'b0;
				fmt2c_pipe[gst]     <= 8'd0;
				wm2c_pipe[gst]      <= 4'd0;
				lanes2c_pipe[gst]   <= 4'd0;
				sub_sel2c_pipe[gst] <= 4'd0;
				use_pq2c_pipe[gst]  <= 4'd0;
			end else if (pe_leaf[E2C]) begin
				v2c_pipe[gst]       <= (gst == 0) ? v2b         : v2c_pipe[PREV];
				known2c_pipe[gst]   <= (gst == 0) ? known2b     : known2c_pipe[PREV];
				fmt2c_pipe[gst]     <= (gst == 0) ? fmt2b       : fmt2c_pipe[PREV];
				wm2c_pipe[gst]      <= (gst == 0) ? wm2b        : wm2c_pipe[PREV];
				lanes2c_pipe[gst]   <= (gst == 0) ? lanes2b     : lanes2c_pipe[PREV];
				sub_sel2c_pipe[gst] <= (gst == 0) ? r2b_sub_sel : sub_sel2c_pipe[PREV];
				use_pq2c_pipe[gst]  <= (gst == 0) ? r2b_use_pq  : use_pq2c_pipe[PREV];
			end
			for (l2c_i = 0; l2c_i < 4; l2c_i = l2c_i + 1) begin
				for (s2c_i = 0; s2c_i < 8; s2c_i = s2c_i + 1) begin
					if (pe_leaf[E2C + 1 + l2c_i * 8 + s2c_i]) begin
						bypass2c_pipe[gst][l2c_i][16 * s2c_i +: 16] <= (gst == 0) ? r2b_bypass[l2c_i][16 * s2c_i +: 16] : bypass2c_pipe[PREV][l2c_i][16 * s2c_i +: 16];
						if (gst == 4 && s2c_i == 0)
							sub_sel2c_l[l2c_i] <= sub_sel2c_pipe[3];
					end
				end
			end
		end
	end
	endgenerate

	/* =========================================================================
	 * STAGE 3A: 4-Stage fp32 Add/Sub P +/- Q (Latency: 4 cycles)
	 * ========================================================================= */
	wire [31:0] pq_add_out [0:3][0:3];
	reg v3a_pipe [0:3];
`ifdef SYNTH_KINTEX7
	wire add_clk = clk;
`else
	reg add_icg_en;
	always @(negedge clk) begin
		if (rst_sync)
			add_icg_en <= 1'b1;
		else
			add_icg_en <= v2c_pipe[4] || v3a_pipe[0] || v3a_pipe[1] || v3a_pipe[2];
	end
	wire add_clk = clk & add_icg_en;
`endif

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_alu_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_alu_c
			localparam integer R_IDX = gl * 4 + gc;
			localparam integer EADD = 1879 + gl * 4 + gc;
			wire add_ov_unused;
			atg_rop_fadd #(.LAT(4)) u_add_pq (
				.clk(add_clk), .rst_n(rst_n_sub[R_IDX]), .en(pe_leaf[EADD]),
				.i_valid(1'b1),
				.i_a(p_mul_out[gl][gc]),
				.i_b(q_mul_out[gl][gc]),
				.i_sub(sub_sel2c_l[gl][gc]),
				.o_valid(add_ov_unused),
				.o_r(pq_add_out[gl][gc])
			);
		end
	end
	endgenerate

	/* 4-stage matching pipeline for bypass, use_pq, fmt, wm, lanes, v, known */
	reg [127:0] bypass3a_pipe [0:3][0:3];
	reg [3:0]   use_pq3a_pipe [0:3];
	(* keep = "true", dont_touch = "true" *) reg [3:0] use_pq3a_lo [0:3];
	(* keep = "true", dont_touch = "true" *) reg [3:0] use_pq3a_hi [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt3a_pipe [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm3a_pipe [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] lanes3a_pipe [0:3];
	reg known3a_pipe [0:3];

	generate
	for (gst = 0; gst < 4; gst = gst + 1) begin : g_s3a_st
		localparam integer E3A = 1895 + gst * 33;
		localparam integer PREV = (gst > 0) ? (gst - 1) : 0;
		integer l3a_i, s3a_i;
		always @(posedge clk) begin
			if (rst_sync) begin
				v3a_pipe[gst]      <= 1'b0;
				known3a_pipe[gst]  <= 1'b0;
				fmt3a_pipe[gst]    <= 8'd0;
				wm3a_pipe[gst]     <= 4'd0;
				lanes3a_pipe[gst]  <= 4'd0;
				use_pq3a_pipe[gst] <= 4'd0;
			end else if (pe_leaf[E3A]) begin
				v3a_pipe[gst]      <= (gst == 0) ? v2c_pipe[4]      : v3a_pipe[PREV];
				known3a_pipe[gst]  <= (gst == 0) ? known2c_pipe[4]  : known3a_pipe[PREV];
				fmt3a_pipe[gst]    <= (gst == 0) ? fmt2c_pipe[4]    : fmt3a_pipe[PREV];
				wm3a_pipe[gst]     <= (gst == 0) ? wm2c_pipe[4]     : wm3a_pipe[PREV];
				lanes3a_pipe[gst]  <= (gst == 0) ? lanes2c_pipe[4]  : lanes3a_pipe[PREV];
				use_pq3a_pipe[gst] <= (gst == 0) ? use_pq2c_pipe[4] : use_pq3a_pipe[PREV];
			end
			for (l3a_i = 0; l3a_i < 4; l3a_i = l3a_i + 1) begin
				for (s3a_i = 0; s3a_i < 8; s3a_i = s3a_i + 1) begin
					if (pe_leaf[E3A + 1 + l3a_i * 8 + s3a_i]) begin
						bypass3a_pipe[gst][l3a_i][16 * s3a_i +: 16] <= (gst == 0) ? bypass2c_pipe[4][l3a_i][16 * s3a_i +: 16] : bypass3a_pipe[PREV][l3a_i][16 * s3a_i +: 16];
						if (gst == 3 && s3a_i == 0) begin
							use_pq3a_lo[l3a_i] <= use_pq3a_pipe[2];
							use_pq3a_hi[l3a_i] <= use_pq3a_pipe[2];
						end
					end
				end
			end
		end
	end
	endgenerate

	/* =========================================================================
	 * STAGE 3B: Result Select & Replicated Encoder Input Registers (1 cycle)
	 * Dedicated registers res4_srgb_a/b/c, res4_un_d0, res4_hf_d0 keep fanout <= 12!
	 * ========================================================================= */
	(* keep = "true", dont_touch = "true" *) wire [127:0] res_w [0:3];
	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_res_mux_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_res_mux_c
			assign res_w[gl][32 * gc +: 16]      = use_pq3a_lo[gl][gc] ? pq_add_out[gl][gc][15:0]  : bypass3a_pipe[3][gl][32 * gc +: 16];
			assign res_w[gl][32 * gc + 16 +: 16] = use_pq3a_hi[gl][gc] ? pq_add_out[gl][gc][31:16] : bypass3a_pipe[3][gl][32 * gc + 16 +: 16];
		end
	end
	endgenerate

	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [95:0]  res4_srgb_a [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [95:0]  res4_srgb_b [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [95:0]  res4_srgb_c [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [127:0] res4_un_d0  [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [127:0] res4_hf_d0  [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [127:0] res4_un     [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0]  res4_un3_2  [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [127:0] res4_hf     [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0]   fmt3b;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0]   wm3b, lanes3b;
	reg v3b, known3b;

	always @(posedge clk) begin
		if (rst_sync) begin
			v3b     <= 1'b0;
			known3b <= 1'b0;
			fmt3b   <= 8'd0;
			wm3b    <= 4'd0;
			lanes3b <= 4'd0;
		end else if (pe_leaf[2027]) begin
			v3b     <= v3a_pipe[3];
			known3b <= known3a_pipe[3];
			fmt3b   <= fmt3a_pipe[3];
			wm3b    <= wm3a_pipe[3];
			lanes3b <= lanes3a_pipe[3];
		end
	end

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_res4_reg_l
		localparam integer E3B = 2028 + gl * 52;
		integer s3b_i;
		always @(posedge clk) begin
			for (s3b_i = 0; s3b_i < 6; s3b_i = s3b_i + 1) begin
				if (pe_leaf[E3B + s3b_i])       res4_srgb_a[gl][16 * s3b_i +: 16] <= res_w[gl][16 * s3b_i +: 16];
				if (pe_leaf[E3B + 6 + s3b_i])   res4_srgb_b[gl][16 * s3b_i +: 16] <= res_w[gl][16 * s3b_i +: 16];
				if (pe_leaf[E3B + 12 + s3b_i])  res4_srgb_c[gl][16 * s3b_i +: 16] <= res_w[gl][16 * s3b_i +: 16];
			end
			for (s3b_i = 0; s3b_i < 8; s3b_i = s3b_i + 1) begin
				if (pe_leaf[E3B + 18 + s3b_i])  res4_un_d0[gl][16 * s3b_i +: 16]  <= res_w[gl][16 * s3b_i +: 16];
				if (pe_leaf[E3B + 26 + s3b_i])  res4_hf_d0[gl][16 * s3b_i +: 16]  <= res_w[gl][16 * s3b_i +: 16];
				if (pe_leaf[E3B + 34 + s3b_i])  res4_un[gl][16 * s3b_i +: 16]     <= res4_un_d0[gl][16 * s3b_i +: 16];
				if (pe_leaf[E3B + 42 + s3b_i])  res4_hf[gl][16 * s3b_i +: 16]     <= res4_hf_d0[gl][16 * s3b_i +: 16];
			end
			if (pe_leaf[E3B + 50]) res4_un3_2[gl][15:0]  <= res4_un_d0[gl][111:96];
			if (pe_leaf[E3B + 51]) res4_un3_2[gl][31:16] <= res4_un_d0[gl][127:112];
		end
	end
	endgenerate

	/* =========================================================================
	 * STAGE 4A..4D: 4-Stage sRGB, UNORM, and FP16 Encoders (Latency: 4 cycles)
	 * ========================================================================= */
	wire [7:0]  srgb0_out [0:3], srgb1_out [0:3], srgb2_out [0:3];
	wire [15:0] un0_out [0:3], un1_out [0:3], un2_out [0:3], un3_8_out [0:3], un3_2_out [0:3];
	wire [15:0] hf0_out [0:3], hf1_out [0:3], hf2_out [0:3], hf3_out [0:3];
	reg v4_pipe [0:3];
`ifdef SYNTH_KINTEX7
	wire enc_clk = clk;
`else
	reg enc_icg_en;
	always @(negedge clk) begin
		if (rst_sync)
			enc_icg_en <= 1'b1;
		else
			enc_icg_en <= v3b || v4_pipe[0] || v4_pipe[1] || v4_pipe[2];
	end
	wire enc_clk = clk & enc_icg_en;
`endif

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_enc_l
		localparam integer E4_BASE = 2236 + gl * 12;
		atg_srgb_enc u_enc0 (.clk(enc_clk), .rst_n(rst_n_sub[gl]), .en(pe_leaf[E4_BASE + 0]), .b_a(res4_srgb_a[gl][31:0]),  .b_b(res4_srgb_b[gl][31:0]),  .b_c(res4_srgb_c[gl][31:0]),  .srgb(srgb0_out[gl]));
		atg_srgb_enc u_enc1 (.clk(enc_clk), .rst_n(rst_n_sub[gl]), .en(pe_leaf[E4_BASE + 1]), .b_a(res4_srgb_a[gl][63:32]), .b_b(res4_srgb_b[gl][63:32]), .b_c(res4_srgb_c[gl][63:32]), .srgb(srgb1_out[gl]));
		atg_srgb_enc u_enc2 (.clk(enc_clk), .rst_n(rst_n_sub[gl]), .en(pe_leaf[E4_BASE + 2]), .b_a(res4_srgb_a[gl][95:64]), .b_b(res4_srgb_b[gl][95:64]), .b_c(res4_srgb_c[gl][95:64]), .srgb(srgb2_out[gl]));

		atg_rop_f2unorm #(.W_CONST(10)) u_un0   (.clk(enc_clk), .rst_n(rst_n_sub[4 + gl]), .en(pe_leaf[E4_BASE + 3]), .f(res4_un[gl][31:0]),   .u(un0_out[gl]));
		atg_rop_f2unorm #(.W_CONST(10)) u_un1   (.clk(enc_clk), .rst_n(rst_n_sub[4 + gl]), .en(pe_leaf[E4_BASE + 4]), .f(res4_un[gl][63:32]),  .u(un1_out[gl]));
		atg_rop_f2unorm #(.W_CONST(10)) u_un2   (.clk(enc_clk), .rst_n(rst_n_sub[4 + gl]), .en(pe_leaf[E4_BASE + 5]), .f(res4_un[gl][95:64]),  .u(un2_out[gl]));
		atg_rop_f2unorm #(.W_CONST(8))  u_un3_8 (.clk(enc_clk), .rst_n(rst_n_sub[8 + gl]), .en(pe_leaf[E4_BASE + 6]), .f(res4_un[gl][127:96]), .u(un3_8_out[gl]));
		atg_rop_f2unorm #(.W_CONST(2))  u_un3_2 (.clk(enc_clk), .rst_n(rst_n_sub[8 + gl]), .en(pe_leaf[E4_BASE + 7]), .f(res4_un3_2[gl]),      .u(un3_2_out[gl]));

		atg_rop_f2h #(.LAT(3)) u_hf0 (.clk(enc_clk), .rst_n(rst_n_sub[12 + gl]), .en(pe_leaf[E4_BASE + 8]),  .f(res4_hf[gl][31:0]),   .h(hf0_out[gl]));
		atg_rop_f2h #(.LAT(3)) u_hf1 (.clk(enc_clk), .rst_n(rst_n_sub[12 + gl]), .en(pe_leaf[E4_BASE + 9]),  .f(res4_hf[gl][63:32]),  .h(hf1_out[gl]));
		atg_rop_f2h #(.LAT(3)) u_hf2 (.clk(enc_clk), .rst_n(rst_n_sub[12 + gl]), .en(pe_leaf[E4_BASE + 10]), .f(res4_hf[gl][95:64]),  .h(hf2_out[gl]));
		atg_rop_f2h #(.LAT(3)) u_hf3 (.clk(enc_clk), .rst_n(rst_n_sub[12 + gl]), .en(pe_leaf[E4_BASE + 11]), .f(res4_hf[gl][127:96]), .h(hf3_out[gl]));
	end
	endgenerate

	/* 4-stage matching pipeline for fmt, wm, lanes, v, known */
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt4_pipe_raw  [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt4_pipe_keep [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm4_pipe_raw   [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm4_pipe_keep  [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] lanes4_pipe [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt4_raw_l  [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt4_keep_l [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm4_raw_l   [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm4_keep_l  [0:3][0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] active4_raw_l  [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] active4_keep_l [0:3];
	reg known4_pipe [0:3];

	generate
	for (gst = 0; gst < 4; gst = gst + 1) begin : g_s4_st
		localparam integer PREV = (gst > 0) ? (gst - 1) : 0;
		always @(posedge clk) begin
			if (rst_sync) begin
				v4_pipe[gst]        <= 1'b0;
				known4_pipe[gst]    <= 1'b0;
				fmt4_pipe_raw[gst]  <= 8'd0;
				fmt4_pipe_keep[gst] <= 8'd0;
				wm4_pipe_raw[gst]   <= 4'd0;
				wm4_pipe_keep[gst]  <= 4'd0;
				lanes4_pipe[gst]    <= 4'd0;
			end else if (pe_leaf[2284 + (gst / 2)]) begin
				v4_pipe[gst]        <= (gst == 0) ? v3b     : v4_pipe[PREV];
				known4_pipe[gst]    <= (gst == 0) ? known3b : known4_pipe[PREV];
				fmt4_pipe_raw[gst]  <= (gst == 0) ? fmt3b   : fmt4_pipe_raw[PREV];
				fmt4_pipe_keep[gst] <= (gst == 0) ? fmt3b   : fmt4_pipe_keep[PREV];
				wm4_pipe_raw[gst]   <= (gst == 0) ? wm3b    : wm4_pipe_raw[PREV];
				wm4_pipe_keep[gst]  <= (gst == 0) ? wm3b    : wm4_pipe_keep[PREV];
				lanes4_pipe[gst]    <= (gst == 0) ? lanes3b : lanes4_pipe[PREV];
			end
		end
	end
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_s4_l_rep
		integer p4_i;
		always @(posedge clk) begin
			if (rst_sync) begin
				active4_raw_l[gl]  <= 4'd0;
				active4_keep_l[gl] <= 4'd0;
				for (p4_i = 0; p4_i < 4; p4_i = p4_i + 1) begin
					fmt4_raw_l[gl][p4_i]  <= 8'd0;
					fmt4_keep_l[gl][p4_i] <= 8'd0;
					wm4_raw_l[gl][p4_i]   <= 4'd0;
					wm4_keep_l[gl][p4_i]  <= 4'd0;
				end
			end else begin
				if (pe_leaf[2286 + gl * 2]) begin
					for (p4_i = 0; p4_i < 4; p4_i = p4_i + 1) begin
						fmt4_raw_l[gl][p4_i]  <= fmt4_pipe_raw[2];
						fmt4_keep_l[gl][p4_i] <= fmt4_pipe_keep[2];
						wm4_raw_l[gl][p4_i]   <= wm4_pipe_raw[2];
						wm4_keep_l[gl][p4_i]  <= wm4_pipe_keep[2];
					end
					active4_raw_l[gl]  <= {4{known4_pipe[2] && lanes4_pipe[2][gl]}};
					active4_keep_l[gl] <= {4{known4_pipe[2] && lanes4_pipe[2][gl]}};
				end
			end
		end
	end
	endgenerate

	/* =========================================================================
	 * STAGE 4E: Output Pack & Final Registers (Latency: 1 cycle)
	 * ========================================================================= */
	wire [255:0] raw_out_w, keep_out_w;

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_pack_l
		wire [7:0] srgb0 = srgb0_out[gl];
		wire [7:0] srgb1 = srgb1_out[gl];
		wire [7:0] srgb2 = srgb2_out[gl];
		wire [9:0] un0   = un0_out[gl][9:0];
		wire [9:0] un1   = un1_out[gl][9:0];
		wire [9:0] un2   = un2_out[gl][9:0];
		wire [7:0] un3_8 = un3_8_out[gl][7:0];
		wire [1:0] un3_2 = un3_2_out[gl][1:0];
		wire [15:0] hf0  = hf0_out[gl];
		wire [15:0] hf1  = hf1_out[gl];
		wire [15:0] hf2  = hf2_out[gl];
		wire [15:0] hf3  = hf3_out[gl];

		for (gc = 0; gc < 4; gc = gc + 1) begin : g_pack_q
			wire [7:0] fmt_raw_q  = fmt4_raw_l[gl][gc];
			wire [7:0] fmt_keep_q = fmt4_keep_l[gl][gc];
			wire [3:0] wm_raw_q   = wm4_raw_l[gl][gc];
			wire [3:0] wm_keep_q  = wm4_keep_l[gl][gc];
			reg [63:0] pk_raw_q;
			reg [63:0] pk_keep_q;

			always @(*) begin
				pk_raw_q = 64'd0;
				case (fmt_raw_q)
				8'd43, 8'd57: pk_raw_q[31:0] = {wm_raw_q[3] ? un3_8 : 8'd0, wm_raw_q[2] ? srgb2 : 8'd0, wm_raw_q[1] ? srgb1 : 8'd0, wm_raw_q[0] ? srgb0 : 8'd0};
				8'd50:        pk_raw_q[31:0] = {wm_raw_q[3] ? un3_8 : 8'd0, wm_raw_q[0] ? srgb0 : 8'd0, wm_raw_q[1] ? srgb1 : 8'd0, wm_raw_q[2] ? srgb2 : 8'd0};
				8'd64:        pk_raw_q[31:0] = {wm_raw_q[3] ? un3_2 : 2'd0, wm_raw_q[2] ? un2 : 10'd0, wm_raw_q[1] ? un1 : 10'd0, wm_raw_q[0] ? un0 : 10'd0};
				8'd76:        pk_raw_q       = {48'd0, wm_raw_q[0] ? hf0 : 16'd0};
				8'd83:        pk_raw_q       = {32'd0, wm_raw_q[1] ? hf1 : 16'd0, wm_raw_q[0] ? hf0 : 16'd0};
				8'd97:        pk_raw_q       = {wm_raw_q[3] ? hf3 : 16'd0, wm_raw_q[2] ? hf2 : 16'd0, wm_raw_q[1] ? hf1 : 16'd0, wm_raw_q[0] ? hf0 : 16'd0};
				default:      pk_raw_q       = 64'd0;
				endcase
			end

			always @(*) begin
				pk_keep_q = {64{1'b1}};
				case (fmt_keep_q)
				8'd43, 8'd57: pk_keep_q[31:0] = {wm_keep_q[3] ? 8'd0 : 8'hFF, wm_keep_q[2] ? 8'd0 : 8'hFF, wm_keep_q[1] ? 8'd0 : 8'hFF, wm_keep_q[0] ? 8'd0 : 8'hFF};
				8'd50:        pk_keep_q[31:0] = {wm_keep_q[3] ? 8'd0 : 8'hFF, wm_keep_q[0] ? 8'd0 : 8'hFF, wm_keep_q[1] ? 8'd0 : 8'hFF, wm_keep_q[2] ? 8'd0 : 8'hFF};
				8'd64:        pk_keep_q[31:0] = {wm_keep_q[3] ? 2'd0 : 2'b11, wm_keep_q[2] ? 10'd0 : 10'h3FF, wm_keep_q[1] ? 10'd0 : 10'h3FF, wm_keep_q[0] ? 10'd0 : 10'h3FF};
				8'd76:        pk_keep_q       = {48'hFFFF_FFFF_FFFF, wm_keep_q[0] ? 16'd0 : 16'hFFFF};
				8'd83:        pk_keep_q       = {32'hFFFF_FFFF, wm_keep_q[1] ? 16'd0 : 16'hFFFF, wm_keep_q[0] ? 16'd0 : 16'hFFFF};
				8'd97:        pk_keep_q       = {wm_keep_q[3] ? 16'd0 : 16'hFFFF, wm_keep_q[2] ? 16'd0 : 16'hFFFF, wm_keep_q[1] ? 16'd0 : 16'hFFFF, wm_keep_q[0] ? 16'd0 : 16'hFFFF};
				default:      pk_keep_q       = {64{1'b1}};
				endcase
			end

			(* keep = "true" *) wire [15:0] raw_slice_w  = active4_raw_l[gl][gc]  ? pk_raw_q[16 * gc +: 16]  : 16'd0;
			(* keep = "true" *) wire [15:0] keep_slice_w = active4_keep_l[gl][gc] ? pk_keep_q[16 * gc +: 16] : 16'hFFFF;
			assign raw_out_w[64 * gl + 16 * gc +: 16]  = raw_slice_w;
			assign keep_out_w[64 * gl + 16 * gc +: 16] = keep_slice_w;

			wire unused_pk_q = &{1'b0, pk_raw_q, pk_keep_q};
		end

		wire unused_un_bits = &{1'b0, un0_out[gl][15:10], un1_out[gl][15:10], un2_out[gl][15:10],
			un3_8_out[gl][15:8], un3_2_out[gl][15:2]};
	end
	endgenerate

	(* max_fanout = 16 *) reg [255:0] r_raw, r_keep;
	reg r_valid;
	integer out_i;

	always @(posedge clk) begin
		if (rst_sync) begin
			r_valid <= 1'b0;
		end else if (out_en_root[2]) begin
			r_valid <= v4_pipe[3];
		end
		for (out_i = 0; out_i < 16; out_i = out_i + 1) begin
			if (out_en_leaf[out_i])
				r_raw[16 * out_i +: 16]  <= raw_out_w[16 * out_i +: 16];
			if (out_en_leaf[16 + out_i])
				r_keep[16 * out_i +: 16] <= keep_out_w[16 * out_i +: 16];
		end
	end

	assign o_valid = r_valid;
	assign o_raw   = r_raw;
	assign o_keep  = r_keep;

`ifndef SYNTH_KINTEX7
	assign pe_leaf = {2496{1'b1}};
`endif

	wire unused_pe = &{1'b0, pe_leaf, PFF, fmt4_pipe_raw[3], fmt4_pipe_keep[3], wm4_pipe_raw[3], wm4_pipe_keep[3], lanes4_pipe[3], known4_pipe[3]};
endmodule

/* Pure-LUT 4-level fp32 <= comparator with NaN detection (0 CARRY4s, <= 4 LUT levels) */
module atg_rop_fblend_fle (
	input wire [31:0] a,
	input wire [31:0] b,
	output wire le,
	output wire has_nan
);
`ifdef SYNTH_KINTEX7
	/* Level 1: 3-bit magnitude slices for bits [26:0], 2-bit slice for [28:27], zero/NaN sub-blocks */
	(* keep = "true" *) wire le0_0 = (~a[2] & b[2]) |
		((a[2] ~^ b[2]) & ((~a[1] & b[1]) | ((a[1] ~^ b[1]) & (~a[0] | b[0]))));
	(* keep = "true" *) wire ge0_0 = (a[2] & ~b[2]) |
		((a[2] ~^ b[2]) & ((a[1] & ~b[1]) | ((a[1] ~^ b[1]) & (a[0] | ~b[0]))));

	(* keep = "true" *) wire [8:1] lt0, gt0, eq0;
	genvar i;
	generate
	for (i = 1; i < 9; i = i + 1) begin : g_s0
		wire [2:0] sa = a[3 * i +: 3];
		wire [2:0] sb = b[3 * i +: 3];
		assign eq0[i] = (sa == sb);
		assign lt0[i] = (~sa[2] & sb[2]) |
			((sa[2] ~^ sb[2]) & ((~sa[1] & sb[1]) | ((sa[1] ~^ sb[1]) & (~sa[0] & sb[0]))));
		assign gt0[i] = (sa[2] & ~sb[2]) |
			((sa[2] ~^ sb[2]) & ((sa[1] & ~sb[1]) | ((sa[1] ~^ sb[1]) & (sa[0] & ~sb[0]))));
	end
	endgenerate

	(* keep = "true" *) wire eq_top_lo = (a[28:27] == b[28:27]);
	(* keep = "true" *) wire lt_top_lo = (~a[28] & b[28]) | ((a[28] ~^ b[28]) & (~a[27] & b[27]));
	(* keep = "true" *) wire gt_top_lo = (a[28] & ~b[28]) | ((a[28] ~^ b[28]) & (a[27] & ~b[27]));

	(* keep = "true" *) wire [3:0] a_mnz, b_mnz;
	assign a_mnz[0] = (a[5:0]   != 6'd0);
	assign a_mnz[1] = (a[11:6]  != 6'd0);
	assign a_mnz[2] = (a[17:12] != 6'd0);
	assign a_mnz[3] = (a[22:18] != 5'd0);
	assign b_mnz[0] = (b[5:0]   != 6'd0);
	assign b_mnz[1] = (b[11:6]  != 6'd0);
	assign b_mnz[2] = (b[17:12] != 6'd0);
	assign b_mnz[3] = (b[22:18] != 5'd0);

	(* keep = "true" *) wire a_elo = &a[28:23];
	(* keep = "true" *) wire b_elo = &b[28:23];
	(* keep = "true" *) wire a_ez0 = (a[26:23] == 4'd0);
	(* keep = "true" *) wire a_ez1 = (a[30:27] == 4'd0);
	(* keep = "true" *) wire b_ez0 = (b[26:23] == 4'd0);
	(* keep = "true" *) wire b_ez1 = (b[30:27] == 4'd0);

	/* Level 2: 9-bit group combines for [26:0], 4-bit top combine for [30:27], zero & mantissa flags */
	(* keep = "true" *) wire le1_0 = lt0[2] | (eq0[2] & (lt0[1] | (eq0[1] & le0_0)));
	(* keep = "true" *) wire ge1_0 = gt0[2] | (eq0[2] & (gt0[1] | (eq0[1] & ge0_0)));

	(* keep = "true" *) wire eq1_1 = eq0[5] & eq0[4] & eq0[3];
	(* keep = "true" *) wire lt1_1 = lt0[5] | (eq0[5] & (lt0[4] | (eq0[4] & lt0[3])));
	(* keep = "true" *) wire gt1_1 = gt0[5] | (eq0[5] & (gt0[4] | (eq0[4] & gt0[3])));

	(* keep = "true" *) wire eq1_2 = eq0[8] & eq0[7] & eq0[6];
	(* keep = "true" *) wire lt1_2 = lt0[8] | (eq0[8] & (lt0[7] | (eq0[7] & lt0[6])));
	(* keep = "true" *) wire gt1_2 = gt0[8] | (eq0[8] & (gt0[7] | (eq0[7] & gt0[6])));

	(* keep = "true" *) wire eq_top = (a[30:29] == b[30:29]) && eq_top_lo;
	(* keep = "true" *) wire lt_top = (~a[30] & b[30]) |
		((a[30] ~^ b[30]) & ((~a[29] & b[29]) | ((a[29] ~^ b[29]) & lt_top_lo)));
	(* keep = "true" *) wire gt_top = (a[30] & ~b[30]) |
		((a[30] ~^ b[30]) & ((a[29] & ~b[29]) | ((a[29] ~^ b[29]) & gt_top_lo)));

	(* keep = "true" *) wire a_m_any = |a_mnz;
	(* keep = "true" *) wire b_m_any = |b_mnz;
	(* keep = "true" *) wire a_is_zero = a_ez1 && a_ez0 && !(|a_mnz);
	(* keep = "true" *) wire b_is_zero = b_ez1 && b_ez0 && !(|b_mnz);

	/* Level 3: 27-bit signed-gated compares, top decision, and NaN flags (each <= 6 inputs) */
	(* keep = "true" *) wire pos_le_26 = (!a[31]) && (lt1_2 | (eq1_2 & (lt1_1 | (eq1_1 & le1_0))));
	(* keep = "true" *) wire neg_ge_26 = a[31]    && (gt1_2 | (eq1_2 & (gt1_1 | (eq1_1 & ge1_0))));
	(* keep = "true" *) wire same_sign_eq_top = (a[31] == b[31]) && eq_top;
	(* keep = "true" *) wire force_le_1 = (a[31] && !b[31]) ||
		(!a[31] && b[31] && a_is_zero && b_is_zero) ||
		(!a[31] && !b[31] && lt_top) ||
		(a[31] && b[31] && gt_top);
	(* keep = "true" *) wire a_nan = a[30] && a[29] && a_elo && a_m_any;
	(* keep = "true" *) wire b_nan = b[30] && b[29] && b_elo && b_m_any;

	/* Level 4: Final 6-input LUT6 for le and 2-input LUT2 for has_nan */
	(* keep = "true", dont_touch = "true" *) wire has_nan_out = a_nan || b_nan;
	(* keep = "true", dont_touch = "true" *) wire le_out = (!a_nan) && (!b_nan) &&
		(force_le_1 || (same_sign_eq_top && (pos_le_26 || neg_ge_26)));

	assign has_nan = has_nan_out;
	assign le      = le_out;
`else
	wire a_nan = (&a[30:23]) && (a[22:0] != 23'd0);
	wire b_nan = (&b[30:23]) && (b[22:0] != 23'd0);
	wire both_zero = (a[30:0] == 31'd0) && (b[30:0] == 31'd0);
	wire ka_le_kb = (a[30:0] <= b[30:0]);
	wire ka_ge_kb = (a[30:0] >= b[30:0]);
	assign has_nan = a_nan || b_nan;
	assign le = !a_nan && !b_nan &&
		(a[31] ? (b[31] ? ka_ge_kb : 1'b1) : (b[31] ? both_zero : ka_le_kb));
`endif
endmodule

/*
 * atg_rop_f2h: 3-stage pipelined fp32 to fp16 RNE converter (LAT = 3).
 * Zero CARRY4s, <= 3 LUT levels per stage, bit-exact with am_fp_f2h.
 */
(* keep_hierarchy = "yes" *)
module atg_rop_f2h #(
	parameter integer LAT = 3
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [31:0] f,
	output wire [15:0] h
);
	wire [4:0] en_s1 = {5{en}};
	wire [4:0] en_s2 = {5{en}};
	wire en_s3 = en;

	/* =========================================================================
	 * Stage 1: Exponent classification, normal rounding ci, and denorm shift amt
	 * (0 CARRY4s, <= 2 LUT levels)
	 * ========================================================================= */
	wire [7:0] e = f[30:23];
	(* keep = "true" *) wire [3:0] m_mnz;
	assign m_mnz[0] = (f[5:0]   != 6'd0);
	assign m_mnz[1] = (f[11:6]  != 6'd0);
	assign m_mnz[2] = (f[17:12] != 6'd0);
	assign m_mnz[3] = (f[22:18] != 5'd0);
	wire m_nz = |m_mnz;

	wire is_ff     = (&e[7:4]) && (&e[3:0]);
	wire is_nan_w  = is_ff && m_nz;
	wire is_inf_w  = is_ff && !m_nz;
	wire is_gt142_w = !is_ff && e[7] && ((e[6:4] != 3'd0) || (&e[3:0]));
	wire is_142_w  = (e[7:4] == 4'h8) && (e[3:0] == 4'hE);
	wire is_norm_w = (!e[7] && (e[6:4] == 3'b111) && (e[3:0] != 4'd0)) ||
	                 (e[7]  && (e[6:4] == 3'b000) && !(&e[3:0]));
	wire is_denorm_w = !e[7] && (((e[6:4] == 3'b110) && (e[3] || (e[2:1] == 2'b11))) ||
	                             ((e[6:4] == 3'b111) && (e[3:0] == 4'd0)));

	wire norm_ci_w = f[12] && (f[13] || m_mnz[1] || m_mnz[0]);

	/* e - 112 mod 32 = {~e[4], e[3:0]}; e - 111 mod 32 = ex0 + 1 */
	wire [4:0] ex0_w = {~e[4], e[3:0]};
	wire [4:0] ex1_w = {
		ex0_w[4] ^ (&ex0_w[3:0]),
		ex0_w[3] ^ (&ex0_w[2:0]),
		ex0_w[2] ^ (&ex0_w[1:0]),
		ex0_w[1] ^ ex0_w[0],
		~ex0_w[0]
	};

	/* sh = 30 - e[4:0] = (~e[4:0]) - 1; sh1 = 29 - e[4:0] = (~e[4:0]) - 2 */
	wire [4:0] ne = ~e[4:0];
	wire [4:0] sh_w = {
		ne[4] ^ (ne[3:0] == 4'd0),
		ne[3] ^ (ne[2:0] == 3'd0),
		ne[2] ^ (ne[1:0] == 2'd0),
		ne[1] ^ ~ne[0],
		~ne[0]
	};
	wire [4:0] sh1_w = {
		ne[4] ^ (ne[3:1] == 3'd0),
		ne[3] ^ (ne[2:1] == 2'd0),
		ne[2] ^ ~ne[1],
		~ne[1],
		ne[0]
	};

	reg r1_sign, r1_is_nan, r1_is_inf, r1_is_gt142, r1_is_142, r1_is_norm, r1_is_denorm, r1_norm_ci;
	reg [4:0] r1_ex0, r1_ex1;
	(* equivalent_register_removal = "no", max_fanout = 12 *) reg [4:0] r1_sh_a, r1_sh_b, r1_sh1;
	reg [23:0] r1_m;

	/* =========================================================================
	 * Stage 2: Normal mantissa increment & denorm barrel shift / guard / sticky
	 * (0 CARRY4s, <= 3 LUT levels)
	 * ========================================================================= */
	wire [10:0] m_norm = r1_m[23:13];
	(* keep = "true" *) wire q_c5 = r1_norm_ci & (&m_norm[4:0]);
	(* keep = "true" *) wire q_c10 = r1_norm_ci & (&m_norm[4:0]) & (&m_norm[9:5]);
	wire [11:0] q2_w;
	assign q2_w[0]  = m_norm[0]  ^ r1_norm_ci;
	assign q2_w[1]  = m_norm[1]  ^ (r1_norm_ci & m_norm[0]);
	assign q2_w[2]  = m_norm[2]  ^ (r1_norm_ci & (&m_norm[1:0]));
	assign q2_w[3]  = m_norm[3]  ^ (r1_norm_ci & (&m_norm[2:0]));
	assign q2_w[4]  = m_norm[4]  ^ (r1_norm_ci & (&m_norm[3:0]));
	assign q2_w[5]  = m_norm[5]  ^ q_c5;
	assign q2_w[6]  = m_norm[6]  ^ (q_c5 & m_norm[5]);
	assign q2_w[7]  = m_norm[7]  ^ (q_c5 & (&m_norm[6:5]));
	assign q2_w[8]  = m_norm[8]  ^ (q_c5 & (&m_norm[7:5]));
	assign q2_w[9]  = m_norm[9]  ^ (q_c5 & (&m_norm[8:5]));
	assign q2_w[10] = m_norm[10] ^ q_c10;
	assign q2_w[11] = q_c10 & m_norm[10];

	/* Denorm shift ds = r1_m >> r1_sh (for r1_sh in [14, 24], result is <= 11 bits) */
	wire [38:0] m_pad = {15'd0, r1_m};
	(* keep = "true" *) wire [34:0] ds_s0;
	(* keep = "true" *) wire [10:0] ds2_w;
	genvar gsi;
	generate
	for (gsi = 0; gsi < 35; gsi = gsi + 1) begin : g_ds_s0
		assign ds_s0[gsi] = (r1_sh_a[1:0] == 2'd0) ? m_pad[gsi] :
		                    (r1_sh_a[1:0] == 2'd1) ? m_pad[gsi + 1] :
		                    (r1_sh_a[1:0] == 2'd2) ? m_pad[gsi + 2] : m_pad[gsi + 3];
	end
	for (gsi = 0; gsi < 11; gsi = gsi + 1) begin : g_ds_s1
		assign ds2_w[gsi] = (r1_sh_b[4:2] == 3'd3) ? ds_s0[gsi + 12] :
		                    (r1_sh_b[4:2] == 3'd4) ? ds_s0[gsi + 16] :
		                    (r1_sh_b[4:2] == 3'd5) ? ds_s0[gsi + 20] :
		                    (r1_sh_b[4:2] == 3'd6) ? ds_s0[gsi + 24] : 1'b0;
	end
	endgenerate

	/* Guard bit g = r1_m[r1_sh1] (r1_sh1 in [13, 23]) */
	(* keep = "true" *) wire [5:0] g_nib;
	(* keep = "true" *) wire [5:0] st_nib;
	genvar gn;
	generate
	for (gn = 0; gn < 6; gn = gn + 1) begin : g_den_nib
		localparam [2:0] N_IDX = gn[2:0];
		wire [3:0] mn = r1_m[4 * gn +: 4];
		assign g_nib[gn] = (r1_sh1[1:0] == 2'd0) ? mn[0] :
		                   (r1_sh1[1:0] == 2'd1) ? mn[1] :
		                   (r1_sh1[1:0] == 2'd2) ? mn[2] : mn[3];
		(* keep = "true" *) wire nib_or = |mn;
		(* keep = "true" *) wire nib_part = (r1_sh1[1:0] == 2'd0) ? 1'b0 :
		                                    (r1_sh1[1:0] == 2'd1) ? mn[0] :
		                                    (r1_sh1[1:0] == 2'd2) ? (|mn[1:0]) : (|mn[2:0]);
		assign st_nib[gn] = (r1_sh1[4:2] > N_IDX) ? nib_or :
		                    (r1_sh1[4:2] == N_IDX) ? nib_part : 1'b0;
	end
	endgenerate
	wire g2_w  = (r1_sh1[4:2] == 3'd3) ? g_nib[3] :
	             (r1_sh1[4:2] == 3'd4) ? g_nib[4] :
	             (r1_sh1[4:2] == 3'd5) ? g_nib[5] : 1'b0;
	wire st2_w = |st_nib;

	reg r2_sign, r2_is_nan, r2_is_inf, r2_is_gt142, r2_is_142, r2_is_norm, r2_is_denorm;
	reg [4:0] r2_ex0, r2_ex1;
	reg [11:0] r2_q;
	reg [10:0] r2_ds;
	reg r2_g, r2_st;

	/* =========================================================================
	 * Stage 3: Denorm RNE increment & Final FP16 Pack + Output Register
	 * (0 CARRY4s, <= 3 LUT levels)
	 * ========================================================================= */
	(* keep = "true" *) wire den_ci = r2_g && (r2_st || r2_ds[0]);
	(* keep = "true" *) wire dr_c5  = den_ci & (&r2_ds[4:0]);
	(* keep = "true" *) wire dr_c10 = den_ci & (&r2_ds[4:0]) & (&r2_ds[9:5]);
	wire [10:0] dr;
	assign dr[0]  = r2_ds[0]  ^ den_ci;
	assign dr[1]  = r2_ds[1]  ^ (den_ci & r2_ds[0]);
	assign dr[2]  = r2_ds[2]  ^ (den_ci & (&r2_ds[1:0]));
	assign dr[3]  = r2_ds[3]  ^ (den_ci & (&r2_ds[2:0]));
	assign dr[4]  = r2_ds[4]  ^ (den_ci & (&r2_ds[3:0]));
	assign dr[5]  = r2_ds[5]  ^ dr_c5;
	assign dr[6]  = r2_ds[6]  ^ (dr_c5 & r2_ds[5]);
	assign dr[7]  = r2_ds[7]  ^ (dr_c5 & (&r2_ds[6:5]));
	assign dr[8]  = r2_ds[8]  ^ (dr_c5 & (&r2_ds[7:5]));
	assign dr[9]  = r2_ds[9]  ^ (dr_c5 & (&r2_ds[8:5]));
	assign dr[10] = r2_ds[10] ^ dr_c10;

	(* keep = "true" *) wire ovf_inf = r2_is_inf || r2_is_gt142 || (r2_is_142 && r2_q[11]);
	wire [4:0] norm_e = r2_q[11] ? r2_ex1 : r2_ex0;
	wire [9:0] norm_m = (r2_q[11:10] != 2'b01) ? 10'd0 : r2_q[9:0];

	wire [15:0] h_w;
	assign h_w[15]    = !r2_is_nan && r2_sign;
	assign h_w[14:10] = (r2_is_nan || ovf_inf) ? 5'h1F :
	                    r2_is_norm             ? norm_e :
	                                             {4'd0, r2_is_denorm & dr[10]};
	assign h_w[9]     = r2_is_nan  ? 1'b1 :
	                    ovf_inf    ? 1'b0 :
	                    r2_is_norm ? norm_m[9] :
	                                 (r2_is_denorm & dr[9]);
	assign h_w[8:0]   = (r2_is_nan || ovf_inf) ? 9'd0 :
	                    r2_is_norm             ? norm_m[8:0] :
	                    r2_is_denorm           ? dr[8:0] : 9'd0;

	(* max_fanout = 16 *) reg [15:0] r3_h;

	always @(posedge clk) begin
		if (!rst_n) begin
			r1_sign      <= 1'b0;
			r1_is_nan    <= 1'b0;
			r1_is_inf    <= 1'b0;
			r1_is_gt142  <= 1'b0;
			r1_is_142    <= 1'b0;
			r1_is_norm   <= 1'b0;
			r1_is_denorm <= 1'b0;
			r1_norm_ci   <= 1'b0;
			r2_sign      <= 1'b0;
			r2_is_nan    <= 1'b0;
			r2_is_inf    <= 1'b0;
			r2_is_gt142  <= 1'b0;
			r2_is_142    <= 1'b0;
			r2_is_norm   <= 1'b0;
			r2_is_denorm <= 1'b0;
			r3_h         <= 16'd0;
		end else begin
			if (en_s1[0]) begin
				r1_sign      <= f[31];
				r1_is_nan    <= is_nan_w;
				r1_is_inf    <= is_inf_w;
				r1_is_gt142  <= is_gt142_w;
				r1_is_142    <= is_142_w;
				r1_is_norm   <= is_norm_w;
				r1_is_denorm <= is_denorm_w;
				r1_norm_ci   <= norm_ci_w;
			end
			if (en_s2[0]) begin
				r2_sign      <= r1_sign;
				r2_is_nan    <= r1_is_nan;
				r2_is_inf    <= r1_is_inf;
				r2_is_gt142  <= r1_is_gt142;
				r2_is_142    <= r1_is_142;
				r2_is_norm   <= r1_is_norm;
				r2_is_denorm <= r1_is_denorm;
			end
			if (en_s3)
				r3_h <= h_w;
		end
		if (en_s1[1]) begin
			r1_ex0  <= ex0_w;
			r1_ex1  <= ex1_w;
		end
		if (en_s1[2]) begin
			r1_sh_a <= sh_w;
			r1_sh_b <= sh_w;
			r1_sh1  <= sh1_w;
		end
		if (en_s1[3]) r1_m[11:0]  <= f[11:0];
		if (en_s1[4]) r1_m[23:12] <= {1'b1, f[22:12]};
		if (en_s2[1]) begin
			r2_ex0 <= r1_ex0;
			r2_ex1 <= r1_ex1;
		end
		if (en_s2[2]) r2_q  <= q2_w;
		if (en_s2[3]) r2_ds <= ds2_w;
		if (en_s2[4]) begin
			r2_g  <= g2_w;
			r2_st <= st2_w;
		end
	end

	assign h = r3_h;

	wire unused_ok = &{1'b0, ds_s0[11:0], g_nib[2:0], LAT[31:0]};
endmodule

`default_nettype wire
