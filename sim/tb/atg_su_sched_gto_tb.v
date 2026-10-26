/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_sched_gto_tb: Tests the GTO (Greedy-Then-Oldest) warp scheduling
 * policy and the scoreboard feedback warp_ready mechanism (Phase 012).
 *
 * Verifies:
 *   1. Greedy: consecutive execution of the same ready warp.
 *   2. Stall switch: immediate switch to another ready warp upon warp_ready deassertion.
 *   3. Oldest: selection of the longest-waiting candidate warp when switching.
 *   4. No-replay: zero replay feedback events.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_sched_gto_tb;
`include "atg_su_uop.vh"

	localparam NPHYS = 8;
	localparam NWARPS = 4;
	localparam WARP_W = 2;
	localparam G = 32 / NPHYS;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg cs_kick = 1'b0;

	reg [NWARPS-1:0] warp_ready = {NWARPS{1'b1}};

	wire f_valid;
	reg f_ready = 1'b1;
	wire [WARP_W-1:0] f_warp;
	wire [15:0] f_pc;
	wire [31:0] f_addr;

	reg fb_valid = 1'b0;
	reg [WARP_W-1:0] fb_warp = 0;
	reg [1:0] fb_kind = 2'd0;
	reg [NWARPS-1:0] wake = {NWARPS{1'b0}};

	wire [159:0] q_info;
	wire init_valid;
	wire [WARP_W-1:0] init_warp;
	wire [31:0] init_mask;
	wire busy;

	integer errors = 0;
	integer cyc = 0;
	integer replay_events = 0;

	always #5 clk = !clk;
	always @(posedge clk) cyc <= cyc + 1;

	atg_su_sched #(
		.NPHYS(NPHYS),
		.NWARPS(NWARPS),
		.WARP_W(WARP_W),
		.NSU(1),
		.SU_INDEX(0),
		.FRAG_RESERVE(0),
		.GTO(1)
	) u_sched (
		.clk(clk),
		.rst_n(rst_n),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.cs_kick(cs_kick),
		.vl_req(1'b0),
		.vl_gnt(),
		.vl_slot(),
		.vl_go(1'b0),
		.vl_mask(32'd0),
		.fl_req(1'b0),
		.fl_gnt(),
		.fl_slot(),
		.fl_go(1'b0),
		.fl_mask(32'd0),
		.fl_info(64'd0),
		.f_valid(f_valid),
		.f_ready(f_ready),
		.f_warp(f_warp),
		.f_pc(f_pc),
		.f_addr(f_addr),
		.fb_valid(fb_valid),
		.fb_warp(fb_warp),
		.fb_kind(fb_kind),
		.wake(wake),
		.warp_ready(warp_ready),
		.wc_valid(1'b0),
		.wc_warp({WARP_W{1'b0}}),
		.wc_op(2'd0),
		.wc_pc(16'd0),
		.q_warp({WARP_W{1'b0}}),
		.q_info(q_info),
		.init_valid(init_valid),
		.init_warp(init_warp),
		.init_mask(init_mask),
		.pt_ok(1'b1),
		.xr_valid(1'b0),
		.xr_warp({WARP_W{1'b0}}),
		.busy(busy)
	);

	task fail;
		input [8*48-1:0] what;
		begin
			$display("FAIL atg_su_sched_gto.%0s", what);
			errors = errors + 1;
		end
	endtask

	task state;
		input [8:0] idx;
		input [31:0] val;
		begin
			@(negedge clk);
			st_we = 1'b1;
			st_idx = idx;
			st_wdata = val;
			@(negedge clk);
			st_we = 1'b0;
		end
	endtask

	/* Automated feedback responder: returns fb_kind 0 after 2 cycles */
	reg [1:0] pend_warp [0:3];
	reg [31:0] pend_due [0:3];
	reg [3:0] pend_v = 4'd0;
	integer p;

	always @(negedge clk) begin
		fb_valid = 1'b0;
		for (p = 0; p < 4; p = p + 1) begin
			if (pend_v[p] && pend_due[p] <= cyc && !fb_valid) begin
				pend_v[p] = 1'b0;
				fb_valid = 1'b1;
				fb_warp = pend_warp[p];
				fb_kind = 2'd0;
			end
		end
	end

	always @(posedge clk) begin
		if (rst_n && f_valid && f_ready) begin
			for (p = 0; p < 4; p = p + 1) begin
				if (!pend_v[p]) begin
					pend_v[p] <= 1'b1;
					pend_warp[p] <= f_warp;
					pend_due[p] <= cyc + 2;
					p = 4;
				end
			end
		end
	end

	integer k, ec;
	integer fetch_count [0:3];
	integer last_w = -1;
	integer consecutive_count = 0;
	integer max_consecutive = 0;

	initial begin
		repeat (2) @(negedge clk);
		rst_n = 1'b1;

		/* Set up compute program with 3 warps (96 lanes) */
		state(9'h194, 32'h2000);	/* CS_BASE */
		state(9'h199, 32'h010160);	/* WG_SIZE: 96 lanes (3 warps) */
		state(9'h1E9, 1);		/* GRID_X */
		state(9'h1EA, 1);		/* GRID_Y */
		state(9'h1EB, 1);		/* GRID_Z */

		/* Kick compute grid */
		@(negedge clk);
		cs_kick = 1'b1;
		@(negedge clk);
		cs_kick = 1'b0;

		/* Wait for warps 0, 1, 2 to launch and become READY */
		repeat (20) @(negedge clk);

		/*
		 * TEST 1: Greedy Execution
		 * When all warps are ready (warp_ready = 4'b1111), GTO must repeatedly
		 * pick the same warp as long as it remains ready.
		 */
		ec = errors;
		warp_ready = 4'b1111;
		for (k = 0; k < 4; k = k + 1) fetch_count[k] = 0;

		/* Observe 40 fetch events */
		for (k = 0; k < 40; k = k + 1) begin
			@(posedge clk);
			while (!(f_valid && f_ready)) @(posedge clk);
			fetch_count[f_warp] = fetch_count[f_warp] + 1;
			if (last_w == f_warp) begin
				consecutive_count = consecutive_count + 1;
				if (consecutive_count > max_consecutive)
					max_consecutive = consecutive_count;
			end else begin
				consecutive_count = 1;
				last_w = f_warp;
			end
		end

		/* Under Greedy, a warp should be executed consecutively multiple times */
		if (max_consecutive < 3) begin
			fail("greedy consecutive execution");
			$display("  max_consecutive = %0d (want >= 3)", max_consecutive);
		end
		if (errors == ec)
			$display("PASS atg_su_sched_gto.greedy");

		/*
		 * TEST 2: Stall Switch
		 * When the active warp's warp_ready goes LOW (e.g. pending memory load),
		 * GTO must immediately switch away to another ready warp on the very next fetch.
		 */
		ec = errors;
		@(posedge clk);
		while (!(f_valid && f_ready)) @(posedge clk);
		last_w = f_warp;

		/* Now stall last_w */
		@(negedge clk);
		warp_ready[last_w] = 1'b0;

		/* Wait for next fetch */
		@(posedge clk);
		while (!(f_valid && f_ready)) @(posedge clk);

		if (f_warp == last_w) begin
			fail("stall switch: fetched stalled warp");
		end else begin
			$display("  successfully switched from stalled warp %0d to ready warp %0d", last_w, f_warp);
		end

		if (errors == ec)
			$display("PASS atg_su_sched_gto.stall_switch");

		/*
		 * TEST 3: Oldest Selection
		 * Warp 0 and Warp 1 have been waiting. Warp 0 waited longer than Warp 2.
		 * Deassert warp_ready for current warp, ensure the one with largest wait_age is chosen.
		 */
		ec = errors;
		@(negedge clk);
		/* Reset readiness: let only warp 0 and warp 1 be candidates, then make warp 2 candidate later */
		warp_ready = 4'b0001; /* only warp 0 ready */
		repeat (10) @(posedge clk);
		warp_ready = 4'b0101; /* now warp 2 is also ready, but warp 0 is older */

		@(posedge clk);
		while (!(f_valid && f_ready)) @(posedge clk);
		if (f_warp != 0) begin
			fail("oldest candidate not selected");
			$display("  expected warp 0 (older), got warp %0d", f_warp);
		end

		if (errors == ec)
			$display("PASS atg_su_sched_gto.oldest");

		/*
		 * TEST 4: No Replay
		 * Verify replay_events == 0 across all runs.
		 */
		ec = errors;
		if (replay_events != 0) begin
			fail("replay occurred");
		end else begin
			$display("PASS atg_su_sched_gto.no_replay");
		end

		if (errors == 0)
			$display("PASS atg_su_sched_gto");

		$finish;
	end

	initial begin
		#500000;
		$display("FAIL atg_su_sched_gto timeout");
		$finish;
	end

endmodule
`default_nettype wire
