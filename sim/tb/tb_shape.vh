/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * tb_shape.vh: the shape choice of the testbenches that run a harness in
 * the ZYBO's shape and one in the KC705's (atg_top_raster_tb and the
 * like).  Included in the testbench's top module after clk.  +shape=zybo
 * or +shape=kc705 runs that shape only (the short run, sim/run.sh -q): the
 * other harness gets no clock and is not waited for.  No plusarg: both.
 */

	reg [8*8-1:0] shape;
	reg run_zybo = 1'b1;
	reg run_kc705 = 1'b1;
	initial
		if ($value$plusargs("shape=%s", shape)) begin
			run_zybo = shape == "zybo";
			run_kc705 = shape == "kc705";
			$display("+shape=%0s: the other shape is not run", shape);
		end
	wire clk_zybo = clk & run_zybo;
	wire clk_kc705 = clk & run_kc705;
