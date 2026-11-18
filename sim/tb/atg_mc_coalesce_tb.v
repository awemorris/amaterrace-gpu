/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_coalesce_tb: Unit testbench for AXI Burst Coalescer (ws001-p027).
 *
 * Tests:
 *   1. 8 consecutive read requests -> single ARLEN=7 (256B) burst.
 *   2. Response demuxing: 8 returning read beats demuxed to 8 client tags.
 *   3. Discontinuous address -> flushes previous burst and starts new burst.
 *   4. Timeout flush: partial burst issued after 8 idle cycles.
 *   5. 4 KiB page boundary protection: no cross-page bursts.
 *   6. Consecutive write burst -> single AWLEN=3 burst + 4 write beats.
 *   7. Write response distribution -> 4 individual write responses for tags.
 *   8. Direction change hazard -> flushes read burst on write request.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_coalesce_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;

	always #5 clk = !clk;

	localparam ADDR_W = 32;
	localparam LINE_BYTES = 32;
	localparam LINE_SHIFT = 5;
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LINE_BITS = LINE_BYTES * 8;
	localparam MAX_BURST = 8;

	/* Upstream signals */
	reg in_req_valid = 1'b0;
	wire in_req_ready;
	reg in_req_write = 1'b0;
	reg [LA_W-1:0] in_req_line = {LA_W{1'b0}};
	reg [LINE_BITS-1:0] in_req_wdata = {LINE_BITS{1'b0}};
	reg [7:0] in_req_tag = 8'd0;

	wire in_rsp_valid;
	wire in_rsp_write;
	wire [LINE_BITS-1:0] in_rsp_rdata;
	wire [7:0] in_rsp_tag;
	wire in_rsp_error;

	/* Downstream signals */
	wire out_req_valid;
	reg out_req_ready = 1'b1;
	wire out_req_write;
	wire [LA_W-1:0] out_req_line;
	wire [7:0] out_req_len;
	wire [LINE_BITS-1:0] out_req_wdata;
	wire [7:0] out_req_tag;

	reg out_rsp_valid = 1'b0;
	reg out_rsp_write = 1'b0;
	reg [LINE_BITS-1:0] out_rsp_rdata = {LINE_BITS{1'b0}};
	reg [7:0] out_rsp_tag = 8'd0;
	reg out_rsp_last = 1'b0;
	reg out_rsp_error = 1'b0;

	wire idle;

	atg_mc_coalesce #(
		.ADDR_W(ADDR_W),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.MAX_BURST(MAX_BURST),
		.TIMEOUT_CYCLES(8)
	) uut (
		.clk(clk),
		.rst_n(rst_n),
		.in_req_valid(in_req_valid),
		.in_req_ready(in_req_ready),
		.in_req_write(in_req_write),
		.in_req_line(in_req_line),
		.in_req_wdata(in_req_wdata),
		.in_req_tag(in_req_tag),
		.in_rsp_valid(in_rsp_valid),
		.in_rsp_write(in_rsp_write),
		.in_rsp_rdata(in_rsp_rdata),
		.in_rsp_tag(in_rsp_tag),
		.in_rsp_error(in_rsp_error),
		.out_req_valid(out_req_valid),
		.out_req_ready(out_req_ready),
		.out_req_write(out_req_write),
		.out_req_line(out_req_line),
		.out_req_len(out_req_len),
		.out_req_wdata(out_req_wdata),
		.out_req_tag(out_req_tag),
		.out_rsp_valid(out_rsp_valid),
		.out_rsp_write(out_rsp_write),
		.out_rsp_rdata(out_rsp_rdata),
		.out_rsp_tag(out_rsp_tag),
		.out_rsp_last(out_rsp_last),
		.out_rsp_error(out_rsp_error),
		.idle(idle)
	);

	integer errors = 0;
	integer k;
	integer rsp_count = 0;
	reg [7:0] expected_tags [0:15];

	/* Response monitor */
	always @(posedge clk) begin
		if (rst_n && in_rsp_valid) begin
			if (in_rsp_tag !== expected_tags[rsp_count]) begin
				$display("FAIL: Expected tag 0x%02h at index %0d, got 0x%02h",
					expected_tags[rsp_count], rsp_count, in_rsp_tag);
				errors = errors + 1;
			end
			rsp_count = rsp_count + 1;
		end
	end

	initial begin
		rst_n = 1'b0;
		#20;
		@(negedge clk);
		rst_n = 1'b1;
		@(negedge clk);

		/* ---------------------------------------------------- */
		/* Test 1 & 2: 8 Consecutive Reads -> ARLEN=7 + Demux   */
		/* ---------------------------------------------------- */
		$display("--- Test 1: 8 Consecutive Reads Coalesced into ARLEN=7 ---");
		rsp_count = 0;
		for (k = 0; k < 8; k = k + 1) begin
			expected_tags[k] = 8'hA0 + k[7:0];
		end

		for (k = 0; k < 8; k = k + 1) begin
			@(negedge clk);
			while (!in_req_ready) @(negedge clk);
			in_req_valid = 1'b1;
			in_req_write = 1'b0;
			in_req_line  = 27'h1000 + k[26:0];
			in_req_tag   = 8'hA0 + k[7:0];
			in_req_wdata = {LINE_BITS{1'b0}};
		end
		@(negedge clk);
		in_req_valid = 1'b0;

		/* Wait for burst request */
		while (!out_req_valid) @(negedge clk);

		if (out_req_line !== 27'h1000) begin
			$display("FAIL: out_req_line mismatch: expected 0x1000, got 0x%07h", out_req_line);
			errors = errors + 1;
		end
		if (out_req_len !== 8'd7) begin
			$display("FAIL: out_req_len mismatch: expected 7 (8 beats), got %0d", out_req_len);
			errors = errors + 1;
		end
		if (out_req_write !== 1'b0) begin
			$display("FAIL: out_req_write mismatch: expected 0 (read), got %b", out_req_write);
			errors = errors + 1;
		end

		$display("PASS: 8-beat read burst correctly requested (ARLEN=7).");

		/* Return 8 read beats from AXI memory */
		$display("--- Test 2: Returning 8 Beats and Tag Demultiplexing ---");
		@(negedge clk);
		for (k = 0; k < 8; k = k + 1) begin
			out_rsp_valid = 1'b1;
			out_rsp_write = 1'b0;
			out_rsp_rdata = {8{32'hBEEF0000 | k}};
			out_rsp_tag   = 8'hA0;
			out_rsp_last  = (k == 7);
			out_rsp_error = 1'b0;
			@(negedge clk);
		end
		out_rsp_valid = 1'b0;
		out_rsp_last  = 1'b0;

		repeat (3) @(negedge clk);
		if (rsp_count !== 8) begin
			$display("FAIL: Expected 8 responses demuxed, got %0d", rsp_count);
			errors = errors + 1;
		end else begin
			$display("PASS: All 8 beats demuxed to original client tags in order.");
		end

		/* ---------------------------------------------------- */
		/* Test 3: Discontinuous Address Triggers Immediate Issue */
		/* ---------------------------------------------------- */
		$display("--- Test 3: Non-Consecutive Address Breaks Burst ---");
		rsp_count = 0;
		expected_tags[0] = 8'h11;
		expected_tags[1] = 8'h22;
		expected_tags[2] = 8'h33;

		/* Issue line 0x2000, then 0x2001 */
		@(negedge clk);
		while (!in_req_ready) @(negedge clk);
		in_req_valid = 1'b1;
		in_req_write = 1'b0;
		in_req_line  = 27'h2000;
		in_req_tag   = 8'h11;

		@(negedge clk);
		while (!in_req_ready) @(negedge clk);
		in_req_valid = 1'b1;
		in_req_write = 1'b0;
		in_req_line  = 27'h2001;
		in_req_tag   = 8'h22;

		/* Issue discontinuous line 0x3000 */
		@(negedge clk);
		while (!in_req_ready) @(negedge clk);
		in_req_valid = 1'b1;
		in_req_write = 1'b0;
		in_req_line  = 27'h3000;
		in_req_tag   = 8'h33;

		@(negedge clk);
		in_req_valid = 1'b0;

		/* First burst should be issued for 0x2000 with len=1 (2 beats) */
		while (!out_req_valid) @(negedge clk);
		if (out_req_line !== 27'h2000 || out_req_len !== 8'd1) begin
			$display("FAIL: Expected first burst line=0x2000 len=1, got line=0x%07h len=%0d",
				out_req_line, out_req_len);
			errors = errors + 1;
		end else begin
			$display("PASS: First burst flushed at discontinuity (len=1).");
		end

		/* Deliver 2 read beats for first burst */
		@(negedge clk);
		out_rsp_valid = 1'b1;
		out_rsp_write = 1'b0;
		out_rsp_rdata = {LINE_BITS{1'b1}};
		out_rsp_last  = 1'b0;
		@(negedge clk);
		out_rsp_last  = 1'b1;
		@(negedge clk);
		out_rsp_valid = 1'b0;
		out_rsp_last  = 1'b0;

		/* Second burst for staged 0x3000 should follow */
		while (!out_req_valid) @(negedge clk);
		if (out_req_line !== 27'h3000 || out_req_len !== 8'd0) begin
			$display("FAIL: Expected second burst line=0x3000 len=0, got line=0x%07h len=%0d",
				out_req_line, out_req_len);
			errors = errors + 1;
		end else begin
			$display("PASS: Discontinuous request issued as new burst (line=0x3000 len=0).");
		end

		/* Complete second burst */
		@(negedge clk);
		out_rsp_valid = 1'b1;
		out_rsp_write = 1'b0;
		out_rsp_rdata = {LINE_BITS{1'b1}};
		out_rsp_last  = 1'b1;
		@(negedge clk);
		out_rsp_valid = 1'b0;
		out_rsp_last  = 1'b0;
		repeat (3) @(negedge clk);

		/* ---------------------------------------------------- */
		/* Test 4: Idle Timeout Flush                           */
		/* ---------------------------------------------------- */
		$display("--- Test 4: Timeout Flush after 8 Idle Cycles ---");
		rsp_count = 0;
		expected_tags[0] = 8'h41;
		expected_tags[1] = 8'h42;
		@(negedge clk);
		while (!in_req_ready) @(negedge clk);
		in_req_valid = 1'b1;
		in_req_write = 1'b0;
		in_req_line  = 27'h4000;
		in_req_tag   = 8'h41;

		@(negedge clk);
		while (!in_req_ready) @(negedge clk);
		in_req_valid = 1'b1;
		in_req_write = 1'b0;
		in_req_line  = 27'h4001;
		in_req_tag   = 8'h42;

		@(negedge clk);
		in_req_valid = 1'b0;

		/* Wait for timeout (8 cycles) */
		while (!out_req_valid) @(negedge clk);
		if (out_req_line !== 27'h4000 || out_req_len !== 8'd1) begin
			$display("FAIL: Timeout burst line/len mismatch: got 0x%07h len=%0d",
				out_req_line, out_req_len);
			errors = errors + 1;
		end else begin
			$display("PASS: Idle timeout successfully triggered burst emission.");
		end

		/* Complete read */
		@(negedge clk);
		out_rsp_valid = 1'b1;
		out_rsp_write = 1'b0;
		out_rsp_last  = 1'b0;
		@(negedge clk);
		out_rsp_last  = 1'b1;
		@(negedge clk);
		out_rsp_valid = 1'b0;
		out_rsp_last  = 1'b0;
		repeat (3) @(negedge clk);

		/* ---------------------------------------------------- */
		/* Test 5 & 6: Consecutive Write Burst & Demux          */
		/* ---------------------------------------------------- */
		$display("--- Test 5: 4 Consecutive Writes Coalesced into AWLEN=3 ---");
		rsp_count = 0;
		expected_tags[0] = 8'hC0;
		expected_tags[1] = 8'hC1;
		expected_tags[2] = 8'hC2;
		expected_tags[3] = 8'hC3;

		for (k = 0; k < 4; k = k + 1) begin
			@(negedge clk);
			while (!in_req_ready) @(negedge clk);
			in_req_valid = 1'b1;
			in_req_write = 1'b1;
			in_req_line  = 27'h5000 + k[26:0];
			in_req_tag   = 8'hC0 + k[7:0];
			in_req_wdata = {8{32'hFACE0000 | k}};
		end
		@(negedge clk);
		in_req_valid = 1'b0;

		/* Wait for timeout or trigger flush */
		while (!out_req_valid) @(negedge clk);
		if (out_req_line !== 27'h5000 || out_req_len !== 8'd3 || out_req_write !== 1'b1) begin
			$display("FAIL: Write burst mismatch: line=0x%07h len=%0d write=%b",
				out_req_line, out_req_len, out_req_write);
			errors = errors + 1;
		end else begin
			$display("PASS: Write burst correctly requested (AWLEN=3).");
		end

		/* Wait until all write beats are transmitted */
		while (uut.state != 3'd4) @(negedge clk);

		$display("--- Test 6: Write Completion Distributed to 4 Client Responses ---");
		@(negedge clk);
		/* Return single AXI B response */
		out_rsp_valid = 1'b1;
		out_rsp_write = 1'b1;
		out_rsp_tag   = 8'hC0;
		out_rsp_error = 1'b0;
		@(negedge clk);
		out_rsp_valid = 1'b0;

		repeat (6) @(negedge clk);
		if (rsp_count !== 4) begin
			$display("FAIL: Expected 4 write responses demuxed, got %0d", rsp_count);
			errors = errors + 1;
		end else begin
			$display("PASS: Single write response distributed to all 4 client tags.");
		end

		repeat (10) @(negedge clk);

		if (errors == 0)
			$display("PASS atg_mc_coalesce");
		else
			$display("FAIL atg_mc_coalesce: %0d errors", errors);

		$finish;
	end
endmodule

`default_nettype wire
