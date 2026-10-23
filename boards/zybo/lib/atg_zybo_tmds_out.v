/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_zybo_tmds_out: The ZYBO HDMI output stage: three OSERDESE2 10:1
 * serialisers (DDR, pclk5) for the TMDS symbols, the TMDS clock channel,
 * and OBUFDS (TMDS_33) for the four pairs.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/boards/zybo/lib/atg_zybo_tmds_out.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_zybo_tmds_out (
	input wire pclk,
	input wire pclk5,
	input wire rst_n,
	input wire [29:0] tmds,
	output wire hdmi_clk_p,
	output wire hdmi_clk_n,
	output wire [2:0] hdmi_d_p,
	output wire [2:0] hdmi_d_n
);
	/* spec/boards/zybo/lib/atg_zybo_tmds_out.md */
	assign hdmi_clk_p = 1'd0;
	assign hdmi_clk_n = 1'd0;
	assign hdmi_d_p = 3'd0;
	assign hdmi_d_n = 3'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		pclk, pclk5, rst_n, tmds};
endmodule

`default_nettype wire
