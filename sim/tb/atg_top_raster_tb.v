/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_raster_tb: the GPU with the RX and the ROP (HAS_RX, HAS_ROP),
 * driven only through its host port: the ring runs the scene of
 * sim/vec/raster_scene.txt (tools/rx-raster-scene.py: SET_REG of the
 * raster state, overlapping triangles by DRAW_RAW with DEBUG_COLOR, depth
 * LESS with write, the last ones blended over, a final FENCE), and the
 * colour and depth buffers must equal the reference model's
 * (tools/rxmodel.py) word for word.  In the ZYBO's shape and the KC705's.
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_top_scene.vh"

module atg_top_raster_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	wire done_zybo, done_kc705;
	wire [31:0] err_zybo, err_kc705;

	always #5 clk = !clk;

	atg_top_scene_harness #(.LINE_BYTES(32), .LINE_SHIFT(5), .DATA_W(64), .NAME("zybo"), .SEED(5)) zybo (
		.clk(clk), .rst_n(rst_n), .finished(done_zybo), .errors(err_zybo)
	);
	atg_top_scene_harness #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .NAME("kc705"), .SEED(6)) kc705 (
		.clk(clk), .rst_n(rst_n), .finished(done_kc705), .errors(err_kc705)
	);

	initial begin
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		wait (done_zybo && done_kc705);
		if (err_zybo == 0 && err_kc705 == 0)
			$display("PASS atg_top_raster");
		else
			$display("FAIL atg_top_raster: %0d + %0d errors", err_zybo, err_kc705);
		$finish;
	end

	initial begin
		#400000000;
		$display("FAIL atg_top_raster: timeout");
		$finish;
	end
endmodule

`default_nettype wire
