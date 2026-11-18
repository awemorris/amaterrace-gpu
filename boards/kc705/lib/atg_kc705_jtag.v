/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_kc705_jtag: The KC705's JTAG register bridge: BSCANE2 (USER2) and
 * am_jtag_regs, giving the second register-bus master of atg_top (design
 * §4.4).  See spec/boards/kc705/lib/atg_kc705_jtag.md.
 *
 * BSCANE2 with JTAG_CHAIN 2 is the USER2 instruction (IR 0x03 on the 7
 * Series; Values referenced: UG470).  Its TCK goes through a BUFG (as in
 * zedBSD's KC705 bringup, which runs the same primitive on USER1); the XDC
 * declares that net as the 30 MHz tck clock.  In simulation the BSCANE2
 * is sim/models/xilinx/BSCANE2.v, whose tasks walk the TAP.
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
	wire tck_raw, tck, tdi, tdo, sel, capture, shift, update;

	BSCANE2 #(.JTAG_CHAIN(2)) bscan (
		.CAPTURE(capture), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel), .SHIFT(shift),
		.TCK(tck_raw), .TDI(tdi), .TMS(), .UPDATE(update), .TDO(tdo)
	);

	BUFG tck_bufg (.I(tck_raw), .O(tck));

	am_jtag_regs bridge (
		.clk(clk), .rst_n(rst_n),
		.tck(tck), .tdi(tdi), .tdo(tdo), .sel(sel), .capture(capture), .shift(shift),
		.update(update),
		.reg_wr(j_wr), .reg_waddr(j_waddr), .reg_wdata(j_wdata), .reg_wstrb(j_wstrb),
		.reg_rd(j_rd), .reg_raddr(j_raddr), .reg_rdata(j_rdata), .bus_busy(j_busy)
	);
endmodule

`default_nettype wire
