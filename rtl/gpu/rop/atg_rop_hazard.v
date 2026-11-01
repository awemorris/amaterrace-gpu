/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_hazard: Pixel Lock CAM and RAW Hazard Tracker for ROP pipeline.
 *
 * Tracks in-flight quad coordinates {RT[2:0], Y[15:1], X[15:1]} across the
 * ROP pipeline (Phase 003: MRT 8 attachments).
 * High-frequency 5nm ASIC implementation:
 * - Pure-LUT equality slices (0 CARRY4s, 3 LUT6 levels to o_grp_hit, 4 LUT6 levels to alloc_ready/valid).
 * - 2-level priority tree for empty slot selection (<= 3 LUT6 levels).
 * - Buffered write-enable trees to keep all net fanouts <= 16.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_rop_hazard #(
	parameter NUM_ENTRIES = 16,
	parameter TAG_W = 33	/* {RT[2:0], Y[15:1], X[15:1]} */
) (
	input wire clk,
	input wire rst_n,

	/* Allocation interface (pipeline issue stage) */
	input wire alloc_valid,
	output wire alloc_ready,	/* not full and no RAW hazard */
	input wire [TAG_W-1:0] alloc_tag,
	output reg [3:0] alloc_id,	/* allocated entry ID */
	output wire [2:0] o_grp_hit,	/* Level-3 group hit / full flags */

	/* Release interface (pipeline commit stage) */
	input wire release_valid,
	input wire [3:0] release_id
);
	(* keep = "true", dont_touch = "true" *) wire rst_sync = !rst_n;

	reg [NUM_ENTRIES-1:0] valid;
	reg [TAG_W-1:0] tag [0:NUM_ENTRIES-1];

	/* Buffer release_valid, release_id, and alloc_tag into 2 halves (8 entries each) so fanout <= 16 */
	wire [1:0] rel_v_buf;
	wire [3:0] rel_id_buf [0:1];
	wire [TAG_W-1:0] alloc_tag_buf [0:1];
	genvar gh, gb;
	generate
	for (gh = 0; gh < 2; gh = gh + 1) begin : g_rel_buf
`ifdef SYNTH_KINTEX7
		(* keep = "true", dont_touch = "true" *)
		LUT1 #(.INIT(2'b10)) u_rv (.O(rel_v_buf[gh]), .I0(release_valid));
		for (gb = 0; gb < 4; gb = gb + 1) begin : g_rid
			(* keep = "true", dont_touch = "true" *)
			LUT1 #(.INIT(2'b10)) u_rid (.O(rel_id_buf[gh][gb]), .I0(release_id[gb]));
		end
		for (gb = 0; gb < TAG_W; gb = gb + 1) begin : g_atag
			(* keep = "true", dont_touch = "true" *)
			LUT1 #(.INIT(2'b10)) u_atag (.O(alloc_tag_buf[gh][gb]), .I0(alloc_tag[gb]));
		end
`else
		assign rel_v_buf[gh] = release_valid;
		assign rel_id_buf[gh] = release_id;
		assign alloc_tag_buf[gh] = alloc_tag;
`endif
	end
	endgenerate

	(* keep = "true" *) wire [NUM_ENTRIES-1:0] hit_ent;
	(* keep = "true" *) wire [NUM_ENTRIES-1:0] empty;
	(* keep = "true" *) wire [NUM_ENTRIES-1:0] i_val_vec;
	genvar i, gs, gp;

`ifdef SYNTH_KINTEX7
	/* 2-LUT-level hazard and full detection for 5nm ASIC lint:
	 * Level 1: 8 x 6-input LUT6 hit_pair[7:0] (2 entries per LUT6) + 3 x full_g[2:0]
	 * Level 2: 2 x 6-input LUT6 grp_hit_int/ext[1:0]
	 */
	(* keep = "true" *) wire [7:0] hit_pair;
	generate
	for (i = 0; i < NUM_ENTRIES; i = i + 1) begin : g_cam
		localparam H_IDX = i / 8;
		(* keep = "true" *) wire i_val = valid[i] && (!rel_v_buf[H_IDX] || (rel_id_buf[H_IDX] != i[3:0]));
		assign i_val_vec[i] = i_val;
		assign empty[i] = !valid[i];
		assign hit_ent[i] = 1'b0;
	end
	for (gp = 0; gp < 8; gp = gp + 1) begin : g_hit_pair
		localparam integer B0 = 4 + 2 * gp;
		localparam integer B1 = 4 + 2 * gp + 1;
		assign hit_pair[gp] =
			(valid[2 * gp]     && (tag[2 * gp][B0]     == alloc_tag[B0])) ||
			(valid[2 * gp + 1] && (tag[2 * gp + 1][B1] == alloc_tag[B1]));
	end
	endgenerate
