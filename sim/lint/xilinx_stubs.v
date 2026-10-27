/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * xilinx_stubs.v: lint-only stand-ins for the Xilinx primitives that the
 * board tops instantiate (tools/lint.sh uses them, nothing else does): the
 * ports the tops use, every output 0.  BUFG is I/O; PLLE2_BASE,
 * MMCME2_BASE and BUFGMUX (the clocking) have the ports and parameters the
 * tops use; IBUFDS, IBUFDS_GTE2, BSCANE2, ODDR and the KC705's IP cores
 * (boards/kc705/ip.tcl; the MIG by hand) likewise.
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

/* The clocking (boards/kc705/lib): the ports and parameters the tops use,
 * names as Vivado 2026.1's unisims. */
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

/* The KC705 (boards/kc705/lib): IBUFDS, BSCANE2 and ODDR as in Vivado
 * 2026.1's unisims (the ports the tops use), and the two IP cores that
 * TCL is to generate for atg_kc705_mig (port names from PG089 and PG164,
 * unverified until the cores exist). */
module IBUFDS (
	input wire I,
	input wire IB,
	output wire O
);
	assign O = I;
endmodule

module BSCANE2 #(
	parameter integer JTAG_CHAIN = 1
) (
	output wire CAPTURE,
	output wire DRCK,
	output wire RESET,
	output wire RUNTEST,
	output wire SEL,
	output wire SHIFT,
	output wire TCK,
	output wire TDI,
	output wire TMS,
	output wire UPDATE,
	input wire TDO
);
	assign CAPTURE = 1'b0;
	assign DRCK = 1'b0;
	assign RESET = 1'b0;
	assign RUNTEST = 1'b0;
	assign SEL = 1'b0;
	assign SHIFT = 1'b0;
	assign TCK = 1'b0;
	assign TDI = 1'b0;
	assign TMS = 1'b0;
	assign UPDATE = 1'b0;
endmodule

module ODDR #(
	parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
	parameter INIT = 1'b0,
	parameter SRTYPE = "SYNC"
) (
	output wire Q,
	input wire C,
	input wire CE,
	input wire D1,
	input wire D2,
	input wire R,
	input wire S
);
	assign Q = C ? D1 : D2;
endmodule

module DSP48E1 #(
	parameter integer ACASCREG = 1,
	parameter integer ADREG = 1,
	parameter integer ALUMODEREG = 1,
	parameter integer AREG = 1,
	parameter AUTORESET_PATDET = "NO_RESET",
	parameter A_INPUT = "DIRECT",
	parameter integer BCASCREG = 1,
	parameter integer BREG = 1,
	parameter B_INPUT = "DIRECT",
	parameter integer CARRYINREG = 1,
	parameter integer CARRYINSELREG = 1,
	parameter integer CREG = 1,
	parameter integer DREG = 1,
	parameter integer INMODEREG = 1,
	parameter [3:0] IS_ALUMODE_INVERTED = 4'b0000,
	parameter [0:0] IS_CARRYIN_INVERTED = 1'b0,
	parameter [0:0] IS_CLK_INVERTED = 1'b0,
	parameter [4:0] IS_INMODE_INVERTED = 5'b00000,
	parameter [6:0] IS_OPMODE_INVERTED = 7'b0000000,
	parameter [47:0] MASK = 48'h3FFFFFFFFFFF,
	parameter integer MREG = 1,
	parameter integer OPMODEREG = 1,
	parameter [47:0] PATTERN = 48'h000000000000,
	parameter integer PREG = 1,
	parameter SEL_MASK = "MASK",
	parameter SEL_PATTERN = "PATTERN",
	parameter USE_DPORT = "FALSE",
	parameter USE_MULT = "MULTIPLY",
	parameter USE_PATTERN_DETECT = "NO_PATDET",
	parameter USE_SIMD = "ONE48"
) (
	output wire [29:0] ACOUT,
	output wire [17:0] BCOUT,
	output wire CARRYCASCOUT,
	output wire [3:0] CARRYOUT,
	output wire MULTSIGNOUT,
	output wire OVERFLOW,
	output wire [47:0] P,
	output wire PATTERNBDETECT,
	output wire PATTERNDETECT,
	output wire [47:0] PCOUT,
	output wire UNDERFLOW,
	input wire [29:0] A,
	input wire [29:0] ACIN,
	input wire [3:0] ALUMODE,
	input wire [17:0] B,
	input wire [17:0] BCIN,
	input wire [47:0] C,
	input wire CARRYCASCIN,
	input wire CARRYIN,
	input wire [2:0] CARRYINSEL,
	input wire CEA1,
	input wire CEA2,
	input wire CEAD,
	input wire CEALUMODE,
	input wire CEB1,
	input wire CEB2,
	input wire CEC,
	input wire CECARRYIN,
	input wire CECTRL,
	input wire CED,
	input wire CEINMODE,
	input wire CEM,
	input wire CEP,
	input wire CLK,
	input wire [24:0] D,
	input wire [4:0] INMODE,
	input wire MULTSIGNIN,
	input wire [6:0] OPMODE,
	input wire [47:0] PCIN,
	input wire RSTA,
	input wire RSTALLCARRYIN,
	input wire RSTALUMODE,
	input wire RSTB,
	input wire RSTC,
	input wire RSTCTRL,
	input wire RSTD,
	input wire RSTINMODE,
	input wire RSTM,
	input wire RSTP
);
	assign ACOUT = 30'd0;
	assign BCOUT = 18'd0;
	assign CARRYCASCOUT = 1'b0;
	assign CARRYOUT = 4'd0;
	assign MULTSIGNOUT = 1'b0;
	assign OVERFLOW = 1'b0;
	assign P = 48'd0;
	assign PATTERNBDETECT = 1'b0;
	assign PATTERNDETECT = 1'b0;
	assign PCOUT = 48'd0;
	assign UNDERFLOW = 1'b0;
endmodule

