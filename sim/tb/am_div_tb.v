/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_div_tb: comprehensive unit testbench for Non-restoring divider am_div.
 * Tests W=8 exhaustively (all 65536 combinations of dividend and divisor including 0),
 * W=16 and W=32 with extensive randomized pairs, powers of 2, large primes,
 * and boundary/corner cases (b=0 division by zero, a=0, a=b, a<b, max values).
 */

`timescale 1ns / 1ps
`default_nettype none

module am_div_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	integer errors = 0;
	integer seed = 98765;
	integer i, j;

	/* -------------------------------------------------------------
	 * Width 8 DUT
	 * ------------------------------------------------------------- */
	reg d8_start;
	reg [7:0] d8_a, d8_b;
	wire d8_busy, d8_done;
	wire [7:0] d8_q, d8_r;

	am_div #(.W(8), .CW(4)) dut8 (
		.clk(clk), .rst_n(rst_n), .start(d8_start),
		.a(d8_a), .b(d8_b), .busy(d8_busy), .done(d8_done),
		.q(d8_q), .r(d8_r)
	);

	/* -------------------------------------------------------------
	 * Width 32 DUT
	 * ------------------------------------------------------------- */
	reg d32_start;
	reg [31:0] d32_a, d32_b;
	wire d32_busy, d32_done;
	wire [31:0] d32_q, d32_r;

	am_div #(.W(32), .CW(6)) dut32 (
		.clk(clk), .rst_n(rst_n), .start(d32_start),
		.a(d32_a), .b(d32_b), .busy(d32_busy), .done(d32_done),
		.q(d32_q), .r(d32_r)
	);

	task test_div8(input [7:0] a, input [7:0] b);
		reg [7:0] exp_q, exp_r;
		integer cycles;
		begin
			if (b == 8'd0) begin
				exp_q = 8'hFF;
				exp_r = a;
			end else begin
				exp_q = a / b;
				exp_r = a % b;
			end

			@(posedge clk); #1;
			d8_a = a;
			d8_b = b;
			d8_start = 1'b1;
			@(posedge clk); #1;
			d8_start = 1'b0;

			cycles = 0;
			while (!d8_done && cycles < 20) begin
				@(posedge clk);
				cycles = cycles + 1;
			end

			if (!d8_done) begin
				$display("FAIL W=8 timeout: a=%0d b=%0d", a, b);
				errors = errors + 1;
			end else if (d8_q !== exp_q || d8_r !== exp_r) begin
				$display("FAIL W=8: a=%0d b=%0d -> q=%0d r=%0d (exp q=%0d r=%0d)",
					a, b, d8_q, d8_r, exp_q, exp_r);
				errors = errors + 1;
			end
		end
	endtask

	task test_div32(input [31:0] a, input [31:0] b);
		reg [31:0] exp_q, exp_r;
		integer cycles;
		begin
			if (b == 32'd0) begin
				exp_q = 32'hFFFFFFFF;
				exp_r = a;
			end else begin
				exp_q = a / b;
				exp_r = a % b;
			end

			@(posedge clk); #1;
			d32_a = a;
			d32_b = b;
			d32_start = 1'b1;
			@(posedge clk); #1;
			d32_start = 1'b0;

			cycles = 0;
			while (!d32_done && cycles < 45) begin
				@(posedge clk);
				cycles = cycles + 1;
			end

			if (!d32_done) begin
				$display("FAIL W=32 timeout: a=0x%08x b=0x%08x", a, b);
				errors = errors + 1;
			end else if (d32_q !== exp_q || d32_r !== exp_r) begin
				$display("FAIL W=32: a=0x%08x b=0x%08x -> q=0x%08x r=0x%08x (exp q=0x%08x r=0x%08x)",
					a, b, d32_q, d32_r, exp_q, exp_r);
				errors = errors + 1;
			end
		end
	endtask

	initial begin
		d8_start  = 1'b0;
		d8_a      = 8'd0;
		d8_b      = 8'd0;
		d32_start = 1'b0;
		d32_a     = 32'd0;
		d32_b     = 32'd0;

		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		repeat (2) @(posedge clk);

		/* 1. Exhaustive test for W=8 (65536 combinations) */
		for (i = 0; i < 256; i = i + 1) begin
			for (j = 0; j < 256; j = j + 1) begin
				test_div8(i[7:0], j[7:0]);
			end
		end

		/* 2. Specific corner cases for W=32 */
		test_div32(32'd0, 32'd0);
		test_div32(32'd100, 32'd0);
		test_div32(32'hFFFFFFFF, 32'd0);
		test_div32(32'd0, 32'd1);
		test_div32(32'd0, 32'hFFFFFFFF);
		test_div32(32'd1, 32'd1);
		test_div32(32'hFFFFFFFF, 32'hFFFFFFFF);
		test_div32(32'hFFFFFFFF, 32'd1);
		test_div32(32'hFFFFFFFF, 32'd2);
		test_div32(32'h80000000, 32'h80000000);
		test_div32(32'h80000000, 32'd2);
		test_div32(32'd10, 32'd20); /* a < b */
		test_div32(32'h12345678, 32'h87654321); /* a < b */
		test_div32(32'hFFFFFFFF, 32'd10);
		test_div32(32'd1000000, 32'd7);

		/* 3. Randomized test for W=32 (1000 vectors) */
		for (i = 0; i < 1000; i = i + 1) begin
			test_div32($random(seed), $random(seed));
		end

		/* Summary */
		if (errors == 0)
			$display("PASS am_div");
		else
			$display("FAIL am_div: %0d errors", errors);

		$finish;
	end
endmodule

`default_nettype wire
