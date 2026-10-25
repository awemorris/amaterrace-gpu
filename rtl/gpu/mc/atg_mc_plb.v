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
	output reg w_inv
);
	reg [PLB-1:0] pl_v;
	reg [PLB*TAGW-1:0] pl_tag;
	reg [LINE_BYTES*8-1:0] pl_data [0:PLB-1];
	reg [PLB_W-1:0] pl_rr;
	reg [PLB_W-1:0] idx;
	reg [PLB-1:0] pl_inv;
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

	/* Whether the line of tag t overlaps [inv_g, inv_g + inv_n). */
	function overlap;
		input [TAGW-1:0] t;
		reg [33:0] gs, ge, is, ie;
		begin
			gs = {{(34-GW){1'b0}}, g0} + {{(34-GW){1'b0}}, t, {LINE_SHIFT{1'b0}}};
			ge = gs + {{(33-LINE_SHIFT){1'b0}}, 1'b1, {LINE_SHIFT{1'b0}}};
			is = {{(34-GW){1'b0}}, inv_g};
			ie = is + {2'b00, inv_n};
			overlap = inv_n == 32'd0 || gs < ie && is < ge;
		end
	endfunction

	always @(*) begin
		for (k = 0; k < PLB; k = k + 1)
`ifdef MUT_PROT_STALE
			pl_inv[k] = 1'b0;
`else
			pl_inv[k] = inv_valid && overlap(pl_tag[k*TAGW +: TAGW]);
`endif
		w_inv = inv_valid && overlap(w_tag);
	end

	always @(posedge clk) begin
		if (!rst_n || flush || !en) begin
			pl_v <= {PLB{1'b0}};
			pl_rr <= {PLB_W{1'b0}};
		end else begin
			pl_v <= pl_v & ~pl_inv;
			if (fill) begin
				pl_v <= (pl_v & ~pl_inv) | {{(PLB-1){1'b0}}, 1'b1} << pl_rr;
				pl_rr <= pl_rr + 1'b1;
			end
		end
	end

	always @(posedge clk) begin
		if (fill) begin
			pl_tag[pl_rr*TAGW +: TAGW] <= fill_tag;
			pl_data[pl_rr] <= fill_data;
		end
	end
endmodule

`default_nettype wire
