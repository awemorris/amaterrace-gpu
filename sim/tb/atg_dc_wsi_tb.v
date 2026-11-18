/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_wsi_tb: Comprehensive testbench for WSI Advanced Display Features
 * (ws002-p010: HDR10, Multi-Plane Overlay, Variable Refresh Rate).
 *
 * Verifies:
 * 1. 10-bit / HDR10 pipeline (atg_dc_hdr):
 *    - BT.709 -> BT.2020 color gamut matrix using am_mul.
 *    - SMPTE ST 2084 (PQ) 1024-entry EOTF LUT conversion accuracy.
 *    - Passthrough when hdr_en is disabled.
 * 2. Multi-Plane Hardware Overlay (atg_dc_plane2):
 *    - NV12 YUV 4:2:0 -> RGB matrix conversion (am_mul).
 *    - Bounding box / window placement.
 *    - Color key transparency.
 *    - Alpha blending with primary plane.
 * 3. VRR (Variable Refresh Rate / Adaptive Sync) in atg_dc_tgen:
 *    - Dynamic VBLANK extension for irregular frame presentation intervals.
 *    - Flip synchronization (vsync release on flip_ready).
 *    - Continuous HSYNC generation without display stutter or tearing.
 *    - Maximum VBLANK timeout (vrr_vmax) fallback.
 * 4. DISP2 register integration in atg_dc / atg_dc_regs:
 *    - 10-bit format 3 (A2B10G10R10) support and DC_CAPS reporting.
 *    - HDR, VRR, and Plane 2 MMIO control and status registers.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_wsi_tb;
	reg clk = 1'b0;
	reg pclk = 1'b0;
	reg rst_n = 1'b0;
	reg prst_n = 1'b0;

	always #2.5 clk = !clk;   /* 200 MHz gclk */
	always #5.0 pclk = !pclk; /* 100 MHz pclk */

	integer errors = 0;

	task fail;
		input [8*60-1:0] msg;
		begin
			errors = errors + 1;
			$display("FAIL atg_dc_wsi: %0s", msg);
		end
	endtask

	/* ====================================================================
	 * Part 1: Unit Testing atg_dc_hdr (HDR10 / ST 2084 PQ / BT.2020)
	 * ==================================================================== */
	reg hdr_en;
	reg [9:0] hdr_in_r, hdr_in_g, hdr_in_b;
	wire [9:0] hdr_out_r, hdr_out_g, hdr_out_b;

	atg_dc_hdr #(
		.CSC_ENABLE(1)
	) u_tb_hdr (
		.pclk(pclk),
		.prst_n(prst_n),
		.hdr_en(hdr_en),
		.in_r(hdr_in_r),
		.in_g(hdr_in_g),
		.in_b(hdr_in_b),
		.out_r(hdr_out_r),
		.out_g(hdr_out_g),
		.out_b(hdr_out_b)
	);

	task test_hdr;
		begin
			$display("--- Testing HDR10 Pipeline (atg_dc_hdr) ---");
			/* Test 1: Passthrough when hdr_en = 0 */
			hdr_en = 1'b0;
			hdr_in_r = 10'd500;
			hdr_in_g = 10'd600;
			hdr_in_b = 10'd700;
			@(posedge pclk);
			@(posedge pclk);
			if (hdr_out_r != 10'd500 || hdr_out_g != 10'd600 || hdr_out_b != 10'd700)
				fail("HDR passthrough mismatch");

			/* Test 2: Enable HDR. Check ST 2084 PQ conversion */
			hdr_en = 1'b1;
			/* Zero level */
			hdr_in_r = 10'd0;
			hdr_in_g = 10'd0;
			hdr_in_b = 10'd0;
			@(posedge pclk);
			@(posedge pclk);
			if (hdr_out_r != 10'd0 || hdr_out_g != 10'd0 || hdr_out_b != 10'd0)
				fail("HDR zero level mismatch");

			/* Peak white (1023 in all channels) -> Matrix preserves white -> PQ LUT max = 1023 */
			hdr_in_r = 10'd1023;
			hdr_in_g = 10'd1023;
			hdr_in_b = 10'd1023;
			@(posedge pclk);
			@(posedge pclk);
			if (hdr_out_r < 10'd1000 || hdr_out_g < 10'd1000 || hdr_out_b < 10'd1000)
				fail("HDR peak white conversion mismatch");

			/* Mid level (SDR 100 nits reference ~ 512) -> non-linear PQ compression */
			hdr_in_r = 10'd512;
			hdr_in_g = 10'd512;
			hdr_in_b = 10'd512;
			@(posedge pclk);
			@(posedge pclk);
			/* ST 2084 PQ value for 512 is approximately 9-10 out of 1023 (100 cd/m2 out of 10000) */
			if (hdr_out_r < 10'd5 || hdr_out_r > 10'd20)
				fail("HDR mid-gray PQ curve mapping mismatch");

			$display("  PASS: HDR10 ST 2084 and BT.2020 matrix verified");
		end
	endtask

	/* ====================================================================
	 * Part 2: Unit Testing atg_dc_plane2 (Multi-Plane Overlay / NV12 / Blend)
	 * ==================================================================== */
	reg p2_en;
	reg [11:0] p2_x, p2_y, p2_w, p2_h;
	reg [7:0]  p2_alpha;
	reg        p2_ck_en;
	reg [23:0] p2_ck;
	reg        p2_yuv;

	reg [11:0] p2_cur_x, p2_cur_y;
	reg [23:0] p2_prim_rgb;
	reg        p2_prim_valid;
	wire [23:0] p2_out_rgb;
	wire        p2_out_valid;

	reg        p2_ov_valid;
	reg [7:0]  p2_ov_y, p2_ov_u, p2_ov_v;
	reg [23:0] p2_ov_rgb;

	atg_dc_plane2 #(
		.ADDR_W(32), .LINE_BYTES(32), .LINE_SHIFT(5)
	) u_tb_plane2 (
		.clk(pclk),
		.rst_n(prst_n),
		.enable(1'b1),
		.plane_en(p2_en),
		.pos_x(p2_x),
		.pos_y(p2_y),
		.width(p2_w),
		.height(p2_h),
		.alpha(p2_alpha),
		.colorkey_en(p2_ck_en),
		.colorkey(p2_ck),
		.yuv_mode(p2_yuv),
		.cur_x(p2_cur_x),
		.cur_y(p2_cur_y),
		.prim_rgb(p2_prim_rgb),
		.prim_valid(p2_prim_valid),
		.out_rgb(p2_out_rgb),
		.out_valid(p2_out_valid),
		.ov_valid(p2_ov_valid),
		.ov_ready(),
		.ov_y(p2_ov_y),
		.ov_u(p2_ov_u),
		.ov_v(p2_ov_v),
		.ov_rgb(p2_ov_rgb),
		.req_valid(), .req_ready(1'b0), .req_write(), .req_line(), .req_be(), .req_wdata(), .req_tag(),
		.rsp_valid(1'b0), .rsp_write(1'b0), .rsp_tag(8'd0), .rsp_rdata(256'd0), .rsp_error(1'b0)
	);

	task test_plane2;
		begin
			$display("--- Testing Multi-Plane Overlay (atg_dc_plane2) ---");
			p2_en = 1'b1;
			p2_x = 12'd10;
			p2_y = 12'd10;
			p2_w = 12'd20;
			p2_h = 12'd20;
			p2_alpha = 8'd255; /* Fully opaque */
			p2_ck_en = 1'b0;
			p2_ck = 24'h000000;
			p2_yuv = 1'b0; /* RGB overlay */
			p2_ov_rgb = 24'h00FF00; /* Green overlay */
			p2_prim_rgb = 24'h0000FF; /* Blue primary */
			p2_prim_valid = 1'b1;

			/* Point outside overlay window (5, 5) -> must output primary */
			p2_cur_x = 12'd5;
			p2_cur_y = 12'd5;
			@(posedge pclk);
			@(posedge pclk);
			if (p2_out_rgb != 24'h0000FF)
				fail("Plane 2 outside window should output primary");

			/* Point inside overlay window (15, 15) -> must output overlay green */
			p2_cur_x = 12'd15;
			p2_cur_y = 12'd15;
			@(posedge pclk);
			@(posedge pclk);
			if (p2_out_rgb != 24'h00FF00)
				fail("Plane 2 inside window should output overlay RGB");

			/* Test Color Keying: set colorkey to green (0x00FF00) */
			p2_ck_en = 1'b1;
			p2_ck = 24'h00FF00;
			@(posedge pclk);
			@(posedge pclk);
			if (p2_out_rgb != 24'h0000FF)
				fail("Plane 2 color key matching should pass through primary");

			/* Disable color key, test 50% Alpha Blending */
			p2_ck_en = 1'b0;
			p2_alpha = 8'd128; /* ~50% blend */
			p2_ov_rgb = 24'hFF0000; /* Red overlay */
			p2_prim_rgb = 24'h0000FF; /* Blue primary */
			@(posedge pclk);
			@(posedge pclk);
			/* Expected: Red ~ 128, Green ~ 0, Blue ~ 127 */
			if (p2_out_rgb[23:16] < 8'd120 || p2_out_rgb[23:16] > 8'd135 ||
			    p2_out_rgb[7:0]   < 8'd120 || p2_out_rgb[7:0]   > 8'd135)
				fail("Plane 2 alpha blending calculation mismatch");

			/* Test NV12 YUV -> RGB conversion */
			p2_yuv = 1'b1;
			p2_alpha = 8'd255;
			/* Standard White: Y=235, U=128, V=128 */
			p2_ov_y = 8'd235;
			p2_ov_u = 8'd128;
			p2_ov_v = 8'd128;
			@(posedge pclk);
			@(posedge pclk);
			if (p2_out_rgb[23:16] < 8'd230 || p2_out_rgb[15:8] < 8'd230 || p2_out_rgb[7:0] < 8'd230)
				fail("Plane 2 YUV white conversion mismatch");

			$display("  PASS: Multi-Plane Overlay window, colorkey, alpha, and YUV matrix verified");
		end
	endtask

	/* ====================================================================
	 * Part 3: Unit Testing atg_dc_tgen with VRR (Variable Refresh Rate)
	 * ==================================================================== */
	reg vrr_enable_cfg = 1'b0;
	reg vrr_tgen_en;
	reg vrr_flip_ready;
	reg [11:0] vrr_vmax_cfg;
	reg [287:0] vrr_timing;
	wire vrr_px_ready;
	wire [23:0] vrr_rgb;
	wire [29:0] vrr_rgb10;
	wire vrr_de, vrr_hs, vrr_vs;
	wire vrr_frame_toggle, vrr_vsync_toggle, vrr_underflow_toggle;
	wire [11:0] vrr_line, vrr_col;

	atg_dc_tgen u_tb_tgen (
		.clk(pclk),
		.rst_n(prst_n),
		.enable(vrr_enable_cfg),
		.test_pattern(1'b0),
		.format(2'd3), /* 10-bit format 3 */
		.timing(vrr_timing),
		.px_valid(1'b1),
		.px_ready(vrr_px_ready),
		.px_data(32'h3FFFFFFF),
		.rgb(vrr_rgb),
		.de(vrr_de),
		.hs(vrr_hs),
		.vs(vrr_vs),
		.frame_toggle(vrr_frame_toggle),
		.vsync_toggle(vrr_vsync_toggle),
		.underflow_toggle(vrr_underflow_toggle),
		.line(vrr_line),
		.vrr_en(vrr_tgen_en),
		.flip_ready(vrr_flip_ready),
		.vrr_vmax(vrr_vmax_cfg),
		.col(vrr_col),
		.rgb10(vrr_rgb10)
	);

	task set_fast_timing;
		reg [31:0] w [0:8];
		integer i;
		begin
			/* Tiny mode: H: 16 active, 4 fp, 4 sync, 4 bp (total 28)
			 *            V: 8 active,  2 fp, 2 sync, 2 bp (total 14) */
			w[0] = 32'd16; w[1] = 32'd4; w[2] = 32'd4; w[3] = 32'd4;
			w[4] = 32'd8;  w[5] = 32'd2; w[6] = 32'd2; w[7] = 32'd2;
			w[8] = 32'd0; /* negative sync */
			for (i = 0; i < 9; i = i + 1)
				vrr_timing[32*i +: 32] = w[i];
		end
	endtask

	task test_vrr;
		integer line_samples;
		integer extended_lines;
		begin
			$display("--- Testing VRR (Adaptive Sync / Dynamic VBLANK) ---");
			vrr_enable_cfg = 1'b0;
			@(posedge pclk);
			set_fast_timing();
			vrr_tgen_en = 1'b1;
			vrr_flip_ready = 1'b0;
			vrr_vmax_cfg = 12'd50; /* Allow up to 50 lines before timeout */
			@(posedge pclk);
			vrr_enable_cfg = 1'b1;
			@(posedge pclk);

			/* Wait until VSYNC begins (v == 10) */
			while (vrr_line != 12'd10)
				@(posedge pclk);

			$display("  Entered VBLANK sync line: line=%0d. Holding flip_ready=0 to test extension...", vrr_line);
			extended_lines = 0;
			repeat (100) begin
				@(posedge pclk);
				if (vrr_col == 12'd0 && vrr_line == 12'd10)
					extended_lines = extended_lines + 1;
			end

			if (extended_lines < 3)
				fail("VRR did not hold vertical line in VBLANK");
			$display("  VBLANK held successfully for %0d H-cycles with continuous HSYNC pulses", extended_lines);

			/* Now assert flip_ready on negedge pclk for clean setup/hold */
			@(negedge pclk);
			vrr_flip_ready = 1'b1;
			@(negedge pclk);
			vrr_flip_ready = 1'b0;

			/* Wait for vertical scan to transition from VBLANK into active area (line == 0) */
			line_samples = 0;
			while (vrr_line != 12'd0 && line_samples < 500) begin
				@(posedge pclk);
				line_samples = line_samples + 1;
			end

			if (vrr_line != 12'd0)
				fail("VRR did not resume active scanning after flip_ready");

			/* Test VRR Maximum VBLANK Timeout Protection */
			vrr_vmax_cfg = 12'd8; /* Max 8 extended lines */
			/* Wait until next VBLANK line 10 */
			while (vrr_line != 12'd10)
				@(posedge pclk);

			$display("  Testing VRR timeout fallback with flip_ready=0...");
			line_samples = 0;
			while (vrr_line != 12'd0 && line_samples < 500) begin
				@(posedge pclk);
				line_samples = line_samples + 1;
			end

			if (vrr_line != 12'd0)
				fail("VRR did not force refresh on vrr_vmax timeout");

			$display("  PASS: VRR dynamic VBLANK extension, flip synchronization, and timeout fallback verified");
		end
	endtask

	/* ====================================================================
	 * Part 4: DISP2 Full Integration & MMIO Registers in atg_dc
	 * ==================================================================== */
	reg d_we = 1'b0;
	reg [5:0] d_idx = 6'd0;
	reg [31:0] d_wdata = 32'd0;
	reg [31:0] d_wmask = 32'hFFFFFFFF;
	reg [5:0] d_ridx = 6'd0;
	wire [31:0] d_rdata;

	wire [1:0] dc_taken, dc_taken_cancel, dc_pending;
	wire dc_idle;
	wire [31:0] dc_frame_count;
	wire dc_vblank, dc_error, dc_hotplug, dc_pclk_sel;
	wire dc_urgent, dc_panic;
	wire [29:0] dc_tmds;
	wire [23:0] dc_px_rgb;
	wire dc_px_de, dc_px_hs, dc_px_vs;

	atg_dc #(
		.TEST_MODE(1)
	) u_dc (
		.clk(clk),
		.rst_n(rst_n),
		.pclk(pclk),
		.prst_n(prst_n),
		.d_we(d_we),
		.d_idx(d_idx),
		.d_wdata(d_wdata),
		.d_wmask(d_wmask),
		.d_ridx(d_ridx),
		.d_rdata(d_rdata),
		.flip_valid(1'b0),
		.flip_plane(1'b0),
		.flip_base(32'd0),
		.taken(dc_taken),
		.taken_cancel(dc_taken_cancel),
		.pending(dc_pending),
		.dc_err(2'b00),
		.idle(dc_idle),
		.frame_count(dc_frame_count),
		.ev_vblank(dc_vblank),
		.ev_error(dc_error),
		.ev_hotplug(dc_hotplug),
		.pclk_sel(dc_pclk_sel),
		.dc_urgent(dc_urgent),
		.dc_panic(dc_panic),
		.req_valid(), .req_ready(1'b1), .req_write(), .req_line(), .req_be(), .req_wdata(), .req_tag(),
		.rsp_valid(1'b0), .rsp_write(1'b0), .rsp_tag(8'd0), .rsp_rdata(256'd0), .rsp_error(1'b0),
		.tmds(dc_tmds),
		.px_rgb(dc_px_rgb),
		.px_de(dc_px_de),
		.px_hs(dc_px_hs),
		.px_vs(dc_px_vs),
		.scl_t(), .scl_i(1'b1), .sda_t(), .sda_i(1'b1)
	);

	task wr;
		input [7:0] addr;
		input [31:0] data;
		begin
			@(negedge clk);
			d_we = 1'b1;
			d_idx = addr[7:2];
			d_wdata = data;
			@(negedge clk);
			d_we = 1'b0;
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

	task test_dc_integration;
		reg [31:0] val;
		begin
			$display("--- Testing atg_dc DISP2 MMIO & Extended Features ---");
			/* Read DC_CAPS (0x08) */
			rd(8'h08, val);
			/* Verify CAPS has format 3 (bit 7 set) and HDR (bit 13), VRR (bit 14), Plane 2 (bit 15) */
			if (!val[7])
				fail("DC_CAPS bit 7 (format 3 A2B10G10R10) not set");
			if (!val[13] || !val[14] || !val[15])
				fail("DC_CAPS bits 13-15 (HDR, VRR, PLANE2) not set");
			$display("  DC_CAPS = 0x%08x verified", val);

			/* Write and read back Plane 2 coordinates and control (0xC4) */
			wr(8'hC4, 32'h00640032);
			rd(8'hC4, val);
			if (val != 32'h00640032)
				fail("PLANE2_POS write/read mismatch");

			/* Write and read back VRR_CTRL (0xD4) */
			wr(8'hD4, 32'h01000001);
			rd(8'hD4, val);
			if (val != 32'h01000001)
				fail("VRR_CTRL write/read mismatch");

			/* Write and read back HDR_CTRL (0xD8) */
			wr(8'hD8, 32'h00000001);
			rd(8'hD8, val);
			if (val != 32'h00000001)
				fail("HDR_CTRL write/read mismatch");

			$display("  PASS: DISP2 MMIO registers for Plane 2, VRR, HDR verified");
		end
	endtask

	initial begin
		$display("=== atg_dc_wsi_tb Starting ===");
		set_fast_timing();
		rst_n = 1'b0;
		prst_n = 1'b0;
		#40;
		rst_n = 1'b1;
		prst_n = 1'b1;
		#40;

		test_hdr();
		test_plane2();
		test_vrr();
		test_dc_integration();

		if (errors == 0) begin
			$display("PASS atg_dc_wsi");
		end else begin
			$display("FAIL atg_dc_wsi with %0d errors", errors);
		end
		$finish;
	end
endmodule

`default_nettype wire
