/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_irq_tb: IRQ_STATUS set by events (RING_EMPTY by its rising edge),
 * cleared by W1C, set winning over clear; the line follows status and
 * enable one cycle later; IRQ_SET raises SOFT; the core reset clears the
 * status but not the enable.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_irq_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg core_rst_n = 1'b0;
	always #5 clk = !clk;

	reg hcr_we = 0;
	reg [9:0] hcr_widx = 0, hcr_ridx = 0;
	reg [31:0] hcr_wdata = 0, hcr_wmask = 0;
	wire [31:0] hcr_rdata;
	reg [8:0] ev = 9'b000000100;
	wire irq;

	atg_cp_irq dut (
		.clk(clk), .rst_n(rst_n), .core_rst_n(core_rst_n),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx), .hcr_rdata(hcr_rdata), .ev(ev), .irq(irq)
	);

	`include "hcr_snoop.vh"

	integer errors = 0;
	integer e0;
	reg [31:0] v;

	task expect_status;
		input [8*30-1:0] what;
		input [8:0] want;
		begin
			hcr_read(GHCI_IRQ_STATUS[11:0], v);
			if (v !== {23'd0, want}) begin
				errors = errors + 1;
				$display("FAIL atg_cp_irq.%0s: IRQ_STATUS %h, expected %h", what, v, want);
			end
		end
	endtask

	task pulse;
		input [8:0] bits;
		begin
			@(negedge clk);
			ev = (ev & 9'b000000100) | bits;
			@(negedge clk);
			ev = ev & 9'b000000100;
		end
	endtask

	initial begin
		repeat (3) @(posedge clk);
		rst_n = 1;
		core_rst_n = 1;
		@(negedge clk);
		expect_status("w1c", 9'd0);
		pulse(9'b100000011);
		expect_status("w1c", 9'b100000011);
		/* RING_EMPTY: falls, then rises: set once. */
		@(negedge clk);
		ev[2] = 0;
		repeat (2) @(negedge clk);
		expect_status("w1c", 9'b100000011);
		ev[2] = 1;
		repeat (3) @(negedge clk);
		expect_status("w1c", 9'b100000111);
		hcr_write(GHCI_IRQ_STATUS[11:0], 32'h00000003);
		expect_status("w1c", 9'b100000100);
		/* set and clear in one cycle: set. */
		@(negedge clk);
		hcr_we = 1;
		hcr_widx = GHCI_IRQ_STATUS[11:2];
		hcr_wdata = 32'h1FF;
		hcr_wmask = 32'hFFFFFFFF;
		ev[4] = 1;
		@(negedge clk);
		hcr_we = 0;
		ev[4] = 0;
		expect_status("w1c", 9'b000010000);
		/* byte strobes: a write of byte 1 only clears bit 8 only. */
		pulse(9'b100000001);
		hcr_write_m(GHCI_IRQ_STATUS[11:0], 32'h1FF, 32'h0000FF00);
		expect_status("w1c", 9'b000010001);
		if (errors == 0)
			$display("PASS atg_cp_irq.w1c");
		e0 = errors;

		/* line */
		hcr_write(GHCI_IRQ_STATUS[11:0], 32'h1FF);
		hcr_write(GHCI_IRQ_ENABLE[11:0], 32'h00000020);
		@(negedge clk);
		if (irq !== 1'b0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_irq.line: line up without status");
		end
		hcr_write(GHCI_IRQ_SET[11:0], 32'h00000020);
		expect_status("line", 9'b000100000);
		@(negedge clk);
		if (irq !== 1'b1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_irq.line: no line for SOFT");
		end
		pulse(9'b000000010);
		hcr_write(GHCI_IRQ_STATUS[11:0], 32'h00000020);
		@(negedge clk);
		@(negedge clk);
		if (irq !== 1'b0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_irq.line: line up for a masked bit");
		end
		/* The core reset clears the status, not the enable. */
		pulse(9'b000100000);
		@(negedge clk);
		core_rst_n = 0;
		@(negedge clk);
		core_rst_n = 1;
		expect_status("line", 9'd0);
		hcr_read(GHCI_IRQ_ENABLE[11:0], v);
		if (v !== 32'h20) begin
			errors = errors + 1;
			$display("FAIL atg_cp_irq.line: IRQ_ENABLE %h after the core reset", v);
		end
		if (errors == e0)
			$display("PASS atg_cp_irq.line");
		if (errors == 0)
			$display("PASS atg_cp_irq");
		else
			$display("FAIL atg_cp_irq: %0d errors", errors);
		$finish;
	end
endmodule

`default_nettype wire
