/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * hcr_snoop.vh: tasks that drive the HCR snoop bus (spec/README.md) of a
 * CP module, for its unit testbench.  Included inside the testbench module
 * that declares clk, the regs hcr_we/hcr_widx/hcr_wdata/hcr_wmask/hcr_ridx
 * and the wire hcr_rdata.  Writes are one-cycle pulses from a falling
 * edge; a read sets hcr_ridx and samples hcr_rdata 1 ns later.
 */

task hcr_write_m;
	input [11:0] off;
	input [31:0] data;
	input [31:0] mask;
	begin
		@(negedge clk);
		hcr_we = 1'b1;
		hcr_widx = off[11:2];
		hcr_wdata = data;
		hcr_wmask = mask;
		@(negedge clk);
		hcr_we = 1'b0;
	end
endtask

task hcr_write;
	input [11:0] off;
	input [31:0] data;
	hcr_write_m(off, data, 32'hFFFFFFFF);
endtask

task hcr_read;
	input [11:0] off;
	output [31:0] data;
	begin
		hcr_ridx = off[11:2];
		#1;
		data = hcr_rdata;
	end
endtask
