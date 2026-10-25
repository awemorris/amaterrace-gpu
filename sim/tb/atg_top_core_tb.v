/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_core_tb: Vulkan 1.0 core rendering (CAPS[30]) through the whole
 * pipeline in the KC705's shape (64-byte lines, 512-bit AXI, the KC705's
 * SU with 64 varying words, HAS_VF, HAS_RX, HAS_TU, HAS_ROP, MS4): the ring
 * runs sim/vec/core_scene.txt (tools/rx-core-scene.py: the cases of the
 * generator's header: stencil with front and back state, D16, four
 * colour attachments, the fp32 blend, lines and points, depth bias, depth
 * clamp and clipping, the occlusion query, texture and vertex formats,
 * the blitter's KEEP, the guard band, four samples with stencil and MRT,
 * state changed back to back, reversed depth, a flat depth range,
 * RESOLVE formats, ETC2 and EAC, 64 varying words, the vertex stage's
 * texture slots and TEX_ROW; 1 MiB of memory, the aperture to 0xF0000).  Every word of each
 * case's images and query words must equal the reference models'
 * (PASS atg_top_core(kc705).CASE for each case); CAPS[30], CAPS[9] and the
 * FMT capability's words of every VkFormat value (PASS
 * atg_top_core(kc705).fmt).
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_top_scene.vh"

module atg_top_core_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	wire done_kc705;
	wire [31:0] err_kc705;

	always #5 clk = !clk;

	atg_top_scene_harness #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .NAME("kc705"),
		.TB("atg_top_core"), .SCENE("sim/vec/core_scene.txt"), .SEED(11), .HAS_VF(1),
		.NSU(1), .HAS_TU(1), .SU_NPHYS(16), .SU_GRP_W(1), .SU_VARY_WORDS(64), .SU_NREGS(64),
		.SU_SB_ENTRIES(8), .SU_SBE_W(3), .SU_PACKED(1), .SU_SUBGROUP(1), .SU_FRAG_RESERVE(2),
		.SU_LDS_BYTES(16384), .ROP_STENCIL(1), .MS4(1), .RING(32'h000D0000), .RING_LOG2(15),
		.WAIT_READS(8000000), .MEM_LOG2(20), .APER_LIMIT(32'h000F0000)) kc705 (
		.clk(clk), .rst_n(rst_n), .finished(done_kc705), .errors(err_kc705)
	);

	initial begin
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		wait (done_kc705);
		if (err_kc705 == 0)
			$display("PASS atg_top_core");
		else
			$display("FAIL atg_top_core: %0d errors", err_kc705);
		$finish;
	end

	initial begin
		#2000000000;
		#2000000000;
		$display("FAIL atg_top_core: timeout");
		$finish;
	end
endmodule

`default_nettype wire
