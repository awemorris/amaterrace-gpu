/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_cursor_tb: the cursor plane against amb_mem (random ready and
 * latency) and a reference model, with a pixel source and sink of random
 * valid/ready standing in for the DMA and the pixel FIFO.  Frames are
 * driven by the testbench: frame_start, the frame's pixels, and dma_done
 * between frames.  Checked: every output pixel (the blend with alpha 0,
 * 255, in between and non-premultiplied values that saturate; clipping at
 * every edge; the position taken at the frame start), the load (no read
 * before dma_done, the take at the first frame start after the load, the
 * cursor hidden while loading, a load across a frame start), RGBA8 and
 * RGB565 (every 565 value unchanged under a = 0, c = 0), the cancels
 * (ENABLE 0, ENABLE falling, the DC's reset) and a read error.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_cursor_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg dc_reset = 0, enable = 0, frame_start = 0, dma_done = 1, show = 0, flip_valid = 0;
	reg [1:0] format = 0;
	reg [15:0] fb_width = 16'd100;
	reg [31:0] pos = 0, flip_base = 0;
	reg i_valid = 0, o_ready = 0;
	reg [31:0] i_data = 0;
	wire i_ready, o_valid, taken, taken_cancel, pending, idle, err;
	wire [31:0] o_data, cursor_base;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;

	atg_dc_cursor dut (
		.clk(clk), .rst_n(rst_n), .dc_reset(dc_reset), .enable(enable), .format(format),
		.frame_start(frame_start), .dma_done(dma_done), .fb_width(fb_width),
		.i_valid(i_valid), .i_ready(i_ready), .i_data(i_data),
		.o_valid(o_valid), .o_ready(o_ready), .o_data(o_data),
		.pos(pos), .show(show), .flip_valid(flip_valid), .flip_base(flip_base),
		.taken(taken), .taken_cancel(taken_cancel), .pending(pending),
		.cursor_base(cursor_base), .idle(idle), .err(err),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	amb_mem #(.MEM_WORDS(16384), .ERR_BASE(32'hC000)) mem (
		.clk(clk), .rst_n(rst_n),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	integer errors = 0;
	integer e0, i, k, t_n, seed, n_taken = 0, n_cancel = 0, n_err = 0, n_req = 0, bad_req = 0;
	reg [31:0] v;

	always @(posedge clk) begin
		if (taken)
			n_taken = n_taken + 1;
		if (taken && taken_cancel)
			n_cancel = n_cancel + 1;
		if (err)
			n_err = n_err + 1;
		if (req_valid && req_ready) begin
			n_req = n_req + 1;
			if (req_write)
				bad_req = bad_req + 1;
		end
	end

	task fail;
		input [8*48-1:0] what;
		input [31:0] got;
		input [31:0] want;
		begin
			errors = errors + 1;
			if (errors < 20)
				$display("FAIL atg_dc_cursor.%0s: %h, expected %h", what, got, want);
		end
	endtask

	/* The reference blend. */
	function [7:0] rmix;
		input [7:0] c, p, a;
		integer t;
		begin
			t = c + (2 * p * (255 - a) + 255) / 510;
			rmix = t > 255 ? 8'd255 : t;
		end
	endfunction

	function [7:0] rnarrow;
		input [7:0] x;
		input integer m;
		begin
			rnarrow = (2 * x * m + 255) / 510;
		end
	endfunction

	/* The model's state: the image shown and its position for a frame. */
	reg [31:0] img_base;
	reg img_shown;
	reg signed [16:0] fx, fy;

	function [31:0] model;
		input [31:0] p;
		input integer x, y;
		reg [31:0] q;
		integer cx, cy;
		reg [7:0] r8, g8, b8;
		begin
			cx = x - fx;
			cy = y - fy;
			if (!img_shown || cx < 0 || cx > 63 || cy < 0 || cy > 63) begin
				model = p;
			end else begin
				q = mem.peek(img_base + cy * 256 + cx * 4);
				if (format == 2'd1) begin
					model = {p[31:24], rmix(q[7:0], p[23:16], q[31:24]),
						rmix(q[15:8], p[15:8], q[31:24]), rmix(q[23:16], p[7:0], q[31:24])};
				end else if (format == 2'd2) begin
					r8 = rmix(q[23:16], {p[15:11], p[15:13]}, q[31:24]);
					g8 = rmix(q[15:8], {p[10:5], p[10:9]}, q[31:24]);
					b8 = rmix(q[7:0], {p[4:0], p[4:2]}, q[31:24]);
					model = p;
					model[15:11] = rnarrow(r8, 31);
					model[10:5] = rnarrow(g8, 63);
					model[4:0] = rnarrow(b8, 31);
				end else begin
					model = {p[31:24], rmix(q[23:16], p[23:16], q[31:24]),
						rmix(q[15:8], p[15:8], q[31:24]), rmix(q[7:0], p[7:0], q[31:24])};
				end
			end
		end
	endfunction

	/* A frame of w x h pixels from random source words, every output checked. */
	reg [31:0] src [0:16383];
	integer out_n, in_n, fw, fh, bad, total, n_blended = 0;
	reg checking = 0, src_on = 0;

	/* The source (the DMA) and the sink (the pixel FIFO). */
	always @(posedge clk) begin
		if (!src_on) begin
			i_valid <= 1'b0;
			o_ready <= 1'b0;
		end else begin
			if (i_valid && i_ready)
				in_n = in_n + 1;
			if (!i_valid || i_ready) begin
				i_valid <= in_n < total && ($unsigned($random(seed)) % 100) < 85;
				i_data <= src[in_n];
			end
			o_ready <= ($unsigned($random(seed)) % 100) < 80;
		end
	end

	always @(posedge clk) begin
		if (checking && o_valid && o_ready) begin
			if (model(src[out_n], out_n % fw, out_n / fw) !== src[out_n])
				n_blended = n_blended + 1;
			if (o_data !== model(src[out_n], out_n % fw, out_n / fw)) begin
				bad = bad + 1;
				if (bad < 3)
					$display("note: pixel (%0d, %0d) %h, expected %h", out_n % fw, out_n / fw,
						o_data, model(src[out_n], out_n % fw, out_n / fw));
			end
			out_n = out_n + 1;
		end
	end

	task frame;
		input [8*40-1:0] what;
		input integer w, h;
		begin
			fw = w;
			fh = h;
			fb_width = w;
			for (i = 0; i < w * h; i = i + 1)
				src[i] = $random(seed);
			@(negedge clk);
			dma_done = 0;
			frame_start = 1;
			@(negedge clk);
			frame_start = 0;
			/* The model takes the image and the position of this frame. */
			fx = $signed({pos[15], pos[15:0]});
			fy = $signed({pos[31], pos[31:16]});
			@(negedge clk);
			img_shown = show && dut.img_ok && dut.st == 2'd0;
			img_base = cursor_base;
			out_n = 0;
			in_n = 0;
			bad = 0;
			total = w * h;
			checking = 1;
			src_on = 1;
			while (out_n < w * h)
				@(negedge clk);
			src_on = 0;
			@(negedge clk);
			checking = 0;
			dma_done = 1;
			if (bad != 0)
				fail(what, bad, 0);
		end
	endtask

	task flip;
		input [31:0] base;
		begin
			@(negedge clk);
			flip_valid = 1;
			flip_base = base;
			@(negedge clk);
			flip_valid = 0;
			@(negedge clk);
		end
	endtask

	/* Waits for the load to be done (READY), with a bound. */
	task wait_ready;
		begin
			k = 0;
			while (dut.st != 2'd2 && k < 20000) begin
				@(negedge clk);
				k = k + 1;
			end
			if (dut.st != 2'd2)
				fail("load not done", dut.st, 2);
		end
	endtask

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		for (i = 0; i < 16384; i = i + 1)
			mem.poke(i * 4, $random(seed));
		/* Row 0 of the image at 0x4000: alpha 0 and c 0, alpha 255, c > a. */
		mem.poke(32'h4000, 32'h00000000);
		mem.poke(32'h4004, 32'hFF102030);
		mem.poke(32'h4008, 32'h80FFFFFF);
		mem.poke(32'h400C, 32'h00FFFFFF);
		/* The image at 0x8000: all zero (for the 565 identity). */
		for (i = 0; i < 4096; i = i + 1)
			mem.poke(32'h8000 + i * 4, 32'd0);
		repeat (3) @(posedge clk);
		rst_n = 1;
		enable = 1;
		img_shown = 0;

		/* load: no read before dma_done; hidden while loading; the take at a frame start. */
		e0 = errors;
		dma_done = 0;
		pos = {16'd5, 16'd10};
		show = 1;
		flip(32'h4000);
		if (pending !== 1'b1) fail("pending", pending, 1);
		repeat (50) @(negedge clk);
		if (n_req != 0) fail("a read before dma_done", n_req, 0);
		frame("hidden while loading", 100, 20);	/* dma_done rises after it: the load starts */
		repeat (5) @(negedge clk);
		if (n_req == 0) fail("no read after dma_done", n_req, 1);
		wait_ready;
		if (n_req != 512) fail("reads of the image", n_req, 512);
		if (n_taken != 0) fail("taken before the frame start", n_taken, 0);
		frame("shown after the take", 100, 80);
		if (n_taken != 1 || n_cancel != 0) fail("taken at the frame start", n_taken, 1);
		if (cursor_base !== 32'h4000) fail("CURSOR_BASE", cursor_base, 32'h4000);
		if (bad_req != 0) fail("a write", bad_req, 0);
		if (errors == e0)
			$display("PASS atg_dc_cursor.load");

		/* blend and clip: positions at every edge, negative ones included. */
		e0 = errors;
		pos = {16'hFFE2, 16'hFFEC};	/* (-20, -30) */
		frame("clip top left", 100, 80);
		pos = {16'd50, 16'd70};	/* right and bottom */
		frame("clip bottom right", 100, 80);
		pos = {16'd0, 16'd0};
		frame("corner 0 0 (alpha 0, 255, saturation)", 100, 80);
		pos = {16'd100, 16'd0};	/* outside on the right */
		frame("outside", 100, 80);
		if (n_blended < 5000) fail("pixels blended", n_blended, 5000);
		if (errors == e0)
			$display("PASS atg_dc_cursor.blend");

		/* pos: a write in the middle of a frame is taken at the next one. */
		e0 = errors;
		pos = {16'd10, 16'd10};
		fork
			frame("frame with the old position", 100, 80);
			begin
				repeat (300) @(negedge clk);
				pos = {16'd40, 16'd30};
				show = 0;
			end
		join
		frame("hidden from the next frame", 100, 80);
		show = 1;
		frame("the new position", 100, 80);
		if (errors == e0)
			$display("PASS atg_dc_cursor.pos");

		/* fmt: RGBA8, RGB565, and every 565 value unchanged under a = 0, c = 0. */
		e0 = errors;
		format = 2'd1;
		pos = {16'd3, 16'd7};
		frame("RGBA8", 100, 80);
		format = 2'd2;
		frame("RGB565", 100, 80);
		format = 2'd0;
		for (i = 0; i < 65536; i = i + 1) begin
			v = {dut.narrow(dut.mix(8'd0, {i[15:11], i[15:13]}, 8'd0), 6'd31),
				dut.narrow(dut.mix(8'd0, {i[10:5], i[10:9]}, 8'd0), 6'd63),
				dut.narrow(dut.mix(8'd0, {i[4:0], i[4:2]}, 8'd0), 6'd31)};
			if ({v[16:12], v[11:6], v[4:0]} !== i[15:0]) begin
				fail("565 identity", v, i);
				i = 65536;
			end
		end
		if (errors == e0)
			$display("PASS atg_dc_cursor.fmt");

		/* cancel: ENABLE 0 at the flip, ENABLE falling before and during a load,
		 * the DC's reset during a load. */
		e0 = errors;
		enable = 0;
		@(negedge clk);
		flip(32'h8000);
		if (n_cancel != 1) fail("cancelled with ENABLE 0", n_cancel, 1);
		enable = 1;
		dma_done = 0;
		flip(32'h8000);
		enable = 0;
		repeat (3) @(negedge clk);
		if (n_cancel != 2) fail("cancelled by ENABLE before the load", n_cancel, 2);
		if (pending !== 1'b0) fail("not pending", pending, 0);
		enable = 1;
		dma_done = 1;
		flip(32'h8000);
		repeat (40) @(negedge clk);
		if (dut.st != 2'd1) fail("loading", dut.st, 1);
		@(negedge clk);
		dc_reset = 1;
		repeat (32) @(negedge clk);
		dc_reset = 0;
		if (n_cancel != 3) fail("cancelled by the DC's reset", n_cancel, 3);
		k = 0;
		while (!(idle && dut.st == 2'd0) && k < 1000) begin
			@(negedge clk);
			k = k + 1;
		end
		if (!idle) fail("idle after the reset", idle, 1);
		frame("hidden after the reset", 100, 20);
		/* A load again after the reset: the reads still outstanding were dropped. */
		flip(32'h8000);
		wait_ready;
		frame("shown again", 100, 80);
		if (cursor_base !== 32'h8000) fail("CURSOR_BASE 0x8000", cursor_base, 32'h8000);
		if (errors == e0)
			$display("PASS atg_dc_cursor.cancel");

		/* err: an image in the error range. */
		e0 = errors;
		t_n = n_taken;
		flip(32'hC000);
		wait_ready;
		if (n_err == 0) fail("err", n_err, 1);
		frame("hidden after an error", 100, 80);
		if (n_taken != t_n + 1) fail("taken after an error", n_taken - t_n, 1);
		if (dut.img_ok !== 1'b0) fail("image not shown", dut.img_ok, 0);
		if (errors == e0)
			$display("PASS atg_dc_cursor.err");

		if (errors == 0)
			$display("PASS atg_dc_cursor");
		$finish;
	end

	initial begin
		#100000000;
		$display("FAIL atg_dc_cursor timeout");
		$finish;
	end

	wire unused_tb = &{1'b0, req_be, req_wdata, req_tag};
endmodule

`default_nettype wire
