/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * xilinx_stubs.v: lint-only stand-ins for the Xilinx primitives that the
 * board tops instantiate (tools/lint.sh uses them, nothing else does): the
 * ports the tops use, every output 0.  The PS7 port names and widths are
 * those of Vivado 2026.1's unisims PS7.v (Values referenced: interface
 * names and widths only); BUFG is I/O; PLLE2_BASE, MMCME2_BASE, BUFGMUX,
 * OSERDESE2 and OBUFDS (the ZYBO DC) have the ports and parameters the tops
 * use.
 * Never used for simulation or synthesis.
 */

`timescale 1ns / 1ps
`default_nettype none

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDPARAM */
module BUFG (
	input wire I,
	output wire O
);
	assign O = I;
endmodule

module PS7 (
	output wire [3:0] FCLKCLK,
	output wire [3:0] FCLKRESETN,
	output wire [31:0] MAXIGP0ARADDR,
	output wire [1:0] MAXIGP0ARBURST,
	output wire [3:0] MAXIGP0ARCACHE,
	output wire MAXIGP0ARESETN,
	output wire [11:0] MAXIGP0ARID,
	output wire [3:0] MAXIGP0ARLEN,
	output wire [1:0] MAXIGP0ARLOCK,
	output wire [2:0] MAXIGP0ARPROT,
	output wire [3:0] MAXIGP0ARQOS,
	output wire [1:0] MAXIGP0ARSIZE,
	output wire MAXIGP0ARVALID,
	output wire [31:0] MAXIGP0AWADDR,
	output wire [1:0] MAXIGP0AWBURST,
	output wire [3:0] MAXIGP0AWCACHE,
	output wire [11:0] MAXIGP0AWID,
	output wire [3:0] MAXIGP0AWLEN,
	output wire [1:0] MAXIGP0AWLOCK,
	output wire [2:0] MAXIGP0AWPROT,
	output wire [3:0] MAXIGP0AWQOS,
	output wire [1:0] MAXIGP0AWSIZE,
	output wire MAXIGP0AWVALID,
	output wire MAXIGP0BREADY,
	output wire MAXIGP0RREADY,
	output wire [31:0] MAXIGP0WDATA,
	output wire [11:0] MAXIGP0WID,
	output wire MAXIGP0WLAST,
	output wire [3:0] MAXIGP0WSTRB,
	output wire MAXIGP0WVALID,
	output wire SAXIHP0ARESETN,
	output wire SAXIHP0ARREADY,
	output wire SAXIHP0AWREADY,
	output wire [5:0] SAXIHP0BID,
	output wire [1:0] SAXIHP0BRESP,
	output wire SAXIHP0BVALID,
	output wire [2:0] SAXIHP0RACOUNT,
	output wire [7:0] SAXIHP0RCOUNT,
	output wire [63:0] SAXIHP0RDATA,
	output wire [5:0] SAXIHP0RID,
	output wire SAXIHP0RLAST,
	output wire [1:0] SAXIHP0RRESP,
	output wire SAXIHP0RVALID,
	output wire [5:0] SAXIHP0WACOUNT,
	output wire [7:0] SAXIHP0WCOUNT,
	output wire SAXIHP0WREADY,
	output wire SAXIHP1ARESETN,
	output wire SAXIHP1ARREADY,
	output wire SAXIHP1AWREADY,
	output wire [5:0] SAXIHP1BID,
	output wire [1:0] SAXIHP1BRESP,
	output wire SAXIHP1BVALID,
	output wire [2:0] SAXIHP1RACOUNT,
	output wire [7:0] SAXIHP1RCOUNT,
	output wire [63:0] SAXIHP1RDATA,
	output wire [5:0] SAXIHP1RID,
	output wire SAXIHP1RLAST,
	output wire [1:0] SAXIHP1RRESP,
	output wire SAXIHP1RVALID,
	output wire [5:0] SAXIHP1WACOUNT,
	output wire [7:0] SAXIHP1WCOUNT,
	output wire SAXIHP1WREADY,
	input wire [19:0] IRQF2P,
	input wire MAXIGP0ACLK,
	input wire MAXIGP0ARREADY,
	input wire MAXIGP0AWREADY,
	input wire [11:0] MAXIGP0BID,
	input wire [1:0] MAXIGP0BRESP,
	input wire MAXIGP0BVALID,
	input wire [31:0] MAXIGP0RDATA,
	input wire [11:0] MAXIGP0RID,
	input wire MAXIGP0RLAST,
	input wire [1:0] MAXIGP0RRESP,
	input wire MAXIGP0RVALID,
	input wire MAXIGP0WREADY,
	input wire SAXIHP0ACLK,
	input wire [31:0] SAXIHP0ARADDR,
	input wire [1:0] SAXIHP0ARBURST,
	input wire [3:0] SAXIHP0ARCACHE,
	input wire [5:0] SAXIHP0ARID,
	input wire [3:0] SAXIHP0ARLEN,
	input wire [1:0] SAXIHP0ARLOCK,
	input wire [2:0] SAXIHP0ARPROT,
	input wire [3:0] SAXIHP0ARQOS,
	input wire [1:0] SAXIHP0ARSIZE,
	input wire SAXIHP0ARVALID,
	input wire [31:0] SAXIHP0AWADDR,
	input wire [1:0] SAXIHP0AWBURST,
	input wire [3:0] SAXIHP0AWCACHE,
	input wire [5:0] SAXIHP0AWID,
	input wire [3:0] SAXIHP0AWLEN,
	input wire [1:0] SAXIHP0AWLOCK,
	input wire [2:0] SAXIHP0AWPROT,
	input wire [3:0] SAXIHP0AWQOS,
	input wire [1:0] SAXIHP0AWSIZE,
	input wire SAXIHP0AWVALID,
	input wire SAXIHP0BREADY,
	input wire SAXIHP0RDISSUECAP1EN,
	input wire SAXIHP0RREADY,
	input wire [63:0] SAXIHP0WDATA,
	input wire [5:0] SAXIHP0WID,
	input wire SAXIHP0WLAST,
	input wire SAXIHP0WRISSUECAP1EN,
	input wire [7:0] SAXIHP0WSTRB,
	input wire SAXIHP0WVALID,
	input wire SAXIHP1ACLK,
	input wire [31:0] SAXIHP1ARADDR,
	input wire [1:0] SAXIHP1ARBURST,
	input wire [3:0] SAXIHP1ARCACHE,
	input wire [5:0] SAXIHP1ARID,
	input wire [3:0] SAXIHP1ARLEN,
	input wire [1:0] SAXIHP1ARLOCK,
	input wire [2:0] SAXIHP1ARPROT,
	input wire [3:0] SAXIHP1ARQOS,
	input wire [1:0] SAXIHP1ARSIZE,
	input wire SAXIHP1ARVALID,
	input wire [31:0] SAXIHP1AWADDR,
	input wire [1:0] SAXIHP1AWBURST,
	input wire [3:0] SAXIHP1AWCACHE,
	input wire [5:0] SAXIHP1AWID,
	input wire [3:0] SAXIHP1AWLEN,
	input wire [1:0] SAXIHP1AWLOCK,
	input wire [2:0] SAXIHP1AWPROT,
	input wire [3:0] SAXIHP1AWQOS,
	input wire [1:0] SAXIHP1AWSIZE,
	input wire SAXIHP1AWVALID,
	input wire SAXIHP1BREADY,
	input wire SAXIHP1RDISSUECAP1EN,
	input wire SAXIHP1RREADY,
	input wire [63:0] SAXIHP1WDATA,
	input wire [5:0] SAXIHP1WID,
	input wire SAXIHP1WLAST,
	input wire SAXIHP1WRISSUECAP1EN,
	input wire [7:0] SAXIHP1WSTRB,
	input wire SAXIHP1WVALID
);
	assign FCLKCLK = 4'd0;
	assign FCLKRESETN = 4'd0;
	assign MAXIGP0ARADDR = 32'd0;
	assign MAXIGP0ARBURST = 2'd0;
	assign MAXIGP0ARCACHE = 4'd0;
	assign MAXIGP0ARESETN = 1'd0;
	assign MAXIGP0ARID = 12'd0;
	assign MAXIGP0ARLEN = 4'd0;
	assign MAXIGP0ARLOCK = 2'd0;
	assign MAXIGP0ARPROT = 3'd0;
	assign MAXIGP0ARQOS = 4'd0;
	assign MAXIGP0ARSIZE = 2'd0;
	assign MAXIGP0ARVALID = 1'd0;
	assign MAXIGP0AWADDR = 32'd0;
	assign MAXIGP0AWBURST = 2'd0;
	assign MAXIGP0AWCACHE = 4'd0;
	assign MAXIGP0AWID = 12'd0;
	assign MAXIGP0AWLEN = 4'd0;
	assign MAXIGP0AWLOCK = 2'd0;
	assign MAXIGP0AWPROT = 3'd0;
	assign MAXIGP0AWQOS = 4'd0;
	assign MAXIGP0AWSIZE = 2'd0;
	assign MAXIGP0AWVALID = 1'd0;
	assign MAXIGP0BREADY = 1'd0;
	assign MAXIGP0RREADY = 1'd0;
	assign MAXIGP0WDATA = 32'd0;
	assign MAXIGP0WID = 12'd0;
	assign MAXIGP0WLAST = 1'd0;
	assign MAXIGP0WSTRB = 4'd0;
	assign MAXIGP0WVALID = 1'd0;
	assign SAXIHP0ARESETN = 1'd0;
	assign SAXIHP0ARREADY = 1'd0;
	assign SAXIHP0AWREADY = 1'd0;
	assign SAXIHP0BID = 6'd0;
	assign SAXIHP0BRESP = 2'd0;
	assign SAXIHP0BVALID = 1'd0;
	assign SAXIHP0RACOUNT = 3'd0;
	assign SAXIHP0RCOUNT = 8'd0;
	assign SAXIHP0RDATA = 64'd0;
	assign SAXIHP0RID = 6'd0;
	assign SAXIHP0RLAST = 1'd0;
	assign SAXIHP0RRESP = 2'd0;
	assign SAXIHP0RVALID = 1'd0;
	assign SAXIHP0WACOUNT = 6'd0;
	assign SAXIHP0WCOUNT = 8'd0;
	assign SAXIHP0WREADY = 1'd0;
	assign SAXIHP1ARESETN = 1'd0;
	assign SAXIHP1ARREADY = 1'd0;
	assign SAXIHP1AWREADY = 1'd0;
	assign SAXIHP1BID = 6'd0;
	assign SAXIHP1BRESP = 2'd0;
	assign SAXIHP1BVALID = 1'd0;
	assign SAXIHP1RACOUNT = 3'd0;
	assign SAXIHP1RCOUNT = 8'd0;
	assign SAXIHP1RDATA = 64'd0;
	assign SAXIHP1RID = 6'd0;
	assign SAXIHP1RLAST = 1'd0;
	assign SAXIHP1RRESP = 2'd0;
	assign SAXIHP1RVALID = 1'd0;
	assign SAXIHP1WACOUNT = 6'd0;
	assign SAXIHP1WCOUNT = 8'd0;
	assign SAXIHP1WREADY = 1'd0;
