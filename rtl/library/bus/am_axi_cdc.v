/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_axi_cdc: an AXI4 slave in s_clk passed on as an AXI4 master in m_clk
 * (the KC705's PCIe BAR0 into the GPU's register port).  The five
 * channels each cross through an am_afifo of 2^DEPTH_LOG2 entries: AW
 * {addr, id}, W {data, strb, last}, B {id, resp}, AR {addr, id, len}, R
 * {data, id, resp, last} (the signals of atg_top's s_* port; bursts,
 * outstanding transactions and their order pass through unchanged).
 *
 * Resets: each side's reset input also resets the other side (through
 * am_sync), so both FIFOs' sides are empty together; each reset input is
 * held for at least 4 cycles of the slower clock.  A transaction in a FIFO
 * at a reset is lost (the PCIe link reset, or the GPU's: the host's access
 * then times out).
 * See spec/library/bus/am_axi_cdc.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_axi_cdc #(
	parameter A_W = 17,	/* address */
	parameter ID_W = 4,
	parameter LEN_W = 8,
	parameter D_W = 32,
	parameter DEPTH_LOG2 = 2
) (
	/* The slave side */
	input wire s_clk,
	input wire s_rst_n,
	input wire [A_W-1:0] s_awaddr,
	input wire [ID_W-1:0] s_awid,
	input wire s_awvalid,
	output wire s_awready,
	input wire [D_W-1:0] s_wdata,
	input wire [D_W/8-1:0] s_wstrb,
	input wire s_wlast,
	input wire s_wvalid,
	output wire s_wready,
	output wire [ID_W-1:0] s_bid,
	output wire [1:0] s_bresp,
	output wire s_bvalid,
	input wire s_bready,
	input wire [A_W-1:0] s_araddr,
	input wire [ID_W-1:0] s_arid,
	input wire [LEN_W-1:0] s_arlen,
	input wire s_arvalid,
	output wire s_arready,
	output wire [D_W-1:0] s_rdata,
	output wire [ID_W-1:0] s_rid,
	output wire [1:0] s_rresp,
	output wire s_rlast,
	output wire s_rvalid,
	input wire s_rready,
	/* The master side */
	input wire m_clk,
	input wire m_rst_n,
	output wire [A_W-1:0] m_awaddr,
	output wire [ID_W-1:0] m_awid,
	output wire m_awvalid,
	input wire m_awready,
	output wire [D_W-1:0] m_wdata,
	output wire [D_W/8-1:0] m_wstrb,
	output wire m_wlast,
	output wire m_wvalid,
	input wire m_wready,
	input wire [ID_W-1:0] m_bid,
	input wire [1:0] m_bresp,
	input wire m_bvalid,
	output wire m_bready,
	output wire [A_W-1:0] m_araddr,
	output wire [ID_W-1:0] m_arid,
	output wire [LEN_W-1:0] m_arlen,
	output wire m_arvalid,
	input wire m_arready,
	input wire [D_W-1:0] m_rdata,
	input wire [ID_W-1:0] m_rid,
	input wire [1:0] m_rresp,
	input wire m_rlast,
	input wire m_rvalid,
	output wire m_rready
);
	/* Each side is in reset while either input is. */
	wire m_in_s, s_in_m;

	am_sync s_of_m (.clk(s_clk), .rst_n(s_rst_n), .d(m_rst_n), .q(m_in_s));
	am_sync m_of_s (.clk(m_clk), .rst_n(m_rst_n), .d(s_rst_n), .q(s_in_m));

	wire s_rn = s_rst_n && m_in_s;
	wire m_rn = m_rst_n && s_in_m;

	am_afifo #(.W(A_W + ID_W), .DEPTH_LOG2(DEPTH_LOG2)) aw (
		.w_clk(s_clk), .w_rst_n(s_rn), .w_valid(s_awvalid), .w_ready(s_awready),
		.w_data({s_awaddr, s_awid}),
		.r_clk(m_clk), .r_rst_n(m_rn), .r_valid(m_awvalid), .r_ready(m_awready),
		.r_data({m_awaddr, m_awid})
	);
	am_afifo #(.W(D_W + D_W/8 + 1), .DEPTH_LOG2(DEPTH_LOG2)) w (
		.w_clk(s_clk), .w_rst_n(s_rn), .w_valid(s_wvalid), .w_ready(s_wready),
		.w_data({s_wdata, s_wstrb, s_wlast}),
		.r_clk(m_clk), .r_rst_n(m_rn), .r_valid(m_wvalid), .r_ready(m_wready),
		.r_data({m_wdata, m_wstrb, m_wlast})
	);
	am_afifo #(.W(ID_W + 2), .DEPTH_LOG2(DEPTH_LOG2)) b (
		.w_clk(m_clk), .w_rst_n(m_rn), .w_valid(m_bvalid), .w_ready(m_bready),
		.w_data({m_bid, m_bresp}),
		.r_clk(s_clk), .r_rst_n(s_rn), .r_valid(s_bvalid), .r_ready(s_bready),
		.r_data({s_bid, s_bresp})
	);
	am_afifo #(.W(A_W + ID_W + LEN_W), .DEPTH_LOG2(DEPTH_LOG2)) ar (
		.w_clk(s_clk), .w_rst_n(s_rn), .w_valid(s_arvalid), .w_ready(s_arready),
		.w_data({s_araddr, s_arid, s_arlen}),
		.r_clk(m_clk), .r_rst_n(m_rn), .r_valid(m_arvalid), .r_ready(m_arready),
		.r_data({m_araddr, m_arid, m_arlen})
	);
	am_afifo #(.W(D_W + ID_W + 3), .DEPTH_LOG2(DEPTH_LOG2)) r (
		.w_clk(m_clk), .w_rst_n(m_rn), .w_valid(m_rvalid), .w_ready(m_rready),
		.w_data({m_rdata, m_rid, m_rresp, m_rlast}),
		.r_clk(s_clk), .r_rst_n(s_rn), .r_valid(s_rvalid), .r_ready(s_rready),
		.r_data({s_rdata, s_rid, s_rresp, s_rlast})
	);
endmodule

`default_nettype wire
