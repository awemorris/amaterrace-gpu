/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_fdiv: the RX's fp32 divider a / b, one quotient bit per cycle
 * (27 cycles from i_start to o_done; 2 for the special cases), with the
 * rules of atg_rx_fadd (correctly rounded to nearest even, denormals
 * flushed, canonical NaN).  i_start is taken only while !busy.
 * See spec/gpu/rx/atg_rx_fdiv.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_fdiv (
	input wire clk,
	input wire rst_n,
	input wire i_start,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	output wire busy,
	output reg o_done,
	output reg [31:0] o_r
);
	wire [7:0] ea = i_a[30:23];
	wire [7:0] eb = i_b[30:23];
	wire za = ea == 8'd0;
	wire zb = eb == 8'd0;
	wire nan_a = ea == 8'hFF && i_a[22:0] != 23'd0;
	wire nan_b = eb == 8'hFF && i_b[22:0] != 23'd0;
	wire inf_a = ea == 8'hFF && i_a[22:0] == 23'd0;
	wire inf_b = eb == 8'hFF && i_b[22:0] == 23'd0;
	wire s = i_a[31] ^ i_b[31];
	wire [23:0] ma = {1'b1, i_a[22:0]};
	wire [23:0] mb = {1'b1, i_b[22:0]};

	reg run, sgn;
	reg [4:0] cnt;
	reg [9:0] e;
	reg [23:0] d;
	reg [25:0] rem;
	reg [23:0] q;

	assign busy = run;

	wire ge = rem >= {2'b00, d};
	wire [25:0] rem_d;
	wire rd_bo_unused;
	am_sub #(.W(26)) u_rem_d (.a(rem), .b({2'b00, d}), .bi(1'b0), .d(rem_d), .bo(rd_bo_unused));
	wire [25:0] rem_n = ge ? rem_d : rem;
	/* the exponent ea - eb + 126 (+ 1 when ma >= mb); cnt - 1 */
	wire [9:0] eab, e_n;
	wire [4:0] cnt_m1;
	wire eab_bo_unused, en_co_unused, cm_bo_unused;
	am_sub #(.W(10)) u_eab (.a({2'b00, ea}), .b({2'b00, eb}), .bi(1'b0), .d(eab), .bo(eab_bo_unused));
	am_add #(.W(10)) u_e_n (.a(eab), .b(10'd126), .ci(!(ma < mb)), .s(e_n), .co(en_co_unused));
	am_sub #(.W(5)) u_cnt (.a(cnt), .b(5'd0), .bi(1'b1), .d(cnt_m1), .bo(cm_bo_unused));

	/* The end: round the 25 quotient bits (24 + guard) with the sticky. */
	wire last = run && cnt == 5'd0;
	wire [24:0] q_n = {q[23:0], ge};
	wire sticky = rem_n != 26'd0;
	wire [24:0] m0;
	wire [9:0] ef;
	wire m0_co_unused, ef_co_unused;
	am_add #(.W(25)) u_m0 (.a({1'b0, q_n[24:1]}), .b(25'd0), .ci(q_n[0] && (sticky || q_n[1])),
		.s(m0), .co(m0_co_unused));
	wire [24:0] m = m0[24] ? {1'b0, m0[24:1]} : m0;
	am_add #(.W(10)) u_ef (.a(e), .b(10'd0), .ci(m0[24]), .s(ef), .co(ef_co_unused));
	wire unused_m = &{1'b0, m[24:23]};

	always @(posedge clk) begin
		o_done <= 1'b0;
		if (!rst_n) begin
			run <= 1'b0;
		end else if (i_start && !run) begin
			sgn <= s;
			if (nan_a || nan_b || (inf_a && inf_b) || (za && zb)) begin
				o_r <= 32'h7FC00000;
				o_done <= 1'b1;
			end else if (inf_a || zb) begin
				o_r <= {s, 8'hFF, 23'd0};
				o_done <= 1'b1;
			end else if (inf_b || za) begin
				o_r <= {s, 31'd0};
				o_done <= 1'b1;
			end else begin
				run <= 1'b1;
				cnt <= 5'd24;
				d <= mb;
				q <= 24'd0;
				if (ma < mb) begin
					rem <= {1'b0, ma, 1'b0};
					e <= e_n;
				end else begin
					rem <= {2'b00, ma};
					e <= e_n;
				end
			end
		end else if (run) begin
			q <= q_n[23:0];
			rem <= {rem_n[24:0], 1'b0};
			cnt <= cnt_m1;
			if (last) begin
				run <= 1'b0;
				o_done <= 1'b1;
				if (!ef[9] && ef >= 10'd255)
					o_r <= {sgn, 8'hFF, 23'd0};
				else if (ef[9] || ef == 10'd0)
					o_r <= {sgn, 31'd0};
				else
					o_r <= {sgn, ef[7:0], m[22:0]};
			end
		end
	end
endmodule

`default_nettype wire
