/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_coarse: Coarse Tile Rasterizer (8x8 pixel tiles).
 *
 * Evaluates the three edge functions across 8x8 pixel tiles within the
 * triangle bounding box. Tests the conservative corner bounds of each tile:
 *   - Trivially Rejected (outside): if for any edge, all corners are further
 *     outside than the maximum MSAA sample offset reach, the entire 8x8 tile
 *     is outside the triangle and skipped in 1 cycle.
 *   - Trivially Accepted (inside): if for all three edges, all corners are
 *     further inside than the maximum MSAA sample offset (e_min > lowm), the
 *     entire 8x8 tile is inside the triangle (tile_trivial = 1).
 *   - Intersecting: boundary tile, evaluated by Fine Rasterizer.
 *
 * Arithmetic operators are prohibited; uses am_add / am_sub library modules.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_coarse (
	input wire clk,
	input wire rst_n,

	/* Setup triangle input */
	input wire tri_valid,
	output wire tri_ready,
	input wire [15:0] bbox_min_x,
	input wire [15:0] bbox_min_y,
	input wire [15:0] bbox_max_x,
	input wire [15:0] bbox_max_y,
	input wire [47:0] e0_a8,
	input wire [47:0] e0_b8,
	input wire [47:0] e0_er,
	input wire [47:0] e1_a8,
	input wire [47:0] e1_b8,
	input wire [47:0] e1_er,
	input wire [47:0] e2_a8,
	input wire [47:0] e2_b8,
	input wire [47:0] e2_er,
	input wire [47:0] lowm0,
	input wire [47:0] lowm1,
	input wire [47:0] lowm2,

	/* Coarse tile output to Fine Rasterizer */
	output reg tile_valid,
	input wire tile_ready,
	output reg [15:0] tile_x,
	output reg [15:0] tile_y,
	output wire [47:0] tile_e0,
	output wire [47:0] tile_e1,
	output wire [47:0] tile_e2,
	output reg tile_trivial,
	output reg tile_last,
	output wire busy
);
	localparam [2:0] S_IDLE = 3'd0, S_INIT = 3'd1, S_WALK = 3'd2, S_EVAL = 3'd3, S_STEP = 3'd4, S_WAIT = 3'd5;
	(* keep = "true", dont_touch = "true" *) wire coarse_rst_sync = !rst_n;
	(* fsm_encoding = "none" *) reg [2:0] st;

	(* extract_reset = "no" *) reg [15:0] bx0, by0, bx1, by1;
	(* extract_reset = "no", equivalent_register_removal = "no" *) reg signed [47:0] a8 [0:2];
	(* extract_reset = "no", equivalent_register_removal = "no" *) reg signed [47:0] b8 [0:2];
	(* extract_reset = "no", equivalent_register_removal = "no" *) reg signed [47:0] ab8 [0:2];
	(* extract_reset = "no" *) reg signed [47:0] er [0:2];
	(* extract_reset = "no" *) reg signed [47:0] ec [0:2];
	(* extract_reset = "no" *) reg [47:0] lm [0:2];

	/* Pipeline registers for clean single-stage arithmetic */
	(* extract_reset = "no", max_fanout = 16 *) reg signed [47:0] r_emax [0:2];
	(* extract_reset = "no", max_fanout = 16 *) reg signed [47:0] r_emin [0:2];
	(* extract_reset = "no", max_fanout = 16 *) reg [15:0] r_tx_next, r_ty_next;
	(* extract_reset = "no", max_fanout = 16 *) reg signed [47:0] r_ec_next [0:2];
	(* extract_reset = "no", max_fanout = 16 *) reg signed [47:0] r_er_next [0:2];
	(* max_fanout = 16 *) reg r_row_end;
	(* max_fanout = 16 *) reg r_tile_outside;
	(* max_fanout = 16 *) reg r_is_trivial;
	(* max_fanout = 16 *) reg r_last_tile;

	assign tile_e0 = ec[0];
	assign tile_e1 = ec[1];
	assign tile_e2 = ec[2];

	/* Conservative corner delta offsets: max and min deltas per edge */
	(* extract_reset = "no" *) reg signed [47:0] d_max [0:2];
	(* extract_reset = "no" *) reg signed [47:0] d_min [0:2];

	/* Step deltas: 8 pixels in x (a8 <<< 3), 8 pixels in y (b8 <<< 3) */
	wire signed [47:0] step_x [0:2];
	wire signed [47:0] step_y [0:2];

	genvar ge;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_step
		assign step_x[ge] = a8[ge] <<< 3;
		assign step_y[ge] = b8[ge] <<< 3;
	end
	endgenerate

	/* Tile evaluation: calculate E_max and E_min for each edge at current tile */
	wire signed [47:0] e_max [0:2];
	wire signed [47:0] e_min [0:2];
	wire [5:0] eval_carry_unused;

	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_eval
		am_add #(.W(48)) u_emax (.a(ec[ge]), .b(d_max[ge]), .ci(1'b0), .s(e_max[ge]),
			.co(eval_carry_unused[2 * ge]));
		am_add #(.W(48)) u_emin (.a(ec[ge]), .b(d_min[ge]), .ci(1'b0), .s(e_min[ge]),
			.co(eval_carry_unused[2 * ge + 1]));
	end
	endgenerate

	/* Any edge where E_max is further outside than lowm reach means all sample points are outside */
	wire edge0_outside = r_emax[0][47] && ((r_emax[0] | lm[0]) != {48{1'b1}});
	wire edge1_outside = r_emax[1][47] && ((r_emax[1] | lm[1]) != {48{1'b1}});
	wire edge2_outside = r_emax[2][47] && ((r_emax[2] | lm[2]) != {48{1'b1}});
	wire tile_outside = edge0_outside || edge1_outside || edge2_outside;

	/* All edges where E_min > lowm means all sample points in tile are unconditionally inside */
	wire signed [47:0] slm0 = lm[0];
	wire signed [47:0] slm1 = lm[1];
	wire signed [47:0] slm2 = lm[2];
	wire edge0_inside = !r_emin[0][47] && (r_emin[0] > slm0);
	wire edge1_inside = !r_emin[1][47] && (r_emin[1] > slm1);
	wire edge2_inside = !r_emin[2][47] && (r_emin[2] > slm2);
	wire all_inside = edge0_inside && edge1_inside && edge2_inside;

	/* Stepping arithmetic for coordinates */
	wire [15:0] tx_next;
	wire [15:0] ty_next;
	wire [1:0] coord_carry_unused;
	am_add #(.W(16)) u_tx_next (.a(tile_x), .b(16'd8), .ci(1'b0), .s(tx_next), .co(coord_carry_unused[0]));
	am_add #(.W(16)) u_ty_next (.a(tile_y), .b(16'd8), .ci(1'b0), .s(ty_next), .co(coord_carry_unused[1]));

	wire row_end = r_tx_next >= bx1;
	wire last_tile = row_end && (r_ty_next >= by1);

	/* Check if tile is fully within bounding box (no scissor/bbox clipping of corners) */
	wire tile_in_bbox = (tile_x >= bx0) && (r_tx_next <= bx1) &&
	                    (tile_y >= by0) && (r_ty_next <= by1);
	wire is_trivial = all_inside && tile_in_bbox;

	/* Stepping arithmetic for edge values */
	wire signed [47:0] ec_next [0:2];
	wire signed [47:0] er_next [0:2];
	wire [5:0] step_carry_unused;

	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_step_edge
		am_add #(.W(48)) u_ec_next (.a(ec[ge]), .b(step_x[ge]), .ci(1'b0), .s(ec_next[ge]),
			.co(step_carry_unused[2 * ge]));
		am_add #(.W(48)) u_er_next (.a(er[ge]), .b(step_y[ge]), .ci(1'b0), .s(er_next[ge]),
			.co(step_carry_unused[2 * ge + 1]));
	end
	endgenerate

	/* Delta preparation wires for S_INIT */
	wire signed [47:0] init_dmax [0:2];
	wire signed [47:0] init_dmin [0:2];
	wire [5:0] init_carry_unused;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_init_delta
`ifdef SYNTH_KINTEX7
		(* keep = "true", dont_touch = "true" *) wire [2:0] sgn_dx_p, sgn_dx_m, sgn_dy_p, sgn_dy_m;
		genvar gsd;
		for (gsd = 0; gsd < 3; gsd = gsd + 1) begin : g_sd_buf
			LUT1 #(.INIT(2'h2)) u_sd_xp (.I0(a8[ge][47]), .O(sgn_dx_p[gsd]));
			LUT1 #(.INIT(2'h2)) u_sd_xm (.I0(a8[ge][47]), .O(sgn_dx_m[gsd]));
			LUT1 #(.INIT(2'h2)) u_sd_yp (.I0(b8[ge][47]), .O(sgn_dy_p[gsd]));
			LUT1 #(.INIT(2'h2)) u_sd_ym (.I0(b8[ge][47]), .O(sgn_dy_m[gsd]));
		end
		wire signed [47:0] dx_p = {sgn_dx_p[2] ? 16'd0 : step_x[ge][47:32], sgn_dx_p[1] ? 16'd0 : step_x[ge][31:16], sgn_dx_p[0] ? 16'd0 : step_x[ge][15:0]};
		wire signed [47:0] dx_m = {sgn_dx_m[2] ? step_x[ge][47:32] : 16'd0, sgn_dx_m[1] ? step_x[ge][31:16] : 16'd0, sgn_dx_m[0] ? step_x[ge][15:0] : 16'd0};
		wire signed [47:0] dy_p = {sgn_dy_p[2] ? 16'd0 : step_y[ge][47:32], sgn_dy_p[1] ? 16'd0 : step_y[ge][31:16], sgn_dy_p[0] ? 16'd0 : step_y[ge][15:0]};
		wire signed [47:0] dy_m = {sgn_dy_m[2] ? step_y[ge][47:32] : 16'd0, sgn_dy_m[1] ? step_y[ge][31:16] : 16'd0, sgn_dy_m[0] ? step_y[ge][15:0] : 16'd0};
`else
		wire signed [47:0] dx_p = a8[ge][47] ? 48'd0 : step_x[ge];
		wire signed [47:0] dx_m = a8[ge][47] ? step_x[ge] : 48'd0;
		wire signed [47:0] dy_p = b8[ge][47] ? 48'd0 : step_y[ge];
		wire signed [47:0] dy_m = b8[ge][47] ? step_y[ge] : 48'd0;
`endif

		am_add #(.W(48)) u_dmax (.a(dx_p), .b(dy_p), .ci(1'b0), .s(init_dmax[ge]),
			.co(init_carry_unused[2 * ge]));
		am_add #(.W(48)) u_dmin (.a(dx_m), .b(dy_m), .ci(1'b0), .s(init_dmin[ge]),
			.co(init_carry_unused[2 * ge + 1]));
	end
	endgenerate

	wire signed [47:0] init_ab8_comb [0:2];
	wire [2:0] init_ab8_carry_unused;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_init_ab8
		wire signed [47:0] ge_a = (ge == 0) ? e0_a8 : (ge == 1) ? e1_a8 : e2_a8;
		wire signed [47:0] ge_b = (ge == 0) ? e0_b8 : (ge == 1) ? e1_b8 : e2_b8;
		am_add #(.W(48)) u_ab8 (.a(ge_a), .b(ge_b), .ci(1'b0), .s(init_ab8_comb[ge]),
			.co(init_ab8_carry_unused[ge]));
	end
	endgenerate

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire [8:0] bx0_0_leaf;
	(* keep = "true", dont_touch = "true" *) wire [8:0] by0_0_leaf;
	genvar g_b0;
	generate
		for (g_b0 = 0; g_b0 < 9; g_b0 = g_b0 + 1) begin : g_b0_buf
			LUT1 #(.INIT(2'h2)) u_bx0_0 (.I0(bx0[0]), .O(bx0_0_leaf[g_b0]));
			LUT1 #(.INIT(2'h2)) u_by0_0 (.I0(by0[0]), .O(by0_0_leaf[g_b0]));
		end
	endgenerate
`endif

	wire signed [47:0] init_e_sub [0:2];
	wire signed [47:0] init_er [0:2];
	wire [2:0] init_er_carry_unused;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_init_er
`ifdef SYNTH_KINTEX7
		wire [47:0] init_e_sub_comb;
		genvar gsk;
		for (gsk = 0; gsk < 3; gsk = gsk + 1) begin : g_sub_sl
			wire bx0_s = bx0_0_leaf[ge * 3 + gsk];
			wire by0_s = by0_0_leaf[ge * 3 + gsk];
			assign init_e_sub_comb[gsk*16 +: 16] = (bx0_s && by0_s) ? ab8[ge][gsk*16 +: 16] :
			                                       bx0_s ? a8[ge][gsk*16 +: 16] :
			                                       by0_s ? b8[ge][gsk*16 +: 16] : 16'd0;
		end
		assign init_e_sub[ge] = init_e_sub_comb;
`else
		assign init_e_sub[ge] = (bx0[0] && by0[0]) ? ab8[ge] :
		                        bx0[0] ? a8[ge] :
		                        by0[0] ? b8[ge] : 48'd0;
`endif
		am_sub #(.W(48)) u_init_er (.a(er[ge]), .b(init_e_sub[ge]), .bi(1'b0), .d(init_er[ge]),
			.bo(init_er_carry_unused[ge]));
	end
	endgenerate

	integer k;
	assign tri_ready = (st == S_IDLE);
	assign busy = (st != S_IDLE);

`ifdef SYNTH_KINTEX7
	wire [8:0] we_walk_emax_leaf, we_walk_emin_leaf;
	wire [8:0] we_walk_er_nx_leaf, we_walk_ec_nx_leaf;
	wire [8:0] we_init_dmax_leaf, we_init_dmin_leaf;
	wire [8:0] we_init_er_leaf, we_init_ec_leaf;
	wire [8:0] we_idle_a_leaf, we_idle_b_leaf, we_idle_ab_leaf;
	wire [8:0] we_idle_er_leaf, we_idle_ec_leaf;
	wire [8:0] we_lm_leaf;
	wire [8:0] we_step_er_leaf, we_step_ec_leaf;
	wire [2:0] we_walk_mid, we_init_mid, we_idle_mid, we_step_mid;
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wwm0 (.I0(st == S_WALK), .O(we_walk_mid[0]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wwm1 (.I0(st == S_WALK), .O(we_walk_mid[1]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wwm2 (.I0(st == S_WALK), .O(we_walk_mid[2]));

	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wim0 (.I0(st == S_INIT), .O(we_init_mid[0]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wim1 (.I0(st == S_INIT), .O(we_init_mid[1]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wim2 (.I0(st == S_INIT), .O(we_init_mid[2]));

	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wid0 (.I0((st == S_IDLE) && tri_valid), .O(we_idle_mid[0]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wid1 (.I0((st == S_IDLE) && tri_valid), .O(we_idle_mid[1]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wid2 (.I0((st == S_IDLE) && tri_valid), .O(we_idle_mid[2]));

	wire step_advance = ((st == S_STEP) && r_tile_outside && !r_last_tile) ||
	                    ((st == S_WAIT) && tile_ready && !r_last_tile);
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wsm0 (.I0(step_advance), .O(we_step_mid[0]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wsm1 (.I0(step_advance), .O(we_step_mid[1]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wsm2 (.I0(step_advance), .O(we_step_mid[2]));

	(* dont_touch = "true" *) wire [8:0] r_row_end_b;
	genvar grre;
	generate
		for (grre = 0; grre < 9; grre = grre + 1) begin : g_rre
			LUT1 #(.INIT(2'h2)) u_rre (.I0(r_row_end), .O(r_row_end_b[grre]));
		end
	endgenerate

	genvar gck;
	generate
		for (gck = 0; gck < 9; gck = gck + 1) begin : g_coarse_we_leaf
			localparam integer EK = gck / 3;
			localparam integer SK = gck % 3;
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wwl_emx (.I0(we_walk_mid[EK]), .O(we_walk_emax_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wwl_emn (.I0(we_walk_mid[EK]), .O(we_walk_emin_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wwl_ern (.I0(we_walk_mid[EK]), .O(we_walk_er_nx_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wwl_ecn (.I0(we_walk_mid[EK]), .O(we_walk_ec_nx_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wil_dmx (.I0(we_init_mid[EK]), .O(we_init_dmax_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wil_dmn (.I0(we_init_mid[EK]), .O(we_init_dmin_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wil_er  (.I0(we_init_mid[EK]), .O(we_init_er_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wil_ec  (.I0(we_init_mid[EK]), .O(we_init_ec_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w_l_a   (.I0(we_idle_mid[EK]), .O(we_idle_a_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w_l_b   (.I0(we_idle_mid[EK]), .O(we_idle_b_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w_l_ab  (.I0(we_idle_mid[EK]), .O(we_idle_ab_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w_l_er  (.I0(we_idle_mid[EK]), .O(we_idle_er_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w_l_ec  (.I0(we_idle_mid[EK]), .O(we_idle_ec_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_w_lm    (.I0(we_idle_mid[EK] || we_init_mid[EK] || we_walk_mid[EK]), .O(we_lm_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wsler   (.I0(we_step_mid[EK]), .O(we_step_er_leaf[gck]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wslec   (.I0(we_step_mid[EK]), .O(we_step_ec_leaf[gck]));

			wire [15:0] in_a8_k = (EK == 0) ? e0_a8[SK*16 +: 16] : (EK == 1) ? e1_a8[SK*16 +: 16] : e2_a8[SK*16 +: 16];
			wire [15:0] in_b8_k = (EK == 0) ? e0_b8[SK*16 +: 16] : (EK == 1) ? e1_b8[SK*16 +: 16] : e2_b8[SK*16 +: 16];
			wire [15:0] in_er_k = (EK == 0) ? e0_er[SK*16 +: 16] : (EK == 1) ? e1_er[SK*16 +: 16] : e2_er[SK*16 +: 16];
			wire [15:0] in_lm_k = (EK == 0) ? lowm0[SK*16 +: 16] : (EK == 1) ? lowm1[SK*16 +: 16] : lowm2[SK*16 +: 16];

			always @(posedge clk) begin
				if (we_idle_a_leaf[gck])
					a8[EK][SK*16 +: 16]  <= in_a8_k;
				if (we_idle_b_leaf[gck])
					b8[EK][SK*16 +: 16]  <= in_b8_k;
				if (we_idle_ab_leaf[gck])
					ab8[EK][SK*16 +: 16] <= init_ab8_comb[EK][SK*16 +: 16];
			end

			always @(posedge clk) begin
				if (we_init_dmax_leaf[gck])
					d_max[EK][SK*16 +: 16] <= init_dmax[EK][SK*16 +: 16];
				if (we_init_dmin_leaf[gck])
					d_min[EK][SK*16 +: 16] <= init_dmin[EK][SK*16 +: 16];
			end

			always @(posedge clk) begin
				if (we_walk_emax_leaf[gck])
					r_emax[EK][SK*16 +: 16]    <= e_max[EK][SK*16 +: 16];
				if (we_walk_emin_leaf[gck])
					r_emin[EK][SK*16 +: 16]    <= e_min[EK][SK*16 +: 16];
				if (we_walk_ec_nx_leaf[gck])
					r_ec_next[EK][SK*16 +: 16] <= ec_next[EK][SK*16 +: 16];
				if (we_walk_er_nx_leaf[gck])
					r_er_next[EK][SK*16 +: 16] <= er_next[EK][SK*16 +: 16];
			end

			always @(posedge clk) begin
				if (we_lm_leaf[gck]) begin
					lm[EK][SK*16 +: 16] <= in_lm_k;
				end
			end

			always @(posedge clk) begin
				if (we_idle_er_leaf[gck]) begin
					er[EK][SK*16 +: 16] <= in_er_k;
				end else if (we_init_er_leaf[gck]) begin
					er[EK][SK*16 +: 16] <= init_er[EK][SK*16 +: 16];
				end else if (we_step_er_leaf[gck] && r_row_end_b[gck]) begin
					er[EK][SK*16 +: 16] <= r_er_next[EK][SK*16 +: 16];
				end
			end

			always @(posedge clk) begin
				if (we_idle_ec_leaf[gck]) begin
					ec[EK][SK*16 +: 16] <= in_er_k;
				end else if (we_init_ec_leaf[gck]) begin
					ec[EK][SK*16 +: 16] <= init_er[EK][SK*16 +: 16];
				end else if (we_step_ec_leaf[gck]) begin
					ec[EK][SK*16 +: 16] <= r_row_end_b[gck] ? r_er_next[EK][SK*16 +: 16] : r_ec_next[EK][SK*16 +: 16];
				end
			end
		end
	endgenerate
`endif

	always @(posedge clk) begin
		if (coarse_rst_sync) begin
			st <= S_IDLE;
			tile_valid <= 1'b0;
			tile_last <= 1'b0;
			tile_trivial <= 1'b0;
			r_row_end <= 1'b0;
			r_tile_outside <= 1'b0;
			r_is_trivial <= 1'b0;
			r_last_tile <= 1'b0;
		end else begin
			case (st)
			S_IDLE: begin
				tile_valid <= 1'b0;
				tile_last <= 1'b0;
				if (tri_valid) begin
					bx0 <= bbox_min_x;
					by0 <= bbox_min_y;
					bx1 <= bbox_max_x;
					by1 <= bbox_max_y;
					/* Align tile origin to bounding box origin */
					tile_x <= {bbox_min_x[15:1], 1'b0};
					tile_y <= {bbox_min_y[15:1], 1'b0};
`ifndef SYNTH_KINTEX7
					a8[0] <= e0_a8; b8[0] <= e0_b8; er[0] <= e0_er; ec[0] <= e0_er;
					a8[1] <= e1_a8; b8[1] <= e1_b8; er[1] <= e1_er; ec[1] <= e1_er;
					a8[2] <= e2_a8; b8[2] <= e2_b8; er[2] <= e2_er; ec[2] <= e2_er;
					ab8[0] <= init_ab8_comb[0];
					ab8[1] <= init_ab8_comb[1];
					ab8[2] <= init_ab8_comb[2];
					lm[0] <= lowm0;
					lm[1] <= lowm1;
					lm[2] <= lowm2;
`endif
					if (bbox_max_x > bbox_min_x && bbox_max_y > bbox_min_y)
						st <= S_INIT;
					else
						st <= S_IDLE;
				end
			end

			S_INIT: begin
`ifndef SYNTH_KINTEX7
				for (k = 0; k < 3; k = k + 1) begin
					d_max[k] <= init_dmax[k];
					d_min[k] <= init_dmin[k];
					er[k] <= init_er[k];
					ec[k] <= init_er[k];
				end
				lm[0] <= lowm0;
				lm[1] <= lowm1;
				lm[2] <= lowm2;
`endif
				st <= S_WALK;
			end

			S_WALK: begin
`ifndef SYNTH_KINTEX7
				for (k = 0; k < 3; k = k + 1) begin
					r_emax[k]    <= e_max[k];
					r_emin[k]    <= e_min[k];
					r_ec_next[k] <= ec_next[k];
					r_er_next[k] <= er_next[k];
					lm[k]        <= (k == 0) ? lowm0 : (k == 1) ? lowm1 : lowm2;
				end
`endif
				r_tx_next <= tx_next;
				r_ty_next <= ty_next;
				st <= S_EVAL;
			end

			S_EVAL: begin
				r_tile_outside <= tile_outside;
				r_is_trivial <= is_trivial;
				r_last_tile <= last_tile;
				r_row_end <= row_end;
				st <= S_STEP;
			end

			S_STEP: begin
				if (r_tile_outside) begin
					if (r_last_tile) begin
						st <= S_IDLE;
					end else begin
						if (r_row_end) begin
							tile_x <= {bx0[15:1], 1'b0};
							tile_y <= r_ty_next;
`ifndef SYNTH_KINTEX7
							for (k = 0; k < 3; k = k + 1) begin
								er[k] <= r_er_next[k];
								ec[k] <= r_er_next[k];
							end
`endif
						end else begin
							tile_x <= r_tx_next;
`ifndef SYNTH_KINTEX7
							for (k = 0; k < 3; k = k + 1)
								ec[k] <= r_ec_next[k];
`endif
						end
						st <= S_WALK;
					end
				end else begin
					tile_valid <= 1'b1;
					tile_trivial <= r_is_trivial;
					tile_last <= r_last_tile;
					st <= S_WAIT;
				end
			end

			S_WAIT: begin
				if (tile_ready) begin
					tile_valid <= 1'b0;
					if (r_last_tile) begin
						tile_last <= 1'b0;
						st <= S_IDLE;
					end else begin
						if (r_row_end) begin
							tile_x <= {bx0[15:1], 1'b0};
							tile_y <= r_ty_next;
`ifndef SYNTH_KINTEX7
							for (k = 0; k < 3; k = k + 1) begin
								er[k] <= r_er_next[k];
								ec[k] <= r_er_next[k];
							end
`endif
						end else begin
							tile_x <= r_tx_next;
`ifndef SYNTH_KINTEX7
							for (k = 0; k < 3; k = k + 1)
								ec[k] <= r_ec_next[k];
`endif
						end
						st <= S_WALK;
					end
				end
			end
			default: st <= S_IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, eval_carry_unused, coord_carry_unused,
		step_carry_unused, init_carry_unused, init_ab8_carry_unused, init_er_carry_unused};
endmodule

`default_nettype wire
