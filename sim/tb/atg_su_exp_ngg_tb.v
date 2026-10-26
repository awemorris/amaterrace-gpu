/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_exp_ngg_tb: Unit testbench for Next-Generation Geometry (NGG)
 * Meshlet Primitive Export Sequencer and LDS Port B interface.
 *
 * Tests:
 *   1. Full triangle assembly (V0, V1, V2 positions & varyings, indices, control flags).
 *   2. Hardware culling skip (primitives with cull flag bit 7 are discarded without reading vertices).
 *   3. 2-stage Skid Buffer backpressure & flow control (stalling when ngg_ready == 0).
 *   4. Boundary conditions (single primitive, last flag, zero primitives).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_exp_ngg_tb;

	localparam AW = 10;
	localparam DATA_W = 32;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	/* Control & Config */
	reg kick_valid = 1'b0;
	reg [15:0] kick_mesh_id = 16'd0;
	reg [7:0] kick_prim_count = 8'd0;
	reg [7:0] kick_vert_count = 8'd0;
	reg [AW-1:0] kick_prim_base = 10'd512;
	reg [AW-1:0] kick_pos_base = 10'd0;
	reg [AW-1:0] kick_var_base = 10'd256;
	wire busy;
	wire done;

	/* LDS Port B */
	wire lds_rd_en;
	wire [AW-1:0] lds_rd_addr;
	wire [DATA_W-1:0] lds_rd_data;

	/* NGG Stream */
	wire ngg_valid;
	reg ngg_ready = 1'b0;
	wire [701:0] ngg_tri;
	wire ngg_last;
	wire [15:0] ngg_mesh_id;

	/* DUT */
	atg_su_exp_ngg #(
		.AW(AW),
		.DATA_W(DATA_W)
	) dut (
		.clk(clk),
		.rst_n(rst_n),
		.kick_valid(kick_valid),
		.kick_mesh_id(kick_mesh_id),
		.kick_prim_count(kick_prim_count),
		.kick_vert_count(kick_vert_count),
		.kick_prim_base(kick_prim_base),
		.kick_pos_base(kick_pos_base),
		.kick_var_base(kick_var_base),
		.busy(busy),
		.done(done),
		.lds_rd_en(lds_rd_en),
		.lds_rd_addr(lds_rd_addr),
		.lds_rd_data(lds_rd_data),
		.ngg_valid(ngg_valid),
		.ngg_ready(ngg_ready),
		.ngg_tri(ngg_tri),
		.ngg_last(ngg_last),
		.ngg_mesh_id(ngg_mesh_id)
	);

	/* LDS Block RAM instance */
	atg_su_lds #(
		.NPHYS(8),
		.NWARPS(4),
		.LDS_BYTES(4096)
	) u_lds (
		.clk(clk),
		.rst_n(rst_n),
		.x_valid(1'b0),
		.x_warp(2'd0),
		.x_grp(2'd0),
		.x_last(1'b0),
		.x_sbe(3'd0),
		.x_pc(16'd0),
		.x_uop(104'd0),
		.x_a(256'd0),
		.x_b(256'd0),
		.x_c(256'd0),
		.x_mask(16'd0),
		.x_info(32'd0),
		.x_ready(),
		.l_valid(),
		.l_ready(1'b1),
		.l_warp(),
		.l_grp(),
		.l_rd(),
		.l_data(),
		.l_lanes(),
		.l_wr(),
		.l_last(),
		.l_sbe(),
		.l_cls(),
		.scrub(1'b0),
		.scrub_busy(),
		.ngg_rd_en(lds_rd_en),
		.ngg_rd_addr(lds_rd_addr),
		.ngg_rd_data(lds_rd_data)
	);

	integer err = 0;
	integer k;
	reg saw_done = 1'b0;

	always @(posedge clk) begin
		if (!rst_n)
			saw_done <= 1'b0;
		else if (done)
			saw_done <= 1'b1;
		else if (kick_valid)
			saw_done <= 1'b0;
	end

	/* Task to populate test meshlet into LDS */
	task init_meshlet;
		begin
			/* Vertices 0..3:
			 * V0: Pos={1.0, 0.0, 0.0, 1.0}, Var={0x1002, 0x1001, 0x1000}
			 * V1: Pos={1.0, 0.0, 1.0, 0.0}, Var={0x1102, 0x1101, 0x1100}
			 * V2: Pos={1.0, 0.0, 0.0, 1.0}, Var={0x1202, 0x1201, 0x1200}
			 * V3: Pos={1.0, 0.0, 1.0, 1.0}, Var={0x1302, 0x1301, 0x1300}
			 */
			u_lds.ram[0] = 32'h00000000;	/* V0 X */
			u_lds.ram[1] = 32'h00000000;	/* V0 Y */
			u_lds.ram[2] = 32'h00000000;	/* V0 Z */
			u_lds.ram[3] = 32'h3F800000;	/* V0 W = 1.0 */
			u_lds.ram[256] = 32'h00001000;	/* V0 Var 0 */
			u_lds.ram[257] = 32'h00001001;	/* V0 Var 1 */
			u_lds.ram[258] = 32'h00001002;	/* V0 Var 2 */

			u_lds.ram[4] = 32'h00000000;	/* V1 X */
			u_lds.ram[5] = 32'h3F800000;	/* V1 Y */
			u_lds.ram[6] = 32'h00000000;	/* V1 Z */
			u_lds.ram[7] = 32'h3F800000;	/* V1 W = 1.0 */
			u_lds.ram[260] = 32'h00001100;	/* V1 Var 0 */
			u_lds.ram[261] = 32'h00001101;	/* V1 Var 1 */
			u_lds.ram[262] = 32'h00001102;	/* V1 Var 2 */

			u_lds.ram[8] = 32'h3F800000;	/* V2 X */
			u_lds.ram[9] = 32'h00000000;	/* V2 Y */
			u_lds.ram[10] = 32'h00000000;	/* V2 Z */
			u_lds.ram[11] = 32'h3F800000;	/* V2 W = 1.0 */
			u_lds.ram[264] = 32'h00001200;	/* V2 Var 0 */
			u_lds.ram[265] = 32'h00001201;	/* V2 Var 1 */
			u_lds.ram[266] = 32'h00001202;	/* V2 Var 2 */

			u_lds.ram[12] = 32'h3F800000;	/* V3 X */
			u_lds.ram[13] = 32'h3F800000;	/* V3 Y */
			u_lds.ram[14] = 32'h00000000;	/* V3 Z */
			u_lds.ram[15] = 32'h3F800000;	/* V3 W = 1.0 */
			u_lds.ram[268] = 32'h00001300;	/* V3 Var 0 */
			u_lds.ram[269] = 32'h00001301;	/* V3 Var 1 */
			u_lds.ram[270] = 32'h00001302;	/* V3 Var 2 */

			/* Primitives:
			 * Prim 0: {flags=8'h05, V2=2, V1=1, V0=0} -> Valid
			 * Prim 1: {flags=8'h80, V2=1, V1=2, V0=3} -> Culled (bit 7=1)
			 * Prim 2: {flags=8'h00, V2=3, V1=2, V0=1} -> Valid
			 */
			u_lds.ram[512] = {8'h05, 8'd2, 8'd1, 8'd0};
			u_lds.ram[513] = {8'h80, 8'd1, 8'd2, 8'd3};
			u_lds.ram[514] = {8'h00, 8'd3, 8'd2, 8'd1};
		end
	endtask

	initial begin
		#20;
		@(posedge clk);
		rst_n <= 1'b1;
		init_meshlet;

		/* -------------------------------------------------------------
		 * Test 1: Standard Export & Fast Culling Skip
		 * ------------------------------------------------------------- */
		@(posedge clk);
		kick_valid <= 1'b1;
		kick_mesh_id <= 16'hA1B2;
		kick_prim_count <= 8'd3;
		kick_vert_count <= 8'd4;
		kick_prim_base <= 10'd512;
		kick_pos_base <= 10'd0;
		kick_var_base <= 10'd256;
		ngg_ready <= 1'b1;
		@(posedge clk);
		kick_valid <= 1'b0;

		/* Wait for Prim 0 to be emitted */
		while (!ngg_valid) @(posedge clk);

		/* Verify Prim 0 */
		if (ngg_mesh_id !== 16'hA1B2) begin
			$display("FAIL: ngg_mesh_id mismatch %h want A1B2", ngg_mesh_id);
			err = err + 1;
		end
		if (ngg_last !== 1'b0) begin
			$display("FAIL: ngg_last should be 0 for prim 0");
			err = err + 1;
		end
		if (ngg_tri[695:672] !== {8'd2, 8'd1, 8'd0}) begin
			$display("FAIL: Prim 0 indices mismatch %h want 020100", ngg_tri[695:672]);
			err = err + 1;
		end
		if (ngg_tri[698:696] !== 3'd5) begin
			$display("FAIL: Prim 0 flags mismatch %d want 5", ngg_tri[698:696]);
			err = err + 1;
		end
		if (ngg_tri[701:700] !== 2'd2) begin
			$display("FAIL: Prim 0 kind mismatch %d want 2 (triangle)", ngg_tri[701:700]);
			err = err + 1;
		end
		if (ngg_tri[127:0] !== {32'h3F800000, 32'd0, 32'd0, 32'd0}) begin
			$display("FAIL: Prim 0 V0 pos mismatch %h", ngg_tri[127:0]);
			err = err + 1;
		end
		if (ngg_tri[479:384] !== {32'h00001002, 32'h00001001, 32'h00001000}) begin
			$display("FAIL: Prim 0 V0 var mismatch %h", ngg_tri[479:384]);
			err = err + 1;
		end

		/* Handshake Prim 0 */
		@(posedge clk);

		/* Wait for Prim 2 to be emitted (Prim 1 must be skipped due to culling) */
		while (!ngg_valid) @(posedge clk);

		/* Verify Prim 2 (last primitive) */
		if (ngg_last !== 1'b1) begin
			$display("FAIL: ngg_last should be 1 for prim 2");
			err = err + 1;
		end
		if (ngg_tri[695:672] !== {8'd3, 8'd2, 8'd1}) begin
			$display("FAIL: Prim 2 indices mismatch %h want 030201", ngg_tri[695:672]);
			err = err + 1;
		end

		/* Handshake Prim 2 */
		@(posedge clk);

		/* Wait for done */
		while (!saw_done) @(posedge clk);
		if (busy !== 1'b0) begin
			$display("FAIL: busy should be 0 after done");
			err = err + 1;
		end

		/* -------------------------------------------------------------
		 * Test 2: Skid Buffer & Backpressure Test
		 * ------------------------------------------------------------- */
		@(posedge clk);
		kick_valid <= 1'b1;
		kick_mesh_id <= 16'h55AA;
		kick_prim_count <= 8'd1;
		kick_prim_base <= 10'd512;
		ngg_ready <= 1'b0;	/* RX is busy / backpressuring */
		@(posedge clk);
		kick_valid <= 1'b0;

		/* Wait until triangle is assembled and presented */
		while (!ngg_valid) @(posedge clk);

		/* Hold ngg_ready low for 10 cycles to verify skid buffer stability */
		for (k = 0; k < 10; k = k + 1) begin
			if (!ngg_valid) begin
				$display("FAIL: ngg_valid dropped while backpressured at cycle %0d", k);
				err = err + 1;
			end
			if (ngg_mesh_id !== 16'h55AA) begin
				$display("FAIL: ngg_mesh_id unstable while backpressured");
				err = err + 1;
			end
			@(posedge clk);
		end

		/* Now accept the triangle */
		ngg_ready <= 1'b1;
		@(posedge clk);
		ngg_ready <= 1'b0;

		/* Wait for done */
		while (!saw_done) @(posedge clk);

		/* -------------------------------------------------------------
		 * Test 3: Zero-Primitive Meshlet (Immediate Done)
		 * ------------------------------------------------------------- */
		@(posedge clk);
		kick_valid <= 1'b1;
		kick_mesh_id <= 16'h0000;
		kick_prim_count <= 8'd0;
		ngg_ready <= 1'b1;
		@(posedge clk);
		kick_valid <= 1'b0;

		@(posedge clk);
		#1;
		if (!saw_done) begin
			$display("FAIL: 0-primitive meshlet did not complete immediately");
			err = err + 1;
		end

		#50;
		if (err == 0)
			$display("PASS atg_su_exp_ngg");
		else
			$display("FAIL atg_su_exp_ngg with %0d errors", err);
		$finish;
	end

	initial begin
		#100000;
		$display("FAIL atg_su_exp_ngg timeout");
		$finish;
	end
endmodule

`default_nettype wire
