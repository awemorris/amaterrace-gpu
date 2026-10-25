/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_etc_tb: atg_tu_etc (3 cycles) against tools/etcmodel.py
 * (sim/vec/tu_etc.txt), every texel of each block.  Groups: "modes" (RGB
 * blocks of every colour mode with and without the flip bit, RGB8A1 with
 * and without the opaque bit, EAC blocks of every table with multipliers 0,
 * 1 and 15 and the extreme bases, in their formats), "random" (random
 * blocks of every format value 0-11).  MUT_ETC_TMODE (a wrong distance
 * entry) must fail "modes".
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_etc_tb;
	reg clk = 1'b0;
	always #5 clk = !clk;
	reg [3:0] fmt = 4'd0;
	reg [127:0] block = 128'd0;
	reg [1:0] s = 2'd0, t = 2'd0;
	wire [1:0] kind;
	wire [31:0] texel;

	atg_tu_etc dut (.clk(clk), .i_fmt(fmt), .i_block(block), .i_s(s), .i_t(t), .o_kind(kind),
		.o_texel(texel));

	integer fd, code, errs, gerrs, n;
	reg [8*12-1:0] tag, gname;
	reg [3:0] x_fmt;
	reg [127:0] x_block;
	reg [1:0] x_s, x_t, x_kind;
	reg [31:0] x_texel;

	initial begin
		errs = 0;
		gerrs = 0;
		n = 0;
		fd = $fopen("sim/vec/tu_etc.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_tu_etc: no sim/vec/tu_etc.txt");
			$finish;
		end
		while (!$feof(fd)) begin
			code = $fscanf(fd, "%s", tag);
			if (code != 1) begin
				/* end of file */
			end else if (tag == "V") begin
				code = $fscanf(fd, "%h %h %h %h %h %h\n", x_fmt, x_block, x_s, x_t, x_kind,
					x_texel);
				fmt = x_fmt;
				block = x_block;
				s = x_s;
				t = x_t;
				repeat (3)
					@(posedge clk);
				#1;
				if (kind !== x_kind || texel !== x_texel) begin
					if (gerrs < 10)
						$display("FAIL atg_tu_etc: fmt %0d block %h texel (%0d, %0d): %0d %h, model %0d %h",
							x_fmt, x_block, x_s, x_t, kind, texel, x_kind, x_texel);
					gerrs = gerrs + 1;
				end
				n = n + 1;
			end else if (tag == "P") begin
				code = $fscanf(fd, "%s\n", gname);
				if (gerrs == 0)
					$display("PASS atg_tu_etc.%0s", gname);
				errs = errs + gerrs;
				gerrs = 0;
			end
		end
		$fclose(fd);
		if (errs == 0 && n > 10000)
			$display("PASS atg_tu_etc");
		else
			$display("FAIL atg_tu_etc: %0d errors, %0d texels", errs, n);
		$finish;
	end
endmodule

`default_nettype wire
