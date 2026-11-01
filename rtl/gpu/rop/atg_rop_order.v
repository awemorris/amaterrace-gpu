/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_order: ROP ordering (design §3.8): retires fragment quads in
 * sequence-number order from SU 0's exports and the RX's direct quads;
 * tells the SU which sequence it waits for.  The SU's quads come as beats
 * (one per colour attachment, CAPS[30]); a warp's beats pass in order and
 * its number retires with ex_last.
 *
 * Two counters (spec/gpu/rop/atg_rop_order.md).
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_rop_order (
	input wire clk,
	input wire rst_n,
	/* Fragment output of SU 0 (atg_su ex_*) */
	input wire ex_valid,
	output wire ex_ready,
	input wire [15:0] ex_seq,
	input wire [31:0] ex_xy,
	input wire [3:0] ex_mask,
	input wire [511:0] ex_color,
	input wire [511:0] ex_color1,
	input wire [127:0] ex_depth,
	input wire ex_last,
	output wire [15:0] ex_next,
	input wire [154:0] ex_aux,	/* {rt[2:0], qlast, qfirst, nocol, front, d_s, zexp, smask} */
	/* Direct fragments to the ROP (no SU: DEBUG_COLOR) */
	input wire dx_valid,
	output wire dx_ready,
	input wire [15:0] dx_seq,
	input wire [31:0] dx_xy,
	input wire [3:0] dx_mask,
	input wire [127:0] dx_depth,
	input wire dx_last,
	/* Issued sequence numbers (atg_rx ord_*) */
	input wire ord_valid,
	input wire [15:0] ord_seq,
	/* To atg_rop_ds */
	output wire q_valid,
	input wire q_ready,
	output wire [31:0] q_xy,
	output wire [3:0] q_mask,
	output wire [511:0] q_color,
	output wire [511:0] q_color1,
	output wire [127:0] q_depth,
	output wire q_dbg,
	output wire [154:0] q_aux,
	output wire busy
);
	/* spec/gpu/rop/atg_rop_order.md */
	reg [15:0] next;	/* the oldest unretired number */
	reg [15:0] issued;	/* numbers issued so far */
	(* keep = "true", dont_touch = "true" *) wire rst_sync = !rst_n;

	/* Pure-LUT 16-bit equality (3 bits per LUT6 -> 6 slices -> 1 LUT6 combine, 0 CARRY4s) */
	(* keep = "true" *) wire [5:0] ex_eq3;
	assign ex_eq3[0] = (ex_seq[2:0]   == next[2:0]);
	assign ex_eq3[1] = (ex_seq[5:3]   == next[5:3]);
	assign ex_eq3[2] = (ex_seq[8:6]   == next[8:6]);
	assign ex_eq3[3] = (ex_seq[11:9]  == next[11:9]);
	assign ex_eq3[4] = (ex_seq[14:12] == next[14:12]);
	assign ex_eq3[5] = (ex_seq[15]    == next[15]) && ex_valid;
	(* keep = "true" *) wire ex_ok = &ex_eq3;

	(* keep = "true" *) wire [5:0] dx_eq3;
	assign dx_eq3[0] = (dx_seq[2:0]   == next[2:0]);
	assign dx_eq3[1] = (dx_seq[5:3]   == next[5:3]);
	assign dx_eq3[2] = (dx_seq[8:6]   == next[8:6]);
	assign dx_eq3[3] = (dx_seq[11:9]  == next[11:9]);
	assign dx_eq3[4] = (dx_seq[14:12] == next[14:12]);
	assign dx_eq3[5] = (dx_seq[15]    == next[15]) && dx_valid;
	(* keep = "true" *) wire dx_ok = &dx_eq3;

	(* keep = "true" *) wire [5:0] busy_eq3;
	assign busy_eq3[0] = (issued[2:0]   == next[2:0]);
	assign busy_eq3[1] = (issued[5:3]   == next[5:3]);
	assign busy_eq3[2] = (issued[8:6]   == next[8:6]);
	assign busy_eq3[3] = (issued[11:9]  == next[11:9]);
	assign busy_eq3[4] = (issued[14:12] == next[14:12]);
	assign busy_eq3[5] = (issued[15]    == next[15]);
	assign busy = !(&busy_eq3);

	assign ex_next = next;
	assign q_valid = ex_ok || dx_ok;
