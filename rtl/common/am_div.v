/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_div: a W-bit unsigned integer divider, one quotient bit per cycle
 * (restoring; one am_sub of W + 1 bits, LUTs and a CARRY4 chain).
 *
 *   start (one cycle, while !busy) takes a (dividend) and b (divisor);
 *   busy is 1 for W cycles; then done pulses for one cycle with q = a / b
 *   and r = a % b, which hold until the next start.
 *
 * b = 0 gives q = all ones and r = a (as RISC-V's divu and remu).  Signed
 * division is the caller's (the magnitudes here, the signs outside).  rst_n
 * stops a division.  Every signal division or remainder outside rtl/common/
 * is an instance of this module (docs/style.md, "Arithmetic").
 */

`timescale 1ns / 1ps
`default_nettype none

module am_div #(
	parameter W = 32,
	parameter CW = 5	/* clog2(W + 1): the step counter */
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
	reg [W-1:0] rem;	/* the partial remainder */
	reg [W-1:0] quo;	/* the dividend's bits not yet used, then the quotient */
	reg [W-1:0] div;
	reg [CW-1:0] n;

	/* One step: the remainder with the next dividend bit, less the divisor if it fits. */
	wire [W:0] trial = {rem, quo[W-1]};
	wire [W:0] diff;
	wire borrow;

	am_sub #(.W(W + 1)) step (
		.a(trial), .b({1'b0, div}), .bi(1'b0), .d(diff), .bo(borrow)
	);

	always @(posedge clk) begin
		if (!rst_n) begin
			busy <= 1'b0;
			done <= 1'b0;
			n <= {CW{1'b0}};
		end else begin
			done <= 1'b0;
			if (start && !busy) begin
				rem <= {W{1'b0}};
				quo <= a;
				div <= b;
				n <= W[CW-1:0];
				busy <= 1'b1;
			end else if (busy) begin
				rem <= borrow ? trial[W-1:0] : diff[W-1:0];
				quo <= {quo[W-2:0], !borrow};
				n <= n - 1'b1;
				if (n == {{(CW-1){1'b0}}, 1'b1}) begin
					busy <= 1'b0;
					done <= 1'b1;
				end
			end
		end
	end

	assign q = quo;
	assign r = rem;

	wire unused_ok = &{1'b0, diff[W]};
endmodule

`default_nettype wire
