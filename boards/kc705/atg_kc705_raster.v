/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_kc705_raster: The KC705 raster/compute configuration (design §3.6,
 * §3.7; no SA): CP with CPU, NSU SUs (NPHYS 16, NREGS 64), VF, RX, TU,
 * ROP, BLT, MC on MIG DDR3, the DC next to the GPU (+0x10000, MC client
 * EXT, ADV7511 parallel output), the JTAG register bridge.
 *
 * Wiring of its children; see
 * spec/boards/kc705/atg_kc705_raster.md.  The HDMI output is the ADV7511's
 * 16-bit YCbCr 4:2:2 input with separate syncs (the DC's PX_FMT 1): the
 * DC's registered outputs drive the pins (IOB registers in the XDC), and
 * the pixel clock is forwarded through an ODDR with D1 0 / D2 1, so the
 * ADV7511's rising edge is in the middle of each pixel.  The DC's TMDS
 * output is left open (removed by the tools).  IIC_MUX_RESET_B is
 * held high (the PCA9548 out of reset); the ADV7511 behind it is set up by
 * the host over the DC's I2C registers.  In simulation atg_kc705_clk and
 * atg_kc705_mig are replaced by sim/models/kc705/ and the primitives by
 * sim/models/xilinx/ (sim/tb/atg_kc705_raster_tb.v).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_kc705_raster #(
	parameter NSU = 1,	/* Shader units (1 for now; 4 to 6 later) */
	parameter CPU_IMEM_INIT = "atg1-cp-kc705.imem.hex",	/* CP firmware (Vivado finds it among the sources) */
	parameter CPU_DMEM_INIT = "atg1-cp-kc705.dmem.hex"
) (
	input wire sys_clk_p,
	input wire sys_clk_n,
	input wire cpu_reset,
	inout wire [63:0] ddr3_dq,
	inout wire [7:0] ddr3_dqs_p,
	inout wire [7:0] ddr3_dqs_n,
	output wire [13:0] ddr3_addr,
	output wire [2:0] ddr3_ba,
	output wire ddr3_ras_n,
	output wire ddr3_cas_n,
	output wire ddr3_we_n,
	output wire ddr3_reset_n,
	output wire ddr3_ck_p,
	output wire ddr3_ck_n,
	output wire ddr3_cke,
	output wire ddr3_cs_n,
	output wire [7:0] ddr3_dm,
	output wire ddr3_odt,
	output wire [7:0] led,
	output wire [15:0] hdmi_d,
	output wire hdmi_de,
	output wire hdmi_hs,
	output wire hdmi_vs,
	output wire hdmi_clk,
	inout wire iic_scl,
	inout wire iic_sda,
	output wire iic_mux_reset_n
);
	wire clk, rst_n, ref_clk, ref_rst_n, pclk, prst_n, pclk_sel, mem_ready, irq;
	/* No host AXI on the KC705 in v1 (JTAG only; PCIe later). */
	wire [31:0] s_awaddr;
	wire [3:0] s_awid;
	wire s_awvalid;
	wire s_awready;
	wire [31:0] s_wdata;
	wire [3:0] s_wstrb;
	wire s_wlast;
	wire s_wvalid;
	wire s_wready;
	wire [3:0] s_bid;
	wire [1:0] s_bresp;
	wire s_bvalid;
	wire s_bready;
	wire [31:0] s_araddr;
	wire [3:0] s_arid;
	wire [7:0] s_arlen;
	wire s_arvalid;
	wire s_arready;
	wire [31:0] s_rdata;
	wire [3:0] s_rid;
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
	wire [511:0] m_wdata;
	wire [63:0] m_wstrb;
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
	wire [511:0] m_rdata;
	wire [1:0] m_rresp;
	wire m_rlast;
	wire m_rvalid;
	wire m_rready;
	wire xr_wr, xr_rd, x_req_valid, x_req_ready, x_req_write, x_rsp_valid, x_rsp_write, x_rsp_error;
	wire x_vsync, j_wr, j_rd, j_busy;
	wire [16:0] xr_waddr, xr_raddr, j_waddr, j_raddr;
	wire [31:0] xr_wdata, xr_rdata, j_wdata, j_rdata;
	wire [3:0] xr_wstrb, j_wstrb;
	wire [25:0] x_req_line;
	wire [63:0] x_req_be;
	wire [511:0] x_req_wdata, x_rsp_rdata;
	wire [7:0] x_req_tag, x_rsp_tag;
	wire [29:0] tmds;
	wire scl_t, sda_t, dc_irq;
	wire [23:0] px;

	/* The host AXI slave is idle. */
	assign s_awaddr = 32'd0;
	assign s_awid = 4'd0;
	assign s_awvalid = 1'b0;
	assign s_wdata = 32'd0;
	assign s_wstrb = 4'd0;
	assign s_wlast = 1'b0;
	assign s_wvalid = 1'b0;
	assign s_bready = 1'b1;
	assign s_araddr = 32'd0;
	assign s_arid = 4'd0;
	assign s_arlen = 8'd0;
	assign s_arvalid = 1'b0;
	assign s_rready = 1'b1;

	atg_kc705_clk clocks (
		.sys_clk_p(sys_clk_p), .sys_clk_n(sys_clk_n), .cpu_reset(cpu_reset), .pclk_sel(pclk_sel),
		.gclk(clk), .grst_n(rst_n), .ref_clk(ref_clk), .ref_rst_n(ref_rst_n), .pclk(pclk),
		.prst_n(prst_n)
	);

	atg_kc705_jtag jtag (
		.clk(clk), .rst_n(rst_n), .j_wr(j_wr), .j_waddr(j_waddr), .j_wdata(j_wdata),
		.j_wstrb(j_wstrb), .j_rd(j_rd), .j_raddr(j_raddr), .j_rdata(j_rdata), .j_busy(j_busy)
	);

	atg_top #(
		.GCLK_HZ(32'd100000000),
		.S_ID_W(4),
		.S_LEN_W(8),
		.LINE_BYTES(64),
		.LINE_SHIFT(6),
		.DATA_W(512),
		.HAS_CPU(1),
		.CPU_IMEM_INIT(CPU_IMEM_INIT),
		.CPU_DMEM_INIT(CPU_DMEM_INIT),
		.NSU(NSU),
		.HAS_VF(1),
		.HAS_RX(1),
		.HAS_TU(1),
		.HAS_ROP(1),
		.EXT_CLIENT(1),
		.HAS_JTAG(1),
		.HAS_DISP(1),
		.ROP_STENCIL(1),
		.SU_NPHYS(16),
		.SU_NWARPS(4),
		.SU_WARP_W(2),
		.SU_GRP_W(1),
		.SU_NREGS(64),
		.SU_SB_ENTRIES(8),
		.SU_SBE_W(3),
		.SU_PACKED(1),
		.SU_SUBGROUP(1),
		.SU_FRAG_RESERVE(2),
		.SU_LDS_BYTES(16384),
		.SU_VARY_WORDS(64)
	) gpu (
		.clk(clk), .rst_n(rst_n), .irq(irq), .mem_ready(mem_ready),
		.s_awaddr(s_awaddr[16:0]), .s_awid(s_awid), .s_awvalid(s_awvalid), .s_awready(s_awready), .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid), .s_wready(s_wready), .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid),
		.s_bready(s_bready), .s_araddr(s_araddr[16:0]), .s_arid(s_arid), .s_arlen(s_arlen), .s_arvalid(s_arvalid), .s_arready(s_arready), .s_rdata(s_rdata), .s_rid(s_rid), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
		.m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awburst(m_awburst), .m_awcache(m_awcache), .m_awprot(m_awprot), .m_awvalid(m_awvalid), .m_awready(m_awready), .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready), .m_bresp(m_bresp), .m_bvalid(m_bvalid),
		.m_bready(m_bready), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst), .m_arcache(m_arcache), .m_arprot(m_arprot), .m_arvalid(m_arvalid), .m_arready(m_arready), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
		.xr_wr(xr_wr), .xr_waddr(xr_waddr), .xr_wdata(xr_wdata), .xr_wstrb(xr_wstrb), .xr_rd(xr_rd),
		.xr_raddr(xr_raddr), .xr_rdata(xr_rdata),
		.x_req_valid(x_req_valid), .x_req_ready(x_req_ready), .x_req_write(x_req_write),
		.x_req_line(x_req_line), .x_req_be(x_req_be), .x_req_wdata(x_req_wdata), .x_req_tag(x_req_tag),
		.x_rsp_valid(x_rsp_valid), .x_rsp_write(x_rsp_write), .x_rsp_tag(x_rsp_tag),
		.x_rsp_rdata(x_rsp_rdata), .x_rsp_error(x_rsp_error), .x_vsync(x_vsync),
		.j_wr(j_wr), .j_waddr(j_waddr), .j_wdata(j_wdata), .j_wstrb(j_wstrb), .j_rd(j_rd), .j_raddr(j_raddr),
		.j_rdata(j_rdata), .j_busy(j_busy)
	);

	atg_kc705_mig mig (
		.clk(clk), .rst_n(rst_n), .sys_clk(ref_clk), .sys_rst_n(ref_rst_n), .mem_ready(mem_ready),
		.s_awaddr(m_awaddr), .s_awlen(m_awlen), .s_awsize(m_awsize), .s_awburst(m_awburst), .s_awcache(m_awcache), .s_awprot(m_awprot), .s_awvalid(m_awvalid), .s_awready(m_awready), .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast), .s_wvalid(m_wvalid), .s_wready(m_wready), .s_bresp(m_bresp), .s_bvalid(m_bvalid),
		.s_bready(m_bready), .s_araddr(m_araddr), .s_arlen(m_arlen), .s_arsize(m_arsize), .s_arburst(m_arburst), .s_arcache(m_arcache), .s_arprot(m_arprot), .s_arvalid(m_arvalid), .s_arready(m_arready), .s_rdata(m_rdata), .s_rresp(m_rresp), .s_rlast(m_rlast), .s_rvalid(m_rvalid), .s_rready(m_rready),
		.ddr3_dq(ddr3_dq), .ddr3_dqs_p(ddr3_dqs_p), .ddr3_dqs_n(ddr3_dqs_n), .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba), .ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n), .ddr3_reset_n(ddr3_reset_n), .ddr3_ck_p(ddr3_ck_p), .ddr3_ck_n(ddr3_ck_n), .ddr3_cke(ddr3_cke), .ddr3_cs_n(ddr3_cs_n), .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt)
	);

	/* The display controller next to the GPU: registers at +0x10000, MC client EXT. */
	atg_dc #(
		.STANDALONE(0), .BASE(17'h10000), .HAS_I2C(1), .LINE_BYTES(64), .LINE_SHIFT(6),
		.FIFO_LOG2(11), .PX_FMT(1)
	) dc (
		.clk(clk), .rst_n(rst_n), .pclk(pclk), .prst_n(prst_n),
		.reg_wr(xr_wr), .reg_waddr(xr_waddr), .reg_wdata(xr_wdata), .reg_wstrb(xr_wstrb),
		.reg_rd(xr_rd), .reg_raddr(xr_raddr), .reg_rdata(xr_rdata),
		.irq(dc_irq), .vsync(x_vsync), .pclk_sel(pclk_sel),
		.req_valid(x_req_valid), .req_ready(x_req_ready), .req_write(x_req_write),
		.req_line(x_req_line), .req_be(x_req_be), .req_wdata(x_req_wdata), .req_tag(x_req_tag),
		.rsp_valid(x_rsp_valid), .rsp_write(x_rsp_write), .rsp_tag(x_rsp_tag),
		.rsp_rdata(x_rsp_rdata), .rsp_error(x_rsp_error),
		.tmds(tmds), .px_rgb(px), .px_de(hdmi_de), .px_hs(hdmi_hs), .px_vs(hdmi_vs),
		.scl_t(scl_t), .scl_i(iic_scl), .sda_t(sda_t), .sda_i(iic_sda)
	);

	/* Open-drain I2C (the tools infer IOBUFs). */
	assign iic_scl = scl_t ? 1'bz : 1'b0;
	assign iic_sda = sda_t ? 1'bz : 1'b0;
	assign iic_mux_reset_n = 1'b1;
	assign hdmi_d = px[15:0];

	/* The pixel clock to the ADV7511, inverted: its rising edge at the
	 * middle of the pixel. */
	ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) hdmi_clk_out (
		.Q(hdmi_clk), .C(pclk), .CE(1'b1), .D1(1'b0), .D2(1'b1), .R(1'b0), .S(1'b0)
	);

	reg [26:0] beat = 27'd0;

	always @(posedge clk)
		beat <= beat + 27'd1;

	wire unused_px = &{1'b0, px[23:16]};

	assign led = {4'd0, mem_ready, dc_irq, irq, beat[26]};

	wire unused_ok = &{1'b0, s_awready, s_wready, s_bid, s_bresp, s_bvalid, s_arready, s_rdata,
		s_rid, s_rresp, s_rlast, s_rvalid, tmds, s_awaddr[31:17], s_araddr[31:17]};
endmodule

`default_nettype wire
