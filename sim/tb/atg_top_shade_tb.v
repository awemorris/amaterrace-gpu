/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_shade_tb: the graphics pipeline through SU 0 (HAS_VF, NSU 1,
 * HAS_RX, HAS_ROP; WS288 p009): the ring runs sim/vec/shade_scene.txt
 * (tools/rx-shade-scene.py: SET_REG of the VF, program, raster and ROP
 * state, one DRAW of a triangle list with per-vertex colours, a vertex and
 * a fragment program in GSI1, a final FENCE): VF → vertex warps → PT → RX
 * (clip, setup, fragment warps with the barycentrics) → fragment warps
 * (lda, fmul, fmadd, exp) → ROP.  The colour and depth buffers must equal
 * the reference model's word for word.  In the ZYBO's shape and the
 * KC705's (64-byte lines, 512-bit AXI, NPHYS 16, 32 varying words).
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_top_scene.vh"

module atg_top_shade_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	wire done_zybo, done_kc705;
	wire [31:0] err_zybo, err_kc705;

	always #5 clk = !clk;

	atg_top_scene_harness #(.LINE_BYTES(32), .LINE_SHIFT(5), .DATA_W(64), .NAME("zybo"),
		.TB("atg_top_shade"), .SCENE("sim/vec/shade_scene.txt"), .SEED(5), .HAS_VF(1),
		.NSU(1)) zybo (
		.clk(clk), .rst_n(rst_n), .finished(done_zybo), .errors(err_zybo)
	);
	atg_top_scene_harness #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .NAME("kc705"),
		.TB("atg_top_shade"), .SCENE("sim/vec/shade_scene.txt"), .SEED(6), .HAS_VF(1),
		.NSU(1), .SU_NPHYS(16), .SU_GRP_W(1), .SU_VARY_WORDS(32)) kc705 (
		.clk(clk), .rst_n(rst_n), .finished(done_kc705), .errors(err_kc705)
	);

	initial begin
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		wait (done_zybo && done_kc705);
		if (err_zybo == 0 && err_kc705 == 0)
			$display("PASS atg_top_shade");
		else
			$display("FAIL atg_top_shade: %0d + %0d errors", err_zybo, err_kc705);
		$finish;
	end

	initial begin
		#400000000;
		$display("FAIL atg_top_shade: timeout");
		$finish;
	end
endmodule

`default_nettype wire
