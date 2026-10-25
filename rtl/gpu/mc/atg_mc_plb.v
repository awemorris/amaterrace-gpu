/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_plb: the protection lookaside buffer of session protection
 * (spec/gpu/mc/atg_mc_plb.md): PLB lines of the protection table, fully
 * associative, filled round-robin.  A line holds LINE_BYTES table bytes,
 * one per granule: the line of tag t covers the granules
 * [g0 + t * LINE_BYTES, + LINE_BYTES).
 *
 * Lookup (combinational): the line of `tag`, if one is valid (hit, data).
 * Fill: fill for one cycle writes fill_tag and fill_data into the next
 * line.  Invalidation: inv_valid for one cycle drops the lines that
 * overlap the granules [inv_g, inv_g + inv_n) (inv_n = 0: all); w_inv
 * says whether that range overlaps the line of w_tag (the walk's).  A fill
 * and an invalidation in the same cycle: the fill is kept (the caller does
 * not fill a line the invalidation overlaps).  rst_n, flush and !en drop
 * every line.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_plb #(
	parameter PLB = 4,
	parameter PLB_W = 2,	/* clog2(PLB) */
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter GW = 20,	/* granule number bits */
	parameter TAGW = 15	/* GW - LINE_SHIFT */
) (
	input wire clk,
	input wire rst_n,
	input wire flush,
	input wire en,

	input wire [GW-1:0] g0,
	input wire [TAGW-1:0] tag,
	output reg hit,
	output wire [LINE_BYTES*8-1:0] data,

	input wire fill,
	input wire [TAGW-1:0] fill_tag,
	input wire [LINE_BYTES*8-1:0] fill_data,

	input wire inv_valid,
	input wire [GW-1:0] inv_g,
	input wire [31:0] inv_n,
	input wire [TAGW-1:0] w_tag,
	output wire w_inv
);
	reg [PLB-1:0] pl_v;
	reg [PLB*TAGW-1:0] pl_tag;
	reg [LINE_BYTES*8-1:0] pl_data [0:PLB-1];
	reg [PLB_W-1:0] pl_rr;
	reg [PLB_W-1:0] idx;
	wire [PLB-1:0] pl_inv;
	integer k;

	always @(*) begin
		hit = 1'b0;
		idx = {PLB_W{1'b0}};
		for (k = 0; k < PLB; k = k + 1)
			if (pl_v[k] && pl_tag[k*TAGW +: TAGW] == tag) begin
				hit = 1'b1;
				idx = k[PLB_W-1:0];
			end
	end

	assign data = pl_data[idx];

	/*
	 * Whether the line of a tag t (the PLB's lines and w_tag) overlaps
	 * [inv_g, inv_g + inv_n): its granules [gs, gs + LINE_BYTES), gs = g0 +
	 * t * LINE_BYTES, against [is, ie), in 34 bits (no wrap).  gs < ie and
	 * is < gs + LINE_BYTES, the latter as is < LINE_BYTES or is -
	 * LINE_BYTES < gs, so that each line needs one adder (gs) and the range
	 * one adder (ie) and one subtractor (is - LINE_BYTES).
	 */
	localparam [33:0] LINE_G = 34'd1 << LINE_SHIFT;
	wire [33:0] is = {{(34-GW){1'b0}}, inv_g};
	wire [33:0] ie, is_l;
	wire ie_co, is_l_bo;

	am_add #(.W(34)) ie_add (.a(is), .b({2'b00, inv_n}), .ci(1'b0), .s(ie), .co(ie_co));
	am_sub #(.W(34)) is_l_sub (.a(is), .b(LINE_G), .bi(1'b0), .d(is_l), .bo(is_l_bo));

	wire is_small = is < LINE_G;
	wire [PLB:0] ov;
	wire [PLB:0] gs_co;
	wire [(PLB+1)*TAGW-1:0] ov_tag = {w_tag, pl_tag};

	genvar gk;
	generate
		for (gk = 0; gk <= PLB; gk = gk + 1) begin : ovl
			wire [33:0] gs;

			am_add #(.W(34)) gs_add (
				.a({{(34-GW){1'b0}}, g0}),
				.b({{(34-GW){1'b0}}, ov_tag[gk*TAGW +: TAGW], {LINE_SHIFT{1'b0}}}),
				.ci(1'b0), .s(gs), .co(gs_co[gk])
			);
			assign ov[gk] = inv_n == 32'd0 || gs < ie && (is_small || is_l < gs);
		end
	endgenerate

`ifdef MUT_PROT_STALE
	assign pl_inv = {PLB{1'b0}};
`else
	assign pl_inv = {PLB{inv_valid}} & ov[PLB-1:0];
`endif
	assign w_inv = inv_valid && ov[PLB];

	/* The next line to fill, round-robin, and its one-hot. */
	wire [PLB_W-1:0] rr_next;
	wire rr_co;
	reg [PLB-1:0] rr_hot;

	am_add #(.W(PLB_W)) rr_add (.a(pl_rr), .b({PLB_W{1'b0}}), .ci(1'b1), .s(rr_next), .co(rr_co));

	always @(*)
		for (k = 0; k < PLB; k = k + 1)
			rr_hot[k] = {{(32 - PLB_W){1'b0}}, pl_rr} == k;

	always @(posedge clk) begin
		if (!rst_n || flush || !en) begin
			pl_v <= {PLB{1'b0}};
			pl_rr <= {PLB_W{1'b0}};
		end else begin
			pl_v <= pl_v & ~pl_inv;
			if (fill) begin
				pl_v <= (pl_v & ~pl_inv) | rr_hot;
				pl_rr <= rr_next;
			end
		end
	end

	always @(posedge clk) begin
		for (k = 0; k < PLB; k = k + 1)
			if (fill && rr_hot[k])
				pl_tag[k*TAGW +: TAGW] <= fill_tag;
		if (fill)
			pl_data[pl_rr] <= fill_data;
	end

	wire unused_ok = &{1'b0, ie_co, is_l_bo, gs_co, rr_co};
endmodule

`default_nettype wire
