/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_lint.v: a lint-only top (tools/lint.sh) that calls the format
 * functions of include/atg_fmt_info.vh, atg_fmt_unpack.vh and
 * atg_fmt_pack.vh, so Verilator checks them before a block uses them.
 * Never used for simulation or synthesis.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_lint (
	input wire [127:0] raw,
	input wire [127:0] comps,
	input wire [7:0] fmt,
	input wire stencil,
	input wire etc,
	input wire [3:0] wm,
	output wire [128:0] up,
	output wire [255:0] pk,
	output wire [67:0] info,
	output wire [25:0] feat
);
	`include "atg_srgb.vh"
	`include "atg_fmt_info.vh"
	`include "atg_fmt_unpack.vh"
	`include "atg_fmt_pack.vh"

	assign up = atg_fmt_unpack(raw, fmt, stencil);
	assign pk = atg_fmt_pack(comps, fmt, wm);
	assign info = atg_fmt_info(fmt);
	assign feat = atg_fmt_feat(fmt, etc);
endmodule

`default_nettype wire
