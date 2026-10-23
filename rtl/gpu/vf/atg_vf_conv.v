/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_conv: VF format conversion: turns raw attribute bytes (R32F …
 * RGBA16F, RGBA8 UNORM/UINT, R32/RG32 UINT) into 32-bit words and writes
 * them into the SU's registers at ATTR_DST[k].
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/vf/atg_vf_conv.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_conv (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* Attribute data (atg_vf_fetch → atg_vf_conv) */
	input wire af_valid,
	output wire af_ready,
	input wire [3:0] af_attr,
	input wire [4:0] af_lane,
	input wire [127:0] af_raw,
	input wire af_last,
	/* Register writes to the SU (atg_su vl_*) */
	output wire vl_we,
	output wire [5:0] vl_reg,
	output wire [4:0] vl_lane,
	output wire [31:0] vl_data,
	output wire conv_done
);
	/* spec/gpu/vf/atg_vf_conv.md */
	assign af_ready = 1'd0;
	assign vl_we = 1'd0;
	assign vl_reg = 6'd0;
	assign vl_lane = 5'd0;
	assign vl_data = 32'd0;
	assign conv_done = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, st_we, st_idx, st_wdata, af_valid, af_attr, af_lane, af_raw, af_last};
endmodule

`default_nettype wire
