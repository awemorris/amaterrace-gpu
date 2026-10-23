/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_zybo_dc: ZYBO bitstream 2 "DC" (design §3.6, §5): the display
 * controller alone as a display-only GHCI device at the PL window (GHCI
 * header at 0, DISP at +0x200), its memory master on S_AXI_HP1, VGA and
 * HDMI (TMDS) outputs.
 *
 * Wiring of its children; see spec/boards/zybo/atg_zybo_dc.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_zybo_dc (
	output wire [3:0] led,
	output wire [4:0] vga_r,
	output wire [5:0] vga_g,
	output wire [4:0] vga_b,
	output wire vga_hs,
	output wire vga_vs,
	output wire hdmi_clk_p,
	output wire hdmi_clk_n,
	output wire [2:0] hdmi_d_p,
	output wire [2:0] hdmi_d_n,
	output wire hdmi_out_en
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
	wire pclk, pclk5, prst_n, pclk_locked, pclk_sel;
	wire reg_wr, reg_rd;
	wire [16:0] reg_waddr, reg_raddr;
	wire [31:0] reg_wdata, reg_rdata;
	wire [3:0] reg_wstrb;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;
	wire [15:0] rsp_user;
	wire [29:0] tmds;
	wire [23:0] px_rgb;
	wire px_de, px_hs, px_vs, scl_t, sda_t, dma_idle;

	atg_zybo_ps #(.HP(1)) ps (
		.clk(clk), .rst_n(rst_n), .irq(irq),
		.s_awaddr(s_awaddr), .s_awid(s_awid), .s_awvalid(s_awvalid), .s_awready(s_awready), .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid), .s_wready(s_wready), .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready), .s_araddr(s_araddr), .s_arid(s_arid), .s_arlen(s_arlen), .s_arvalid(s_arvalid), .s_arready(s_arready), .s_rdata(s_rdata), .s_rid(s_rid), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
		.m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awburst(m_awburst), .m_awcache(m_awcache), .m_awprot(m_awprot), .m_awvalid(m_awvalid), .m_awready(m_awready), .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst), .m_arcache(m_arcache), .m_arprot(m_arprot), .m_arvalid(m_arvalid), .m_arready(m_arready), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready)
	);

	am_axi_regs #(.ADDR_BITS(17), .ID_W(12), .LEN_W(4)) regs (
		.clk(clk), .rst_n(rst_n),
		.s_awaddr(s_awaddr[16:0]), .s_awid(s_awid), .s_awvalid(s_awvalid), .s_awready(s_awready),
		.s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid),
		.s_wready(s_wready), .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid),
		.s_bready(s_bready), .s_araddr(s_araddr[16:0]), .s_arid(s_arid), .s_arlen(s_arlen),
		.s_arvalid(s_arvalid), .s_arready(s_arready), .s_rdata(s_rdata), .s_rid(s_rid),
		.s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
		.reg_wr(reg_wr), .reg_waddr(reg_waddr), .reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd), .reg_raddr(reg_raddr), .reg_rdata(reg_rdata)
	);

	atg_zybo_pclk clocks (
		.clk(clk), .rst_n(rst_n), .sel(pclk_sel), .pclk(pclk), .pclk5(pclk5), .prst_n(prst_n),
		.locked(pclk_locked)
	);

	atg_dc #(.STANDALONE(1), .LINE_BYTES(32), .LINE_SHIFT(5), .FIFO_LOG2(9)) dc (
		.clk(clk), .rst_n(rst_n), .pclk(pclk), .prst_n(prst_n),
		.reg_wr(reg_wr), .reg_waddr(reg_waddr), .reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd), .reg_raddr(reg_raddr), .reg_rdata(reg_rdata),
		.irq(irq), .vsync(), .pclk_sel(pclk_sel),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
		.req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
		.rsp_error(rsp_error),
		.vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b), .vga_hs(vga_hs), .vga_vs(vga_vs),
		.tmds(tmds), .px_rgb(px_rgb), .px_de(px_de), .px_hs(px_hs), .px_vs(px_vs),
		.scl_t(scl_t), .scl_i(1'b1), .sda_t(sda_t), .sda_i(1'b1)
	);

	/* The DC's own memory master on HP1 (read only, design §4.2). */
	am_axi_master #(.LINE_BYTES(32), .LINE_SHIFT(5), .DATA_W(64)) master (
		.clk(clk), .rst_n(rst_n), .halt(1'b0), .idle(dma_idle),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
		.req_be(req_be), .req_wdata(req_wdata), .req_user({8'd0, req_tag}),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_user(rsp_user), .rsp_rdata(rsp_rdata),
		.rsp_error(rsp_error),
		.m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awburst(m_awburst), .m_awcache(m_awcache), .m_awprot(m_awprot), .m_awvalid(m_awvalid), .m_awready(m_awready), .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready), .m_bresp(m_bresp), .m_bvalid(m_bvalid),
		.m_bready(m_bready), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst), .m_arcache(m_arcache), .m_arprot(m_arprot), .m_arvalid(m_arvalid), .m_arready(m_arready), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready)
	);
	assign rsp_tag = rsp_user[7:0];

	atg_zybo_tmds_out hdmi (
		.pclk(pclk), .pclk5(pclk5), .rst_n(prst_n), .tmds(tmds),
		.hdmi_clk_p(hdmi_clk_p), .hdmi_clk_n(hdmi_clk_n), .hdmi_d_p(hdmi_d_p), .hdmi_d_n(hdmi_d_n)
	);

	reg [25:0] beat = 26'd0;

	always @(posedge clk)
		beat <= beat + 26'd1;

	assign led = {pclk_locked, dma_idle, irq, beat[25]};

	/* The ZYBO's HDMI port as a source (HDMI_OUT_EN high). */
	assign hdmi_out_en = 1'b1;

	wire unused_ok = &{1'b0, s_awaddr[31:17], s_araddr[31:17], rsp_user[15:8], px_rgb, px_de, px_hs,
		px_vs, scl_t, sda_t};
endmodule

`default_nettype wire
