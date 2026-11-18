/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_lint.v: a lint-only top (tools/lint.sh) that calls the format
 * functions of include/atg_fmt_info.vh for any format value, so Verilator
 * checks them (the conversions are the modules of rtl/gpu/fmt).
 * Never used for simulation or synthesis.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_lint (
	input wire [7:0] fmt,
	input wire etc,
	output wire [67:0] info,
	output wire [25:0] feat
);
	`include "atg_fmt_info.vh"

	assign info = atg_fmt_info(fmt);
	assign feat = atg_fmt_feat(fmt, etc);
endmodule

`default_nettype wire
