/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_muldiv_tb: all eight RV32M operations on corner and random
 * operands against a behavioural reference, checking the latency (MUL 3,
 * DIV 34 cycles from start to done), busy, and that y holds after done.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_muldiv_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg start = 1'b0;
	reg [2:0] op = 3'd0;
	reg [31:0] a = 0, b = 0;
	wire busy, done;
	wire [31:0] y;
	integer seed = 1;
	integer errors = 0;
	integer i, j, k, n, e0;
	reg [31:0] corner [0:9];

	always #5 clk = !clk;

	atg_cpu_muldiv dut (
		.clk(clk), .rst_n(rst_n), .start(start), .op(op), .a(a), .b(b),
		.busy(busy), .done(done), .y(y)
	);

	function [31:0] ref_y;
		input [2:0] o;
		input [31:0] x, z;
		reg [63:0] pr;
		begin
			case (o)
			3'd0: begin pr = x * z; ref_y = pr[31:0]; end
			3'd1: begin
				pr = $signed({{32{x[31]}}, x}) * $signed({{32{z[31]}}, z});
				ref_y = pr[63:32];
			end
			3'd2: begin pr = {{32{x[31]}}, x} * {32'd0, z}; ref_y = pr[63:32]; end
			3'd3: begin pr = {32'd0, x} * {32'd0, z}; ref_y = pr[63:32]; end
			3'd4:
				if (z == 0)
					ref_y = 32'hFFFF_FFFF;
				else if (x == 32'h8000_0000 && z == 32'hFFFF_FFFF)
					ref_y = x;
				else
					ref_y = $signed(x) / $signed(z);
			3'd5: ref_y = (z == 0) ? 32'hFFFF_FFFF : x / z;
			3'd6:
				if (z == 0)
					ref_y = x;
				else if (x == 32'h8000_0000 && z == 32'hFFFF_FFFF)
					ref_y = 0;
				else
					ref_y = $signed(x) % $signed(z);
			default: ref_y = (z == 0) ? x : x % z;
			endcase
		end
	endfunction

	task run;
		input [2:0] o;
		input [31:0] x, z;
		begin
			@(negedge clk);
			op = o;
			a = x;
			b = z;
			start = 1'b1;
			@(negedge clk);
			start = 1'b0;
			op = 3'bxxx;
			a = 32'hxxxx_xxxx;
			b = 32'hxxxx_xxxx;
			n = 1;
			while (!done && n < 100) begin
				if (!busy) begin
					$display("FAIL busy low before done op=%0d", o);
					errors = errors + 1;
				end
				@(negedge clk);
				n = n + 1;
			end
			if (n != (o[2] ? 34 : 3)) begin
				$display("FAIL latency op=%0d %0d cycles", o, n);
				errors = errors + 1;
			end
			if (y !== ref_y(o, x, z)) begin
				$display("FAIL op=%0d a=%h b=%h y=%h want %h", o, x, z, y, ref_y(o, x, z));
				errors = errors + 1;
			end
			@(negedge clk);
			if (done || busy || y !== ref_y(o, x, z)) begin
				$display("FAIL y not held op=%0d", o);
				errors = errors + 1;
			end
		end
	endtask

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;
		corner[0] = 0;
		corner[1] = 1;
		corner[2] = 32'hFFFF_FFFF;
		corner[3] = 32'h8000_0000;
		corner[4] = 32'h7FFF_FFFF;
		corner[5] = 2;
		corner[6] = 32'hFFFF_FFFE;
		corner[7] = 7;
		corner[8] = 32'hFFFF_FFF9;
		corner[9] = 32'h1234_5678;
		repeat (3) @(negedge clk);
		rst_n = 1'b1;
		for (k = 0; k < 2; k = k + 1) begin
			e0 = errors;
			for (i = 0; i < 10; i = i + 1)
				for (j = 0; j < 10; j = j + 1)
					for (n = 0; n < 4; n = n + 1)
						run(k * 4 + n, corner[i], corner[j]);
			for (i = 0; i < 400; i = i + 1)
				run(k * 4 + (i % 4), $random(seed),
					(i % 5 == 0) ? ($random(seed) & 32'hFF) : $random(seed));
			if (errors == e0)
				$display("PASS atg_cpu_muldiv.%s", k ? "div" : "mul");
		end
		if (errors == 0)
			$display("PASS atg_cpu_muldiv");
		$finish;
	end
endmodule

`default_nettype wire
