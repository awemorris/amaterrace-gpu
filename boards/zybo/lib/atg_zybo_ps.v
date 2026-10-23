/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_zybo_ps: The ZYBO's PS7 shell shared by the per-block bitstreams:
 * FCLK_CLK0 through a BUFG as the single clock, its reset synchronised,
 * M_AXI_GP0 (the GHCI window) and one HP port (HP0 or HP1) as AXI ports,
 * IRQ_F2P[0].
 *
 * Wiring of its children (WS288 p023); see spec/boards/zybo/lib/atg_zybo_ps.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_zybo_ps #(
	parameter HP = 0	/* 0: S_AXI_HP0 (the GPU), 1: S_AXI_HP1 (the DC, design §4.2) */
) (
	output wire clk,
	output wire rst_n,
	input wire irq,
	/* M_AXI_GP0 (AXI3 master of the PS) */
	output wire [31:0] s_awaddr,
	output wire [11:0] s_awid,
	output wire s_awvalid,
	input wire s_awready,
	output wire [31:0] s_wdata,
	output wire [3:0] s_wstrb,
	output wire s_wlast,
	output wire s_wvalid,
	input wire s_wready,
	input wire [11:0] s_bid,
	input wire [1:0] s_bresp,
	input wire s_bvalid,
	output wire s_bready,
	output wire [31:0] s_araddr,
	output wire [11:0] s_arid,
	output wire [3:0] s_arlen,
	output wire s_arvalid,
	input wire s_arready,
	input wire [31:0] s_rdata,
	input wire [11:0] s_rid,
	input wire [1:0] s_rresp,
	input wire s_rlast,
	input wire s_rvalid,
	output wire s_rready,
	/* S_AXI_HP0 or HP1 (AXI3 slave of the PS, AXI4-shaped here: the low bits of LEN/SIZE are used) */
	input wire [31:0] m_awaddr,
	input wire [7:0] m_awlen,
	input wire [2:0] m_awsize,
	input wire [1:0] m_awburst,
	input wire [3:0] m_awcache,
	input wire [2:0] m_awprot,
	input wire m_awvalid,
	output wire m_awready,
	input wire [63:0] m_wdata,
	input wire [7:0] m_wstrb,
	input wire m_wlast,
	input wire m_wvalid,
	output wire m_wready,
	output wire [1:0] m_bresp,
	output wire m_bvalid,
	input wire m_bready,
	input wire [31:0] m_araddr,
	input wire [7:0] m_arlen,
	input wire [2:0] m_arsize,
	input wire [1:0] m_arburst,
	input wire [3:0] m_arcache,
	input wire [2:0] m_arprot,
	input wire m_arvalid,
	output wire m_arready,
	output wire [63:0] m_rdata,
	output wire [1:0] m_rresp,
	output wire m_rlast,
	output wire m_rvalid,
	input wire m_rready
);
	wire [3:0] fclk;
	wire [3:0] fclk_resetn;
	BUFG fclk0_bufg (.I(fclk[0]), .O(clk));

	/* FCLK_RESET0_N comes from the PS's domain: take it in twice. */
	(* ASYNC_REG = "TRUE" *) reg [1:0] rst_sync = 2'b00;
	assign rst_n = rst_sync[1];

	always @(posedge clk)
		rst_sync <= {rst_sync[0], fclk_resetn[0]};

	/* The GP0 master (the GHCI window 0x43C00000). */
	wire [31:0] gp_awaddr;
	wire [11:0] gp_awid;
	wire gp_awvalid;
	wire gp_awready;
	wire [31:0] gp_wdata;
	wire [3:0] gp_wstrb;
	wire gp_wlast;
	wire gp_wvalid;
	wire gp_wready;
	wire [11:0] gp_bid;
	wire [1:0] gp_bresp;
	wire gp_bvalid;
	wire gp_bready;
	wire [31:0] gp_araddr;
	wire [11:0] gp_arid;
	wire [3:0] gp_arlen;
	wire gp_arvalid;
	wire gp_arready;
	wire [31:0] gp_rdata;
	wire [11:0] gp_rid;
	wire [1:0] gp_rresp;
	wire gp_rlast;
	wire gp_rvalid;
	wire gp_rready;
	assign s_awaddr = gp_awaddr;
	assign s_awid = gp_awid;
	assign s_awvalid = gp_awvalid;
	assign s_wdata = gp_wdata;
	assign s_wstrb = gp_wstrb;
	assign s_wlast = gp_wlast;
	assign s_wvalid = gp_wvalid;
	assign s_bready = gp_bready;
	assign s_araddr = gp_araddr;
	assign s_arid = gp_arid;
	assign s_arlen = gp_arlen;
	assign s_arvalid = gp_arvalid;
	assign s_rready = gp_rready;
	assign gp_awready = s_awready;
	assign gp_wready = s_wready;
	assign gp_bid = s_bid;
	assign gp_bresp = s_bresp;
	assign gp_bvalid = s_bvalid;
	assign gp_arready = s_arready;
	assign gp_rdata = s_rdata;
	assign gp_rid = s_rid;
	assign gp_rresp = s_rresp;
	assign gp_rlast = s_rlast;
	assign gp_rvalid = s_rvalid;

	generate
	if (HP == 0) begin : g_hp0
		PS7 ps7 (
			.FCLKCLK(fclk), .FCLKRESETN(fclk_resetn), .IRQF2P({19'd0, irq}),
			.MAXIGP0ACLK(clk),
			.MAXIGP0AWADDR(gp_awaddr),
			.MAXIGP0AWID(gp_awid),
			.MAXIGP0AWVALID(gp_awvalid),
			.MAXIGP0AWREADY(gp_awready),
			.MAXIGP0WDATA(gp_wdata),
			.MAXIGP0WSTRB(gp_wstrb),
			.MAXIGP0WLAST(gp_wlast),
			.MAXIGP0WVALID(gp_wvalid),
			.MAXIGP0WREADY(gp_wready),
			.MAXIGP0BID(gp_bid),
			.MAXIGP0BRESP(gp_bresp),
			.MAXIGP0BVALID(gp_bvalid),
			.MAXIGP0BREADY(gp_bready),
			.MAXIGP0ARADDR(gp_araddr),
			.MAXIGP0ARID(gp_arid),
			.MAXIGP0ARLEN(gp_arlen),
			.MAXIGP0ARVALID(gp_arvalid),
			.MAXIGP0ARREADY(gp_arready),
			.MAXIGP0RDATA(gp_rdata),
			.MAXIGP0RID(gp_rid),
			.MAXIGP0RRESP(gp_rresp),
			.MAXIGP0RLAST(gp_rlast),
			.MAXIGP0RVALID(gp_rvalid),
			.MAXIGP0RREADY(gp_rready),
			.SAXIHP0ACLK(clk),
			.SAXIHP0AWADDR(m_awaddr),
			.SAXIHP0AWLEN(m_awlen[3:0]),
			.SAXIHP0AWSIZE(m_awsize[1:0]),
			.SAXIHP0AWBURST(m_awburst),
			.SAXIHP0AWCACHE(m_awcache),
			.SAXIHP0AWPROT(m_awprot),
			.SAXIHP0AWVALID(m_awvalid),
			.SAXIHP0AWREADY(m_awready),
			.SAXIHP0WDATA(m_wdata),
			.SAXIHP0WSTRB(m_wstrb),
			.SAXIHP0WLAST(m_wlast),
			.SAXIHP0WVALID(m_wvalid),
			.SAXIHP0WREADY(m_wready),
			.SAXIHP0BRESP(m_bresp),
			.SAXIHP0BVALID(m_bvalid),
			.SAXIHP0BREADY(m_bready),
			.SAXIHP0ARADDR(m_araddr),
			.SAXIHP0ARLEN(m_arlen[3:0]),
			.SAXIHP0ARSIZE(m_arsize[1:0]),
			.SAXIHP0ARBURST(m_arburst),
			.SAXIHP0ARCACHE(m_arcache),
			.SAXIHP0ARPROT(m_arprot),
			.SAXIHP0ARVALID(m_arvalid),
			.SAXIHP0ARREADY(m_arready),
			.SAXIHP0RDATA(m_rdata),
			.SAXIHP0RRESP(m_rresp),
			.SAXIHP0RLAST(m_rlast),
			.SAXIHP0RVALID(m_rvalid),
			.SAXIHP0RREADY(m_rready),
			.SAXIHP0AWID(6'd0), .SAXIHP0ARID(6'd0), .SAXIHP0WID(6'd0),
			.SAXIHP0AWLOCK(2'b00), .SAXIHP0ARLOCK(2'b00), .SAXIHP0AWQOS(4'd0), .SAXIHP0ARQOS(4'd0),
			.SAXIHP0RDISSUECAP1EN(1'b0), .SAXIHP0WRISSUECAP1EN(1'b0)
		);
	end else begin : g_hp1
		PS7 ps7 (
			.FCLKCLK(fclk), .FCLKRESETN(fclk_resetn), .IRQF2P({19'd0, irq}),
			.MAXIGP0ACLK(clk),
			.MAXIGP0AWADDR(gp_awaddr),
			.MAXIGP0AWID(gp_awid),
			.MAXIGP0AWVALID(gp_awvalid),
			.MAXIGP0AWREADY(gp_awready),
			.MAXIGP0WDATA(gp_wdata),
			.MAXIGP0WSTRB(gp_wstrb),
			.MAXIGP0WLAST(gp_wlast),
			.MAXIGP0WVALID(gp_wvalid),
			.MAXIGP0WREADY(gp_wready),
			.MAXIGP0BID(gp_bid),
			.MAXIGP0BRESP(gp_bresp),
			.MAXIGP0BVALID(gp_bvalid),
			.MAXIGP0BREADY(gp_bready),
			.MAXIGP0ARADDR(gp_araddr),
			.MAXIGP0ARID(gp_arid),
			.MAXIGP0ARLEN(gp_arlen),
			.MAXIGP0ARVALID(gp_arvalid),
			.MAXIGP0ARREADY(gp_arready),
			.MAXIGP0RDATA(gp_rdata),
			.MAXIGP0RID(gp_rid),
			.MAXIGP0RRESP(gp_rresp),
			.MAXIGP0RLAST(gp_rlast),
			.MAXIGP0RVALID(gp_rvalid),
			.MAXIGP0RREADY(gp_rready),
			.SAXIHP1ACLK(clk),
			.SAXIHP1AWADDR(m_awaddr),
			.SAXIHP1AWLEN(m_awlen[3:0]),
			.SAXIHP1AWSIZE(m_awsize[1:0]),
			.SAXIHP1AWBURST(m_awburst),
			.SAXIHP1AWCACHE(m_awcache),
			.SAXIHP1AWPROT(m_awprot),
			.SAXIHP1AWVALID(m_awvalid),
			.SAXIHP1AWREADY(m_awready),
			.SAXIHP1WDATA(m_wdata),
			.SAXIHP1WSTRB(m_wstrb),
			.SAXIHP1WLAST(m_wlast),
			.SAXIHP1WVALID(m_wvalid),
			.SAXIHP1WREADY(m_wready),
			.SAXIHP1BRESP(m_bresp),
			.SAXIHP1BVALID(m_bvalid),
			.SAXIHP1BREADY(m_bready),
			.SAXIHP1ARADDR(m_araddr),
			.SAXIHP1ARLEN(m_arlen[3:0]),
			.SAXIHP1ARSIZE(m_arsize[1:0]),
			.SAXIHP1ARBURST(m_arburst),
			.SAXIHP1ARCACHE(m_arcache),
			.SAXIHP1ARPROT(m_arprot),
			.SAXIHP1ARVALID(m_arvalid),
			.SAXIHP1ARREADY(m_arready),
			.SAXIHP1RDATA(m_rdata),
			.SAXIHP1RRESP(m_rresp),
			.SAXIHP1RLAST(m_rlast),
			.SAXIHP1RVALID(m_rvalid),
			.SAXIHP1RREADY(m_rready),
			.SAXIHP1AWID(6'd0), .SAXIHP1ARID(6'd0), .SAXIHP1WID(6'd0),
			.SAXIHP1AWLOCK(2'b00), .SAXIHP1ARLOCK(2'b00), .SAXIHP1AWQOS(4'd0), .SAXIHP1ARQOS(4'd0),
			.SAXIHP1RDISSUECAP1EN(1'b0), .SAXIHP1WRISSUECAP1EN(1'b0)
		);
	end
	endgenerate

	wire unused_ok = &{1'b0, fclk[3:1], fclk_resetn[3:1], m_awlen[7:4], m_awsize[2],
		m_arlen[7:4], m_arsize[2]};
endmodule

`default_nettype wire
