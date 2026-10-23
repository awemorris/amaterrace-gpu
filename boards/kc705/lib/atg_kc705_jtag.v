/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_kc705_jtag: The KC705's JTAG register bridge: BSCANE2 (USER2) and
 * am_jtag_regs, giving the second register-bus master of atg_top (design
 * §4.4).
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/boards/kc705/lib/atg_kc705_jtag.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_kc705_jtag (
	input wire clk,
	input wire rst_n,
	output wire j_wr,
	output wire [16:0] j_waddr,
	output wire [31:0] j_wdata,
	output wire [3:0] j_wstrb,
	output wire j_rd,
	output wire [16:0] j_raddr,
	input wire [31:0] j_rdata,
	input wire j_busy
);
	/* spec/boards/kc705/lib/atg_kc705_jtag.md */
	assign j_wr = 1'd0;
	assign j_waddr = 17'd0;
	assign j_wdata = 32'd0;
	assign j_wstrb = 4'd0;
	assign j_rd = 1'd0;
	assign j_raddr = 17'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, j_rdata, j_busy};
endmodule

`default_nettype wire
