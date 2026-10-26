/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_arb3: picks one of three valid sources in turn and keeps it for a
 * whole unit (am_axi_split's B and R; spec/library/bus/am_axi_split.md).  sel
 * is the source shown: while a unit is under way (a transfer of it went
 * through, fire, without last; or the source was shown valid without
 * fire) the same one; otherwise the next valid source after the one that
 * finished the last unit.
 * fire: a transfer of sel went through; last: it ended the unit (a B is
 * always last; an R beat with RLAST).
 */

`timescale 1ns / 1ps
`default_nettype none

module am_arb3 (
	input wire clk,
	input wire rst_n,
	input wire [2:0] v,
	input wire fire,
	input wire last,
	output wire [1:0] sel
);
	reg hold;
	reg [1:0] hsel, prev;
	reg [1:0] pick;

	always @(*) begin
		case (prev)
		2'd0: pick = v[1] ? 2'd1 : v[2] ? 2'd2 : 2'd0;
		2'd1: pick = v[2] ? 2'd2 : v[0] ? 2'd0 : 2'd1;
		default: pick = v[0] ? 2'd0 : v[1] ? 2'd1 : 2'd2;
		endcase
	end

	assign sel = hold ? hsel : pick;
	wire shown = sel == 2'd0 ? v[0] : sel == 2'd1 ? v[1] : v[2];

	always @(posedge clk) begin
		if (!rst_n) begin
			hold <= 1'b0;
			hsel <= 2'd0;
			prev <= 2'd2;
		end else begin
`ifdef MUT_SPLIT_NOHOLD
			hold <= !fire && shown;
`else
			hold <= fire ? !last : hold || shown;
`endif
			hsel <= sel;
			if (fire && last)
				prev <= sel;
		end
	end
endmodule

`default_nettype wire
