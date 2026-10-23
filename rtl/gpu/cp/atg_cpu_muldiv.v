/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_muldiv: The RV32M unit: MUL/MULH/MULHSU/MULHU on a DSP (3
 * cycles) and DIV/DIVU/REM/REMU by a 32-step restoring divider.
 *
 * start (one cycle) takes op (funct3), a and b.  busy is 1 from the
 * cycle after start until the cycle before done; done is a one-cycle
 * pulse in the cycle y is first valid (start + 3 for MUL*, start + 34
 * for DIV/REM*), and y holds until the next start.  A start while busy
 * is ignored.  Division by zero gives quotient all ones and remainder a;
 * INT_MIN / -1 gives INT_MIN and remainder 0 (RISC-V).
 * See spec/gpu/cp/atg_cpu_muldiv.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_muldiv (
	input wire clk,
	input wire rst_n,
	input wire start,
	input wire [2:0] op,
	input wire [31:0] a,
	input wire [31:0] b,
	output wire busy,
	output reg done,
	output reg [31:0] y
);
	localparam [1:0] S_IDLE = 2'd0;
	localparam [1:0] S_MUL = 2'd1;	/* product into p */
	localparam [1:0] S_MSEL = 2'd2;	/* select the half */
	localparam [1:0] S_DIV = 2'd3;	/* 32 steps, then the sign fix */

	reg [1:0] state;
	reg [1:0] op_r;	/* funct3[1:0]: the MUL half or REM */
	/* Multiplier: operands extended to 33 bits by their signedness. */
	reg signed [32:0] ma, mb;
	reg signed [65:0] p;
	/* Divider: magnitudes, partial remainder and quotient. */
	reg [31:0] dq;	/* dividend shifting out, quotient shifting in */
	reg [31:0] dd;	/* divisor magnitude */
	reg [32:0] dr;	/* partial remainder */
	reg [5:0] cnt;
	reg neg_q, neg_r, dzero;
	reg [31:0] a_r;

	assign busy = state != S_IDLE;

	wire is_div = op[2];
	/* MULH and MULHSU take a as signed; MULH takes b as signed. */
	wire a_signed = op[1:0] != 2'd3;
	wire b_signed = op[1:0] == 2'd1;
	/* DIV and REM are signed (funct3 4 and 6). */
	wire d_signed = !op[0];
	wire [31:0] a_abs = (d_signed && a[31]) ? 32'd0 - a : a;
	wire [31:0] b_abs = (d_signed && b[31]) ? 32'd0 - b : b;

	/* One restoring step. */
	wire [32:0] trial = {dr[31:0], dq[31]};
	wire [32:0] tsub = trial - {1'b0, dd};
	wire take = !tsub[32];

	always @(posedge clk) begin
		if (state == S_MUL)
			p <= ma * mb;
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			done <= 1'b0;
			y <= 32'd0;
			op_r <= 2'd0;
			cnt <= 6'd0;
		end else begin
			done <= 1'b0;
			case (state)
			S_IDLE:
				if (start) begin
					op_r <= op[1:0];
					a_r <= a;
					if (is_div) begin
						dq <= a_abs;
						dd <= b_abs;
						dr <= 33'd0;
						cnt <= 6'd0;
						neg_q <= d_signed && (a[31] != b[31]);
						neg_r <= d_signed && a[31];
						dzero <= b == 32'd0;
						state <= S_DIV;
					end else begin
						ma <= {a_signed && a[31], a};
						mb <= {b_signed && b[31], b};
						state <= S_MUL;
					end
				end
			S_MUL:
				state <= S_MSEL;
			S_MSEL: begin
				y <= (op_r[1:0] == 2'd0) ? p[31:0] : p[63:32];
				done <= 1'b1;
				state <= S_IDLE;
			end
			S_DIV:
				if (cnt != 6'd32) begin
					dr <= take ? tsub : trial;
					dq <= {dq[30:0], take};
					cnt <= cnt + 6'd1;
				end else begin
					/* Sign fix; op_r[1] = 1 is REM/REMU. */
					if (dzero)
						y <= op_r[1] ? a_r : 32'hFFFF_FFFF;
					else if (op_r[1])
						y <= neg_r ? 32'd0 - dr[31:0] : dr[31:0];
					else
						y <= neg_q ? 32'd0 - dq : dq;
					done <= 1'b1;
					state <= S_IDLE;
				end
			endcase
		end
	end

	wire unused_ok = &{1'b0, p[65:64], dr[32]};
endmodule

`default_nettype wire
