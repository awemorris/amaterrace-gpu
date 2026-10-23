/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc: the memory controller.  NCLIENT blocks share one AXI master
 * (am_axi_master) through the Amaterrace memory bus (AMB), a line-wide
 * request/response port per client:
 *
 *   request   c_req_valid/ready, c_req_write, c_req_line (the address
 *             without its low LINE_SHIFT bits), c_req_be (one bit per byte
 *             of the line), c_req_wdata, c_req_tag (8 bits, the client's)
 *   response  rsp_valid[client] for one cycle, with the shared rsp_write,
 *             rsp_tag, rsp_rdata and rsp_error; no back-pressure
 *
 * Every request gets one response (a write's after its BRESP).  A client's
 * reads are answered in order and so are its writes; a read is not ordered
 * against an earlier write, so a client that reads what it wrote waits for
 * the write's response first.  Client vectors are packed with client 0 in
 * the low bits.
 *
 * Arbitration: the clients whose bit is set in HIGH_MASK have a fixed
 * priority, lowest number first, over the others, which take turns
 * (round-robin).  At most one request is granted per cycle.
 *
 * Aperture: a request whose line is outside [aperture_base, aperture_limit)
 * (both line-aligned; the low bits are ignored) is not executed.  It gets
 * an error response and a one-cycle fault pulse with the client, address
 * and direction; nothing is granted while that response waits to go out.
 * That error response may come before the responses of the client's
 * earlier requests (the CP treats the fault as a device fault, quiesces
 * and waits for RESET).
 *
 * Quiesce: while quiesce is 1 nothing new is granted and axi_idle becomes 1
 * when every granted request is answered.  flush (with quiesce held)
 * returns the arbiter to its reset state; the MC has no queue of its own
 * to drop.  The AXI ports are those of am_axi_master.  The atomic port
 * (ATOM, design §4.1) comes with the SU.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc #(
	parameter NCLIENT = 2,
	parameter [NCLIENT-1:0] HIGH_MASK = {NCLIENT{1'b0}},
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter DATA_W = 64,
	parameter OUTSTANDING_LOG2 = 2
) (
	input wire clk,
	input wire rst_n,

	input wire [NCLIENT-1:0] c_req_valid,
	output wire [NCLIENT-1:0] c_req_ready,
	input wire [NCLIENT-1:0] c_req_write,
	input wire [NCLIENT*(ADDR_W-LINE_SHIFT)-1:0] c_req_line,
	input wire [NCLIENT*LINE_BYTES-1:0] c_req_be,
	input wire [NCLIENT*LINE_BYTES*8-1:0] c_req_wdata,
	input wire [NCLIENT*8-1:0] c_req_tag,

	output wire [NCLIENT-1:0] rsp_valid,
	output wire rsp_write,
	output wire [7:0] rsp_tag,
	output wire [LINE_BYTES*8-1:0] rsp_rdata,
	output wire rsp_error,

	input wire quiesce,
	input wire flush,
	input wire [ADDR_W-1:0] aperture_base,
	input wire [ADDR_W-1:0] aperture_limit,
	output wire axi_idle,
	output reg fault,
	output reg [7:0] fault_client,
	output reg [ADDR_W-1:0] fault_addr,
	output reg fault_write,

	output wire [ADDR_W-1:0] m_awaddr,
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
	output wire [ADDR_W-1:0] m_araddr,
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
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LINE_BITS = LINE_BYTES * 8;
	localparam CW = NCLIENT > 1 ? $clog2(NCLIENT) : 1;

	/* The request selected this cycle. */
	reg sel_any;
	reg [CW-1:0] sel;
	reg [CW-1:0] rr_next;	/* the first client to look at among the others */

	integer i;
	integer k;

	always @(*) begin
		sel_any = 1'b0;
		sel = {CW{1'b0}};
		for (i = 0; i < NCLIENT; i = i + 1) begin
			if (!sel_any && HIGH_MASK[i] && c_req_valid[i]) begin
				sel_any = 1'b1;
				sel = i[CW-1:0];
			end
		end
		for (i = 0; i < NCLIENT; i = i + 1) begin
			k = {{(32 - CW){1'b0}}, rr_next} + i;
			if (k >= NCLIENT)
				k = k - NCLIENT;
			if (!sel_any && !HIGH_MASK[k] && c_req_valid[k]) begin
				sel_any = 1'b1;
				sel = k[CW-1:0];
			end
		end
	end

	wire sel_write = c_req_write[sel];
	wire [LA_W-1:0] sel_line = c_req_line[sel*LA_W +: LA_W];
	wire [LINE_BYTES-1:0] sel_be = c_req_be[sel*LINE_BYTES +: LINE_BYTES];
	wire [LINE_BITS-1:0] sel_wdata = c_req_wdata[sel*LINE_BITS +: LINE_BITS];
	wire [7:0] sel_tag = c_req_tag[sel*8 +: 8];

	wire [LA_W-1:0] ap_base = aperture_base[ADDR_W-1:LINE_SHIFT];
	wire [LA_W-1:0] ap_limit = aperture_limit[ADDR_W-1:LINE_SHIFT];
	wire sel_inside = sel_line >= ap_base && sel_line < ap_limit;

	/* The error response of a refused request. */
	reg err_v;
	reg [CW-1:0] err_client;
	reg [7:0] err_tag;
	reg err_write;

	wire m_req_ready;
	wire m_rsp_valid;
	wire m_rsp_write;
	wire [15:0] m_rsp_user;
	wire [LINE_BITS-1:0] m_rsp_rdata;
	wire m_rsp_error;
	wire m_idle;

	wire may_grant = sel_any && !quiesce && !err_v;
	wire grant_ok = may_grant && sel_inside && m_req_ready;
	wire grant_bad = may_grant && !sel_inside;
	wire granted = grant_ok || grant_bad;

	wire [7:0] sel_client8 = {{(8 - CW){1'b0}}, sel};
	assign c_req_ready = granted ? ({{(NCLIENT - 1){1'b0}}, 1'b1} << sel) : {NCLIENT{1'b0}};

	/* Responses: the AXI master's first, then a refused request's. */
	wire err_out = err_v && !m_rsp_valid;
	wire [CW-1:0] rsp_client = m_rsp_valid ? m_rsp_user[8+CW-1:8] : err_client;
	wire rsp_any = m_rsp_valid || err_out;

	assign rsp_valid = rsp_any ? ({{(NCLIENT - 1){1'b0}}, 1'b1} << rsp_client) : {NCLIENT{1'b0}};
	assign rsp_write = m_rsp_valid ? m_rsp_write : err_write;
	assign rsp_tag = m_rsp_valid ? m_rsp_user[7:0] : err_tag;
	assign rsp_rdata = m_rsp_rdata;
	assign rsp_error = m_rsp_valid ? m_rsp_error : 1'b1;

	assign axi_idle = m_idle && !err_v;

	always @(posedge clk) begin
		if (!rst_n || flush) begin
			rr_next <= {CW{1'b0}};
			err_v <= 1'b0;
			err_client <= {CW{1'b0}};
			err_tag <= 8'd0;
			err_write <= 1'b0;
			fault <= 1'b0;
			fault_client <= 8'd0;
			fault_addr <= {ADDR_W{1'b0}};
			fault_write <= 1'b0;
		end else begin
			fault <= 1'b0;
			if (granted && !HIGH_MASK[sel])
				rr_next <= {{(32 - CW){1'b0}}, sel} == NCLIENT - 1 ? {CW{1'b0}} : sel + 1'b1;
			if (grant_bad) begin
				err_v <= 1'b1;
				err_client <= sel;
				err_tag <= sel_tag;
				err_write <= sel_write;
				fault <= 1'b1;
				fault_client <= sel_client8;
				fault_addr <= {sel_line, {LINE_SHIFT{1'b0}}};
				fault_write <= sel_write;
			end else if (err_out) begin
				err_v <= 1'b0;
			end
		end
	end

	am_axi_master #(
		.ADDR_W(ADDR_W),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.DATA_W(DATA_W),
		.UW(16),
		.OUTSTANDING_LOG2(OUTSTANDING_LOG2)
	) axi (
		.clk(clk),
		.rst_n(rst_n),
		.halt(quiesce),
		.idle(m_idle),
		.req_valid(may_grant && sel_inside),
		.req_ready(m_req_ready),
		.req_write(sel_write),
		.req_line(sel_line),
		.req_be(sel_be),
		.req_wdata(sel_wdata),
		.req_user({sel_client8, sel_tag}),
		.rsp_valid(m_rsp_valid),
		.rsp_write(m_rsp_write),
		.rsp_user(m_rsp_user),
		.rsp_rdata(m_rsp_rdata),
		.rsp_error(m_rsp_error),
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

	/*
	 * WS288 p023 scaffold: the arbiter and the aperture check as the
	 * modules of design §7.6 (spec/gpu/mc/atg_mc_arb.md, atg_mc_aper.md).
	 * They are stubs fed with the real signals; the inline logic above
	 * still decides.  The split replaces the inline code with them.
	 */
	wire s_gnt_valid;
	wire [CW-1:0] s_gnt_idx;
	wire s_inside;

	atg_mc_arb #(.NCLIENT(NCLIENT), .CW(CW), .HIGH_MASK(HIGH_MASK)) s_arb (
		.clk(clk), .rst_n(rst_n), .req(c_req_valid), .hold(quiesce || err_v),
		.gnt_valid(s_gnt_valid), .gnt_idx(s_gnt_idx), .take(granted), .flush(flush)
	);

	atg_mc_aper #(.ADDR_W(ADDR_W), .LINE_SHIFT(LINE_SHIFT)) s_aper (
		.line(sel_line), .base(aperture_base), .limit(aperture_limit), .ok(s_inside)
	);

	wire unused_scaffold = &{1'b0, s_gnt_valid, s_gnt_idx, s_inside};

	wire unused_ok = &{1'b0, m_rsp_user[15:8+CW], aperture_base[LINE_SHIFT-1:0],
		aperture_limit[LINE_SHIFT-1:0]};
endmodule

`default_nettype wire
