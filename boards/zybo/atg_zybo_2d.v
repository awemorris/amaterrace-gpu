/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_zybo_2d: ZYBO bitstream 1, "2D" (WS288 design §3.6): the GPU with
 * the CP, the blitter and the MC on the original ZYBO (XC7Z010-1CLG400).
 *
 *   M_AXI_GP0 (AXI3, 12-bit IDs) -> the GHCI registers, the kernel's PL
 *                                   window 0x43C00000 (64 KiB of the 128
 *                                   KiB decode)
 *   S_AXI_HP0 (AXI3, 64-bit)     <- the GPU's memory master
 *   IRQ_F2P[0]                   <- the GPU's level interrupt (GIC 61)
 *   FCLK_CLK0 (100 MHz)             gclk = mclk = the GP0 and HP0 clocks
 *   LD0                             heartbeat (about 1.5 Hz), LD1 the
 *                                   interrupt line
 *
 * The PS (ps7_init by zedBSD's boot) must have FCLK0 at 100 MHz, the
 * level shifters enabled and HP0 in 64-bit mode.  Checked on the board
 * (WS288 p003, booted from SD by U-Boot SPL's ps7_init, then fpgaload):
 * FPGA0_CLK_CTRL 0x00100A00 (IO PLL / 10), LVL_SHFTR_EN 0xF, FPGA_RST_CTRL
 * 0, and AFI0's RDCHAN_CTRL 0 and WRCHAN_CTRL 0xF00, the reset values,
 * whose bit 0 (32BIT_EN) 0 is the 64-bit mode: ps7_init does not write
 * the AFI.  The HP port's AXI3
 * widths are those of the PS7 primitive (Vivado 2026.1's unisim PS7.v):
 * IDs 6 bits, AxLEN 4, AxSIZE 2, WSTRB 8.  WID is 0 like AWID.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_zybo_2d (
	output wire [3:0] led
);
	wire [3:0] fclk;
	wire [3:0] fclk_resetn;
	wire clk;
	BUFG fclk0_bufg (.I(fclk[0]), .O(clk));

	/* FCLK_RESET0_N comes from the PS's domain: take it in twice. */
	(* ASYNC_REG = "TRUE" *) reg [1:0] rst_sync = 2'b00;
	wire rst_n = rst_sync[1];

	always @(posedge clk)
		rst_sync <= {rst_sync[0], fclk_resetn[0]};

	/* M_AXI_GP0. */
	wire [31:0] gp_awaddr, gp_araddr, gp_wdata, gp_rdata;
	wire [11:0] gp_awid, gp_arid, gp_bid, gp_rid;
	wire [3:0] gp_arlen, gp_wstrb;
	wire [1:0] gp_bresp, gp_rresp;
	wire gp_awvalid, gp_awready, gp_wlast, gp_wvalid, gp_wready, gp_bvalid, gp_bready;
	wire gp_arvalid, gp_arready, gp_rlast, gp_rvalid, gp_rready;

	/* S_AXI_HP0. */
	wire [31:0] hp_awaddr, hp_araddr;
	wire [7:0] hp_awlen, hp_arlen;
	wire [2:0] hp_awsize, hp_arsize, hp_awprot, hp_arprot;
	wire [1:0] hp_awburst, hp_arburst, hp_bresp, hp_rresp;
	wire [3:0] hp_awcache, hp_arcache;
	wire [63:0] hp_wdata, hp_rdata;
	wire [7:0] hp_wstrb;
	wire hp_awvalid, hp_awready, hp_wlast, hp_wvalid, hp_wready, hp_bvalid, hp_bready;
	wire hp_arvalid, hp_arready, hp_rlast, hp_rvalid, hp_rready;

	wire irq;

	PS7 ps7 (
		.FCLKCLK(fclk),
		.FCLKRESETN(fclk_resetn),
		.IRQF2P({19'd0, irq}),

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
		.SAXIHP0AWADDR(hp_awaddr),
		.SAXIHP0AWID(6'd0),
		.SAXIHP0AWLEN(hp_awlen[3:0]),
		.SAXIHP0AWSIZE(hp_awsize[1:0]),
		.SAXIHP0AWBURST(hp_awburst),
		.SAXIHP0AWLOCK(2'b00),
		.SAXIHP0AWCACHE(hp_awcache),
		.SAXIHP0AWPROT(hp_awprot),
		.SAXIHP0AWQOS(4'd0),
		.SAXIHP0AWVALID(hp_awvalid),
		.SAXIHP0AWREADY(hp_awready),
		.SAXIHP0WID(6'd0),
		.SAXIHP0WDATA(hp_wdata),
		.SAXIHP0WSTRB(hp_wstrb),
		.SAXIHP0WLAST(hp_wlast),
		.SAXIHP0WVALID(hp_wvalid),
		.SAXIHP0WREADY(hp_wready),
		.SAXIHP0BRESP(hp_bresp),
		.SAXIHP0BVALID(hp_bvalid),
		.SAXIHP0BREADY(hp_bready),
		.SAXIHP0ARADDR(hp_araddr),
		.SAXIHP0ARID(6'd0),
		.SAXIHP0ARLEN(hp_arlen[3:0]),
		.SAXIHP0ARSIZE(hp_arsize[1:0]),
		.SAXIHP0ARBURST(hp_arburst),
		.SAXIHP0ARLOCK(2'b00),
		.SAXIHP0ARCACHE(hp_arcache),
		.SAXIHP0ARPROT(hp_arprot),
		.SAXIHP0ARQOS(4'd0),
		.SAXIHP0ARVALID(hp_arvalid),
		.SAXIHP0ARREADY(hp_arready),
		.SAXIHP0RDATA(hp_rdata),
		.SAXIHP0RRESP(hp_rresp),
		.SAXIHP0RLAST(hp_rlast),
		.SAXIHP0RVALID(hp_rvalid),
		.SAXIHP0RREADY(hp_rready),
		.SAXIHP0RDISSUECAP1EN(1'b0),
		.SAXIHP0WRISSUECAP1EN(1'b0)
	);

	atg_top #(
		.GCLK_HZ(32'd100000000),
		.S_ID_W(12),
		.S_LEN_W(4),
		.LINE_BYTES(32),
		.LINE_SHIFT(5),
		.DATA_W(64)
	) gpu (
		.clk(clk),
		.rst_n(rst_n),
		.irq(irq),
		.mem_ready(1'b1),
		.s_awaddr(gp_awaddr[16:0]),
		.s_awid(gp_awid),
		.s_awvalid(gp_awvalid),
		.s_awready(gp_awready),
		.s_wdata(gp_wdata),
		.s_wstrb(gp_wstrb),
		.s_wlast(gp_wlast),
		.s_wvalid(gp_wvalid),
		.s_wready(gp_wready),
		.s_bid(gp_bid),
		.s_bresp(gp_bresp),
		.s_bvalid(gp_bvalid),
		.s_bready(gp_bready),
		.s_araddr(gp_araddr[16:0]),
		.s_arid(gp_arid),
		.s_arlen(gp_arlen),
		.s_arvalid(gp_arvalid),
		.s_arready(gp_arready),
		.s_rdata(gp_rdata),
		.s_rid(gp_rid),
		.s_rresp(gp_rresp),
		.s_rlast(gp_rlast),
		.s_rvalid(gp_rvalid),
		.s_rready(gp_rready),
		.m_awaddr(hp_awaddr),
		.m_awlen(hp_awlen),
		.m_awsize(hp_awsize),
		.m_awburst(hp_awburst),
		.m_awcache(hp_awcache),
		.m_awprot(hp_awprot),
		.m_awvalid(hp_awvalid),
		.m_awready(hp_awready),
		.m_wdata(hp_wdata),
		.m_wstrb(hp_wstrb),
		.m_wlast(hp_wlast),
		.m_wvalid(hp_wvalid),
		.m_wready(hp_wready),
		.m_bresp(hp_bresp),
		.m_bvalid(hp_bvalid),
		.m_bready(hp_bready),
		.m_araddr(hp_araddr),
		.m_arlen(hp_arlen),
		.m_arsize(hp_arsize),
		.m_arburst(hp_arburst),
		.m_arcache(hp_arcache),
		.m_arprot(hp_arprot),
		.m_arvalid(hp_arvalid),
		.m_arready(hp_arready),
		.m_rdata(hp_rdata),
		.m_rresp(hp_rresp),
		.m_rlast(hp_rlast),
		.m_rvalid(hp_rvalid),
		.m_rready(hp_rready),
		/* WS288 p023: nothing outside the GPU here. */
		.xr_wr(), .xr_waddr(), .xr_wdata(), .xr_wstrb(), .xr_rd(), .xr_raddr(),
		.xr_rdata(32'd0),
		.x_req_valid(1'b0), .x_req_ready(), .x_req_write(1'b0), .x_req_line(27'd0),
		.x_req_be(32'd0), .x_req_wdata(256'd0), .x_req_tag(8'd0),
		.x_rsp_valid(), .x_rsp_write(), .x_rsp_tag(), .x_rsp_rdata(), .x_rsp_error(),
		.x_vsync(1'b0),
		.j_wr(1'b0), .j_waddr(17'd0), .j_wdata(32'd0), .j_wstrb(4'd0), .j_rd(1'b0),
		.j_raddr(17'd0), .j_rdata(), .j_busy()
	);

	reg [25:0] beat = 26'd0;

	always @(posedge clk)
		beat <= beat + 26'd1;

	assign led = {2'b00, irq, beat[25]};
endmodule

`default_nettype wire
