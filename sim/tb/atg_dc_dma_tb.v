/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_dma_tb: the DMA against amb_mem (random ready and latency) and a
 * sink with a random px_ready.  Frames of 32-bit and RGB565 pixels whose
 * rows end inside a line are compared word by word with the memory; the
 * scan sum and count of a frame; rows in the error range give zeros;
 * ENABLE = 0 in the middle of a frame stops the requests and idle rises,
 * and a frame_start in the middle of a frame aborts it: the next frame is
 * whole and in order (the late responses of the old one are dropped).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_dma_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg enable = 0, frame_start = 0, clear = 0;
	reg [31:0] fb_base = 0, fb_stride = 0, fb_size = 0;
	reg [1:0] format = 0;
	wire px_valid, idle, done, err;
	reg px_ready = 0;
	wire [31:0] px_data, scan_sum, scan_words;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;

	atg_dc_dma dut (
		.clk(clk), .rst_n(rst_n), .clear(clear), .enable(enable), .frame_start(frame_start),
		.fb_base(fb_base), .fb_stride(fb_stride), .fb_size(fb_size), .format(format),
		.px_valid(px_valid), .px_ready(px_ready), .px_data(px_data), .idle(idle),
		.done(done), .err(err), .scan_sum(scan_sum), .scan_words(scan_words),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	amb_mem #(.MEM_WORDS(8192), .ERR_BASE(32'h6000)) mem (
		.clk(clk), .rst_n(rst_n),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	integer errors = 0;
	integer e0, i, seed, got_n, ready_pct;
	integer burst_count, max_burst;
	reg [31:0] got [0:4095];
	reg [31:0] sum;

	integer n_err = 0;
	always @(posedge clk)
		if (err)
			n_err = n_err + 1;

	/* The sink: records every pixel taken. */
	always @(posedge clk) begin
		px_ready <= ($unsigned($random(seed)) % 100) < ready_pct;
		if (px_valid && px_ready) begin
			got[got_n] <= px_data;
			got_n <= got_n + 1;
		end
	end

	/* A request must not be dropped before req_ready. */
	reg rv_q = 0;
	reg [26:0] rl_q = 0;
	always @(posedge clk) begin
		if (rv_q && !(req_valid && req_line == rl_q)) begin
			errors = errors + 1;
			$display("FAIL atg_dc_dma.protocol: request dropped or changed before ready");
		end
		rv_q <= req_valid && !req_ready;
		rl_q <= req_line;
		if (req_valid && req_write) begin
			errors = errors + 1;
			$display("FAIL atg_dc_dma.protocol: a write");
		end
	end

	function [31:0] model;
		input [31:0] base, stride;
		input integer x, y, bpp16;
		reg [31:0] a, w;
		begin
			a = base + y * stride + (bpp16 ? 2 * x : 4 * x);
			w = a >= 32'h6000 ? 32'd0 : mem.peek(a & ~32'd3);
			model = bpp16 ? {16'd0, a[1] ? w[31:16] : w[15:0]} : w;
		end
	endfunction

	task pulse_start;
		begin
			@(negedge clk);
			frame_start = 1;
			@(negedge clk);
			frame_start = 0;
		end
	endtask

	/* One frame: start it, wait for w * h pixels, compare. */
	task frame;
		input [8*20-1:0] what;
		input [31:0] base, stride;
		input integer w, h, fmt;
		integer x, y, n, t;
		begin
			fb_base = base;
			fb_stride = stride;
			fb_size = {h[15:0], w[15:0]};
			format = fmt;
			@(negedge clk);
			got_n = 0;
			frame_start = 1;
			@(negedge clk);
			frame_start = 0;
			t = 0;
			while (got_n < w * h && t < 200000) begin
				@(negedge clk);
				t = t + 1;
			end
			repeat (200) @(negedge clk);
			if (got_n != w * h) begin
				errors = errors + 1;
				$display("FAIL atg_dc_dma.%0s: %0d pixels, expected %0d", what, got_n, w * h);
			end
			n = 0;
			sum = 0;
			for (y = 0; y < h; y = y + 1)
				for (x = 0; x < w; x = x + 1) begin
					sum = sum + model(base, stride, x, y, fmt == 2);
					if (n < got_n && got[n] !== model(base, stride, x, y, fmt == 2)) begin
						errors = errors + 1;
						if (errors < 10)
							$display("FAIL atg_dc_dma.%0s: (%0d, %0d) %h, expected %h",
								what, x, y, got[n], model(base, stride, x, y, fmt == 2));
					end
					n = n + 1;
				end
		end
	endtask

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		got_n = 0;
		ready_pct = 70;
		for (i = 0; i < 8192; i = i + 1)
			mem.poke(i * 4, $random(seed));
		repeat (3) @(posedge clk);
		rst_n = 1;
		enable = 1;

		/* frame */
		e0 = errors;
		frame("frame32", 32'h0100, 32'd128, 20, 5, 0);	/* 80 bytes: 3 lines a row */
		frame("frame565", 32'h1000, 32'd96, 37, 6, 2);	/* 74 bytes */
		frame("frame32 slow sink", 32'h2000, 32'd64, 16, 4, 1);
		pulse_start;	/* takes the last frame's sum */
		@(negedge clk);
		if (scan_words !== 32'd64 || scan_sum !== sum) begin
			errors = errors + 1;
			$display("FAIL atg_dc_dma.frame: scan %0d words sum %h, expected 64 and %h",
				scan_words, scan_sum, sum);
		end
		ready_pct = 100;
		i = n_err;
		frame("error rows", 32'h5F00, 32'd64, 16, 8, 0);	/* rows 4.. at 0x6000 */
		repeat (4) @(negedge clk);
		if (n_err - i != 8) begin	/* 4 rows of 2 lines */
			errors = errors + 1;
			$display("FAIL atg_dc_dma.frame: %0d err pulses, expected 8", n_err - i);
		end
		if (!done) begin
			errors = errors + 1;
			$display("FAIL atg_dc_dma.frame: done is 0 after the frame");
		end
		ready_pct = 70;
		frame("empty", 32'h0, 32'd64, 0, 4, 0);
		if (errors == e0)
			$display("PASS atg_dc_dma.frame");

		/* stop */
		e0 = errors;
		ready_pct = 5;	/* the FIFO fills: requests wait for room */
		fb_base = 32'h0;
		fb_stride = 32'd256;
		fb_size = {16'd16, 16'd64};
		format = 0;
		pulse_start;
		repeat (100) @(negedge clk);
		enable = 0;
		@(negedge clk);
		i = 0;
		while (!idle && i < 100) begin
			@(negedge clk);
			i = i + 1;
		end
		if (!idle) begin
			errors = errors + 1;
			$display("FAIL atg_dc_dma.stop: not idle");
		end
		repeat (50) @(negedge clk);
		if (req_valid || px_valid) begin
			errors = errors + 1;
			$display("FAIL atg_dc_dma.stop: a request or pixel after ENABLE = 0");
		end
		/* Enable again: a whole frame. */
		ready_pct = 70;
		enable = 1;
		frame("after stop", 32'h0300, 32'd128, 24, 3, 0);
		/* A frame_start in the middle of a frame, with responses on the way. */
		ready_pct = 30;
		fb_base = 32'h0;
		fb_size = {16'd16, 16'd64};
		pulse_start;
		repeat (37) @(negedge clk);
		ready_pct = 70;
		frame("after abort", 32'h0400, 32'd128, 32, 4, 0);
		if (errors == e0)
			$display("PASS atg_dc_dma.stop");

		/* clear: the DC's reset in the middle of a frame with reads on the way. */
		e0 = errors;
		ready_pct = 30;
		fb_base = 32'h0;
		fb_stride = 32'd256;
		fb_size = {16'd16, 16'd64};
		format = 0;
		pulse_start;
		repeat (8) @(negedge clk);
		if (done) begin
			errors = errors + 1;
			$display("FAIL atg_dc_dma.clear: done in the middle of a frame");
		end
		while (idle)
			@(negedge clk);	/* a read is outstanding */
		/* One cycle (the reads outstanding answer after it). */
		clear = 1;
		frame_start = 1;	/* ignored under clear */
		@(negedge clk);
		frame_start = 0;
		clear = 0;
		if (px_valid) begin
			errors = errors + 1;
			$display("FAIL atg_dc_dma.clear: a pixel under clear");
		end
		i = 0;
		while (!idle && i < 200) begin
			@(negedge clk);
			i = i + 1;
		end
		if (!idle || !done) begin
			errors = errors + 1;
			$display("FAIL atg_dc_dma.clear: not idle and done after clear (%b %b)", idle, done);
		end
		ready_pct = 70;
		frame("after clear", 32'h0500, 32'd128, 24, 3, 0);
		if (errors == e0)
			$display("PASS atg_dc_dma.clear");

		/* Continuous burst verification: verify that DMA issues multiple lines back-to-back without 1-cycle bubbles */
		e0 = errors;
		enable = 0;
		@(negedge clk);
		enable = 1;
		fb_base = 32'h0600;
		fb_stride = 32'd256;
		fb_size = {16'd32, 16'd64};
		format = 0;
		pulse_start;
		burst_count = 0;
		max_burst = 0;
		for (i = 0; i < 80; i = i + 1) begin
			@(posedge clk);
			if (req_valid && req_ready)
				burst_count = burst_count + 1;
			else if (req_valid && !req_ready)
				burst_count = burst_count;
			else
				burst_count = 0;
			if (burst_count > max_burst)
				max_burst = burst_count;
		end
		if (max_burst < 16) begin
			errors = errors + 1;
			$display("FAIL atg_dc_dma.burst: max consecutive issued lines %0d < 16", max_burst);
		end else begin
			$display("PASS atg_dc_dma.burst (%0d consecutive lines issued without bubbles)", max_burst);
		end

		if (errors == 0)
			$display("PASS atg_dc_dma");
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL atg_dc_dma timeout");
		$finish;
	end

	wire unused_tb = &{1'b0, scan_sum};
endmodule

`default_nettype wire
