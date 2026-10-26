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
	output reg [143:0] o_lowm,
	output wire [143:0] o_op,
	output wire [143:0] o_oq
);
	reg signed [47:0] op [0:2];
	reg signed [47:0] oq [0:2];
	reg signed [47:0] es [0:2];

	function signed [47:0] sx48;
		input [23:0] v;
		sx48 = {{24{v[23]}}, v};
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

	genvar ge;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_e
		wire [47:0] a = sx48(i_ab[48 * ge +: 24]);
		wire [47:0] b = sx48(i_ab[48 * ge + 24 +: 24]);
		/* op = 32 A + 64 B + 32 B, oq = 64 A + 32 A - 32 B; |op|, |oq| */
		wire [47:0] op1, op_n, oq1, oq_n, pa, qa, es_n;
		wire [6:0] carry_unused;
		am_add #(.W(48)) u_op1 (.a(a <<< 5), .b(b <<< 6), .ci(1'b0), .s(op1), .co(carry_unused[0]));
		am_add #(.W(48)) u_op (.a(op1), .b(b <<< 5), .ci(1'b0), .s(op_n), .co(carry_unused[1]));
		am_add #(.W(48)) u_oq1 (.a(a <<< 6), .b(a <<< 5), .ci(1'b0), .s(oq1), .co(carry_unused[2]));
		am_sub #(.W(48)) u_oq (.a(oq1), .b(b <<< 5), .bi(1'b0), .d(oq_n), .bo(carry_unused[3]));
		am_addsub #(.W(48)) u_pa (.a(48'd0), .b(op[ge]), .sub(op[ge][47]), .s(pa), .co(carry_unused[4]));
		am_addsub #(.W(48)) u_qa (.a(48'd0), .b(oq[ge]), .sub(oq[ge][47]), .s(qa), .co(carry_unused[5]));
		/* es: ec - op (start), ec + oq (sample 0), ec - oq (1), ec + op (2, 3) */
		am_addsub #(.W(48)) u_es (.a(i_ec[48 * ge +: 48]), .b(i_start || i_sc[1] ? op[ge] : oq[ge]),
`ifdef MUT_SAMPLE_SWAP
			.sub(i_start || i_sc == 2'd0),
`else
			.sub(i_start || i_sc == 2'd1),
`endif
			.s(es_n), .co(carry_unused[6]));
		always @(posedge clk) begin
			if (i_load) begin
				op[ge] <= op_n;
				oq[ge] <= oq_n;
			end
`ifdef MUT_COV_SKIP
			o_lowm[48 * ge +: 48] <= smear(pa | qa) >> 3;
`else
			o_lowm[48 * ge +: 48] <= smear(pa | qa);
`endif
			if (i_start || i_step)
				es[ge] <= es_n;
		end
	end
	endgenerate

	wire signed [47:0] es_0 = es[0], es_1 = es[1], es_2 = es[2];
	assign o_eb = i_samp ? {es_2, es_1, es_0} : i_ec;
	assign o_op = {op[2], op[1], op[0]};
	assign o_oq = {oq[2], oq[1], oq[0]};
endmodule

`default_nettype wire
