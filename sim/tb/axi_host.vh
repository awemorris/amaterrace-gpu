/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * axi_host.vh: simulation only.  Tasks that act as the host (the Zynq GP0
 * or a JTAG bridge) on an AXI slave port, included in a testbench module
 * that declares clk and the h_* signals (regs driven by the tasks, wires
 * from the slave) and a variable seed.  Single 32-bit accesses:
 *
 *   host_write(addr, data)       WSTRB 1111
 *   host_write_strb(addr, data, strb)
 *   host_read(addr, data)        data is an output
 *
 * The W beat comes one cycle after AW is offered; BREADY and RREADY are
 * held low for a random 0-2 cycles to exercise the slave's holding.
 */

task host_write_strb;
	input [31:0] addr;
	input [31:0] data;
	input [3:0] strb;
	integer n;
	begin
		@(posedge clk);
		h_awaddr <= addr[16:0];
		h_awid <= h_awid + 1'b1;
		h_awvalid <= 1'b1;
		@(posedge clk);
		while (!h_awready)
			@(posedge clk);
		h_awvalid <= 1'b0;
		h_wdata <= data;
		h_wstrb <= strb;
		h_wlast <= 1'b1;
		h_wvalid <= 1'b1;
		@(posedge clk);
		while (!h_wready)
			@(posedge clk);
		h_wvalid <= 1'b0;
		n = $unsigned($random(seed)) % 3;
		repeat (n)
			@(posedge clk);
		h_bready <= 1'b1;
		@(posedge clk);
		while (!h_bvalid)
			@(posedge clk);
		if (h_bresp != 2'b00 || h_bid != h_awid)
			$display("FAIL host_write: BRESP %b BID %h", h_bresp, h_bid);
		h_bready <= 1'b0;
	end
endtask

task host_write;
	input [31:0] addr;
	input [31:0] data;
	begin
		host_write_strb(addr, data, 4'hF);
	end
endtask

task host_read;
	input [31:0] addr;
	output [31:0] data;
	integer n;
	begin
		@(posedge clk);
		h_araddr <= addr[16:0];
		h_arid <= h_arid + 1'b1;
		h_arlen <= 0;
		h_arvalid <= 1'b1;
		@(posedge clk);
		while (!h_arready)
			@(posedge clk);
		h_arvalid <= 1'b0;
		n = $unsigned($random(seed)) % 3;
		repeat (n)
			@(posedge clk);
		h_rready <= 1'b1;
		@(posedge clk);
		while (!h_rvalid)
			@(posedge clk);
		data = h_rdata;
		if (h_rresp != 2'b00 || !h_rlast || h_rid != h_arid)
			$display("FAIL host_read: RRESP %b RLAST %b RID %h", h_rresp, h_rlast, h_rid);
		h_rready <= 1'b0;
	end
endtask
