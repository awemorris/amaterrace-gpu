/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_filter_tb: atg_tu_filter against the reference conversion and
 * filter of tools/tumodel.py (sim/vec/tu_filter.txt, tools/tu-vectors.py).
 * Passes go in as soon as they are taken, with random gaps, and tr_ready
 * is random (seeded), sometimes low for 40 cycles (the unit keeps several
 * quads); tr_data, tr_tag and tr_last of every quad are checked in order
 * (a pass with more to follow must return nothing: a return without one
 * expected fails).  Groups:
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
		.tc_ctl(tc_ctl), .tc_value(tc_value), .tc_last(tc_last), .idle(), .tr_valid(tr_valid),
		.tr_ready(tr_ready), .tr_tag(tr_tag), .tr_data(tr_data), .tr_last(tr_last));

	integer fd, code, seed, errs, nq, nr, ng, w, j, stall, c0, c1;
	reg [8*10-1:0] kind, gname;
	reg [511:0] tex, x_data;
	reg [127:0] wts;
	reg [3:0] mask;
	reg [49:0] ctl;
	reg [127:0] val;
	reg [15:0] tag;
	reg last;
	/* The quads expected in order (their group), the groups' names and
	 * errors. */
	reg [511:0] e_data [0:4095];
	reg [15:0] e_tag [0:4095];
	reg e_last [0:4095];
	reg [7:0] e_grp [0:4095];
	reg [8*10-1:0] g_name [0:63];
	integer g_err [0:63];
	reg done = 1'b0;
	integer cyc = 0;

	initial begin
		seed = 1;
		if ($value$plusargs("seed=%d", seed))
			seed = seed + 0;
		errs = 0;
		nq = 0;
		ng = 0;
		for (j = 0; j < 64; j = j + 1)
			g_err[j] = 0;
		fd = $fopen("sim/vec/tu_filter.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_tu_filter: no sim/vec/tu_filter.txt");
			$finish;
		end
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		c0 = cyc;
		/* The passes go in as soon as they are taken (random gaps); the
		 * results are checked in order by the block below. */
		while (!$feof(fd)) begin
			code = $fscanf(fd, "%s", kind);
			if (code != 1) begin
				/* end of file */
			end else if (kind == "H" || kind == "F") begin
				if (kind == "H") begin
					/* A first level: taken, nothing returned. */
					code = $fscanf(fd, "%h %h %h %h %h\n", tex, wts, mask, ctl, val);
					tag = $random(seed);
					last = $random(seed);
				end else begin
					code = $fscanf(fd, "%h %h %h %h %h %h %h %h\n", tex, wts, mask, ctl, val,
						tag, last, x_data);
					e_data[nq] = x_data;
					e_tag[nq] = tag;
					e_last[nq] = last;
					e_grp[nq] = ng;
					nq = nq + 1;
				end
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
			end else if (kind == "P") begin
				code = $fscanf(fd, "%s\n", gname);
				g_name[ng] = gname;
				ng = ng + 1;
			end
		end
		$fclose(fd);
		j = 0;
		while (nr < nq && j < 2000) begin
			@(posedge clk);
			j = j + 1;
		end
		c1 = cyc;
		repeat (50)
			@(posedge clk);
		done = 1'b1;
		for (j = 0; j < ng; j = j + 1) begin
			if (g_err[j] == 0)
				$display("PASS atg_tu_filter.%0s", g_name[j]);
			errs = errs + g_err[j];
		end
		$display("INFO atg_tu_filter: %0d quads in %0d cycles (streamed)", nq, c1 - c0);
		if (errs == 0 && nq > 600 && nr == nq)
			$display("PASS atg_tu_filter");
		else
			$display("FAIL atg_tu_filter: %0d errors, %0d quads, %0d returned", errs, nq, nr);
		$finish;
	end

	/* The returns: tr_ready random, sometimes held low for a while (the
	 * FIFO and the credits); each checked against the next expected. */
	initial begin
		nr = 0;
		stall = 0;
	end
	always @(posedge clk) begin
		cyc = cyc + 1;
		if (tr_valid && tr_ready) begin
			if (nr >= nq || done) begin
				$display("FAIL atg_tu_filter: a return with none expected (a pass with more to follow?)");
				g_err[ng] = g_err[ng] + 1;
			end else begin
				for (w = 0; w < 16; w = w + 1)
					if (tr_data[w*32 +: 32] !== e_data[nr][w*32 +: 32]) begin
						if (g_err[e_grp[nr]] < 10)
							$display("FAIL atg_tu_filter: quad %0d word %0d: %h, model %h",
								nr, w, tr_data[w*32 +: 32], e_data[nr][w*32 +: 32]);
						g_err[e_grp[nr]] = g_err[e_grp[nr]] + 1;
					end
				if (tr_tag !== e_tag[nr] || tr_last !== e_last[nr]) begin
					$display("FAIL atg_tu_filter: quad %0d: tag %h last %b, want %h %b",
						nr, tr_tag, tr_last, e_tag[nr], e_last[nr]);
					g_err[e_grp[nr]] = g_err[e_grp[nr]] + 1;
				end
			end
			nr = nr + 1;
		end
		if (stall > 0) begin
			stall = stall - 1;
			tr_ready <= 1'b0;
		end else if (($random(seed) & 63) == 0) begin
			stall = 40;
			tr_ready <= 1'b0;
		end else
			tr_ready <= ($random(seed) & 3) != 0;
	end

	initial begin
		#10000000;
		$display("FAIL atg_tu_filter: timeout");
		$finish;
	end
endmodule

`default_nettype wire
