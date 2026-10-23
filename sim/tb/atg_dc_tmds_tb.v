/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_tmds_tb: random pixels in DE runs: each channel's symbol decodes
 * (the DVI decoder: bit 9 inverts, bit 8 XOR/XNOR) to its byte two cycles
 * later, and the running disparity of the sent bits stays within ±10 at
 * every symbol (DC balance); in blanking the four control symbols of
 * {vs, hs} on channel 0 and {0, 0} on 1 and 2.  Also runs of a constant
 * byte (the worst case for balance).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_tmds_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg [23:0] rgb = 24'd0;
	reg de = 0, hs = 0, vs = 0;
	wire [29:0] tmds;

	atg_dc_tmds dut (.clk(clk), .rst_n(rst_n), .rgb(rgb), .de(de), .hs(hs), .vs(vs),
		.tmds(tmds));

	integer errors = 0;
	integer e_enc = 0, e_ctrl = 0;
	integer i, c, seed, k;
	integer disp [0:2];
	integer maxd;

	function [7:0] decode;
		input [9:0] q;
		reg [7:0] d;
		integer j;
		begin
			d = q[9] ? ~q[7:0] : q[7:0];
			decode[0] = d[0];
			for (j = 1; j < 8; j = j + 1)
				decode[j] = q[8] ? d[j] ^ d[j - 1] : !(d[j] ^ d[j - 1]);
		end
	endfunction

	function integer ones;
		input [9:0] q;
		integer j;
		begin
			ones = 0;
			for (j = 0; j < 10; j = j + 1)
				ones = ones + q[j];
		end
	endfunction

	function [9:0] ctrl_sym;
		input [1:0] cc;
		begin
			case (cc)
			2'b00: ctrl_sym = 10'b1101010100;
			2'b01: ctrl_sym = 10'b0010101011;
			2'b10: ctrl_sym = 10'b0101010100;
			default: ctrl_sym = 10'b1010101011;
			endcase
		end
	endfunction

	/* The inputs of two cycles ago. */
	reg [23:0] rgb1 = 0, rgb2 = 0;
	reg de1 = 0, de2 = 0;
	reg [1:0] sy1 = 0, sy2 = 0;
	reg checking = 0;
	reg [9:0] sym;

	always @(posedge clk) begin
		rgb1 <= rgb;
		rgb2 <= rgb1;
		de1 <= de;
		de2 <= de1;
		sy1 <= {vs, hs};
		sy2 <= sy1;
	end

	always @(negedge clk) begin
		if (checking) begin
			for (c = 0; c < 3; c = c + 1) begin
				sym = tmds[10*c +: 10];
				if (de2) begin
					if (decode(sym) !== rgb2[8*c +: 8]) begin
						e_enc = e_enc + 1;
						if (e_enc < 5)
							$display("FAIL atg_dc_tmds.encode: ch %0d %b -> %h, expected %h",
								c, sym, decode(sym), rgb2[8*c +: 8]);
					end
					disp[c] = disp[c] + 2 * ones(sym) - 10;
					if (disp[c] > maxd) maxd = disp[c];
					if (-disp[c] > maxd) maxd = -disp[c];
				end else begin
					disp[c] = 0;
					if (sym !== ctrl_sym(c == 0 ? sy2 : 2'b00)) begin
						e_ctrl = e_ctrl + 1;
						if (e_ctrl < 5)
							$display("FAIL atg_dc_tmds.ctrl: ch %0d %b", c, sym);
					end
				end
			end
		end
	end

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		disp[0] = 0;
		disp[1] = 0;
		disp[2] = 0;
		maxd = 0;
		repeat (3) @(negedge clk);
		rst_n = 1;
		repeat (3) @(negedge clk);
		checking = 1;
		for (i = 0; i < 20000; i = i + 1) begin
			@(negedge clk);
			k = $unsigned($random(seed)) % 100;
			if (i % 200 < 150) begin
				de = 1;
				/* Mostly random, sometimes a constant run. */
				if (i % 1000 < 500 || k < 10)
					rgb = $random(seed);
			end else begin
				de = 0;
				hs = $random(seed);
				vs = $random(seed);
			end
		end
		@(negedge clk);
		@(negedge clk);
		checking = 0;
		$display("note: the running disparity stayed within %0d", maxd);
		if (maxd > 10) begin
			errors = errors + 1;
			$display("FAIL atg_dc_tmds.encode: running disparity reached %0d", maxd);
		end
		errors = errors + e_enc;
		if (e_enc == 0 && maxd <= 10)
			$display("PASS atg_dc_tmds.encode");
		errors = errors + e_ctrl;
		if (e_ctrl == 0)
			$display("PASS atg_dc_tmds.ctrl");
		if (errors == 0)
			$display("PASS atg_dc_tmds");
		$finish;
	end
endmodule

`default_nettype wire
