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
	/* a - b with a borrow bit: diff[32] = 1 when a < b unsigned. */
	wire [32:0] diff = {1'b0, a} - {1'b0, b};

	assign eq = a == b;
	assign ltu = diff[32];
	/* Signed: different signs → a's sign; equal signs → the unsigned result. */
	assign lt = (a[31] != b[31]) ? a[31] : diff[32];

	always @(*) begin
		case (op)
		OP_ADD: y = a + b;
		OP_SUB: y = diff[31:0];
		OP_SLL: y = a << sh;
		OP_SLT: y = {31'd0, lt};
		OP_SLTU: y = {31'd0, ltu};
		OP_XOR: y = a ^ b;
		OP_SRL: y = a >> sh;
		OP_SRA: y = $unsigned($signed(a) >>> sh);
		OP_OR: y = a | b;
		OP_AND: y = a & b;
		OP_PASS_B: y = b;
		default: y = 32'd0;
		endcase
	end
endmodule

`default_nettype wire
