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
	input wire [LINE_SHIFT-1:0] byte_idx,
	output wire hit,
	output wire [LINE_BYTES*8-1:0] data,
	output wire [7:0] byte_data,

	input wire fill,
	input wire [TAGW-1:0] fill_tag,
	input wire [LINE_BYTES*8-1:0] fill_data,

	input wire inv_valid,
	input wire [GW-1:0] inv_g,
	input wire [31:0] inv_n,
	input wire [TAGW-1:0] w_tag,
	output wire w_inv
);
	localparam LB = LINE_BYTES * 8;

	reg [PLB-1:0] pl_v;
	reg [PLB*TAGW-1:0] pl_tag;
	reg [PLB*LB-1:0] pl_data;
	reg [PLB_W-1:0] pl_rr;
	wire [PLB-1:0] pl_inv;
	integer k;

	/* Parallel tag match across PLB ways, then mux way line before byte select. */
	wire [PLB-1:0] pl_match;
	wire [PLB*LB-1:0] pl_masked;
	genvar gm;
	generate
		for (gm = 0; gm < PLB; gm = gm + 1) begin : g_match
			assign pl_match[gm] = pl_v[gm] && (pl_tag[gm*TAGW +: TAGW] == tag);
			assign pl_masked[gm*LB +: LB] = {LB{pl_match[gm]}} & pl_data[gm*LB +: LB];
		end
	endgenerate

	assign hit = |pl_match;

	generate
		if (PLB == 4) begin : g_mux4
			assign data = (pl_masked[0*LB +: LB] | pl_masked[1*LB +: LB]) |
				      (pl_masked[2*LB +: LB] | pl_masked[3*LB +: LB]);
		end else if (PLB == 8) begin : g_mux8
			wire [LB-1:0] s0 = pl_masked[0*LB +: LB] | pl_masked[1*LB +: LB];
			wire [LB-1:0] s1 = pl_masked[2*LB +: LB] | pl_masked[3*LB +: LB];
			wire [LB-1:0] s2 = pl_masked[4*LB +: LB] | pl_masked[5*LB +: LB];
			wire [LB-1:0] s3 = pl_masked[6*LB +: LB] | pl_masked[7*LB +: LB];
			assign data = (s0 | s1) | (s2 | s3);
		end else if (PLB == 16) begin : g_mux16
			wire [LB-1:0] s0 = (pl_masked[0*LB +: LB] | pl_masked[1*LB +: LB]) |
					   (pl_masked[2*LB +: LB] | pl_masked[3*LB +: LB]);
			wire [LB-1:0] s1 = (pl_masked[4*LB +: LB] | pl_masked[5*LB +: LB]) |
					   (pl_masked[6*LB +: LB] | pl_masked[7*LB +: LB]);
			wire [LB-1:0] s2 = (pl_masked[8*LB +: LB] | pl_masked[9*LB +: LB]) |
					   (pl_masked[10*LB +: LB] | pl_masked[11*LB +: LB]);
			wire [LB-1:0] s3 = (pl_masked[12*LB +: LB] | pl_masked[13*LB +: LB]) |
					   (pl_masked[14*LB +: LB] | pl_masked[15*LB +: LB]);
			assign data = (s0 | s1) | (s2 | s3);
		end else begin : g_mux_gen
			reg [LB-1:0] mux_or;
			integer km;
			always @(*) begin
				mux_or = {LB{1'b0}};
				for (km = 0; km < PLB; km = km + 1)
					mux_or = mux_or | pl_masked[km*LB +: LB];
			end
			assign data = mux_or;
		end
	endgenerate

	assign byte_data = data[{byte_idx, 3'b000} +: 8];

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

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			pl_v <= {PLB{1'b0}};
			pl_rr <= {PLB_W{1'b0}};
		end else if (flush || !en) begin
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
			if (fill && rr_hot[k]) begin
				pl_tag[k*TAGW +: TAGW] <= fill_tag;
				pl_data[k*LB +: LB] <= fill_data;
			end
	end

	wire unused_ok = &{1'b0, ie_co, is_l_bo, gs_co, rr_co};
endmodule

`default_nettype wire
