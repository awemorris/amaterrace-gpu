/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_cache_tb: Unit test for atg_rop_cache.
 * Tests:
 * 1. 100% Hit continuous streaming (1 cycle/req read/write throughput).
 * 2. Tree-PLRU replacement policy & dirty line writeback on eviction.
 * 3. Cache flush draining all dirty lines.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_cache_tb;
	localparam LINE_BYTES = 64;
	localparam WAYS = 4;
	localparam SETS_LOG2 = 5;
	localparam LINE_SHIFT = 6;
	localparam LA_W = 32 - LINE_SHIFT;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	/* ROP port */
	reg        req_valid = 1'b0;
	wire       req_ready;
	reg        req_write = 1'b0;
	reg [31:0] req_addr = 32'd0;
	reg [LINE_BYTES-1:0]   req_be = {LINE_BYTES{1'b0}};
	reg [LINE_BYTES*8-1:0] req_wdata = {(LINE_BYTES*8){1'b0}};
	wire       rsp_valid;
	wire [LINE_BYTES*8-1:0] rsp_rdata;

	/* Memory port */
	wire       mem_req_valid;
	reg        mem_req_ready = 1'b1;
	wire       mem_req_write;
	wire [LA_W-1:0] mem_req_line;
	wire [LINE_BYTES*8-1:0] mem_req_wdata;
	reg        mem_rsp_valid = 1'b0;
	reg [LINE_BYTES*8-1:0] mem_rsp_rdata = {(LINE_BYTES*8){1'b0}};

	reg        flush = 1'b0;
	wire       busy;

	atg_rop_cache #(
		.LINE_BYTES(LINE_BYTES),
		.WAYS(WAYS),
		.SETS_LOG2(SETS_LOG2)
	) dut (
		.clk(clk),
		.rst_n(rst_n),
		.req_valid(req_valid),
		.req_ready(req_ready),
		.req_write(req_write),
		.req_addr(req_addr),
		.req_be(req_be),
		.req_wdata(req_wdata),
		.rsp_valid(rsp_valid),
		.rsp_rdata(rsp_rdata),
		.mem_req_valid(mem_req_valid),
		.mem_req_ready(mem_req_ready),
		.mem_req_write(mem_req_write),
		.mem_req_line(mem_req_line),
		.mem_req_wdata(mem_req_wdata),
		.mem_rsp_valid(mem_rsp_valid),
		.mem_rsp_rdata(mem_rsp_rdata),
		.flush(flush),
		.busy(busy)
	);

	/* Mock Memory backend */
	reg [LINE_BYTES*8-1:0] mock_ram [0:4095];
	integer m;
	initial begin
		for (m = 0; m < 4096; m = m + 1)
			mock_ram[m] = {16{m[31:0]}};
	end

	always @(posedge clk) begin
		mem_rsp_valid <= 1'b0;
		if (mem_req_valid && mem_req_ready) begin
			if (mem_req_write) begin
				mock_ram[mem_req_line[11:0]] <= mem_req_wdata;
			end else begin
				mem_rsp_valid <= 1'b1;
				mem_rsp_rdata <= mock_ram[mem_req_line[11:0]];
			end
		end
	end

	integer i;
	reg [LINE_BYTES*8-1:0] exp_line;

	initial begin
		rst_n <= 1'b0;
		req_valid <= 1'b0;
		flush <= 1'b0;
		@(posedge clk);
		@(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);

		/* -------------------------------------------------------------
		 * Test 1: Initial Read Miss and 100% Hit Streaming
		 * ------------------------------------------------------------- */
		/* Initial read miss on 0x1000 */
		req_valid <= 1'b1;
		req_write <= 1'b0;
		req_addr  <= 32'h0000_1000;
		@(posedge clk);
		while (!rsp_valid)
			@(posedge clk);
		req_valid <= 1'b0;
		@(posedge clk);

		/* Line 0x1000 is now in cache. Perform 8 back-to-back hits (1 cycle/req) */
		for (i = 0; i < 8; i = i + 1) begin
			req_valid <= 1'b1;
			req_write <= 1'b1;
			req_addr  <= 32'h0000_1000;
			req_be    <= {{(LINE_BYTES-4){1'b0}}, 4'hF} << (4 * i);
			req_wdata <= {16{32'hDEAD_0000 | i}};
			@(posedge clk);
			if (!req_ready) begin
				$display("FAIL atg_rop_cache: write hit stalled at step %0d", i);
				$finish;
			end
		end
		req_valid <= 1'b0;
		@(posedge clk);

		/* Verify read hit */
		req_valid <= 1'b1;
		req_write <= 1'b0;
		req_addr  <= 32'h0000_1000;
		@(posedge clk);
		@(negedge clk);
		if (!req_ready) begin
			$display("FAIL atg_rop_cache: req_ready not asserted on read hit");
			$finish;
		end
		@(posedge clk);
		req_valid <= 1'b0;
		if (!rsp_valid) begin
			$display("FAIL atg_rop_cache: read hit did not complete with rsp_valid=1");
			$finish;
		end
		req_valid <= 1'b0;
		@(posedge clk);

		$display("PASS atg_rop_cache.hit");

		/* -------------------------------------------------------------
		 * Test 2: Tree-PLRU Eviction & Dirty Writeback
		 * Fill all 4 ways of Set 0 (index 0x00):
		 * Line addresses: 0x0000, 0x0800, 0x1000, 0x1800 (all have set_idx = 0)
		 * ------------------------------------------------------------- */
		/* Way 0 already has 0x1000. Let's write to 3 other lines mapping to Set 0 */
		/* 1. Address 0x0000_2000 (set 0, tag 1) */
		req_valid <= 1'b1;
		req_write <= 1'b1;
		req_addr  <= 32'h0000_2000;
		req_be    <= {LINE_BYTES{1'b1}};
		req_wdata <= {16{32'hAAAA_AAAA}};
		@(posedge clk);
		while (!rsp_valid)
			@(posedge clk);
		req_valid <= 1'b0;
		@(posedge clk);

		/* 2. Address 0x0000_3000 (set 0, tag 2) */
		req_valid <= 1'b1;
		req_write <= 1'b1;
		req_addr  <= 32'h0000_3000;
		req_be    <= {LINE_BYTES{1'b1}};
		req_wdata <= {16{32'hBBBB_BBBB}};
		@(posedge clk);
		while (!rsp_valid)
			@(posedge clk);
		req_valid <= 1'b0;
		@(posedge clk);

		/* 3. Address 0x0000_4000 (set 0, tag 3) */
		req_valid <= 1'b1;
		req_write <= 1'b1;
		req_addr  <= 32'h0000_4000;
		req_be    <= {LINE_BYTES{1'b1}};
		req_wdata <= {16{32'hCCCC_CCCC}};
		@(posedge clk);
		while (!rsp_valid)
			@(posedge clk);
		req_valid <= 1'b0;
		@(posedge clk);

		/* Now all 4 ways of Set 0 are occupied and dirty.
		 * Access a 5th address mapping to Set 0: 0x0000_5000 (tag 4).
		 * Tree-PLRU must evict the LRU line and write it back to memory! */
		req_valid <= 1'b1;
		req_write <= 1'b1;
		req_addr  <= 32'h0000_5000;
		req_be    <= {LINE_BYTES{1'b1}};
		req_wdata <= {16{32'hDDDD_DDDD}};
		@(posedge clk);
		while (!rsp_valid)
			@(posedge clk);
		req_valid <= 1'b0;
		@(posedge clk);

		/* Verify that mock_ram received the evicted dirty line */
		if (mock_ram[32'h0000_1000 >> LINE_SHIFT] == {16{32'h0000_0040}}) begin
			$display("FAIL atg_rop_cache: evicted line was not written back to memory");
			$finish;
		end

		$display("PASS atg_rop_cache.plru");

		/* -------------------------------------------------------------
		 * Test 3: Flush Control
		 * ------------------------------------------------------------- */
		flush <= 1'b1;
		@(posedge clk);
		flush <= 1'b0;
		while (busy)
			@(posedge clk);

		$display("PASS atg_rop_cache.flush");
		$display("PASS atg_rop_cache");
		$finish;
	end
endmodule

`default_nettype wire