/* The KC705 IP cores of boards/kc705/ip.tcl (ports as Vivado 2026.1 generates them). */
module atg_kc705_pcie_ip (
	input wire axi_aresetn,
	output wire user_link_up,
	output wire axi_aclk_out,
	output wire axi_ctl_aclk_out,
	output wire mmcm_lock,
	output wire interrupt_out,
	input wire INTX_MSI_Request,
	output wire INTX_MSI_Grant,
	output wire MSI_enable,
	input wire [4:0] MSI_Vector_Num,
	output wire [2:0] MSI_Vector_Width,
	input wire [3:0] s_axi_awid,
	input wire [31:0] s_axi_awaddr,
	input wire [3:0] s_axi_awregion,
	input wire [7:0] s_axi_awlen,
	input wire [2:0] s_axi_awsize,
	input wire [1:0] s_axi_awburst,
	input wire s_axi_awvalid,
	output wire s_axi_awready,
	input wire [127:0] s_axi_wdata,
	input wire [15:0] s_axi_wstrb,
	input wire s_axi_wlast,
	input wire s_axi_wvalid,
	output wire s_axi_wready,
	output wire [3:0] s_axi_bid,
	output wire [1:0] s_axi_bresp,
	output wire s_axi_bvalid,
	input wire s_axi_bready,
	input wire [3:0] s_axi_arid,
	input wire [31:0] s_axi_araddr,
	input wire [3:0] s_axi_arregion,
	input wire [7:0] s_axi_arlen,
	input wire [2:0] s_axi_arsize,
	input wire [1:0] s_axi_arburst,
	input wire s_axi_arvalid,
	output wire s_axi_arready,
	output wire [3:0] s_axi_rid,
	output wire [127:0] s_axi_rdata,
	output wire [1:0] s_axi_rresp,
	output wire s_axi_rlast,
	output wire s_axi_rvalid,
	input wire s_axi_rready,
	output wire [31:0] m_axi_awaddr,
	output wire [7:0] m_axi_awlen,
	output wire [2:0] m_axi_awsize,
	output wire [1:0] m_axi_awburst,
	output wire [2:0] m_axi_awprot,
	output wire m_axi_awvalid,
	input wire m_axi_awready,
	output wire m_axi_awlock,
	output wire [3:0] m_axi_awcache,
	output wire [127:0] m_axi_wdata,
	output wire [15:0] m_axi_wstrb,
	output wire m_axi_wlast,
	output wire m_axi_wvalid,
	input wire m_axi_wready,
	input wire [1:0] m_axi_bresp,
	input wire m_axi_bvalid,
	output wire m_axi_bready,
	output wire [31:0] m_axi_araddr,
	output wire [7:0] m_axi_arlen,
	output wire [2:0] m_axi_arsize,
	output wire [1:0] m_axi_arburst,
	output wire [2:0] m_axi_arprot,
	output wire m_axi_arvalid,
	input wire m_axi_arready,
	output wire m_axi_arlock,
	output wire [3:0] m_axi_arcache,
	input wire [127:0] m_axi_rdata,
	input wire [1:0] m_axi_rresp,
	input wire m_axi_rlast,
	input wire m_axi_rvalid,
	output wire m_axi_rready,
	output wire [3:0] pci_exp_txp,
	output wire [3:0] pci_exp_txn,
	input wire [3:0] pci_exp_rxp,
	input wire [3:0] pci_exp_rxn,
	input wire REFCLK,
	input wire [31:0] s_axi_ctl_awaddr,
	input wire s_axi_ctl_awvalid,
	output wire s_axi_ctl_awready,
	input wire [31:0] s_axi_ctl_wdata,
	input wire [3:0] s_axi_ctl_wstrb,
	input wire s_axi_ctl_wvalid,
	output wire s_axi_ctl_wready,
	output wire [1:0] s_axi_ctl_bresp,
	output wire s_axi_ctl_bvalid,
	input wire s_axi_ctl_bready,
	input wire [31:0] s_axi_ctl_araddr,
	input wire s_axi_ctl_arvalid,
	output wire s_axi_ctl_arready,
	output wire [31:0] s_axi_ctl_rdata,
	output wire [1:0] s_axi_ctl_rresp,
	output wire s_axi_ctl_rvalid,
	input wire s_axi_ctl_rready
);
	assign user_link_up = 0;
	assign axi_aclk_out = 0;
	assign axi_ctl_aclk_out = 0;
	assign mmcm_lock = 0;
	assign interrupt_out = 0;
	assign INTX_MSI_Grant = 0;
	assign MSI_enable = 0;
	assign MSI_Vector_Width = 0;
	assign s_axi_awready = 0;
	assign s_axi_wready = 0;
	assign s_axi_bid = 0;
	assign s_axi_bresp = 0;
	assign s_axi_bvalid = 0;
	assign s_axi_arready = 0;
	assign s_axi_rid = 0;
	assign s_axi_rdata = 0;
	assign s_axi_rresp = 0;
	assign s_axi_rlast = 0;
	assign s_axi_rvalid = 0;
	assign m_axi_awaddr = 0;
	assign m_axi_awlen = 0;
	assign m_axi_awsize = 0;
	assign m_axi_awburst = 0;
	assign m_axi_awprot = 0;
	assign m_axi_awvalid = 0;
	assign m_axi_awlock = 0;
	assign m_axi_awcache = 0;
	assign m_axi_wdata = 0;
	assign m_axi_wstrb = 0;
	assign m_axi_wlast = 0;
	assign m_axi_wvalid = 0;
	assign m_axi_bready = 0;
	assign m_axi_araddr = 0;
	assign m_axi_arlen = 0;
	assign m_axi_arsize = 0;
	assign m_axi_arburst = 0;
	assign m_axi_arprot = 0;
	assign m_axi_arvalid = 0;
	assign m_axi_arlock = 0;
	assign m_axi_arcache = 0;
	assign m_axi_rready = 0;
	assign pci_exp_txp = 0;
	assign pci_exp_txn = 0;
	assign s_axi_ctl_awready = 0;
	assign s_axi_ctl_wready = 0;
	assign s_axi_ctl_bresp = 0;
	assign s_axi_ctl_bvalid = 0;
	assign s_axi_ctl_arready = 0;
	assign s_axi_ctl_rdata = 0;
	assign s_axi_ctl_rresp = 0;
	assign s_axi_ctl_rvalid = 0;
endmodule

