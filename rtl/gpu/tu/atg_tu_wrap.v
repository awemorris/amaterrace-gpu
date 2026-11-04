/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_wrap: an integer texel coordinate into the level: {border texel,
 * index} by the address mode (0 repeat, 1 mirrored repeat, 2 clamp to
 * edge, 3 clamp to border).  The former functions tu_wrap and tu_mod of
 * include/atg_tu_fn.vh (tools/tumodel.py wrap_idx); i mod p for i in
 * [−9, p + 7]: one correction for p >= 16, a 5-bit remainder (a table of
 * constants) for p < 16.  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_wrap #(
	parameter LAT = 0
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire signed [23:0] i,
	input wire [15:0] n,
	input wire [1:0] mode,
	output wire [16:0] w
);
	wire lt = i < 0;
	wire mode0_lo = mode[0];
	wire mode0_hi = mode[0];
	wire [16:0] p = {mode0_hi ? n[15:8] : {1'b0, n[15:9]}, mode0_lo ? {n[7:0], 1'b0} : n[8:0]};

	/* Parallel arithmetic operations directly on inputs i and n (no cascading) */
	wire [16:0] mb;
	wire [15:0] mir, n1;
	wire [23:0] in_sum, gen_d, gep_d;
	wire [5:0] carry_unused;

	/* lt_n: i + n < 0 */
	am_add #(.W(24)) u_lt_n (.a(i), .b({{8{1'b0}}, n}), .ci(1'b0), .s(in_sum), .co(carry_unused[3]));
	wire lt_n_s0 = in_sum[23];

	/* ge_n: i >= n */
	am_sub #(.W(24)) u_ge_n (.a(i), .b({8'd0, n}), .bi(1'b0), .d(gen_d), .bo(carry_unused[4]));
	wire ge_n_s0 = !gen_d[23];

	/* ge_p: i >= p */
	am_sub #(.W(24)) u_ge_p (.a(i), .b({7'd0, p}), .bi(1'b0), .d(gep_d), .bo(carry_unused[5]));
	wire ge_p_s0 = !gep_d[23];

	/* u_mb: i + p (when lt) or i - p */
	am_addsub #(.W(17)) u_mb (.a(i[16:0]), .b(p), .sub(!lt), .s(mb), .co(carry_unused[0]));

	/* u_mir: 2n - 1 - i directly in parallel */
	am_sub #(.W(16)) u_mir (.a({n[14:0], 1'b0}), .b(i[15:0]), .bi(1'b1), .d(mir), .bo(carry_unused[1]));

	/* u_n1: n - 1 */
	am_sub #(.W(16)) u_n1 (.a(n), .b(16'd0), .bi(1'b1), .d(n1), .bo(carry_unused[2]));

	/* Constant lookup table for small sizes p < 16: direct wrap result */
	(* rom_style = "distributed" *) reg [3:0] lut_wrap [0:2047];
	integer init_m, init_p, init_u, s_val, m_val, w_val, n_val;
	initial begin
		for (init_m = 0; init_m < 2; init_m = init_m + 1) begin
			for (init_p = 0; init_p < 16; init_p = init_p + 1) begin
				for (init_u = 0; init_u < 64; init_u = init_u + 1) begin
					s_val = (init_u < 32) ? init_u : (init_u - 64);
					m_val = (init_p > 0) ? (s_val % init_p) : 0;
					if (m_val < 0)
						m_val = m_val + init_p;
					if (init_m == 0) begin
						w_val = m_val;
					end else begin
						n_val = init_p >> 1;
						w_val = (m_val < n_val) ? m_val : (init_p - 1 - m_val);
					end
					lut_wrap[{init_m[0], init_p[3:0], init_u[5:0]}] = w_val[3:0];
				end
			end
		end
	end

	wire [10:0] lut_a0 = {mode[0], p[3:0], i[5:0]};
	wire [10:0] lut_a1 = {mode[0], p[3:0], i[5:0]};
	wire [10:0] lut_a2 = {mode[0], p[3:0], i[5:0]};
	wire [10:0] lut_a3 = {mode[0], p[3:0], i[5:0]};
	wire [3:0] m_small_s0 = {lut_wrap[lut_a3][3], lut_wrap[lut_a2][2], lut_wrap[lut_a1][1], lut_wrap[lut_a0][0]};
	wire p_ge16_s0 = (p[16:4] != 13'd0);

	/* Stage 0 -> Stage 1 Pipeline Registers (when LAT >= 1) */
	(* extract_reset = "no" *) reg        r_lt_lo, r_lt_hi, r_lt_n_lo, r_lt_n_hi, r_ge_n_lo, r_ge_n_hi, r_ge_p_lo, r_ge_p_hi, r_p_ge16_lo, r_p_ge16_hi;
	(* extract_reset = "no" *) reg [15:0] r_mb, r_mir, r_n1, r_i;
	(* extract_reset = "no", rom_style = "distributed" *) reg [3:0]  r_m_small;
	(* extract_reset = "no" *) reg [1:0]  r_mode_lo, r_mode_hi;
	always @(posedge clk) begin
		if (en) begin
			r_lt_lo     <= lt;       r_lt_hi     <= lt;
			r_lt_n_lo   <= lt_n_s0;  r_lt_n_hi   <= lt_n_s0;
			r_ge_n_lo   <= ge_n_s0;  r_ge_n_hi   <= ge_n_s0;
			r_ge_p_lo   <= ge_p_s0;  r_ge_p_hi   <= ge_p_s0;
			r_p_ge16_lo <= p_ge16_s0; r_p_ge16_hi <= p_ge16_s0;
			r_mb        <= mb[15:0];
			r_mir       <= mir;
			r_n1        <= n1;
			r_i         <= i[15:0];
			r_m_small   <= m_small_s0;
			r_mode_lo   <= mode;     r_mode_hi   <= mode;
		end
	end

	wire        s_lt_lo     = (LAT >= 1) ? r_lt_lo     : lt;
	wire        s_lt_hi     = (LAT >= 1) ? r_lt_hi     : lt;
	wire        s_lt_n_lo   = (LAT >= 1) ? r_lt_n_lo   : lt_n_s0;
	wire        s_lt_n_hi   = (LAT >= 1) ? r_lt_n_hi   : lt_n_s0;
	wire        s_ge_n_lo   = (LAT >= 1) ? r_ge_n_lo   : ge_n_s0;
	wire        s_ge_n_hi   = (LAT >= 1) ? r_ge_n_hi   : ge_n_s0;
	wire        s_ge_p_lo   = (LAT >= 1) ? r_ge_p_lo   : ge_p_s0;
	wire        s_ge_p_hi   = (LAT >= 1) ? r_ge_p_hi   : ge_p_s0;
	wire        s_p_ge16_lo = (LAT >= 1) ? r_p_ge16_lo : p_ge16_s0;
	wire        s_p_ge16_hi = (LAT >= 1) ? r_p_ge16_hi : p_ge16_s0;
	wire [15:0] s_mb        = (LAT >= 1) ? r_mb        : mb[15:0];
	wire [15:0] s_mir       = (LAT >= 1) ? r_mir       : mir;
	wire [15:0] s_n1        = (LAT >= 1) ? r_n1        : n1;
	wire [15:0] s_i         = (LAT >= 1) ? r_i         : i[15:0];
	wire [3:0]  s_m_small   = (LAT >= 1) ? r_m_small   : m_small_s0;
	wire [1:0]  s_mode_lo   = (LAT >= 1) ? r_mode_lo   : mode;
	wire [1:0]  s_mode_hi   = (LAT >= 1) ? r_mode_hi   : mode;

	wire [15:0] rep_res = {
		s_p_ge16_hi ? ((s_lt_hi || s_ge_p_hi) ? s_mb[15:8] : s_i[15:8]) : 8'd0,
		s_p_ge16_lo ? ((s_lt_lo || s_ge_p_lo) ? s_mb[7:0]  : s_i[7:0])  : {4'd0, s_m_small}
	};
	wire [15:0] mir_res = {
		s_p_ge16_hi ? ((s_lt_n_hi || s_ge_p_hi) ? s_mb[15:8] : s_lt_hi ? ~s_i[15:8] : s_ge_n_hi ? s_mir[15:8] : s_i[15:8]) : 8'd0,
		s_p_ge16_lo ? ((s_lt_n_lo || s_ge_p_lo) ? s_mb[7:0]  : s_lt_lo ? ~s_i[7:0]  : s_ge_n_lo ? s_mir[7:0]  : s_i[7:0])  : {4'd0, s_m_small}
	};

	wire [16:0] w_out;
	assign w_out[7:0]  = s_mode_lo == 2'd0 ? rep_res[7:0]  : s_mode_lo == 2'd1 ? mir_res[7:0]  : (s_lt_lo ? 8'd0 : s_ge_n_lo ? s_n1[7:0]  : s_i[7:0]);
	assign w_out[15:8] = s_mode_hi == 2'd0 ? rep_res[15:8] : s_mode_hi == 2'd1 ? mir_res[15:8] : (s_lt_hi ? 8'd0 : s_ge_n_hi ? s_n1[15:8] : s_i[15:8]);
	assign w_out[16]   = (s_mode_hi == 2'd0 || s_mode_hi == 2'd1) ? 1'b0 : (s_mode_hi[0] && (s_lt_hi || s_ge_n_hi));
	assign w = w_out;

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, en} : 1'b0;
	wire unused_ok = &{1'b0, rst_n, unused_lat0, mb[16], gen_d[22:0], gep_d[22:0], in_sum[22:0]};
endmodule

`default_nettype wire
