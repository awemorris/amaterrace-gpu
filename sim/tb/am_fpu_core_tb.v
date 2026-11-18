/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fpu_core_tb: standalone unit testbench for am_fpu_core against the 6000
 * reference vectors in sim/tb/su/fpu_vec.hex (from tools/gsi1fp.py --fpu-vec).
 * Tests all FP and integer multiplication operations across all rounding modes,
 * saturations, and special corner cases for both LAT=0 (combinational) and
 * LAT=4 (4-stage physical pipeline).
 */

`timescale 1ns / 1ps
`default_nettype none

module am_fpu_core_tb;
	localparam NV = 6000;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg [4:0] op = 5'd0;
	reg [2:0] rm = 3'd0;
	reg sat = 1'b0;
	reg [31:0] a = 32'd0, b = 32'd0, c = 32'd0;
	wire [31:0] res0;
	wire [31:0] res4;

	am_fpu_core #(.LAT(0)) dut0 (
		.clk(clk),
		.rst_n(rst_n),
		.en(1'b1),
		.op(op),
		.rm(rm),
		.sat(sat),
		.a(a),
		.b(b),
		.c(c),
		.res(res0)
	);

	am_fpu_core #(.LAT(4)) dut4 (
		.clk(clk),
		.rst_n(rst_n),
		.en(1'b1),
		.op(op),
		.rm(rm),
		.sat(sat),
		.a(a),
		.b(b),
		.c(c),
		.res(res4)
	);

	reg [143:0] vec [0:NV-1];
	integer i, errors;

	initial begin
		errors = 0;
		$readmemh("sim/tb/su/fpu_vec.hex", vec);
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		@(posedge clk);
		#1;

		for (i = 0; i < NV + 4; i = i + 1) begin
			if (i < NV) begin
				op  <= vec[i][140:136];
				rm  <= vec[i][134:132];
				sat <= vec[i][128];
				a   <= vec[i][127:96];
				b   <= vec[i][95:64];
				c   <= vec[i][63:32];
			end else begin
				op  <= 5'd0;
				rm  <= 3'd0;
				sat <= 1'b0;
				a   <= 32'd0;
				b   <= 32'd0;
				c   <= 32'd0;
			end
			#1;
			if (i < NV && res0 !== vec[i][31:0]) begin
				if (errors < 20) begin
					$display("FAIL am_fpu_core (LAT=0): vector %0d op=%0d rm=%0d sat=%0b", i, op, rm, sat);
					$display("  a=%h b=%h c=%h got=%h want=%h", a, b, c, res0, vec[i][31:0]);
				end
				errors = errors + 1;
			end
			if (i >= 4 && i - 4 < NV) begin
				if (res4 !== vec[i-4][31:0]) begin
					if (errors < 20) begin
						$display("FAIL am_fpu_core (LAT=4): vector %0d got=%h want=%h", i-4, res4, vec[i-4][31:0]);
					end
					errors = errors + 1;
				end
			end
			@(posedge clk);
			#1;
		end

		if (errors == 0) begin
			$display("PASS am_fpu_core");
		end else begin
			$display("FAIL am_fpu_core: %0d total mismatches", errors);
		end
		$finish;
	end
endmodule

`default_nettype wire
