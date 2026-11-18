/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_irq_tb: IRQ_STATUS set by events (FENCE, FAULT, WATCHDOG, DISPLAY, HALTED),
 * cleared by W1C, set winning over clear; the line follows status and
 * enable one cycle later; IRQ_SET raises SOFT; the core reset clears the
 * status but not the enable. Ring becoming empty does not affect IRQ_STATUS.
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
	reg [6:0] ev = 7'b0;
	reg ctrl_irq_global = 1'b1;
	wire irq;

	atg_cp_irq dut (
		.clk(clk), .rst_n(rst_n), .core_rst_n(core_rst_n),
		.ctrl_irq_global(ctrl_irq_global),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx), .hcr_rdata(hcr_rdata), .ev(ev), .irq(irq)
	);

	`include "hcr_snoop.vh"

	integer errors = 0;
	integer e0;
	reg [31:0] v;

	task expect_status;
		input [8*30-1:0] what;
		input [6:0] want;
		begin
			hcr_read(GHCI_REG_IRQ_STATUS[11:0], v);
			if (v !== {25'd0, want}) begin
				errors = errors + 1;
				$display("FAIL atg_cp_irq.%0s: IRQ_STATUS %h, expected %h", what, v, want);
			end
		end
	endtask

	task pulse;
		input [6:0] bits;
		begin
			@(negedge clk);
			ev = bits;
			@(negedge clk);
			ev = 7'd0;
		end
	endtask

	reg ring_empty = 1'b1;

	initial begin
		repeat (3) @(posedge clk);
		rst_n = 1;
		core_rst_n = 1;
		@(negedge clk);
		expect_status("w1c", 7'd0);

		/* Ring becoming empty does not change IRQ_STATUS */
		ring_empty = 1'b0;
		@(negedge clk);
		ring_empty = 1'b1;
		repeat (3) @(negedge clk);
		expect_status("ring_empty", 7'd0);

		/* Watchdog assertion sets IRQ_STATUS == 0x00000004 (bit 2) */
		pulse(7'b0000100);
		expect_status("watchdog", 7'h04);
		hcr_write(GHCI_REG_IRQ_STATUS[11:0], 32'h00000004);
		expect_status("w1c_wdt", 7'd0);

		/* DISP2 event sets IRQ_STATUS[3] == 1 */
		pulse(7'b0001000);
		expect_status("disp2", 7'h08);
		hcr_write(GHCI_REG_IRQ_STATUS[11:0], 32'h00000008);
		expect_status("w1c_disp", 7'd0);

		/* IRQ_SET[5] sets IRQ_STATUS == 0x00000020 */
		hcr_write(GHCI_REG_IRQ_SET[11:0], 32'h00000020);
		expect_status("soft_set", 7'h20);
		hcr_write(GHCI_REG_IRQ_STATUS[11:0], 32'h00000020);
		expect_status("w1c_soft", 7'd0);

		/* FENCE and FAULT events */
		pulse(7'b0000011);
		expect_status("w1c", 7'b0000011);
		pulse(7'b0000100);
		expect_status("w1c", 7'b0000111);
		hcr_write(GHCI_REG_IRQ_STATUS[11:0], 32'h00000003);
		expect_status("w1c", 7'b0000100);

		/* Set and clear in one cycle: set wins */
		@(negedge clk);
		hcr_we = 1;
		hcr_widx = GHCI_REG_IRQ_STATUS[11:2];
		hcr_wdata = 32'h7F;
		hcr_wmask = 32'hFFFFFFFF;
		ev[1] = 1;
		@(negedge clk);
		hcr_we = 0;
		ev[1] = 0;
		expect_status("w1c_set_wins", 7'b0000010);

		/* Byte strobes: a write of byte 0 only clears bit 1 */
		pulse(7'b0000001);
		expect_status("w1c_pulse1", 7'b0000011);
		hcr_write_m(GHCI_REG_IRQ_STATUS[11:0], 32'h02, 32'h000000FF);
		expect_status("w1c_byte_clr", 7'b0000001);
		hcr_write(GHCI_REG_IRQ_STATUS[11:0], 32'h01);
		expect_status("w1c_clr_all", 7'd0);

		/* Reserved bits (bit 4, bits 7..31) cannot be set and read 0 */
		hcr_write(GHCI_REG_IRQ_STATUS[11:0], 32'hFFFFFFFF);
		expect_status("reserved_zero", 7'd0);

		if (errors == 0)
			$display("PASS atg_cp_irq.w1c");
		e0 = errors;

		/* Line tests */
		hcr_write(GHCI_REG_IRQ_STATUS[11:0], 32'h7F);
		hcr_write(GHCI_REG_IRQ_ENABLE[11:0], 32'h00000020);
		@(negedge clk);
		if (irq !== 1'b0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_irq.line: line up without status");
		end
		hcr_write(GHCI_REG_IRQ_SET[11:0], 32'h00000020);
		expect_status("line_soft", 7'b0100000);
		@(negedge clk);
		if (irq !== 1'b1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_irq.line: no line for SOFT");
		end
		pulse(7'b0000010);
		hcr_write(GHCI_REG_IRQ_STATUS[11:0], 32'h00000020);
		@(negedge clk);
		@(negedge clk);
		if (irq !== 1'b0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_irq.line: line up for a masked bit");
		end

		/* DISPLAY (bit 3) enabled raises the line */
		hcr_write(GHCI_REG_IRQ_STATUS[11:0], 32'h7F);
		hcr_write(GHCI_REG_IRQ_ENABLE[11:0], 32'h00000008);
		pulse(7'b0001000);
		@(negedge clk);
		if (irq !== 1'b1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_irq.line: no line for DISPLAY");
		end
		hcr_write(GHCI_REG_IRQ_STATUS[11:0], 32'h00000008);
		hcr_write(GHCI_REG_IRQ_ENABLE[11:0], 32'h00000020);
		@(negedge clk);
		@(negedge clk);
		if (irq !== 1'b0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_irq.line: line up for a masked bit");
		end

		/* IRQ_GLOBAL master enable check:
		 * Even if IRQ_STATUS & IRQ_ENABLE != 0, if IRQ_GLOBAL == 0 then irq == 0. When IRQ_GLOBAL == 1, irq == 1. */
		hcr_write(GHCI_REG_IRQ_STATUS[11:0], 32'h7F);
		hcr_write(GHCI_REG_IRQ_ENABLE[11:0], 32'h00000020);
		hcr_write(GHCI_REG_IRQ_SET[11:0], 32'h00000020);
		expect_status("global_soft", 7'h20);
		@(negedge clk);
		if (irq !== 1'b1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_irq.global: irq not 1 when IRQ_GLOBAL == 1");
		end
		ctrl_irq_global = 1'b0;
		@(negedge clk);
		if (irq !== 1'b0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_irq.global: irq not 0 when IRQ_GLOBAL == 0");
		end
		ctrl_irq_global = 1'b1;
		@(negedge clk);
		if (irq !== 1'b1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_irq.global: irq not restored when IRQ_GLOBAL == 1");
		end

		/* The core reset clears the status, not the enable */
		hcr_write(GHCI_REG_IRQ_SET[11:0], 32'h00000020);
		expect_status("line_before_rst", 7'h20);
		@(negedge clk);
		core_rst_n = 0;
		@(negedge clk);
		core_rst_n = 1;
		expect_status("line_rst", 7'd0);
		hcr_read(GHCI_REG_IRQ_ENABLE[11:0], v);
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