`ifdef SYNTH_KINTEX7
	reg r_ex_ready, r_dx_ready;
	always @(posedge clk) begin
		if (rst_sync) begin
			r_ex_ready <= 1'b0;
			r_dx_ready <= 1'b0;
		end else begin
			r_ex_ready <= ex_ok && q_ready;
			r_dx_ready <= dx_ok && q_ready;
		end
	end
	assign ex_ready = r_ex_ready;
	assign dx_ready = r_dx_ready;

	(* keep = "true" *) wire [5:0] ex_eq3_rep [0:4];
	wire [40:0] ex_ok_buf;
	wire [127:0] ex_v_buf;
	wire [7:0] ex_v_mid;
	genvar g_ev_m, g_ev_b, g_qc;
	generate
	for (g_ev_m = 0; g_ev_m < 5; g_ev_m = g_ev_m + 1) begin : g_eq3_rep
		assign ex_eq3_rep[g_ev_m][0] = (ex_seq[2:0]   == next[2:0]);
		assign ex_eq3_rep[g_ev_m][1] = (ex_seq[5:3]   == next[5:3]);
		assign ex_eq3_rep[g_ev_m][2] = (ex_seq[8:6]   == next[8:6]);
		assign ex_eq3_rep[g_ev_m][3] = (ex_seq[11:9]  == next[11:9]);
		assign ex_eq3_rep[g_ev_m][4] = (ex_seq[14:12] == next[14:12]);
		assign ex_eq3_rep[g_ev_m][5] = (ex_seq[15]    == next[15]) && ex_valid;
	end
	for (g_ev_b = 0; g_ev_b < 41; g_ev_b = g_ev_b + 1) begin : g_ok_leaf
		(* keep = "true", dont_touch = "true" *) LUT6 #(.INIT(64'h8000000000000000)) u_okl (
			.I0(ex_eq3_rep[g_ev_b / 9][0]),
			.I1(ex_eq3_rep[g_ev_b / 9][1]),
			.I2(ex_eq3_rep[g_ev_b / 9][2]),
			.I3(ex_eq3_rep[g_ev_b / 9][3]),
			.I4(ex_eq3_rep[g_ev_b / 9][4]),
			.I5(ex_eq3_rep[g_ev_b / 9][5]),
			.O(ex_ok_buf[g_ev_b])
		);
	end
	for (g_ev_m = 0; g_ev_m < 8; g_ev_m = g_ev_m + 1) begin : g_ev_mid
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mid (
			.I0(ex_valid), .O(ex_v_mid[g_ev_m])
		);
	end
	for (g_ev_b = 0; g_ev_b < 128; g_ev_b = g_ev_b + 1) begin : g_ev_leaf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_leaf (
			.I0(ex_v_mid[g_ev_b / 16]), .O(ex_v_buf[g_ev_b])
		);
	end
	for (g_qc = 0; g_qc < 64; g_qc = g_qc + 1) begin : g_qcol
		assign q_color[8 * g_qc +: 8] = ex_v_buf[g_qc] ? ex_color[8 * g_qc +: 8] : 8'd0;
		assign q_color1[8 * g_qc +: 8] = ex_v_buf[64 + g_qc] ? ex_color1[8 * g_qc +: 8] : 8'd0;
	end
	for (g_qc = 0; g_qc < 4; g_qc = g_qc + 1) begin : g_qxy
		assign q_xy[8 * g_qc +: 8] = ex_ok_buf[g_qc] ? ex_xy[8 * g_qc +: 8] : dx_xy[8 * g_qc +: 8];
	end
	for (g_qc = 0; g_qc < 16; g_qc = g_qc + 1) begin : g_qdep
		assign q_depth[8 * g_qc +: 8] = ex_ok_buf[4 + g_qc] ? ex_depth[8 * g_qc +: 8] : dx_depth[8 * g_qc +: 8];
	end
	endgenerate
	assign q_mask = ex_ok_buf[20] ? ex_mask : dx_mask;
	assign q_dbg = !ex_ok_buf[20];
	wire [154:0] dx_aux_val = {3'd0, 1'b1, 1'b1, 1'b0, 1'b1, 128'd0, 4'hF, {4{dx_mask[3]}},
		{4{dx_mask[2]}}, {4{dx_mask[1]}}, {4{dx_mask[0]}}};
	generate
	for (g_qc = 0; g_qc < 19; g_qc = g_qc + 1) begin : g_qaux
		assign q_aux[8 * g_qc +: 8] = ex_ok_buf[21 + g_qc] ? ex_aux[8 * g_qc +: 8] : dx_aux_val[8 * g_qc +: 8];
	end
	endgenerate
	assign q_aux[154:152] = ex_ok_buf[40] ? ex_aux[154:152] : dx_aux_val[154:152];
`else
	assign ex_ready = ex_ok && q_ready;
	assign dx_ready = dx_ok && q_ready;
	assign q_xy = ex_ok ? ex_xy : dx_xy;
	assign q_mask = ex_ok ? ex_mask : dx_mask;
	assign q_color = ex_valid ? ex_color : 512'd0;
	assign q_color1 = ex_valid ? ex_color1 : 512'd0;
	assign q_depth = ex_ok ? ex_depth : dx_depth;
	assign q_dbg = !ex_ok;
	/* the SU's beat (ex_aux); the direct path: one beat of attachment 0,
	 * front, every sample of a covered lane, with the lane's depth (zexp) */
	assign q_aux = ex_ok ? ex_aux : {3'd0, 1'b1, 1'b1, 1'b0, 1'b1, 128'd0, 4'hF, {4{dx_mask[3]}},
		{4{dx_mask[2]}}, {4{dx_mask[1]}}, {4{dx_mask[0]}}};
`endif

	wire [15:0] seq1, next1;	/* ord_seq + 1, next + 1 */
	wire s1_co_unused, n1_co_unused;
	am_add #(.W(16)) u_seq1 (.a(ord_seq), .b(16'd0), .ci(1'b1), .s(seq1), .co(s1_co_unused));
	am_add #(.W(16)) u_next1 (.a(next), .b(16'd0), .ci(1'b1), .s(next1), .co(n1_co_unused));

	always @(posedge clk)
		if (rst_sync) begin
			next <= 16'd0;
			issued <= 16'd0;
		end else begin
			if (ord_valid)
				issued <= seq1;
			if ((ex_ready && ex_last) || (dx_ready && dx_last))
				next <= next1;
		end
endmodule

`default_nettype wire
