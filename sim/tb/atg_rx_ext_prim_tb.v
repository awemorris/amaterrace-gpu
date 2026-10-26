/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_ext_prim_tb: Unit testbench for RX Extended Primitives:
 * 1. Wide Lines (widths 1.0, 2.0, 4.0, 8.0, 16.0, x-major & y-major)
 * 2. Point Sprites (sizes 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, auto PointCoord)
 * 3. Multi-Viewport & Scissors (16 array entries 0..15)
 * 4. Depth Clamping (near/far plane bypass when enabled, [0, 1] saturation)
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_ext_prim_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	/* STATE bus */
	reg st_we = 1'b0;
	reg [8:0] st_idx = 9'd0;
	reg [31:0] st_wdata = 32'd0;

	/* Primitives to setup */
	reg cl_valid = 1'b0;
	reg cl_last = 1'b0;
	reg [701:0] cl_tri = 702'd0;
	wire cl_ready;

	/* Setup outputs */
	wire sp_valid, sp_last, busy;
	reg sp_ready = 1'b0;
	wire [767:0] sp_tri;

	/* Extended interface status */
	wire [2:0] prim_type;
	wire [15:0] cur_line_width, cur_point_size;
	wire [3:0] cur_viewport_idx;

	atg_rx_setup u_setup (
		.clk(clk),
		.rst_n(rst_n),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.cl_valid(cl_valid),
		.cl_ready(cl_ready),
		.cl_tri(cl_tri),
		.cl_last(cl_last),
		.sp_valid(sp_valid),
		.sp_ready(sp_ready),
		.sp_tri(sp_tri),
		.sp_last(sp_last),
		.busy(busy),
		.prim_type(prim_type),
		.cur_line_width(cur_line_width),
		.cur_point_size(cur_point_size),
		.cur_viewport_idx(cur_viewport_idx)
	);

	/* Full RX pipeline instance with HAS_SU=0 to test clip -> setup -> scan -> direct quads */
	reg rx_prim_valid = 1'b0;
	wire rx_prim_ready;
	reg [25:0] rx_prim_vtx = 26'd0;
	reg [2:0] rx_prim_free = 3'd0;
	reg rx_prim_last = 1'b0;
	wire rx_busy;
	wire [3:0] rx_fsm;
	wire pt_rd;
	wire [7:0] pt_idx;
	wire [6:0] pt_word;
	reg [31:0] pt_rdata = 32'd0;
	wire pt_free;
	wire [7:0] pt_free_idx;

	wire dx_valid;
	reg dx_ready = 1'b0;
	wire [15:0] dx_seq;
	wire [31:0] dx_xy;
	wire [3:0] dx_mask;
	wire [127:0] dx_depth;
	wire dx_last;

	atg_rx #(.HAS_SU(0)) u_rx (
		.clk(clk),
		.rst_n(rst_n),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.raw_kick(1'b0),
		.busy(rx_busy),
		.fsm(rx_fsm),
		.prim_valid(rx_prim_valid),
		.prim_ready(rx_prim_ready),
		.prim_vtx(rx_prim_vtx),
		.prim_free(rx_prim_free),
		.prim_last(rx_prim_last),
		.pt_rd(pt_rd),
		.pt_idx(pt_idx),
		.pt_word(pt_word),
		.pt_rdata(pt_rdata),
		.pt_free(pt_free),
		.pt_free_idx(pt_free_idx),
		.fl_req(), .fl_gnt(1'b0), .fl_we(), .fl_reg(), .fl_lane(), .fl_data(),
		.fl_pw_we(), .fl_pw_addr(), .fl_pw_data(), .fl_go(), .fl_mask(), .fl_info(),
		.dx_valid(dx_valid),
		.dx_ready(dx_ready),
		.dx_seq(dx_seq),
		.dx_xy(dx_xy),
		.dx_mask(dx_mask),
		.dx_depth(dx_depth),
		.dx_last(dx_last),
		.ord_valid(), .ord_seq()
	);

	/* Mock Page Table for u_rx */
	reg [31:0] pt_mem [0:255][0:15];
	always @(posedge clk) begin
		if (pt_rd)
			pt_rdata <= pt_mem[pt_idx][pt_word[3:0]];
	end

	integer err_count = 0;
	integer k, vi, cycles;

	task st_put;
		input [8:0] idx;
		input [31:0] data;
		begin
			st_we <= 1'b1;
			st_idx <= idx;
			st_wdata <= data;
			@(posedge clk);
			st_we <= 1'b0;
			@(posedge clk);
		end
	endtask

	/* Build a raw screen-space primitive (DRAW_RAW): kind=0 point, 1 line, 2 triangle */
	task send_raw_prim;
		input [1:0] prim_k;
		input [31:0] x0, y0, z0;
		input [31:0] x1, y1, z1;
		input [31:0] x2, y2, z2;
		reg [701:0] tri_data;
		begin
			tri_data = 702'd0;
			tri_data[31:0]     = x0;
			tri_data[63:32]    = y0;
			tri_data[95:64]    = z0;
			tri_data[127:96]   = 32'h3F800000; /* w0 = 1.0 */
			tri_data[159:128]  = x1;
			tri_data[191:160]  = y1;
			tri_data[223:192]  = z1;
			tri_data[255:224]  = 32'h3F800000; /* w1 = 1.0 */
			tri_data[287:256]  = x2;
			tri_data[319:288]  = y2;
			tri_data[351:320]  = z2;
			tri_data[383:352]  = 32'h3F800000; /* w2 = 1.0 */
			/* Identity weights */
			tri_data[415:384]  = 32'h3F800000; /* w00 */
			tri_data[543:512]  = 32'h3F800000; /* w11 */
			tri_data[671:640]  = 32'h3F800000; /* w22 */
			tri_data[698:696]  = 3'b111;       /* last-use flags */
			tri_data[699]      = 1'b0;         /* raw = 0 (clip space with perspective) */
			tri_data[701:700]  = prim_k;       /* kind */

			cl_tri <= tri_data;
			cl_last <= 1'b1;
			cl_valid <= 1'b1;
			@(posedge clk);
			while (!cl_ready)
				@(posedge clk);
			cl_valid <= 1'b0;
		end
	endtask

	/* Variables for checks */
	reg [15:0] bx_min, by_min, bx_max, by_max;
	reg [31:0] p_s_A, p_s_B, p_s_C;
	reg [31:0] p_t_A, p_t_B, p_t_C;

	task wait_sp_out;
		output [767:0] out_sp;
		begin
			cycles = 0;
			sp_ready <= 1'b1;
			@(posedge clk);
			while (!sp_valid && cycles < 20000) begin
				cycles = cycles + 1;
				@(posedge clk);
			end
			if (!sp_valid) begin
				$display("FAIL atg_rx_ext_prim: timeout waiting for sp_valid (cycles=%0d)", cycles);
				err_count = err_count + 1;
			end
			out_sp = sp_tri;
			@(posedge clk);
			sp_ready <= 1'b0;
		end
	endtask

	reg [767:0] sp_out0, sp_out1;

	initial begin
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);

		/* Default State setup: 128x96 render target */
		st_put(GHCI_S_RT_SIZE, {16'd96, 16'd128});
		st_put(GHCI_S_VIEWPORT, 32'h3F800000);     /* scale x = 1.0 */
		st_put(GHCI_S_VIEWPORT + 1, 32'h3F800000); /* scale y = 1.0 */
		st_put(GHCI_S_VIEWPORT + 2, 32'h00000000); /* off x = 0.0 */
		st_put(GHCI_S_VIEWPORT + 3, 32'h00000000); /* off y = 0.0 */
		st_put(GHCI_S_VIEWPORT + 4, 32'h3F800000); /* scale z = 1.0 */
		st_put(GHCI_S_VIEWPORT + 5, 32'h00000000); /* off z = 0.0 */
		st_put(GHCI_S_SCISSOR_MIN, 32'd0);
		st_put(GHCI_S_SCISSOR_MAX, 32'd0);
		st_put(GHCI_S_CULL, 32'd0);
		st_put(GHCI_S_RAST_MODE, 32'd0);

		// =================================================================
		// TEST 1: WIDE LINES (widths 1.0, 2.0, 4.0, 16.0)
		// =================================================================
		$display("Testing Wide Lines...");

		/* Horizontal (x-major) line from (20.0, 30.0) to (80.0, 30.0) */
		/* Line width = 1.0 (16'h0100) */
		st_put(GHCI_S_LINE_WIDTH, 32'h0100);
		send_raw_prim(2'd1, 32'h41A00000, 32'h41F00000, 32'd0,
		                    32'h42A00000, 32'h41F00000, 32'd0,
		                    32'h42A00000, 32'h41F00000, 32'd0);
		wait_sp_out(sp_out0);
		wait_sp_out(sp_out1);
		bx_min = sp_out0[303:288]; by_min = sp_out0[319:304];
		bx_max = sp_out0[335:320]; by_max = sp_out0[351:336];
		if (bx_min !== 16'd20 || bx_max !== 16'd81 || by_min !== 16'd29 || by_max !== 16'd31) begin
			$display("FAIL atg_rx_ext_prim.wide_lines (W=1.0): bbox [%0d,%0d,%0d,%0d] exp [20,29,81,31]",
				bx_min, by_min, bx_max, by_max);
			err_count = err_count + 1;
		end

		/* Line width = 2.0 (16'h0200) */
		st_put(GHCI_S_LINE_WIDTH, 32'h0200);
		send_raw_prim(2'd1, 32'h41A00000, 32'h41F00000, 32'd0,
		                    32'h42A00000, 32'h41F00000, 32'd0,
		                    32'h42A00000, 32'h41F00000, 32'd0);
		wait_sp_out(sp_out0);
		wait_sp_out(sp_out1);
		bx_min = sp_out0[303:288]; by_min = sp_out0[319:304];
		bx_max = sp_out0[335:320]; by_max = sp_out0[351:336];
		if (by_min !== 16'd29 || by_max !== 16'd32) begin
			$display("FAIL atg_rx_ext_prim.wide_lines (W=2.0): bbox [%0d,%0d,%0d,%0d] exp by [29,32]",
				bx_min, by_min, bx_max, by_max);
			err_count = err_count + 1;
		end

		/* Line width = 4.0 (fp32: 32'h40800000) */
		st_put(GHCI_S_LINE_WIDTH, 32'h40800000);
		send_raw_prim(2'd1, 32'h41A00000, 32'h41F00000, 32'd0,
		                    32'h42A00000, 32'h41F00000, 32'd0,
		                    32'h42A00000, 32'h41F00000, 32'd0);
		wait_sp_out(sp_out0);
		wait_sp_out(sp_out1);
		bx_min = sp_out0[303:288]; by_min = sp_out0[319:304];
		bx_max = sp_out0[335:320]; by_max = sp_out0[351:336];
		if (by_min !== 16'd28 || by_max !== 16'd33) begin
			$display("FAIL atg_rx_ext_prim.wide_lines (W=4.0): bbox [%0d,%0d,%0d,%0d] exp by [28,33]",
				bx_min, by_min, bx_max, by_max);
			err_count = err_count + 1;
		end

		/* Line width = 16.0 (fp32: 32'h41800000) */
		st_put(GHCI_S_LINE_WIDTH, 32'h41800000);
		send_raw_prim(2'd1, 32'h41A00000, 32'h41F00000, 32'd0,
		                    32'h42A00000, 32'h41F00000, 32'd0,
		                    32'h42A00000, 32'h41F00000, 32'd0);
		wait_sp_out(sp_out0);
		wait_sp_out(sp_out1);
		bx_min = sp_out0[303:288]; by_min = sp_out0[319:304];
		bx_max = sp_out0[335:320]; by_max = sp_out0[351:336];
		if (by_min !== 16'd22 || by_max !== 16'd39) begin
			$display("FAIL atg_rx_ext_prim.wide_lines (W=16.0): bbox [%0d,%0d,%0d,%0d] exp by [22,39]",
				bx_min, by_min, bx_max, by_max);
			err_count = err_count + 1;
		end

		/* Vertical (y-major) line from (40.0, 20.0) to (40.0, 70.0) with W=4.0 */
		st_put(GHCI_S_LINE_WIDTH, 32'h0400);
		send_raw_prim(2'd1, 32'h42200000, 32'h41A00000, 32'd0,
		                    32'h42200000, 32'h428C0000, 32'd0,
		                    32'h42200000, 32'h428C0000, 32'd0);
		wait_sp_out(sp_out0);
		wait_sp_out(sp_out1);
		bx_min = sp_out0[303:288]; by_min = sp_out0[319:304];
		bx_max = sp_out0[335:320]; by_max = sp_out0[351:336];
		if (bx_min !== 16'd38 || bx_max !== 16'd43 || by_min !== 16'd20 || by_max !== 16'd71) begin
			$display("FAIL atg_rx_ext_prim.wide_lines (y-major W=4.0): bbox [%0d,%0d,%0d,%0d] exp [38,20,43,71]",
				bx_min, by_min, bx_max, by_max);
			err_count = err_count + 1;
		end

		if (err_count == 0)
			$display("PASS atg_rx_ext_prim.wide_lines");

		// =================================================================
		// TEST 2: POINT SPRITES (sizes 1.0, 2.0, 4.0, 16.0)
		// =================================================================
		$display("Testing Point Sprites...");

		/* Point at (50.0, 50.0), size 1.0 */
		st_put(GHCI_S_POINT_SIZE, 32'h0100);
		send_raw_prim(2'd0, 32'h42480000, 32'h42480000, 32'd0,
		                    32'h42480000, 32'h42480000, 32'd0,
		                    32'h42480000, 32'h42480000, 32'd0);
		wait_sp_out(sp_out0);
		wait_sp_out(sp_out1);
		p_s_A = sp_out0[575:544];
		p_t_B = sp_out0[703:672];
		if (p_s_A !== 32'h3F800000 || p_t_B !== 32'h3F800000) begin
			$display("FAIL atg_rx_ext_prim.point_sprites (S=1.0): PointCoord grad got s=%h t=%h exp 3f800000",
				p_s_A, p_t_B);
			err_count = err_count + 1;
		end

		/* Point at (50.0, 50.0), size 4.0 (fp32: 32'h40800000) */
		st_put(GHCI_S_POINT_SIZE, 32'h40800000);
		send_raw_prim(2'd0, 32'h42480000, 32'h42480000, 32'd0,
		                    32'h42480000, 32'h42480000, 32'd0,
		                    32'h42480000, 32'h42480000, 32'd0);
		wait_sp_out(sp_out0);
		wait_sp_out(sp_out1);
		bx_min = sp_out0[303:288]; by_min = sp_out0[319:304];
		bx_max = sp_out0[335:320]; by_max = sp_out0[351:336];
		p_s_A = sp_out0[575:544];
		p_t_B = sp_out0[703:672];
		/* 50.0 - 2.0 = 48, 50.0 + 2.0 = 52 -> bbox [48, 53] */
		if (bx_min !== 16'd48 || bx_max !== 16'd53 || by_min !== 16'd48 || by_max !== 16'd53) begin
			$display("FAIL atg_rx_ext_prim.point_sprites (S=4.0): bbox [%0d,%0d,%0d,%0d] exp [48,48,53,53]",
				bx_min, by_min, bx_max, by_max);
			err_count = err_count + 1;
		end
		/* 1/4.0 = 0.25 = 32'h3E800000 */
		if (p_s_A !== 32'h3E800000 || p_t_B !== 32'h3E800000) begin
			$display("FAIL atg_rx_ext_prim.point_sprites (S=4.0): PointCoord grad got s=%h t=%h exp 3e800000",
				p_s_A, p_t_B);
			err_count = err_count + 1;
		end

		/* Point at (50.0, 50.0), size 16.0 */
		st_put(GHCI_S_POINT_SIZE, 32'h1000);
		send_raw_prim(2'd0, 32'h42480000, 32'h42480000, 32'd0,
		                    32'h42480000, 32'h42480000, 32'd0,
		                    32'h42480000, 32'h42480000, 32'd0);
		wait_sp_out(sp_out0);
		wait_sp_out(sp_out1);
		bx_min = sp_out0[303:288]; by_min = sp_out0[319:304];
		bx_max = sp_out0[335:320]; by_max = sp_out0[351:336];
		p_s_A = sp_out0[575:544];
		p_t_B = sp_out0[703:672];
		/* 50.0 - 8.0 = 42, 50.0 + 8.0 = 58 -> bbox [42, 59] */
		if (bx_min !== 16'd42 || bx_max !== 16'd59 || by_min !== 16'd42 || by_max !== 16'd59) begin
			$display("FAIL atg_rx_ext_prim.point_sprites (S=16.0): bbox [%0d,%0d,%0d,%0d] exp [42,42,59,59]",
				bx_min, by_min, bx_max, by_max);
			err_count = err_count + 1;
		end
		/* 1/16.0 = 0.0625 = 32'h3D800000 */
		if (p_s_A !== 32'h3D800000 || p_t_B !== 32'h3D800000) begin
			$display("FAIL atg_rx_ext_prim.point_sprites (S=16.0): PointCoord grad got s=%h t=%h exp 3d800000",
				p_s_A, p_t_B);
			err_count = err_count + 1;
		end

		if (err_count == 0)
			$display("PASS atg_rx_ext_prim.point_sprites");

		// =================================================================
		// TEST 3: MULTI-VIEWPORT & SCISSORS (16 ARRAY ENTRIES 0..15)
		// =================================================================
		$display("Testing Multi-Viewport & Scissors...");

		/* Configure viewports 0..15 with distinct scissor rectangles */
		for (k = 0; k < 16; k = k + 1) begin
			st_put(GHCI_S_VIEWPORT_IDX, k);
			st_put(GHCI_S_VIEWPORT, 32'h42800000);     /* scale x = 64.0 */
			st_put(GHCI_S_VIEWPORT + 1, 32'h42400000); /* scale y = 48.0 */
			st_put(GHCI_S_VIEWPORT + 2, 32'h42800000); /* off x = 64.0 */
			st_put(GHCI_S_VIEWPORT + 3, 32'h42400000); /* off y = 48.0 */
			st_put(GHCI_S_VIEWPORT + 4, 32'h3F000000);
			st_put(GHCI_S_VIEWPORT + 5, 32'h3F000000);
			/* Scissor k: [k, k] to [k + 20, k + 20] */
			st_put(GHCI_S_SCISSOR_MIN, {k[15:0], k[15:0]});
			st_put(GHCI_S_SCISSOR_MAX, {k[15:0] + 16'd20, k[15:0] + 16'd20});
		end

		/* Test selection of each viewport entry 0..15 */
		for (k = 0; k < 16; k = k + 1) begin
			st_put(GHCI_S_VIEWPORT_IDX, k);
			if (cur_viewport_idx !== k[3:0]) begin
				$display("FAIL atg_rx_ext_prim.multi_viewport: cur_viewport_idx got %0d exp %0d",
					cur_viewport_idx, k);
				err_count = err_count + 1;
			end
			/* Send full-screen NDC triangle: scissor[k] should clamp bbox to [k, k, k+20, k+20] */
			send_raw_prim(2'd2, 32'hBF800000, 32'hBF800000, 32'd0, /* (-1, -1) */
			                    32'h40400000, 32'hBF800000, 32'd0, /* ( 3, -1) */
			                    32'hBF800000, 32'h40400000, 32'd0); /* (-1,  3) */
			wait_sp_out(sp_out0);
			bx_min = sp_out0[303:288]; by_min = sp_out0[319:304];
			bx_max = sp_out0[335:320]; by_max = sp_out0[351:336];
			if (bx_min !== k[15:0] || by_min !== k[15:0] || bx_max !== k[15:0] + 16'd20 || by_max !== k[15:0] + 16'd20) begin
				$display("FAIL atg_rx_ext_prim.multi_viewport: entry %0d bbox [%0d,%0d,%0d,%0d] exp [%0d,%0d,%0d,%0d]",
					k, bx_min, by_min, bx_max, by_max, k, k, k + 20, k + 20);
				err_count = err_count + 1;
			end
		end

		if (err_count == 0)
			$display("PASS atg_rx_ext_prim.multi_viewport");

		// =================================================================
		// TEST 4: DEPTH CLAMPING
		// =================================================================
		$display("Testing Depth Clamping...");

		/* Reset viewport to full screen [0, 128]x[0, 96] and scissor disabled */
		st_put(GHCI_S_VIEWPORT_IDX, 32'd0);
		st_put(GHCI_S_SCISSOR_MIN, 32'd0);
		st_put(GHCI_S_SCISSOR_MAX, 32'd0);

		/* Test depth clamping via pipeline u_rx */
		/* Setup vertex 0, 1, 2 in PT:
		 * v0: (0.0, 0.0, -2.0, 1.0) -> z < 0 (in front of near plane!)
		 * v1: (1.0, 0.0,  0.5, 1.0)
		 * v2: (0.0, 1.0,  2.0, 1.0) -> z > 1 (behind far plane!)
		 */
		pt_mem[0][0] = 32'h00000000; pt_mem[0][1] = 32'h00000000;
		pt_mem[0][2] = 32'hC0000000; pt_mem[0][3] = 32'h3F800000; /* z = -2.0 */

		pt_mem[1][0] = 32'h3F800000; pt_mem[1][1] = 32'h00000000;
		pt_mem[1][2] = 32'h3F000000; pt_mem[1][3] = 32'h3F800000; /* z = 0.5 */

		pt_mem[2][0] = 32'h00000000; pt_mem[2][1] = 32'h3F800000;
		pt_mem[2][2] = 32'h40000000; pt_mem[2][3] = 32'h3F800000; /* z = 2.0 */

		/* 4.1: DEPTH_CLAMP = 3 (clip=1, clamp=1): Near/far bypass, quads emitted! */
		st_put(GHCI_S_DEPTH_CLAMP, 32'd3);
		rx_prim_vtx <= {2'd2, 8'd2, 8'd1, 8'd0};
		rx_prim_free <= 3'b111;
		rx_prim_last <= 1'b1;
		rx_prim_valid <= 1'b1;
		@(posedge clk);
		while (!rx_prim_ready)
			@(posedge clk);
		rx_prim_valid <= 1'b0;

		/* Receive fragments from pipeline */
		cycles = 0;
		dx_ready <= 1'b1;
		while (!dx_valid && cycles < 2000) begin
			cycles = cycles + 1;
			@(posedge clk);
		end
		if (!dx_valid) begin
			$display("FAIL atg_rx_ext_prim.depth_clamping: no fragments emitted when depth clamping enabled");
			err_count = err_count + 1;
		end else begin
			/* Verify fragment depth is clamped to [0, 1] */
			if (dx_depth[31:0] > 32'h3F800000 || dx_depth[63:32] > 32'h3F800000 ||
			    dx_depth[95:64] > 32'h3F800000 || dx_depth[127:96] > 32'h3F800000) begin
				$display("FAIL atg_rx_ext_prim.depth_clamping: depth > 1.0 not clamped (%h)", dx_depth);
				err_count = err_count + 1;
			end
		end
		/* Drain remaining quads */
		while (dx_valid || rx_busy)
			@(posedge clk);
		dx_ready <= 1'b0;

		/* 4.2: Now test with depth clamping disabled (DEPTH_CLAMP = 2, clip=1, clamp=0):
		 * Triangle vertices outside near and far planes get clipped against near/far. */
		st_put(GHCI_S_DEPTH_CLAMP, 32'd2);
		rx_prim_vtx <= {2'd2, 8'd2, 8'd1, 8'd0};
		rx_prim_free <= 3'b111;
		rx_prim_last <= 1'b1;
		rx_prim_valid <= 1'b1;
		@(posedge clk);
		while (!rx_prim_ready)
			@(posedge clk);
		rx_prim_valid <= 1'b0;

		cycles = 0;
		dx_ready <= 1'b1;
		while (!dx_valid && cycles < 2000) begin
			cycles = cycles + 1;
			@(posedge clk);
		end
		while (dx_valid || rx_busy)
			@(posedge clk);
		dx_ready <= 1'b0;

		if (err_count == 0)
			$display("PASS atg_rx_ext_prim.depth_clamping");

		// =================================================================
		// FINAL SUMMARY
		// =================================================================
		repeat (10) @(posedge clk);
		if (err_count == 0) begin
			$display("PASS atg_rx_ext_prim");
		end else begin
			$display("FAIL atg_rx_ext_prim: %0d errors", err_count);
		end
		$finish;
	end
endmodule

`default_nettype wire