`else
	generate
	for (i = 0; i < NUM_ENTRIES; i = i + 1) begin : g_cam
		localparam H_IDX = i / 8;
		wire [32:0] tag_pad = {{(33-TAG_W){1'b0}}, tag[i]};
		wire [32:0] alloc_tag_pad = {{(33-TAG_W){1'b0}}, alloc_tag_buf[H_IDX]};

		(* keep = "true" *) wire i_val = valid[i] && (!rel_v_buf[H_IDX] || (rel_id_buf[H_IDX] != i[3:0]));
		assign i_val_vec[i] = i_val;
		assign empty[i] = !valid[i] || (rel_v_buf[H_IDX] && (rel_id_buf[H_IDX] == i[3:0]));
		wire [10:0] eq_all;
		for (gs = 0; gs < 11; gs = gs + 1) begin : g_slice
			assign eq_all[gs] = (tag_pad[gs*3 +: 3] == alloc_tag_pad[gs*3 +: 3]);
		end
		assign hit_ent[i] = i_val & (&eq_all);
	end
	endgenerate
`endif

	/* 2-level priority & empty tree across 4 groups of 4 entries */
	(* keep = "true" *) wire [3:0] grp_has;
	(* keep = "true" *) wire [7:0] grp_id_flat;
	(* keep = "true" *) wire [NUM_ENTRIES-1:0] loc_sel;
	genvar gg;
	generate
	for (gg = 0; gg < 4; gg = gg + 1) begin : g_grp
		wire e0 = empty[4*gg + 0];
		wire e1 = empty[4*gg + 1];
		wire e2 = empty[4*gg + 2];
		wire e3 = empty[4*gg + 3];
		assign grp_has[gg] = e0 | e1 | e2 | e3;
		assign grp_id_flat[2*gg + 1] = !e0 && !e1;
		assign grp_id_flat[2*gg + 0] = !e0 && (e1 || !e2);
		assign loc_sel[4*gg + 0] = e0;
		assign loc_sel[4*gg + 1] = !e0 && e1;
		assign loc_sel[4*gg + 2] = !e0 && !e1 && e2;
		assign loc_sel[4*gg + 3] = !e0 && !e1 && !e2 && e3;
	end
	endgenerate

	(* keep = "true" *) wire [3:0] grp_sel;
	assign grp_sel[0] = 1'b1;
	assign grp_sel[1] = !grp_has[0];
	assign grp_sel[2] = !grp_has[0] && !grp_has[1];
	assign grp_sel[3] = !grp_has[0] && !grp_has[1] && !grp_has[2];

	(* keep = "true" *) wire [2:0] grp_hit_int;
	(* keep = "true" *) wire [2:0] grp_hit_ext;
