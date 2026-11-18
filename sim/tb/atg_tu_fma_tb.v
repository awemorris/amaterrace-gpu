/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_fma_tb: atg_tu_fma against ref_su_ffma(a, b, c, 0, 0) of
 * sim/tb/atg_su_fp_ref.vh (the former function of include/atg_su_fp.vh,
 * now the module atg_su_ffma), one operation a cycle with random bubbles
 * (seeded).  Operands: random words, exponents near one another (the
 * alignment's cases, cancellation c = -a b with a few bits changed),
 * zeros, denormals, infinities and NaNs of both signs, and the weights
 * of atg_tu_ffilt (n x 2^-32).  The addend is given in the cycle the unit
 * asks for it (c_tag).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_fma_tb;
	`include "atg_su_fp_ref.vh"
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg i_vld = 1'b0;
	reg [15:0] i_tag = 16'd0;
	reg [31:0] i_a = 32'd0, i_b = 32'd0;
	wire c_vld, r_vld;
	wire [15:0] c_tag, r_tag;
	wire [31:0] r_val;
	reg [31:0] cmem [0:65535];
	reg [31:0] xmem [0:65535];

	am_fp_fma #(.TW(16), .LAT(10)) dut (.clk(clk), .rst_n(rst_n), .i_vld(i_vld), .i_tag(i_tag),
		.i_a(i_a), .i_b(i_b), .c_vld(c_vld), .c_tag(c_tag), .c_val(cmem[c_tag]),
		.rm(3'd0), .noc(1'b0),
		.r_vld(r_vld), .r_tag(r_tag), .r_val(r_val), .o_busy());

	integer seed, errs, n, nr, j;
	reg [31:0] a, b, c, x;

	/* A random operand of kind r. */
	function [31:0] opnd;
		input [31:0] r0, r1;
		input [7:0] ebase;
		begin
			case (r0[3:0])
			4'd0: opnd = {r1[31], 31'd0};	/* zero */
			4'd1: opnd = {r1[31], 8'd0, r1[22:0]};	/* denormal */
			4'd2: opnd = {r1[31], 8'hFF, 23'd0};	/* infinity */
			4'd3: opnd = {r1[31], 8'hFF, r1[22:1], 1'b1};	/* NaN */
			4'd4: opnd = r1;	/* any */
			4'd5: opnd = {r1[31], 8'd1 + {7'd0, r1[30]}, r1[22:0]};	/* smallest */
			4'd6: opnd = {r1[31], 8'hFE - {7'd0, r1[30]}, r1[22:0]};	/* largest */
			default: opnd = {r1[31], ebase + {{5{r0[7]}}, r0[6:4]}, r1[22:0]};
			endcase
		end
	endfunction

	initial begin
		seed = 1;
		if ($value$plusargs("seed=%d", seed))
			seed = seed + 0;
		errs = 0;
		n = 0;
		nr = 0;
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		for (j = 0; j < 200000; j = j + 1) begin
			@(posedge clk);
			if (($random(seed) & 7) == 0) begin
				i_vld <= 1'b0;
			end else begin
				a = opnd($random(seed), $random(seed), 8'd127);
				b = opnd($random(seed), $random(seed), 8'd127);
				case ($random(seed) & 7)
				0: begin
					/* the weights of atg_tu_ffilt and a texel */
					x = $random(seed);
					a = {1'b0, 8'd95 + {3'd0, x[27:23]}, x[22:0]};
					c = opnd($random(seed), $random(seed), 8'd120);
				end
				1, 2: begin
					/* c near -a b: cancellation */
					x = ref_su_ffma(a, b, 32'd0, 3'd0, 1'b1);
					c = {!x[31], x[30:0]} ^ ($random(seed) & 32'h0000000F);
				end
				3: begin
					x = $random(seed);
					c = opnd($random(seed), $random(seed),
						a[30:23] + b[30:23] - 8'd127 + {2'd0, x[5:0]} - 8'd32);
				end
				default: c = opnd($random(seed), $random(seed), 8'd127);
				endcase
				i_vld <= 1'b1;
				i_a <= a;
				i_b <= b;
				i_tag <= n[15:0];
				cmem[n[15:0]] = c;
				xmem[n[15:0]] = ref_su_ffma(a, b, c, 3'd0, 1'b0);
				n = n + 1;
			end
		end
		@(posedge clk);
		i_vld <= 1'b0;
		repeat (20) @(posedge clk);
		if (errs == 0 && nr == n)
			$display("PASS atg_tu_fma");
		else
			$display("FAIL atg_tu_fma: %0d errors, %0d of %0d results", errs, nr, n);
		$finish;
	end

	always @(posedge clk)
		if (r_vld) begin
			if (r_tag !== nr[15:0] || r_val !== xmem[r_tag]) begin
				if (errs < 10)
					$display("FAIL atg_tu_fma: result %0d tag %h: %h, model %h", nr, r_tag,
						r_val, xmem[r_tag]);
				errs = errs + 1;
			end
			nr = nr + 1;
		end
endmodule

`default_nettype wire