module atg_kc705_bar_xbar (
	input wire aclk,
	input wire aresetn,
	input wire [0:0] s_axi_awid,
	input wire [31:0] s_axi_awaddr,
	input wire [7:0] s_axi_awlen,
	input wire [2:0] s_axi_awsize,
	input wire [1:0] s_axi_awburst,
	input wire [0:0] s_axi_awlock,
	input wire [3:0] s_axi_awcache,
	input wire [2:0] s_axi_awprot,
	input wire [3:0] s_axi_awqos,
	input wire [0:0] s_axi_awvalid,
	output wire [0:0] s_axi_awready,
	input wire [127:0] s_axi_wdata,
	input wire [15:0] s_axi_wstrb,
	input wire [0:0] s_axi_wlast,
	input wire [0:0] s_axi_wvalid,
	output wire [0:0] s_axi_wready,
	output wire [0:0] s_axi_bid,
	output wire [1:0] s_axi_bresp,
	output wire [0:0] s_axi_bvalid,
	input wire [0:0] s_axi_bready,
	input wire [0:0] s_axi_arid,
	input wire [31:0] s_axi_araddr,
	input wire [7:0] s_axi_arlen,
	input wire [2:0] s_axi_arsize,
	input wire [1:0] s_axi_arburst,
	input wire [0:0] s_axi_arlock,
	input wire [3:0] s_axi_arcache,
	input wire [2:0] s_axi_arprot,
	input wire [3:0] s_axi_arqos,
	input wire [0:0] s_axi_arvalid,
	output wire [0:0] s_axi_arready,
	output wire [0:0] s_axi_rid,
	output wire [127:0] s_axi_rdata,
	output wire [1:0] s_axi_rresp,
	output wire [0:0] s_axi_rlast,
	output wire [0:0] s_axi_rvalid,
	input wire [0:0] s_axi_rready,
	output wire [1:0] m_axi_awid,
	output wire [63:0] m_axi_awaddr,
	output wire [15:0] m_axi_awlen,
	output wire [5:0] m_axi_awsize,
	output wire [3:0] m_axi_awburst,
	output wire [1:0] m_axi_awlock,
	output wire [7:0] m_axi_awcache,
	output wire [5:0] m_axi_awprot,
	output wire [7:0] m_axi_awregion,
	output wire [7:0] m_axi_awqos,
	output wire [1:0] m_axi_awvalid,
	input wire [1:0] m_axi_awready,
	output wire [255:0] m_axi_wdata,
	output wire [31:0] m_axi_wstrb,
	output wire [1:0] m_axi_wlast,
	output wire [1:0] m_axi_wvalid,
	input wire [1:0] m_axi_wready,
	input wire [1:0] m_axi_bid,
	input wire [3:0] m_axi_bresp,
	input wire [1:0] m_axi_bvalid,
	output wire [1:0] m_axi_bready,
	output wire [1:0] m_axi_arid,
	output wire [63:0] m_axi_araddr,
	output wire [15:0] m_axi_arlen,
	output wire [5:0] m_axi_arsize,
	output wire [3:0] m_axi_arburst,
	output wire [1:0] m_axi_arlock,
	output wire [7:0] m_axi_arcache,
	output wire [5:0] m_axi_arprot,
	output wire [7:0] m_axi_arregion,
	output wire [7:0] m_axi_arqos,
	output wire [1:0] m_axi_arvalid,
	input wire [1:0] m_axi_arready,
	input wire [1:0] m_axi_rid,
	input wire [255:0] m_axi_rdata,
	input wire [3:0] m_axi_rresp,
	input wire [1:0] m_axi_rlast,
	input wire [1:0] m_axi_rvalid,
	output wire [1:0] m_axi_rready
);
	assign s_axi_awready = 0;
	assign s_axi_wready = 0;
	assign s_axi_bid = 0;
	assign s_axi_bresp = 0;
	assign s_axi_bvalid = 0;
	assign s_axi_arready = 0;
	assign s_axi_rid = 0;
	assign s_axi_rdata = 0;
	assign s_axi_rresp = 0;
	assign s_axi_rlast = 0;
	assign s_axi_rvalid = 0;
	assign m_axi_awid = 0;
	assign m_axi_awaddr = 0;
	assign m_axi_awlen = 0;
	assign m_axi_awsize = 0;
	assign m_axi_awburst = 0;
	assign m_axi_awlock = 0;
	assign m_axi_awcache = 0;
	assign m_axi_awprot = 0;
	assign m_axi_awregion = 0;
	assign m_axi_awqos = 0;
	assign m_axi_awvalid = 0;
	assign m_axi_wdata = 0;
	assign m_axi_wstrb = 0;
	assign m_axi_wlast = 0;
	assign m_axi_wvalid = 0;
	assign m_axi_bready = 0;
	assign m_axi_arid = 0;
	assign m_axi_araddr = 0;
	assign m_axi_arlen = 0;
	assign m_axi_arsize = 0;
	assign m_axi_arburst = 0;
	assign m_axi_arlock = 0;
	assign m_axi_arcache = 0;
	assign m_axi_arprot = 0;
	assign m_axi_arregion = 0;
	assign m_axi_arqos = 0;
	assign m_axi_arvalid = 0;
	assign m_axi_rready = 0;
endmodule

module atg_kc705_bar0_dn (
	input wire s_axi_aclk,
	input wire s_axi_aresetn,
	input wire [0:0] s_axi_awid,
	input wire [31:0] s_axi_awaddr,
	input wire [7:0] s_axi_awlen,
	input wire [2:0] s_axi_awsize,
	input wire [1:0] s_axi_awburst,
	input wire [0:0] s_axi_awlock,
	input wire [3:0] s_axi_awcache,
	input wire [2:0] s_axi_awprot,
	input wire [3:0] s_axi_awregion,
	input wire [3:0] s_axi_awqos,
	input wire s_axi_awvalid,
	output wire s_axi_awready,
	input wire [127:0] s_axi_wdata,
	input wire [15:0] s_axi_wstrb,
	input wire s_axi_wlast,
	input wire s_axi_wvalid,
	output wire s_axi_wready,
	output wire [0:0] s_axi_bid,
	output wire [1:0] s_axi_bresp,
	output wire s_axi_bvalid,
	input wire s_axi_bready,
	input wire [0:0] s_axi_arid,
	input wire [31:0] s_axi_araddr,
	input wire [7:0] s_axi_arlen,
	input wire [2:0] s_axi_arsize,
	input wire [1:0] s_axi_arburst,
	input wire [0:0] s_axi_arlock,
	input wire [3:0] s_axi_arcache,
	input wire [2:0] s_axi_arprot,
	input wire [3:0] s_axi_arregion,
	input wire [3:0] s_axi_arqos,
	input wire s_axi_arvalid,
	output wire s_axi_arready,
	output wire [0:0] s_axi_rid,
	output wire [127:0] s_axi_rdata,
	output wire [1:0] s_axi_rresp,
	output wire s_axi_rlast,
	output wire s_axi_rvalid,
	input wire s_axi_rready,
	output wire [31:0] m_axi_awaddr,
	output wire [7:0] m_axi_awlen,
	output wire [2:0] m_axi_awsize,
	output wire [1:0] m_axi_awburst,
	output wire [0:0] m_axi_awlock,
	output wire [3:0] m_axi_awcache,
	output wire [2:0] m_axi_awprot,
	output wire [3:0] m_axi_awregion,
	output wire [3:0] m_axi_awqos,
	output wire m_axi_awvalid,
	input wire m_axi_awready,
	output wire [63:0] m_axi_wdata,
	output wire [7:0] m_axi_wstrb,
	output wire m_axi_wlast,
	output wire m_axi_wvalid,
	input wire m_axi_wready,
	input wire [1:0] m_axi_bresp,
	input wire m_axi_bvalid,
	output wire m_axi_bready,
	output wire [31:0] m_axi_araddr,
	output wire [7:0] m_axi_arlen,
	output wire [2:0] m_axi_arsize,
	output wire [1:0] m_axi_arburst,
	output wire [0:0] m_axi_arlock,
	output wire [3:0] m_axi_arcache,
	output wire [2:0] m_axi_arprot,
	output wire [3:0] m_axi_arregion,
	output wire [3:0] m_axi_arqos,
	output wire m_axi_arvalid,
	input wire m_axi_arready,
	input wire [63:0] m_axi_rdata,
	input wire [1:0] m_axi_rresp,
	input wire m_axi_rlast,
	input wire m_axi_rvalid,
	output wire m_axi_rready
);
	assign s_axi_awready = 0;
	assign s_axi_wready = 0;
	assign s_axi_bid = 0;
	assign s_axi_bresp = 0;
	assign s_axi_bvalid = 0;
	assign s_axi_arready = 0;
	assign s_axi_rid = 0;
	assign s_axi_rdata = 0;
	assign s_axi_rresp = 0;
	assign s_axi_rlast = 0;
	assign s_axi_rvalid = 0;
	assign m_axi_awaddr = 0;
	assign m_axi_awlen = 0;
	assign m_axi_awsize = 0;
	assign m_axi_awburst = 0;
	assign m_axi_awlock = 0;
	assign m_axi_awcache = 0;
	assign m_axi_awprot = 0;
	assign m_axi_awregion = 0;
	assign m_axi_awqos = 0;
	assign m_axi_awvalid = 0;
	assign m_axi_wdata = 0;
	assign m_axi_wstrb = 0;
	assign m_axi_wlast = 0;
	assign m_axi_wvalid = 0;
	assign m_axi_bready = 0;
	assign m_axi_araddr = 0;
	assign m_axi_arlen = 0;
	assign m_axi_arsize = 0;
	assign m_axi_arburst = 0;
	assign m_axi_arlock = 0;
	assign m_axi_arcache = 0;
	assign m_axi_arprot = 0;
	assign m_axi_arregion = 0;
	assign m_axi_arqos = 0;
	assign m_axi_arvalid = 0;
	assign m_axi_rready = 0;
