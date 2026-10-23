/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_blend: ROP blend: converts fp32 colour to the render-target
 * format, blends with the destination pixels (BLEND factors and ops,
 * BLEND_CONST), applies WRITE_MASK; a fixed pipeline used by atg_rop_wb.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/rop/atg_rop_blend.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_blend #(
	parameter LAT = 3	/* Pipeline cycles from b_valid to b_rvalid */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire b_valid,
	input wire [511:0] b_src,
	input wire [127:0] b_dst,
	input wire [3:0] b_mask,
	output wire b_rvalid,
	output wire [127:0] b_pix
);
	/* spec/gpu/rop/atg_rop_blend.md */
	assign b_rvalid = 1'd0;
	assign b_pix = 128'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, st_we, st_idx, st_wdata, b_valid, b_src, b_dst, b_mask, (LAT != 0)};
endmodule

`default_nettype wire
