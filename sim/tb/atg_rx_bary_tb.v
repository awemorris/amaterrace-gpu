/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_bary_tb: Unit testbench for atg_rx_bary.
 * Tests parallel plane evaluation (Z, 1/W, B0/W, B1/W), 4-lane perspective division,
 * and depth slope calculation (dz).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_bary_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg i_start = 1'b0;
	reg i_dz = 1'b0;
	reg [383:0] i_pl = 384'd0;
	reg [15:0] i_qx = 16'd0;
	reg [15:0] i_qy = 16'd0;
	reg [15:0] i_bx0 = 16'd0;
	reg [15:0] i_by0 = 16'd0;
	reg [11:0] i_osel = 12'd0;

	wire busy;
	wire o_done;
	wire [127:0] o_b0;
	wire [127:0] o_b1;
	wire [127:0] o_b2;
	wire [127:0] o_z;
	wire [127:0] o_ds;

	atg_rx_bary dut (
		.clk(clk),
		.rst_n(rst_n),
		.i_start(i_start),
		.i_dz(i_dz),
		.i_pl(i_pl),
		.i_qx(i_qx),
		.i_qy(i_qy),
		.i_bx0(i_bx0),
		.i_by0(i_by0),
		.i_osel(i_osel),
		.busy(busy),
		.o_done(o_done),
		.o_b0(o_b0),
		.o_b1(o_b1),
		.o_b2(o_b2),
		.o_z(o_z),
		.o_ds(o_ds)
	);

	integer errors = 0;
	integer cycles = 0;

	/* fp32 constants */
	localparam [31:0] FP_0_0   = 32'h00000000;
	localparam [31:0] FP_0_125 = 32'h3E000000; /* +1/8 */
	localparam [31:0] FP_0_25  = 32'h3E800000; /* +0.25 */
	localparam [31:0] FP_0_5   = 32'h3F000000; /* +0.5 */
	localparam [31:0] FP_1_0   = 32'h3F800000; /* +1.0 */
	localparam [31:0] FP_2_0   = 32'h40000000; /* +2.0 */
	localparam [31:0] FP_N0_125 = 32'hBE000000; /* -1/8 */
	localparam [31:0] FP_N0_875 = 32'hBF600000; /* -0.875 */
	localparam [31:0] FP_0_875  = 32'h3F600000; /* +0.875 */

	initial begin
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);

		/* Test 1: Depth slope evaluation (i_dz) */
		/* Plane 0 (Z): Az = 1.0 (FP_1_0), Bz = 2.0 (FP_2_0), Cz = 0.0 */
		i_pl[32 * 0 +: 32] <= FP_1_0; /* Az */
		i_pl[32 * 1 +: 32] <= FP_2_0; /* Bz */
		i_pl[32 * 2 +: 32] <= FP_0_0; /* Cz */

		i_dz <= 1'b1;
		@(posedge clk);
		i_dz <= 1'b0;

		cycles = 0;
		while (!o_done && cycles < 100) begin
			@(posedge clk);
			cycles = cycles + 1;
		end

		if (!o_done) begin
			$display("FAIL atg_rx_bary: timeout waiting for o_done on i_dz");
			errors = errors + 1;
		end else begin
			/* Expected sample depth slopes:
			 * s=0: 1.0 * (-1/8) + 2.0 * (-3/8) = -0.125 - 0.75 = -0.875 (0xBF600000)
			 * s=1: 1.0 * ( 3/8) + 2.0 * (-1/8) =  0.375 - 0.25 = +0.125 (0x3E000000)
			 * s=2: 1.0 * (-3/8) + 2.0 * ( 1/8) = -0.375 + 0.25 = -0.125 (0xBE000000)
			 * s=3: 1.0 * ( 1/8) + 2.0 * ( 3/8) =  0.125 + 0.75 = +0.875 (0x3F600000)
			 */
			if (o_ds[31:0] !== FP_N0_875) begin
				$display("FAIL atg_rx_bary: ds[0] = %h, want %h", o_ds[31:0], FP_N0_875);
				errors = errors + 1;
			end
			if (o_ds[63:32] !== FP_0_125) begin
				$display("FAIL atg_rx_bary: ds[1] = %h, want %h", o_ds[63:32], FP_0_125);
				errors = errors + 1;
			end
			if (o_ds[95:64] !== FP_N0_125) begin
				$display("FAIL atg_rx_bary: ds[2] = %h, want %h", o_ds[95:64], FP_N0_125);
				errors = errors + 1;
			end
			if (o_ds[127:96] !== FP_0_875) begin
				$display("FAIL atg_rx_bary: ds[3] = %h, want %h", o_ds[127:96], FP_0_875);
				errors = errors + 1;
			end
		end

		@(posedge clk);

		/* Test 2: Flat Plane Evaluation & Barycentrics (i_start) */
		/* Plane 0 (Z):    A=0, B=0, C = 0.50 (FP_0_5)
		 * Plane 1 (1/W):  A=0, B=0, C = 1.00 (FP_1_0) -> rw = 1.0
		 * Plane 2 (B0/W): A=0, B=0, C = 0.25 (FP_0_25) -> b0 = 0.25
		 * Plane 3 (B1/W): A=0, B=0, C = 0.25 (FP_0_25) -> b1 = 0.25
		 * -> b2 = 1.0 - 0.25 - 0.25 = 0.50 (FP_0_5)
		 */
		i_pl <= 384'd0;
		i_pl[32 * 2 +: 32]  <= FP_0_5;  /* Z C */
		i_pl[32 * 5 +: 32]  <= FP_1_0;  /* 1/W C */
		i_pl[32 * 8 +: 32]  <= FP_0_25; /* B0/W C */
		i_pl[32 * 11 +: 32] <= FP_0_25; /* B1/W C */

		i_qx <= 16'd10;
		i_qy <= 16'd20;
		i_bx0 <= 16'd10;
		i_by0 <= 16'd20;
		i_osel <= 12'd0;

		i_start <= 1'b1;
		@(posedge clk);
		i_start <= 1'b0;

		cycles = 0;
		while (!o_done && cycles < 100) begin
			@(posedge clk);
			cycles = cycles + 1;
		end

		if (!o_done) begin
			$display("FAIL atg_rx_bary: timeout waiting for o_done on i_start");
			errors = errors + 1;
		end else begin
			/* Check all 4 lanes: z=0.5, b0=0.25, b1=0.25, b2=0.5 */
			if (o_z[31:0] !== FP_0_5 || o_z[63:32] !== FP_0_5 ||
			    o_z[95:64] !== FP_0_5 || o_z[127:96] !== FP_0_5) begin
				$display("FAIL atg_rx_bary: o_z = %h, want all %h", o_z, FP_0_5);
				errors = errors + 1;
			end
			if (o_b0[31:0] !== FP_0_25 || o_b0[63:32] !== FP_0_25 ||
			    o_b0[95:64] !== FP_0_25 || o_b0[127:96] !== FP_0_25) begin
				$display("FAIL atg_rx_bary: o_b0 = %h, want all %h", o_b0, FP_0_25);
				errors = errors + 1;
			end
			if (o_b1[31:0] !== FP_0_25 || o_b1[63:32] !== FP_0_25 ||
			    o_b1[95:64] !== FP_0_25 || o_b1[127:96] !== FP_0_25) begin
				$display("FAIL atg_rx_bary: o_b1 = %h, want all %h", o_b1, FP_0_25);
				errors = errors + 1;
			end
			if (o_b2[31:0] !== FP_0_5 || o_b2[63:32] !== FP_0_5 ||
			    o_b2[95:64] !== FP_0_5 || o_b2[127:96] !== FP_0_5) begin
				$display("FAIL atg_rx_bary: o_b2 = %h, want all %h", o_b2, FP_0_5);
				errors = errors + 1;
			end
		end

		if (errors == 0)
			$display("PASS atg_rx_bary");

		$finish;
	end
endmodule

`default_nettype wire
