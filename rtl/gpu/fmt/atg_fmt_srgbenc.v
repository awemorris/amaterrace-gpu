/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_srgbenc: the sRGB encoder of the ROP and the BLT: a linear fp32
 * colour component to the nearest 8-bit sRGB code (the code whose interval
 * of the sRGB EOTF holds it), by an 8-step binary search over the 255
 * thresholds of include/atg_srgb.vh (atg_srgb_thr: the smallest fp32 above
 * EOTF((c + 0.5) / 255)): the code is the count of thresholds <= x.  A
 * positive fp32 orders as its bits, so each step is an integer compare.
 * The step is a one-hot bit (2^7 down to 2^0) and below it the bits
 * under it: lo has no bit under the step, so lo + step - 1 is lo | below
 * and lo + step is lo | step (no adder, docs/style.md "Arithmetic").
 * NaN, negative values and -0 give 0; values >= 1 (and +infinity) 255.
 *
 * i_valid/i_ready: one component, taken in IDLE.  o_valid/o_ready: the
 * code, held until taken: o_valid comes 9 cycles after the accept (eight
 * steps), one component at a time.
 * spec/gpu/fmt/atg_fmt_srgbenc.md; tools/fmtmodel.py (srgb_encode) is the
 * reference.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_srgbenc (
	input wire clk,
	input wire rst_n,
	input wire i_valid,
	output wire i_ready,
	input wire [31:0] i_x,
	output wire o_valid,
	input wire o_ready,
	output wire [7:0] o_code
);
	`include "atg_srgb.vh"

	localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_OUT = 2'd2;

	reg [1:0] state;
	reg [30:0] x;	/* the magnitude; the sign and NaN are folded to 0 on input */
	reg [7:0] lo;
	reg [7:0] step;	/* the step, one-hot: 2^7 down to 2^0 */
	reg [6:0] below;	/* the bits under it (step - 1) */

	wire [7:0] probe = lo | {1'b0, below};
`ifdef MUT_SRGB_ROUND
	wire [31:0] thr = atg_srgb_thr(lo | step);	/* a deliberate error (the TB must fail) */
`else
	wire [31:0] thr = atg_srgb_thr(probe);
`endif
	wire nan = i_x[30:23] == 8'hFF && i_x[22:0] != 23'd0;

	assign i_ready = state == S_IDLE;
	assign o_valid = state == S_OUT;
	assign o_code = lo;

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			x <= 31'd0;
			lo <= 8'd0;
			step <= 8'h80;
			below <= 7'h7F;
		end else begin
			case (state)
			S_IDLE:
				if (i_valid) begin
					x <= i_x[31] || nan ? 31'd0 : i_x[30:0];
					lo <= 8'd0;
					step <= 8'h80;
					below <= 7'h7F;
					state <= S_RUN;
				end
			S_RUN: begin
				if ({1'b0, x} >= thr)
					lo <= lo | step;
				step <= step >> 1;
				below <= below >> 1;
				if (step[0])
					state <= S_OUT;
			end
			S_OUT:
				if (o_ready)
					state <= S_IDLE;
			default:
				state <= S_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
