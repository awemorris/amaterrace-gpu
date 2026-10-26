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
	localparam [1:0] S_IDLE = 2'd0, S_INIT = 2'd1, S_WALK = 2'd2;
	reg [1:0] st;

	reg [15:0] bx0, by0, bx1, by1;
	reg signed [47:0] a8 [0:2];
	reg signed [47:0] b8 [0:2];
	reg signed [47:0] er [0:2];
	reg signed [47:0] ec [0:2];
	reg [47:0] lm [0:2];

	assign tile_e0 = ec[0];
	assign tile_e1 = ec[1];
	assign tile_e2 = ec[2];

	/* Conservative corner delta offsets: max and min deltas per edge */
	reg signed [47:0] d_max [0:2];
	reg signed [47:0] d_min [0:2];

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
	wire edge0_outside = e_max[0][47] && ((e_max[0] | lm[0]) != {48{1'b1}});
	wire edge1_outside = e_max[1][47] && ((e_max[1] | lm[1]) != {48{1'b1}});
	wire edge2_outside = e_max[2][47] && ((e_max[2] | lm[2]) != {48{1'b1}});
	wire tile_outside = edge0_outside || edge1_outside || edge2_outside;

	/* All edges where E_min > lowm means all sample points in tile are unconditionally inside */
	wire signed [47:0] slm0 = lm[0];
	wire signed [47:0] slm1 = lm[1];
	wire signed [47:0] slm2 = lm[2];
	wire edge0_inside = !e_min[0][47] && (e_min[0] > slm0);
	wire edge1_inside = !e_min[1][47] && (e_min[1] > slm1);
	wire edge2_inside = !e_min[2][47] && (e_min[2] > slm2);
	wire all_inside = edge0_inside && edge1_inside && edge2_inside;

	/* Stepping arithmetic for coordinates */
	wire [15:0] tx_next;
	wire [15:0] ty_next;
	wire [1:0] coord_carry_unused;
	am_add #(.W(16)) u_tx_next (.a(tile_x), .b(16'd8), .ci(1'b0), .s(tx_next), .co(coord_carry_unused[0]));
	am_add #(.W(16)) u_ty_next (.a(tile_y), .b(16'd8), .ci(1'b0), .s(ty_next), .co(coord_carry_unused[1]));

	wire row_end = tx_next >= bx1;
	wire last_tile = row_end && (ty_next >= by1);

	/* Check if tile is fully within bounding box (no scissor/bbox clipping of corners) */
	wire tile_in_bbox = (tile_x >= bx0) && (tx_next <= bx1) &&
	                    (tile_y >= by0) && (ty_next <= by1);
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
		wire signed [47:0] dx_p = a8[ge][47] ? 48'd0 : step_x[ge];
		wire signed [47:0] dx_m = a8[ge][47] ? step_x[ge] : 48'd0;
		wire signed [47:0] dy_p = b8[ge][47] ? 48'd0 : step_y[ge];
		wire signed [47:0] dy_m = b8[ge][47] ? step_y[ge] : 48'd0;

		am_add #(.W(48)) u_dmax (.a(dx_p), .b(dy_p), .ci(1'b0), .s(init_dmax[ge]),
			.co(init_carry_unused[2 * ge]));
		am_add #(.W(48)) u_dmin (.a(dx_m), .b(dy_m), .ci(1'b0), .s(init_dmin[ge]),
			.co(init_carry_unused[2 * ge + 1]));
	end
	endgenerate

	integer k;
	assign tri_ready = (st == S_IDLE);
	assign busy = (st != S_IDLE);

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= S_IDLE;
			tile_valid <= 1'b0;
			tile_last <= 1'b0;
			tile_trivial <= 1'b0;
			tile_x <= 16'd0;
			tile_y <= 16'd0;
			bx0 <= 16'd0;
			by0 <= 16'd0;
			bx1 <= 16'd0;
			by1 <= 16'd0;
			for (k = 0; k < 3; k = k + 1) begin
				a8[k] <= 48'd0;
				b8[k] <= 48'd0;
				er[k] <= 48'd0;
				ec[k] <= 48'd0;
				d_max[k] <= 48'd0;
				d_min[k] <= 48'd0;
				lm[k] <= 48'd0;
			end
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
					a8[0] <= e0_a8; b8[0] <= e0_b8; er[0] <= e0_er; ec[0] <= e0_er;
					a8[1] <= e1_a8; b8[1] <= e1_b8; er[1] <= e1_er; ec[1] <= e1_er;
					a8[2] <= e2_a8; b8[2] <= e2_b8; er[2] <= e2_er; ec[2] <= e2_er;
					lm[0] <= lowm0;
					lm[1] <= lowm1;
					lm[2] <= lowm2;
					if (bbox_max_x > bbox_min_x && bbox_max_y > bbox_min_y)
						st <= S_INIT;
					else
						st <= S_IDLE;
				end
			end

			S_INIT: begin
				for (k = 0; k < 3; k = k + 1) begin
					d_max[k] <= init_dmax[k];
					d_min[k] <= init_dmin[k];
				end
				lm[0] <= lowm0;
				lm[1] <= lowm1;
				lm[2] <= lowm2;
				st <= S_WALK;
			end

			S_WALK: begin
				if (tile_valid) begin
					/* Waiting for fine rasterizer to accept tile */
					if (tile_ready) begin
						tile_valid <= 1'b0;
						if (tile_last) begin
							tile_last <= 1'b0;
							st <= S_IDLE;
						end else begin
							/* Advance to next tile */
							if (row_end) begin
								tile_x <= {bx0[15:1], 1'b0};
								tile_y <= ty_next;
								for (k = 0; k < 3; k = k + 1) begin
									er[k] <= er_next[k];
									ec[k] <= er_next[k];
								end
							end else begin
								tile_x <= tx_next;
								for (k = 0; k < 3; k = k + 1)
									ec[k] <= ec_next[k];
							end
						end
					end
				end else begin
					/* Evaluating current tile */
					if (tile_outside) begin
						/* 1-cycle skip of empty tile! */
						if (last_tile) begin
							st <= S_IDLE;
						end else if (row_end) begin
							tile_x <= {bx0[15:1], 1'b0};
							tile_y <= ty_next;
							for (k = 0; k < 3; k = k + 1) begin
								er[k] <= er_next[k];
								ec[k] <= er_next[k];
							end
						end else begin
							tile_x <= tx_next;
							for (k = 0; k < 3; k = k + 1)
								ec[k] <= ec_next[k];
						end
					end else begin
						/* Active tile: present to Fine Rasterizer */
						tile_valid <= 1'b1;
						tile_trivial <= is_trivial;
						tile_last <= last_tile;
					end
				end
			end
			default: st <= S_IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, eval_carry_unused, coord_carry_unused,
		step_carry_unused, init_carry_unused};
endmodule

`default_nettype wire
