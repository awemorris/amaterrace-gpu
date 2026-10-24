/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_tb: the whole DC (STANDALONE, 32-byte lines) with amb_mem and a
 * pixel clock of its own (gclk 100 MHz, pclk 25 MHz): the driver's steps
 * through the register bus (timing, FB_*, IRQ_ENABLE, ENABLE), then the
 * active pixels of frames compared with the framebuffer, the vsync
 * interrupt and FRAME_COUNT, a flip to a second framebuffer at a vsync
 * (FLIP_DONE), the scan sum, RGB565, no underflow, ENABLE = 0 → STATUS.idle,
 * CTRL.RESET and a frame after it.  Not in the spec's list (atg_dc is
 * wiring): it covers the clock crossings.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0, pclk = 1'b0;
	reg rst_n = 1'b0, prst_n = 1'b0;
	always #5 clk = !clk;
	always #20 pclk = !pclk;

	reg reg_wr = 0, reg_rd = 0;
	reg [16:0] reg_waddr = 0, reg_raddr = 0;
	reg [31:0] reg_wdata = 0;
	wire [31:0] reg_rdata;
	wire irq, vsync, pclk_sel;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;
	wire [29:0] tmds;
	wire px_de, px_hs, px_vs, scl_t, sda_t;
	wire [23:0] px_rgb;

	atg_dc #(.STANDALONE(1)) dut (
		.clk(clk), .rst_n(rst_n), .pclk(pclk), .prst_n(prst_n),
		.reg_wr(reg_wr), .reg_waddr(reg_waddr), .reg_wdata(reg_wdata), .reg_wstrb(4'hF),
		.reg_rd(reg_rd), .reg_raddr(reg_raddr), .reg_rdata(reg_rdata),
		.irq(irq), .vsync(vsync), .pclk_sel(pclk_sel),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
		.tmds(tmds), .px_rgb(px_rgb), .px_de(px_de), .px_hs(px_hs), .px_vs(px_vs),
		.scl_t(scl_t), .scl_i(1'b1), .sda_t(sda_t), .sda_i(1'b1)
	);

	amb_mem #(.MEM_WORDS(8192)) mem (
		.clk(clk), .rst_n(rst_n),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	localparam [16:0] D = GHCI_DC_STANDALONE_DISP;
	localparam W = 40, H = 12;

	integer errors = 0;
	integer e0, i, seed;
	reg [31:0] v;

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
			data = reg_rdata;
		end
	endtask

	task fail;
		input [8*50-1:0] what;
		input [31:0] got;
		input [31:0] want;
		begin
			errors = errors + 1;
			if (errors < 20)
				$display("FAIL atg_dc.%0s: %h, expected %h", what, got, want);
		end
	endtask

	/* The pixel side: count the active pixels of each frame and compare
	 * them with the framebuffer at cmp_base (format cmp_fmt). */
	integer px_n = 0, frames = 0, bad = 0, frames_bad = 0;
	reg [31:0] cmp_base = 0;
	reg [1:0] cmp_fmt = 0;
	reg vs_q = 1;
	reg [31:0] mw;
	reg [23:0] want_rgb;

	always @(posedge pclk) begin
		vs_q <= px_vs;
		if (!px_vs && vs_q) begin	/* vsync (active low): a frame ended */
			if (px_n != 0) begin
				frames = frames + 1;
				if (px_n != W * H || bad != 0)
					frames_bad = frames_bad + 1;
			end
			px_n = 0;
			bad = 0;
		end
		if (px_de) begin
			if (cmp_fmt == 2'd2) begin
				mw = mem.peek(cmp_base + (px_n / W) * 128 + (px_n % W) * 2 & ~32'd3);
				mw = (px_n % 2) ? mw[31:16] : mw[15:0];
				want_rgb = {mw[15:11], mw[15:13], mw[10:5], mw[10:9], mw[4:0], mw[4:2]};
			end else begin
				mw = mem.peek(cmp_base + (px_n / W) * 256 + (px_n % W) * 4);
				want_rgb = mw[23:0];
			end
			if (px_rgb !== want_rgb) begin
				bad = bad + 1;
				if (bad < 3)
					$display("note: frame %0d pixel %0d %h, expected %h", frames, px_n,
						px_rgb, want_rgb);
			end
			px_n = px_n + 1;
		end
	end

	/* Waits for n whole frames and checks none was wrong. */
	task frames_ok;
		input [8*30-1:0] what;
		input integer n;
		integer f0, b0;
		begin
			f0 = frames;
			b0 = frames_bad;
			wait (frames >= f0 + 1);	/* the frame in progress may be partial */
			b0 = frames_bad;
			wait (frames >= f0 + 1 + n);
			if (frames_bad != b0)
				fail(what, frames_bad - b0, 0);
		end
	endtask

	integer irqs = 0;
	reg irq_q = 0;
	always @(posedge clk) begin
		irq_q <= irq;
		if (irq && !irq_q)
			irqs = irqs + 1;
	end

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		for (i = 0; i < 8192; i = i + 1)
			mem.poke(i * 4, $random(seed));
		repeat (4) @(posedge pclk);
		rst_n = 1;
		prst_n = 1;

		/* A small mode: 40x12, H 40/4/8/4 (56), V 12/2/2/3 (19); negative
		 * syncs. */
		e0 = errors;
		wr(D + GHCI_DC_TIMING + 0, W);
		wr(D + GHCI_DC_TIMING + 4, 4);
		wr(D + GHCI_DC_TIMING + 8, 8);
		wr(D + GHCI_DC_TIMING + 12, 4);
		wr(D + GHCI_DC_TIMING + 16, H);
		wr(D + GHCI_DC_TIMING + 20, 2);
		wr(D + GHCI_DC_TIMING + 24, 2);
		wr(D + GHCI_DC_TIMING + 28, 3);
		wr(D + GHCI_DC_SYNC_POL, 0);
		wr(D + GHCI_DC_FB_NEXT, 32'h1000);
		wr(D + GHCI_DC_FB_STRIDE, 256);
		wr(D + GHCI_DC_FB_SIZE, {16'd12, 16'd40});
		wr(D + GHCI_DC_IRQ_ENABLE, 32'h7);
		cmp_base = 32'h1000;
		cmp_fmt = 0;
		wr(D + GHCI_DC_CTRL, 32'h1);
		frames_ok("frames of fb 0x1000", 3);
		rd(D + GHCI_DC_FRAME_COUNT, v);
		if (v < 4 || v > 6) fail("FRAME_COUNT", v, 4);
		if (irqs < 1) fail("vsync irq", irqs, 1);
		rd(D + GHCI_DC_IRQ_STATUS, v);
		if (v[0] !== 1'b1) fail("IRQ_STATUS.VSYNC", v, 1);
		if (v[1] !== 1'b0) fail("IRQ_STATUS.UNDERFLOW", v, 0);
		rd(D + GHCI_DC_SCAN_WORDS, v);
		if (v !== W * H) fail("SCAN_WORDS", v, W * H);
		/* Flip: FB_NEXT then the next vsync. */
		wr(D + GHCI_DC_IRQ_STATUS, 32'h7);
		wr(D + GHCI_DC_FB_NEXT, 32'h4000);
		@(posedge vsync);
		@(negedge clk);
		cmp_base = 32'h4000;
		rd(D + GHCI_DC_IRQ_STATUS, v);
		if (v[2] !== 1'b1) fail("FLIP_DONE", v, 4);
		rd(D + GHCI_DC_FB_BASE, v);
		if (v !== 32'h4000) fail("FB_BASE after flip", v, 32'h4000);
		frames_ok("frames of fb 0x4000", 2);
		rd(D + GHCI_DC_STATUS, v);
		if (v[1:0] !== 2'b01) fail("STATUS running, no underflow", v, 1);
		/* Disable: idle. */
		wr(D + GHCI_DC_CTRL, 32'h0);
		repeat (200) @(posedge clk);
		rd(D + GHCI_DC_STATUS, v);
		if (v[2:0] !== 3'b100) fail("STATUS idle", v, 4);
		/* RGB565 with a stride of 128. */
		wr(D + GHCI_DC_FB_NEXT, 32'h6000);
		wr(D + GHCI_DC_FB_STRIDE, 128);
		cmp_base = 32'h6000;
		cmp_fmt = 2;
		wr(D + GHCI_DC_CTRL, 32'h21);
		frames_ok("frames of RGB565", 2);
		/* CTRL.RESET while running, then enable again. */
		wr(D + GHCI_DC_CTRL, 32'h23);
		repeat (100) @(posedge clk);
		rd(D + GHCI_DC_FRAME_COUNT, v);
		if (v !== 32'd0) fail("FRAME_COUNT after RESET", v, 0);
		rd(D + GHCI_DC_CTRL, v);
		if (v[0] !== 1'b0) fail("ENABLE after RESET", v, 0);
		wr(D + GHCI_DC_CTRL, 32'h21);
		frames_ok("frames after RESET", 2);
		rd(D + GHCI_DC_STATUS, v);
		if (v[1] !== 1'b0) fail("no underflow after RESET", v, 0);
		if (errors == e0)
			$display("PASS atg_dc.scanout");
		if (errors == 0)
			$display("PASS atg_dc");
		$finish;
	end

	initial begin
		#30000000;
		$display("FAIL atg_dc timeout");
		$finish;
	end

	wire unused_tb = &{1'b0, tmds, px_hs, scl_t, sda_t, pclk_sel};
endmodule

`default_nettype wire
