/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_addr_tb: atg_tu_addr against the reference addressing of
 * tools/tumodel.py (sim/vec/tu_addr.txt, tools/tu-vectors.py).  The STATE
 * writes go in between quads; the quads go in with random gaps (seeded)
 * and ta_ready is random, and every ta_* of every quad is checked in
 * order (a mip linear quad has two outputs, both checked).  Groups:
 * "wrap" (texl, texf, texsz on random descriptors, every wrap mode,
 * nearest and bilinear, special coordinates), "lod" (texb: the quad LOD
 * from the derivatives, biases, level counts), "tile" (4x4 tiled levels),
 * "trilinear" (mip linear: the two levels and the weight, one pass when no
 * lane needs a second level), "border" (clamp to border: the border
 * texels' address bit 0, the border colour class), "compare" (depth
 * formats with and without compare: the reference on ta_value, λ 0 for
 * texl and without bias for texb, no filter without compare), "lodclamp"
 * (the sampler's minLod, maxLod and mipLodBias), "gather" (every
 * component, DrefGather, border: the level-0 footprint), "query" (texqlod's
 * values, texsz.l's level count).  The coordinates are 4 words a lane
 * (Dref the fourth).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_addr_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg tx_valid = 1'b0;
	reg [7:0] tx_op = 0;
	reg [3:0] tx_slot = 0, tx_mask = 0;
	reg [511:0] tx_coord = 0;
	reg [15:0] tx_tag = 0;
	reg tx_last = 1'b0;
	reg ta_ready = 1'b0;
	wire tx_ready, ta_valid, ta_last;
	wire [511:0] ta_addr;
	wire [95:0] ta_wts;
	wire [15:0] ta_tag;
	wire [3:0] ta_mask;
	wire [23:0] ta_ctl;
	wire [127:0] ta_value;

	atg_tu_addr dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op),
		.tx_slot(tx_slot), .tx_mask(tx_mask), .tx_coord(tx_coord), .tx_tag(tx_tag),
		.tx_last(tx_last), .ta_valid(ta_valid), .ta_ready(ta_ready), .ta_addr(ta_addr),
		.ta_wts(ta_wts), .ta_tag(ta_tag), .ta_mask(ta_mask), .ta_ctl(ta_ctl),
		.ta_value(ta_value), .ta_last(ta_last));

	integer fd, code, seed, errs, gerrs, nq, tmo, np, ip;
	reg [8*12-1:0] kind, gname;
	reg [8:0] sidx;
	reg [31:0] sval;
	reg [7:0] op;
	reg [3:0] slot, mask;
	reg [15:0] tag;
	reg last;
	reg [511:0] crd;
	reg [511:0] x_addr;
	reg [95:0] x_wts;
	reg [23:0] x_ctl;
	reg [127:0] x_value;

	task check_out;
		integer l, t;
		begin
			#1;	/* after the edge that took the previous output */
			tmo = 0;
			while (!ta_valid && tmo < 1000) begin
				@(posedge clk);
				tmo = tmo + 1;
			end
			while (($random(seed) & 3) == 0)
				@(posedge clk);
			if (!ta_valid) begin
				$display("FAIL atg_tu_addr: quad %0d: no ta_valid", nq);
				gerrs = gerrs + 1;
			end else begin
				/* Texels 1-3 matter only for bilinear quads. */
				for (l = 0; l < 4; l = l + 1)
					for (t = 0; t < 4; t = t + 1)
						if (ta_addr[(l*4+t)*32 +: 32] !== x_addr[(l*4+t)*32 +: 32] &&
						    (t == 0 || x_ctl[0]) && mask[l] && !x_ctl[2]) begin
							if (gerrs < 10)
								$display("FAIL atg_tu_addr: quad %0d lane %0d texel %0d: %h, model %h",
									nq, l, t, ta_addr[(l*4+t)*32 +: 32],
									x_addr[(l*4+t)*32 +: 32]);
							gerrs = gerrs + 1;
						end
				for (l = 0; l < 4; l = l + 1)
					if (mask[l] && (ta_wts[l*24 +: 24] !== x_wts[l*24 +: 24] ||
					    ta_value[l*32 +: 32] !== x_value[l*32 +: 32])) begin
						if (gerrs < 10)
							$display("FAIL atg_tu_addr: quad %0d lane %0d: wts %h value %h, model %h %h",
								nq, l, ta_wts[l*24 +: 24], ta_value[l*32 +: 32],
								x_wts[l*24 +: 24], x_value[l*32 +: 32]);
						gerrs = gerrs + 1;
					end
				if (ta_ctl !== x_ctl || ta_tag !== tag || ta_mask !== mask || ta_last !== last) begin
					if (gerrs < 10)
						$display("FAIL atg_tu_addr: quad %0d: ctl %h tag %h mask %h last %b, model %h %h %h %b",
							nq, ta_ctl, ta_tag, ta_mask, ta_last, x_ctl, tag, mask, last);
					gerrs = gerrs + 1;
				end
			end
			ta_ready <= 1'b1;
			@(posedge clk);
			ta_ready <= 1'b0;
		end
	endtask

	initial begin
		seed = 1;
		if ($value$plusargs("seed=%d", seed))
			seed = seed + 0;
		errs = 0;
		gerrs = 0;
		nq = 0;
		fd = $fopen("sim/vec/tu_addr.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_tu_addr: no sim/vec/tu_addr.txt");
			$finish;
		end
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		while (!$feof(fd)) begin
			code = $fscanf(fd, "%s", kind);
			if (code != 1) begin
				/* end of file */
			end else if (kind == "S") begin
				code = $fscanf(fd, "%h %h\n", sidx, sval);
				st_we <= 1'b1;
				st_idx <= sidx;
				st_wdata <= sval;
				@(posedge clk);
				st_we <= 1'b0;
			end else if (kind == "Q") begin
				code = $fscanf(fd, "%h %h %h %h %h %h %h\n", op, slot, mask, tag, last, crd, np);
				while (($random(seed) & 3) == 0)
					@(posedge clk);
				tx_valid <= 1'b1;
				tx_op <= op;
				tx_slot <= slot;
				tx_mask <= mask;
				tx_coord <= crd;
				tx_tag <= tag;
				tx_last <= last;
				@(posedge clk);
				while (!tx_ready)
					@(posedge clk);
				tx_valid <= 1'b0;
				/* Scramble the inputs once taken (they must have been latched). */
				tx_coord <= {16{$random(seed)}};
				tx_slot <= $random(seed);
				for (ip = 0; ip < np; ip = ip + 1) begin
					code = $fscanf(fd, "%s %h %h %h %h\n", kind, x_addr, x_wts, x_ctl, x_value);
					check_out;
				end
				nq = nq + 1;
			end else if (kind == "P") begin
				code = $fscanf(fd, "%s\n", gname);
				if (gerrs == 0)
					$display("PASS atg_tu_addr.%0s", gname);
				errs = errs + gerrs;
				gerrs = 0;
			end
		end
		$fclose(fd);
		if (errs == 0 && nq > 1000)
			$display("PASS atg_tu_addr");
		else
			$display("FAIL atg_tu_addr: %0d errors, %0d quads", errs, nq);
		$finish;
	end

	initial begin
		#50000000;
		$display("FAIL atg_tu_addr: timeout");
		$finish;
	end
endmodule

`default_nettype wire
