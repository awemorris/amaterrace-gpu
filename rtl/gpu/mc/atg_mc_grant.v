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
	output reg hit
);
	reg [NGRANT-1:0] e_valid;
	reg [NGRANT*6-1:0] e_slot;
	reg [NGRANT-1:0] e_read;
	reg [NGRANT-1:0] e_write;
	reg [NGRANT*20-1:0] e_base;
	reg [NGRANT*21-1:0] e_limit;
	integer k;

	always @(posedge clk) begin
		if (!rst_n || flush) begin
			e_valid <= {NGRANT{1'b0}};
		end else if (w_valid) begin
			e_valid[w_idx] <= w_data[0];
			e_read[w_idx] <= w_data[7];
			e_write[w_idx] <= w_data[8];
		end
	end

	/* The entry's fields need no reset: valid says whether they mean anything. */
	always @(posedge clk) begin
		if (w_valid) begin
			e_slot[w_idx*6 +: 6] <= w_data[6:1];
			e_base[w_idx*20 +: 20] <= w_data[28:9];
			e_limit[w_idx*21 +: 21] <= w_data[49:29];
		end
	end

	always @(*) begin
		hit = 1'b0;
		for (k = 0; k < NGRANT; k = k + 1)
			if (e_valid[k] && e_slot[k*6 +: 6] == slot && e_base[k*20 +: 20] <= g &&
`ifdef MUT_PROT_LIMIT
			    {1'b0, g} <= e_limit[k*21 +: 21] &&
`else
			    {1'b0, g} < e_limit[k*21 +: 21] &&
`endif
			    (write ? e_write[k] : e_read[k]))
				hit = slot != 6'd0;
	end
endmodule

`default_nettype wire