endmodule

module atg_kc705_bar2_cc (
	input wire s_axi_aclk,
	input wire s_axi_aresetn,
	input wire [3:0] s_axi_awid,
	input wire [31:0] s_axi_awaddr,
	input wire [7:0] s_axi_awlen,
	input wire [2:0] s_axi_awsize,
	input wire [1:0] s_axi_awburst,
	input wire [0:0] s_axi_awlock,
	input wire [3:0] s_axi_awcache,
	input wire [2:0] s_axi_awprot,
	input wire [3:0] s_axi_awregion,
	input wire [3:0] s_axi_awqos,
	input wire s_axi_awvalid,
	output wire s_axi_awready,
	input wire [127:0] s_axi_wdata,
	input wire [15:0] s_axi_wstrb,
	input wire s_axi_wlast,
	input wire s_axi_wvalid,
	output wire s_axi_wready,
	output wire [3:0] s_axi_bid,
	output wire [1:0] s_axi_bresp,
	output wire s_axi_bvalid,
	input wire s_axi_bready,
	input wire [3:0] s_axi_arid,
	input wire [31:0] s_axi_araddr,
	input wire [7:0] s_axi_arlen,
	input wire [2:0] s_axi_arsize,
	input wire [1:0] s_axi_arburst,
	input wire [0:0] s_axi_arlock,
	input wire [3:0] s_axi_arcache,
	input wire [2:0] s_axi_arprot,
	input wire [3:0] s_axi_arregion,
	input wire [3:0] s_axi_arqos,
	input wire s_axi_arvalid,
	output wire s_axi_arready,
	output wire [3:0] s_axi_rid,
	output wire [127:0] s_axi_rdata,
	output wire [1:0] s_axi_rresp,
	output wire s_axi_rlast,
	output wire s_axi_rvalid,
	input wire s_axi_rready,
	input wire m_axi_aclk,
	input wire m_axi_aresetn,
	output wire [3:0] m_axi_awid,
	output wire [31:0] m_axi_awaddr,
	output wire [7:0] m_axi_awlen,
	output wire [2:0] m_axi_awsize,
	output wire [1:0] m_axi_awburst,
	output wire [0:0] m_axi_awlock,
	output wire [3:0] m_axi_awcache,
	output wire [2:0] m_axi_awprot,
	output wire [3:0] m_axi_awregion,
	output wire [3:0] m_axi_awqos,
	output wire m_axi_awvalid,
	input wire m_axi_awready,
	output wire [127:0] m_axi_wdata,
	output wire [15:0] m_axi_wstrb,
	output wire m_axi_wlast,
	output wire m_axi_wvalid,
	input wire m_axi_wready,
	input wire [3:0] m_axi_bid,
	input wire [1:0] m_axi_bresp,
	input wire m_axi_bvalid,
	output wire m_axi_bready,
	output wire [3:0] m_axi_arid,
	output wire [31:0] m_axi_araddr,
	output wire [7:0] m_axi_arlen,
	output wire [2:0] m_axi_arsize,
	output wire [1:0] m_axi_arburst,
	output wire [0:0] m_axi_arlock,
	output wire [3:0] m_axi_arcache,
	output wire [2:0] m_axi_arprot,
	output wire [3:0] m_axi_arregion,
	output wire [3:0] m_axi_arqos,
	output wire m_axi_arvalid,
	input wire m_axi_arready,
	input wire [3:0] m_axi_rid,
	input wire [127:0] m_axi_rdata,
	input wire [1:0] m_axi_rresp,
	input wire m_axi_rlast,
	input wire m_axi_rvalid,
	output wire m_axi_rready
);
	assign s_axi_awready = 0;
	assign s_axi_wready = 0;
	assign s_axi_bid = 0;
	assign s_axi_bresp = 0;
	assign s_axi_bvalid = 0;
	assign s_axi_arready = 0;
	assign s_axi_rid = 0;
	assign s_axi_rdata = 0;
	assign s_axi_rresp = 0;
	assign s_axi_rlast = 0;
	assign s_axi_rvalid = 0;
	assign m_axi_awid = 0;
	assign m_axi_awaddr = 0;
	assign m_axi_awlen = 0;
	assign m_axi_awsize = 0;
	assign m_axi_awburst = 0;
	assign m_axi_awlock = 0;
	assign m_axi_awcache = 0;
	assign m_axi_awprot = 0;
	assign m_axi_awregion = 0;
	assign m_axi_awqos = 0;
	assign m_axi_awvalid = 0;
	assign m_axi_wdata = 0;
	assign m_axi_wstrb = 0;
	assign m_axi_wlast = 0;
	assign m_axi_wvalid = 0;
	assign m_axi_bready = 0;
	assign m_axi_arid = 0;
	assign m_axi_araddr = 0;
	assign m_axi_arlen = 0;
	assign m_axi_arsize = 0;
	assign m_axi_arburst = 0;
	assign m_axi_arlock = 0;
	assign m_axi_arcache = 0;
	assign m_axi_arprot = 0;
	assign m_axi_arregion = 0;
	assign m_axi_arqos = 0;
	assign m_axi_arvalid = 0;
	assign m_axi_rready = 0;
