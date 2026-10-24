/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_cov: the sample offsets of atg_rx_scan's multisampling (docs/
 * ghci.md section 12.11).  At the triangle's load (i_load, the edges' A
 * and B in 15.8 subpixel steps) it makes, per edge, P = 32 A + 96 B and
 * Q = 96 A - 32 B: the edge's change from the pixel centre to the
 * standard sample locations (offsets (-32, -96), (96, -32), (-96, 32),
 * (32, 96) subpixels) are -P, +Q, -Q, +P for samples 0..3.  The next cycle
 * o_lowm holds, per edge, the bits below the top bit of |P| | |Q|, set: a
 * value v < -(o_lowm + 1) is further outside than any sample reaches.
 *
 * es, the edges at the quad plus a sample's offset: i_start loads sample
 * 0's (i_ec - P), i_step with i_sc = s the next sample's (i_ec + the
 * offset of s + 1).  o_eb = es while i_samp, else i_ec (the lanes' adders
 * of atg_rx_scan take o_eb).  Values referenced: Vulkan specification,
 * Multisampling, standard sample locations (VK_SAMPLE_COUNT_4_BIT).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_cov (
	input wire clk,
	input wire i_load,
	input wire [143:0] i_ab,	/* edge e: {B, A} (24 bits each) at bits 48 e */
	input wire [143:0] i_ec,	/* the edges at the quad, 48 bits each */
	input wire i_start,
	input wire i_step,
	input wire [1:0] i_sc,
	input wire i_samp,
	output wire [143:0] o_eb,
	output reg [143:0] o_lowm
);
	reg signed [47:0] op [0:2];
	reg signed [47:0] oq [0:2];
	reg signed [47:0] es [0:2];
	integer k;

	function signed [47:0] sx48;
		input [23:0] v;
		sx48 = {{24{v[23]}}, v};
	endfunction

	function [47:0] abs48;
		input [47:0] v;
		abs48 = v[47] ? -v : v;
	endfunction

	/* All the bits below the top set bit of v, set (v itself included). */
	function [47:0] smear;
		input [47:0] v;
		integer b;
		begin
			smear = 48'd0;
			for (b = 0; b < 48; b = b + 1)
				if (v[b])
					smear = (48'd1 << b) | ((48'd1 << b) - 48'd1);
		end
	endfunction

	always @(posedge clk) begin
		for (k = 0; k < 3; k = k + 1) begin
			if (i_load) begin
				op[k] <= (sx48(i_ab[48 * k +: 24]) <<< 5) +
					(sx48(i_ab[48 * k + 24 +: 24]) <<< 6) +
					(sx48(i_ab[48 * k + 24 +: 24]) <<< 5);
				oq[k] <= (sx48(i_ab[48 * k +: 24]) <<< 6) +
					(sx48(i_ab[48 * k +: 24]) <<< 5) -
					(sx48(i_ab[48 * k + 24 +: 24]) <<< 5);
			end
`ifdef MUT_COV_SKIP
			o_lowm[48 * k +: 48] <= smear(abs48(op[k]) | abs48(oq[k])) >> 3;
`else
			o_lowm[48 * k +: 48] <= smear(abs48(op[k]) | abs48(oq[k]));
`endif
			if (i_start)
				es[k] <= $signed(i_ec[48 * k +: 48]) - op[k];
			else if (i_step)
`ifdef MUT_SAMPLE_SWAP
				es[k] <= $signed(i_ec[48 * k +: 48]) +
					(i_sc == 2'd0 ? -oq[k] : i_sc == 2'd1 ? oq[k] : op[k]);
`else
				es[k] <= $signed(i_ec[48 * k +: 48]) +
					(i_sc == 2'd0 ? oq[k] : i_sc == 2'd1 ? -oq[k] : op[k]);
`endif
		end
	end

	wire signed [47:0] es_0 = es[0], es_1 = es[1], es_2 = es[2];
	assign o_eb = i_samp ? {es_2, es_1, es_0} : i_ec;
endmodule

`default_nettype wire
