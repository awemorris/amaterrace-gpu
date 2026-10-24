/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_tex_tb: the graphics pipeline with the texture unit (HAS_VF,
 * NSU 1, HAS_RX, HAS_TU, HAS_ROP): the ring runs
 * sim/vec/tex_scene.txt (tools/rx-tex-scene.py: twelve DRAWs of textured
 * triangles: texb from a linear RGBA8 texture with mip levels; after
 * SET_REG changes the slot and the fragment program, texl from a 4x4
 * tiled BGRA8 copy; trilinear with clamp to border; a D24 compare sampler
 * with bilinear and mip linear filtering (texb.c, z the reference); a D32F
 * compare sampler with clamp to border (texl.c); a gather (texg); a LOD
 * query (texqlod); a 2D array (texl.3, the layer 4 z, texel offsets); a
 * 3D texture (texb.3, w = z, linear in three axes and mip linear); a cube
 * map (texb.3, the direction across the faces' edges and corners);
 * offsets with mirrored repeat (texl); unnormalized coordinates; a final
 * FENCE): VF → vertex warps → PT → RX → fragment warps (lda, fmul, fmadd,
 * texture instructions, exp) ↔ TU (addressing, cache on its MC port,
 * filter) → ROP.  The colour and depth buffers must equal the reference
 * models' word for word.  In the KC705's shape (64-byte lines, 512-bit
 * AXI, NPHYS 16, 32 varying words). */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_top_scene.vh"

module atg_top_tex_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	wire done_kc705;
	wire [31:0] err_kc705;

	always #5 clk = !clk;

	atg_top_scene_harness #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .NAME("kc705"),
		.TB("atg_top_tex"), .SCENE("sim/vec/tex_scene.txt"), .SEED(6), .HAS_VF(1),
		.NSU(1), .HAS_TU(1), .SU_NPHYS(16), .SU_GRP_W(1), .SU_VARY_WORDS(32)) kc705 (
		.clk(clk), .rst_n(rst_n), .finished(done_kc705), .errors(err_kc705)
	);

	initial begin
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		wait (done_kc705);
		if (err_kc705 == 0)
			$display("PASS atg_top_tex");
		else
			$display("FAIL atg_top_tex: %0d errors", err_kc705);
		$finish;
	end

	initial begin
		#800000000;
		$display("FAIL atg_top_tex: timeout");
		$finish;
	end
endmodule

`default_nettype wire
