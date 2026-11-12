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
	(* MAX_FANOUT = 16 *) reg signed [47:0] op [0:2];
	(* MAX_FANOUT = 16 *) reg signed [47:0] oq [0:2];
	(* MAX_FANOUT = 16 *) reg signed [47:0] es [0:2];

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire [2:0] i_load_edge;
	LUT1 #(.INIT(2'b10)) u_ild_0 (.I0(i_load), .O(i_load_edge[0]));
	LUT1 #(.INIT(2'b10)) u_ild_1 (.I0(i_load), .O(i_load_edge[1]));
	LUT1 #(.INIT(2'b10)) u_ild_2 (.I0(i_load), .O(i_load_edge[2]));

	reg r_load;
	always @(posedge clk) r_load <= i_load;

	wire [2:0] w_load_op [0:2];
	wire [2:0] w_load_oq [0:2];
	genvar gg, gsl;
	generate
		for (gg = 0; gg < 3; gg = gg + 1) begin : g_ld_buf
			for (gsl = 0; gsl < 3; gsl = gsl + 1) begin : g_ld_s
				(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_w_op (.I0(r_load), .O(w_load_op[gg][gsl]));
				(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_w_oq (.I0(r_load), .O(w_load_oq[gg][gsl]));
			end
		end
	endgenerate
`endif

	function signed [47:0] sx48;
		input [23:0] v;
		sx48 = {{24{v[23]}}, v};
	endfunction

	/* All the bits below the top set bit of v, set (v itself included).
	 * Implemented with hierarchical prefix-OR across 8 groups of 6 bits
	 * guaranteeing <= 2 LUT levels. */
	/* verilator lint_off BLKSEQ */
	function [47:0] smear;
		input [47:0] v;
		reg [7:0] grp;
		reg [7:0] pfx;
		integer k, j, m;
		reg w;
		begin
			for (k = 0; k < 8; k = k + 1)
				grp[k] = |v[k*6 +: 6];
			pfx[7] = grp[7];
			for (k = 6; k >= 0; k = k - 1)
				pfx[k] = grp[k] | pfx[k+1];
			for (k = 0; k < 8; k = k + 1) begin
				for (j = 0; j < 6; j = j + 1) begin
					w = 1'b0;
					for (m = j; m < 6; m = m + 1)
						w = w | v[k*6 + m];
					if (k < 7)
						smear[k*6 + j] = pfx[k+1] | w;
					else
						smear[k*6 + j] = w;
				end
			end
		end
	endfunction
	/* verilator lint_on BLKSEQ */

	genvar ge;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_e
`ifdef SYNTH_KINTEX7
		(* keep = "true", dont_touch = "true" *) wire sgn_a_0, sgn_a_1, sgn_a_2, sgn_a_3;
		(* keep = "true", dont_touch = "true" *) wire sgn_b_0, sgn_b_1, sgn_b_2, sgn_b_3;
		LUT1 #(.INIT(2'b10)) u_sgn_a0 (.I0(i_ab[48 * ge + 23]), .O(sgn_a_0));
		LUT1 #(.INIT(2'b10)) u_sgn_a1 (.I0(i_ab[48 * ge + 23]), .O(sgn_a_1));
		LUT1 #(.INIT(2'b10)) u_sgn_a2 (.I0(i_ab[48 * ge + 23]), .O(sgn_a_2));
		LUT1 #(.INIT(2'b10)) u_sgn_a3 (.I0(i_ab[48 * ge + 23]), .O(sgn_a_3));
		LUT1 #(.INIT(2'b10)) u_sgn_b0 (.I0(i_ab[48 * ge + 47]), .O(sgn_b_0));
		LUT1 #(.INIT(2'b10)) u_sgn_b1 (.I0(i_ab[48 * ge + 47]), .O(sgn_b_1));
		LUT1 #(.INIT(2'b10)) u_sgn_b2 (.I0(i_ab[48 * ge + 47]), .O(sgn_b_2));
		LUT1 #(.INIT(2'b10)) u_sgn_b3 (.I0(i_ab[48 * ge + 47]), .O(sgn_b_3));
		wire [47:0] a = {{6{sgn_a_3}}, {6{sgn_a_2}}, {6{sgn_a_1}}, {6{sgn_a_0}}, i_ab[48 * ge +: 24]};
		wire [47:0] b = {{6{sgn_b_3}}, {6{sgn_b_2}}, {6{sgn_b_1}}, {6{sgn_b_0}}, i_ab[48 * ge + 24 +: 24]};
`else
		wire [47:0] a = sx48(i_ab[48 * ge +: 24]);
		wire [47:0] b = sx48(i_ab[48 * ge + 24 +: 24]);
`endif
		/* op = 32 A + 64 B + 32 B, oq = 64 A + 32 A - 32 B; |op|, |oq| */
		wire [47:0] op1, oq1, pa, qa, es_n;
		wire [6:0] carry_unused;
		am_add #(.W(48)) u_op1 (.a(a <<< 5), .b(b <<< 6), .ci(1'b0), .s(op1), .co(carry_unused[0]));
		am_add #(.W(48)) u_oq1 (.a(a <<< 6), .b(a <<< 5), .ci(1'b0), .s(oq1), .co(carry_unused[2]));

`ifdef SYNTH_KINTEX7
		wire [47:0] b_s5 = b <<< 5;
		(* extract_reset = "no" *) reg signed [15:0] op1_r [0:2];
		(* extract_reset = "no" *) reg signed [15:0] oq1_r [0:2];
		(* extract_reset = "no" *) reg signed [15:0] b_s5_op_r [0:2];
		(* extract_reset = "no" *) reg signed [15:0] b_s5_oq_r [0:2];
		genvar gr;
		for (gr = 0; gr < 3; gr = gr + 1) begin : g_r_pipe
			(* keep = "true", dont_touch = "true" *) wire we_op1, we_oq1, we_bop, we_boq;
			LUT1 #(.INIT(2'b10)) u_we_op1 (.I0(i_load_edge[ge]), .O(we_op1));
			LUT1 #(.INIT(2'b10)) u_we_oq1 (.I0(i_load_edge[ge]), .O(we_oq1));
			LUT1 #(.INIT(2'b10)) u_we_bop (.I0(i_load_edge[ge]), .O(we_bop));
			LUT1 #(.INIT(2'b10)) u_we_boq (.I0(i_load_edge[ge]), .O(we_boq));
			always @(posedge clk) begin
				if (we_op1) op1_r[gr]     <= op1[16 * gr +: 16];
				if (we_oq1) oq1_r[gr]     <= oq1[16 * gr +: 16];
				if (we_bop) b_s5_op_r[gr] <= b_s5[16 * gr +: 16];
				if (we_boq) b_s5_oq_r[gr] <= b_s5[16 * gr +: 16];
			end
		end
		wire [47:0] op1_r_w     = {op1_r[2], op1_r[1], op1_r[0]};
		wire [47:0] oq1_r_w     = {oq1_r[2], oq1_r[1], oq1_r[0]};
		wire [47:0] b_s5_op_r_w = {b_s5_op_r[2], b_s5_op_r[1], b_s5_op_r[0]};
		wire [47:0] b_s5_oq_r_w = {b_s5_oq_r[2], b_s5_oq_r[1], b_s5_oq_r[0]};
		wire [47:0] op_n, oq_n;
		am_add #(.W(48)) u_op (.a(op1_r_w), .b(b_s5_op_r_w), .ci(1'b0), .s(op_n), .co(carry_unused[1]));
		am_sub #(.W(48)) u_oq (.a(oq1_r_w), .b(b_s5_oq_r_w), .bi(1'b0), .d(oq_n), .bo(carry_unused[3]));
`else
		wire [47:0] op_n, oq_n;
		am_add #(.W(48)) u_op (.a(op1), .b(b <<< 5), .ci(1'b0), .s(op_n), .co(carry_unused[1]));
		am_sub #(.W(48)) u_oq (.a(oq1), .b(b <<< 5), .bi(1'b0), .d(oq_n), .bo(carry_unused[3]));
`endif
		wire [47:0] pa_in = op[ge];
		wire [47:0] qa_in = oq[ge];
		am_addsub #(.W(48)) u_pa (.a(48'd0), .b(pa_in), .sub(pa_in[47]), .s(pa), .co(carry_unused[4]));
		am_addsub #(.W(48)) u_qa (.a(48'd0), .b(qa_in), .sub(qa_in[47]), .s(qa), .co(carry_unused[5]));
		/* es: ec - op (start), ec + oq (sample 0), ec - oq (1), ec + op (2, 3) */
		am_addsub #(.W(48)) u_es (.a(i_ec[48 * ge +: 48]), .b(i_start || i_sc[1] ? op[ge] : oq[ge]),
`ifdef MUT_SAMPLE_SWAP
			.sub(i_start || i_sc == 2'd0),
`else
			.sub(i_start || i_sc == 2'd1),
`endif
			.s(es_n), .co(carry_unused[6]));
		(* dont_touch = "true", extract_reset = "no" *) reg [47:0] r_pqa;
		always @(posedge clk) begin
			r_pqa <= pa | qa;
`ifdef MUT_COV_SKIP
			o_lowm[48 * ge +: 48] <= smear(r_pqa) >> 3;
`else
			o_lowm[48 * ge +: 48] <= smear(r_pqa);
`endif
			if (i_start || i_step)
				es[ge] <= es_n;
		end

		genvar gs_e;
		for (gs_e = 0; gs_e < 3; gs_e = gs_e + 1) begin : g_opq_slices
`ifdef SYNTH_KINTEX7
			always @(posedge clk) begin
				if (w_load_op[ge][gs_e]) op[ge][16 * gs_e +: 16] <= op_n[16 * gs_e +: 16];
				if (w_load_oq[ge][gs_e]) oq[ge][16 * gs_e +: 16] <= oq_n[16 * gs_e +: 16];
			end
`else
			always @(posedge clk) begin
				if (i_load) begin
					op[ge][16 * gs_e +: 16] <= op_n[16 * gs_e +: 16];
					oq[ge][16 * gs_e +: 16] <= oq_n[16 * gs_e +: 16];
				end
			end
`endif
		end
	end
	endgenerate

	wire signed [47:0] es_0 = es[0], es_1 = es[1], es_2 = es[2];
	assign o_eb = i_samp ? {es_2, es_1, es_0} : i_ec;
	assign o_op = {op[2], op[1], op[0]};
	assign o_oq = {oq[2], oq[1], oq[0]};
endmodule

`default_nettype wire
