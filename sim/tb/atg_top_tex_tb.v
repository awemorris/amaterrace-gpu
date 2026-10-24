/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_tex_tb: the graphics pipeline with the texture unit (HAS_VF,
 * NSU 1, HAS_RX, HAS_TU, HAS_ROP): the ring runs
 * sim/vec/tex_scene.txt (tools/rx-tex-scene.py: seven DRAWs of textured
 * triangles, the first sampling with texb from a linear RGBA8 texture
 * with mip levels, the second, after SET_REG changes the slot and the
 * fragment program, with texl from a 4x4 tiled BGRA8 copy, the third
 * trilinear with clamp to border, the fourth a D24 compare sampler with
 * bilinear and mip linear filtering (texb, z the reference), the fifth a
 * D32F compare sampler with clamp to border (texl), the sixth a gather
 * (texg), the seventh a LOD query (texqlod), a final FENCE):
 * VF → vertex warps → PT → RX → fragment warps (lda, fmul, fmadd, texb or
 * texl, exp) ↔ TU (addressing, cache on its MC port, filter) → ROP.  The
 * colour and depth buffers must equal the reference models' word for
 * word.  In the ZYBO's shape (the ZYBO's bitstreams have no TU: the shape
 * is only the line and beat sizes) and the KC705's (64-byte lines, 512-bit
 * AXI, NPHYS 16, 32 varying words).
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_top_scene.vh"

module atg_top_tex_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	wire done_zybo, done_kc705;
	wire [31:0] err_zybo, err_kc705;

	always #5 clk = !clk;
	`include "tb_shape.vh"

	atg_top_scene_harness #(.LINE_BYTES(32), .LINE_SHIFT(5), .DATA_W(64), .NAME("zybo"),
		.TB("atg_top_tex"), .SCENE("sim/vec/tex_scene.txt"), .SEED(5), .HAS_VF(1),
		.NSU(1), .HAS_TU(1)) zybo (
		.clk(clk_zybo), .rst_n(rst_n), .finished(done_zybo), .errors(err_zybo)
	);
	atg_top_scene_harness #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .NAME("kc705"),
		.TB("atg_top_tex"), .SCENE("sim/vec/tex_scene.txt"), .SEED(6), .HAS_VF(1),
		.NSU(1), .HAS_TU(1), .SU_NPHYS(16), .SU_GRP_W(1), .SU_VARY_WORDS(32)) kc705 (
		.clk(clk_kc705), .rst_n(rst_n), .finished(done_kc705), .errors(err_kc705)
	);

	initial begin
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		wait ((done_zybo || !run_zybo) && (done_kc705 || !run_kc705));
		if (err_zybo == 0 && err_kc705 == 0)
			$display("PASS atg_top_tex");
		else
			$display("FAIL atg_top_tex: %0d + %0d errors", err_zybo, err_kc705);
		$finish;
	end

	initial begin
		#400000000;
		$display("FAIL atg_top_tex: timeout");
		$finish;
	end
endmodule

`default_nettype wire