endmodule

/* The DC's clocking and HDMI output (boards/zybo/lib): the ports and
 * parameters the tops use, names as Vivado 2026.1's unisims. */
module MMCME2_BASE #(
	parameter real CLKIN1_PERIOD = 0.000,
	parameter integer DIVCLK_DIVIDE = 1,
	parameter real CLKFBOUT_MULT_F = 5.000,
	parameter real CLKOUT0_DIVIDE_F = 1.000,
	parameter integer CLKOUT1_DIVIDE = 1
) (
	input wire CLKIN1,
	input wire CLKFBIN,
	input wire RST,
	input wire PWRDWN,
	output wire CLKFBOUT,
	output wire CLKFBOUTB,
	output wire CLKOUT0,
	output wire CLKOUT0B,
	output wire CLKOUT1,
	output wire CLKOUT1B,
	output wire CLKOUT2,
	output wire CLKOUT2B,
	output wire CLKOUT3,
	output wire CLKOUT3B,
	output wire CLKOUT4,
	output wire CLKOUT5,
	output wire CLKOUT6,
	output wire LOCKED
);
	assign CLKFBOUT = CLKIN1;
	assign CLKFBOUTB = 1'b0;
	assign CLKOUT0 = CLKIN1;
	assign CLKOUT0B = 1'b0;
	assign CLKOUT1 = CLKIN1;
	assign CLKOUT1B = 1'b0;
	assign CLKOUT2 = 1'b0;
	assign CLKOUT2B = 1'b0;
	assign CLKOUT3 = 1'b0;
	assign CLKOUT3B = 1'b0;
	assign CLKOUT4 = 1'b0;
	assign CLKOUT5 = 1'b0;
	assign CLKOUT6 = 1'b0;
	assign LOCKED = 1'b0;
