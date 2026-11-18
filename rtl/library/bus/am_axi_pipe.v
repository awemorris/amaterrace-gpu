/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_axi_pipe: AXI4 channel pipeline register slice.
 * Inserts skid buffers (am_skid) to break combinational timing paths
 * across long distances while preserving 100% sustained throughput.
 *
 * Parameters control which channels have register slices enabled:
 *   PIPE_AW: Skid buffer on AW channel
 *   PIPE_W:  Skid buffer on W channel
 *   PIPE_B:  Skid buffer on B channel
 *   PIPE_AR: Skid buffer on AR channel
 *   PIPE_R:  Skid buffer on R channel
 */

`timescale 1ns / 1ps
`default_nettype none

module am_axi_pipe #(
	parameter A_W = 64,
	parameter D_W = 512,
	parameter ID_W = 1,
	parameter PIPE_AW = 0,
	parameter PIPE_W  = 0,
	parameter PIPE_B  = 0,
	parameter PIPE_AR = 0,
	parameter PIPE_R  = 1
) (
	input wire clk,
	input wire rst_n,

	/* Slave interface (from upstream) */
	input wire [ID_W-1:0] s_awid,
	input wire [A_W-1:0]  s_awaddr,
	input wire [7:0]      s_awlen,
	input wire [2:0]      s_awsize,
	input wire [1:0]      s_awburst,
	input wire [3:0]      s_awcache,
	input wire [2:0]      s_awprot,
	input wire            s_awvalid,
	output wire           s_awready,

	input wire [D_W-1:0]   s_wdata,
	input wire [D_W/8-1:0] s_wstrb,
	input wire             s_wlast,
	input wire             s_wvalid,
	output wire            s_wready,

	output wire [ID_W-1:0] s_bid,
	output wire [1:0]      s_bresp,
	output wire            s_bvalid,
	input wire             s_bready,

	input wire [ID_W-1:0] s_arid,
	input wire [A_W-1:0]  s_araddr,
	input wire [7:0]      s_arlen,
	input wire [2:0]      s_arsize,
	input wire [1:0]      s_arburst,
	input wire [3:0]      s_arcache,
	input wire [2:0]      s_arprot,
	input wire            s_arvalid,
	output wire           s_arready,

	output wire [ID_W-1:0] s_rid,
	output wire [D_W-1:0]  s_rdata,
	output wire [1:0]      s_rresp,
	output wire            s_rlast,
	output wire            s_rvalid,
	input wire             s_rready,

	/* Master interface (to downstream) */
	output wire [ID_W-1:0] m_awid,
	output wire [A_W-1:0]  m_awaddr,
	output wire [7:0]      m_awlen,
	output wire [2:0]      m_awsize,
	output wire [1:0]      m_awburst,
	output wire [3:0]      m_awcache,
	output wire [2:0]      m_awprot,
	output wire            m_awvalid,
	input wire             m_awready,

	output wire [D_W-1:0]   m_wdata,
	output wire [D_W/8-1:0] m_wstrb,
	output wire             m_wlast,
	output wire             m_wvalid,
	input wire              m_wready,

	input wire [ID_W-1:0] m_bid,
	input wire [1:0]      m_bresp,
	input wire            m_bvalid,
	output wire           m_bready,

	output wire [ID_W-1:0] m_arid,
	output wire [A_W-1:0]  m_araddr,
	output wire [7:0]      m_arlen,
	output wire [2:0]      m_arsize,
	output wire [1:0]      m_arburst,
	output wire [3:0]      m_arcache,
	output wire [2:0]      m_arprot,
	output wire            m_arvalid,
	input wire             m_arready,

	input wire [ID_W-1:0] m_rid,
	input wire [D_W-1:0]  m_rdata,
	input wire [1:0]      m_rresp,
	input wire            m_rlast,
	input wire            m_rvalid,
	output wire           m_rready
);
	/* AW Channel */
	localparam AW_PAYLOAD_W = ID_W + A_W + 8 + 3 + 2 + 4 + 3;
	generate
		if (PIPE_AW) begin : g_pipe_aw
			wire [AW_PAYLOAD_W-1:0] in_payload = {s_awid, s_awaddr, s_awlen, s_awsize, s_awburst, s_awcache, s_awprot};
			wire [AW_PAYLOAD_W-1:0] out_payload;
			am_skid #(.WIDTH(AW_PAYLOAD_W)) u_skid_aw (
				.clk(clk), .rst_n(rst_n),
				.in_valid(s_awvalid), .in_ready(s_awready), .in_data(in_payload),
				.out_valid(m_awvalid), .out_ready(m_awready), .out_data(out_payload)
			);
			assign {m_awid, m_awaddr, m_awlen, m_awsize, m_awburst, m_awcache, m_awprot} = out_payload;
		end else begin : g_pass_aw
			assign m_awid    = s_awid;
			assign m_awaddr  = s_awaddr;
			assign m_awlen   = s_awlen;
			assign m_awsize  = s_awsize;
			assign m_awburst = s_awburst;
			assign m_awcache = s_awcache;
			assign m_awprot  = s_awprot;
			assign m_awvalid = s_awvalid;
			assign s_awready = m_awready;
		end
	endgenerate

	/* W Channel */
	localparam W_PAYLOAD_W = D_W + (D_W / 8) + 1;
	generate
		if (PIPE_W) begin : g_pipe_w
			wire [W_PAYLOAD_W-1:0] in_payload = {s_wdata, s_wstrb, s_wlast};
			wire [W_PAYLOAD_W-1:0] out_payload;
			am_skid #(.WIDTH(W_PAYLOAD_W)) u_skid_w (
				.clk(clk), .rst_n(rst_n),
				.in_valid(s_wvalid), .in_ready(s_wready), .in_data(in_payload),
				.out_valid(m_wvalid), .out_ready(m_wready), .out_data(out_payload)
			);
			assign {m_wdata, m_wstrb, m_wlast} = out_payload;
		end else begin : g_pass_w
			assign m_wdata  = s_wdata;
			assign m_wstrb  = s_wstrb;
			assign m_wlast  = s_wlast;
			assign m_wvalid = s_wvalid;
			assign s_wready = m_wready;
		end
	endgenerate

	/* B Channel (Master -> Slave) */
	localparam B_PAYLOAD_W = ID_W + 2;
	generate
		if (PIPE_B) begin : g_pipe_b
			wire [B_PAYLOAD_W-1:0] in_payload = {m_bid, m_bresp};
			wire [B_PAYLOAD_W-1:0] out_payload;
			am_skid #(.WIDTH(B_PAYLOAD_W)) u_skid_b (
				.clk(clk), .rst_n(rst_n),
				.in_valid(m_bvalid), .in_ready(m_bready), .in_data(in_payload),
				.out_valid(s_bvalid), .out_ready(s_bready), .out_data(out_payload)
			);
			assign {s_bid, s_bresp} = out_payload;
		end else begin : g_pass_b
			assign s_bid    = m_bid;
			assign s_bresp  = m_bresp;
			assign s_bvalid = m_bvalid;
			assign m_bready = s_bready;
		end
	endgenerate

	/* AR Channel */
	localparam AR_PAYLOAD_W = ID_W + A_W + 8 + 3 + 2 + 4 + 3;
	generate
		if (PIPE_AR) begin : g_pipe_ar
			wire [AR_PAYLOAD_W-1:0] in_payload = {s_arid, s_araddr, s_arlen, s_arsize, s_arburst, s_arcache, s_arprot};
			wire [AR_PAYLOAD_W-1:0] out_payload;
			am_skid #(.WIDTH(AR_PAYLOAD_W)) u_skid_ar (
				.clk(clk), .rst_n(rst_n),
				.in_valid(s_arvalid), .in_ready(s_arready), .in_data(in_payload),
				.out_valid(m_arvalid), .out_ready(m_arready), .out_data(out_payload)
			);
			assign {m_arid, m_araddr, m_arlen, m_arsize, m_arburst, m_arcache, m_arprot} = out_payload;
		end else begin : g_pass_ar
			assign m_arid    = s_arid;
			assign m_araddr  = s_araddr;
			assign m_arlen   = s_arlen;
			assign m_arsize  = s_arsize;
			assign m_arburst = s_arburst;
			assign m_arcache = s_arcache;
			assign m_arprot  = s_arprot;
			assign m_arvalid = s_arvalid;
			assign s_arready = m_arready;
		end
	endgenerate

	/* R Channel (Master -> Slave) */
	localparam R_PAYLOAD_W = ID_W + D_W + 2 + 1;
	generate
		if (PIPE_R) begin : g_pipe_r
			wire [R_PAYLOAD_W-1:0] in_payload = {m_rid, m_rdata, m_rresp, m_rlast};
			wire [R_PAYLOAD_W-1:0] out_payload;
			am_skid #(.WIDTH(R_PAYLOAD_W)) u_skid_r (
				.clk(clk), .rst_n(rst_n),
				.in_valid(m_rvalid), .in_ready(m_rready), .in_data(in_payload),
				.out_valid(s_rvalid), .out_ready(s_rready), .out_data(out_payload)
			);
			assign {s_rid, s_rdata, s_rresp, s_rlast} = out_payload;
		end else begin : g_pass_r
			assign s_rid    = m_rid;
			assign s_rdata  = m_rdata;
			assign s_rresp  = m_rresp;
			assign s_rlast  = m_rlast;
			assign s_rvalid = m_rvalid;
			assign m_rready = s_rready;
		end
	endgenerate

endmodule

`default_nettype wire
