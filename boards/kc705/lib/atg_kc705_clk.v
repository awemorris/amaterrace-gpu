/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_kc705_clk: The KC705's clocks: SYSCLK 200 MHz (differential) →
 * MMCME2 → gclk 100 MHz, the MIG reference, and the pixel clocks (BUFGMUX
 * by PCLK_SEL); resets synchronised per domain.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/boards/kc705/lib/atg_kc705_clk.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_kc705_clk (
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
	/* spec/boards/kc705/lib/atg_kc705_clk.md */
	assign gclk = 1'd0;
	assign grst_n = 1'd0;
	assign ref_clk = 1'd0;
	assign ref_rst_n = 1'd0;
	assign pclk = 1'd0;
	assign prst_n = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		sys_clk_p, sys_clk_n, cpu_reset, pclk_sel};
endmodule

`default_nettype wire
