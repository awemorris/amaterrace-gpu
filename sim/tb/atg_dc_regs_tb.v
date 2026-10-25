/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_regs_tb: the DC's scan-out registers on the internal bus: every
 * register (read back, strobes, the outputs), the refusals while ENABLE is
 * 1 (BAD_WRITE), plane 0's flips (at once while disabled, at a vsync,
 * cancelled by ENABLE falling, by CTRL.RESET and by a host FB_NEXT), the
 * sticky status with W1C, DISP_ERROR at most once a frame, FRAME_COUNT and
 * CTRL.RESET.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_regs_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg d_we = 0;
	reg [5:0] d_idx = 0, d_ridx = 0;
	reg [31:0] d_wdata = 0, d_wmask = 32'hFFFFFFFF;
	wire [31:0] d_rdata;
	reg flip_valid = 0;
	reg [31:0] flip_base = 0;
	reg ev_vsync = 0, ev_underflow = 0, idle_in = 1, rd_err = 0, connected = 1, pending1 = 0;
	reg [1:0] dc_err = 0;
	reg [11:0] line = 12'd0;
	wire enable, test_pattern, pclk_sel, dc_reset, taken, taken_cancel, pending;
	wire ev_vblank, ev_error;
	wire [1:0] format;
	wire [31:0] fb_base, fb_stride, fb_size, frame_count;
	wire [287:0] timing;
	wire i2c_we;
	wire [1:0] i2c_idx;
	wire [31:0] i2c_wdata;

	atg_dc_regs #(.HAS_I2C(1), .HAS_CURSOR(1)) dut (
		.clk(clk), .rst_n(rst_n),
		.d_we(d_we), .d_idx(d_idx), .d_wdata(d_wdata), .d_wmask(d_wmask), .d_ridx(d_ridx),
		.d_rdata(d_rdata),
		.enable(enable), .test_pattern(test_pattern), .format(format), .fb_base(fb_base),
		.fb_stride(fb_stride), .fb_size(fb_size), .timing(timing), .pclk_sel(pclk_sel),
		.dc_reset(dc_reset),
		.flip_valid(flip_valid), .flip_base(flip_base),
		.taken(taken), .taken_cancel(taken_cancel), .pending(pending),
		.ev_vsync(ev_vsync), .ev_underflow(ev_underflow), .idle_in(idle_in), .line(line),
		.scan_sum(32'h12345678), .scan_words(32'd307200), .rd_err(rd_err), .dc_err(dc_err),
		.connected(connected), .pending1(pending1),
		.ev_vblank(ev_vblank), .ev_error(ev_error), .frame_count(frame_count),
		.i2c_we(i2c_we), .i2c_idx(i2c_idx), .i2c_wdata(i2c_wdata), .i2c_rdata(32'hC3C3C3C3)
	);

	/* Counts of the pulses. */
	integer n_taken = 0, n_cancel = 0, n_error = 0, n_vblank = 0;
	always @(posedge clk) begin
		if (taken)
			n_taken = n_taken + 1;
		if (taken && taken_cancel)
			n_cancel = n_cancel + 1;
		if (ev_error)
			n_error = n_error + 1;
		if (ev_vblank)
			n_vblank = n_vblank + 1;
	end

	integer errors = 0;
	integer e0, k, n, t0, c0;
	reg [31:0] v;
	reg saw_i2c = 0;

	always @(posedge clk)
		if (i2c_we && i2c_idx == 2'd1 && i2c_wdata == 32'h55)
			saw_i2c <= 1;

	task wr;
		input [7:0] off;
		input [31:0] data;
		begin
			@(negedge clk);
			d_we = 1;
			d_idx = off[7:2];
			d_wdata = data;
			@(negedge clk);
			d_we = 0;
			d_wmask = 32'hFFFFFFFF;
			@(negedge clk);	/* the pulses of the write are counted */
		end
	endtask

	task rd;
		input [7:0] off;
		output [31:0] data;
		begin
			@(negedge clk);
			d_ridx = off[7:2];
			#1;
			data = d_rdata;
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
		input [7:0] off;
		input [31:0] want;
		begin
			rd(off, v);
			check(what, v, want);
		end
	endtask

	task vsync;
		begin
			@(negedge clk);
			ev_vsync = 1;
			@(negedge clk);
			ev_vsync = 0;
			@(negedge clk);
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

	task pulse;
		input integer which;	/* 0 underflow, 1 read error, 2 record error, 3 bad write */
		begin
			@(negedge clk);
			ev_underflow = which == 0;
			rd_err = which == 1;
			dc_err = which == 2 ? 2'b01 : which == 3 ? 2'b10 : 2'b00;
			@(negedge clk);
			ev_underflow = 0;
			rd_err = 0;
			dc_err = 0;
			@(negedge clk);
		end
	endtask

	initial begin
		repeat (3) @(posedge clk);
		rst_n = 1;

		/* map */
		e0 = errors;
		expect_reg("DC_ID", GHCI_DC_ID[7:0], GHCI_DC_ID_VALUE);
		expect_reg("DC_VERSION", GHCI_DC_VERSION[7:0], 32'h00000002);
		expect_reg("DC_CAPS", GHCI_DC_CAPS[7:0], 32'h00000574);
		wr(GHCI_DC_CTRL[7:0], 32'h0000_0065);	/* ENABLE, TEST_PATTERN, FORMAT 2, OUTPUT */
		expect_reg("CTRL", GHCI_DC_CTRL[7:0], 32'h0000_0065);
		check("enable/test/format", {29'd0, enable, test_pattern, format}, {29'd0, 1'b1, 1'b1, 2'd2});
		wr(GHCI_DC_CTRL[7:0], 32'h0000_0000);
		check("enable 0", {31'd0, enable}, 32'd0);
		wr(GHCI_DC_FB_NEXT[7:0], 32'h1C00_0000);
		expect_reg("FB_NEXT", GHCI_DC_FB_NEXT[7:0], 32'h1C00_0000);
		expect_reg("FB_BASE (disabled: at once)", GHCI_DC_FB_BASE[7:0], 32'h1C00_0000);
		check("fb_base out", fb_base, 32'h1C00_0000);
		wr(GHCI_DC_FB_STRIDE[7:0], 32'd2560);
		wr(GHCI_DC_FB_SIZE[7:0], {16'd480, 16'd640});
		expect_reg("FB_STRIDE", GHCI_DC_FB_STRIDE[7:0], 32'd2560);
		expect_reg("FB_SIZE", GHCI_DC_FB_SIZE[7:0], {16'd480, 16'd640});
		check("fb_stride/size out", fb_stride ^ fb_size, 32'd2560 ^ {16'd480, 16'd640});
		for (k = 0; k < 9; k = k + 1)
			wr(GHCI_DC_TIMING[7:0] + 4 * k, 32'h100 + k);
		for (k = 0; k < 9; k = k + 1) begin
			expect_reg("timing word", GHCI_DC_TIMING[7:0] + 4 * k, 32'h100 + k);
			check("timing bus", timing[32*k +: 32], 32'h100 + k);
		end
		/* Byte strobes: only byte 1 of H_ACTIVE. */
		@(negedge clk);
		d_wmask = 32'h0000FF00;
		wr(GHCI_DC_TIMING[7:0], 32'hFFFF_AAFF);
		expect_reg("strobes", GHCI_DC_TIMING[7:0], 32'h0000_AA00);
		wr(GHCI_DC_PCLK_SEL[7:0], 32'd1);
		expect_reg("PCLK_SEL", GHCI_DC_PCLK_SEL[7:0], 32'd1);
		check("pclk_sel out", {31'd0, pclk_sel}, 32'd1);
		expect_reg("SCAN_SUM", GHCI_DC_SCAN_SUM[7:0], 32'h12345678);
		expect_reg("SCAN_WORDS", GHCI_DC_SCAN_WORDS[7:0], 32'd307200);
		expect_reg("unused 0x0C", 8'h0C, 32'd0);
		expect_reg("IRQ_STATUS is DISP's only", 8'h18, 32'd0);
		expect_reg("0x6C (CONNECTED, not here)", 8'h6C, 32'd0);
		expect_reg("0x80 (MODE_INDEX, not here)", 8'h80, 32'd0);
		expect_reg("I2C window", GHCI_DC_I2C[7:0] + 8'h8, 32'hC3C3C3C3);
		wr(GHCI_DC_I2C[7:0] + 8'h4, 32'h55);
		check("I2C write", {31'd0, saw_i2c}, 32'd1);
		line = 12'd123;
		expect_reg("STATUS idle", GHCI_DC_STATUS[7:0], {4'b0001, 12'd123, 10'd0, 6'b000100});
		idle_in = 0;
		connected = 0;
		pending1 = 1;
		expect_reg("STATUS busy", GHCI_DC_STATUS[7:0], {4'b0100, 12'd123, 10'd0, 6'b000000});
		idle_in = 1;
		connected = 1;
		pending1 = 0;
		if (errors == e0)
			$display("PASS atg_dc_regs.map");

		/* bad: the quasi-static registers and FORMAT while ENABLE is 1. */
		e0 = errors;
		wr(GHCI_DC_CTRL[7:0], 32'h0000_0001);	/* ENABLE, FORMAT 0 */
		n = n_error;
		wr(GHCI_DC_FB_STRIDE[7:0], 32'd1280);
		expect_reg("FB_STRIDE kept", GHCI_DC_FB_STRIDE[7:0], 32'd2560);
		rd(GHCI_DC_STATUS[7:0], v);
		check("BAD_WRITE", {31'd0, v[GHCI_DC_ST_BAD_WRITE]}, 32'd1);
		check("DISP_ERROR for BAD_WRITE", n_error - n, 1);
		wr(GHCI_DC_TIMING[7:0] + 8'h10, 32'd720);
		expect_reg("V_ACTIVE kept", GHCI_DC_TIMING[7:0] + 8'h10, 32'h104);
		wr(GHCI_DC_PCLK_SEL[7:0], 32'd0);
		expect_reg("PCLK_SEL kept", GHCI_DC_PCLK_SEL[7:0], 32'd1);
		check("one DISP_ERROR in the frame", n_error - n, 1);
		wr(GHCI_DC_CTRL[7:0], 32'h0000_0015);	/* FORMAT 1 with ENABLE: refused; TEST taken */
		expect_reg("CTRL FORMAT kept", GHCI_DC_CTRL[7:0], 32'h0000_0005);
		wr(GHCI_DC_STATUS[7:0], 32'h0000_0020);	/* W1C BAD_WRITE */
		rd(GHCI_DC_STATUS[7:0], v);
		check("BAD_WRITE cleared", {31'd0, v[GHCI_DC_ST_BAD_WRITE]}, 32'd0);
		wr(GHCI_DC_CTRL[7:0], 32'h0000_0000);
		wr(GHCI_DC_FB_STRIDE[7:0], 32'd1280);	/* disabled: taken */
		expect_reg("FB_STRIDE disabled", GHCI_DC_FB_STRIDE[7:0], 32'd1280);
		rd(GHCI_DC_STATUS[7:0], v);
		check("no BAD_WRITE disabled", {31'd0, v[GHCI_DC_ST_BAD_WRITE]}, 32'd0);
		if (errors == e0)
			$display("PASS atg_dc_regs.bad");

		/* flip: plane 0. */
		e0 = errors;
		n = n_taken;
		c0 = n_cancel;
		flip(32'h2000_0000);	/* disabled: at once, taken */
		check("flip at once", fb_base, 32'h2000_0000);
		check("taken at once", n_taken - n, 1);
		check("not cancelled", n_cancel - c0, 0);
		check("nothing pending", {31'd0, pending}, 32'd0);
		wr(GHCI_DC_CTRL[7:0], 32'h0000_0001);
		flip(32'h2100_0000);
		check("pending", {31'd0, pending}, 32'd1);
		expect_reg("FB_BASE before vsync", GHCI_DC_FB_BASE[7:0], 32'h2000_0000);
		rd(GHCI_DC_STATUS[7:0], v);
		check("STATUS[29]", {31'd0, v[GHCI_DC_ST_PENDING0]}, 32'd1);
		check("no take before vsync", n_taken - n, 1);
		vsync;
		expect_reg("FB_BASE after vsync", GHCI_DC_FB_BASE[7:0], 32'h2100_0000);
		check("taken at vsync", n_taken - n, 2);
		check("no cancel at vsync", n_cancel - c0, 0);
		vsync;
		check("no take without a flip", n_taken - n, 2);
		/* ENABLE falling takes a pending flip as cancelled. */
		flip(32'h2200_0000);
		wr(GHCI_DC_CTRL[7:0], 32'h0000_0000);
		check("cancelled by ENABLE", n_cancel - c0, 1);
		check("taken (cancelled)", n_taken - n, 3);
		check("pending cleared", {31'd0, pending}, 32'd0);
		expect_reg("FB_BASE kept", GHCI_DC_FB_BASE[7:0], 32'h2100_0000);
		/* A host FB_NEXT over a flip of the CP: cancelled, the host's image pending. */
		wr(GHCI_DC_CTRL[7:0], 32'h0000_0001);
		flip(32'h2300_0000);
		wr(GHCI_DC_FB_NEXT[7:0], 32'h2400_0000);
		check("cancelled by FB_NEXT", n_cancel - c0, 2);
		check("host's pending", {31'd0, pending}, 32'd1);
		t0 = n_taken;
		vsync;
		expect_reg("host's image at vsync", GHCI_DC_FB_BASE[7:0], 32'h2400_0000);
		check("no taken for the host's", n_taken - t0, 0);
		/* CTRL.RESET takes a pending flip as cancelled. */
		flip(32'h2500_0000);
		wr(GHCI_DC_CTRL[7:0], 32'h0000_0003);
		check("cancelled by RESET", n_cancel - c0, 3);
		while (dc_reset)
			@(negedge clk);
		if (errors == e0)
			$display("PASS atg_dc_regs.flip");

		/* status: the sticky bits, W1C, DISP_ERROR once a frame, FRAME_COUNT, RESET. */
		e0 = errors;
		wr(GHCI_DC_CTRL[7:0], 32'h0000_0001);
		vsync;
		n = n_error;
		pulse(0);
		pulse(1);
		pulse(2);
		pulse(3);
		rd(GHCI_DC_STATUS[7:0], v);
		check("sticky [1] [3] [4] [5]", {26'd0, v[5:0]}, 32'h3B);
		check("DISP_ERROR once a frame", n_error - n, 1);
		vsync;
		pulse(1);
		check("DISP_ERROR in the next frame", n_error - n, 2);
		wr(GHCI_DC_STATUS[7:0], 32'h0000_000A);	/* W1C [1] and [3] */
		rd(GHCI_DC_STATUS[7:0], v);
		check("W1C [1] [3]", {26'd0, v[5:0]}, 32'h31);
		/* Set and clear in the same cycle: set wins. */
		@(negedge clk);
		rd_err = 1;
		d_we = 1;
		d_idx = GHCI_DC_STATUS[7:2];
		d_wdata = 32'h8;
		@(negedge clk);
		rd_err = 0;
		d_we = 0;
		rd(GHCI_DC_STATUS[7:0], v);
		check("set wins", {31'd0, v[3]}, 32'd1);
		wr(GHCI_DC_CTRL[7:0], 32'h0000_0000);
		n = n_error;
		pulse(3);
		pulse(3);
		check("disabled: every error", n_error - n, 2);
		pulse(0);
		rd(GHCI_DC_STATUS[7:0], v);
		check("underflow while disabled", {31'd0, v[1]}, 32'd1);
		wr(GHCI_DC_CTRL[7:0], 32'h0000_0001);
		rd(GHCI_DC_STATUS[7:0], v);
		check("ENABLE 0 -> 1 clears underflow", {31'd0, v[1]}, 32'd0);
		k = frame_count;
		vsync;
		check("FRAME_COUNT", frame_count - k, 1);
		check("VBLANK while enabled", n_vblank > 0, 1);
		wr(GHCI_DC_CTRL[7:0], 32'h0000_0003);
		n = 0;
		while (dc_reset) begin
			@(negedge clk);
			n = n + 1;
		end
		if (n < 30 || n > 33) begin
			errors = errors + 1;
			$display("FAIL atg_dc_regs.status reset pulse %0d cycles", n);
		end
		expect_reg("CTRL after RESET", GHCI_DC_CTRL[7:0], 32'h0);
		expect_reg("FRAME_COUNT after RESET", GHCI_DC_FRAME_COUNT[7:0], 32'h0);
		expect_reg("STATUS after RESET", GHCI_DC_STATUS[7:0], {4'b0001, 12'd123, 10'd0, 6'b000100});
		expect_reg("FB_SIZE kept", GHCI_DC_FB_SIZE[7:0], {16'd480, 16'd640});
		if (errors == e0)
			$display("PASS atg_dc_regs.status");

		if (errors == 0)
			$display("PASS atg_dc_regs");
		$finish;
	end

	initial begin
		#200000;
		$display("FAIL atg_dc_regs timeout");
		$finish;
	end
endmodule

`default_nettype wire
