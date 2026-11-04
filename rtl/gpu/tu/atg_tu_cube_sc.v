/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_cube_sc: one of atg_tu_cube's face coordinates before the
 * division (the former function scaled): floor(v 2^(150 - em)) with the
 * sign flipped by neg, clamped to [-3 mm, 3 mm], plus 3 mm: [0, 6 mm]
 * (m3 = 3 mm, computed by the caller once for both coordinates).
 * Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_cube_sc (
	input wire clk,
	input wire rst_n,
	input wire [31:0] v,
	input wire neg,
	input wire [7:0] em,
	input wire [26:0] m3,
	output wire [26:0] o
);
	wire rst_inv = !rst_n;

	/* Stage 1 (P0 -> P1): sh = e - em, k = em - e */
	wire [8:0] sh_w, k_w;
	wire [3:0] carry_unused;
	am_sub #(.W(9)) u_sh (.a({1'b0, v[30:23]}), .b({1'b0, em}), .bi(1'b0), .d(sh_w), .bo(carry_unused[0]));
	am_sub #(.W(9)) u_k (.a({1'b0, em}), .b({1'b0, v[30:23]}), .bi(1'b0), .d(k_w), .bo(carry_unused[1]));

	reg [31:0] v_p1;
	reg neg_p1;
	reg [8:0] sh_p1, k_p1_st0, k_p1_st1;
	(* max_fanout = 12 *) reg [8:0] k_p1_sh_lo, k_p1_sh_hi;
	reg v_zero_p1, sh_gt2_p1, k_lt24_p1;
	reg [26:0] m3_p1;

	always @(posedge clk) begin
		if (rst_inv) begin
			v_p1 <= 32'd0;
			neg_p1 <= 1'b0;
			sh_p1 <= 9'd0;
			k_p1_sh_lo <= 9'd0;
			k_p1_sh_hi <= 9'd0;
			k_p1_st0 <= 9'd0;
			k_p1_st1 <= 9'd0;
			v_zero_p1 <= 1'b0;
			sh_gt2_p1 <= 1'b0;
			k_lt24_p1 <= 1'b0;
			m3_p1 <= 27'd0;
		end else begin
			v_p1 <= v;
			neg_p1 <= neg;
			sh_p1 <= sh_w;
			k_p1_sh_lo <= k_w;
			k_p1_sh_hi <= k_w;
			k_p1_st0 <= k_w;
			k_p1_st1 <= k_w;
			v_zero_p1 <= v[30:23] == 8'd0;
			sh_gt2_p1 <= !sh_w[8] && sh_w > 9'd2;
			k_lt24_p1 <= k_w < 9'd24;
			m3_p1 <= m3;
		end
	end

	/* Stage 2 (P1 -> P2): barrel shift and sticky bit */
	wire [26:0] qs_r_lo, qs_r_hi;
	am_shift #(.W(27), .SW(5)) u_qs_lo (
		.a({3'd0, 1'b1, v_p1[22:0]}),
		.amt(k_p1_sh_lo[4:0]),
		.left(1'b0), .arith(1'b0), .y(qs_r_lo)
	);
	am_shift #(.W(27), .SW(5)) u_qs_hi (
		.a({3'd0, 1'b1, v_p1[22:0]}),
		.amt(k_p1_sh_hi[4:0]),
		.left(1'b0), .arith(1'b0), .y(qs_r_hi)
	);
	wire [26:0] qs_r = {qs_r_hi[26:14], qs_r_lo[13:0]};
	wire [1:0] sh_lo = sh_p1[1:0];
	wire [1:0] sh_hi = sh_p1[1:0];
	wire [26:0] qs_l_0 = {3'd0, 1'b1, v_p1[22:0]};
	wire [26:0] qs_l_1 = {2'd0, 1'b1, v_p1[22:0], 1'b0};
	wire [26:0] qs_l_2 = {1'd0, 1'b1, v_p1[22:0], 2'b00};
	wire [26:0] qs_l = {
		(sh_hi == 2'd0) ? qs_l_0[26:14] : (sh_hi == 2'd1) ? qs_l_1[26:14] : qs_l_2[26:14],
		(sh_lo == 2'd0) ? qs_l_0[13:0]  : (sh_lo == 2'd1) ? qs_l_1[13:0]  : qs_l_2[13:0]
	};

	wire [3:0] vz_s   = {4{v_zero_p1}};
	wire [3:0] sgt2_s = {4{sh_gt2_p1}};
	wire [3:0] sh8_s  = {4{sh_p1[8]}};
	wire [3:0] k24_s  = {4{k_lt24_p1}};

	wire [26:0] q_w = {
		vz_s[3] ? 6'd0 : sgt2_s[3] ? m3_p1[26:21] : !sh8_s[3] ? qs_l[26:21] : k24_s[3] ? qs_r[26:21] : 6'd0,
		vz_s[2] ? 7'd0 : sgt2_s[2] ? m3_p1[20:14] : !sh8_s[2] ? qs_l[20:14] : k24_s[2] ? qs_r[20:14] : 7'd0,
		vz_s[1] ? 7'd0 : sgt2_s[1] ? m3_p1[13:7]  : !sh8_s[1] ? qs_l[13:7]  : k24_s[1] ? qs_r[13:7]  : 7'd0,
		vz_s[0] ? 7'd0 : sgt2_s[0] ? m3_p1[6:0]   : !sh8_s[0] ? qs_l[6:0]   : k24_s[0] ? qs_r[6:0]   : 7'd0
	};
	reg sticky_w;
	integer b;
	always @(*) begin
		sticky_w = 1'b0;
		if (!v_zero_p1 && !sh_gt2_p1 && sh_p1[8]) begin
			if (k_lt24_p1) begin
				for (b = 0; b < 12; b = b + 1)
					if (b < k_p1_st0)
						sticky_w = sticky_w | v_p1[b];
				for (b = 12; b < 24; b = b + 1)
					if (b < k_p1_st1)
						sticky_w = sticky_w | (b == 23 ? 1'b1 : v_p1[b]);
			end else
				sticky_w = 1'b1;
		end
	end

	reg [26:0] q_p2, m3_p2;
	reg sticky_p2, ng_p2, v_zero_p2;

	always @(posedge clk) begin
		if (rst_inv) begin
			q_p2 <= 27'd0;
			m3_p2 <= 27'd0;
			sticky_p2 <= 1'b0;
			ng_p2 <= 1'b0;
			v_zero_p2 <= 1'b0;
		end else begin
			q_p2 <= q_w;
			m3_p2 <= m3_p1;
			sticky_p2 <= sticky_w;
			ng_p2 <= v_p1[31] ^ neg_p1;
			v_zero_p2 <= v_zero_p1;
		end
	end

	/* Stage 3 (P2 -> P3): clamp q <= m3 */
	wire [26:0] qm_d_unused;
	wire qm_bo;
	am_sub #(.W(27)) u_qm (.a(m3_p2), .b(q_p2), .bi(1'b0), .d(qm_d_unused), .bo(qm_bo));
	wire gt_m3_lo = qm_bo;
	wire gt_m3_hi = qm_bo;
	wire [26:0] q_c = {
		gt_m3_hi ? m3_p2[26:14] : q_p2[26:14],
		gt_m3_lo ? m3_p2[13:0]  : q_p2[13:0]
	};

	reg [26:0] q_p3, m3_p3;
	reg sticky_p3, ng_p3_lo, ng_p3_hi, v_zero_p3;

	always @(posedge clk) begin
		if (rst_inv) begin
			q_p3 <= 27'd0;
			m3_p3 <= 27'd0;
			sticky_p3 <= 1'b0;
			ng_p3_lo <= 1'b0;
			ng_p3_hi <= 1'b0;
			v_zero_p3 <= 1'b0;
		end else begin
			q_p3 <= q_c;
			m3_p3 <= m3_p2;
			sticky_p3 <= sticky_p2;
			ng_p3_lo <= ng_p2;
			ng_p3_hi <= ng_p2;
			v_zero_p3 <= v_zero_p2;
		end
	end

	/* Stage 4 (P3 -> P4): qst = q + sticky, r = m3 +/- q */
	wire [26:0] qst_w, r_w;
	am_add #(.W(27)) u_qst (.a(q_p3), .b(27'd0), .ci(sticky_p3), .s(qst_w), .co(carry_unused[2]));
	am_add #(.W(27)) u_r (
		.a(m3_p3),
		.b({ng_p3_hi ? ~q_p3[26:14] : q_p3[26:14], ng_p3_lo ? ~q_p3[13:0] : q_p3[13:0]}),
		.ci(ng_p3_lo && !sticky_p3),
		.s(r_w),
		.co(carry_unused[3])
	);

	reg [26:0] qst_p4, r_p4, m3_p4;
	reg [3:0] ng_p4, v_zero_p4;

	always @(posedge clk) begin
		if (rst_inv) begin
			qst_p4 <= 27'd0;
			r_p4 <= 27'd0;
			m3_p4 <= 27'd0;
			ng_p4 <= 4'd0;
			v_zero_p4 <= 4'd0;
		end else begin
			qst_p4 <= qst_w;
			r_p4 <= r_w;
			m3_p4 <= m3_p3;
			ng_p4 <= {4{ng_p3_lo}};
			v_zero_p4 <= {4{v_zero_p3}};
		end
	end

	/* Stage 5 (P4): final mux */
	wire [26:0] qst_cmp_unused;
	wire qst_lt_m3;
	am_sub #(.W(27)) u_qst_cmp (.a(qst_p4), .b(m3_p4), .bi(1'b0), .d(qst_cmp_unused), .bo(qst_lt_m3));
	wire [3:0] qst_lt_m3_s = {4{qst_lt_m3}};
	wire [26:0] o_mux;
	assign o_mux[6:0]   = v_zero_p4[0] ? m3_p4[6:0]   : (ng_p4[0] && !qst_lt_m3_s[0]) ? 7'd0 : r_p4[6:0];
	assign o_mux[13:7]  = v_zero_p4[1] ? m3_p4[13:7]  : (ng_p4[1] && !qst_lt_m3_s[1]) ? 7'd0 : r_p4[13:7];
	assign o_mux[20:14] = v_zero_p4[2] ? m3_p4[20:14] : (ng_p4[2] && !qst_lt_m3_s[2]) ? 7'd0 : r_p4[20:14];
	assign o_mux[26:21] = v_zero_p4[3] ? m3_p4[26:21] : (ng_p4[3] && !qst_lt_m3_s[3]) ? 6'd0 : r_p4[26:21];
	assign o = o_mux;

	wire unused_ok = &{1'b0, carry_unused, sh_p1[7:2], k_p1_sh_lo[8:5], k_p1_sh_hi[8:5], qs_r_lo[26:14], qs_r_hi[13:0], qm_d_unused, qst_cmp_unused};
endmodule

`default_nettype wire
