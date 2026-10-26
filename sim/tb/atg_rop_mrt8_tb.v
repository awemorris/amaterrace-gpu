/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_mrt8_tb: Unit test for MRT 8 attachments (Phase 003, CAPS[30]).
 *
 * Verifies:
 *   1. 8-attachment configuration via STATE registers (0x070-0x08D and 0x1B0-0x1BD).
 *   2. G-Buffer simultaneous rendering across 8 attachments (Albedo, Normal, Position,
 *      Specular, Roughness, Metalness, Emissive, Custom).
 *   3. Format packing and memory layout across distinct pixel formats (RGBA8, R8, etc.).
 *   4. Hazard Tracker validation: same coordinate on different RTs issues without
 *      RAW hazard (streaming throughput); same coordinate on same RT detects hazard and stalls.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_mrt8_tb;
	`include "ghci_regs.vh"

	localparam LINE_BYTES = 32;
	localparam LINE_SHIFT = 5;
	localparam LA_W = 32 - LINE_SHIFT;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;

	reg d_valid = 1'b0;
	reg [31:0] d_xy = 0;
	reg [15:0] d_smask = 16'h0000;
	reg [511:0] d_color = 0;
	reg [2:0] d_rt = 3'd0;
	reg d_nocol = 1'b0;

	wire d_ready, b_valid, b_rvalid, busy;
	wire [511:0] b_src;
	wire [127:0] b_dst, b_pix;
	wire [3:0] b_mask;
	wire [2:0] b_rt;

	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [LA_W-1:0] req_line;
	wire [LINE_BYTES-1:0] req_be;
	wire [LINE_BYTES*8-1:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;

	integer errors = 0;

	atg_rop_wb #(
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT)
	) dut_wb (
		.clk(clk),
		.rst_n(rst_n),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.d_valid(d_valid),
		.d_ready(d_ready),
		.d_xy(d_xy),
		.d_smask(d_smask),
		.d_color(d_color),
		.d_rt(d_rt),
		.d_nocol(d_nocol),
		.b_valid(b_valid),
		.b_src(b_src),
		.b_dst(b_dst),
		.b_mask(b_mask),
		.b_rt(b_rt),
		.b_rvalid(b_rvalid),
		.b_pix(b_pix),
		.busy(busy),
		.req_valid(req_valid),
		.req_ready(req_ready),
		.req_write(req_write),
		.req_line(req_line),
		.req_be(req_be),
		.req_wdata(req_wdata),
		.req_tag(req_tag),
		.rsp_valid(rsp_valid),
		.rsp_write(rsp_write),
		.rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata),
		.rsp_error(rsp_error)
	);

	atg_rop_blend dut_blend (
		.clk(clk),
		.rst_n(rst_n),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.b_valid(b_valid),
		.b_src(b_src),
		.b_src1(512'd0),
		.b_has_src1(1'b0),
		.b_dst(b_dst),
		.b_mask(b_mask),
		.b_rt(b_rt),
		.b_rvalid(b_rvalid),
		.b_pix(b_pix)
	);

	amb_mem #(
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.MEM_WORDS(65536),
		.SEED(1)
	) mem (
		.clk(clk),
		.rst_n(rst_n),
		.req_valid(req_valid),
		.req_ready(req_ready),
		.req_write(req_write),
		.req_line(req_line),
		.req_be(req_be),
		.req_wdata(req_wdata),
		.req_tag(req_tag),
		.rsp_valid(rsp_valid),
		.rsp_write(rsp_write),
		.rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata),
		.rsp_error(rsp_error)
	);

	task fail;
		input [8*48-1:0] what;
		begin
			$display("FAIL atg_rop_mrt8.%0s", what);
			errors = errors + 1;
		end
	endtask

	task st_put;
		input [8:0] i_;
		input [31:0] val;
		begin
			@(negedge clk);
			st_we <= 1'b1;
			st_idx <= i_;
			st_wdata <= val;
			@(posedge clk);
			st_we <= 1'b0;
		end
	endtask

	task send_beat;
		input [2:0] rt_idx;
		input [31:0] xy;
		input [511:0] col;
		begin
			@(posedge clk);
			d_valid <= 1'b1;
			d_rt <= rt_idx;
			d_xy <= xy;
			d_color <= col;
			d_nocol <= 1'b0;
			d_smask <= 16'h1111; /* 4 lanes active, 1 sample */
			@(posedge clk);
			while (!d_ready) @(posedge clk);
			d_valid <= 1'b0;
		end
	endtask

	/* Wait until ROP pipeline and cache writeback drain to memory */
	task drain;
		integer dc;
		begin
			repeat (30) @(posedge clk);
			while (busy) @(posedge clk);
		end
	endtask

	/* Constant color generator helper: fills all 4 lanes with same RGBA fp32 */
	function [511:0] make_col;
		input [31:0] r;
		input [31:0] g;
		input [31:0] b;
		input [31:0] a;
		begin
			make_col = {
				{a, b, g, r},
				{a, b, g, r},
				{a, b, g, r},
				{a, b, g, r}
			};
		end
	endfunction

	integer k, ec;
	reg [31:0] peek_val;

	initial begin
		repeat (3) @(negedge clk);
		rst_n = 1'b1;
		repeat (3) @(posedge clk);

		/*
		 * TEST 1: 8-Attachment Configuration
		 * Program base addresses, strides, formats and write masks for RT0-RT7.
		 */
		ec = errors;

		/* RT0 (0x070, 0x071) */
		st_put(GHCI_S_RT_BASE, 32'h00001000);
		st_put(GHCI_S_RT_STRIDE, 32'd256);

		/* RT1-3 (0x07E-0x083) */
		st_put(GHCI_S_RT1_BASE + 9'd0, 32'h00002000); /* RT1_BASE */
		st_put(GHCI_S_RT1_BASE + 9'd1, 32'd256);      /* RT1_STRIDE */
		st_put(GHCI_S_RT1_BASE + 9'd2, 32'h00003000); /* RT2_BASE */
		st_put(GHCI_S_RT1_BASE + 9'd3, 32'd256);      /* RT2_STRIDE */
		st_put(GHCI_S_RT1_BASE + 9'd4, 32'h00004000); /* RT3_BASE */
		st_put(GHCI_S_RT1_BASE + 9'd5, 32'd256);      /* RT3_STRIDE */

		/* RT4-7 (0x1B0-0x1B7) */
		st_put(GHCI_S_RT4_BASE, 32'h00005000);
		st_put(GHCI_S_RT4_STRIDE, 32'd256);
		st_put(GHCI_S_RT5_BASE, 32'h00006000);
		st_put(GHCI_S_RT5_STRIDE, 32'd256);
		st_put(GHCI_S_RT6_BASE, 32'h00007000);
		st_put(GHCI_S_RT6_STRIDE, 32'd256);
		st_put(GHCI_S_RT7_BASE, 32'h00008000);
		st_put(GHCI_S_RT7_STRIDE, 32'd256);

		/* Formats: RT0-3 = RGBA8 (VkFormat 37 = 0x25), RT4-7 = RGBA8 */
		st_put(GHCI_S_RT_FORMATS, 32'h25252525);
		st_put(GHCI_S_RT_FORMATS1, 32'h25252525);

		/* Write mask: all 8 attachments RGBA enabled (4 bits each = 32'hFFFFFFFF) */
		st_put(GHCI_S_WRITE_MASK, 32'hFFFFFFFF);

		/* Blend: disable for all (direct write) */
		st_put(GHCI_S_BLEND, 32'd0);
		st_put(GHCI_S_BLEND1 + 9'd0, 32'd0);
		st_put(GHCI_S_BLEND1 + 9'd1, 32'd0);
		st_put(GHCI_S_BLEND1 + 9'd2, 32'd0);
		st_put(GHCI_S_BLEND4 + 9'd0, 32'd0);
		st_put(GHCI_S_BLEND4 + 9'd1, 32'd0);
		st_put(GHCI_S_BLEND4 + 9'd2, 32'd0);
		st_put(GHCI_S_BLEND4 + 9'd3, 32'd0);

		@(posedge clk);
		if (dut_wb.wpix.base[0] !== 32'h00001000 || dut_wb.wpix.base[7] !== 32'h00008000)
			fail("config base");
		if (dut_wb.wpix.stride[0] !== 32'd256 || dut_wb.wpix.stride[7] !== 32'd256)
			fail("config stride");
		if (dut_wb.wpix.fmts !== 64'h2525252525252525)
			fail("config fmts");
		if (dut_wb.wpix.wms !== 32'hFFFFFFFF)
			fail("config wms");

		if (errors == ec)
			$display("PASS atg_rop_mrt8.config");

		/*
		 * TEST 2: G-Buffer 8-Attachment Simultaneous Output
		 * Render 8 distinct colour channels into RT0..RT7 at coordinate (0, 0).
		 */
		ec = errors;

		/* Send 8 beats in sequence (one per attachment) */
		send_beat(3'd0, 32'h00000000, make_col(32'h3F800000, 32'h0, 32'h0, 32'h3F800000)); /* RT0: Red (1,0,0,1) */
		send_beat(3'd1, 32'h00000000, make_col(32'h0, 32'h3F800000, 32'h0, 32'h3F800000)); /* RT1: Green (0,1,0,1) */
		send_beat(3'd2, 32'h00000000, make_col(32'h0, 32'h0, 32'h3F800000, 32'h3F800000)); /* RT2: Blue (0,0,1,1) */
		send_beat(3'd3, 32'h00000000, make_col(32'h3F800000, 32'h3F800000, 32'h0, 32'h3F800000)); /* RT3: Yellow (1,1,0,1) */
		send_beat(3'd4, 32'h00000000, make_col(32'h3F800000, 32'h0, 32'h3F800000, 32'h3F800000)); /* RT4: Magenta (1,0,1,1) */
		send_beat(3'd5, 32'h00000000, make_col(32'h0, 32'h3F800000, 32'h3F800000, 32'h3F800000)); /* RT5: Cyan (0,1,1,1) */
		send_beat(3'd6, 32'h00000000, make_col(32'h3F000000, 32'h3F000000, 32'h3F000000, 32'h3F800000)); /* RT6: Gray (0.5,0.5,0.5,1) */
		send_beat(3'd7, 32'h00000000, make_col(32'h3F800000, 32'h3F800000, 32'h3F800000, 32'h3F800000)); /* RT7: White (1,1,1,1) */

		drain();

		/* Verify memory at each base address: RGBA8 unorm pixel (R in low byte [7:0], G in [15:8], B in [23:16], A in [31:24]) */
		peek_val = mem.peek(32'h00001000);
		if (peek_val !== 32'hFF0000FF) begin /* Red: A=FF, B=00, G=00, R=FF */
			fail("gbuffer RT0 red");
			$display("  RT0 got %h, want FF0000FF", peek_val);
		end

		peek_val = mem.peek(32'h00002000);
		if (peek_val !== 32'hFF00FF00) begin /* Green */
			fail("gbuffer RT1 green");
			$display("  RT1 got %h, want FF00FF00", peek_val);
		end

		peek_val = mem.peek(32'h00003000);
		if (peek_val !== 32'hFFFF0000) begin /* Blue */
			fail("gbuffer RT2 blue");
			$display("  RT2 got %h, want FFFF0000", peek_val);
		end

		peek_val = mem.peek(32'h00004000);
		if (peek_val !== 32'hFF00FFFF) begin /* Yellow */
			fail("gbuffer RT3 yellow");
			$display("  RT3 got %h, want FF00FFFF", peek_val);
		end

		peek_val = mem.peek(32'h00005000);
		if (peek_val !== 32'hFFFF00FF) begin /* Magenta */
			fail("gbuffer RT4 magenta");
			$display("  RT4 got %h, want FFFF00FF", peek_val);
		end

		peek_val = mem.peek(32'h00006000);
		if (peek_val !== 32'hFFFFFF00) begin /* Cyan */
			fail("gbuffer RT5 cyan");
			$display("  RT5 got %h, want FFFFFF00", peek_val);
		end

		peek_val = mem.peek(32'h00007000);
		if (peek_val[31:24] !== 8'hFF || peek_val[7:0] < 8'h70) begin /* Gray */
			fail("gbuffer RT6 gray");
			$display("  RT6 got %h, want ~FF808080", peek_val);
		end

		peek_val = mem.peek(32'h00008000);
		if (peek_val !== 32'hFFFFFFFF) begin /* White */
			fail("gbuffer RT7 white");
			$display("  RT7 got %h, want FFFFFFFF", peek_val);
		end

		if (errors == ec)
			$display("PASS atg_rop_mrt8.gbuffer");

		/*
		 * TEST 3: Mixed Pixel Formats across Attachments
		 * Test R8 (1 byte/pixel, VkFormat 9) on RT4 and RT5, RGBA8 on others.
		 */
		ec = errors;

		/* Reconfigure RT4 and RT5 format to R8_UNORM (9 = 0x09) */
		st_put(GHCI_S_RT_FORMATS1, {8'd37, 8'd37, 8'd09, 8'd09});

		/* Render to RT4 and RT5 at coordinate (x=0, y=0) */
		send_beat(3'd4, 32'h00000000, make_col(32'h3F800000, 32'h0, 32'h0, 32'h0)); /* R=1.0 -> 0xFF */
		send_beat(3'd5, 32'h00000000, make_col(32'h3F000000, 32'h0, 32'h0, 32'h0)); /* R=0.5 -> 0x80 */

		drain();

		/* For R8_UNORM, a 2x2 quad takes 4 bytes total: lane 0 at +0, lane 1 at +1, lane 2 at stride+0, lane 3 at stride+1 */
		peek_val = mem.peek(32'h00005000);
		if (peek_val[7:0] !== 8'hFF) begin
			fail("format R8 RT4");
			$display("  RT4 R8 got byte %h, want FF", peek_val[7:0]);
		end

		peek_val = mem.peek(32'h00006000);
		if (peek_val[7:0] < 8'h70 || peek_val[7:0] > 8'h90) begin
			fail("format R8 RT5");
			$display("  RT5 R8 got byte %h, want ~80", peek_val[7:0]);
		end

		if (errors == ec)
			$display("PASS atg_rop_mrt8.formats");

		/*
		 * TEST 4: Hazard Tracker with 3-bit RT
		 * Verify that identical coordinates on DIFFERENT RT attachments (0 vs 1..7)
		 * do not hit hazard, while identical coordinates on the SAME RT attachment hit hazard.
		 */
		ec = errors;

		if (dut_wb.u_hazard.TAG_W !== 33)
			fail("hazard TAG_W");

		/* Send beat to RT0 and wait for pipeline commit */
		send_beat(3'd0, {16'd4, 16'd4}, make_col(32'h3F800000, 32'd0, 32'd0, 32'd0));
		drain();

		/* Test CAM matching across RT bits */
		@(negedge clk);
		dut_wb.u_hazard.valid[0] = 1'b1;
		d_xy = {16'd4, 16'd4};
		dut_wb.u_hazard.tag[0] = {3'd0, d_xy[31:17], d_xy[15:1]}; /* RT=0, Y=4, X=4 */

		/* Check RT=1 with same Y=4, X=4: MUST NOT hit hazard (alloc_ready == 1) */
		d_rt = 3'd1;
		#1;
		if (!dut_wb.alloc_ready)
			fail("hazard: different RT (1 vs 0) falsely hit hazard");

		/* Check RT=2 with same Y=4, X=4: MUST NOT hit hazard (alloc_ready == 1) */
		d_rt = 3'd2;
		#1;
		if (!dut_wb.alloc_ready)
			fail("hazard: different RT (2 vs 0) falsely hit hazard");

		/* Check RT=7 with same Y=4, X=4: MUST NOT hit hazard (alloc_ready == 1) */
		d_rt = 3'd7;
		#1;
		if (!dut_wb.alloc_ready)
			fail("hazard: different RT (7 vs 0) falsely hit hazard");

		/* Check RT=0 with same Y=4, X=4: MUST hit hazard (alloc_ready == 0) */
		d_rt = 3'd0;
		#1;
		if (dut_wb.alloc_ready)
			fail("hazard: same RT (0 vs 0) failed to detect hazard");

		/* Clean up CAM entry */
		@(negedge clk);
		dut_wb.u_hazard.valid[0] = 1'b0;

		if (errors == ec)
			$display("PASS atg_rop_mrt8.hazard");

		/* Summary */
		if (errors == 0)
			$display("PASS atg_rop_mrt8");

		$finish;
	end

	initial begin
		#10000000;
		$display("FAIL atg_rop_mrt8 timeout");
		$finish;
	end

endmodule
`default_nettype wire
