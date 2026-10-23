/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_dbg_tb: the debug port against amb_mem: DBG_ADDR starts a read
 * whose word lands in DBG_DATA; DBG_DATA starts a write with its byte
 * strobes; writes while busy are dropped; an error response sets
 * DBG_STATUS.error only; ev_done pulses once per access.
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
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;

	atg_cp_dbg dut (
		.clk(clk), .rst_n(rst_n),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx), .hcr_rdata(hcr_rdata), .ev_done(ev_done), .dbg_busy(dbg_busy),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	amb_mem #(.MEM_WORDS(4096), .ERR_BASE(32'h00008000), .SEED(5)) mem (
		.clk(clk), .rst_n(rst_n),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	`include "hcr_snoop.vh"

	integer errors = 0;
	integer dones = 0;
	integer e0, i;
	reg [31:0] v, st;

	always @(posedge clk)
		if (ev_done)
			dones = dones + 1;

	task wait_idle;
		integer n;
		begin
			n = 0;
			hcr_read(GHCI_DBG_STATUS[11:0], st);
			while (st[0] && n < 200) begin
				@(negedge clk);
				hcr_read(GHCI_DBG_STATUS[11:0], st);
				n = n + 1;
			end
			if (st[0] || dbg_busy) begin
				errors = errors + 1;
				$display("FAIL atg_cp_dbg: stays busy");
			end
		end
	endtask

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
		for (i = 0; i < 128; i = i + 1)
			mem.poke(i * 4, 32'hA5000000 + i);
		repeat (3) @(posedge clk);
		rst_n = 1;
		/* read: every word of two lines. */
		for (i = 0; i < 16; i = i + 1) begin
			hcr_write(GHCI_DBG_ADDR[11:0], i * 4 + 32'h22);
			hcr_read(GHCI_DBG_STATUS[11:0], st);
			expect_eq("read busy", st, 32'd1);
			wait_idle();
			hcr_read(GHCI_DBG_DATA[11:0], v);
			expect_eq("read", v, 32'hA5000000 + i + 8);
		end
		expect_eq("read done pulses", dones, 16);
		if (errors == 0)
			$display("PASS atg_cp_dbg.read");
		e0 = errors;
		/* write: bytes 1 and 3 of word 0x10C. */
		hcr_write(GHCI_DBG_ADDR[11:0], 32'h10C);
		wait_idle();
		hcr_write_m(GHCI_DBG_DATA[11:0], 32'h11223344, 32'hFF00FF00);
		/* A second write while busy is dropped. */
		hcr_write(GHCI_DBG_DATA[11:0], 32'hDEADBEEF);
		wait_idle();
		expect_eq("write", mem.peek(32'h10C), 32'h11003300 | (32'hA5000043 & 32'h00FF00FF));
		expect_eq("write neighbour", mem.peek(32'h108), 32'hA5000042);
		expect_eq("write count", mem.writes, 1);
		if (errors == e0)
			$display("PASS atg_cp_dbg.write");
		e0 = errors;
		/* error: an address the memory refuses. */
		hcr_write(GHCI_DBG_ADDR[11:0], 32'h00009000);
		wait_idle();
		hcr_read(GHCI_DBG_STATUS[11:0], st);
		expect_eq("error status", st, 32'd2);
		hcr_read(GHCI_DBG_DATA[11:0], v);
		expect_eq("error data kept", v, 32'h11003343);
		hcr_write(GHCI_DBG_ADDR[11:0], 32'h0);
		wait_idle();
		hcr_read(GHCI_DBG_STATUS[11:0], st);
		expect_eq("error cleared", st, 32'd0);
		if (errors == e0)
			$display("PASS atg_cp_dbg.error");
		if (errors == 0)
			$display("PASS atg_cp_dbg");
		else
			$display("FAIL atg_cp_dbg: %0d errors", errors);
		$finish;
	end
endmodule

`default_nettype wire
