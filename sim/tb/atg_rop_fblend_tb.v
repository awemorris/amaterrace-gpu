/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_fblend_tb: atg_rop_fblend against the model of tools/rxmodel.py
 * (fblend_lane; sim/vec/rop_fblend.txt from tools/rop-vectors.py): beats of
 * the seven formats (and one the path does not have) with random BLEND
 * words (every op and factor), constants, write masks, lanes and sources
 * with specials ("ops"), and the sRGB formats with ZERO x source + ONE x
 * destination, which must write every code back unchanged ("srgb").
 * o_raw and o_keep are compared; i_valid gaps and o_ready are random.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_fblend_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg i_valid = 1'b0, o_ready = 1'b0;
	reg [3:0] i_lanes = 0, i_wm = 0;
	reg [511:0] i_src = 0;
	reg [255:0] i_dst = 0;
	reg [7:0] i_fmt = 0;
	reg [22:0] i_blend = 0;
	reg [127:0] i_const = 0;
	wire i_ready, o_valid;
	wire [255:0] o_raw, o_keep;

	atg_rop_fblend dut (.clk(clk), .rst_n(rst_n), .i_valid(i_valid), .i_ready(i_ready),
		.i_lanes(i_lanes), .i_src(i_src), .i_dst(i_dst), .i_fmt(i_fmt), .i_blend(i_blend),
		.i_const(i_const), .i_wm(i_wm), .o_valid(o_valid), .o_ready(o_ready),
		.o_raw(o_raw), .o_keep(o_keep));

	integer fd, code, j, sect, fmt, seed, nb, maxc, cyc, got;
	integer e_s [0:1];
	reg [7:0] tag;
	reg [31:0] bl, wt, ln, wmv;
	reg [63:0] w64;
	reg [255:0] x_raw, x_keep;

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		e_s[0] = 0;
		e_s[1] = 0;
		nb = 0;
		maxc = 0;
		fd = $fopen("sim/vec/rop_fblend.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rop_fblend: no sim/vec/rop_fblend.txt");
			$finish;
		end
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		code = 1;
		while (code > 0) begin
			code = $fscanf(fd, "%c", tag);
			if (tag == "F") begin
				code = $fscanf(fd, " %d %d %h", sect, fmt, bl);
				for (j = 0; j < 4; j = j + 1) begin
					code = $fscanf(fd, " %h", wt);
					i_const[32 * j +: 32] = wt;
				end
				code = $fscanf(fd, " %h %h", wmv, ln);
				for (j = 0; j < 16; j = j + 1) begin
					code = $fscanf(fd, " %h", wt);
					i_src[32 * j +: 32] = wt;
				end
				for (j = 0; j < 4; j = j + 1) begin
					code = $fscanf(fd, " %h", w64);
					i_dst[64 * j +: 64] = w64;
				end
				for (j = 0; j < 4; j = j + 1) begin
					code = $fscanf(fd, " %h", w64);
					x_raw[64 * j +: 64] = w64;
				end
				for (j = 0; j < 4; j = j + 1) begin
					code = $fscanf(fd, " %h", w64);
					x_keep[64 * j +: 64] = w64;
				end
				code = $fscanf(fd, "%c", tag);
				i_fmt = fmt;
				i_blend = bl[22:0];
				i_wm = wmv[3:0];
				i_lanes = ln[3:0];
				if ($random(seed) & 1)
					@(posedge clk);
				i_valid <= 1'b1;
				@(posedge clk);
				while (!i_ready)
					@(posedge clk);
				i_valid <= 1'b0;
				cyc = 0;
				got = 0;
				@(negedge clk);
				while (!got && cyc < 5000) begin
					o_ready = ($random(seed) & 3) != 0;
					@(posedge clk);
					got = o_valid && o_ready;
					@(negedge clk);
					cyc = cyc + 1;
				end
				if (cyc > maxc)
					maxc = cyc;
				if (!got || o_raw !== x_raw || o_keep !== x_keep) begin
					e_s[sect] = e_s[sect] + 1;
					if (e_s[0] + e_s[1] < 8)
						$display("FAIL atg_rop_fblend: beat %0d (fmt %0d blend %h lanes %h wm %h)\n raw %h\n exp %h\n keep %h\n exp %h",
							nb, fmt, bl, ln, wmv, o_raw, x_raw, o_keep, x_keep);
				end
				o_ready = 1'b0;
				nb = nb + 1;
			end else
				code = 0;
		end
		$fclose(fd);
		$display("atg_rop_fblend: %0d beats, at most %0d cycles each", nb, maxc);
		if (e_s[0] == 0 && nb > 0)
			$display("PASS atg_rop_fblend.ops");
		if (e_s[1] == 0 && nb > 0)
			$display("PASS atg_rop_fblend.srgb");
		if (e_s[0] + e_s[1] == 0 && nb > 0)
			$display("PASS atg_rop_fblend");
		$finish;
	end

	initial begin
		#200000000;
		$display("FAIL atg_rop_fblend: timeout");
		$finish;
	end
endmodule

`default_nettype wire
