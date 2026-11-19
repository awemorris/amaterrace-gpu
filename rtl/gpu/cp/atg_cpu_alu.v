/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_alu: The RV32I integer ALU and branch comparator of
 * atg_cpu_core, combinational.
 *
 * y = op(a, b): 0 ADD, 1 SUB, 2 SLL, 3 SLT, 4 SLTU, 5 XOR, 6 SRL, 7 SRA,
 * 8 OR, 9 AND, 10 PASS_B; other codes give 0.  Shifts use b[4:0].
 * eq, lt (signed) and ltu (unsigned) compare a with b whatever op is.
 * See spec/gpu/cp/atg_cpu_alu.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_alu (
	input wire [3:0] op,
	input wire [31:0] a,
	input wire [31:0] b,
	output reg [31:0] y,
	output wire eq,
	output wire lt,
	output wire ltu
);
	localparam [3:0] OP_ADD = 4'd0;
	localparam [3:0] OP_SUB = 4'd1;
	localparam [3:0] OP_SLL = 4'd2;
	localparam [3:0] OP_SLT = 4'd3;
	localparam [3:0] OP_SLTU = 4'd4;
	localparam [3:0] OP_XOR = 4'd5;
	localparam [3:0] OP_SRL = 4'd6;
	localparam [3:0] OP_SRA = 4'd7;
	localparam [3:0] OP_OR = 4'd8;
	localparam [3:0] OP_AND = 4'd9;
	localparam [3:0] OP_PASS_B = 4'd10;

	wire [4:0] sh = b[4:0];
	/* Fast 4-chunk carry-select a - b and a + b (with borrow bit diff[32] for a < b unsigned). */
	wire [7:0] d0, d1_0, d1_1, d2_0, d2_1;
	wire [8:0] d3_0, d3_1;
	wire bo0, bo1_0, bo1_1, bo2_0, bo2_1, bo3_0, bo3_1;
	am_sub #(.W(8)) u_d0   (.a(a[7:0]),       .b(b[7:0]),       .bi(1'b0), .d(d0),   .bo(bo0));
	am_sub #(.W(8)) u_d1_0 (.a(a[15:8]),      .b(b[15:8]),      .bi(1'b0), .d(d1_0), .bo(bo1_0));
	am_sub #(.W(8)) u_d1_1 (.a(a[15:8]),      .b(b[15:8]),      .bi(1'b1), .d(d1_1), .bo(bo1_1));
	am_sub #(.W(8)) u_d2_0 (.a(a[23:16]),     .b(b[23:16]),     .bi(1'b0), .d(d2_0), .bo(bo2_0));
	am_sub #(.W(8)) u_d2_1 (.a(a[23:16]),     .b(b[23:16]),     .bi(1'b1), .d(d2_1), .bo(bo2_1));
	am_sub #(.W(9)) u_d3_0 (.a({1'b0, a[31:24]}), .b({1'b0, b[31:24]}), .bi(1'b0), .d(d3_0), .bo(bo3_0));
	am_sub #(.W(9)) u_d3_1 (.a({1'b0, a[31:24]}), .b({1'b0, b[31:24]}), .bi(1'b1), .d(d3_1), .bo(bo3_1));
	wire bo1 = bo0 ? bo1_1 : bo1_0;
	wire bo2 = bo2_0 | (bo2_1 & bo1_0) | (bo2_1 & bo1_1 & bo0);
	wire [32:0] diff = {
		bo2 ? d3_1 : d3_0,
		bo1 ? d2_1 : d2_0,
		bo0 ? d1_1 : d1_0,
		d0
	};
	wire diff_bo = bo2 ? bo3_1 : bo3_0;

	wire [7:0] s0, s1_0, s1_1, s2_0, s2_1, s3_0, s3_1;
	wire co0, co1_0, co1_1, co2_0, co2_1, co3_0, co3_1;
	am_add #(.W(8)) u_s0   (.a(a[7:0]),   .b(b[7:0]),   .ci(1'b0), .s(s0),   .co(co0));
	am_add #(.W(8)) u_s1_0 (.a(a[15:8]),  .b(b[15:8]),  .ci(1'b0), .s(s1_0), .co(co1_0));
	am_add #(.W(8)) u_s1_1 (.a(a[15:8]),  .b(b[15:8]),  .ci(1'b1), .s(s1_1), .co(co1_1));
	am_add #(.W(8)) u_s2_0 (.a(a[23:16]), .b(b[23:16]), .ci(1'b0), .s(s2_0), .co(co2_0));
	am_add #(.W(8)) u_s2_1 (.a(a[23:16]), .b(b[23:16]), .ci(1'b1), .s(s2_1), .co(co2_1));
	am_add #(.W(8)) u_s3_0 (.a(a[31:24]), .b(b[31:24]), .ci(1'b0), .s(s3_0), .co(co3_0));
	am_add #(.W(8)) u_s3_1 (.a(a[31:24]), .b(b[31:24]), .ci(1'b1), .s(s3_1), .co(co3_1));
	wire co1 = co0 ? co1_1 : co1_0;
	wire co2 = co2_0 | (co2_1 & co1_0) | (co2_1 & co1_1 & co0);
	wire [31:0] sum = {
		co2 ? s3_1 : s3_0,
		co1 ? s2_1 : s2_0,
		co0 ? s1_1 : s1_0,
		s0
	};
	wire sum_co = co2 ? co3_1 : co3_0;

	wire [31:0] shifted;
	/* SLL, SRL and SRA share one shifter. */
	am_shift #(.W(32), .SW(5)) shifter (
		.a(a), .amt(sh), .left(op == OP_SLL), .arith(op == OP_SRA), .y(shifted)
	);

	wire [3:0] eq_b = {
		a[31:24] == b[31:24],
		a[23:16] == b[23:16],
		a[15:8]  == b[15:8],
		a[7:0]   == b[7:0]
	};
	wire [3:0] lt_b = {
		a[31:24] < b[31:24],
		a[23:16] < b[23:16],
		a[15:8]  < b[15:8],
		a[7:0]   < b[7:0]
	};
	assign eq = &eq_b;
	assign ltu = lt_b[3] || (eq_b[3] && lt_b[2]) || (eq_b[3] && eq_b[2] && lt_b[1]) ||
		(eq_b[3] && eq_b[2] && eq_b[1] && lt_b[0]);
	/* Signed: different signs -> a's sign; equal signs -> the unsigned result. */
	assign lt = (a[31] != b[31]) ? a[31] : ltu;

	always @(*) begin
		case (op)
		OP_ADD: y = sum;
		OP_SUB: y = diff[31:0];
		OP_SLL: y = shifted;
		OP_SLT: y = {31'd0, lt};
		OP_SLTU: y = {31'd0, ltu};
		OP_XOR: y = a ^ b;
		OP_SRL: y = shifted;
		OP_SRA: y = shifted;
		OP_OR: y = a | b;
		OP_AND: y = a & b;
		OP_PASS_B: y = b;
		default: y = 32'd0;
		endcase
	end

	wire unused_ok = &{1'b0, diff[32], diff_bo, sum_co};
endmodule

`default_nettype wire
