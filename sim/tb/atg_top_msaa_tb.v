/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_msaa_tb: 4x multisampling through the whole pipeline (HAS_VF,
 * NSU 1, HAS_RX, HAS_TU, HAS_ROP, MS4): the ring runs
 * sim/vec/msaa_scene.txt (tools/rx-msaa-scene.py: fourteen cases on 32x24
 * images in the sample-interleaved layout: a fan of triangles sharing
 * edges with additive blend, triangles crossing in depth (D32F), alpha to
 * coverage and alpha to one, SAMPLE_MASK exported twice (the last wins)
 * and r6 overwritten, centroid barycentrics r7-r9, the blitter's RESOLVE
 * of a two-layer image (offsets and a clip; a 4x4 tiled destination),
 * texf of the 4x depth in a 1x draw, an RGB565 target and its RESOLVE, a
 * 31x23 target, a 1x draw right after a 4x one, texf of the 31x23 4x
 * image, SAMPLE_KILL with CENTROID, a depth-only program with WRITE_MASK
 * 0 on D24, texsz.s of a 4x and a 1x slot): VF -> vertex warps -> PT -> RX -> fragment warps ->
 * TU / ROP -> BLT.  Every word of each case's images must equal the
 * reference models' (PASS atg_top_msaa(kc705).CASE for each of the 14);
 * CAPS[29] is set.  In the KC705's shape (64-byte lines, 512-bit AXI,
 * NPHYS 16, 32 varying words). */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_top_scene.vh"

module atg_top_msaa_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	wire done_kc705;
	wire [31:0] err_kc705;

	always #5 clk = !clk;

	atg_top_scene_harness #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .NAME("kc705"),
		.TB("atg_top_msaa"), .SCENE("sim/vec/msaa_scene.txt"), .SEED(9), .HAS_VF(1),
		.NSU(1), .HAS_TU(1), .SU_NPHYS(16), .SU_GRP_W(1), .SU_VARY_WORDS(64), .MS4(1),
		.RING(32'h0005C000), .RING_LOG2(13), .WAIT_READS(4000000)) kc705 (
		.clk(clk), .rst_n(rst_n), .finished(done_kc705), .errors(err_kc705)
	);

	initial begin
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		wait (done_kc705);
		if (err_kc705 == 0)
			$display("PASS atg_top_msaa");
		else
			$display("FAIL atg_top_msaa: %0d errors", err_kc705);
		$finish;
	end

	initial begin
		#2000000000;
		$display("FAIL atg_top_msaa: timeout");
		$finish;
	end
endmodule

`default_nettype wire
