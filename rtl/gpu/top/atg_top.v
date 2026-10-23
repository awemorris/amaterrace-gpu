/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top: the GPU IP.  An AXI slave for the GHCI registers (s_*, the low
 * 17 address bits of the window), one AXI master to memory (m_*) and a
 * level interrupt.  WS288 p002 has the CP stub, the blitter skeleton and
 * the MC (bitstream 1, "2D"); the other blocks are added here as they
 * come.  MC clients: 0 CP (debug port; later ring and fence), 1 BLT.
 *
 * One clock (gclk = mclk; the KC705's MIG clock comes with am_afifo in
 * p012) and one synchronous active-low reset, already synchronised to clk.
 * S_ID_W/S_LEN_W fit the host port (12/4 for the Zynq GP0, AXI3); the
 * master is AXI4-shaped (see am_axi_master for an AXI3 port).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_top #(
	parameter [31:0] GCLK_HZ = 32'd100000000,
	parameter S_ID_W = 12,
	parameter S_LEN_W = 4,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter DATA_W = 64
) (
	input wire clk,
	input wire rst_n,
	output wire irq,
	input wire mem_ready,

	input wire [16:0] s_awaddr,
	input wire [S_ID_W-1:0] s_awid,
	input wire s_awvalid,
	output wire s_awready,
	input wire [31:0] s_wdata,
	input wire [3:0] s_wstrb,
	input wire s_wlast,
	input wire s_wvalid,
	output wire s_wready,
	output wire [S_ID_W-1:0] s_bid,
	output wire [1:0] s_bresp,
	output wire s_bvalid,
	input wire s_bready,
	input wire [16:0] s_araddr,
	input wire [S_ID_W-1:0] s_arid,
	input wire [S_LEN_W-1:0] s_arlen,
	input wire s_arvalid,
	output wire s_arready,
	output wire [31:0] s_rdata,
	output wire [S_ID_W-1:0] s_rid,
	output wire [1:0] s_rresp,
	output wire s_rlast,
	output wire s_rvalid,
	input wire s_rready,

	output wire [31:0] m_awaddr,
	output wire [7:0] m_awlen,
	output wire [2:0] m_awsize,
	output wire [1:0] m_awburst,
	output wire [3:0] m_awcache,
	output wire [2:0] m_awprot,
	output wire m_awvalid,
	input wire m_awready,
	output wire [DATA_W-1:0] m_wdata,
	output wire [DATA_W/8-1:0] m_wstrb,
	output wire m_wlast,
	output wire m_wvalid,
	input wire m_wready,
	input wire [1:0] m_bresp,
	input wire m_bvalid,
	output wire m_bready,
	output wire [31:0] m_araddr,
	output wire [7:0] m_arlen,
	output wire [2:0] m_arsize,
	output wire [1:0] m_arburst,
	output wire [3:0] m_arcache,
	output wire [2:0] m_arprot,
	output wire m_arvalid,
	input wire m_arready,
	input wire [DATA_W-1:0] m_rdata,
	input wire [1:0] m_rresp,
	input wire m_rlast,
	input wire m_rvalid,
	output wire m_rready
);
	localparam NCLIENT = 2;
	localparam LA_W = 32 - LINE_SHIFT;
	localparam LINE_BITS = LINE_BYTES * 8;

	/* The register bus. */
	wire reg_wr;
	wire [16:0] reg_waddr;
	wire [31:0] reg_wdata;
	wire [3:0] reg_wstrb;
	wire reg_rd;
	wire [16:0] reg_raddr;
	wire [31:0] reg_rdata;

	am_axi_regs #(.ADDR_BITS(17), .ID_W(S_ID_W), .LEN_W(S_LEN_W)) regs (
		.clk(clk),
		.rst_n(rst_n),
		.s_awaddr(s_awaddr),
		.s_awid(s_awid),
		.s_awvalid(s_awvalid),
		.s_awready(s_awready),
		.s_wdata(s_wdata),
		.s_wstrb(s_wstrb),
		.s_wlast(s_wlast),
		.s_wvalid(s_wvalid),
		.s_wready(s_wready),
		.s_bid(s_bid),
		.s_bresp(s_bresp),
		.s_bvalid(s_bvalid),
		.s_bready(s_bready),
		.s_araddr(s_araddr),
		.s_arid(s_arid),
		.s_arlen(s_arlen),
		.s_arvalid(s_arvalid),
		.s_arready(s_arready),
		.s_rdata(s_rdata),
		.s_rid(s_rid),
		.s_rresp(s_rresp),
		.s_rlast(s_rlast),
		.s_rvalid(s_rvalid),
		.s_rready(s_rready),
		.reg_wr(reg_wr),
		.reg_waddr(reg_waddr),
		.reg_wdata(reg_wdata),
		.reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd),
		.reg_raddr(reg_raddr),
		.reg_rdata(reg_rdata)
	);

	/* The CP's controls. */
	wire core_rst_n;
	wire mc_quiesce;
	wire mc_flush;
	wire [31:0] aperture_base;
	wire [31:0] aperture_limit;
	wire mc_idle;
	wire mc_fault;
	wire [7:0] mc_fault_client;
	wire [31:0] mc_fault_addr;
	wire mc_fault_write;
	wire st_we;
	wire [8:0] st_idx;
	wire [31:0] st_wdata;
	wire blt_kick;
	wire blt_busy;
	wire blt_done;
	wire blt_error;
	wire [3:0] blt_error_kind;

	/* The AMB: one request port per client, the responses shared. */
	wire [NCLIENT-1:0] c_req_valid;
	wire [NCLIENT-1:0] c_req_ready;
	wire [NCLIENT-1:0] c_req_write;
	wire [NCLIENT*LA_W-1:0] c_req_line;
	wire [NCLIENT*LINE_BYTES-1:0] c_req_be;
	wire [NCLIENT*LINE_BITS-1:0] c_req_wdata;
	wire [NCLIENT*8-1:0] c_req_tag;
	wire [NCLIENT-1:0] rsp_valid;
	wire rsp_write;
	wire [7:0] rsp_tag;
	wire [LINE_BITS-1:0] rsp_rdata;
	wire rsp_error;

	atg_cp #(
		.ADDR_W(32),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.GCLK_HZ(GCLK_HZ)
	) cp (
		.clk(clk),
		.rst_n(rst_n),
		.reg_wr(reg_wr),
		.reg_waddr(reg_waddr),
		.reg_wdata(reg_wdata),
		.reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd),
		.reg_raddr(reg_raddr),
		.reg_rdata(reg_rdata),
		.irq(irq),
		.mem_ready(mem_ready),
		.core_rst_n(core_rst_n),
		.mc_quiesce(mc_quiesce),
		.mc_flush(mc_flush),
		.aperture_base(aperture_base),
		.aperture_limit(aperture_limit),
		.mc_idle(mc_idle),
		.mc_fault(mc_fault),
		.mc_fault_client(mc_fault_client),
		.mc_fault_addr(mc_fault_addr),
		.mc_fault_write(mc_fault_write),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.blt_kick(blt_kick),
		.blt_busy(blt_busy),
		.blt_error(blt_error),
		.blt_error_kind(blt_error_kind),
		.req_valid(c_req_valid[0]),
		.req_ready(c_req_ready[0]),
		.req_write(c_req_write[0]),
		.req_line(c_req_line[0*LA_W +: LA_W]),
		.req_be(c_req_be[0*LINE_BYTES +: LINE_BYTES]),
		.req_wdata(c_req_wdata[0*LINE_BITS +: LINE_BITS]),
		.req_tag(c_req_tag[0*8 +: 8]),
		.rsp_valid(rsp_valid[0]),
		.rsp_write(rsp_write),
		.rsp_rdata(rsp_rdata),
		.rsp_error(rsp_error)
	);

	atg_blt #(
		.ADDR_W(32),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT)
	) blt (
		.clk(clk),
		.rst_n(core_rst_n),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.kick(blt_kick),
		.busy(blt_busy),
		.done(blt_done),
		.error(blt_error),
		.error_kind(blt_error_kind),
		.req_valid(c_req_valid[1]),
		.req_ready(c_req_ready[1]),
		.req_write(c_req_write[1]),
		.req_line(c_req_line[1*LA_W +: LA_W]),
		.req_be(c_req_be[1*LINE_BYTES +: LINE_BYTES]),
		.req_wdata(c_req_wdata[1*LINE_BITS +: LINE_BITS]),
		.req_tag(c_req_tag[1*8 +: 8]),
		.rsp_valid(rsp_valid[1]),
		.rsp_write(rsp_write),
		.rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata),
		.rsp_error(rsp_error)
	);

	atg_mc #(
		.NCLIENT(NCLIENT),
		.HIGH_MASK(2'b01),
		.ADDR_W(32),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.DATA_W(DATA_W),
		.OUTSTANDING_LOG2(2)
	) mc (
		.clk(clk),
		.rst_n(rst_n),
		.c_req_valid(c_req_valid),
		.c_req_ready(c_req_ready),
		.c_req_write(c_req_write),
		.c_req_line(c_req_line),
		.c_req_be(c_req_be),
		.c_req_wdata(c_req_wdata),
		.c_req_tag(c_req_tag),
		.rsp_valid(rsp_valid),
		.rsp_write(rsp_write),
		.rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata),
		.rsp_error(rsp_error),
		.quiesce(mc_quiesce),
		.flush(mc_flush),
		.aperture_base(aperture_base),
		.aperture_limit(aperture_limit),
		.axi_idle(mc_idle),
		.fault(mc_fault),
		.fault_client(mc_fault_client),
		.fault_addr(mc_fault_addr),
		.fault_write(mc_fault_write),
		.m_awaddr(m_awaddr),
		.m_awlen(m_awlen),
		.m_awsize(m_awsize),
		.m_awburst(m_awburst),
		.m_awcache(m_awcache),
		.m_awprot(m_awprot),
		.m_awvalid(m_awvalid),
		.m_awready(m_awready),
		.m_wdata(m_wdata),
		.m_wstrb(m_wstrb),
		.m_wlast(m_wlast),
		.m_wvalid(m_wvalid),
		.m_wready(m_wready),
		.m_bresp(m_bresp),
		.m_bvalid(m_bvalid),
		.m_bready(m_bready),
		.m_araddr(m_araddr),
		.m_arlen(m_arlen),
		.m_arsize(m_arsize),
		.m_arburst(m_arburst),
		.m_arcache(m_arcache),
		.m_arprot(m_arprot),
		.m_arvalid(m_arvalid),
		.m_arready(m_arready),
		.m_rdata(m_rdata),
		.m_rresp(m_rresp),
		.m_rlast(m_rlast),
		.m_rvalid(m_rvalid),
		.m_rready(m_rready)
	);

	wire unused_ok = &{1'b0, blt_done};
endmodule

`default_nettype wire
