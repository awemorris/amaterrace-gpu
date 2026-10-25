/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_tb: the whole DC (32-byte lines) with amb_mem and a pixel clock
 * of its own (gclk 100 MHz, pclk 25 MHz), driven as atg_cp_disp drives it:
 * the internal register bus (timing, FB_*, ENABLE) and the flips.  The
 * active pixels of frames are compared with the image; VBLANK and
 * FRAME_COUNT; a flip at once while disabled and one at a vsync (taken,
 * FB_BASE); the scan sum; RGB565; no underflow; a read error (black lines,
 * STATUS.read error, DISP_ERROR at most once a frame); ENABLE = 0 with a
 * pending flip (cancelled) → STATUS.idle; CTRL.RESET with a pending flip
 * and reads on the way, and frames after it.  Not in the spec's list
 * (atg_dc is wiring): it covers the clock crossings.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0, pclk = 1'b0;
	reg rst_n = 1'b0, prst_n = 1'b0;
	always #5 clk = !clk;
	always #20 pclk = !pclk;

	reg d_we = 0, flip_valid = 0, flip_plane = 0;
	reg [5:0] d_idx = 0, d_ridx = 0;
	reg [31:0] d_wdata = 0, flip_base = 0;
	wire [31:0] d_rdata, frame_count;
	wire [1:0] taken, taken_cancel, pending;
	wire idle, vsync, ev_error, ev_hotplug, pclk_sel;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;
	wire [29:0] tmds;
	wire px_de, px_hs, px_vs, scl_t, sda_t;
	wire [23:0] px_rgb;

	atg_dc dut (
		.clk(clk), .rst_n(rst_n), .pclk(pclk), .prst_n(prst_n),
		.d_we(d_we), .d_idx(d_idx), .d_wdata(d_wdata), .d_wmask(32'hFFFFFFFF),
		.d_ridx(d_ridx), .d_rdata(d_rdata),
		.flip_valid(flip_valid), .flip_plane(flip_plane), .flip_base(flip_base),
		.taken(taken), .taken_cancel(taken_cancel), .pending(pending), .dc_err(2'b00),
		.idle(idle), .frame_count(frame_count),
		.ev_vblank(vsync), .ev_error(ev_error), .ev_hotplug(ev_hotplug), .pclk_sel(pclk_sel),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
		.tmds(tmds), .px_rgb(px_rgb), .px_de(px_de), .px_hs(px_hs), .px_vs(px_vs),
		.scl_t(scl_t), .scl_i(1'b1), .sda_t(sda_t), .sda_i(1'b1)
	);

	amb_mem #(.MEM_WORDS(16384), .ERR_BASE(32'hF000)) mem (
		.clk(clk), .rst_n(rst_n),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	localparam [7:0] D = 8'h00;
	localparam W = 40, H = 12;

	integer errors = 0;
	integer e0, i, seed;
	reg [31:0] v;

	task wr;
		input [7:0] addr;
		input [31:0] data;
		begin
			@(negedge clk);
			d_we = 1;
			d_idx = addr[7:2];
			d_wdata = data;
			@(negedge clk);
			d_we = 0;
			@(negedge clk);
		end
	endtask

	task rd;
		input [7:0] addr;
		output [31:0] data;
		begin
			@(negedge clk);
			d_ridx = addr[7:2];
			#1;
			data = d_rdata;
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

	integer n_taken = 0, n_cancel = 0, n_error = 0, n_taken1 = 0;
	always @(posedge clk) begin
		if (taken[1] && !taken_cancel[1])
			n_taken1 = n_taken1 + 1;
		if (taken[0])
			n_taken = n_taken + 1;
		if (taken[0] && taken_cancel[0])
			n_cancel = n_cancel + 1;
		if (ev_error)
			n_error = n_error + 1;
	end

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
			end else if (cmp_base + (px_n / W) * 256 >= 32'hF000) begin
				want_rgb = 24'd0;	/* a read error: black */
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
	always @(posedge clk)
		if (vsync)
			irqs = irqs + 1;

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		for (i = 0; i < 16384; i = i + 1)
			mem.poke(i * 4, i >= 32'h2000 && i < 32'h3000 ? 32'd0 : $random(seed));
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
		flip(32'h1000);	/* disabled: taken at once */
		if (n_taken !== 1 || n_cancel !== 0) fail("flip at once", n_taken, 1);
		wr(D + GHCI_DC_FB_STRIDE, 256);
		wr(D + GHCI_DC_FB_SIZE, {16'd12, 16'd40});
		cmp_base = 32'h1000;
		cmp_fmt = 0;
		wr(D + GHCI_DC_CTRL, 32'h1);
		frames_ok("frames of fb 0x1000", 3);
		rd(D + GHCI_DC_FRAME_COUNT, v);
		if (v < 4 || v > 6) fail("FRAME_COUNT", v, 4);
		if (irqs < 4) fail("VBLANK", irqs, 4);
		rd(D + GHCI_DC_STATUS, v);
		if (v[1] !== 1'b0) fail("no underflow", v, 0);
		rd(D + GHCI_DC_SCAN_WORDS, v);
		if (v !== W * H) fail("SCAN_WORDS", v, W * H);
		/* A flip of the CP: pending, taken at the next vsync. */
		flip(32'h4000);
		if (pending[0] !== 1'b1) fail("pending", pending, 1);
		@(posedge vsync);
		repeat (3) @(negedge clk);
		cmp_base = 32'h4000;
		if (n_taken !== 2 || n_cancel !== 0) fail("taken at vsync", n_taken, 2);
		rd(D + GHCI_DC_FB_BASE, v);
		if (v !== 32'h4000) fail("FB_BASE after flip", v, 32'h4000);
		frames_ok("frames of fb 0x4000", 2);
		rd(D + GHCI_DC_STATUS, v);
		if (v[1:0] !== 2'b01) fail("STATUS running, no underflow", v, 1);
		/* A read error: rows 6.. of the image at 0xEA00 are at 0xF000 and up. */
		e0 = n_error;
		flip(32'hEA00);
		@(posedge vsync);
		@(negedge clk);
		cmp_base = 32'hEA00;
		i = n_error;
		frames_ok("frames with read errors", 3);
		if (n_error - i < 3 || n_error - i > 5) fail("DISP_ERROR once a frame", n_error - i, 4);
		rd(D + GHCI_DC_STATUS, v);
		if (v[GHCI_DC_ST_READ_ERROR] !== 1'b1) fail("STATUS.read error", v, 8);
		flip(32'h4000);
		@(posedge vsync);
		@(negedge clk);
		cmp_base = 32'h4000;
		wr(D + GHCI_DC_STATUS, 32'h8);
		rd(D + GHCI_DC_STATUS, v);
		if (v[GHCI_DC_ST_READ_ERROR] !== 1'b0) fail("W1C read error", v, 0);
		/* Disable with a pending flip: cancelled; then idle. */
		flip(32'h5000);
		wr(D + GHCI_DC_CTRL, 32'h0);
		if (n_cancel !== 1) fail("cancelled by ENABLE", n_cancel, 1);
		repeat (200) @(posedge clk);
		rd(D + GHCI_DC_STATUS, v);
		if (v[2:0] !== 3'b100) fail("STATUS idle", v, 4);
		if (idle !== 1'b1) fail("idle out", idle, 1);
		rd(D + GHCI_DC_FB_BASE, v);
		if (v !== 32'h4000) fail("FB_BASE kept", v, 32'h4000);
		/* RGB565 with a stride of 128. */
		flip(32'h6000);
		wr(D + GHCI_DC_FB_STRIDE, 128);
		cmp_base = 32'h6000;
		cmp_fmt = 2;
		wr(D + GHCI_DC_CTRL, 32'h21);
		frames_ok("frames of RGB565", 2);
		/* The cursor (plane 1) shown over RGB565 with a transparent image (all
		 * zero at 0x8000): its reads share the port with the scan-out's and
		 * the frames stay as they are. */
		wr(D + GHCI_DC_CURSOR_POS, {16'd2, 16'd5});
		wr(D + GHCI_DC_CURSOR_CTRL, 32'd1);
		@(negedge clk);
		flip_plane = 1;
		flip(32'h8000);
		flip_plane = 0;
		if (pending[1] !== 1'b1) fail("cursor pending", pending, 2);
		i = 0;
		while (n_taken1 == 0 && i < 200000) begin
			@(negedge clk);
			i = i + 1;
		end
		if (n_taken1 != 1) fail("cursor taken", n_taken1, 1);
		rd(D + GHCI_DC_CURSOR_BASE, v);
		if (v !== 32'h8000) fail("CURSOR_BASE", v, 32'h8000);
		frames_ok("frames with the cursor", 2);
		/* CTRL.RESET while running, with a pending flip and reads on the way. */
		flip(32'h5000);
		wait (!idle);
		wr(D + GHCI_DC_CTRL, 32'h23);
		if (n_cancel !== 2) fail("cancelled by RESET", n_cancel, 2);
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

	wire unused_tb = &{1'b0, tmds, px_hs, scl_t, sda_t, pclk_sel, frame_count, ev_hotplug,
		taken[1], taken_cancel[1], pending[1]};
endmodule

`default_nettype wire
