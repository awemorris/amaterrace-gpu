/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_kc705_raster: The KC705 raster/compute configuration (design §3.6,
 * §3.7; no SA): CP with CPU, NSU SUs (NPHYS 8, NREGS 64), VF, RX, TU,
 * ROP, BLT, MC on MIG DDR3, the DC inside the GPU (atg_top's HAS_DISP,
 * ADV7511 parallel output), the JTAG register bridge, and the PCIe
 * endpoint (ws288 p013, docs/ghci.md section 15.2): BAR0 the register
 * window (atg_kc705_pcie's m0_* through am_axi_cdc into atg_top's s_*,
 * beside the JTAG bridge; the DC's DISP2 window is in it), BAR2 the
 * 64 MiB local window (m2_* to the MIG's second port, not through the
 * MC), one MSI vector for GHCI's interrupt line by atg_pcie_msi (the
 * DC's events are bits of IRQ_STATUS).  The GPU -> host port of
 * atg_kc705_pcie is idle in version 1 (no host memory: its model answers
 * DECERR).
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
	output wire iic_mux_reset_n,
	input wire pcie_refclk_p,
	input wire pcie_refclk_n,
	input wire pcie_perst_n,
	output wire [3:0] pcie_txp,
	output wire [3:0] pcie_txn,
	input wire [3:0] pcie_rxp,
	input wire [3:0] pcie_rxn
);
	wire clk, rst_n, ref_clk, ref_rst_n, pclk, prst_n, pclk_sel, mem_ready, irq;
	/* The host's register port: PCIe BAR0 through am_axi_cdc. */
	wire [16:0] s_awaddr;
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
	wire [16:0] s_araddr;
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
	wire xr_wr, xr_rd, x_req_ready, x_rsp_valid, x_rsp_write, x_rsp_error;
	wire j_wr, j_rd, j_busy;
	wire [16:0] xr_waddr, xr_raddr, j_waddr, j_raddr;
	wire [31:0] xr_wdata, j_wdata, j_rdata;
	wire [3:0] xr_wstrb, j_wstrb;
	wire [511:0] x_rsp_rdata;
	wire [7:0] x_rsp_tag;
	wire [29:0] tmds;
	wire scl_t, sda_t;
	wire [23:0] px;

	/* ---- PCIe (atg_kc705_pcie: the bridge IP) ---- */
	wire user_clk, user_rst_n, link_up;
	wire [16:0] p0_awaddr, p0_araddr;
	wire [3:0] p0_awid, p0_bid, p0_arid, p0_rid, p0_wstrb;
	wire [7:0] p0_arlen;
	wire p0_awvalid, p0_awready, p0_wlast, p0_wvalid, p0_wready, p0_bvalid, p0_bready;
	wire p0_arvalid, p0_arready, p0_rlast, p0_rvalid, p0_rready;
	wire [31:0] p0_wdata, p0_rdata;
	wire [1:0] p0_bresp, p0_rresp;
	wire [25:0] p2_awaddr, p2_araddr;
	wire [3:0] p2_awid, p2_bid, p2_arid, p2_rid;
	wire [7:0] p2_awlen, p2_arlen;
	wire [2:0] p2_awsize, p2_arsize;
	wire [1:0] p2_awburst, p2_arburst, p2_bresp, p2_rresp;
	wire p2_awvalid, p2_awready, p2_wlast, p2_wvalid, p2_wready, p2_bvalid, p2_bready;
	wire p2_arvalid, p2_arready, p2_rlast, p2_rvalid, p2_rready;
	wire [127:0] p2_wdata, p2_rdata, h_rdata;
	wire [15:0] p2_wstrb;
	wire h_awready, h_wready, h_bvalid, h_arready, h_rlast, h_rvalid;
	wire [3:0] h_bid, h_rid;
	wire [1:0] h_bresp, h_rresp;
	wire msi_req, msi_ack;

	atg_kc705_pcie pcie (
		.pcie_refclk_p(pcie_refclk_p), .pcie_refclk_n(pcie_refclk_n),
		.pcie_perst_n(pcie_perst_n), .pcie_txp(pcie_txp), .pcie_txn(pcie_txn),
		.pcie_rxp(pcie_rxp), .pcie_rxn(pcie_rxn),
		.user_clk(user_clk), .user_rst_n(user_rst_n), .link_up(link_up),
		.m0_awaddr(p0_awaddr), .m0_awid(p0_awid), .m0_awvalid(p0_awvalid),
		.m0_awready(p0_awready), .m0_wdata(p0_wdata), .m0_wstrb(p0_wstrb), .m0_wlast(p0_wlast),
		.m0_wvalid(p0_wvalid), .m0_wready(p0_wready), .m0_bid(p0_bid), .m0_bresp(p0_bresp),
		.m0_bvalid(p0_bvalid), .m0_bready(p0_bready), .m0_araddr(p0_araddr),
		.m0_arid(p0_arid), .m0_arlen(p0_arlen), .m0_arvalid(p0_arvalid),
		.m0_arready(p0_arready), .m0_rdata(p0_rdata), .m0_rid(p0_rid), .m0_rresp(p0_rresp),
		.m0_rlast(p0_rlast), .m0_rvalid(p0_rvalid), .m0_rready(p0_rready),
		.m2_awaddr(p2_awaddr), .m2_awid(p2_awid), .m2_awlen(p2_awlen), .m2_awsize(p2_awsize),
		.m2_awburst(p2_awburst), .m2_awvalid(p2_awvalid), .m2_awready(p2_awready),
		.m2_wdata(p2_wdata), .m2_wstrb(p2_wstrb), .m2_wlast(p2_wlast), .m2_wvalid(p2_wvalid),
		.m2_wready(p2_wready), .m2_bid(p2_bid), .m2_bresp(p2_bresp), .m2_bvalid(p2_bvalid),
		.m2_bready(p2_bready), .m2_araddr(p2_araddr), .m2_arid(p2_arid), .m2_arlen(p2_arlen),
		.m2_arsize(p2_arsize), .m2_arburst(p2_arburst), .m2_arvalid(p2_arvalid),
		.m2_arready(p2_arready), .m2_rdata(p2_rdata), .m2_rid(p2_rid), .m2_rresp(p2_rresp),
		.m2_rlast(p2_rlast), .m2_rvalid(p2_rvalid), .m2_rready(p2_rready),
		/* GPU -> host memory: idle in version 1 */
		.s_awaddr(32'd0), .s_awid(4'd0), .s_awlen(8'd0), .s_awsize(3'd4), .s_awburst(2'b01),
		.s_awvalid(1'b0), .s_awready(h_awready), .s_wdata(128'd0), .s_wstrb(16'd0),
		.s_wlast(1'b0), .s_wvalid(1'b0), .s_wready(h_wready), .s_bid(h_bid), .s_bresp(h_bresp),
		.s_bvalid(h_bvalid), .s_bready(1'b1), .s_araddr(32'd0), .s_arid(4'd0), .s_arlen(8'd0),
		.s_arsize(3'd4), .s_arburst(2'b01), .s_arvalid(1'b0), .s_arready(h_arready),
		.s_rdata(h_rdata), .s_rid(h_rid), .s_rresp(h_rresp), .s_rlast(h_rlast),
		.s_rvalid(h_rvalid), .s_rready(1'b1),
		.msi_req(msi_req), .msi_ack(msi_ack)
	);

	/* BAR0 into gclk: atg_top's register port. */
	am_axi_cdc #(.A_W(17), .ID_W(4), .LEN_W(8), .D_W(32), .DEPTH_LOG2(2)) bar0 (
		.s_clk(user_clk), .s_rst_n(user_rst_n),
		.s_awaddr(p0_awaddr), .s_awid(p0_awid), .s_awvalid(p0_awvalid), .s_awready(p0_awready),
		.s_wdata(p0_wdata), .s_wstrb(p0_wstrb), .s_wlast(p0_wlast), .s_wvalid(p0_wvalid),
		.s_wready(p0_wready), .s_bid(p0_bid), .s_bresp(p0_bresp), .s_bvalid(p0_bvalid),
		.s_bready(p0_bready), .s_araddr(p0_araddr), .s_arid(p0_arid), .s_arlen(p0_arlen),
		.s_arvalid(p0_arvalid), .s_arready(p0_arready), .s_rdata(p0_rdata), .s_rid(p0_rid),
		.s_rresp(p0_rresp), .s_rlast(p0_rlast), .s_rvalid(p0_rvalid), .s_rready(p0_rready),
		.m_clk(clk), .m_rst_n(rst_n),
		.m_awaddr(s_awaddr), .m_awid(s_awid), .m_awvalid(s_awvalid), .m_awready(s_awready),
		.m_wdata(s_wdata), .m_wstrb(s_wstrb), .m_wlast(s_wlast), .m_wvalid(s_wvalid),
		.m_wready(s_wready), .m_bid(s_bid), .m_bresp(s_bresp), .m_bvalid(s_bvalid),
		.m_bready(s_bready), .m_araddr(s_araddr), .m_arid(s_arid), .m_arlen(s_arlen),
		.m_arvalid(s_arvalid), .m_arready(s_arready), .m_rdata(s_rdata), .m_rid(s_rid),
		.m_rresp(s_rresp), .m_rlast(s_rlast), .m_rvalid(s_rvalid), .m_rready(s_rready)
	);

	/* MSI: the one vector of GHCI's interrupt line (the DC's events included). */
	atg_pcie_msi msi (
		.clk(clk), .rst_n(rst_n), .irq(irq), .aw_take(s_awvalid && s_awready),
		.aw_addr(s_awaddr), .b_take(s_bvalid && s_bready), .uclk(user_clk),
		.urst_n(user_rst_n), .msi_req(msi_req), .msi_ack(msi_ack)
	);

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
		.LOCAL_BASE(32'h80000000),	/* the MIG's 1 GiB (it takes address bits 29:0) */
		.LOCAL_BYTES(32'h40000000),
		.WINDOW_BYTES(32'h04000000),	/* the 64 MiB local window of the PCIe BAR2 */
		.HAS_CPU(1),
		.CPU_IMEM_INIT(CPU_IMEM_INIT),
		.CPU_DMEM_INIT(CPU_DMEM_INIT),
		.CPU_IMEM_WORDS(32768),
		.CPU_DMEM_WORDS(16384),
		.NSU(NSU),
		.HAS_VF(1),
		.HAS_RX(1),
		.HAS_TU(1),
		.HAS_ROP(1),
		.HAS_JTAG(1),
		.HAS_DISP(1),
		.DC_HAS_I2C(1),
		.DC_FIFO_LOG2(11),
		.DC_PX_FMT(1),
		.ROP_STENCIL(1),
		.SU_NPHYS(8),
		.SU_NWARPS(4),
		.SU_WARP_W(2),
		.SU_GRP_W(2),
		.SU_NREGS(64),
		.SU_SB_ENTRIES(8),
		.SU_SBE_W(3),
		.SU_PACKED(1),
		.SU_SUBGROUP(1),
		.SU_FRAG_RESERVE(2),
		.SU_LDS_BYTES(16384),
		.SU_VARY_WORDS(64),
		/* Session protection (docs/ghci.md section 11.6): 31 protected sessions, 64 grants,
		 * a 16-line PLB. */
		.HAS_PROT(1),
		.PROT_SLOTS(31),
		.PROT_GRANTS(64),
		.PROT_GIDX_W(6),
		.PROT_PLB(16),
		.PROT_PLB_W(4)
	) gpu (
		.clk(clk), .rst_n(rst_n), .irq(irq), .mem_ready(mem_ready),
		.s_awaddr(s_awaddr), .s_awid(s_awid), .s_awvalid(s_awvalid), .s_awready(s_awready), .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid), .s_wready(s_wready), .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid),
		.s_bready(s_bready), .s_araddr(s_araddr), .s_arid(s_arid), .s_arlen(s_arlen), .s_arvalid(s_arvalid), .s_arready(s_arready), .s_rdata(s_rdata), .s_rid(s_rid), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
		.m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awburst(m_awburst), .m_awcache(m_awcache), .m_awprot(m_awprot), .m_awvalid(m_awvalid), .m_awready(m_awready), .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready), .m_bresp(m_bresp), .m_bvalid(m_bvalid),
		.m_bready(m_bready), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst), .m_arcache(m_arcache), .m_arprot(m_arprot), .m_arvalid(m_arvalid), .m_arready(m_arready), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
		.xr_wr(xr_wr), .xr_waddr(xr_waddr), .xr_wdata(xr_wdata), .xr_wstrb(xr_wstrb), .xr_rd(xr_rd),
		.xr_raddr(xr_raddr), .xr_rdata(32'd0),
		.x_req_valid(1'b0), .x_req_ready(x_req_ready), .x_req_write(1'b0),
		.x_req_line(26'd0), .x_req_be(64'd0), .x_req_wdata(512'd0), .x_req_tag(8'd0),
		.x_rsp_valid(x_rsp_valid), .x_rsp_write(x_rsp_write), .x_rsp_tag(x_rsp_tag),
		.x_rsp_rdata(x_rsp_rdata), .x_rsp_error(x_rsp_error), .x_vsync(1'b0),
		.j_wr(j_wr), .j_waddr(j_waddr), .j_wdata(j_wdata), .j_wstrb(j_wstrb), .j_rd(j_rd), .j_raddr(j_raddr),
		.j_rdata(j_rdata), .j_busy(j_busy),
		.pclk(pclk), .prst_n(prst_n), .pclk_sel(pclk_sel),
		.tmds(tmds), .px_rgb(px), .px_de(hdmi_de), .px_hs(hdmi_hs), .px_vs(hdmi_vs),
		.scl_t(scl_t), .scl_i(iic_scl), .sda_t(sda_t), .sda_i(iic_sda)
	);

	atg_kc705_mig mig (
		.clk(clk), .rst_n(rst_n), .sys_clk(ref_clk), .sys_rst_n(ref_rst_n), .mem_ready(mem_ready),
		.s_awaddr(m_awaddr), .s_awlen(m_awlen), .s_awsize(m_awsize), .s_awburst(m_awburst), .s_awcache(m_awcache), .s_awprot(m_awprot), .s_awvalid(m_awvalid), .s_awready(m_awready), .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast), .s_wvalid(m_wvalid), .s_wready(m_wready), .s_bresp(m_bresp), .s_bvalid(m_bvalid),
		.s_bready(m_bready), .s_araddr(m_araddr), .s_arlen(m_arlen), .s_arsize(m_arsize), .s_arburst(m_arburst), .s_arcache(m_arcache), .s_arprot(m_arprot), .s_arvalid(m_arvalid), .s_arready(m_arready), .s_rdata(m_rdata), .s_rresp(m_rresp), .s_rlast(m_rlast), .s_rvalid(m_rvalid), .s_rready(m_rready),
		.s2_clk(user_clk), .s2_rst_n(user_rst_n),
		.s2_awaddr(p2_awaddr), .s2_awid(p2_awid), .s2_awlen(p2_awlen), .s2_awsize(p2_awsize),
		.s2_awburst(p2_awburst), .s2_awvalid(p2_awvalid), .s2_awready(p2_awready),
		.s2_wdata(p2_wdata), .s2_wstrb(p2_wstrb), .s2_wlast(p2_wlast), .s2_wvalid(p2_wvalid),
		.s2_wready(p2_wready), .s2_bid(p2_bid), .s2_bresp(p2_bresp), .s2_bvalid(p2_bvalid),
		.s2_bready(p2_bready), .s2_araddr(p2_araddr), .s2_arid(p2_arid), .s2_arlen(p2_arlen),
		.s2_arsize(p2_arsize), .s2_arburst(p2_arburst), .s2_arvalid(p2_arvalid),
		.s2_arready(p2_arready), .s2_rdata(p2_rdata), .s2_rid(p2_rid), .s2_rresp(p2_rresp),
		.s2_rlast(p2_rlast), .s2_rvalid(p2_rvalid), .s2_rready(p2_rready),
		.ddr3_dq(ddr3_dq), .ddr3_dqs_p(ddr3_dqs_p), .ddr3_dqs_n(ddr3_dqs_n), .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba), .ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n), .ddr3_reset_n(ddr3_reset_n), .ddr3_ck_p(ddr3_ck_p), .ddr3_ck_n(ddr3_ck_n), .ddr3_cke(ddr3_cke), .ddr3_cs_n(ddr3_cs_n), .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt)
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

	assign led = {3'd0, link_up, mem_ready, 1'b0, irq, beat[26]};	/* [2] is free */

	wire unused_ok = &{1'b0, tmds, h_awready, h_wready, h_bid, h_bresp, h_bvalid, h_arready,
		h_rdata, h_rid, h_rresp, h_rlast, h_rvalid, xr_wr, xr_rd, xr_waddr, xr_raddr, xr_wdata,
		xr_wstrb, x_req_ready, x_rsp_valid, x_rsp_write, x_rsp_error, x_rsp_rdata, x_rsp_tag};
endmodule

`default_nettype wire
