/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_mode_tb: the mode table through MODE_INDEX (both modes against
 * CTA-861 formats 1 and 4, an index without a mode), CONNECTED (its reset
 * value, HOTPLUG only on a change, the DC's reset), and the cursor's
 * registers (CURSOR_POS with strobes, CURSOR_CTRL, CURSOR_BASE from the
 * cursor); and a second instance with TEST_MODE 1 on the same bus: its one
 * small mode at index 0 and nothing at index 1.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_mode_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg d_we = 0, dc_reset = 0;
	reg [5:0] d_idx = 0, d_ridx = 0;
	reg [31:0] d_wdata = 0, d_wmask = 32'hFFFFFFFF;
	wire [31:0] d_rdata, cur_pos;
	wire connected, ev_hotplug, cur_show;
	wire [31:0] t_rdata, t_cur_pos;
	wire t_connected, t_ev_hotplug, t_cur_show;

	atg_dc_mode dut (
		.clk(clk), .rst_n(rst_n), .dc_reset(dc_reset),
		.d_we(d_we), .d_idx(d_idx), .d_wdata(d_wdata), .d_wmask(d_wmask), .d_ridx(d_ridx),
		.d_rdata(d_rdata), .connected(connected), .ev_hotplug(ev_hotplug),
		.cur_pos(cur_pos), .cur_show(cur_show), .cursor_base(32'h3000_0040)
	);

	atg_dc_mode #(.TEST_MODE(1)) tdut (
		.clk(clk), .rst_n(rst_n), .dc_reset(dc_reset),
		.d_we(d_we), .d_idx(d_idx), .d_wdata(d_wdata), .d_wmask(d_wmask), .d_ridx(d_ridx),
		.d_rdata(t_rdata), .connected(t_connected), .ev_hotplug(t_ev_hotplug),
		.cur_pos(t_cur_pos), .cur_show(t_cur_show), .cursor_base(32'h3000_0040)
	);

	integer n_hot = 0;
	always @(posedge clk)
		if (ev_hotplug)
			n_hot = n_hot + 1;

	integer errors = 0;
	integer e0;
	reg [31:0] v;

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
			@(negedge clk);
		end
	endtask

	task check;
		input [8*40-1:0] what;
		input [31:0] got;
		input [31:0] want;
		begin
			if (got !== want) begin
				errors = errors + 1;
				$display("FAIL atg_dc_mode.%0s: %h, expected %h", what, got, want);
			end
		end
	endtask

	task expect_reg;
		input [8*40-1:0] what;
		input [7:0] off;
		input [31:0] want;
		begin
			@(negedge clk);
			d_ridx = off[7:2];
			#1;
			check(what, d_rdata, want);
		end
	endtask

	/* The same, of the TEST_MODE instance. */
	task expect_test;
		input [8*40-1:0] what;
		input [7:0] off;
		input [31:0] want;
		begin
			@(negedge clk);
			d_ridx = off[7:2];
			#1;
			check(what, t_rdata, want);
		end
	endtask

	initial begin
		repeat (3) @(posedge clk);
		rst_n = 1;

		/* modes */
		e0 = errors;
		expect_reg("MODE_INDEX reset", GHCI_DC_MODE_INDEX[7:0], 32'd0);
		expect_reg("480 H0", GHCI_DC_MODE_H0[7:0], {16'd96, 16'd640});
		expect_reg("480 H1", GHCI_DC_MODE_H1[7:0], {16'd48, 16'd16});
		expect_reg("480 V0", GHCI_DC_MODE_V0[7:0], {16'd2, 16'd480});
		expect_reg("480 V1", GHCI_DC_MODE_V1[7:0], {16'd33, 16'd10});
		expect_reg("480 CLOCK", GHCI_DC_MODE_CLOCK[7:0], 32'd25200);
		expect_reg("480 FLAGS", GHCI_DC_MODE_FLAGS[7:0], 32'h00);
		wr(GHCI_DC_MODE_INDEX[7:0], 32'd1);
		expect_reg("MODE_INDEX", GHCI_DC_MODE_INDEX[7:0], 32'd1);
		expect_reg("720 H0", GHCI_DC_MODE_H0[7:0], {16'd40, 16'd1280});
		expect_reg("720 H1", GHCI_DC_MODE_H1[7:0], {16'd220, 16'd110});
		expect_reg("720 V0", GHCI_DC_MODE_V0[7:0], {16'd5, 16'd720});
		expect_reg("720 V1", GHCI_DC_MODE_V1[7:0], {16'd20, 16'd5});
		expect_reg("720 CLOCK", GHCI_DC_MODE_CLOCK[7:0], 32'd74250);
		expect_reg("720 FLAGS", GHCI_DC_MODE_FLAGS[7:0], 32'h13);
		/* The totals give the clock at 60 Hz. */
		check("720 total", (1280 + 110 + 40 + 220) * (720 + 5 + 5 + 20) * 60 / 1000, 74250);
		check("480 total", (640 + 16 + 96 + 48) * (480 + 10 + 2 + 33) * 60 / 1000, 25200);
		wr(GHCI_DC_MODE_INDEX[7:0], 32'd2);
		expect_reg("no mode 2", GHCI_DC_MODE_CLOCK[7:0], 32'd0);
		if (errors == e0)
			$display("PASS atg_dc_mode.modes");

		/* connected */
		e0 = errors;
		expect_reg("CONNECTED reset", GHCI_DC_CONNECTED[7:0], 32'd1);
		check("connected out", {31'd0, connected}, 32'd1);
		wr(GHCI_DC_CONNECTED[7:0], 32'd1);
		check("no HOTPLUG without a change", n_hot, 0);
		wr(GHCI_DC_CONNECTED[7:0], 32'd0);
		check("HOTPLUG on 1 -> 0", n_hot, 1);
		expect_reg("CONNECTED 0", GHCI_DC_CONNECTED[7:0], 32'd0);
		wr(GHCI_DC_CONNECTED[7:0], 32'd0);
		check("no HOTPLUG 0 -> 0", n_hot, 1);
		@(negedge clk);
		dc_reset = 1;
		@(negedge clk);
		dc_reset = 0;
		expect_reg("CONNECTED after the DC's reset", GHCI_DC_CONNECTED[7:0], 32'd1);
		check("no HOTPLUG at the reset", n_hot, 1);
		wr(GHCI_DC_CONNECTED[7:0], 32'd0);
		check("HOTPLUG again", n_hot, 2);
		if (errors == e0)
			$display("PASS atg_dc_mode.connected");

		/* cursor */
		e0 = errors;
		expect_reg("CURSOR_BASE", GHCI_DC_CURSOR_BASE[7:0], 32'h3000_0040);
		wr(GHCI_DC_CURSOR_POS[7:0], {16'hFFF0, 16'd100});	/* y = -16, x = 100 */
		expect_reg("CURSOR_POS", GHCI_DC_CURSOR_POS[7:0], {16'hFFF0, 16'd100});
		check("cur_pos out", cur_pos, {16'hFFF0, 16'd100});
		@(negedge clk);
		d_wmask = 32'h0000FFFF;
		wr(GHCI_DC_CURSOR_POS[7:0], {16'd7, 16'd200});
		expect_reg("CURSOR_POS strobes", GHCI_DC_CURSOR_POS[7:0], {16'hFFF0, 16'd200});
		wr(GHCI_DC_CURSOR_CTRL[7:0], 32'd1);
		expect_reg("CURSOR_CTRL", GHCI_DC_CURSOR_CTRL[7:0], 32'd1);
		check("cur_show", {31'd0, cur_show}, 32'd1);
		wr(GHCI_DC_CURSOR_CTRL[7:0], 32'd0);
		check("cur_show 0", {31'd0, cur_show}, 32'd0);
		expect_reg("not here: STATUS", GHCI_DC_STATUS[7:0], 32'd0);
		expect_reg("not here: TAKEN0", GHCI_DC_TAKEN0[7:0], 32'd0);
		if (errors == e0)
			$display("PASS atg_dc_mode.cursor");

		/* test: TEST_MODE's one mode (MODE_INDEX is written on both instances' bus). */
		e0 = errors;
		wr(GHCI_DC_MODE_INDEX[7:0], 32'd0);
		expect_test("test H0", GHCI_DC_MODE_H0[7:0], {16'd8, 16'd320});
		expect_test("test H1", GHCI_DC_MODE_H1[7:0], {16'd8, 16'd8});
		expect_test("test V0", GHCI_DC_MODE_V0[7:0], {16'd2, 16'd240});
		expect_test("test V1", GHCI_DC_MODE_V1[7:0], {16'd2, 16'd2});
		expect_test("test CLOCK", GHCI_DC_MODE_CLOCK[7:0], 32'd25000);
		expect_test("test FLAGS", GHCI_DC_MODE_FLAGS[7:0], 32'h00);
		expect_reg("board mode 0 beside it", GHCI_DC_MODE_H0[7:0], {16'd96, 16'd640});
		wr(GHCI_DC_MODE_INDEX[7:0], 32'd1);
		expect_test("test: no mode 1 H0", GHCI_DC_MODE_H0[7:0], 32'd0);
		expect_test("test: no mode 1 CLOCK", GHCI_DC_MODE_CLOCK[7:0], 32'd0);
		expect_test("test CONNECTED", GHCI_DC_CONNECTED[7:0], 32'd0);
		if (errors == e0)
			$display("PASS atg_dc_mode.test");

		if (errors == 0)
			$display("PASS atg_dc_mode");
		$finish;
	end

	initial begin
		#100000;
		$display("FAIL atg_dc_mode timeout");
		$finish;
	end
endmodule

`default_nettype wire
