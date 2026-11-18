/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_odd_bbox_tb: Directed verification of RX setup and scan integration
 * with odd bounding box origins (xmin odd, ymin odd, both odd) across:
 * - MSAA 1 (MS_CTRL=0) and MSAA 4 (MS_CTRL=2)
 * - COARSE_SCAN=0 (direct bbox traversal) and COARSE_SCAN=1 (8x8 tile traversal)
 * Bit-exact match against reference model (tools/msmodel.py / tools/rxmodel.py).
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

module atg_rx_odd_bbox_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	/* STATE broadcast */
	reg st_we = 1'b0;
	reg [8:0] st_idx = 9'd0;
	reg [31:0] st_wdata = 32'd0;

	/* Setup instance */
	reg cl_valid = 1'b0;
	wire cl_ready;
	reg [701:0] cl_tri = 702'd0;
	reg cl_last = 1'b0;
	wire sp_valid;
	reg sp_ready = 1'b0;
	wire [767:0] sp_tri;
	wire sp_last, setup_busy;

	atg_rx_setup dut_setup (
		.clk(clk),
		.rst_n(rst_n),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.cl_valid(cl_valid),
		.cl_ready(cl_ready),
		.cl_tri(cl_tri),
		.cl_last(cl_last),
		.mesh_valid(1'b0),
		.mesh_ready(),
		.mesh_tri(702'd0),
		.mesh_last(1'b0),
		.mesh_id(16'd0),
		.sp_valid(sp_valid),
		.sp_ready(sp_ready),
		.sp_tri(sp_tri),
		.sp_last(sp_last),
		.busy(setup_busy)
	);

	/* Scan instances: COARSE_SCAN 0 and 1 */
	reg sp_valid_c0 = 1'b0;
	wire sp_ready_c0;
	reg [767:0] sp_tri_c0 = 768'd0;
	reg sp_last_c0 = 1'b0;
	wire fq_valid_c0, fq_end_c0, scan_busy_c0;
	wire [31:0] fq_xy_c0;
	wire [15:0] fq_scov_c0;
	wire [3:0] fq_ccov_c0;

	atg_rx_scan #(
		.HAS_SU(1),
		.COARSE_SCAN(0)
	) dut_scan_c0 (
		.clk(clk),
		.rst_n(rst_n),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.sp_valid(sp_valid_c0),
		.sp_ready(sp_ready_c0),
		.sp_tri(sp_tri_c0),
		.sp_last(sp_last_c0),
		.pt_free(),
		.pt_free_idx(),
		.fq_valid(fq_valid_c0),
		.fq_ready(1'b1),
		.fq_xy(fq_xy_c0),
		.fq_scov(fq_scov_c0),
		.fq_ccov(fq_ccov_c0),
		.fq_end(fq_end_c0),
		.f_busy(1'b0),
		.dx_valid(),
		.dx_ready(1'b1),
		.dx_seq(),
		.dx_xy(),
		.dx_mask(),
		.dx_depth(),
		.dx_last(),
		.sq_req(),
		.sq_seq(16'd0),
		.busy(scan_busy_c0)
	);

	reg sp_valid_c1 = 1'b0;
	wire sp_ready_c1;
	reg [767:0] sp_tri_c1 = 768'd0;
	reg sp_last_c1 = 1'b0;
	wire fq_valid_c1, fq_end_c1, scan_busy_c1;
	wire [31:0] fq_xy_c1;
	wire [15:0] fq_scov_c1;
	wire [3:0] fq_ccov_c1;

	atg_rx_scan #(
		.HAS_SU(1),
		.COARSE_SCAN(1)
	) dut_scan_c1 (
		.clk(clk),
		.rst_n(rst_n),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.sp_valid(sp_valid_c1),
		.sp_ready(sp_ready_c1),
		.sp_tri(sp_tri_c1),
		.sp_last(sp_last_c1),
		.pt_free(),
		.pt_free_idx(),
		.fq_valid(fq_valid_c1),
		.fq_ready(1'b1),
		.fq_xy(fq_xy_c1),
		.fq_scov(fq_scov_c1),
		.fq_ccov(fq_ccov_c1),
		.fq_end(fq_end_c1),
		.f_busy(1'b0),
		.dx_valid(),
		.dx_ready(1'b1),
		.dx_seq(),
		.dx_xy(),
		.dx_mask(),
		.dx_depth(),
		.dx_last(),
		.sq_req(),
		.sq_seq(16'd0),
		.busy(scan_busy_c1)
	);

	/* Expected values table */
	localparam MAX_EXP = 32;
	integer exp_n;
	reg [31:0] exp_xy   [0:MAX_EXP-1];
	reg [15:0] exp_scov [0:MAX_EXP-1];
	reg [3:0]  exp_ccov [0:MAX_EXP-1];
	reg exp_seen [0:MAX_EXP-1];

	task write_st(input [8:0] idx, input [31:0] val);
		begin
			@(posedge clk);
			st_we <= 1'b1;
			st_idx <= idx;
			st_wdata <= val;
			@(posedge clk);
			st_we <= 1'b0;
		end
	endtask

	/* Triangle 0: odd_x (xmin=3, ymin=4, xmax=12, ymax=13) */
	localparam [701:0] CL_TRI_ODD_X = 702'h270201003f8000000000000000000000000000003f8000000000000000000000000000003f8000003f8000003f00000041400000404000003f8000003f00000040800000413000003f8000003f0000004080000040400000;
	task init_expect_odd_x_msaa1;
		begin
			exp_n = 10;
			exp_xy[0] = 32'h0004_0002; exp_scov[0] = 16'h1010; exp_ccov[0] = 4'ha;
			exp_xy[1] = 32'h0004_0004; exp_scov[1] = 16'h1111; exp_ccov[1] = 4'hf;
			exp_xy[2] = 32'h0004_0006; exp_scov[2] = 16'h1111; exp_ccov[2] = 4'hf;
			exp_xy[3] = 32'h0004_0008; exp_scov[3] = 16'h0111; exp_ccov[3] = 4'h7;
			exp_xy[4] = 32'h0006_0002; exp_scov[4] = 16'h1010; exp_ccov[4] = 4'ha;
			exp_xy[5] = 32'h0006_0004; exp_scov[5] = 16'h1111; exp_ccov[5] = 4'hf;
			exp_xy[6] = 32'h0006_0006; exp_scov[6] = 16'h0111; exp_ccov[6] = 4'h7;
			exp_xy[7] = 32'h0008_0002; exp_scov[7] = 16'h1010; exp_ccov[7] = 4'ha;
			exp_xy[8] = 32'h0008_0004; exp_scov[8] = 16'h0111; exp_ccov[8] = 4'h7;
			exp_xy[9] = 32'h000a_0002; exp_scov[9] = 16'h0010; exp_ccov[9] = 4'h2;
		end
	endtask

	task init_expect_odd_x_msaa4;
		begin
			exp_n = 14;
			exp_xy[0] = 32'h0004_0002; exp_scov[0] = 16'hf0f0; exp_ccov[0] = 4'ha;
			exp_xy[1] = 32'h0004_0004; exp_scov[1] = 16'hffff; exp_ccov[1] = 4'hf;
			exp_xy[2] = 32'h0004_0006; exp_scov[2] = 16'hffff; exp_ccov[2] = 4'hf;
			exp_xy[3] = 32'h0004_0008; exp_scov[3] = 16'h5fff; exp_ccov[3] = 4'h7;
			exp_xy[4] = 32'h0004_000a; exp_scov[4] = 16'h0005; exp_ccov[4] = 4'h0;
			exp_xy[5] = 32'h0006_0002; exp_scov[5] = 16'hf0f0; exp_ccov[5] = 4'ha;
			exp_xy[6] = 32'h0006_0004; exp_scov[6] = 16'hffff; exp_ccov[6] = 4'hf;
			exp_xy[7] = 32'h0006_0006; exp_scov[7] = 16'h5fff; exp_ccov[7] = 4'h7;
			exp_xy[8] = 32'h0006_0008; exp_scov[8] = 16'h0005; exp_ccov[8] = 4'h0;
			exp_xy[9] = 32'h0008_0002; exp_scov[9] = 16'hf0f0; exp_ccov[9] = 4'ha;
			exp_xy[10] = 32'h0008_0004; exp_scov[10] = 16'h5fff; exp_ccov[10] = 4'h7;
			exp_xy[11] = 32'h0008_0006; exp_scov[11] = 16'h0005; exp_ccov[11] = 4'h0;
			exp_xy[12] = 32'h000a_0002; exp_scov[12] = 16'h50f0; exp_ccov[12] = 4'h2;
			exp_xy[13] = 32'h000a_0004; exp_scov[13] = 16'h0005; exp_ccov[13] = 4'h0;
		end
	endtask

	/* Triangle 1: odd_y (xmin=4, ymin=5, xmax=13, ymax=14) */
	localparam [701:0] CL_TRI_ODD_Y = 702'h270201003f8000000000000000000000000000003f8000000000000000000000000000003f8000003f8000003f00000041500000408000003f8000003f00000040a00000414000003f8000003f00000040a0000040800000;
	task init_expect_odd_y_msaa1;
		begin
			exp_n = 10;
			exp_xy[0] = 32'h0004_0004; exp_scov[0] = 16'h1100; exp_ccov[0] = 4'hc;
			exp_xy[1] = 32'h0004_0006; exp_scov[1] = 16'h1100; exp_ccov[1] = 4'hc;
			exp_xy[2] = 32'h0004_0008; exp_scov[2] = 16'h1100; exp_ccov[2] = 4'hc;
			exp_xy[3] = 32'h0004_000a; exp_scov[3] = 16'h0100; exp_ccov[3] = 4'h4;
			exp_xy[4] = 32'h0006_0004; exp_scov[4] = 16'h1111; exp_ccov[4] = 4'hf;
			exp_xy[5] = 32'h0006_0006; exp_scov[5] = 16'h1111; exp_ccov[5] = 4'hf;
			exp_xy[6] = 32'h0006_0008; exp_scov[6] = 16'h0111; exp_ccov[6] = 4'h7;
			exp_xy[7] = 32'h0008_0004; exp_scov[7] = 16'h1111; exp_ccov[7] = 4'hf;
			exp_xy[8] = 32'h0008_0006; exp_scov[8] = 16'h0111; exp_ccov[8] = 4'h7;
			exp_xy[9] = 32'h000a_0004; exp_scov[9] = 16'h0111; exp_ccov[9] = 4'h7;
		end
	endtask

	task init_expect_odd_y_msaa4;
		begin
			exp_n = 14;
			exp_xy[0] = 32'h0004_0004; exp_scov[0] = 16'hff00; exp_ccov[0] = 4'hc;
			exp_xy[1] = 32'h0004_0006; exp_scov[1] = 16'hff00; exp_ccov[1] = 4'hc;
			exp_xy[2] = 32'h0004_0008; exp_scov[2] = 16'hff00; exp_ccov[2] = 4'hc;
			exp_xy[3] = 32'h0004_000a; exp_scov[3] = 16'h5f00; exp_ccov[3] = 4'h4;
			exp_xy[4] = 32'h0006_0004; exp_scov[4] = 16'hffff; exp_ccov[4] = 4'hf;
			exp_xy[5] = 32'h0006_0006; exp_scov[5] = 16'hffff; exp_ccov[5] = 4'hf;
			exp_xy[6] = 32'h0006_0008; exp_scov[6] = 16'h5fff; exp_ccov[6] = 4'h7;
			exp_xy[7] = 32'h0006_000a; exp_scov[7] = 16'h0005; exp_ccov[7] = 4'h0;
			exp_xy[8] = 32'h0008_0004; exp_scov[8] = 16'hffff; exp_ccov[8] = 4'hf;
			exp_xy[9] = 32'h0008_0006; exp_scov[9] = 16'h5fff; exp_ccov[9] = 4'h7;
			exp_xy[10] = 32'h0008_0008; exp_scov[10] = 16'h0005; exp_ccov[10] = 4'h0;
			exp_xy[11] = 32'h000a_0004; exp_scov[11] = 16'h5fff; exp_ccov[11] = 4'h7;
			exp_xy[12] = 32'h000a_0006; exp_scov[12] = 16'h0005; exp_ccov[12] = 4'h0;
			exp_xy[13] = 32'h000c_0004; exp_scov[13] = 16'h0005; exp_ccov[13] = 4'h0;
		end
	endtask

	/* Triangle 2: odd_xy (xmin=5, ymin=7, xmax=14, ymax=16) */
	localparam [701:0] CL_TRI_ODD_XY = 702'h270201003f8000000000000000000000000000003f8000000000000000000000000000003f8000003f8000003f0000004170000040a000003f8000003f00000040e00000415000003f8000003f00000040e0000040a00000;
	task init_expect_odd_xy_msaa1;
		begin
			exp_n = 13;
			exp_xy[0] = 32'h0006_0004; exp_scov[0] = 16'h1000; exp_ccov[0] = 4'h8;
			exp_xy[1] = 32'h0006_0006; exp_scov[1] = 16'h1100; exp_ccov[1] = 4'hc;
			exp_xy[2] = 32'h0006_0008; exp_scov[2] = 16'h1100; exp_ccov[2] = 4'hc;
			exp_xy[3] = 32'h0006_000a; exp_scov[3] = 16'h1100; exp_ccov[3] = 4'hc;
			exp_xy[4] = 32'h0008_0004; exp_scov[4] = 16'h1010; exp_ccov[4] = 4'ha;
			exp_xy[5] = 32'h0008_0006; exp_scov[5] = 16'h1111; exp_ccov[5] = 4'hf;
			exp_xy[6] = 32'h0008_0008; exp_scov[6] = 16'h1111; exp_ccov[6] = 4'hf;
			exp_xy[7] = 32'h0008_000a; exp_scov[7] = 16'h0001; exp_ccov[7] = 4'h1;
			exp_xy[8] = 32'h000a_0004; exp_scov[8] = 16'h1010; exp_ccov[8] = 4'ha;
			exp_xy[9] = 32'h000a_0006; exp_scov[9] = 16'h1111; exp_ccov[9] = 4'hf;
			exp_xy[10] = 32'h000a_0008; exp_scov[10] = 16'h0001; exp_ccov[10] = 4'h1;
			exp_xy[11] = 32'h000c_0004; exp_scov[11] = 16'h1010; exp_ccov[11] = 4'ha;
			exp_xy[12] = 32'h000c_0006; exp_scov[12] = 16'h0001; exp_ccov[12] = 4'h1;
		end
	endtask

	task init_expect_odd_xy_msaa4;
		begin
			exp_n = 15;
			exp_xy[0] = 32'h0006_0004; exp_scov[0] = 16'hf000; exp_ccov[0] = 4'h8;
			exp_xy[1] = 32'h0006_0006; exp_scov[1] = 16'hff00; exp_ccov[1] = 4'hc;
			exp_xy[2] = 32'h0006_0008; exp_scov[2] = 16'hff00; exp_ccov[2] = 4'hc;
			exp_xy[3] = 32'h0006_000a; exp_scov[3] = 16'hff00; exp_ccov[3] = 4'hc;
			exp_xy[4] = 32'h0006_000c; exp_scov[4] = 16'h0500; exp_ccov[4] = 4'h0;
			exp_xy[5] = 32'h0008_0004; exp_scov[5] = 16'hf0f0; exp_ccov[5] = 4'ha;
			exp_xy[6] = 32'h0008_0006; exp_scov[6] = 16'hffff; exp_ccov[6] = 4'hf;
			exp_xy[7] = 32'h0008_0008; exp_scov[7] = 16'hffff; exp_ccov[7] = 4'hf;
			exp_xy[8] = 32'h0008_000a; exp_scov[8] = 16'h055f; exp_ccov[8] = 4'h1;
			exp_xy[9] = 32'h000a_0004; exp_scov[9] = 16'hf0f0; exp_ccov[9] = 4'ha;
			exp_xy[10] = 32'h000a_0006; exp_scov[10] = 16'hffff; exp_ccov[10] = 4'hf;
			exp_xy[11] = 32'h000a_0008; exp_scov[11] = 16'h055f; exp_ccov[11] = 4'h1;
			exp_xy[12] = 32'h000c_0004; exp_scov[12] = 16'hf0f0; exp_ccov[12] = 4'ha;
			exp_xy[13] = 32'h000c_0006; exp_scov[13] = 16'h055f; exp_ccov[13] = 4'h1;
			exp_xy[14] = 32'h000e_0004; exp_scov[14] = 16'h0050; exp_ccov[14] = 4'h0;
		end
	endtask

	integer total_errors = 0;

	task run_case(
		input [127:0] case_name,
		input [701:0] tri_bits,
		input is_c1,
		input is_ms4
	);
		integer k, got_quads, timeout;
		reg found;
		reg done;
		begin
			for (k = 0; k < MAX_EXP; k = k + 1) exp_seen[k] = 1'b0;
			got_quads = 0;
			done = 1'b0;

			/* 1. Setup MSAA STATE */
			write_st(GHCI_S_MS_CTRL, is_ms4 ? 32'd2 : 32'd0);
			write_st(GHCI_S_SAMPLE_KILL, 32'd0);

			/* 2. Send primitive into atg_rx_setup */
			@(posedge clk);
			cl_valid <= 1'b1;
			cl_tri <= tri_bits;
			cl_last <= 1'b0;
			@(posedge clk);
			while (!cl_ready) @(posedge clk);
			cl_valid <= 1'b0;

			/* 3. Wait for sp_valid from setup and transfer to chosen scan instance */
			timeout = 0;
			while (!sp_valid && timeout < 2000) begin
				@(posedge clk);
				timeout = timeout + 1;
			end
			if (timeout >= 2000) begin
				$display("FAIL %0s: setup timeout", case_name);
				total_errors = total_errors + 1;
			end else begin
				@(posedge clk);
				sp_ready <= 1'b1;
				if (is_c1) begin
					sp_valid_c1 <= 1'b1;
					sp_tri_c1 <= sp_tri;
					sp_last_c1 <= 1'b0;
				end else begin
					sp_valid_c0 <= 1'b1;
					sp_tri_c0 <= sp_tri;
					sp_last_c0 <= 1'b0;
				end
				@(posedge clk);
				sp_ready <= 1'b0;
				sp_valid_c1 <= 1'b0;
				sp_valid_c0 <= 1'b0;

				/* 4. Collect and verify quads from scan */
				timeout = 0;
				while (!done && timeout < 5000) begin
					@(posedge clk);
					timeout = timeout + 1;
					if (is_c1) begin
						if (fq_valid_c1) begin
							if (fq_end_c1) begin
								done = 1'b1;
							end else begin
								found = 1'b0;
								for (k = 0; k < exp_n; k = k + 1) begin
									if (!found && !exp_seen[k] && exp_xy[k] === fq_xy_c1) begin
										found = 1'b1;
										exp_seen[k] = 1'b1;
										if (fq_scov_c1 !== exp_scov[k] || fq_ccov_c1 !== exp_ccov[k]) begin
											$display("FAIL %0s: quad %h mismatch: got scov=%h ccov=%h, want scov=%h ccov=%h",
												case_name, fq_xy_c1, fq_scov_c1, fq_ccov_c1, exp_scov[k], exp_ccov[k]);
											total_errors = total_errors + 1;
										end
									end
								end
								if (!found) begin
									$display("FAIL %0s: unexpected quad %h (scov=%h, ccov=%h)",
										case_name, fq_xy_c1, fq_scov_c1, fq_ccov_c1);
									total_errors = total_errors + 1;
								end
								got_quads = got_quads + 1;
							end
						end
					end else begin
						if (fq_valid_c0) begin
							if (fq_end_c0) begin
								done = 1'b1;
							end else begin
								found = 1'b0;
								for (k = 0; k < exp_n; k = k + 1) begin
									if (!found && !exp_seen[k] && exp_xy[k] === fq_xy_c0) begin
										found = 1'b1;
										exp_seen[k] = 1'b1;
										if (fq_scov_c0 !== exp_scov[k] || fq_ccov_c0 !== exp_ccov[k]) begin
											$display("FAIL %0s: quad %h mismatch: got scov=%h ccov=%h, want scov=%h ccov=%h",
												case_name, fq_xy_c0, fq_scov_c0, fq_ccov_c0, exp_scov[k], exp_ccov[k]);
											total_errors = total_errors + 1;
										end
									end
								end
								if (!found) begin
									$display("FAIL %0s: unexpected quad %h (scov=%h, ccov=%h)",
										case_name, fq_xy_c0, fq_scov_c0, fq_ccov_c0);
									total_errors = total_errors + 1;
								end
								got_quads = got_quads + 1;
							end
						end
					end
				end

				if (!done) begin
					$display("FAIL %0s: scan timeout waiting for fq_end", case_name);
					total_errors = total_errors + 1;
				end else if (got_quads != exp_n) begin
					$display("FAIL %0s: quad count mismatch: got %0d, want %0d",
						case_name, got_quads, exp_n);
					total_errors = total_errors + 1;
				end else begin
					$display("PASS %0s (%0d quads bit-exact)", case_name, got_quads);
				end
			end
			repeat (5) @(posedge clk);
		end
	endtask

	initial begin
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);

		/* Common STATE setup */
		write_st(GHCI_S_VIEWPORT + 0, 32'h3F800000); /* sx = 1.0 */
		write_st(GHCI_S_VIEWPORT + 1, 32'h3F800000); /* sy = 1.0 */
		write_st(GHCI_S_VIEWPORT + 2, 32'h00000000); /* ox = 0.0 */
		write_st(GHCI_S_VIEWPORT + 3, 32'h00000000); /* oy = 0.0 */
		write_st(GHCI_S_VIEWPORT + 4, 32'h3F800000); /* sz = 1.0 */
		write_st(GHCI_S_VIEWPORT + 5, 32'h00000000); /* oz = 0.0 */
		write_st(GHCI_S_RT_SIZE, {16'd480, 16'd640});
		write_st(GHCI_S_SCISSOR_MIN, {16'd0, 16'd0});
		write_st(GHCI_S_SCISSOR_MAX, {16'd480, 16'd640});
		write_st(GHCI_S_CULL, 32'd0);

		/* 1. odd_x: xmin odd, ymin even */
		init_expect_odd_x_msaa1;
		run_case("odd_x.ms1.c1", CL_TRI_ODD_X, 1'b1, 1'b0);
		init_expect_odd_x_msaa1;
		run_case("odd_x.ms1.c0", CL_TRI_ODD_X, 1'b0, 1'b0);
		init_expect_odd_x_msaa4;
		run_case("odd_x.ms4.c1", CL_TRI_ODD_X, 1'b1, 1'b1);
		init_expect_odd_x_msaa4;
		run_case("odd_x.ms4.c0", CL_TRI_ODD_X, 1'b0, 1'b1);

		/* 2. odd_y: xmin even, ymin odd */
		init_expect_odd_y_msaa1;
		run_case("odd_y.ms1.c1", CL_TRI_ODD_Y, 1'b1, 1'b0);
		init_expect_odd_y_msaa1;
		run_case("odd_y.ms1.c0", CL_TRI_ODD_Y, 1'b0, 1'b0);
		init_expect_odd_y_msaa4;
		run_case("odd_y.ms4.c1", CL_TRI_ODD_Y, 1'b1, 1'b1);
		init_expect_odd_y_msaa4;
		run_case("odd_y.ms4.c0", CL_TRI_ODD_Y, 1'b0, 1'b1);

		/* 3. odd_xy: xmin odd, ymin odd */
		init_expect_odd_xy_msaa1;
		run_case("odd_xy.ms1.c1", CL_TRI_ODD_XY, 1'b1, 1'b0);
		init_expect_odd_xy_msaa1;
		run_case("odd_xy.ms1.c0", CL_TRI_ODD_XY, 1'b0, 1'b0);
		init_expect_odd_xy_msaa4;
		run_case("odd_xy.ms4.c1", CL_TRI_ODD_XY, 1'b1, 1'b1);
		init_expect_odd_xy_msaa4;
		run_case("odd_xy.ms4.c0", CL_TRI_ODD_XY, 1'b0, 1'b1);

		if (total_errors == 0) begin
			$display("PASS atg_rx_odd_bbox");
		end else begin
			$display("FAIL atg_rx_odd_bbox (%0d total errors)", total_errors);
		end
		$finish;
	end

endmodule

`default_nettype wire
