/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_hazard_tb: Unit test for atg_rop_hazard Pixel Lock CAM.
 * Tests:
 * 1. 16-entry non-conflicting continuous burst throughput.
 * 2. Full CAM backpressure (stall when 16 entries occupied).
 * 3. RAW hazard detection and stall on matching {RT, Y, X}.
 * 4. Release and hazard clearing (immediate deassertion of stall).
 * 5. Distinct attachments (same X, Y but different RT) non-collision.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_hazard_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg alloc_valid = 1'b0;
	reg [31:0] alloc_tag = 32'd0;
	wire alloc_ready;
	wire [3:0] alloc_id;

	reg release_valid = 1'b0;
	reg [3:0] release_id = 4'd0;

	atg_rop_hazard #(.NUM_ENTRIES(16), .TAG_W(32)) dut (
		.clk(clk),
		.rst_n(rst_n),
		.alloc_valid(alloc_valid),
		.alloc_ready(alloc_ready),
		.alloc_tag(alloc_tag),
		.alloc_id(alloc_id),
		.release_valid(release_valid),
		.release_id(release_id)
	);

	integer i;
	reg [3:0] allocated_ids [0:15];

	initial begin
		rst_n <= 1'b0;
		alloc_valid <= 1'b0;
		release_valid <= 1'b0;
		@(posedge clk);
		@(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);

		/* -------------------------------------------------------------
		 * Test 1: Non-conflicting continuous burst throughput (16 entries)
		 * ------------------------------------------------------------- */
		for (i = 0; i < 16; i = i + 1) begin
			alloc_valid <= 1'b1;
			/* Unique coordinates: RT=0, Y=0, X = 2 * i */
			alloc_tag <= {2'd0, 15'd0, i[14:0]};
			@(posedge clk);
			if (!alloc_ready) begin
				$display("FAIL atg_rop_hazard: stalled on entry %0d during burst", i);
				$finish;
			end
			allocated_ids[i] = alloc_id;
		end

		/* 17th allocation must be stalled because CAM is full (16/16) */
		alloc_tag <= {2'd0, 15'd0, 15'd99};
		@(negedge clk);
		if (alloc_ready) begin
			$display("FAIL atg_rop_hazard: alloc_ready asserted when CAM is full");
			$finish;
		end

		/* Release 1 entry and verify alloc_ready becomes 1 */
		alloc_valid <= 1'b0;
		release_valid <= 1'b1;
		release_id <= allocated_ids[0];
		@(posedge clk);
		release_valid <= 1'b0;
		@(negedge clk);

		if (!alloc_ready) begin
			$display("FAIL atg_rop_hazard: alloc_ready not restored after release");
			$finish;
		end

		/* Release the remaining 15 entries */
		for (i = 1; i < 16; i = i + 1) begin
			release_valid <= 1'b1;
			release_id <= allocated_ids[i];
			@(posedge clk);
		end
		release_valid <= 1'b0;
		@(posedge clk);

		$display("PASS atg_rop_hazard.burst");

		/* -------------------------------------------------------------
		 * Test 2: RAW hazard detection & stall
		 * ------------------------------------------------------------- */
		/* Allocate quad at coordinate (X=10, Y=20, RT=0) */
		alloc_valid <= 1'b1;
		alloc_tag <= {2'd0, 15'd20, 15'd10};
		@(posedge clk);
		allocated_ids[0] = alloc_id;

		/* Attempt to allocate EXACT SAME coordinate: must hazard stall! */
		alloc_tag <= {2'd0, 15'd20, 15'd10};
		@(negedge clk);
		if (alloc_ready) begin
			$display("FAIL atg_rop_hazard: failed to detect RAW hazard on same coordinate");
			$finish;
		end

		/* Keep trying for 5 cycles: must remain stalled */
		for (i = 0; i < 5; i = i + 1) begin
			@(posedge clk);
			@(negedge clk);
			if (alloc_ready) begin
				$display("FAIL atg_rop_hazard: prematurely cleared hazard at cycle %0d", i);
				$finish;
			end
		end

		/* Now release the conflicting entry: hazard must clear immediately */
		release_valid <= 1'b1;
		release_id <= allocated_ids[0];
		@(negedge clk);
		if (!alloc_ready) begin
			$display("FAIL atg_rop_hazard: hazard not cleared in same cycle as release");
			$finish;
		end

		@(posedge clk);
		/* The second quad is now allocated */
		release_valid <= 1'b0;
		allocated_ids[1] = alloc_id;

		/* Different coordinate: should NOT stall */
		alloc_tag <= {2'd0, 15'd20, 15'd12};
		@(negedge clk);
		if (!alloc_ready) begin
			$display("FAIL atg_rop_hazard: falsely stalled on different X coordinate");
			$finish;
		end
		@(posedge clk);
		allocated_ids[2] = alloc_id;

		/* Same X, Y but DIFFERENT RT: should NOT stall */
		alloc_tag <= {2'd1, 15'd20, 15'd12};
		@(negedge clk);
		if (!alloc_ready) begin
			$display("FAIL atg_rop_hazard: falsely stalled on different RT attachment");
			$finish;
		end
		@(posedge clk);
		allocated_ids[3] = alloc_id;

		alloc_valid <= 1'b0;
		/* Release all active */
		release_valid <= 1'b1;
		release_id <= allocated_ids[1];
		@(posedge clk);
		release_id <= allocated_ids[2];
		@(posedge clk);
		release_id <= allocated_ids[3];
		@(posedge clk);
		release_valid <= 1'b0;
		@(posedge clk);

		$display("PASS atg_rop_hazard.raw");
		$display("PASS atg_rop_hazard");
		$finish;
	end
endmodule

`default_nettype wire
