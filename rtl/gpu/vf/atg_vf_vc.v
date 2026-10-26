/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_vc: Post-Transform Vertex Cache (PT-VC, Phase 033):
 * 32-entry fully-associative post-transform vertex cache for indexed draws.
 * Caches transformed vertex clip positions and varying attributes to eliminate
 * redundant vertex shader execution for shared vertices in index meshes.
 *
 * Lookup is zero-cycle combinational CAM match.
 * On hit: bypasses SU vertex shader issue and reuses cached vertex data.
 * On miss: vertex proceeds through SU, and result is committed upon shader completion.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_vc #(
	parameter NENTRIES = 32,
	parameter VDATA_W  = 512,	/* Clip position (x, y, z, w) + point size + varyings */
	parameter SLOT_W   = 5
) (
	input  wire clk,
	input  wire rst_n,
	input  wire flush,	/* Cache flush on draw call boundary */

	/* Index lookup port */
	input  wire        lookup_valid,
	input  wire [31:0] lookup_index,
	output wire        hit,
	output wire [VDATA_W-1:0] hit_vdata,
	output wire [SLOT_W-1:0]  hit_slot,

	/* SU shader completion commit port */
	input  wire        commit_valid,
	input  wire [31:0] commit_index,
	input  wire [VDATA_W-1:0] commit_vdata
);
	reg [31:0]        entry_idx   [0:NENTRIES-1];
	reg [VDATA_W-1:0] entry_vdata [0:NENTRIES-1];
	reg [NENTRIES-1:0] entry_valid;
	reg [SLOT_W-1:0]  victim_ptr;

	function [4:0] inc5;
		input [4:0] v;
		case (v)
		5'd0: inc5 = 5'd1;
		5'd1: inc5 = 5'd2;
		5'd2: inc5 = 5'd3;
		5'd3: inc5 = 5'd4;
		5'd4: inc5 = 5'd5;
		5'd5: inc5 = 5'd6;
		5'd6: inc5 = 5'd7;
		5'd7: inc5 = 5'd8;
		5'd8: inc5 = 5'd9;
		5'd9: inc5 = 5'd10;
		5'd10: inc5 = 5'd11;
		5'd11: inc5 = 5'd12;
		5'd12: inc5 = 5'd13;
		5'd13: inc5 = 5'd14;
		5'd14: inc5 = 5'd15;
		5'd15: inc5 = 5'd16;
		5'd16: inc5 = 5'd17;
		5'd17: inc5 = 5'd18;
		5'd18: inc5 = 5'd19;
		5'd19: inc5 = 5'd20;
		5'd20: inc5 = 5'd21;
		5'd21: inc5 = 5'd22;
		5'd22: inc5 = 5'd23;
		5'd23: inc5 = 5'd24;
		5'd24: inc5 = 5'd25;
		5'd25: inc5 = 5'd26;
		5'd26: inc5 = 5'd27;
		5'd27: inc5 = 5'd28;
		5'd28: inc5 = 5'd29;
		5'd29: inc5 = 5'd30;
		5'd30: inc5 = 5'd31;
		5'd31: inc5 = 5'd0;
		default: inc5 = 5'd0;
		endcase
	endfunction

	function [4:0] prio32;
		input [31:0] m;
		casez (m)
		32'b???????????????????????????????1: prio32 = 5'd0;
		32'b??????????????????????????????10: prio32 = 5'd1;
		32'b?????????????????????????????100: prio32 = 5'd2;
		32'b????????????????????????????1000: prio32 = 5'd3;
		32'b???????????????????????????10000: prio32 = 5'd4;
		32'b??????????????????????????100000: prio32 = 5'd5;
		32'b?????????????????????????1000000: prio32 = 5'd6;
		32'b????????????????????????10000000: prio32 = 5'd7;
		32'b???????????????????????100000000: prio32 = 5'd8;
		32'b??????????????????????1000000000: prio32 = 5'd9;
		32'b?????????????????????10000000000: prio32 = 5'd10;
		32'b????????????????????100000000000: prio32 = 5'd11;
		32'b???????????????????1000000000000: prio32 = 5'd12;
		32'b??????????????????10000000000000: prio32 = 5'd13;
		32'b?????????????????100000000000000: prio32 = 5'd14;
		32'b????????????????1000000000000000: prio32 = 5'd15;
		32'b???????????????10000000000000000: prio32 = 5'd16;
		32'b??????????????100000000000000000: prio32 = 5'd17;
		32'b?????????????1000000000000000000: prio32 = 5'd18;
		32'b????????????10000000000000000000: prio32 = 5'd19;
		32'b???????????100000000000000000000: prio32 = 5'd20;
		32'b??????????1000000000000000000000: prio32 = 5'd21;
		32'b?????????10000000000000000000000: prio32 = 5'd22;
		32'b????????100000000000000000000000: prio32 = 5'd23;
		32'b???????1000000000000000000000000: prio32 = 5'd24;
		32'b??????10000000000000000000000000: prio32 = 5'd25;
		32'b?????100000000000000000000000000: prio32 = 5'd26;
		32'b????1000000000000000000000000000: prio32 = 5'd27;
		32'b???10000000000000000000000000000: prio32 = 5'd28;
		32'b??100000000000000000000000000000: prio32 = 5'd29;
		32'b?1000000000000000000000000000000: prio32 = 5'd30;
		32'b10000000000000000000000000000000: prio32 = 5'd31;
		default: prio32 = 5'd0;
		endcase
	endfunction

	/* CAM Lookup logic */
	wire [NENTRIES-1:0] match_vec;
	genvar gi;
	generate
		for (gi = 0; gi < NENTRIES; gi = gi + 1) begin: g_match
			assign match_vec[gi] = entry_valid[gi] && (entry_idx[gi] == lookup_index);
		end
	endgenerate

	wire is_hit = lookup_valid && (|match_vec);
	wire [4:0] hit_idx = prio32(match_vec);

	assign hit = is_hit;
	assign hit_slot = hit_idx;
	assign hit_vdata = entry_vdata[hit_idx];

	/* Commit logic */
	wire [NENTRIES-1:0] commit_match_vec;
	generate
		for (gi = 0; gi < NENTRIES; gi = gi + 1) begin: g_commit_match
			assign commit_match_vec[gi] = entry_valid[gi] && (entry_idx[gi] == commit_index);
		end
	endgenerate

	wire commit_hit = |commit_match_vec;
	wire [4:0] commit_hit_slot = prio32(commit_match_vec);

	wire [31:0] free_vec = ~entry_valid;
	wire has_free = |free_vec;
	wire [4:0] free_slot = prio32(free_vec);

	wire [4:0] alloc_slot = commit_hit ? commit_hit_slot :
		(has_free ? free_slot : victim_ptr);

	integer i;
	always @(posedge clk) begin
		if (!rst_n || flush) begin
			entry_valid <= {NENTRIES{1'b0}};
			victim_ptr  <= 5'd0;
			for (i = 0; i < NENTRIES; i = i + 1) begin
				entry_idx[i]   <= 32'd0;
				entry_vdata[i] <= {VDATA_W{1'b0}};
			end
		end else if (commit_valid) begin
			entry_valid[alloc_slot] <= 1'b1;
			entry_idx[alloc_slot]   <= commit_index;
			entry_vdata[alloc_slot] <= commit_vdata;
			if (!commit_hit && !has_free)
				victim_ptr <= inc5(victim_ptr);
		end
	end
endmodule

`default_nettype wire
