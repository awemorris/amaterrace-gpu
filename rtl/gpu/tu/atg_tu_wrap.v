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

module atg_tu_wrap (
	input wire signed [23:0] i,
	input wire [15:0] n,
	input wire [1:0] mode,
	output wire [16:0] w
);
	wire lt = i < 0;
	wire ge_n = i >= $signed({8'd0, n});
	wire [16:0] p = mode[0] ? {n, 1'b0} : {1'b0, n};
	wire ge_p = i >= $signed({7'd0, p});

	/* Parallel arithmetic operations directly on inputs i and n (no cascading) */
	wire [16:0] mb;
	wire [15:0] mir, n1;
	wire [23:0] in_sum;
	wire [3:0] carry_unused;

	/* lt_n: i + n < 0 */
	am_add #(.W(24)) u_lt_n (.a(i), .b({{8{1'b0}}, n}), .ci(1'b0), .s(in_sum), .co(carry_unused[3]));
	wire lt_n = in_sum[23];

	/* u_mb: i + p (when lt) or i - p */
	am_addsub #(.W(17)) u_mb (.a(i[16:0]), .b(p), .sub(!lt), .s(mb), .co(carry_unused[0]));

	/* u_mir: 2n - 1 - i directly in parallel */
	am_sub #(.W(16)) u_mir (.a({n[14:0], 1'b0}), .b(i[15:0]), .bi(1'b1), .d(mir), .bo(carry_unused[1]));

	/* u_n1: n - 1 */
	am_sub #(.W(16)) u_n1 (.a(n), .b(16'd0), .bi(1'b1), .d(n1), .bo(carry_unused[2]));

	/* Constant lookup table for small sizes p < 16: direct wrap result */
	reg [3:0] lut_wrap [0:2047];
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

	wire [3:0] m_small = lut_wrap[{mode[0], p[3:0], i[5:0]}];

	wire [15:0] rep_res = p >= 17'd16 ? ((lt || ge_p) ? mb[15:0] : i[15:0]) : {12'd0, m_small};
	wire [15:0] mir_res = p >= 17'd16 ? ((lt_n || ge_p) ? mb[15:0] : lt ? ~i[15:0] : ge_n ? mir : i[15:0]) :
		{12'd0, m_small};

	assign w = mode == 2'd0 ? {1'b0, rep_res} :
	           mode == 2'd1 ? {1'b0, mir_res} :
	           {mode[0] && (lt || ge_n), lt ? 16'd0 : ge_n ? n1 : i[15:0]};
endmodule

`default_nettype wire
