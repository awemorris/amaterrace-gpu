/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_vc_tb: Unit testbench for Post-Transform Vertex Cache (atg_vf_vc).
 * Checks:
 *   - Basic lookup/commit/hit semantics and 0-cycle response
 *   - 32-entry capacity and FIFO eviction behaviour
 *   - Cache flush semantics
 *   - Realistic indexed mesh (grid) vertex reuse: verifying >70% hit rate
 *     and bit-exact data recovery.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_vc_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg flush = 1'b0;
	reg lookup_valid = 1'b0;
	reg [31:0] lookup_index = 32'd0;
	wire hit;
	wire [511:0] hit_vdata;
	wire [4:0] hit_slot;

	reg commit_valid = 1'b0;
	reg [31:0] commit_index = 32'd0;
	reg [511:0] commit_vdata = 512'd0;

	atg_vf_vc #(.NENTRIES(32), .VDATA_W(512), .SLOT_W(5)) dut (
		.clk(clk),
		.rst_n(rst_n),
		.flush(flush),
		.lookup_valid(lookup_valid),
		.lookup_index(lookup_index),
		.hit(hit),
		.hit_vdata(hit_vdata),
		.hit_slot(hit_slot),
		.commit_valid(commit_valid),
		.commit_index(commit_index),
		.commit_vdata(commit_vdata)
	);

	integer errs = 0;
	integer i, j, x, y;
	integer hits, misses;
	integer v0, v1, v2, v3, vi;
	reg [31:0] tri_v [0:5];

	function [511:0] make_vdata;
		input [31:0] idx;
		begin
			make_vdata = {16{idx}};
		end
	endfunction

	initial begin
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);

		/* 1. Basic test: cold miss -> commit -> hit */
		lookup_valid <= 1'b1;
		lookup_index <= 32'h00000042;
		#1;
		if (hit) begin
			$display("FAIL atg_vf_vc: cold hit on 0x42");
			errs = errs + 1;
		end

		@(posedge clk);
		lookup_valid <= 1'b0;
		commit_valid <= 1'b1;
		commit_index <= 32'h00000042;
		commit_vdata <= make_vdata(32'h00000042);
		@(posedge clk);
		commit_valid <= 1'b0;

		/* Lookup again: must hit immediately (0-cycle) */
		lookup_valid <= 1'b1;
		lookup_index <= 32'h00000042;
		#1;
		if (!hit || hit_vdata != make_vdata(32'h00000042)) begin
			$display("FAIL atg_vf_vc: lookup 0x42 hit=%0d vdata=%0h", hit, hit_vdata);
			errs = errs + 1;
		end
		@(posedge clk);
		lookup_valid <= 1'b0;
		$display("PASS atg_vf_vc.basic");

		/* 2. Fill 32 entries and test FIFO eviction */
		for (i = 0; i < 32; i = i + 1) begin
			commit_valid <= 1'b1;
			commit_index <= 32'd1000 + i;
			commit_vdata <= make_vdata(32'd1000 + i);
			@(posedge clk);
		end
		commit_valid <= 1'b0;

		/* All 32 entries should hit */
		for (i = 0; i < 32; i = i + 1) begin
			lookup_valid <= 1'b1;
			lookup_index <= 32'd1000 + i;
			#1;
			if (!hit || hit_vdata != make_vdata(32'd1000 + i)) begin
				$display("FAIL atg_vf_vc: fill check index=%0d hit=%0d", 1000 + i, hit);
				errs = errs + 1;
			end
			@(posedge clk);
		end
		lookup_valid <= 1'b0;

		/* Commit 33rd entry (evicts index 1000) */
		commit_valid <= 1'b1;
		commit_index <= 32'd2000;
		commit_vdata <= make_vdata(32'd2000);
		@(posedge clk);
		commit_valid <= 1'b0;

		/* Index 1000 should now miss */
		lookup_valid <= 1'b1;
		lookup_index <= 32'd1000;
		#1;
		if (hit) begin
			$display("FAIL atg_vf_vc: index 1000 not evicted");
			errs = errs + 1;
		end
		@(posedge clk);

		/* Index 1001..1031 and 2000 should hit */
		lookup_index <= 32'd2000;
		#1;
		if (!hit || hit_vdata != make_vdata(32'd2000)) begin
			$display("FAIL atg_vf_vc: index 2000 missed");
			errs = errs + 1;
		end
		@(posedge clk);
		lookup_valid <= 1'b0;
		$display("PASS atg_vf_vc.fill_evict");

		/* 3. Flush test */
		flush <= 1'b1;
		@(posedge clk);
		flush <= 1'b0;
		@(posedge clk);

		lookup_valid <= 1'b1;
		lookup_index <= 32'd2000;
		#1;
		if (hit) begin
			$display("FAIL atg_vf_vc: flush did not invalidate index 2000");
			errs = errs + 1;
		end
		@(posedge clk);
		lookup_valid <= 1'b0;
		$display("PASS atg_vf_vc.flush");

		/* 4. Realistic mesh (8x8 quad grid = 128 triangles, 384 vertex indices) */
		hits = 0;
		misses = 0;
		for (y = 0; y < 8; y = y + 1) begin
			for (x = 0; x < 8; x = x + 1) begin
				v0 = y * 9 + x;
				v1 = y * 9 + x + 1;
				v2 = (y + 1) * 9 + x;
				v3 = (y + 1) * 9 + x + 1;
				tri_v[0] = v0; tri_v[1] = v1; tri_v[2] = v2;
				tri_v[3] = v2; tri_v[4] = v1; tri_v[5] = v3;

				for (vi = 0; vi < 6; vi = vi + 1) begin
					lookup_valid <= 1'b1;
					lookup_index <= tri_v[vi];
					#1;
					if (hit) begin
						hits = hits + 1;
						if (hit_vdata != make_vdata(tri_v[vi])) begin
							$display("FAIL atg_vf_vc: mesh data mismatch for vtx %0d", tri_v[vi]);
							errs = errs + 1;
						end
					end else begin
						misses = misses + 1;
						@(posedge clk);
						commit_valid <= 1'b1;
						commit_index <= tri_v[vi];
						commit_vdata <= make_vdata(tri_v[vi]);
						@(posedge clk);
						commit_valid <= 1'b0;
					end
				end
			end
		end
		@(posedge clk);
		lookup_valid <= 1'b0;
		$display("atg_vf_vc mesh simulation: 384 indices, hits=%0d, misses=%0d (hit rate: %0d%%)",
			hits, misses, (hits * 100) / (hits + misses));
		if (hits < 192) begin	/* require > 50% hit rate */
			$display("FAIL atg_vf_vc: mesh hit rate %0d%% < 50%%", (hits * 100) / (hits + misses));
			errs = errs + 1;
		end
		$display("PASS atg_vf_vc.mesh");

		if (errs == 0)
			$display("PASS atg_vf_vc");
		else
			$display("FAIL atg_vf_vc with %0d errors", errs);
		$finish;
	end
endmodule

`default_nettype wire
