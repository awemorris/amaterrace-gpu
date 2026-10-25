/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_depth_tb: atg_fmt_depth_u24 and atg_fmt_depth_key against the
 * testbench's own reference (the former functions of include/atg_depth.vh,
 * tools/rxmodel.py f2u24): every exponent and sign with the mantissas 0,
 * 1, all ones and 4096 random ones, the specials, and 200,000 random fp32.
 * Prints PASS atg_fmt_depth.u24, .key and PASS atg_fmt_depth; the seed is
 * +seed.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_depth_tb;
	integer seed = 1;
	integer errors = 0;
	integer i, e, s;
	reg [31:0] f, r;
	wire [23:0] u;
	wire [32:0] k;

	atg_fmt_depth_u24 dut_u (.f(f), .u(u));
	atg_fmt_depth_key dut_k (.f(f), .k(k));

	function [23:0] ref_u24;
		input [31:0] x;
		reg [47:0] p;
		reg [71:0] z;
		begin
			p = {1'b1, x[22:0], 24'd0} - {24'd0, 1'b1, x[22:0]};
			z = {p, 24'd0} >> (5'd30 - x[27:23]);
			if (x[30:23] == 8'd0 || x[31] || (x[30:23] == 8'hFF && x[22:0] != 23'd0) ||
			    x[30:23] < 8'd102)
				ref_u24 = 24'd0;
			else if (x[30:23] >= 8'd127)
				ref_u24 = 24'hFFFFFF;
			else
				ref_u24 = z[71:48] + {23'd0, z[47] && (z[46:0] != 47'd0 || z[48])};
		end
	endfunction

	function [32:0] ref_key;
		input [31:0] x;
		ref_key = x[30:23] == 8'd0 ? 33'd0 : x[31] ? -{2'b00, x[30:0]} : {2'b00, x[30:0]};
	endfunction

	reg [31:0] eu, ek;
	task check;
		input [31:0] x;
		begin
			f = x;
			#1;
			if (u !== ref_u24(x)) begin
				eu = eu + 1;
				if (eu < 8)
					$display("FAIL atg_fmt_depth.u24 f %h: %h, expected %h", x, u, ref_u24(x));
			end
			if (k !== ref_key(x)) begin
				ek = ek + 1;
				if (ek < 8)
					$display("FAIL atg_fmt_depth.key f %h: %h, expected %h", x, k, ref_key(x));
			end
		end
	endtask

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;
		eu = 0;
		ek = 0;
		for (s = 0; s < 2; s = s + 1)
			for (e = 0; e < 256; e = e + 1) begin
				check({s[0], e[7:0], 23'd0});
				check({s[0], e[7:0], 23'd1});
				check({s[0], e[7:0], 23'h7FFFFF});
				for (i = 0; i < 4096; i = i + 1) begin
					r = $random(seed);
					check({s[0], e[7:0], r[22:0]});
				end
			end
		/* 1.0, the largest below 1, 2^-24, +inf, NaN, -0 */
		check(32'h3F800000);
		check(32'h3F7FFFFF);
		check(32'h33800000);
		check(32'h7F800000);
		check(32'h7FC00000);
		check(32'h80000000);
		for (i = 0; i < 200000; i = i + 1)
			check($random(seed));
		if (eu == 0)
			$display("PASS atg_fmt_depth.u24");
		if (ek == 0)
			$display("PASS atg_fmt_depth.key");
		errors = eu + ek;
		if (errors == 0)
			$display("PASS atg_fmt_depth");
		else
			$display("FAIL atg_fmt_depth: %0d errors", errors);
		$finish;
	end
endmodule

`default_nettype wire
