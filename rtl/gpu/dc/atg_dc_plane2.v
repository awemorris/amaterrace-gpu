/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_plane2: Display Controller Multi-Plane Hardware Overlay Engine.
 *
 * Implements:
 * 1. Independent video/UI overlay plane (Plane 2).
 * 2. Hardware NV12 YUV 4:2:0 -> RGB color space converter:
 *    R = Y + 1.402 * (V - 128)
 *    G = Y - 0.344 * (U - 128) - 0.714 * (V - 128)
 *    B = Y + 1.772 * (U - 128)
 *    All multiplications performed using am_mul, additions/subtractions
 *    via am_add / am_sub.
 * 3. Color Key matching and transparency pass-through.
 * 4. Per-pixel / global alpha blending over primary plane:
 *    C_out = (alpha * C_overlay + (255 - alpha) * C_primary + 128) >> 8
 * 5. Optional AMB client DMA interface and direct video stream feed.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_plane2 #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5
) (
	input  wire        clk,
	input  wire        rst_n,
	input  wire        enable,

	/* Configuration */
	input  wire        plane_en,
	input  wire [11:0] pos_x,
	input  wire [11:0] pos_y,
	input  wire [11:0] width,
	input  wire [11:0] height,
	input  wire [7:0]  alpha,
	input  wire        colorkey_en,
	input  wire [23:0] colorkey,
	input  wire        yuv_mode, /* 1: NV12 YUV, 0: RGB */

	/* Primary plane pixel stream */
	input  wire [11:0] cur_x,
	input  wire [11:0] cur_y,
	input  wire [23:0] prim_rgb,
	input  wire        prim_valid,
	output reg  [23:0] out_rgb,
	output reg         out_valid,

	/* Video overlay feed (direct stream or decoded from DMA) */
	input  wire        ov_valid,
	output wire        ov_ready,
	input  wire [7:0]  ov_y,
	input  wire [7:0]  ov_u,
	input  wire [7:0]  ov_v,
	input  wire [23:0] ov_rgb,

	/* AMB client port (for autonomous video DMA fetch) */
	output wire        req_valid,
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire        req_ready,
	/* verilator lint_on UNUSEDSIGNAL */
	output wire        req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0]  req_tag,
	input  wire        rsp_valid,
	input  wire        rsp_write,
	input  wire [7:0]  rsp_tag,
	input  wire [LINE_BYTES*8-1:0] rsp_rdata,
	input  wire        rsp_error
);
	localparam LW = LINE_BYTES * 8;
	localparam AW = ADDR_W - LINE_SHIFT;

	assign req_valid = 1'b0;
	assign req_write = 1'b0;
	assign req_line  = {AW{1'b0}};
	assign req_be    = {LINE_BYTES{1'b0}};
	assign req_wdata = {LW{1'b0}};
	assign req_tag   = 8'd0;
	assign ov_ready  = prim_valid;

	/* Bounding box end coordinates */
	wire [11:0] end_x, end_y;
	wire [1:0] box_co_unused;
	am_add #(.W(12)) a_end_x (.a(pos_x), .b(width),  .ci(1'b0), .s(end_x), .co(box_co_unused[0]));
	am_add #(.W(12)) a_end_y (.a(pos_y), .b(height), .ci(1'b0), .s(end_y), .co(box_co_unused[1]));

`ifdef SYNTH_KINTEX7
	reg [11:0] end_x_r, end_y_r;
	always @(posedge clk) begin
		end_x_r <= end_x;
		end_y_r <= end_y;
	end
	wire in_box = (cur_x >= pos_x) && (cur_x < end_x_r) && (cur_y >= pos_y) && (cur_y < end_y_r);
`else
	wire in_box = (cur_x >= pos_x) && (cur_x < end_x) && (cur_y >= pos_y) && (cur_y < end_y);
`endif

	/*
	 * YUV to RGB Conversion:
	 * diff_u = U - 128, diff_v = V - 128
	 * R_raw = (Y << 8) + 359 * diff_v
	 * G_raw = (Y << 8) - 88 * diff_u - 183 * diff_v
	 * B_raw = (Y << 8) + 454 * diff_u
	 */
	wire [8:0] diff_u, diff_v;
	wire [1:0] diff_bo_unused;
	am_sub #(.W(9)) s_diff_u (.a({1'b0, ov_u}), .b(9'd128), .bi(1'b0), .d(diff_u), .bo(diff_bo_unused[0]));
	am_sub #(.W(9)) s_diff_v (.a({1'b0, ov_v}), .b(9'd128), .bi(1'b0), .d(diff_v), .bo(diff_bo_unused[1]));

`ifdef SYNTH_KINTEX7
	localparam P2_MUL_LAT = 2;
`else
	localparam P2_MUL_LAT = 0;
`endif

	wire [18:0] p_rv, p_gu, p_gv, p_bu;
	/* Signed multipliers */
	am_mul #(.AW(9), .BW(10), .SIGNED(1), .LAT(P2_MUL_LAT)) u_mul_rv (.clk(clk), .en(1'b1), .a(diff_v), .b(10'sd359),  .p(p_rv));
	am_mul #(.AW(9), .BW(10), .SIGNED(1), .LAT(P2_MUL_LAT)) u_mul_gu (.clk(clk), .en(1'b1), .a(diff_u), .b(-10'sd88),  .p(p_gu));
	am_mul #(.AW(9), .BW(10), .SIGNED(1), .LAT(P2_MUL_LAT)) u_mul_gv (.clk(clk), .en(1'b1), .a(diff_v), .b(-10'sd183), .p(p_gv));
	am_mul #(.AW(9), .BW(10), .SIGNED(1), .LAT(P2_MUL_LAT)) u_mul_bu (.clk(clk), .en(1'b1), .a(diff_u), .b(10'sd454),  .p(p_bu));

	wire [18:0] y_scaled = {3'd0, ov_y, 8'd0};

	/* verilator lint_off UNUSEDSIGNAL */
	wire [18:0] r_raw, g_sum_u, g_raw, b_raw;
	/* verilator lint_on UNUSEDSIGNAL */
	wire [3:0] yuv_co_unused;
	am_add #(.W(19)) a_r_raw   (.a(y_scaled), .b(p_rv),    .ci(1'b0), .s(r_raw),   .co(yuv_co_unused[0]));
	am_add #(.W(19)) a_g_sum_u (.a(y_scaled), .b(p_gu),    .ci(1'b0), .s(g_sum_u), .co(yuv_co_unused[1]));
	am_add #(.W(19)) a_g_raw   (.a(g_sum_u),  .b(p_gv),    .ci(1'b0), .s(g_raw),   .co(yuv_co_unused[2]));
	am_add #(.W(19)) a_b_raw   (.a(y_scaled), .b(p_bu),    .ci(1'b0), .s(b_raw),   .co(yuv_co_unused[3]));

	/* Clamping to [0, 255] */
	wire [7:0] r_yuv = r_raw[18] ? 8'd0 : (r_raw[17:16] != 2'd0 ? 8'hFF : r_raw[15:8]);
	wire [7:0] g_yuv = g_raw[18] ? 8'd0 : (g_raw[17:16] != 2'd0 ? 8'hFF : g_raw[15:8]);
	wire [7:0] b_yuv = b_raw[18] ? 8'd0 : (b_raw[17:16] != 2'd0 ? 8'hFF : b_raw[15:8]);

	/* Selected overlay RGB */
`ifdef SYNTH_KINTEX7
	wire yuv_mode_l, yuv_mode_h;
	LUT1 #(.INIT(2'b10)) u_buf_yl (.I0(yuv_mode), .O(yuv_mode_l));
	LUT1 #(.INIT(2'b10)) u_buf_yh (.I0(yuv_mode), .O(yuv_mode_h));
	wire [23:0] sel_ov_rgb = {
		yuv_mode_h ? {r_yuv, g_yuv[7:4]} : ov_rgb[23:12],
		yuv_mode_l ? {g_yuv[3:0], b_yuv} : ov_rgb[11:0]
	};
`else
	wire [23:0] sel_ov_rgb = yuv_mode ? {r_yuv, g_yuv, b_yuv} : ov_rgb;
`endif

`ifdef SYNTH_KINTEX7
	(* max_fanout = 16 *) reg [23:0] sel_ov_rgb_q;
	(* max_fanout = 16 *) reg [23:0] prim_rgb_q;
	(* max_fanout = 16 *) reg [7:0]  alpha_q;
	always @(posedge clk) begin
		sel_ov_rgb_q <= sel_ov_rgb;
		prim_rgb_q   <= prim_rgb;
		alpha_q      <= alpha;
	end
	wire [23:0] p2_sel_ov_rgb = sel_ov_rgb_q;
	wire [23:0] p2_prim_rgb   = prim_rgb_q;
	wire [7:0]  p2_alpha      = alpha_q;
`else
	wire [23:0] p2_sel_ov_rgb = sel_ov_rgb;
	wire [23:0] p2_prim_rgb   = prim_rgb;
	wire [7:0]  p2_alpha      = alpha;
`endif

	/* Color key matching */
	wire colorkey_match = colorkey_en && (p2_sel_ov_rgb == colorkey);
	wire active_overlay = plane_en && in_box && !colorkey_match;

	/* Alpha Blending */
	wire [7:0] inv_alpha;
	wire alpha_bo_unused;
	am_sub #(.W(8)) s_inv_alpha (.a(8'hFF), .b(p2_alpha), .bi(1'b0), .d(inv_alpha), .bo(alpha_bo_unused));

	/* Red channel blending */
	wire [15:0] p_r_ov, p_r_prim;
	am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(P2_MUL_LAT)) u_mul_r_ov   (.clk(clk), .en(1'b1), .a(p2_alpha),  .b(p2_sel_ov_rgb[23:16]), .p(p_r_ov));
	am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(P2_MUL_LAT)) u_mul_r_prim (.clk(clk), .en(1'b1), .a(inv_alpha), .b(p2_prim_rgb[23:16]),   .p(p_r_prim));

	/* Green channel blending */
	wire [15:0] p_g_ov, p_g_prim;
	am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(P2_MUL_LAT)) u_mul_g_ov   (.clk(clk), .en(1'b1), .a(p2_alpha),  .b(p2_sel_ov_rgb[15:8]),  .p(p_g_ov));
	am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(P2_MUL_LAT)) u_mul_g_prim (.clk(clk), .en(1'b1), .a(inv_alpha), .b(p2_prim_rgb[15:8]),   .p(p_g_prim));

	/* Blue channel blending */
	wire [15:0] p_b_ov, p_b_prim;
	am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(P2_MUL_LAT)) u_mul_b_ov   (.clk(clk), .en(1'b1), .a(p2_alpha),  .b(p2_sel_ov_rgb[7:0]),   .p(p_b_ov));
	am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(P2_MUL_LAT)) u_mul_b_prim (.clk(clk), .en(1'b1), .a(inv_alpha), .b(p2_prim_rgb[7:0]),    .p(p_b_prim));

`ifdef SYNTH_KINTEX7
	(* max_fanout = 16 *) reg [15:0] p_r_ov_q, p_r_prim_q;
	(* max_fanout = 16 *) reg [15:0] p_g_ov_q, p_g_prim_q;
	(* max_fanout = 16 *) reg [15:0] p_b_ov_q, p_b_prim_q;
	(* max_fanout = 16 *) reg [23:0] sel_ov_rgb_q2, prim_rgb_q2;
	(* max_fanout = 16 *) reg [7:0] alpha_q2;
	(* max_fanout = 16 *) reg active_overlay_q2;
	always @(posedge clk) begin
		p_r_ov_q <= p_r_ov; p_r_prim_q <= p_r_prim;
		p_g_ov_q <= p_g_ov; p_g_prim_q <= p_g_prim;
		p_b_ov_q <= p_b_ov; p_b_prim_q <= p_b_prim;
		sel_ov_rgb_q2 <= p2_sel_ov_rgb;
		prim_rgb_q2 <= p2_prim_rgb;
		alpha_q2 <= p2_alpha;
		active_overlay_q2 <= active_overlay;
	end
	wire [15:0] d_r_ov = p_r_ov_q, d_r_prim = p_r_prim_q;
	wire [15:0] d_g_ov = p_g_ov_q, d_g_prim = p_g_prim_q;
	wire [15:0] d_b_ov = p_b_ov_q, d_b_prim = p_b_prim_q;
	wire [23:0] d_sel_ov_rgb = sel_ov_rgb_q2, d_prim_rgb = prim_rgb_q2;
	wire [7:0]  d_alpha = alpha_q2;
	wire d_active_overlay = active_overlay_q2;
`else
	wire [15:0] d_r_ov = p_r_ov, d_r_prim = p_r_prim;
	wire [15:0] d_g_ov = p_g_ov, d_g_prim = p_g_prim;
	wire [15:0] d_b_ov = p_b_ov, d_b_prim = p_b_prim;
	wire [23:0] d_sel_ov_rgb = p2_sel_ov_rgb, d_prim_rgb = p2_prim_rgb;
	wire [7:0]  d_alpha = p2_alpha;
	wire d_active_overlay = active_overlay;
`endif

	/* verilator lint_off UNUSEDSIGNAL */
	wire [16:0] sum_r_mul, sum_r_tot;
	/* verilator lint_on UNUSEDSIGNAL */
	wire [1:0] co_r_unused;
	am_add #(.W(17)) a_sum_r_mul (.a({1'b0, d_r_ov}),    .b({1'b0, d_r_prim}), .ci(1'b0), .s(sum_r_mul), .co(co_r_unused[0]));
	am_add #(.W(17)) a_sum_r_tot (.a(sum_r_mul),         .b(17'd128),          .ci(1'b0), .s(sum_r_tot), .co(co_r_unused[1]));
	wire [7:0] r_blend = (d_alpha == 8'hFF) ? d_sel_ov_rgb[23:16] : ((d_alpha == 8'h00) ? d_prim_rgb[23:16] : sum_r_tot[15:8]);

	/* verilator lint_off UNUSEDSIGNAL */
	wire [16:0] sum_g_mul, sum_g_tot;
	/* verilator lint_on UNUSEDSIGNAL */
	wire [1:0] co_g_unused;
	am_add #(.W(17)) a_sum_g_mul (.a({1'b0, d_g_ov}),    .b({1'b0, d_g_prim}), .ci(1'b0), .s(sum_g_mul), .co(co_g_unused[0]));
	am_add #(.W(17)) a_sum_g_tot (.a(sum_g_mul),         .b(17'd128),          .ci(1'b0), .s(sum_g_tot), .co(co_g_unused[1]));
	wire [7:0] g_blend = (d_alpha == 8'hFF) ? d_sel_ov_rgb[15:8]  : ((d_alpha == 8'h00) ? d_prim_rgb[15:8]  : sum_g_tot[15:8]);

	/* verilator lint_off UNUSEDSIGNAL */
	wire [16:0] sum_b_mul, sum_b_tot;
	/* verilator lint_on UNUSEDSIGNAL */
	wire [1:0] co_b_unused;
	am_add #(.W(17)) a_sum_b_mul (.a({1'b0, d_b_ov}),    .b({1'b0, d_b_prim}), .ci(1'b0), .s(sum_b_mul), .co(co_b_unused[0]));
	am_add #(.W(17)) a_sum_b_tot (.a(sum_b_mul),         .b(17'd128),          .ci(1'b0), .s(sum_b_tot), .co(co_b_unused[1]));
	wire [7:0] b_blend = (d_alpha == 8'hFF) ? d_sel_ov_rgb[7:0]   : ((d_alpha == 8'h00) ? d_prim_rgb[7:0]   : sum_b_tot[15:8]);

	(* keep = "true" *) wire rst_high = !rst_n;

	always @(posedge clk) begin
		if (rst_high) begin
			out_rgb   <= 24'd0;
			out_valid <= 1'b0;
		end else begin
			out_valid <= prim_valid;
			if (!d_active_overlay)
				out_rgb <= d_prim_rgb;
			else
				out_rgb <= {r_blend, g_blend, b_blend};
		end
	end

	wire unused_ok = &{1'b0, box_co_unused, diff_bo_unused, yuv_co_unused,
		alpha_bo_unused, co_r_unused, co_g_unused, co_b_unused,
		ov_valid, rsp_valid, rsp_write, rsp_tag, rsp_rdata, rsp_error, enable};
endmodule

`default_nettype wire
