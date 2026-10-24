/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_ycc_tb: atg_dc_ycc fed with lines of random pixels (and the
 * primary colours) between blanking of random length, the syncs random.
 * A reference model (signed BT.601 arithmetic, written independently of
 * the folded sums of the RTL) gives each output two cycles after its
 * input.  Checks, in order:
 *
 *   - colors: the model gives BT.601's studio values within 1 for white,
 *     black, red, green, blue and grey, and the RTL the model's values for
 *     a pair of pixels after blanking;
 *   - stream: every output against the model: Y of each pixel, Cb of the
 *     first and Cr of the first in the second pixel of each pair from the
 *     rise of DE, black outside DE, DE/HS/VS delayed by two.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_ycc_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg [23:0] rgb = 24'd0;
	reg de = 1'b0;
	reg hs = 1'b0;
	reg vs = 1'b0;
	wire [15:0] ycc;
	wire ycc_de, ycc_hs, ycc_vs;
	integer errors = 0;
	integer seed = 1;
	integer k;

	always #5 clk = !clk;

	atg_dc_ycc dut (
		.clk(clk), .rst_n(rst_n), .rgb(rgb), .de(de), .hs(hs), .vs(vs),
		.ycc(ycc), .ycc_de(ycc_de), .ycc_hs(ycc_hs), .ycc_vs(ycc_vs)
	);

	function [7:0] f_y;
		input [23:0] p;
		integer v;
		begin
			v = 66 * p[23:16] + 129 * p[15:8] + 25 * p[7:0] + 128;
			f_y = (v >>> 8) + 16;
		end
	endfunction

	function [7:0] f_cb;
		input [23:0] p;
		integer v;
		begin
			v = -38 * $signed({1'b0, p[23:16]}) - 74 * $signed({1'b0, p[15:8]}) +
				112 * $signed({1'b0, p[7:0]}) + 128;
			f_cb = (v >>> 8) + 128;
		end
	endfunction

	function [7:0] f_cr;
		input [23:0] p;
		integer v;
		begin
			v = 112 * $signed({1'b0, p[23:16]}) - 94 * $signed({1'b0, p[15:8]}) -
				18 * $signed({1'b0, p[7:0]}) + 128;
			f_cr = (v >>> 8) + 128;
		end
	endfunction

	/* The model: inputs taken at each rising edge (they change on the
	 * falling one); the output after a rising edge is the input of the
	 * edge before (two stages), checked at the falling edge. */
	reg [15:0] e0, e1;
	reg [2:0] s0, s1;
	reg odd = 1'b0;
	reg [7:0] crh = 8'd0;
	reg checking = 1'b0;

	always @(posedge clk) begin
		e1 = e0;
		s1 = s0;
		s0 = {de, hs, vs};
		if (!de) begin
			e0 = {8'd128, 8'd16};
			odd = 1'b0;
		end else if (!odd) begin
			e0 = {f_cb(rgb), f_y(rgb)};
			crh = f_cr(rgb);
			odd = 1'b1;
		end else begin
			e0 = {crh, f_y(rgb)};
			odd = 1'b0;
		end
	end

	always @(negedge clk)
		if (checking && (ycc !== e1 || {ycc_de, ycc_hs, ycc_vs} !== s1)) begin
			errors = errors + 1;
			if (errors < 10)
				$display("FAIL atg_dc_ycc: got %h %b, want %h %b at %0t", ycc,
					{ycc_de, ycc_hs, ycc_vs}, e1, s1, $time);
		end

	/* The model against BT.601's real values (Y = 16 + 219 E'y, ...), +-1. */
	function near;
		input [7:0] got;
		input real want;
		begin
			near = got >= want - 1.0 && got <= want + 1.0;
		end
	endfunction

	task color;
		input [23:0] p;
		input real y, cb, cr;
		begin
			if (!near(f_y(p), y) || !near(f_cb(p), cb) || !near(f_cr(p), cr)) begin
				errors = errors + 1;
				$display("FAIL atg_dc_ycc: model %h -> %0d %0d %0d", p, f_y(p), f_cb(p),
					f_cr(p));
			end
		end
	endtask

	/* Two pixels of one colour after blanking: {Cb, Y} then {Cr, Y}. */
	task pair;
		input [23:0] p;
		begin
			@(negedge clk);
			de = 1'b1;
			rgb = p;
			@(negedge clk);
			rgb = p;
			@(posedge clk);
			#1;
			if (ycc !== {f_cb(p), f_y(p)} || !ycc_de) begin
				errors = errors + 1;
				$display("FAIL atg_dc_ycc: %h first %h", p, ycc);
			end
			@(negedge clk);
			de = 1'b0;
			rgb = 24'd0;
			@(posedge clk);
			#1;
			if (ycc !== {f_cr(p), f_y(p)} || !ycc_de) begin
				errors = errors + 1;
				$display("FAIL atg_dc_ycc: %h second %h", p, ycc);
			end
		end
	endtask

	integer line, x, w, gap;

	initial begin
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		repeat (3) @(posedge clk);
		@(negedge clk);
		checking = 1'b1;
		color(24'hFFFFFF, 235.0, 128.0, 128.0);
		color(24'h000000, 16.0, 128.0, 128.0);
		color(24'hFF0000, 81.481, 90.203, 240.0);
		color(24'h00FF00, 144.553, 53.797, 34.214);
		color(24'h0000FF, 40.966, 240.0, 109.786);
		color(24'h808080, 126.439, 128.0, 128.0);
		pair(24'hFFFFFF);
		pair(24'hFF0000);
		pair(24'h0000FF);
		if (errors == 0)
			$display("PASS atg_dc_ycc.colors");

		for (line = 0; line < 40; line = line + 1) begin
			w = 1 + ($unsigned($random(seed)) % 37);
			gap = 1 + ($unsigned($random(seed)) % 5);
			for (x = 0; x < w; x = x + 1) begin
				@(negedge clk);
				de = 1'b1;
				rgb = $random(seed);
				hs = $random(seed);
				vs = $random(seed);
			end
			for (x = 0; x < gap; x = x + 1) begin
				@(negedge clk);
				de = 1'b0;
				rgb = $random(seed);
				hs = $random(seed);
				vs = $random(seed);
			end
		end
		repeat (4) @(posedge clk);
		if (errors == 0)
			$display("PASS atg_dc_ycc.stream");

		if (errors == 0)
			$display("PASS atg_dc_ycc");
		else
			$display("FAIL atg_dc_ycc: %0d errors", errors);
		$finish;
	end
endmodule

`default_nettype wire
