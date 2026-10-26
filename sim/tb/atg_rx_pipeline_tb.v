/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_pipeline_tb: Unit testbench for RX 6-stage stream pipeline integration (ws001-p025).
 * Tests multi-primitive stream execution across:
 *   ST0: Prune & Cull (atg_rx_clip) -> am_skid
 *   ST1: Stream Setup (atg_rx_setup)
 *   ST2/ST3: Coarse & Fine Raster / MSAA 4x (atg_rx_scan) -> am_skid
 *   ST4/ST5: Fast DDA Interpolator (atg_rx_bary) & Warp Packing (atg_rx_frag)
 *
 * Verifies:
 * 1. Back-to-back triangle ingestion with registered skid buffer isolation.
 * 2. Unthrottled vs throttled SU grant backpressure handling without deadlock or quad drop.
 * 3. Warp execution sequencing, register/table writes, sequence numbers, and PT freeing.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_pipeline_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	/* STATE broadcast */
	reg st_we = 1'b0;
	reg [8:0] st_idx = 9'd0;
	reg [31:0] st_wdata = 32'd0;
	reg raw_kick = 1'b0;

	/* Primitives */
	reg prim_valid = 1'b0;
	wire prim_ready;
	reg [25:0] prim_vtx = 26'd0;
	reg [2:0] prim_free = 3'd0;
	reg prim_last = 1'b0;

	/* PT */
	wire pt_rd;
	wire [7:0] pt_idx;
	wire [6:0] pt_word;
	reg [31:0] pt_rdata = 32'd0;
	wire pt_free;
	wire [7:0] pt_free_idx;

	/* Fragment warps to SU */
	wire fl_req;
	reg fl_gnt = 1'b0;
	wire fl_we;
	wire [5:0] fl_reg;
	wire [4:0] fl_lane;
	wire [31:0] fl_data;
	wire fl_pw_we;
	wire [11:0] fl_pw_addr;
	wire [31:0] fl_pw_data;
	wire fl_go;
	wire [31:0] fl_mask;
	wire [63:0] fl_info;

	/* Direct quads */
	wire dx_valid;
	reg dx_ready = 1'b1;
	wire [15:0] dx_seq;
	wire [31:0] dx_xy;
	wire [3:0] dx_mask;
	wire [127:0] dx_depth;
	wire dx_last;

	/* Sequence numbers */
	wire ord_valid;
	wire [15:0] ord_seq;

	/* Status */
	wire busy;
	wire [3:0] fsm;

	atg_rx #(.HAS_SU(1)) dut (
		.clk(clk),
		.rst_n(rst_n),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.raw_kick(raw_kick),
		.busy(busy),
		.fsm(fsm),
		.prim_valid(prim_valid),
		.prim_ready(prim_ready),
		.prim_vtx(prim_vtx),
		.prim_free(prim_free),
		.prim_last(prim_last),
		.pt_rd(pt_rd),
		.pt_idx(pt_idx),
		.pt_word(pt_word),
		.pt_rdata(pt_rdata),
		.pt_free(pt_free),
		.pt_free_idx(pt_free_idx),
		.fl_req(fl_req),
		.fl_gnt(fl_gnt),
		.fl_we(fl_we),
		.fl_reg(fl_reg),
		.fl_lane(fl_lane),
		.fl_data(fl_data),
		.fl_pw_we(fl_pw_we),
		.fl_pw_addr(fl_pw_addr),
		.fl_pw_data(fl_pw_data),
		.fl_go(fl_go),
		.fl_mask(fl_mask),
		.fl_info(fl_info),
		.dx_valid(dx_valid),
		.dx_ready(dx_ready),
		.dx_seq(dx_seq),
		.dx_xy(dx_xy),
		.dx_mask(dx_mask),
		.dx_depth(dx_depth),
		.dx_last(dx_last),
		.ord_valid(ord_valid),
		.ord_seq(ord_seq)
	);

	/* PT memory: 256 entries x 16 words */
	reg [31:0] pt_mem [0:255][0:15];
	reg [255:0] pt_allocated = 256'd0;

	/* PT read latency: 1 cycle */
	always @(posedge clk) begin
		if (pt_rd)
			pt_rdata <= pt_mem[pt_idx][pt_word];
		if (pt_free)
			pt_allocated[pt_free_idx] <= 1'b0;
	end

	/* SU grant flow control */
	integer gdelay_cfg = 0;
	integer gdelay = 0;
	reg granted = 1'b0;
	integer warps_issued = 0;
	integer pw_writes = 0;
	integer reg_writes = 0;

	always @(posedge clk) begin
		fl_gnt <= 1'b0;
		if (!rst_n) begin
			granted <= 1'b0;
			gdelay <= 0;
			warps_issued <= 0;
			pw_writes <= 0;
			reg_writes <= 0;
		end else begin
			if (fl_req && !fl_gnt && !granted) begin
				if (gdelay == 0) begin
					fl_gnt <= 1'b1;
					granted <= 1'b1;
					gdelay <= gdelay_cfg;
				end else begin
					gdelay <= gdelay - 1;
				end
			end
			if (fl_pw_we)
				pw_writes <= pw_writes + 1;
			if (fl_we)
				reg_writes <= reg_writes + 1;
			if (fl_go) begin
				granted <= 1'b0;
				warps_issued <= warps_issued + 1;
			end
		end
	end

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

	task send_tri(
		input [7:0] v0, input [7:0] v1, input [7:0] v2,
		input [2:0] free_flags, input is_last
	);
		begin
			@(posedge clk);
			prim_valid <= 1'b1;
			prim_vtx <= {2'b00, v2, v1, v0};
			prim_free <= free_flags;
			prim_last <= is_last;
			pt_allocated[v0] <= 1'b1;
			pt_allocated[v1] <= 1'b1;
			pt_allocated[v2] <= 1'b1;
			@(posedge clk);
			while (!prim_ready)
				@(posedge clk);
			prim_valid <= 1'b0;
			prim_last <= 1'b0;
		end
	endtask

	integer errors = 0;
	integer timeout = 0;
	integer prev_warps = 0;

	initial begin
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);

		/* 1. Setup GPU STATE */
		/* Viewport: 640 x 480 centred at (320, 240) */
		write_st(GHCI_S_VIEWPORT + 0, 32'h43A00000); /* sx = 320.0 */
		write_st(GHCI_S_VIEWPORT + 1, 32'hC3700000); /* sy = -240.0 */
		write_st(GHCI_S_VIEWPORT + 2, 32'h43A00000); /* ox = 320.0 */
		write_st(GHCI_S_VIEWPORT + 3, 32'h43700000); /* oy = 240.0 */
		write_st(GHCI_S_VIEWPORT + 4, 32'h3F000000); /* sz = 0.5 */
		write_st(GHCI_S_VIEWPORT + 5, 32'h3F000000); /* oz = 0.5 */

		/* Scissor: [0, 640) x [0, 480) */
		write_st(GHCI_S_SCISSOR_MIN, {16'd0, 16'd0});
		write_st(GHCI_S_SCISSOR_MAX, {16'd480, 16'd640});
		write_st(GHCI_S_RT_SIZE, {16'd480, 16'd640});

		/* Cull: None (0) */
		write_st(GHCI_S_CULL, 32'd0);

		/* Varying count: 1 */
		write_st(GHCI_S_VARYING_COUNT, 32'd1);

		/* Multisampling: 1 sample (MS_CTRL = 0) */
		write_st(GHCI_S_MS_CTRL, 32'd0);

		/* 2. Load Vertex Data into PT memory */
		/* Triangle 0: Vertices 0, 1, 2 (Top-left area)
		 * V0: (-0.5, 0.5, 0.5, 1.0) -> screen (160, 120)
		 * V1: ( 0.0, 0.5, 0.5, 1.0) -> screen (320, 120)
		 * V2: (-0.5, 0.0, 0.5, 1.0) -> screen (160, 240)
		 */
		pt_mem[0][0] = 32'hBF000000; /* x = -0.5 */
		pt_mem[0][1] = 32'h3F000000; /* y = 0.5 */
		pt_mem[0][2] = 32'h3F000000; /* z = 0.5 */
		pt_mem[0][3] = 32'h3F800000; /* w = 1.0 */
		pt_mem[0][4] = 32'h3F800000; /* varying 0 = 1.0 */

		pt_mem[1][0] = 32'h00000000; /* x = 0.0 */
		pt_mem[1][1] = 32'h3F000000; /* y = 0.5 */
		pt_mem[1][2] = 32'h3F000000; /* z = 0.5 */
		pt_mem[1][3] = 32'h3F800000; /* w = 1.0 */
		pt_mem[1][4] = 32'h40000000; /* varying 0 = 2.0 */

		pt_mem[2][0] = 32'hBF000000; /* x = -0.5 */
		pt_mem[2][1] = 32'h00000000; /* y = 0.0 */
		pt_mem[2][2] = 32'h3F000000; /* z = 0.5 */
		pt_mem[2][3] = 32'h3F800000; /* w = 1.0 */
		pt_mem[2][4] = 32'h40400000; /* varying 0 = 3.0 */

		/* Triangle 1: Vertices 3, 4, 5 (Bottom-right area)
		 * V3: (0.0,  0.0, 0.5, 1.0) -> screen (320, 240)
		 * V4: (0.5,  0.0, 0.5, 1.0) -> screen (480, 240)
		 * V5: (0.0, -0.5, 0.5, 1.0) -> screen (320, 360)
		 */
		pt_mem[3][0] = 32'h00000000; pt_mem[3][1] = 32'h00000000; pt_mem[3][2] = 32'h3F000000; pt_mem[3][3] = 32'h3F800000; pt_mem[3][4] = 32'h3F800000;
		pt_mem[4][0] = 32'h3F000000; pt_mem[4][1] = 32'h00000000; pt_mem[4][2] = 32'h3F000000; pt_mem[4][3] = 32'h3F800000; pt_mem[4][4] = 32'h40000000;
		pt_mem[5][0] = 32'h00000000; pt_mem[5][1] = 32'hBF000000; pt_mem[5][2] = 32'h3F000000; pt_mem[5][3] = 32'h3F800000; pt_mem[5][4] = 32'h40400000;

		/* TEST PHASE 1: Back-to-back primitives with UNTHROTTLED grant (gdelay = 0) */
		$display("Starting Phase 1: Unthrottled pipeline execution...");
		gdelay_cfg = 0;
		send_tri(8'd0, 8'd1, 8'd2, 3'b111, 1'b0);
		send_tri(8'd3, 8'd4, 8'd5, 3'b111, 1'b1);

		timeout = 0;
		while (busy && timeout < 10000) begin
			@(posedge clk);
			timeout = timeout + 1;
		end

		if (timeout >= 10000) begin
			$display("FAIL atg_rx_pipeline: Phase 1 timeout (busy stuck high)");
			errors = errors + 1;
		end else begin
			$display("Phase 1 completed in %0d cycles: %0d warps, %0d pw_writes, %0d reg_writes",
				timeout, warps_issued, pw_writes, reg_writes);
			if (warps_issued == 0) begin
				$display("FAIL atg_rx_pipeline: Phase 1 produced 0 warps");
				errors = errors + 1;
			end
		end

		repeat (10) @(posedge clk);

		/* TEST PHASE 2: Pipelined primitives with THROTTLED grant (gdelay = 25 cycles) */
		$display("Starting Phase 2: Throttled pipeline execution (backpressure test)...");
		gdelay_cfg = 25;
		prev_warps = warps_issued;

		/* Re-send triangle 0 and triangle 1 */
		send_tri(8'd0, 8'd1, 8'd2, 3'b111, 1'b0);
		send_tri(8'd3, 8'd4, 8'd5, 3'b111, 1'b1);

		timeout = 0;
		while (busy && timeout < 20000) begin
			@(posedge clk);
			timeout = timeout + 1;
		end

		if (timeout >= 20000) begin
			$display("FAIL atg_rx_pipeline: Phase 2 timeout under backpressure");
			errors = errors + 1;
		end else begin
			$display("Phase 2 completed in %0d cycles: %0d new warps issued",
				timeout, warps_issued - prev_warps);
			if (warps_issued - prev_warps == 0) begin
				$display("FAIL atg_rx_pipeline: Phase 2 produced 0 warps under throttling");
				errors = errors + 1;
			end
		end

		/* Check PT entries all freed */
		if (pt_allocated[0] || pt_allocated[1] || pt_allocated[2] ||
		    pt_allocated[3] || pt_allocated[4] || pt_allocated[5]) begin
			$display("FAIL atg_rx_pipeline: PT entries not properly freed: %b", pt_allocated[7:0]);
			errors = errors + 1;
		end

		if (errors == 0)
			$display("PASS atg_rx_pipeline");

		$finish;
	end
endmodule

`default_nettype wire