endmodule

module atg_kc705_host_dn (
	input wire s_axi_aclk,
	input wire s_axi_aresetn,
	input wire [3:0] s_axi_awid,
	input wire [31:0] s_axi_awaddr,
	input wire [7:0] s_axi_awlen,
	input wire [2:0] s_axi_awsize,
	input wire [1:0] s_axi_awburst,
	input wire [0:0] s_axi_awlock,
	input wire [3:0] s_axi_awcache,
	input wire [2:0] s_axi_awprot,
	input wire [3:0] s_axi_awregion,
	input wire [3:0] s_axi_awqos,
	input wire s_axi_awvalid,
	output wire s_axi_awready,
	input wire [511:0] s_axi_wdata,
	input wire [63:0] s_axi_wstrb,
	input wire s_axi_wlast,
	input wire s_axi_wvalid,
	output wire s_axi_wready,
	output wire [3:0] s_axi_bid,
	output wire [1:0] s_axi_bresp,
	output wire s_axi_bvalid,
	input wire s_axi_bready,
	input wire [3:0] s_axi_arid,
	input wire [31:0] s_axi_araddr,
	input wire [7:0] s_axi_arlen,
	input wire [2:0] s_axi_arsize,
	input wire [1:0] s_axi_arburst,
	input wire [0:0] s_axi_arlock,
	input wire [3:0] s_axi_arcache,
	input wire [2:0] s_axi_arprot,
	input wire [3:0] s_axi_arregion,
	input wire [3:0] s_axi_arqos,
	input wire s_axi_arvalid,
	output wire s_axi_arready,
	output wire [3:0] s_axi_rid,
	output wire [511:0] s_axi_rdata,
	output wire [1:0] s_axi_rresp,
	output wire s_axi_rlast,
	output wire s_axi_rvalid,
	input wire s_axi_rready,
	output wire [31:0] m_axi_awaddr,
	output wire [7:0] m_axi_awlen,
	output wire [2:0] m_axi_awsize,
	output wire [1:0] m_axi_awburst,
	output wire [0:0] m_axi_awlock,
	output wire [3:0] m_axi_awcache,
	output wire [2:0] m_axi_awprot,
	output wire [3:0] m_axi_awregion,
	output wire [3:0] m_axi_awqos,
	output wire m_axi_awvalid,
	input wire m_axi_awready,
	output wire [127:0] m_axi_wdata,
	output wire [15:0] m_axi_wstrb,
	output wire m_axi_wlast,
	output wire m_axi_wvalid,
	input wire m_axi_wready,
	input wire [1:0] m_axi_bresp,
	input wire m_axi_bvalid,
	output wire m_axi_bready,
	output wire [31:0] m_axi_araddr,
	output wire [7:0] m_axi_arlen,
	output wire [2:0] m_axi_arsize,
	output wire [1:0] m_axi_arburst,
	output wire [0:0] m_axi_arlock,
	output wire [3:0] m_axi_arcache,
	output wire [2:0] m_axi_arprot,
	output wire [3:0] m_axi_arregion,
	output wire [3:0] m_axi_arqos,
	output wire m_axi_arvalid,
	input wire m_axi_arready,
	input wire [127:0] m_axi_rdata,
	input wire [1:0] m_axi_rresp,
	input wire m_axi_rlast,
	input wire m_axi_rvalid,
	output wire m_axi_rready
);
	assign s_axi_awready = 0;
	assign s_axi_wready = 0;
	assign s_axi_bid = 0;
	assign s_axi_bresp = 0;
	assign s_axi_bvalid = 0;
	assign s_axi_arready = 0;
	assign s_axi_rid = 0;
	assign s_axi_rdata = 0;
	assign s_axi_rresp = 0;
	assign s_axi_rlast = 0;
	assign s_axi_rvalid = 0;
	assign m_axi_awaddr = 0;
	assign m_axi_awlen = 0;
	assign m_axi_awsize = 0;
	assign m_axi_awburst = 0;
	assign m_axi_awlock = 0;
	assign m_axi_awcache = 0;
	assign m_axi_awprot = 0;
	assign m_axi_awregion = 0;
	assign m_axi_awqos = 0;
	assign m_axi_awvalid = 0;
	assign m_axi_wdata = 0;
	assign m_axi_wstrb = 0;
	assign m_axi_wlast = 0;
	assign m_axi_wvalid = 0;
	assign m_axi_bready = 0;
	assign m_axi_araddr = 0;
	assign m_axi_arlen = 0;
	assign m_axi_arsize = 0;
	assign m_axi_arburst = 0;
	assign m_axi_arlock = 0;
	assign m_axi_arcache = 0;
	assign m_axi_arprot = 0;
	assign m_axi_arregion = 0;
	assign m_axi_arqos = 0;
	assign m_axi_arvalid = 0;
	assign m_axi_rready = 0;
endmodule

