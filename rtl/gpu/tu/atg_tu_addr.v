/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_addr: TU addressing: per quad, the slot's descriptor (STATE
 * 16s+0..15), level of detail (texl explicit, texb from the quad
 * derivatives + bias, texf level), mip selection, wrap modes, bilinear
 * footprint, texel byte addresses (linear or 4×4 tiled), and texsz.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/tu/atg_tu_addr.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_addr (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* Requests from the SU (atg_su tx_* /tr_*) */
	input wire tx_valid,
	output wire tx_ready,
	input wire [1:0] tx_op,
	input wire [3:0] tx_slot,
	input wire [3:0] tx_mask,
	input wire [383:0] tx_coord,
	input wire [15:0] tx_tag,
	input wire tx_last,
	/* To atg_tu_cache */
	output wire ta_valid,
	input wire ta_ready,
	output wire [511:0] ta_addr,
	output wire [63:0] ta_wts,
	output wire [15:0] ta_tag,
	output wire [3:0] ta_mask,
	output wire [7:0] ta_ctl,
	output wire [127:0] ta_value,
	output wire ta_last
);
	/* spec/gpu/tu/atg_tu_addr.md */
	assign tx_ready = 1'd0;
	assign ta_valid = 1'd0;
	assign ta_addr = 512'd0;
	assign ta_wts = 64'd0;
	assign ta_tag = 16'd0;
	assign ta_mask = 4'd0;
	assign ta_ctl = 8'd0;
	assign ta_value = 128'd0;
	assign ta_last = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, st_we, st_idx, st_wdata, tx_valid, tx_op, tx_slot, tx_mask, tx_coord,
		tx_tag, tx_last, ta_ready};
endmodule

`default_nettype wire
