/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_zybo_raster: ZYBO bitstream 3 "raster" (design §3.6): CP, RX, ROP,
 * BLT, MC; DRAW_RAW and DEBUG_COLOR (no VF, no SU).
 *
 * Wiring of its children (WS288 p023); see spec/boards/zybo/atg_zybo_raster.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_zybo_raster (
	output wire [3:0] led
);
	wire [31:0] s_awaddr;
	wire [11:0] s_awid;
	wire s_awvalid;
	wire s_awready;
	wire [31:0] s_wdata;
	wire [3:0] s_wstrb;
	wire s_wlast;
	wire s_wvalid;
	wire s_wready;
	wire [11:0] s_bid;
	wire [1:0] s_bresp;
	wire s_bvalid;
	wire s_bready;
	wire [31:0] s_araddr;
	wire [11:0] s_arid;
	wire [3:0] s_arlen;
	wire s_arvalid;
	wire s_arready;
	wire [31:0] s_rdata;
	wire [11:0] s_rid;
	wire [1:0] s_rresp;
	wire s_rlast;
	wire s_rvalid;
	wire s_rready;
	wire [31:0] m_awaddr;
	wire [7:0] m_awlen;
	wire [2:0] m_awsize;
	wire [1:0] m_awburst;
	wire [3:0] m_awcache;
	wire [2:0] m_awprot;
	wire m_awvalid;
	wire m_awready;
	wire [63:0] m_wdata;
	wire [7:0] m_wstrb;
	wire m_wlast;
	wire m_wvalid;
	wire m_wready;
	wire [1:0] m_bresp;
	wire m_bvalid;
	wire m_bready;
	wire [31:0] m_araddr;
	wire [7:0] m_arlen;
	wire [2:0] m_arsize;
	wire [1:0] m_arburst;
	wire [3:0] m_arcache;
	wire [2:0] m_arprot;
	wire m_arvalid;
	wire m_arready;
	wire [63:0] m_rdata;
	wire [1:0] m_rresp;
	wire m_rlast;
	wire m_rvalid;
	wire m_rready;
	wire clk, rst_n, irq;

	atg_zybo_ps #(.HP(0)) ps (
		.clk(clk), .rst_n(rst_n), .irq(irq),
		.s_awaddr(s_awaddr), .s_awid(s_awid), .s_awvalid(s_awvalid), .s_awready(s_awready), .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid), .s_wready(s_wready), .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready), .s_araddr(s_araddr), .s_arid(s_arid), .s_arlen(s_arlen), .s_arvalid(s_arvalid), .s_arready(s_arready), .s_rdata(s_rdata), .s_rid(s_rid), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
		.m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awburst(m_awburst), .m_awcache(m_awcache), .m_awprot(m_awprot), .m_awvalid(m_awvalid), .m_awready(m_awready), .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst), .m_arcache(m_arcache), .m_arprot(m_arprot), .m_arvalid(m_arvalid), .m_arready(m_arready), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready)
	);

	atg_top #(
		.GCLK_HZ(32'd100000000),
		.S_ID_W(12),
		.S_LEN_W(4),
		.LINE_BYTES(32),
		.LINE_SHIFT(5),
		.DATA_W(64),
		.HAS_RX(1),
		.HAS_ROP(1)
	) gpu (
		.clk(clk), .rst_n(rst_n), .irq(irq), .mem_ready(1'b1),
		.s_awaddr(s_awaddr[16:0]), .s_awid(s_awid), .s_awvalid(s_awvalid), .s_awready(s_awready), .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid), .s_wready(s_wready), .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid),
		.s_bready(s_bready), .s_araddr(s_araddr[16:0]), .s_arid(s_arid), .s_arlen(s_arlen), .s_arvalid(s_arvalid), .s_arready(s_arready), .s_rdata(s_rdata), .s_rid(s_rid), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
		.m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awburst(m_awburst), .m_awcache(m_awcache), .m_awprot(m_awprot), .m_awvalid(m_awvalid), .m_awready(m_awready), .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready), .m_bresp(m_bresp), .m_bvalid(m_bvalid),
		.m_bready(m_bready), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst), .m_arcache(m_arcache), .m_arprot(m_arprot), .m_arvalid(m_arvalid), .m_arready(m_arready), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
		.xr_wr(), .xr_waddr(), .xr_wdata(), .xr_wstrb(), .xr_rd(), .xr_raddr(), .xr_rdata(32'd0),
		.x_req_valid(1'b0), .x_req_ready(), .x_req_write(1'b0), .x_req_line(27'd0), .x_req_be(32'd0),
		.x_req_wdata(256'd0), .x_req_tag(8'd0), .x_rsp_valid(), .x_rsp_write(), .x_rsp_tag(),
		.x_rsp_rdata(), .x_rsp_error(), .x_vsync(1'b0),
		.j_wr(1'b0), .j_waddr(17'd0), .j_wdata(32'd0), .j_wstrb(4'd0), .j_rd(1'b0), .j_raddr(17'd0),
		.j_rdata(), .j_busy()
	);

	reg [25:0] beat = 26'd0;

	always @(posedge clk)
		beat <= beat + 26'd1;

	assign led = {2'b00, irq, beat[25]};

	wire unused_ok = &{1'b0, s_awaddr[31:17], s_araddr[31:17]};
endmodule

`default_nettype wire
