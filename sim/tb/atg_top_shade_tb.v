/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_shade_tb: the graphics pipeline through SU 0 (HAS_VF, NSU 1,
 * HAS_RX, HAS_ROP): the ring runs sim/vec/shade_scene.txt
 * (tools/rx-shade-scene.py: SET_REG of the VF, program, raster and ROP
 * state, one DRAW of a triangle list with per-vertex colours, a vertex and
 * a fragment program in GSI1, a final FENCE): VF → vertex warps → PT → RX
 * (clip, setup, fragment warps with the barycentrics) → fragment warps
 * (lda, fmul, fmadd, exp) → ROP.  The colour and depth buffers must equal
 * the reference model's word for word.  In the KC705's shape
 * (64-byte lines, 512-bit AXI, and atg_top's blocks and SU shape
 * as in boards/kc705/atg_kc705_top.v: the TU, NPHYS 4, NREGS 64, 8
 * scoreboard entries, PACKED, SUBGROUP, FRAG_RESERVE 2, 16 KiB LDS, 32
 * varying words, the stencil ROP).
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_top_scene.vh"

module atg_top_shade_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	wire done_kc705;
	wire [31:0] err_kc705;

	always #5 clk = !clk;

	atg_top_scene_harness #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .NAME("kc705"),
		.TB("atg_top_shade"), .SCENE("sim/vec/shade_scene.txt"), .SEED(6), .HAS_VF(1),
		.NSU(1), .HAS_TU(1), .SU_NPHYS(4), .SU_GRP_W(3), .SU_VARY_WORDS(64), .SU_NREGS(64),
		.SU_SB_ENTRIES(8), .SU_SBE_W(3), .SU_PACKED(1), .SU_SUBGROUP(1), .SU_FRAG_RESERVE(2),
		.SU_LDS_BYTES(16384), .ROP_STENCIL(1)) kc705 (
		.clk(clk), .rst_n(rst_n), .finished(done_kc705), .errors(err_kc705)
	);

	/*
	 * Assert that during the interval from DRAW kick until the last ROP memory write,
	 * the pipeline busy mask (all units' busy OR checked by CP before FENCE)
	 * never drops to zero.
	 */
	reg draw_active = 1'b0;
	reg rop_has_written = 1'b0;
	wire rop_mem_wr = kc705.dut.g_rop.rop.req_valid && kc705.dut.g_rop.rop.req_ready && kc705.dut.g_rop.rop.req_write;

	always @(posedge clk) begin
		if (!rst_n) begin
			draw_active <= 1'b0;
			rop_has_written <= 1'b0;
		end else begin
			if (kc705.dut.draw_kick) begin
				draw_active <= 1'b1;
				rop_has_written <= 1'b0;
			end else if (draw_active && rop_has_written &&
			             !kc705.dut.rop_busy && !kc705.dut.rx_busy &&
			             !kc705.dut.su_busy && !kc705.dut.vf_busy) begin
				draw_active <= 1'b0;
			end

			if (rop_mem_wr)
				rop_has_written <= 1'b1;

			if (draw_active) begin
				if (kc705.dut.pipe_busy_mask == 8'd0) begin
					$display("FAIL atg_top_shade: pipe_busy_mask == 0 while DRAW in flight (rop_has_written=%b, time=%0t)",
						rop_has_written, $time);
					$finish;
				end
			end
		end
	end

	initial begin
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		wait (done_kc705);
		if (err_kc705 == 0)
			$display("PASS atg_top_shade");
		else
			$display("FAIL atg_top_shade: %0d errors", err_kc705);
		$finish;
	end

	initial begin
		#400000000;
		$display("FAIL atg_top_shade: timeout");
		$finish;
	end
endmodule

`default_nettype wire
