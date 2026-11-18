/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_dbg_tb: testbench for atg_cp_dbg in GHCI 1.0 architecture.
 *
 * In GHCI 1.0 (docs/ghci.md), the debug bridge is outside the host bus
 * (capability ID 2: DBG). The host MMIO registers (0x0A0..0x0A8) are unmapped.
 * Verifies that host MMIO reads return 0, host writes are dropped, and
 * the bridge/memory client interface ports remain idle and quiescent.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_dbg_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg hcr_we = 0;
	reg [9:0] hcr_widx = 0, hcr_ridx = 0;
	reg [31:0] hcr_wdata = 0, hcr_wmask = 0;
	wire [31:0] hcr_rdata;
	wire ev_done, dbg_busy;
	wire req_valid, req_ready, req_write;
	reg rsp_valid = 0, rsp_write = 0, rsp_error = 0;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata;
	reg [255:0] rsp_rdata = 0;
	wire [7:0] req_tag;
	reg [7:0] rsp_tag = 0;

	atg_cp_dbg dut (
		.clk(clk), .rst_n(rst_n),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx), .hcr_rdata(hcr_rdata), .ev_done(ev_done), .dbg_busy(dbg_busy),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	assign req_ready = 1'b1;

	`include "hcr_snoop.vh"

	integer errors = 0;
	integer e0, i;
	reg [31:0] v;

	task expect_eq;
		input [8*40-1:0] what;
		input [31:0] got;
		input [31:0] want;
		if (got !== want) begin
			errors = errors + 1;
			$display("FAIL atg_cp_dbg.%0s: %h, expected %h", what, got, want);
		end
	endtask

	initial begin
		repeat (3) @(posedge clk);
		rst_n = 1;
		@(posedge clk);

		/* 1. Host MMIO reads to legacy DBG addresses must return 0 (unmapped). */
		e0 = errors;
		hcr_read(GHCI_DBG_ADDR[11:0], v);
		expect_eq("unmapped addr read", v, 32'd0);
		hcr_read(GHCI_DBG_DATA[11:0], v);
		expect_eq("unmapped data read", v, 32'd0);
		hcr_read(GHCI_DBG_STATUS[11:0], v);
		expect_eq("unmapped status read", v, 32'd0);

		/* Host MMIO writes to legacy DBG addresses must be dropped (no busy, no req). */
		for (i = 0; i < 4; i = i + 1) begin
			hcr_write(GHCI_DBG_ADDR[11:0], 32'h00001000 + i * 4);
			expect_eq("write dropped busy", dbg_busy, 1'b0);
			expect_eq("write dropped req_valid", req_valid, 1'b0);
			hcr_write(GHCI_DBG_DATA[11:0], 32'hA5A50000 + i);
			expect_eq("data write dropped busy", dbg_busy, 1'b0);
			expect_eq("data write dropped req_valid", req_valid, 1'b0);
		end
		if (errors == e0)
			$display("PASS atg_cp_dbg.unmapped");

		/* 2. Bridge side and client interface ports stay idle and quiescent. */
		e0 = errors;
		repeat (5) @(posedge clk);
		expect_eq("quiescent req_valid", req_valid, 1'b0);
		expect_eq("quiescent dbg_busy", dbg_busy, 1'b0);
		expect_eq("quiescent ev_done", ev_done, 1'b0);

		/* Unsolicited memory responses while idle must not trigger events. */
		rsp_valid = 1;
		rsp_write = 0;
		rsp_tag = 8'd0;
		rsp_rdata = 256'hDEADBEEF;
		rsp_error = 0;
		@(posedge clk);
		rsp_valid = 0;
		expect_eq("idle rsp ev_done", ev_done, 1'b0);
		expect_eq("idle rsp dbg_busy", dbg_busy, 1'b0);

		rsp_valid = 1;
		rsp_error = 1;
		@(posedge clk);
		rsp_valid = 0;
		rsp_error = 0;
		expect_eq("idle err rsp ev_done", ev_done, 1'b0);
		expect_eq("idle err rsp dbg_busy", dbg_busy, 1'b0);

		/* Reset assertion keeps ports safe and quiescent. */
		rst_n = 0;
		@(posedge clk);
		expect_eq("reset dbg_busy", dbg_busy, 1'b0);
		expect_eq("reset req_valid", req_valid, 1'b0);
		expect_eq("reset ev_done", ev_done, 1'b0);
		rst_n = 1;
		@(posedge clk);

		if (errors == e0)
			$display("PASS atg_cp_dbg.bridge");

		if (errors == 0)
			$display("PASS atg_cp_dbg");
		else
			$display("FAIL atg_cp_dbg: %0d errors", errors);
		$finish;
	end
endmodule

`default_nettype wire
