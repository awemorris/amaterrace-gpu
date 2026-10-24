/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_ffilt_tb: atg_tu_ffilt, the fp32 path, against tools/tumodel.py
 * (FFilter; sim/vec/tu_ffilt.txt, tools/tu-vectors.py).
 * Quads go in with random gaps and tr_ready is random (seeded); tr_data,
 * tr_tag and tr_last of every quad are checked in order.  Groups (each
 * over every sampled format of the path, with random swizzles, border
 * texels, masks): "nearest" (one pass, texel 0 as converted), "bilinear"
 * (the formats with FILTER_LINEAR; 8-byte texels in two row passes),
 * "passes" (mip linear and 3D linear: 2 to 8 passes, those with more to
 * follow must return nothing), "gather" (the component through the
 * swizzle, the word of 8- and 16-byte texels), "border" (half the texels
 * border texels, every colour class).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_ffilt_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg tc_valid = 1'b0;
	reg [511:0] tc_texels = 0;
	reg [15:0] tc_bord = 0;
	reg [127:0] tc_wts = 0;
	reg [15:0] tc_tag = 0;
	reg [3:0] tc_mask = 0;
	reg [47:0] tc_ctl = 0;
	reg tc_last = 1'b0;
	reg tr_ready = 1'b0;
	wire tc_ready, tr_valid, tr_last;
	wire [15:0] tr_tag;
	wire [511:0] tr_data;

	atg_tu_ffilt dut (.clk(clk), .rst_n(rst_n), .tc_valid(tc_valid), .tc_ready(tc_ready),
		.tc_texels(tc_texels), .tc_bord(tc_bord), .tc_wts(tc_wts), .tc_tag(tc_tag), .tc_mask(tc_mask),
		.tc_ctl(tc_ctl), .tc_last(tc_last), .tr_valid(tr_valid),
		.tr_ready(tr_ready), .tr_tag(tr_tag), .tr_data(tr_data), .tr_last(tr_last));

	integer fd, code, seed, errs, gerrs, nq, tmo, w;
	reg [8*10-1:0] kind, gname;
	reg [511:0] tex, x_data;
	reg [127:0] wts;
	reg [3:0] mask;
	reg [47:0] ctl;
	reg [15:0] bord;
	reg [15:0] tag;
	reg last;

	initial begin
		seed = 1;
		if ($value$plusargs("seed=%d", seed))
			seed = seed + 0;
		errs = 0;
		gerrs = 0;
		nq = 0;
		fd = $fopen("sim/vec/tu_ffilt.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_tu_ffilt: no sim/vec/tu_ffilt.txt");
			$finish;
		end
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		while (!$feof(fd)) begin
			code = $fscanf(fd, "%s", kind);
			if (code != 1) begin
				/* end of file */
			end else if (kind == "H") begin
				/* A first level: taken, nothing returned. */
				code = $fscanf(fd, "%h %h %h %h %h\n", tex, bord, wts, mask, ctl);
				while (($random(seed) & 3) == 0)
					@(posedge clk);
				tc_valid <= 1'b1;
				tc_texels <= tex;
				tc_wts <= wts;
				tc_mask <= mask;
				tc_ctl <= ctl;
				tc_bord <= bord;
				tc_tag <= $random(seed);
				tc_last <= $random(seed);
				@(posedge clk);
				while (!tc_ready)
					@(posedge clk);
				tc_valid <= 1'b0;
				tc_texels <= {16{$random(seed)}};
				tc_wts <= {4{$random(seed)}};
				repeat (80) begin
					@(posedge clk);
					if (tr_valid) begin
						$display("FAIL atg_tu_ffilt: quad %0d: a pass with more to follow returned", nq);
						gerrs = gerrs + 1;
					end
				end
			end else if (kind == "F") begin
				code = $fscanf(fd, "%h %h %h %h %h %h %h %h\n", tex, bord, wts, mask, ctl, tag,
					last, x_data);
				while (($random(seed) & 3) == 0)
					@(posedge clk);
				tc_valid <= 1'b1;
				tc_texels <= tex;
				tc_wts <= wts;
				tc_mask <= mask;
				tc_ctl <= ctl;
				tc_bord <= bord;
				tc_tag <= tag;
				tc_last <= last;
				@(posedge clk);
				while (!tc_ready)
					@(posedge clk);
				tc_valid <= 1'b0;
				tc_texels <= {16{$random(seed)}};
				tc_wts <= {4{$random(seed)}};
				tc_bord <= $random(seed);
				tmo = 0;
				while (!tr_valid && tmo < 1000) begin
					@(posedge clk);
					tmo = tmo + 1;
				end
				while (($random(seed) & 3) == 0)
					@(posedge clk);
				for (w = 0; w < 16; w = w + 1)
					if (tr_data[w*32 +: 32] !== x_data[w*32 +: 32]) begin
						if (gerrs < 10)
							$display("FAIL atg_tu_ffilt: quad %0d word %0d: %h, model %h",
								nq, w, tr_data[w*32 +: 32], x_data[w*32 +: 32]);
						gerrs = gerrs + 1;
					end
				if (!tr_valid || tr_tag !== tag || tr_last !== last) begin
					$display("FAIL atg_tu_ffilt: quad %0d: valid %b tag %h last %b, want %h %b",
						nq, tr_valid, tr_tag, tr_last, tag, last);
					gerrs = gerrs + 1;
				end
				tr_ready <= 1'b1;
				@(posedge clk);
				tr_ready <= 1'b0;
				nq = nq + 1;
			end else if (kind == "P") begin
				code = $fscanf(fd, "%s\n", gname);
				if (gerrs == 0)
					$display("PASS atg_tu_ffilt.%0s", gname);
				errs = errs + gerrs;
				gerrs = 0;
			end
		end
		$fclose(fd);
		if (errs == 0 && nq > 400)
			$display("PASS atg_tu_ffilt");
		else
			$display("FAIL atg_tu_ffilt: %0d errors, %0d quads", errs, nq);
		$finish;
	end

	initial begin
		#50000000;
		$display("FAIL atg_tu_ffilt: timeout");
		$finish;
	end
endmodule

`default_nettype wire