module atg_kc705_bar2_up (
	input wire s_axi_aclk,
	input wire s_axi_aresetn,
	input wire [3:0] s_axi_awid,
	input wire [31:0] s_axi_awaddr,
	input wire [7:0] s_axi_awlen,
	input wire [2:0] s_axi_awsize,
	input wire [1:0] s_axi_awburst,
	input wire [0:0] s_axi_awlock,
	input wire [3:0] s_axi_awcache,
	input wire [2:0] s_axi_awprot,
	input wire [3:0] s_axi_awregion,
	input wire [3:0] s_axi_awqos,
	input wire s_axi_awvalid,
	output wire s_axi_awready,
	input wire [127:0] s_axi_wdata,
	input wire [15:0] s_axi_wstrb,
	input wire s_axi_wlast,
	input wire s_axi_wvalid,
	output wire s_axi_wready,
	output wire [3:0] s_axi_bid,
	output wire [1:0] s_axi_bresp,
	output wire s_axi_bvalid,
	input wire s_axi_bready,
	input wire [3:0] s_axi_arid,
	input wire [31:0] s_axi_araddr,
	input wire [7:0] s_axi_arlen,
	input wire [2:0] s_axi_arsize,
	input wire [1:0] s_axi_arburst,
	input wire [0:0] s_axi_arlock,
	input wire [3:0] s_axi_arcache,
	input wire [2:0] s_axi_arprot,
	input wire [3:0] s_axi_arregion,
	input wire [3:0] s_axi_arqos,
	input wire s_axi_arvalid,
	output wire s_axi_arready,
	output wire [3:0] s_axi_rid,
	output wire [127:0] s_axi_rdata,
	output wire [1:0] s_axi_rresp,
	output wire s_axi_rlast,
	output wire s_axi_rvalid,
	input wire s_axi_rready,
	output wire [31:0] m_axi_awaddr,
	output wire [7:0] m_axi_awlen,
	output wire [2:0] m_axi_awsize,
	output wire [1:0] m_axi_awburst,
	output wire [0:0] m_axi_awlock,
	output wire [3:0] m_axi_awcache,
	output wire [2:0] m_axi_awprot,
	output wire [3:0] m_axi_awregion,
	output wire [3:0] m_axi_awqos,
	output wire m_axi_awvalid,
	input wire m_axi_awready,
	output wire [511:0] m_axi_wdata,
	output wire [63:0] m_axi_wstrb,
	output wire m_axi_wlast,
	output wire m_axi_wvalid,
	input wire m_axi_wready,
	input wire [1:0] m_axi_bresp,
	input wire m_axi_bvalid,
	output wire m_axi_bready,
	output wire [31:0] m_axi_araddr,
	output wire [7:0] m_axi_arlen,
	output wire [2:0] m_axi_arsize,
	output wire [1:0] m_axi_arburst,
	output wire [0:0] m_axi_arlock,
	output wire [3:0] m_axi_arcache,
	output wire [2:0] m_axi_arprot,
	output wire [3:0] m_axi_arregion,
	output wire [3:0] m_axi_arqos,
	output wire m_axi_arvalid,
	input wire m_axi_arready,
	input wire [511:0] m_axi_rdata,
	input wire [1:0] m_axi_rresp,
	input wire m_axi_rlast,
	input wire m_axi_rvalid,
	output wire m_axi_rready
);
	assign s_axi_awready = 0;
	assign s_axi_wready = 0;
	assign s_axi_bid = 0;
	assign s_axi_bresp = 0;
	assign s_axi_bvalid = 0;
	assign s_axi_arready = 0;
	assign s_axi_rid = 0;
	assign s_axi_rdata = 0;
	assign s_axi_rresp = 0;
	assign s_axi_rlast = 0;
	assign s_axi_rvalid = 0;
	assign m_axi_awaddr = 0;
	assign m_axi_awlen = 0;
	assign m_axi_awsize = 0;
	assign m_axi_awburst = 0;
	assign m_axi_awlock = 0;
	assign m_axi_awcache = 0;
	assign m_axi_awprot = 0;
	assign m_axi_awregion = 0;
	assign m_axi_awqos = 0;
	assign m_axi_awvalid = 0;
	assign m_axi_wdata = 0;
	assign m_axi_wstrb = 0;
	assign m_axi_wlast = 0;
	assign m_axi_wvalid = 0;
	assign m_axi_bready = 0;
	assign m_axi_araddr = 0;
	assign m_axi_arlen = 0;
	assign m_axi_arsize = 0;
	assign m_axi_arburst = 0;
	assign m_axi_arlock = 0;
	assign m_axi_arcache = 0;
	assign m_axi_arprot = 0;
	assign m_axi_arregion = 0;
	assign m_axi_arqos = 0;
	assign m_axi_arvalid = 0;
	assign m_axi_rready = 0;
endmodule

module atg_kc705_mem_xbar (
	input wire aclk,
	input wire aresetn,
	input wire [1:0] s_axi_awid,
	input wire [63:0] s_axi_awaddr,
	input wire [15:0] s_axi_awlen,
	input wire [5:0] s_axi_awsize,
	input wire [3:0] s_axi_awburst,
	input wire [1:0] s_axi_awlock,
	input wire [7:0] s_axi_awcache,
	input wire [5:0] s_axi_awprot,
	input wire [7:0] s_axi_awqos,
	input wire [1:0] s_axi_awvalid,
	output wire [1:0] s_axi_awready,
	input wire [1023:0] s_axi_wdata,
	input wire [127:0] s_axi_wstrb,
	input wire [1:0] s_axi_wlast,
	input wire [1:0] s_axi_wvalid,
	output wire [1:0] s_axi_wready,
	output wire [1:0] s_axi_bid,
	output wire [3:0] s_axi_bresp,
	output wire [1:0] s_axi_bvalid,
	input wire [1:0] s_axi_bready,
	input wire [1:0] s_axi_arid,
	input wire [63:0] s_axi_araddr,
	input wire [15:0] s_axi_arlen,
	input wire [5:0] s_axi_arsize,
	input wire [3:0] s_axi_arburst,
	input wire [1:0] s_axi_arlock,
	input wire [7:0] s_axi_arcache,
	input wire [5:0] s_axi_arprot,
	input wire [7:0] s_axi_arqos,
	input wire [1:0] s_axi_arvalid,
	output wire [1:0] s_axi_arready,
	output wire [1:0] s_axi_rid,
	output wire [1023:0] s_axi_rdata,
	output wire [3:0] s_axi_rresp,
	output wire [1:0] s_axi_rlast,
	output wire [1:0] s_axi_rvalid,
	input wire [1:0] s_axi_rready,
	output wire [0:0] m_axi_awid,
	output wire [31:0] m_axi_awaddr,
	output wire [7:0] m_axi_awlen,
	output wire [2:0] m_axi_awsize,
	output wire [1:0] m_axi_awburst,
	output wire [0:0] m_axi_awlock,
	output wire [3:0] m_axi_awcache,
	output wire [2:0] m_axi_awprot,
	output wire [3:0] m_axi_awregion,
	output wire [3:0] m_axi_awqos,
	output wire [0:0] m_axi_awvalid,
	input wire [0:0] m_axi_awready,
	output wire [511:0] m_axi_wdata,
	output wire [63:0] m_axi_wstrb,
	output wire [0:0] m_axi_wlast,
	output wire [0:0] m_axi_wvalid,
	input wire [0:0] m_axi_wready,
	input wire [0:0] m_axi_bid,
	input wire [1:0] m_axi_bresp,
	input wire [0:0] m_axi_bvalid,
	output wire [0:0] m_axi_bready,
	output wire [0:0] m_axi_arid,
	output wire [31:0] m_axi_araddr,
	output wire [7:0] m_axi_arlen,
	output wire [2:0] m_axi_arsize,
	output wire [1:0] m_axi_arburst,
	output wire [0:0] m_axi_arlock,
	output wire [3:0] m_axi_arcache,
	output wire [2:0] m_axi_arprot,
	output wire [3:0] m_axi_arregion,
	output wire [3:0] m_axi_arqos,
	output wire [0:0] m_axi_arvalid,
	input wire [0:0] m_axi_arready,
	input wire [0:0] m_axi_rid,
	input wire [511:0] m_axi_rdata,
	input wire [1:0] m_axi_rresp,
	input wire [0:0] m_axi_rlast,
	input wire [0:0] m_axi_rvalid,
	output wire [0:0] m_axi_rready
);
	assign s_axi_awready = 0;
	assign s_axi_wready = 0;
	assign s_axi_bid = 0;
	assign s_axi_bresp = 0;
	assign s_axi_bvalid = 0;
	assign s_axi_arready = 0;
	assign s_axi_rid = 0;
	assign s_axi_rdata = 0;
	assign s_axi_rresp = 0;
	assign s_axi_rlast = 0;
	assign s_axi_rvalid = 0;
	assign m_axi_awid = 0;
	assign m_axi_awaddr = 0;
	assign m_axi_awlen = 0;
	assign m_axi_awsize = 0;
	assign m_axi_awburst = 0;
	assign m_axi_awlock = 0;
	assign m_axi_awcache = 0;
	assign m_axi_awprot = 0;
	assign m_axi_awregion = 0;
	assign m_axi_awqos = 0;
	assign m_axi_awvalid = 0;
	assign m_axi_wdata = 0;
	assign m_axi_wstrb = 0;
	assign m_axi_wlast = 0;
	assign m_axi_wvalid = 0;
	assign m_axi_bready = 0;
	assign m_axi_arid = 0;
	assign m_axi_araddr = 0;
	assign m_axi_arlen = 0;
	assign m_axi_arsize = 0;
	assign m_axi_arburst = 0;
	assign m_axi_arlock = 0;
	assign m_axi_arcache = 0;
	assign m_axi_arprot = 0;
	assign m_axi_arregion = 0;
	assign m_axi_arqos = 0;
	assign m_axi_arvalid = 0;
	assign m_axi_rready = 0;
