/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_jtag_regs: KC705 JTAG register bridge: a BSCANE2 USER2 data register
 * of 72 bits {cmd, addr, data} that becomes a second master on the GHCI
 * register bus (DBG capability).
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/common/am_jtag_regs.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_jtag_regs (
	input wire clk,
	input wire rst_n,
	/* From BSCANE2 (tck domain) */
	input wire tck,
	input wire tdi,
	output wire tdo,
	input wire sel,
	input wire capture,
	input wire shift,
	input wire update,
	/* Register bus master (gclk) */
	output wire reg_wr,
	output wire [16:0] reg_waddr,
	output wire [31:0] reg_wdata,
	output wire [3:0] reg_wstrb,
	output wire reg_rd,
	output wire [16:0] reg_raddr,
	input wire [31:0] reg_rdata,
	input wire bus_busy
);
	/* spec/common/am_jtag_regs.md */
	assign tdo = 1'd0;
	assign reg_wr = 1'd0;
	assign reg_waddr = 17'd0;
	assign reg_wdata = 32'd0;
	assign reg_wstrb = 4'd0;
	assign reg_rd = 1'd0;
	assign reg_raddr = 17'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, tck, tdi, sel, capture, shift, update, reg_rdata, bus_busy};
endmodule

`default_nettype wire
