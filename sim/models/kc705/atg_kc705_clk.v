/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_kc705_clk (simulation model): stands in for
 * boards/kc705/lib/atg_kc705_clk.v (same name and ports) in the KC705
 * board testbench, which compiles this file instead of the real one.
 * gclk is sys_clk_p / 2 (100 MHz from the testbench's 200 MHz; the
 * board's MMCM gives 1000 MHz / GCLK_DIVIDE, GCLK_HZ says so), ref_clk is
 * sys_clk_p, and pclk runs from its own delay at 25.185 MHz (pclk_sel 0)
 * or 74.21875 MHz (1), the frequencies of the real clock managers.  Each
 * reset is released LOCK_CYCLES cycles of its clock after CPU_RESET falls
 * (the "lock"), then through two flops as in the real wrapper.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_kc705_clk #(
	parameter integer LOCK_CYCLES = 16,
	parameter integer GCLK_DIVIDE = 50	/* the board's MMCM setting; the model's gclk is sys_clk / 2 */
) (
	input wire sys_clk_p,
	input wire sys_clk_n,
	input wire cpu_reset,
	input wire pclk_sel,
	output wire gclk,
	output wire grst_n,
	output wire ref_clk,
	output wire ref_rst_n,
	output wire pclk,
	output wire prst_n
);
	reg g = 1'b0;
	reg p = 1'b0;
	reg [1:0] gs = 2'b00, rs = 2'b00, ps = 2'b00;
	integer g_lock = 0;
	integer p_lock = 0;

	always @(posedge sys_clk_p)
		g <= !g;

	always begin
		#(pclk_sel === 1'b1 ? 6.737 : 19.853);
		p = !p;
	end

	assign gclk = g;
	assign ref_clk = sys_clk_p;
	assign pclk = p;

	always @(posedge g)
		if (cpu_reset)
			g_lock <= 0;
		else if (g_lock < LOCK_CYCLES)
			g_lock <= g_lock + 1;

	always @(posedge p)
		if (cpu_reset)
			p_lock <= 0;
		else if (p_lock < LOCK_CYCLES)
			p_lock <= p_lock + 1;

	always @(posedge g)
		gs <= {gs[0], g_lock == LOCK_CYCLES};
	always @(posedge sys_clk_p)
		rs <= {rs[0], !cpu_reset};
	always @(posedge p)
		ps <= {ps[0], p_lock == LOCK_CYCLES};

	assign grst_n = gs[1];
	assign ref_rst_n = rs[1];
	assign prst_n = ps[1];

	wire unused_ok = &{1'b0, sys_clk_n};
endmodule

`default_nettype wire
