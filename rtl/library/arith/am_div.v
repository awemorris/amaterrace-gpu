/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_div: a W-bit unsigned integer divider, one quotient bit per cycle.
 * Optimized with Non-Restoring division: uses am_addsub of W+2 bits.
 *
 * Eliminates the restoring multiplexer from the critical path: the adder/
 * subtractor result drives flip-flop inputs directly with no MUX delay.
 * Add/subtract control is decided by the sign bit of the previous remainder
 * register.
 *
 *   start (one cycle, while !busy) takes a (dividend) and b (divisor);
 *   busy is 1 for W cycles; then done pulses for one cycle with q = a / b
 *   and r = a % b, which hold until the next start.
 *
 * b = 0 gives q = all ones and r = a (as RISC-V's divu and remu). Signed
 * division is the caller's (the magnitudes here, the signs outside). rst_n
 * stops a division.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_div #(
	parameter W = 32,
	parameter CW = 6	/* clog2(W + 1): the step counter */
) (
	input wire clk,
	input wire rst_n,
	input wire start,
	input wire [W-1:0] a,
	input wire [W-1:0] b,
	output reg busy,
	output reg done,
	output wire [W-1:0] q,
	output wire [W-1:0] r
);
	/* synthesis syn_ramstyle = "registers", syn_srl_style = "registers" */
	reg [W+1:0] rem;	/* W+2 bits signed partial remainder */
	reg [W-1:0] quo;	/* the dividend's bits not yet used, then the quotient */
	reg [W-1:0] div;
	reg [CW-1:0] n;

	/*
	 * One non-restoring step:
	 * If previous remainder >= 0 (rem[W+1] == 0), subtract divisor (sub = 1).
	 * If previous remainder < 0 (rem[W+1] == 1), add divisor (sub = 0).
	 * Output feeds directly into flip-flop without restoring MUX on critical path.
	 */
	wire [W+1:0] trial = {rem[W:0], quo[W-1]};
	wire [W+1:0] next_rem;
	wire co_unused;

	am_addsub #(.W(W + 2)) step (
		.a(trial),
		.b({2'b00, div}),
		.sub(!rem[W+1]),
		.s(next_rem),
		.co(co_unused)
	);

	/* Step counter decrement */
	wire [CW-1:0] next_n;
	wire n_bo_unused;
	am_sub #(.W(CW)) u_n_dec (
		.a(n),
		.b({{(CW-1){1'b0}}, 1'b1}),
		.bi(1'b0),
		.d(next_n),
		.bo(n_bo_unused)
	);

	/* Final remainder correction if negative (rem[W+1] == 1) */
	wire [W-1:0] rem_corr;
	wire corr_co_unused;
	am_add #(.W(W)) u_rem_corr (
		.a(rem[W-1:0]),
		.b(div),
		.ci(1'b0),
		.s(rem_corr),
		.co(corr_co_unused)
	);

	always @(posedge clk) begin
		if (!rst_n) begin
			busy <= 1'b0;
			done <= 1'b0;
			n    <= {CW{1'b0}};
			rem  <= {(W+2){1'b0}};
			quo  <= {W{1'b0}};
			div  <= {W{1'b0}};
		end else begin
			done <= 1'b0;
			if (start && !busy) begin
				rem  <= {(W+2){1'b0}};
				quo  <= a;
				div  <= b;
				n    <= W[CW-1:0];
				busy <= 1'b1;
			end else if (busy) begin
				rem <= next_rem;
				quo <= {quo[W-2:0], !next_rem[W+1]};
				n   <= next_n;
				if (n == {{(CW-1){1'b0}}, 1'b1}) begin
					busy <= 1'b0;
					done <= 1'b1;
				end
			end
		end
	end

	assign q = quo;
	assign r = rem[W+1] ? rem_corr : rem[W-1:0];

	wire unused_ok = &{1'b0, co_unused, n_bo_unused, corr_co_unused};
endmodule

`default_nettype wire
