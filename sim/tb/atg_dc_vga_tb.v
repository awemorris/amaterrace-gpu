/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_vga_tb: random pixels, DE and syncs; each output one cycle later
 * is the channel's top bits in DE and 0 outside, the syncs as given.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_vga_tb;
	reg clk = 1'b0;
	always #5 clk = !clk;

	reg [23:0] rgb = 24'd0;
	reg de = 0, hs = 0, vs = 0;
	wire [4:0] vga_r, vga_b;
	wire [5:0] vga_g;
	wire vga_hs, vga_vs;

	atg_dc_vga dut (
		.clk(clk), .rgb(rgb), .de(de), .hs(hs), .vs(vs),
		.vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b), .vga_hs(vga_hs), .vga_vs(vga_vs)
	);

	integer errors = 0;
	integer i, seed;
	reg [23:0] p_rgb;
	reg p_de, p_hs, p_vs;
	reg [17:0] want, got;

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		for (i = 0; i < 2000; i = i + 1) begin
			@(negedge clk);
			rgb = $random(seed);
			de = $random(seed);
			hs = $random(seed);
			vs = $random(seed);
			p_rgb = rgb;
			p_de = de;
			p_hs = hs;
			p_vs = vs;
			@(posedge clk);
			#1;
			want = {p_de ? {p_rgb[23:19], p_rgb[15:10], p_rgb[7:3]} : 16'd0, p_hs, p_vs};
			got = {vga_r, vga_g, vga_b, vga_hs, vga_vs};
			if (got !== want) begin
				errors = errors + 1;
				if (errors < 10)
					$display("FAIL atg_dc_vga.bits: %h, expected %h", got, want);
			end
		end
		if (errors == 0)
			$display("PASS atg_dc_vga.bits");
		if (errors == 0)
			$display("PASS atg_dc_vga");
		$finish;
	end
endmodule

`default_nettype wire