endmodule

module atg_kc705_axi_cc (
	input wire s_axi_aclk,
	input wire s_axi_aresetn,
	input wire [0:0] s_axi_awid,
	input wire [31:0] s_axi_awaddr,
	input wire [7:0] s_axi_awlen,
	input wire [2:0] s_axi_awsize,
	input wire [1:0] s_axi_awburst,
	input wire [0:0] s_axi_awlock,
	input wire [3:0] s_axi_awcache,
	input wire [2:0] s_axi_awprot,
	input wire [3:0] s_axi_awregion,
	input wire [3:0] s_axi_awqos,
	input wire s_axi_awvalid,
	output wire s_axi_awready,
	input wire [511:0] s_axi_wdata,
	input wire [63:0] s_axi_wstrb,
	input wire s_axi_wlast,
	input wire s_axi_wvalid,
	output wire s_axi_wready,
	output wire [0:0] s_axi_bid,
	output wire [1:0] s_axi_bresp,
	output wire s_axi_bvalid,
	input wire s_axi_bready,
	input wire [0:0] s_axi_arid,
	input wire [31:0] s_axi_araddr,
	input wire [7:0] s_axi_arlen,
	input wire [2:0] s_axi_arsize,
	input wire [1:0] s_axi_arburst,
	input wire [0:0] s_axi_arlock,
	input wire [3:0] s_axi_arcache,
	input wire [2:0] s_axi_arprot,
	input wire [3:0] s_axi_arregion,
	input wire [3:0] s_axi_arqos,
	input wire s_axi_arvalid,
	output wire s_axi_arready,
	output wire [0:0] s_axi_rid,
	output wire [511:0] s_axi_rdata,
	output wire [1:0] s_axi_rresp,
	output wire s_axi_rlast,
	output wire s_axi_rvalid,
	input wire s_axi_rready,
	input wire m_axi_aclk,
	input wire m_axi_aresetn,
	output wire [0:0] m_axi_awid,
	output wire [31:0] m_axi_awaddr,
	output wire [7:0] m_axi_awlen,
	output wire [2:0] m_axi_awsize,
	output wire [1:0] m_axi_awburst,
	output wire [0:0] m_axi_awlock,
	output wire [3:0] m_axi_awcache,
	output wire [2:0] m_axi_awprot,
	output wire [3:0] m_axi_awregion,
	output wire [3:0] m_axi_awqos,
	output wire m_axi_awvalid,
	input wire m_axi_awready,
	output wire [511:0] m_axi_wdata,
	output wire [63:0] m_axi_wstrb,
	output wire m_axi_wlast,
	output wire m_axi_wvalid,
	input wire m_axi_wready,
	input wire [0:0] m_axi_bid,
	input wire [1:0] m_axi_bresp,
	input wire m_axi_bvalid,
	output wire m_axi_bready,
	output wire [0:0] m_axi_arid,
	output wire [31:0] m_axi_araddr,
	output wire [7:0] m_axi_arlen,
	output wire [2:0] m_axi_arsize,
	output wire [1:0] m_axi_arburst,
	output wire [0:0] m_axi_arlock,
	output wire [3:0] m_axi_arcache,
	output wire [2:0] m_axi_arprot,
	output wire [3:0] m_axi_arregion,
	output wire [3:0] m_axi_arqos,
	output wire m_axi_arvalid,
	input wire m_axi_arready,
	input wire [0:0] m_axi_rid,
	input wire [511:0] m_axi_rdata,
	input wire [1:0] m_axi_rresp,
	input wire m_axi_rlast,
	input wire m_axi_rvalid,
	output wire m_axi_rready
);
	assign s_axi_awready = 0;
	assign s_axi_wready = 0;
	assign s_axi_bid = 0;
	assign s_axi_bresp = 0;
	assign s_axi_bvalid = 0;
	assign s_axi_arready = 0;
	assign s_axi_rid = 0;
	assign s_axi_rdata = 0;
	assign s_axi_rresp = 0;
	assign s_axi_rlast = 0;
	assign s_axi_rvalid = 0;
	assign m_axi_awid = 0;
	assign m_axi_awaddr = 0;
	assign m_axi_awlen = 0;
	assign m_axi_awsize = 0;
	assign m_axi_awburst = 0;
	assign m_axi_awlock = 0;
	assign m_axi_awcache = 0;
	assign m_axi_awprot = 0;
	assign m_axi_awregion = 0;
	assign m_axi_awqos = 0;
	assign m_axi_awvalid = 0;
	assign m_axi_wdata = 0;
	assign m_axi_wstrb = 0;
	assign m_axi_wlast = 0;
	assign m_axi_wvalid = 0;
	assign m_axi_bready = 0;
	assign m_axi_arid = 0;
	assign m_axi_araddr = 0;
	assign m_axi_arlen = 0;
	assign m_axi_arsize = 0;
	assign m_axi_arburst = 0;
	assign m_axi_arlock = 0;
	assign m_axi_arcache = 0;
	assign m_axi_arprot = 0;
	assign m_axi_arregion = 0;
	assign m_axi_arqos = 0;
	assign m_axi_arvalid = 0;
	assign m_axi_rready = 0;
