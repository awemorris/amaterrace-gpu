/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fp_div: fp32 divider a / b, 1 quotient bit per cycle.
 * RNE, denormals flushed, canonical NaN 0x7FC00000.
 * Two-stage pipelined post-normalization/rounding for >= 200 MHz.
 * See spec/library/fp/am_fp_div.md.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module am_fp_div (
	input wire clk,
	input wire rst_n,
	input wire i_start,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	output wire busy,
	output reg o_done,
	output reg [31:0] o_r
);
	wire rst_sync = !rst_n;

	wire [7:0] ea = i_a[30:23];
	wire [7:0] eb = i_b[30:23];
	wire ea_ff_lo = &ea[5:0];
	wire ea_z_lo  = (ea[5:0] == 6'd0);
	wire eb_ff_lo = &eb[5:0];
	wire eb_z_lo  = (eb[5:0] == 6'd0);
	wire za = (ea[7:6] == 2'b00) && ea_z_lo;
	wire zb = (eb[7:6] == 2'b00) && eb_z_lo;
	wire ea_ff = (ea[7:6] == 2'b11) && ea_ff_lo;
	wire eb_ff = (eb[7:6] == 2'b11) && eb_ff_lo;
	wire sp_a = za || ea_ff;
	wire sp_b = zb || eb_ff;

	wire ma_nz_0 = (i_a[5:0]   != 6'd0);
	wire ma_nz_1 = (i_a[11:6]  != 6'd0);
	wire ma_nz_2 = (i_a[17:12] != 6'd0);
	wire ma_nz_3 = (i_a[22:18] != 5'd0);
	(* keep = "true" *) wire ma_nz = ma_nz_0 || ma_nz_1 || ma_nz_2 || ma_nz_3;

	wire mb_nz_0 = (i_b[5:0]   != 6'd0);
	wire mb_nz_1 = (i_b[11:6]  != 6'd0);
	wire mb_nz_2 = (i_b[17:12] != 6'd0);
	wire mb_nz_3 = (i_b[22:18] != 5'd0);
	(* keep = "true" *) wire mb_nz = mb_nz_0 || mb_nz_1 || mb_nz_2 || mb_nz_3;

	wire s = i_a[31] ^ i_b[31];
	wire [23:0] ma = {1'b1, i_a[22:0]};
	wire [23:0] mb = {1'b1, i_b[22:0]};

	(* keep = "true" *) reg prep_ctrl_a, prep_ctrl_b, prep_ctrl_c;
	(* keep = "true" *) reg run_ctrl_a, run_ctrl_b, run_ctrl_c, run_q0, run_q1, run_r0, run_r1;
	reg r_last;
	(* keep = "true" *) reg round_s1_ctrl, round_s1_a, round_s1_b, round_s1_c;
	(* keep = "true" *) reg round_s2_ctrl, round_s2_a, round_s2_b;
	reg sgn;
	reg r_sp_any, r_sp_nan, r_sp_exp_ff;
	(* keep = "true" *) reg r_ma_lt_mb_a, r_ma_lt_mb_b;
	(* extract_reset = "no" *) reg [9:0] r_eab;
	(* extract_reset = "no" *) reg [23:0] r_ma;
	(* keep = "true" *) reg r_round_up_a, r_round_up_b;
	(* extract_reset = "no" *) reg [24:0] r_m0_inc;
	(* extract_reset = "no" *) reg [7:0] r_ef_0, r_ef_1;
	(* keep = "true" *) reg r_mz_0_a, r_mz_0_b;
	(* keep = "true" *) reg r_mz_1_a, r_mz_1_b;
	reg [4:0] cnt;
	reg [9:0] e;
	(* extract_reset = "no" *) reg [23:0] d_lo, d_hi;
	(* extract_reset = "no" *) reg [25:0] rem;
	(* extract_reset = "no" *) reg [24:0] q_reg;

	assign busy = prep_ctrl_a || run_ctrl_a || round_s1_ctrl || round_s2_ctrl;

	/* 26-bit remainder subtractors */
	wire [25:0] rem_d_lo, rem_d_hi;
	wire rd_bo_lo, rd_bo_hi;
	am_sub #(.W(26)) u_rem_d_lo (.a(rem), .b({2'b00, d_lo}), .bi(1'b0), .d(rem_d_lo), .bo(rd_bo_lo));
	am_sub #(.W(26)) u_rem_d_hi (.a(rem), .b({2'b00, d_hi}), .bi(1'b0), .d(rem_d_hi), .bo(rd_bo_hi));

	wire [24:0] rem_next_shift;
	assign rem_next_shift[12:0]  = rd_bo_lo ? rem[12:0]  : rem_d_lo[12:0];
	assign rem_next_shift[24:13] = rd_bo_hi ? rem[24:13] : rem_d_hi[24:13];

	/* ma < mb via am_sub borrow-out */
	wire [22:0] ma_mb_unused;
	wire ma_lt_mb_raw;
	am_sub #(.W(23)) u_ma_lt_mb (.a(i_a[22:0]), .b(i_b[22:0]), .bi(1'b0), .d(ma_mb_unused), .bo(ma_lt_mb_raw));

	/* Exponent difference */
	wire [9:0] eab, e_n;
	wire [4:0] cnt_m1;
	wire eab_bo_unused, en_co_unused, cm_bo_unused;
	am_sub #(.W(10)) u_eab (.a({2'b00, ea}), .b({2'b00, eb}), .bi(1'b0), .d(eab), .bo(eab_bo_unused));
	am_add #(.W(10)) u_e_n (.a(r_eab), .b(10'd126), .ci(!r_ma_lt_mb_a), .s(e_n), .co(en_co_unused));
	am_sub #(.W(5)) u_cnt (.a(cnt), .b(5'd0), .bi(1'b1), .d(cnt_m1), .bo(cm_bo_unused));

	wire [24:0] q_n = {q_reg[23:0], !rd_bo_hi};

	(* keep = "true" *) wire [12:0] rem_init_lo = r_ma_lt_mb_a ? {r_ma[11:0], 1'b0} : r_ma[12:0];
	(* keep = "true" *) wire [24:13] rem_init_hi = r_ma_lt_mb_b ? r_ma[23:12] : {1'b0, r_ma[23:13]};

	/* round_s1 stage */
	wire [24:0] m0_inc_w;
	wire [9:0] e_p1_w;
	wire m0_co_unused, ep1_co_unused;
	am_add #(.W(25)) u_m0 (.a({1'b0, q_reg[24:1]}), .b(25'd1), .ci(1'b0), .s(m0_inc_w), .co(m0_co_unused));
	am_add #(.W(10)) u_ef (.a(e), .b(10'd1), .ci(1'b0), .s(e_p1_w), .co(ep1_co_unused));

	wire round_up_w = q_reg[0] && (q_reg[1] || (rem[25:1] != 25'd0));
	(* keep = "true" *) wire ovf_0_w = !e[9] && (e[8] || (&e[7:0]));
	(* keep = "true" *) wire udf_0_w = e[9] || (e[8:0] == 9'd0);
	(* keep = "true" *) wire ovf_1_w = !e[9] && (e[8] || (&e[7:1]));
	(* keep = "true" *) wire udf_1_w = e[9] && (e != 10'h3FF);

	wire [7:0] ef_0_w = ovf_0_w ? 8'hFF : (udf_0_w ? 8'h00 : e[7:0]);
	wire [7:0] ef_1_w = ovf_1_w ? 8'hFF : (udf_1_w ? 8'h00 : e_p1_w[7:0]);
	wire mz_0_w = ovf_0_w || udf_0_w;
	wire mz_1_w = ovf_1_w || udf_1_w;

	wire unused_m = &{1'b0, rem_d_lo[25:13], rem_d_hi[12:0], e_p1_w[9:8],
		ma_mb_unused, eab_bo_unused, en_co_unused, cm_bo_unused, m0_co_unused, ep1_co_unused};

	(* keep = "true" *) wire sp_nan = (ea_ff && (ma_nz || eb_ff)) || (eb_ff && mb_nz) || (za && zb);
	(* keep = "true" *) wire sp_exp_ff = ea_ff || zb || (eb_ff && mb_nz);
	wire sp_any = sp_a || sp_b;
	(* keep = "true" *) wire start_ok_a = i_start && !prep_ctrl_a && !run_ctrl_a && !round_s1_ctrl && !round_s2_ctrl;
	(* keep = "true" *) wire start_ok_b = i_start && !prep_ctrl_b && !run_ctrl_b && !round_s1_ctrl && !round_s2_ctrl;

	wire start_d0 = start_ok_a;
	wire start_d1 = start_ok_a;
	wire start_d2 = start_ok_b;
	wire start_d3 = start_ok_b;
	wire start_m0 = start_ok_a;
	wire start_m1 = start_ok_b;
	wire start_eab = start_ok_b;

	(* keep = "true" *) wire prep_sp_a = prep_ctrl_a && r_sp_any;
	(* keep = "true" *) wire prep_sp_b = prep_ctrl_b && r_sp_any;

	(* keep = "true" *) wire ce_q0 = run_q0 || prep_ctrl_a;
	(* keep = "true" *) wire ce_q1 = run_q1 || prep_ctrl_b;
	(* keep = "true" *) wire ce_r0 = run_r0 || prep_ctrl_a;
	(* keep = "true" *) wire ce_r1 = run_r1 || prep_ctrl_b;

	wire [31:0] sp_or_val = {!r_sp_nan && sgn, {8{r_sp_exp_ff}}, r_sp_nan, 22'd0};

	/* round_s2 stage */
	(* keep = "true" *) wire use_e1 = r_round_up_b && r_m0_inc[24];
	wire [7:0] s2_e = use_e1 ? r_ef_1 : r_ef_0;
	(* keep = "true" *) wire mz_s2_a = (r_round_up_a && r_m0_inc[24]) ? r_mz_1_a : r_mz_0_a;
	(* keep = "true" *) wire mz_s2_b = use_e1 ? r_mz_1_b : r_mz_0_b;
	wire [22:0] s2_m;
	assign s2_m[15:0]  = mz_s2_a ? 16'd0 : (r_round_up_a ? r_m0_inc[15:0]  : q_reg[16:1]);
	assign s2_m[22:16] = mz_s2_b ? 7'd0  : (r_round_up_b ? r_m0_inc[22:16] : q_reg[23:17]);
	wire [31:0] s2_or_val = {sgn, s2_e, s2_m};

	always @(posedge clk) begin
		if (rst_sync) begin
			o_done <= 1'b0;
			prep_ctrl_a <= 1'b0;
			prep_ctrl_b <= 1'b0;
			prep_ctrl_c <= 1'b0;
			run_ctrl_a <= 1'b0;
			run_ctrl_b <= 1'b0;
			run_ctrl_c <= 1'b0;
			run_q0 <= 1'b0;
			run_q1 <= 1'b0;
			run_r0 <= 1'b0;
			run_r1 <= 1'b0;
			r_last <= 1'b0;
			round_s1_ctrl <= 1'b0;
			round_s1_a <= 1'b0;
			round_s1_b <= 1'b0;
			round_s1_c <= 1'b0;
			round_s2_ctrl <= 1'b0;
			round_s2_a <= 1'b0;
			round_s2_b <= 1'b0;
		end else begin
			o_done <= (prep_ctrl_b && r_sp_any) || round_s2_ctrl;

			if (start_ok_a) begin
				prep_ctrl_a <= 1'b1;
				prep_ctrl_b <= 1'b1;
				prep_ctrl_c <= 1'b1;
			end else if (prep_ctrl_a) begin
				prep_ctrl_a <= 1'b0;
				prep_ctrl_b <= 1'b0;
				prep_ctrl_c <= 1'b0;
			end

			if (prep_ctrl_a && !r_sp_any) begin
				run_ctrl_a <= 1'b1;
				run_ctrl_b <= 1'b1;
				run_ctrl_c <= 1'b1;
				run_q0 <= 1'b1;
				run_q1 <= 1'b1;
				run_r0 <= 1'b1;
				run_r1 <= 1'b1;
			end else if (run_ctrl_c && r_last) begin
				run_ctrl_a <= 1'b0;
				run_ctrl_b <= 1'b0;
				run_ctrl_c <= 1'b0;
				run_q0 <= 1'b0;
				run_q1 <= 1'b0;
				run_r0 <= 1'b0;
				run_r1 <= 1'b0;
			end

			if (prep_ctrl_b)
				r_last <= 1'b0;
			else if (run_ctrl_c)
				r_last <= (cnt == 5'd1);

			if (run_ctrl_c && r_last) begin
				round_s1_ctrl <= 1'b1;
				round_s1_a <= 1'b1;
				round_s1_b <= 1'b1;
				round_s1_c <= 1'b1;
			end else if (round_s1_ctrl) begin
				round_s1_ctrl <= 1'b0;
				round_s1_a <= 1'b0;
				round_s1_b <= 1'b0;
				round_s1_c <= 1'b0;
			end

			if (round_s1_ctrl) begin
				round_s2_ctrl <= 1'b1;
				round_s2_a <= 1'b1;
				round_s2_b <= 1'b1;
			end else if (round_s2_ctrl) begin
				round_s2_ctrl <= 1'b0;
				round_s2_a <= 1'b0;
				round_s2_b <= 1'b0;
			end
		end

		if (start_ok_a) begin
			sgn <= s;
			r_sp_any <= sp_any;
			r_sp_nan <= sp_nan;
			r_sp_exp_ff <= sp_exp_ff;
			r_ma_lt_mb_a <= ma_lt_mb_raw;
			r_ma_lt_mb_b <= ma_lt_mb_raw;
		end

		if (round_s1_ctrl) begin
			r_round_up_a <= round_up_w;
			r_round_up_b <= round_up_w;
			r_mz_0_a <= mz_0_w;
			r_mz_0_b <= mz_0_w;
			r_mz_1_a <= mz_1_w;
			r_mz_1_b <= mz_1_w;
		end

		if (start_eab)
			r_eab <= eab;
		if (prep_ctrl_c) begin
			e <= e_n;
			cnt <= 5'd24;
		end else if (run_ctrl_c) begin
			cnt <= cnt_m1;
		end

		if (start_m0)
			r_ma[11:0] <= ma[11:0];
		if (start_m1)
			r_ma[23:12] <= ma[23:12];

		if (start_d0)
			d_lo[11:0] <= mb[11:0];
		if (start_d1)
			d_lo[23:12] <= mb[23:12];
		if (start_d2)
			d_hi[11:0] <= mb[11:0];
		if (start_d3)
			d_hi[23:12] <= mb[23:12];

		if (ce_q0)
			q_reg[12:0] <= !run_q0 ? 13'd0 : q_n[12:0];
		if (ce_q1)
			q_reg[24:13] <= !run_q1 ? 12'd0 : q_n[24:13];

		if (ce_r0)
			rem[12:0] <= !run_r0 ? rem_init_lo : {rem_next_shift[11:0], 1'b0};
		if (ce_r1)
			rem[25:13] <= !run_r1 ? {1'b0, rem_init_hi} : rem_next_shift[24:12];

		if (round_s1_a)
			r_m0_inc[15:0] <= m0_inc_w[15:0];
		if (round_s1_b)
			r_m0_inc[24:16] <= m0_inc_w[24:16];
		if (round_s1_c) begin
			r_ef_0 <= ef_0_w;
			r_ef_1 <= ef_1_w;
		end

		if (prep_sp_a)
			o_r[15:0] <= sp_or_val[15:0];
		else if (round_s2_a)
			o_r[15:0] <= s2_or_val[15:0];

		if (prep_sp_b)
			o_r[31:16] <= sp_or_val[31:16];
		else if (round_s2_b)
			o_r[31:16] <= s2_or_val[31:16];
	end
endmodule

`default_nettype wire
