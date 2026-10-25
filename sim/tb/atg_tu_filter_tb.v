/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_filter_tb: atg_tu_filter against the reference conversion and
 * filter of tools/tumodel.py (sim/vec/tu_filter.txt, tools/tu-vectors.py).
 * Quads go in with random gaps and tr_ready is random (seeded); tr_data,
 * tr_tag and tr_last of every quad are checked in order.  Groups:
 * "nearest" (every byte value in every channel, both formats, texsz,
 * texf, lane masks), "bilinear" (random texels and weights, the end
 * weights 0, 1, 128, 255), "trilinear" (the passes of mip linear and 3D
 * linear filtering, 2 to 4: those with more to follow, H lines, must
 * return nothing, the last the weighted sum), "depth" (D24 and D32F
 * without compare), "compare" (every compare op, both depth formats,
 * references at and next to the texels, NaN, nearest, bilinear and
 * trilinear), "gather" (components of the four texels: colour, depth,
 * compare), "query" (texqlod's two values, texsz.l), "rgb565" (the
 * earlier format 4), "vkformat" (TEX_FORMAT's formats of this path: R8
 * and R8G8, D16 compare, the swizzle, gather through the swizzle).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_filter_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg tc_valid = 1'b0;
	reg [511:0] tc_texels = 0;
	reg [127:0] tc_wts = 0;
	reg [15:0] tc_tag = 0;
	reg [3:0] tc_mask = 0;
	reg [49:0] tc_ctl = 0;
	reg [127:0] tc_value = 0;
	reg tc_last = 1'b0;
	reg tr_ready = 1'b0;
	wire tc_ready, tr_valid, tr_last;
	wire [15:0] tr_tag;
	wire [511:0] tr_data;

	atg_tu_filter dut (.clk(clk), .rst_n(rst_n), .tc_valid(tc_valid), .tc_ready(tc_ready),
		.tc_texels(tc_texels), .tc_wts(tc_wts), .tc_tag(tc_tag), .tc_mask(tc_mask),
		.tc_ctl(tc_ctl), .tc_value(tc_value), .tc_last(tc_last), .tr_valid(tr_valid),
		.tr_ready(tr_ready), .tr_tag(tr_tag), .tr_data(tr_data), .tr_last(tr_last));

	integer fd, code, seed, errs, gerrs, nq, tmo, w;
	reg [8*10-1:0] kind, gname;
	reg [511:0] tex, x_data;
	reg [127:0] wts;
	reg [3:0] mask;
	reg [49:0] ctl;
	reg [127:0] val;
	reg [15:0] tag;
	reg last;

	initial begin
		seed = 1;
		if ($value$plusargs("seed=%d", seed))
			seed = seed + 0;
		errs = 0;
		gerrs = 0;
		nq = 0;
		fd = $fopen("sim/vec/tu_filter.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_tu_filter: no sim/vec/tu_filter.txt");
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
				code = $fscanf(fd, "%h %h %h %h %h\n", tex, wts, mask, ctl, val);
				while (($random(seed) & 3) == 0)
					@(posedge clk);
				tc_valid <= 1'b1;
				tc_texels <= tex;
				tc_wts <= wts;
				tc_mask <= mask;
				tc_ctl <= ctl;
				tc_value <= val;
				tc_tag <= $random(seed);
				tc_last <= $random(seed);
				@(posedge clk);
				while (!tc_ready)
					@(posedge clk);
				tc_valid <= 1'b0;
				tc_texels <= {16{$random(seed)}};
				tc_wts <= {4{$random(seed)}};
				repeat (8) begin
					@(posedge clk);
					if (tr_valid) begin
						$display("FAIL atg_tu_filter: quad %0d: a pass with more to follow returned", nq);
						gerrs = gerrs + 1;
					end
				end
			end else if (kind == "F") begin
				code = $fscanf(fd, "%h %h %h %h %h %h %h %h\n", tex, wts, mask, ctl, val, tag,
					last, x_data);
				while (($random(seed) & 3) == 0)
					@(posedge clk);
				tc_valid <= 1'b1;
				tc_texels <= tex;
				tc_wts <= wts;
				tc_mask <= mask;
				tc_ctl <= ctl;
				tc_value <= val;
				tc_tag <= tag;
				tc_last <= last;
				@(posedge clk);
				while (!tc_ready)
					@(posedge clk);
				tc_valid <= 1'b0;
				tc_texels <= {16{$random(seed)}};
				tc_wts <= {4{$random(seed)}};
				tc_value <= {4{$random(seed)}};
				tmo = 0;
				while (!tr_valid && tmo < 100) begin
					@(posedge clk);
					tmo = tmo + 1;
				end
				while (($random(seed) & 3) == 0)
					@(posedge clk);
				for (w = 0; w < 16; w = w + 1)
					if (tr_data[w*32 +: 32] !== x_data[w*32 +: 32]) begin
						if (gerrs < 10)
							$display("FAIL atg_tu_filter: quad %0d word %0d: %h, model %h",
								nq, w, tr_data[w*32 +: 32], x_data[w*32 +: 32]);
						gerrs = gerrs + 1;
					end
				if (!tr_valid || tr_tag !== tag || tr_last !== last) begin
					$display("FAIL atg_tu_filter: quad %0d: valid %b tag %h last %b, want %h %b",
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
					$display("PASS atg_tu_filter.%0s", gname);
				errs = errs + gerrs;
				gerrs = 0;
			end
		end
		$fclose(fd);
		if (errs == 0 && nq > 600)
			$display("PASS atg_tu_filter");
		else
			$display("FAIL atg_tu_filter: %0d errors, %0d quads", errs, nq);
		$finish;
	end

	initial begin
		#10000000;
		$display("FAIL atg_tu_filter: timeout");
		$finish;
	end
endmodule

`default_nettype wire