endmodule

module IBUFDS_GTE2 (
	input wire I,
	input wire IB,
	input wire CEB,
	output wire O,
	output wire ODIV2
);
	assign O = I;
	assign ODIV2 = I;
endmodule

module atg_kc705_ddr3 (
	inout wire [63:0] ddr3_dq,
	inout wire [7:0] ddr3_dqs_n,
	inout wire [7:0] ddr3_dqs_p,
	output wire [13:0] ddr3_addr,
	output wire [2:0] ddr3_ba,
	output wire ddr3_ras_n,
	output wire ddr3_cas_n,
	output wire ddr3_we_n,
	output wire ddr3_reset_n,
	output wire [0:0] ddr3_ck_p,
	output wire [0:0] ddr3_ck_n,
	output wire [0:0] ddr3_cke,
	output wire [0:0] ddr3_cs_n,
	output wire [7:0] ddr3_dm,
	output wire [0:0] ddr3_odt,
	input wire sys_clk_i,
	input wire clk_ref_i,
	input wire sys_rst,
	output wire ui_clk,
	output wire ui_clk_sync_rst,
	output wire mmcm_locked,
	input wire aresetn,
	input wire app_sr_req,
	input wire app_ref_req,
	input wire app_zq_req,
	output wire app_sr_active,
	output wire app_ref_ack,
	output wire app_zq_ack,
	output wire init_calib_complete,
	output wire [11:0] device_temp,
	output wire [119:0] ddr3_ila_basic,
	output wire [1023:0] ddr3_ila_rdpath,
	output wire [390:0] ddr3_ila_wrpath,
	input wire [13:0] ddr3_vio_sync_out,
	input wire [3:0] dbg_byte_sel,
	input wire dbg_sel_pi_incdec,
	input wire dbg_pi_f_inc,
	input wire dbg_pi_f_dec,
	input wire dbg_sel_po_incdec,
	input wire dbg_po_f_inc,
	input wire dbg_po_f_dec,
	input wire dbg_po_f_stg23_sel,
	output wire [5:0] dbg_pi_counter_read_val,
	output wire [8:0] dbg_po_counter_read_val,
	output wire [107:0] dbg_prbs_final_dqs_tap_cnt_r,
	output wire [107:0] dbg_prbs_first_edge_taps,
	output wire [107:0] dbg_prbs_second_edge_taps,
	input wire [3:0] s_axi_awid,
	input wire [29:0] s_axi_awaddr,
	input wire [7:0] s_axi_awlen,
	input wire [2:0] s_axi_awsize,
	input wire [1:0] s_axi_awburst,
	input wire [0:0] s_axi_awlock,
	input wire [3:0] s_axi_awcache,
	input wire [2:0] s_axi_awprot,
	input wire [3:0] s_axi_awqos,
	input wire s_axi_awvalid,
	output wire s_axi_awready,
	input wire [511:0] s_axi_wdata,
	input wire [63:0] s_axi_wstrb,
	input wire s_axi_wlast,
	input wire s_axi_wvalid,
	output wire s_axi_wready,
	input wire s_axi_bready,
	output wire [3:0] s_axi_bid,
	output wire [1:0] s_axi_bresp,
	output wire s_axi_bvalid,
	input wire [3:0] s_axi_arid,
	input wire [29:0] s_axi_araddr,
	input wire [7:0] s_axi_arlen,
	input wire [2:0] s_axi_arsize,
	input wire [1:0] s_axi_arburst,
	input wire [0:0] s_axi_arlock,
	input wire [3:0] s_axi_arcache,
	input wire [2:0] s_axi_arprot,
	input wire [3:0] s_axi_arqos,
	input wire s_axi_arvalid,
	output wire s_axi_arready,
	input wire s_axi_rready,
	output wire [3:0] s_axi_rid,
	output wire [511:0] s_axi_rdata,
	output wire [1:0] s_axi_rresp,
	output wire s_axi_rlast,
	output wire s_axi_rvalid
);
	assign ddr3_dq = {64{1'bz}};
	assign ddr3_dqs_n = {8{1'bz}};
	assign ddr3_dqs_p = {8{1'bz}};
	assign ddr3_addr = 14'd0;
	assign ddr3_ba = 3'd0;
	assign ddr3_ras_n = 1'b1;
	assign ddr3_cas_n = 1'b1;
	assign ddr3_we_n = 1'b1;
	assign ddr3_reset_n = 1'b0;
	assign ddr3_ck_p = 1'b0;
	assign ddr3_ck_n = 1'b1;
	assign ddr3_cke = 1'b0;
	assign ddr3_cs_n = 1'b1;
	assign ddr3_dm = 8'd0;
	assign ddr3_odt = 1'b0;
	assign ui_clk = sys_clk_i;
	assign ui_clk_sync_rst = 1'b0;
	assign mmcm_locked = 1'b0;
	assign app_sr_active = 1'b0;
	assign app_ref_ack = 1'b0;
	assign app_zq_ack = 1'b0;
	assign init_calib_complete = 1'b0;
	assign device_temp = 12'd0;
	assign ddr3_ila_basic = 120'd0;
	assign ddr3_ila_rdpath = 1024'd0;
	assign ddr3_ila_wrpath = 391'd0;
	assign dbg_pi_counter_read_val = 6'd0;
	assign dbg_po_counter_read_val = 9'd0;
	assign dbg_prbs_final_dqs_tap_cnt_r = 108'd0;
	assign dbg_prbs_first_edge_taps = 108'd0;
	assign dbg_prbs_second_edge_taps = 108'd0;
	assign s_axi_awready = 1'b0;
	assign s_axi_wready = 1'b0;
	assign s_axi_bid = 4'd0;
	assign s_axi_bresp = 2'd0;
	assign s_axi_bvalid = 1'b0;
	assign s_axi_arready = 1'b0;
	assign s_axi_rid = 4'd0;
	assign s_axi_rdata = 512'd0;
	assign s_axi_rresp = 2'd0;
	assign s_axi_rlast = 1'b0;
	assign s_axi_rvalid = 1'b0;
endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on DECLFILENAME */
/* verilator lint_on UNUSEDSIGNAL */

`default_nettype wire
