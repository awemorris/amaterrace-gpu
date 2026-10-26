/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_mshr_tb: Unit testbench for atg_tu_mshr (4-entry MSHR).
 *
 * Verifies:
 *   1. Primary miss allocation across all 4 entries (0..3).
 *   2. Full condition and backpressure (alloc_ready deasserts when 4 entries full).
 *   3. Secondary miss / Merge: identical line address merges onto existing entry
 *      without consuming a new entry, accumulating quad mask.
 *   4. Out-of-order and parallel refills from memory.
 *   5. Hit-Under-Miss: 80-cycle latency miss in flight while subsequent hits
 *      and secondary misses are handled.
 *   6. Same-cycle refill and allocation reuse.
 */

`timescale 1ns / 1ps
`default_nettype none

`ifndef CFG_ENABLE_MSHR
`define CFG_ENABLE_MSHR 1
`endif

module atg_tu_mshr_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;

	always #5 clk = !clk;

	localparam NENTRIES   = 4;
	localparam ADDR_W     = 32;
	localparam LINE_BYTES = 64;
	localparam LINE_SHIFT = 6;
	localparam QUAD_ID_W  = 6;
	localparam LA_W       = ADDR_W - LINE_SHIFT;
	localparam LB         = LINE_BYTES * 8;
	localparam QMASK_W    = 1 << QUAD_ID_W;

	reg check_valid = 1'b0;
	reg [LA_W-1:0] check_line_addr = 0;
	wire check_hit;
	wire [1:0] check_mshr_idx;

	reg alloc_valid = 1'b0;
	wire alloc_ready;
	reg [LA_W-1:0] alloc_line_addr = 0;
	reg [QUAD_ID_W-1:0] alloc_quad_id = 0;
	wire [1:0] alloc_mshr_idx;
	wire alloc_merged;

	reg refill_valid = 1'b0;
	reg [1:0] refill_mshr_idx = 0;
	reg [LB-1:0] refill_data = 0;
	reg refill_error = 1'b0;

	wire mshr_ready_valid;
	wire [QUAD_ID_W-1:0] mshr_ready_quad_id;
	wire [QMASK_W-1:0] mshr_ready_mask;
	wire [LB-1:0] mshr_ready_data;
	wire [LA_W-1:0] mshr_ready_line;
	wire mshr_ready_error;
	wire [1:0] mshr_ready_idx;

	wire [2:0] active_count;
	wire empty, full;

	integer errors = 0;

	atg_tu_mshr #(
		.NENTRIES(NENTRIES),
		.ADDR_W(ADDR_W),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.QUAD_ID_W(QUAD_ID_W)
	) dut (
		.clk(clk),
		.rst_n(rst_n),
		.check_valid(check_valid),
		.check_line_addr(check_line_addr),
		.check_hit(check_hit),
		.check_mshr_idx(check_mshr_idx),
		.alloc_valid(alloc_valid),
		.alloc_ready(alloc_ready),
		.alloc_line_addr(alloc_line_addr),
		.alloc_quad_id(alloc_quad_id),
		.alloc_mshr_idx(alloc_mshr_idx),
		.alloc_merged(alloc_merged),
		.refill_valid(refill_valid),
		.refill_mshr_idx(refill_mshr_idx),
		.refill_data(refill_data),
		.refill_error(refill_error),
		.mshr_ready_valid(mshr_ready_valid),
		.mshr_ready_quad_id(mshr_ready_quad_id),
		.mshr_ready_mask(mshr_ready_mask),
		.mshr_ready_data(mshr_ready_data),
		.mshr_ready_line(mshr_ready_line),
		.mshr_ready_error(mshr_ready_error),
		.mshr_ready_idx(mshr_ready_idx),
		.active_count(active_count),
		.empty(empty),
		.full(full),
		.mshr_vld_vec(),
		.mshr_line_vec()
	);

	task fail(input [80*8-1:0] msg);
		begin
			$display("FAIL atg_tu_mshr: %0s", msg);
			errors = errors + 1;
		end
	endtask

	integer step;

	initial begin
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);

		/* 1. Check initial state */
		if (!empty || full || active_count !== 3'd0)
			fail("initial state not empty");

		/* 2. Primary miss allocation: fill all 4 entries */
		// Entry 0
		alloc_valid <= 1'b1;
		alloc_line_addr <= 26'h001000;
		alloc_quad_id <= 6'd10;
		@(posedge clk);
		if (alloc_mshr_idx !== 2'd0 || alloc_merged !== 1'b0 || !alloc_ready)
			fail("entry 0 allocation mismatch");

		// Entry 1
		alloc_line_addr <= 26'h002000;
		alloc_quad_id <= 6'd11;
		@(posedge clk);
		if (alloc_mshr_idx !== 2'd1 || alloc_merged !== 1'b0 || !alloc_ready)
			fail("entry 1 allocation mismatch");

		// Entry 2
		alloc_line_addr <= 26'h003000;
		alloc_quad_id <= 6'd12;
		@(posedge clk);
		if (alloc_mshr_idx !== 2'd2 || alloc_merged !== 1'b0 || !alloc_ready)
			fail("entry 2 allocation mismatch");

		// Entry 3
		alloc_line_addr <= 26'h004000;
		alloc_quad_id <= 6'd13;
		@(posedge clk);
		if (alloc_mshr_idx !== 2'd3 || alloc_merged !== 1'b0 || !alloc_ready)
			fail("entry 3 allocation mismatch");

		alloc_valid <= 1'b0;
		@(posedge clk);

		if (!full || active_count !== 3'd4)
			fail("mshr should be full with active_count=4");

		/* 3. Full backpressure check: new line cannot be allocated */
		alloc_valid <= 1'b1;
		alloc_line_addr <= 26'h005000;
		alloc_quad_id <= 6'd14;
		#1;
		if (alloc_ready !== 1'b0 || alloc_merged !== 1'b0)
			fail("alloc_ready should be 0 when full and non-matching");
		alloc_valid <= 1'b0;
		@(posedge clk);

		/* 4. Secondary Miss / Merge while full */
		// Line 0x002000 is in entry 1: it should merge even when full!
		alloc_valid <= 1'b1;
		alloc_line_addr <= 26'h002000;
		alloc_quad_id <= 6'd25;
		#1;
		if (alloc_ready !== 1'b1 || alloc_merged !== 1'b1 || alloc_mshr_idx !== 2'd1)
			fail("merge into entry 1 failed while full");
		@(posedge clk);
		alloc_valid <= 1'b0;
		@(posedge clk);

		/* 5. Refill Entry 1 out-of-order */
		refill_valid <= 1'b1;
		refill_mshr_idx <= 2'd1;
		refill_data <= {16{32'hDEADBEEF}};
		refill_error <= 1'b0;
		@(posedge clk);
		refill_valid <= 1'b0;
		#1;
		if (!mshr_ready_valid || mshr_ready_idx !== 2'd1 || mshr_ready_quad_id !== 6'd11)
			fail("mshr_ready_valid or quad_id mismatch on refill entry 1");
		if (mshr_ready_line !== 26'h002000 || mshr_ready_data !== {16{32'hDEADBEEF}})
			fail("mshr_ready line or data mismatch on entry 1");
		if (mshr_ready_mask[11] !== 1'b1 || mshr_ready_mask[25] !== 1'b1)
			fail("mshr_ready_mask should have both primary (11) and secondary (25) set");
		if (full || active_count !== 3'd3)
			fail("active_count should be 3 after freeing entry 1");

		/* 6. Allocate into freed Entry 1 */
		alloc_valid <= 1'b1;
		alloc_line_addr <= 26'h005000;
		alloc_quad_id <= 6'd15;
		@(posedge clk);
		if (alloc_mshr_idx !== 2'd1 || alloc_merged !== 1'b0)
			fail("reallocation of entry 1 failed");
		alloc_valid <= 1'b0;
		@(posedge clk);

		/* 7. Refill remaining entries: 0, 2, 3, 1 */
		// Refill 0
		refill_valid <= 1'b1;
		refill_mshr_idx <= 2'd0;
		refill_data <= {16{32'hCAFEBABE}};
		@(posedge clk);
		refill_mshr_idx <= 2'd2;
		refill_data <= {16{32'h11223344}};
		@(posedge clk);
		refill_mshr_idx <= 2'd3;
		refill_data <= {16{32'h55667788}};
		@(posedge clk);
		refill_mshr_idx <= 2'd1;
		refill_data <= {16{32'h99AABBCC}};
		@(posedge clk);
		refill_valid <= 1'b0;
		@(posedge clk);

		if (!empty || active_count !== 3'd0)
			fail("mshr should be empty after all refills");

		/* 8. Hit-Under-Miss scenario with 80 cycles latency */
		// Miss 0 allocated at t=0
		alloc_valid <= 1'b1;
		alloc_line_addr <= 26'h008000;
		alloc_quad_id <= 6'd1;
		@(posedge clk);
		alloc_valid <= 1'b0;

		// Query checks: line 0x008000 is in flight
		check_valid <= 1'b1;
		check_line_addr <= 26'h008000;
		#1;
		if (!check_hit || check_mshr_idx !== 2'd0)
			fail("check_hit failed on in-flight line 0x008000");

		// Non-matching query: line 0x009000 is NOT in flight (hit in cache)
		check_line_addr <= 26'h009000;
		#1;
		if (check_hit)
			fail("check_hit should be 0 for line not in flight");
		check_valid <= 1'b0;

		// Secondary miss arrives during memory latency
		repeat (30) @(posedge clk);
		alloc_valid <= 1'b1;
		alloc_line_addr <= 26'h008000;
		alloc_quad_id <= 6'd2;
		@(posedge clk);
		alloc_valid <= 1'b0;

		// Another miss on independent line arrives
		repeat (20) @(posedge clk);
		alloc_valid <= 1'b1;
		alloc_line_addr <= 26'h00A000;
		alloc_quad_id <= 6'd3;
		@(posedge clk);
		if (alloc_mshr_idx !== 2'd1 || alloc_merged !== 1'b0)
			fail("second independent miss should allocate entry 1");
		alloc_valid <= 1'b0;

		// Complete remaining cycles of 80-cycle latency
		repeat (28) @(posedge clk);
		refill_valid <= 1'b1;
		refill_mshr_idx <= 2'd0;
		refill_data <= {16{32'h88880000}};
		@(posedge clk);
		refill_valid <= 1'b0;
		#1;
		if (!mshr_ready_valid || mshr_ready_mask[1] !== 1'b1 || mshr_ready_mask[2] !== 1'b1)
			fail("refill of 80-cycle miss should notify both quad 1 and quad 2");

		// Refill second miss
		@(posedge clk);
		refill_valid <= 1'b1;
		refill_mshr_idx <= 2'd1;
		refill_data <= {16{32'hAAAA0000}};
		@(posedge clk);
		refill_valid <= 1'b0;
		@(posedge clk);

		if (!empty)
			fail("mshr should be empty at end of test");

		if (errors == 0)
			$display("PASS atg_tu_mshr");
		else
			$display("FAIL atg_tu_mshr: %0d errors", errors);

		$finish;
	end

	initial begin
		#200000;
		$display("FAIL atg_tu_mshr: timeout");
		$finish;
	end
endmodule

`default_nettype wire
