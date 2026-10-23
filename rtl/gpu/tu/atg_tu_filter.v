/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_filter: TU filtering: converts texels (RGBA8/BGRA8 UNORM, or raw
 * integers for texf) to fp32 RGBA and blends nearest or bilinear per lane.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/tu/atg_tu_filter.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_filter (
	input wire clk,
	input wire rst_n,
	/* From atg_tu_cache */
	input wire tc_valid,
	output wire tc_ready,
	input wire [511:0] tc_texels,
	input wire [63:0] tc_wts,
	input wire [15:0] tc_tag,
	input wire [3:0] tc_mask,
	input wire [7:0] tc_ctl,
	input wire [127:0] tc_value,
	input wire tc_last,
	/* Return to the SU */
	output wire tr_valid,
	input wire tr_ready,
	output wire [15:0] tr_tag,
	output wire [511:0] tr_data,
	output wire tr_last
);
	/* spec/gpu/tu/atg_tu_filter.md */
	assign tc_ready = 1'd0;
	assign tr_valid = 1'd0;
	assign tr_tag = 16'd0;
	assign tr_data = 512'd0;
	assign tr_last = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, tc_valid, tc_texels, tc_wts, tc_tag, tc_mask, tc_ctl, tc_value, tc_last,
		tr_ready};
endmodule

`default_nettype wire
