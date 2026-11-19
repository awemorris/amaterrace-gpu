/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_grant: the grant CAM of session protection
 * (spec/gpu/mc/atg_mc_grant.md, docs/ghci.md section 11.6).  NGRANT
 * entries, each {valid, slot, read, write, base, limit}: the protected
 * session in slot `slot` may also read (write) the granules [base, limit)
 * (absolute granule numbers, address >> 12; limit has one bit more so
 * that 2^20 can be the end).
 *
 * Lookup (combinational): hit = some valid entry with the slot, base <= g
 * < limit and the access's permission (write for a write).  Slot 0 never
 * hits (it is not a protected session).
 *
 * Write port (the firmware, through the CP): w_valid for one cycle
 * replaces the entry w_idx with w_data = {limit[20:0], base[19:0],
 * write, read, slot[5:0], valid}.  rst_n and flush (the CP's RESET) make
 * every entry invalid.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_grant #(
	parameter NGRANT = 8,
	parameter IDX_W = 3	/* clog2(NGRANT) */
) (
	input wire clk,
	input wire rst_n,
	input wire flush,

	input wire w_valid,
	input wire [IDX_W-1:0] w_idx,
	input wire [49:0] w_data,

	input wire [5:0] slot,
	input wire [19:0] g,
	input wire write,
	output wire hit
);
	reg [NGRANT-1:0] e_valid;
	reg [NGRANT*6-1:0] e_slot;
	reg [NGRANT-1:0] e_read;
	reg [NGRANT-1:0] e_write;
	reg [NGRANT*20-1:0] e_base;
	reg [NGRANT*21-1:0] e_limit;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			e_valid <= {NGRANT{1'b0}};
		end else if (flush) begin
			e_valid <= {NGRANT{1'b0}};
		end else if (w_valid) begin
			e_valid[w_idx] <= w_data[0];
			e_read[w_idx] <= w_data[7];
			e_write[w_idx] <= w_data[8];
		end
	end

	/*
	 * The entry's fields need no reset: valid says whether they mean
	 * anything.  The entry is chosen by comparing w_idx with each index (a
	 * constant part-select per entry, no multiply of the index).
	 */
	integer j;

	always @(posedge clk) begin
		for (j = 0; j < NGRANT; j = j + 1) begin
			if (w_valid && {{(32 - IDX_W){1'b0}}, w_idx} == j) begin
				e_slot[j*6 +: 6] <= w_data[6:1];
				e_base[j*20 +: 20] <= w_data[28:9];
				e_limit[j*21 +: 21] <= w_data[49:29];
			end
		end
	end

	/* Parallel per-entry match + OR reduction keeps depth O(1) for NGRANT=64. */
	wire [NGRANT-1:0] entry_hit;
	genvar gk;
	generate
		for (gk = 0; gk < NGRANT; gk = gk + 1) begin : g_ent
			wire dir_ok = write ? e_write[gk] : e_read[gk];
			wire slot_ok = e_slot[gk*6 +: 6] == slot;
			wire lo_ok = e_base[gk*20 +: 20] <= g;
`ifdef MUT_PROT_LIMIT
			wire hi_ok = {1'b0, g} <= e_limit[gk*21 +: 21];
`else
			wire hi_ok = {1'b0, g} < e_limit[gk*21 +: 21];
`endif
			assign entry_hit[gk] = e_valid[gk] && dir_ok && slot_ok && lo_ok && hi_ok;
		end
	endgenerate
	assign hit = (slot != 6'd0) && (|entry_hit);
endmodule

`default_nettype wire
