/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_div255_tb: unit testbench for atg_rop_div255.
 * Exhaustively tests all inputs 0 <= x <= 65025 against the mathematical
 * reference round(x / 255) and the 5-stage legacy reference.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_div255_tb;
	integer errors = 0;
	integer val;
	reg [17:0] x;
	wire [8:0] q;

	atg_rop_div255 dut (
		.x(x),
		.q(q)
	);

	function [8:0] ref_math(input [17:0] in_x);
		integer ix;
		begin
			ix = in_x;
			ref_math = (ix + 127) / 255;
		end
	endfunction

	function [8:0] ref_legacy(input [17:0] in_x);
		reg [18:0] y;
		reg [9:0] lo0, lo;
		reg [10:0] hi0, hi;
		begin
			y = {1'b0, in_x} + 19'd128;
			lo0 = {2'd0, y[7:0]} + {2'd0, y[15:8]};
			lo = lo0 + {7'd0, y[18:16]};
			hi0 = y[18:8] + {8'd0, y[18:16]};
			hi = hi0 + {9'd0, lo[9:8]};
			ref_legacy = hi[8:0];
		end
	endfunction

	initial begin
		#1;
		for (val = 0; val <= 130050; val = val + 1) begin
			x = val[17:0];
			#1;
			if (q !== ref_math(x)) begin
				$display("FAIL atg_rop_div255: x=%0d, got q=%0d, expected math=%0d", val, q, ref_math(x));
				errors = errors + 1;
			end
			if (q !== ref_legacy(x)) begin
				$display("FAIL atg_rop_div255: x=%0d, got q=%0d, expected legacy=%0d", val, q, ref_legacy(x));
				errors = errors + 1;
			end
		end

		if (errors == 0) begin
			$display("PASS atg_rop_div255");
		end else begin
			$display("FAIL atg_rop_div255: %0d errors", errors);
		end
		$finish;
	end
endmodule

`default_nettype wire
