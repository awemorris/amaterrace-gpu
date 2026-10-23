/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_regs_tb: every DISP register (read back, strobes, the outputs to
 * the DMA and the timing generator), the standalone GHCI header and its
 * EXTCAP entry, the KC705 window at BASE, the interrupt status (events,
 * W1C, the line), the flip at vsync, FRAME_COUNT, the sticky underflow and
 * CTRL.RESET.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_regs_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg reg_wr = 0, reg_rd = 0;
	reg [16:0] reg_waddr = 0, reg_raddr = 0;
	reg [31:0] reg_wdata = 0;
	reg [3:0] reg_wstrb = 4'hF;
	wire [31:0] rdata_s, rdata_k;
	reg ev_vsync = 0, ev_flip = 0, ev_underflow = 0, dma_idle = 1;
	reg [11:0] line = 12'd0;
	reg [31:0] scan_sum = 32'h12345678, scan_words = 32'd307200;

	wire enable, test_pattern, pclk_sel, dc_reset, irq;
	wire [1:0] format;
	wire [31:0] fb_next, fb_stride, fb_size, fb_base;
	wire [287:0] timing;
	wire i2c_we;
	wire [1:0] i2c_idx;
	wire [31:0] i2c_wdata;

	/* The ZYBO's standalone device (checked in detail). */
	atg_dc_regs #(.STANDALONE(1)) dut (
		.clk(clk), .rst_n(rst_n),
		.reg_wr(reg_wr), .reg_waddr(reg_waddr), .reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd), .reg_raddr(reg_raddr), .reg_rdata(rdata_s),
		.enable(enable), .test_pattern(test_pattern), .format(format), .fb_next(fb_next),
		.fb_stride(fb_stride), .fb_size(fb_size), .timing(timing), .pclk_sel(pclk_sel),
		.dc_reset(dc_reset),
		.ev_vsync(ev_vsync), .ev_flip(ev_flip), .ev_underflow(ev_underflow),
		.dma_idle(dma_idle), .line(line), .scan_sum(scan_sum), .scan_words(scan_words),
		.fb_base(fb_base), .irq(irq),
		.i2c_we(i2c_we), .i2c_idx(i2c_idx), .i2c_wdata(i2c_wdata), .i2c_rdata(32'hA5A5A5A5)
	);

	/* The KC705's window at BASE with the I2C master (decode only). */
	wire [31:0] unused_k_bus;
	atg_dc_regs #(.STANDALONE(0), .BASE(17'h10000), .HAS_I2C(1)) kc (
		.clk(clk), .rst_n(rst_n),
		.reg_wr(reg_wr), .reg_waddr(reg_waddr), .reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd), .reg_raddr(reg_raddr), .reg_rdata(rdata_k),
		.enable(), .test_pattern(), .format(), .fb_next(), .fb_stride(), .fb_size(),
		.timing(), .pclk_sel(), .dc_reset(),
		.ev_vsync(1'b0), .ev_flip(1'b0), .ev_underflow(1'b0), .dma_idle(1'b1),
		.line(12'd0), .scan_sum(32'd0), .scan_words(32'd0), .fb_base(), .irq(),
		.i2c_we(), .i2c_idx(), .i2c_wdata(), .i2c_rdata(32'hC3C3C3C3)
	);

	/* The KC705 instance's I2C write strobe. */
	reg saw_i2c = 0;
	integer errors = 0;
	integer e0, k, n;
	reg [31:0] v;
	localparam [16:0] D = GHCI_DC_STANDALONE_DISP;

	task wr;
		input [16:0] addr;
		input [31:0] data;
		begin
			@(negedge clk);
			reg_wr = 1;
			reg_waddr = addr;
			reg_wdata = data;
			@(negedge clk);
			reg_wr = 0;
			reg_wstrb = 4'hF;
		end
	endtask

	task rd;
		input [16:0] addr;
		output [31:0] data;
		begin
			@(negedge clk);
			reg_rd = 1;
			reg_raddr = addr;
			@(negedge clk);
			reg_rd = 0;
			data = rdata_s;
		end
	endtask

	task rd_k;
		input [16:0] addr;
		output [31:0] data;
		begin
			@(negedge clk);
			reg_rd = 1;
			reg_raddr = addr;
			@(negedge clk);
			reg_rd = 0;
			data = rdata_k;
		end
	endtask

	task check;
		input [8*40-1:0] what;
		input [31:0] got;
		input [31:0] want;
		begin
			if (got !== want) begin
				errors = errors + 1;
				$display("FAIL atg_dc_regs.%0s: %h, expected %h", what, got, want);
			end
		end
	endtask

	task expect_reg;
		input [8*40-1:0] what;
		input [16:0] addr;
		input [31:0] want;
		begin
			rd(addr, v);
			check(what, v, want);
		end
	endtask

	task pulse_ev;
		input vs, fl, uf;
		begin
			@(negedge clk);
			ev_vsync = vs;
			ev_flip = fl;
			ev_underflow = uf;
			@(negedge clk);
			ev_vsync = 0;
			ev_flip = 0;
			ev_underflow = 0;
		end
	endtask

	initial begin
		repeat (3) @(posedge clk);
		rst_n = 1;

		/* map */
		e0 = errors;
		expect_reg("DC_ID", D + GHCI_DC_ID, GHCI_DC_ID_VALUE);
		expect_reg("DC_VERSION", D + GHCI_DC_VERSION, 32'h00000001);
		expect_reg("DC_CAPS", D + GHCI_DC_CAPS, 32'h00000473);
		wr(D + GHCI_DC_CTRL, 32'h0000_0065);	/* ENABLE, TEST_PATTERN, FORMAT 2, OUTPUT */
		expect_reg("CTRL", D + GHCI_DC_CTRL, 32'h0000_0065);
		check("enable/test/format", {29'd0, enable, test_pattern, format}, {29'd0, 1'b1, 1'b1, 2'd2});
		wr(D + GHCI_DC_CTRL, 32'h0000_0000);
		check("enable 0", {31'd0, enable}, 32'd0);
		wr(D + GHCI_DC_FB_NEXT, 32'h1C00_0000);
		expect_reg("FB_NEXT", D + GHCI_DC_FB_NEXT, 32'h1C00_0000);
		expect_reg("FB_BASE (disabled: at once)", D + GHCI_DC_FB_BASE, 32'h1C00_0000);
		check("fb_base out", fb_base, 32'h1C00_0000);
		wr(D + GHCI_DC_FB_STRIDE, 32'd2560);
		wr(D + GHCI_DC_FB_SIZE, {16'd480, 16'd640});
		expect_reg("FB_STRIDE", D + GHCI_DC_FB_STRIDE, 32'd2560);
		expect_reg("FB_SIZE", D + GHCI_DC_FB_SIZE, {16'd480, 16'd640});
		check("fb_stride/size out", fb_stride ^ fb_size, 32'd2560 ^ {16'd480, 16'd640});
		for (k = 0; k < 9; k = k + 1)
			wr(D + GHCI_DC_TIMING + 4 * k, 32'h100 + k);
		for (k = 0; k < 9; k = k + 1) begin
			expect_reg("timing word", D + GHCI_DC_TIMING + 4 * k, 32'h100 + k);
			check("timing bus", timing[32*k +: 32], 32'h100 + k);
		end
		/* Byte strobes: only byte 1 of H_ACTIVE. */
		@(negedge clk);
		reg_wstrb = 4'b0010;
		wr(D + GHCI_DC_TIMING, 32'hFFFF_AAFF);
		expect_reg("strobes", D + GHCI_DC_TIMING, 32'h0000_AA00);
		wr(D + GHCI_DC_PCLK_SEL, 32'd1);
		expect_reg("PCLK_SEL", D + GHCI_DC_PCLK_SEL, 32'd1);
		check("pclk_sel out", {31'd0, pclk_sel}, 32'd1);
		expect_reg("SCAN_SUM", D + GHCI_DC_SCAN_SUM, 32'h12345678);
		expect_reg("SCAN_WORDS", D + GHCI_DC_SCAN_WORDS, 32'd307200);
		expect_reg("unused 0x0C", D + 17'h0C, 32'd0);
		expect_reg("I2C absent", D + GHCI_DC_I2C, 32'd0);
		wr(17'h10000 + GHCI_DC_I2C + 17'h4, 32'h55);
		check("KC705 I2C write", {31'd0, saw_i2c}, 32'd1);
		rd_k(17'h10000 + GHCI_DC_I2C + 17'h8, v);
		check("KC705 I2C window", v, 32'hC3C3C3C3);
		if (errors == e0)
			$display("PASS atg_dc_regs.map");

		/* header */
		e0 = errors;
		expect_reg("MAGIC", GHCI_MAGIC, GHCI_MAGIC_VALUE);
		expect_reg("VERSION", GHCI_VERSION, 32'h00010000);
		expect_reg("VENDOR", GHCI_VENDOR_ID, 32'h414D4154);
		expect_reg("DEVICE", GHCI_DEVICE_ID, 32'h41544443);
		expect_reg("ISA", GHCI_ISA_ID, 32'd0);
		expect_reg("GCLK_HZ", GHCI_GCLK_HZ, 32'd100000000);
		expect_reg("CAPS", GHCI_CAPS, 32'h00000008);
		expect_reg("CAPS2", GHCI_CAPS2, 32'd0);
		rd(GHCI_EXTCAP, v);
		check("EXTCAP", v, 32'h100);
		n = v;
		expect_reg("entry word0", n[16:0], 32'h00000101);
		expect_reg("entry word1", n[16:0] + 17'd4, 32'h200);
		expect_reg("ring absent", GHCI_RING_BASE, 32'd0);
		expect_reg("above the window", 17'h280, 32'd0);
		expect_reg("alias at 0x10200", 17'h10200, 32'd0);
		rd_k(17'h10000 + GHCI_DC_ID, v);
		check("KC705 DC_ID", v, GHCI_DC_ID_VALUE);
		rd_k(17'h10000 + GHCI_DC_CAPS, v);
		check("KC705 DC_CAPS", v, 32'h00000474);
		rd_k(GHCI_MAGIC, v);
		check("KC705 0x000 (the GPU's)", v, 32'd0);
		if (errors == e0)
			$display("PASS atg_dc_regs.header");

		/* irq */
		e0 = errors;
		line = 12'd123;
		expect_reg("STATUS idle", D + GHCI_DC_STATUS, {16'd0, 12'd123, 4'b0100});
		dma_idle = 0;
		expect_reg("STATUS busy", D + GHCI_DC_STATUS, {16'd0, 12'd123, 4'b0000});
		dma_idle = 1;
		wr(D + GHCI_DC_FB_NEXT, 32'h1D00_0000);	/* disabled: FB_BASE at once */
		wr(D + GHCI_DC_CTRL, 32'h1);
		wr(D + GHCI_DC_IRQ_ENABLE, 32'h7);
		expect_reg("IRQ_ENABLE", D + GHCI_DC_IRQ_ENABLE, 32'h7);
		check("irq low", {31'd0, irq}, 32'd0);
		wr(D + GHCI_DC_FB_NEXT, 32'h1E00_0000);
		expect_reg("FB_BASE before vsync", D + GHCI_DC_FB_BASE, 32'h1D00_0000);
		pulse_ev(1, 1, 0);
		expect_reg("FB_BASE after vsync", D + GHCI_DC_FB_BASE, 32'h1E00_0000);
		expect_reg("IRQ VSYNC+FLIP", D + GHCI_DC_IRQ_STATUS, 32'h5);
		check("irq high", {31'd0, irq}, 32'd1);
		expect_reg("FRAME_COUNT 1", D + GHCI_DC_FRAME_COUNT, 32'd1);
		wr(D + GHCI_DC_IRQ_STATUS, 32'h1);
		expect_reg("W1C VSYNC", D + GHCI_DC_IRQ_STATUS, 32'h4);
		pulse_ev(1, 1, 0);	/* no flip pending: no FLIP_DONE */
		wr(D + GHCI_DC_IRQ_STATUS, 32'h5);
		expect_reg("W1C all", D + GHCI_DC_IRQ_STATUS, 32'h0);
		check("irq low after W1C", {31'd0, irq}, 32'd0);
		pulse_ev(0, 0, 1);
		expect_reg("UNDERFLOW", D + GHCI_DC_IRQ_STATUS, 32'h2);
		rd(D + GHCI_DC_STATUS, v);
		check("sticky underflow", {31'd0, v[1]}, 32'd1);
		wr(D + GHCI_DC_IRQ_ENABLE, 32'h1);
		check("irq masked", {31'd0, irq}, 32'd0);
		/* Set and clear in the same cycle: set wins. */
		@(negedge clk);
		ev_vsync = 1;
		reg_wr = 1;
		reg_waddr = D + GHCI_DC_IRQ_STATUS;
		reg_wdata = 32'h1;
		@(negedge clk);
		ev_vsync = 0;
		reg_wr = 0;
		expect_reg("set wins", D + GHCI_DC_IRQ_STATUS, 32'h3);
		expect_reg("FRAME_COUNT 3", D + GHCI_DC_FRAME_COUNT, 32'd3);
		/* CTRL.RESET: a pulse of 32 cycles; ENABLE, status, count cleared. */
		wr(D + GHCI_DC_CTRL, 32'h3);
		n = 0;
		while (dc_reset) begin
			@(negedge clk);
			n = n + 1;
		end
		if (n < 30 || n > 33) begin
			errors = errors + 1;
			$display("FAIL atg_dc_regs.reset pulse %0d cycles", n);
		end
		expect_reg("CTRL after RESET", D + GHCI_DC_CTRL, 32'h0);
		expect_reg("IRQ after RESET", D + GHCI_DC_IRQ_STATUS, 32'h0);
		expect_reg("FRAME_COUNT after RESET", D + GHCI_DC_FRAME_COUNT, 32'h0);
		expect_reg("STATUS after RESET", D + GHCI_DC_STATUS, {16'd0, 12'd123, 4'b0100});
		expect_reg("FB_SIZE kept", D + GHCI_DC_FB_SIZE, {16'd480, 16'd640});
		if (errors == e0)
			$display("PASS atg_dc_regs.irq");

		if (errors == 0)
			$display("PASS atg_dc_regs");
		$finish;
	end

	always @(posedge clk)
		if (kc.i2c_we && kc.i2c_idx == 2'd1 && kc.i2c_wdata == 32'h55)
			saw_i2c <= 1;

	initial begin
		#200000;
		$display("FAIL atg_dc_regs timeout");
		$finish;
	end

	wire unused_tb = &{1'b0, i2c_we, i2c_idx, i2c_wdata, fb_next, saw_i2c, unused_k_bus};
endmodule

`default_nettype wire
