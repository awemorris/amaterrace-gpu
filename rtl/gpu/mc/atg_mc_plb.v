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

	/* Parallel tag match + OR reduction across PLB ways; single byte extraction cuts byte_idx FO. */
	wire [PLB-1:0] pl_match;
	wire [PLB*LB-1:0] pl_masked;
	genvar gm;
	generate
		for (gm = 0; gm < PLB; gm = gm + 1) begin : g_match
			wire [LB-1:0] pl_line_w = pl_data[gm*LB +: LB];
			assign pl_match[gm] = pl_v[gm] && (pl_tag[gm*TAGW +: TAGW] == tag);
			assign pl_masked[gm*LB +: LB] = {LB{pl_match[gm]}} & pl_line_w;
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
	 * t * LINE_BYTES, against [is, ie), in GW+1 bits (overflow >= 2^(GW+1) handled).
	 */
	localparam integer TAG_LO_W = TAGW / 2;
	localparam integer TAG_HI_W = TAGW - TAG_LO_W;
	localparam integer IE_M_W = TAG_LO_W;
	localparam integer IE_H_W = (GW + 1) - LINE_SHIFT - IE_M_W;

	wire is_small = inv_g[GW-1:LINE_SHIFT] == {TAGW{1'b0}};
	wire inv_n_zero = inv_n == 32'd0;

	/* Fast carry-select ie[GW:0] = inv_g[GW-1:0] + inv_n[31:0] */
	wire [LINE_SHIFT-1:0] ie_lo;
	wire ie_c0;
	am_add #(.W(LINE_SHIFT)) u_ie0 (
		.a(inv_g[LINE_SHIFT-1:0]), .b(inv_n[LINE_SHIFT-1:0]), .ci(1'b0),
		.s(ie_lo), .co(ie_c0)
	);
	wire [IE_M_W-1:0] ie_m0, ie_m1;
	wire ie_mc0, ie_mc1;
	am_add #(.W(IE_M_W)) u_iem0 (
		.a(inv_g[LINE_SHIFT +: IE_M_W]), .b(inv_n[LINE_SHIFT +: IE_M_W]), .ci(1'b0),
		.s(ie_m0), .co(ie_mc0)
	);
	am_add #(.W(IE_M_W)) u_iem1 (
		.a(inv_g[LINE_SHIFT +: IE_M_W]), .b(inv_n[LINE_SHIFT +: IE_M_W]), .ci(1'b1),
		.s(ie_m1), .co(ie_mc1)
	);
	wire [IE_M_W-1:0] ie_mid = ie_c0 ? ie_m1 : ie_m0;
	wire ie_cmid = ie_c0 ? ie_mc1 : ie_mc0;

	wire [IE_H_W-1:0] ie_h0, ie_h1;
	wire ie_hc0, ie_hc1;
	am_add #(.W(IE_H_W)) u_ieh0 (
		.a({1'b0, inv_g[GW-1:LINE_SHIFT+IE_M_W]}),
		.b(inv_n[LINE_SHIFT+IE_M_W +: IE_H_W]),
		.ci(1'b0), .s(ie_h0), .co(ie_hc0)
	);
	am_add #(.W(IE_H_W)) u_ieh1 (
		.a({1'b0, inv_g[GW-1:LINE_SHIFT+IE_M_W]}),
		.b(inv_n[LINE_SHIFT+IE_M_W +: IE_H_W]),
		.ci(1'b1), .s(ie_h1), .co(ie_hc1)
	);
	wire [IE_H_W-1:0] ie_hi = ie_cmid ? ie_h1 : ie_h0;
	wire ie_ov = (|inv_n[31:GW+1]) || (ie_cmid ? ie_hc1 : ie_hc0);
	wire [GW:0] ie_21 = {ie_hi, ie_mid, ie_lo};

	/* is_l = inv_g - (1 << LINE_SHIFT): low LINE_SHIFT bits unchanged; subtract 1 from upper TAGW bits. */
	wire [TAG_LO_W-1:0] isl_lo;
	wire isl_bo0;
	am_sub #(.W(TAG_LO_W)) u_isll (
		.a(inv_g[LINE_SHIFT +: TAG_LO_W]), .b({TAG_LO_W{1'b0}}), .bi(1'b1),
		.d(isl_lo), .bo(isl_bo0)
	);
	wire [TAG_HI_W-1:0] isl_h0 = inv_g[GW-1:LINE_SHIFT+TAG_LO_W];
	wire [TAG_HI_W-1:0] isl_h1;
	wire isl_bo1_unused;
	am_sub #(.W(TAG_HI_W)) u_islh (
		.a(isl_h0), .b({TAG_HI_W{1'b0}}), .bi(1'b1),
		.d(isl_h1), .bo(isl_bo1_unused)
	);
	wire [GW-1:0] is_l_20 = {isl_bo0 ? isl_h1 : isl_h0, isl_lo, inv_g[LINE_SHIFT-1:0]};

	wire [PLB:0] ov;
	wire [(PLB+1)*TAGW-1:0] ov_tag = {w_tag, pl_tag};

	localparam integer C0_W = 5;
	localparam integer C1_W = 5;
	localparam integer C2_W = 5;
	localparam integer C3_W = (GW + 1) - C0_W - C1_W - C2_W;

	genvar gk;
	generate
		for (gk = 0; gk <= PLB; gk = gk + 1) begin : ovl
			wire [TAGW-1:0] t_w = ov_tag[gk*TAGW +: TAGW];
			wire [TAG_LO_W-1:0] gs_m;
			wire gs_mc;
			am_add #(.W(TAG_LO_W)) u_gsm (
				.a(g0[LINE_SHIFT +: TAG_LO_W]), .b(t_w[TAG_LO_W-1:0]), .ci(1'b0),
				.s(gs_m), .co(gs_mc)
			);
			wire [TAG_HI_W:0] gs_h0, gs_h1;
			wire [1:0] gs_hc_unused;
			am_add #(.W(TAG_HI_W + 1)) u_gsh0 (
				.a({1'b0, g0[GW-1:LINE_SHIFT+TAG_LO_W]}), .b({1'b0, t_w[TAGW-1:TAG_LO_W]}), .ci(1'b0),
				.s(gs_h0), .co(gs_hc_unused[0])
			);
			am_add #(.W(TAG_HI_W + 1)) u_gsh1 (
				.a({1'b0, g0[GW-1:LINE_SHIFT+TAG_LO_W]}), .b({1'b0, t_w[TAGW-1:TAG_LO_W]}), .ci(1'b1),
				.s(gs_h1), .co(gs_hc_unused[1])
			);
			wire [GW:0] gs_21 = {gs_mc ? gs_h1 : gs_h0, gs_m, g0[LINE_SHIFT-1:0]};

			/* Fast chunked unsigned compare: gs_21 < ie_21 */
			wire lt_gi_0 = gs_21[0 +: C0_W] < ie_21[0 +: C0_W];
			wire eq_gi_1 = gs_21[C0_W +: C1_W] == ie_21[C0_W +: C1_W];
			wire lt_gi_1 = gs_21[C0_W +: C1_W] < ie_21[C0_W +: C1_W];
			wire eq_gi_2 = gs_21[C0_W+C1_W +: C2_W] == ie_21[C0_W+C1_W +: C2_W];
			wire lt_gi_2 = gs_21[C0_W+C1_W +: C2_W] < ie_21[C0_W+C1_W +: C2_W];
			wire eq_gi_3 = gs_21[GW:C0_W+C1_W+C2_W] == ie_21[GW:C0_W+C1_W+C2_W];
			wire lt_gi_3 = gs_21[GW:C0_W+C1_W+C2_W] < ie_21[GW:C0_W+C1_W+C2_W];
			wire lt_gi_lo = lt_gi_1 || (eq_gi_1 && lt_gi_0);
			wire gs_lt_ie = ie_ov || lt_gi_3 || (eq_gi_3 && (lt_gi_2 || (eq_gi_2 && lt_gi_lo)));

			/* Fast chunked unsigned compare: is_l_20 < gs_21 */
			wire lt_ig_0 = is_l_20[0 +: C0_W] < gs_21[0 +: C0_W];
			wire eq_ig_1 = is_l_20[C0_W +: C1_W] == gs_21[C0_W +: C1_W];
			wire lt_ig_1 = is_l_20[C0_W +: C1_W] < gs_21[C0_W +: C1_W];
			wire eq_ig_2 = is_l_20[C0_W+C1_W +: C2_W] == gs_21[C0_W+C1_W +: C2_W];
			wire lt_ig_2 = is_l_20[C0_W+C1_W +: C2_W] < gs_21[C0_W+C1_W +: C2_W];
			wire eq_ig_3 = is_l_20[GW-1:C0_W+C1_W+C2_W] == gs_21[GW-1:C0_W+C1_W+C2_W];
			wire lt_ig_3 = is_l_20[GW-1:C0_W+C1_W+C2_W] < gs_21[GW-1:C0_W+C1_W+C2_W];
			wire lt_ig_lo = lt_ig_1 || (eq_ig_1 && lt_ig_0);
			wire isl_lt_gs = gs_21[GW] || lt_ig_3 || (eq_ig_3 && (lt_ig_2 || (eq_ig_2 && lt_ig_lo)));

			assign ov[gk] = inv_n_zero || (gs_lt_ie && (is_small || isl_lt_gs));
			wire unused_ovl = &{1'b0, gs_hc_unused};
		end
	endgenerate

`ifdef MUT_PROT_STALE
	assign pl_inv = {PLB{1'b0}};
`else
	assign pl_inv = {PLB{inv_valid}} & ov[PLB-1:0];
`endif
	assign w_inv = inv_valid && ov[PLB];

	/* The next line to fill, round-robin, with replicated one-hot FFs to keep FO <= 256. */
	wire [PLB_W-1:0] rr_next;
	wire rr_co;
	reg [PLB-1:0] rr_hot;
	(* keep = "true" *) reg [PLB-1:0] rr_hot_lo;
	(* keep = "true" *) reg [PLB-1:0] rr_hot_hi;

	am_add #(.W(PLB_W)) rr_add (.a(pl_rr), .b({PLB_W{1'b0}}), .ci(1'b1), .s(rr_next), .co(rr_co));

	always @(*)
		for (k = 0; k < PLB; k = k + 1)
			rr_hot[k] = {{(32 - PLB_W){1'b0}}, pl_rr} == k;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			pl_v <= {PLB{1'b0}};
			pl_rr <= {PLB_W{1'b0}};
			rr_hot_lo <= {{(PLB-1){1'b0}}, 1'b1};
			rr_hot_hi <= {{(PLB-1){1'b0}}, 1'b1};
		end else if (flush || !en) begin
			pl_v <= {PLB{1'b0}};
			pl_rr <= {PLB_W{1'b0}};
			rr_hot_lo <= {{(PLB-1){1'b0}}, 1'b1};
			rr_hot_hi <= {{(PLB-1){1'b0}}, 1'b1};
		end else begin
			pl_v <= pl_v & ~pl_inv;
			if (fill) begin
				pl_v <= (pl_v & ~pl_inv) | rr_hot;
				pl_rr <= rr_next;
				rr_hot_lo <= {rr_hot_lo[PLB-2:0], rr_hot_lo[PLB-1]};
				rr_hot_hi <= {rr_hot_hi[PLB-2:0], rr_hot_hi[PLB-1]};
			end
		end
	end

	localparam integer HALF_LB = LB / 2;
	always @(posedge clk) begin
		for (k = 0; k < PLB; k = k + 1) begin
			if (fill && rr_hot_lo[k]) begin
				pl_tag[k*TAGW +: TAGW] <= fill_tag;
				pl_data[k*LB +: HALF_LB] <= fill_data[HALF_LB-1:0];
			end
			if (fill && rr_hot_hi[k]) begin
				pl_data[k*LB + HALF_LB +: LB - HALF_LB] <= fill_data[LB-1:HALF_LB];
			end
		end
	end

	wire unused_ok = &{1'b0, isl_bo1_unused, rr_co,
		ie_c0, ie_mc0, ie_mc1, ie_hc0, ie_hc1};
endmodule

`default_nettype wire
