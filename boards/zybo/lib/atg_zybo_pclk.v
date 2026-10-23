/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_zybo_pclk: The ZYBO DC's pixel clocks: an MMCME2 from FCLK_CLK0 (100
 * MHz) making 25.2 / 126 MHz (640×480) and 74.25 / 371.25 MHz (720p),
 * selected by a BUFGMUX pair (design §1.3, §5.1).
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/boards/zybo/lib/atg_zybo_pclk.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_zybo_pclk (
	input wire clk,
	input wire rst_n,
	input wire sel,
	output wire pclk,
	output wire pclk5,
	output wire prst_n,
	output wire locked
);
	/* spec/boards/zybo/lib/atg_zybo_pclk.md */
	assign pclk = 1'd0;
	assign pclk5 = 1'd0;
	assign prst_n = 1'd0;
	assign locked = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, sel};
endmodule

`default_nettype wire