endmodule

module PLLE2_BASE #(
	parameter real CLKIN1_PERIOD = 0.000,
	parameter integer DIVCLK_DIVIDE = 1,
	parameter integer CLKFBOUT_MULT = 5,
	parameter integer CLKOUT0_DIVIDE = 1,
	parameter integer CLKOUT1_DIVIDE = 1
) (
	input wire CLKIN1,
	input wire CLKFBIN,
	input wire RST,
	input wire PWRDWN,
	output wire CLKFBOUT,
	output wire CLKOUT0,
	output wire CLKOUT1,
	output wire CLKOUT2,
	output wire CLKOUT3,
	output wire CLKOUT4,
	output wire CLKOUT5,
	output wire LOCKED
);
	assign CLKFBOUT = CLKIN1;
	assign CLKOUT0 = CLKIN1;
	assign CLKOUT1 = CLKIN1;
	assign CLKOUT2 = 1'b0;
	assign CLKOUT3 = 1'b0;
	assign CLKOUT4 = 1'b0;
	assign CLKOUT5 = 1'b0;
	assign LOCKED = 1'b0;
endmodule

module BUFGMUX (
	input wire I0,
	input wire I1,
	input wire S,
	output wire O
);
	assign O = S ? I1 : I0;
endmodule

module OSERDESE2 #(
	parameter DATA_RATE_OQ = "DDR",
	parameter DATA_RATE_TQ = "DDR",
	parameter integer DATA_WIDTH = 4,
	parameter SERDES_MODE = "MASTER",
	parameter integer TRISTATE_WIDTH = 4
) (
	input wire CLK,
	input wire CLKDIV,
	input wire RST,
	input wire OCE,
	input wire D1,
	input wire D2,
	input wire D3,
	input wire D4,
	input wire D5,
	input wire D6,
	input wire D7,
	input wire D8,
	input wire SHIFTIN1,
	input wire SHIFTIN2,
	input wire T1,
	input wire T2,
	input wire T3,
	input wire T4,
	input wire TCE,
	input wire TBYTEIN,
	output wire OQ,
	output wire SHIFTOUT1,
	output wire SHIFTOUT2,
	output wire OFB,
	output wire TFB,
	output wire TQ,
	output wire TBYTEOUT
);
	assign OQ = 1'b0;
	assign SHIFTOUT1 = 1'b0;
	assign SHIFTOUT2 = 1'b0;
	assign OFB = 1'b0;
	assign TFB = 1'b0;
	assign TQ = 1'b0;
	assign TBYTEOUT = 1'b0;
endmodule

module OBUFDS (
	input wire I,
	output wire O,
	output wire OB
);
	assign O = I;
	assign OB = !I;
endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on DECLFILENAME */
/* verilator lint_on UNUSEDSIGNAL */

`default_nettype wire