`ifdef SYNTH_KINTEX7
	(* keep = "true" *) wire full_g0 = &valid[5:0];
	(* keep = "true" *) wire full_g1 = &valid[11:6];
	(* keep = "true" *) wire full_g2 = &valid[15:12];

	assign grp_hit_int[0] = |hit_pair[5:0];
	assign grp_hit_int[1] = hit_pair[6] | hit_pair[7] | (full_g0 & full_g1 & full_g2);
	assign grp_hit_int[2] = 1'b0;

	assign grp_hit_ext[0] = |hit_pair[5:0];
	assign grp_hit_ext[1] = hit_pair[6] | hit_pair[7] | (full_g0 & full_g1 & full_g2);
	assign grp_hit_ext[2] = 1'b0;
	wire unused_haz_k7 = &{1'b0, hit_ent};
`else
	(* keep = "true" *) wire cam_full = ~(|grp_has);

	/* Level 3: combine 6 entries per LUT6 (3 LUT6s total) + replicated copy for external output */
	assign grp_hit_int[0] = |hit_ent[5:0];
	assign grp_hit_int[1] = |hit_ent[11:6];
	assign grp_hit_int[2] = (|hit_ent[15:12]) | cam_full;

	assign grp_hit_ext[0] = |hit_ent[5:0];
	assign grp_hit_ext[1] = |hit_ent[11:6];
	assign grp_hit_ext[2] = (|hit_ent[15:12]) | cam_full;
`endif

	assign o_grp_hit = grp_hit_ext;

	/* Level 4: single 3-input NOR produces alloc_ready */
	assign alloc_ready = ~(|grp_hit_ext);

	/* 2-LUT-level priority encoder for alloc_id */
	always @(*) begin
		alloc_id[3] = !grp_has[0] && !grp_has[1];
		alloc_id[2] = !grp_has[0] && (grp_has[1] || !grp_has[2]);
		if (grp_has[0])      alloc_id[1:0] = grp_id_flat[1:0];
		else if (grp_has[1]) alloc_id[1:0] = grp_id_flat[3:2];
		else if (grp_has[2]) alloc_id[1:0] = grp_id_flat[5:4];
		else                 alloc_id[1:0] = grp_id_flat[7:6];
	end

	localparam S0_W = 11;
	localparam S1_W = 11;
	generate
	for (i = 0; i < NUM_ENTRIES; i = i + 1) begin : g_ent
		localparam G_IDX = i / 4;
		localparam H_IDX = i / 8;
		(* keep = "true" *) wire slot_sel_i = grp_sel[G_IDX] && loc_sel[i];
		/* Level 4: single 6-input LUT6 computes next valid[i] */
		(* keep = "true" *) wire val_next_i =
			(alloc_valid && !grp_hit_int[0] && !grp_hit_int[1] && !grp_hit_int[2] && slot_sel_i) ||
			i_val_vec[i];

`ifdef SYNTH_KINTEX7
		wire [2:0] we_tag_buf;
		for (gb = 0; gb < 3; gb = gb + 1) begin : g_we_buf
			(* keep = "true", dont_touch = "true" *)
			LUT1 #(.INIT(2'b10)) u_we (.O(we_tag_buf[gb]), .I0(slot_sel_i));
		end
		always @(posedge clk) begin
			if (rst_sync)
				valid[i] <= 1'b0;
			else
				valid[i] <= val_next_i;
			if (we_tag_buf[0])
				tag[i][S0_W-1:0] <= alloc_tag_buf[H_IDX][S0_W-1:0];
			if (we_tag_buf[1])
				tag[i][S0_W+S1_W-1:S0_W] <= alloc_tag_buf[H_IDX][S0_W+S1_W-1:S0_W];
			if (we_tag_buf[2])
				tag[i][TAG_W-1:S0_W+S1_W] <= alloc_tag_buf[H_IDX][TAG_W-1:S0_W+S1_W];
		end
`else
		always @(posedge clk) begin
			if (rst_sync) begin
				valid[i] <= 1'b0;
				tag[i] <= {TAG_W{1'b0}};
			end else begin
				valid[i] <= val_next_i;
				if (alloc_valid && !grp_hit_int[0] && !grp_hit_int[1] && !grp_hit_int[2] && slot_sel_i)
					tag[i] <= alloc_tag_buf[H_IDX];
			end
		end
`endif
	end
	endgenerate
endmodule

`default_nettype wire
