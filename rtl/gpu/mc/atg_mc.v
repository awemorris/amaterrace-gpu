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
 *   response  rsp_valid[client] for one cycle with that client's
 *             rsp_write, rsp_tag, rsp_rdata and rsp_error; no back-pressure
 *
 * Every request gets one response (a write's after its BRESP).  A client's
 * reads are answered in order and so are its writes; a read is not ordered
 * against an earlier write, so a client that reads what it wrote waits for
 * the write's response first.  Client vectors are packed with client 0 in
 * the low bits.
 *
 * The clients reach the root through a tree of 2-way routers (atg_mc_tree:
 * am_amb_to_rt leaves, atg_rt routers, design §4.1; WS288 p023 after the
 * user's request of 2026-10-23), one register stage per hop each way.  A
 * request is a header flit and, for a write, a data flit; a response is one
 * flit.  The clients of HIGH_MASK send with the priority bit, which wins at
 * every router; the others take turns at each router.  ROOT_CLIENT (the
 * KC705's DC; -1 for none) is one hop from the root.  Addresses travel as
 * VRAM_AW-bit window offsets; the root adds VRAM_BASE.
 *
 * The root: a request (assembled from its flits) whose line is outside
 * [aperture_base, aperture_limit) (atg_mc_aper; both line-aligned), or
 * outside the VRAM window, is not executed.  It gets an error response and
 * a one-cycle fault pulse with the client, address and direction; nothing
 * is granted while that response waits to go out.  That error response may
 * come before the responses of the client's earlier requests (the CP treats
 * the fault as a device fault, quiesces and waits for RESET).
 *
 * Quiesce: while quiesce is 1 the clients' leaves start no new packet
 * (except those of QUIESCE_EXEMPT: the CP, whose debug port must work in
 * HALTED and FAULTED); the packets already in the tree are still granted,
 * and axi_idle becomes 1 when no request is in the tree or the root, every
 * granted one is answered and its response has left the tree.  flush (with
 * quiesce held) empties the tree and the root (the CP's RESET resets the
 * clients in the same cycle).  The AXI ports are those of am_axi_master.
 * The atomic unit (atg_mc_atom) is a client of its own.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc #(
	parameter NCLIENT = 2,
	parameter [NCLIENT-1:0] HIGH_MASK = {NCLIENT{1'b0}},
	parameter [NCLIENT-1:0] QUIESCE_EXEMPT = {NCLIENT{1'b0}},	/* clients that quiesce does not hold */
	parameter ROOT_CLIENT = -1,	/* the client one hop from the root, or -1 */
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter DATA_W = 64,
	parameter OUTSTANDING_LOG2 = 2,
	parameter VRAM_AW = 32,	/* address bits carried in the tree */
	parameter [ADDR_W-1:0] VRAM_BASE = {ADDR_W{1'b0}}
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
	output wire [NCLIENT-1:0] rsp_write,
	output wire [NCLIENT*8-1:0] rsp_tag,
	output wire [NCLIENT*LINE_BYTES*8-1:0] rsp_rdata,
	output wire [NCLIENT-1:0] rsp_error,

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
	localparam HAS_ROOT = (ROOT_CLIENT >= 0 && ROOT_CLIENT < NCLIENT) ? 1 : 0;
	localparam NT = NCLIENT - HAS_ROOT;
	localparam TREE_L = NT > 1 ? $clog2(NT) : 0;
	localparam RW = TREE_L + HAS_ROOT > 0 ? TREE_L + HAS_ROOT : 1;
	localparam LAW = VRAM_AW - LINE_SHIFT;
	localparam HW = 20 + RW + LAW + LINE_BYTES;	/* header bits used */
	localparam RFW = LINE_BITS + 10 + RW;
	localparam UW = 16 + RW;
	localparam RC = HAS_ROOT != 0 ? ROOT_CLIENT : 0;

	/* The tree. */
	wire t_req_valid, t_req_ready, t_req_last;
	wire [LINE_BITS-1:0] t_req_data;
	wire t_rsp_valid, t_rsp_ready, t_rsp_idle;
	wire [RFW-1:0] t_rsp_data;

	atg_mc_tree #(
		.NCLIENT(NCLIENT), .HIGH_MASK(HIGH_MASK), .HAS_ROOT(HAS_ROOT), .ROOT_CLIENT(RC),
		.TREE_L(TREE_L), .RW(RW), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .VRAM_AW(VRAM_AW), .VRAM_BASE(VRAM_BASE)
	) tree (
		.clk(clk), .rst_n(rst_n), .flush(flush), .hold({NCLIENT{quiesce}} & ~QUIESCE_EXEMPT),
		.c_req_valid(c_req_valid), .c_req_ready(c_req_ready), .c_req_write(c_req_write),
		.c_req_line(c_req_line), .c_req_be(c_req_be), .c_req_wdata(c_req_wdata),
		.c_req_tag(c_req_tag),
		.c_rsp_valid(rsp_valid), .c_rsp_write(rsp_write), .c_rsp_tag(rsp_tag),
		.c_rsp_rdata(rsp_rdata), .c_rsp_error(rsp_error),
		.r_req_valid(t_req_valid), .r_req_ready(t_req_ready), .r_req_data(t_req_data),
		.r_req_last(t_req_last),
		.r_rsp_valid(t_rsp_valid), .r_rsp_ready(t_rsp_ready), .r_rsp_data(t_rsp_data),
		.rsp_idle(t_rsp_idle)
	);

	/*
	 * The request being assembled at the root: the header flit, then a
	 * write's data flit.  a_hdr: a write's header is in, its data is not;
	 * a_full: the request is complete and offered to the grant.
	 */
	reg a_hdr;
	reg a_full;
	reg [LINE_BITS-1:0] a_head;
	reg [LINE_BITS-1:0] a_data;

	wire sel_write = a_head[1];
	wire sel_outside = a_head[2];
	wire [7:0] sel_tag = a_head[11:4];
	wire [7:0] sel_client = a_head[19:12];
	wire [RW-1:0] sel_route = a_head[20 +: RW];
	wire [LAW-1:0] sel_off = a_head[20+RW +: LAW];
	wire [LINE_BYTES-1:0] sel_be = a_head[20+RW+LAW +: LINE_BYTES];
	wire [LA_W-1:0] sel_line;

	generate
	if (VRAM_AW < ADDR_W) begin : g_window
		assign sel_line = {VRAM_BASE[ADDR_W-1:VRAM_AW], sel_off};
		wire unused_base = &{1'b0, VRAM_BASE[VRAM_AW-1:0]};
	end else begin : g_flat
		assign sel_line = sel_off;
		wire unused_base = &{1'b0, VRAM_BASE};
	end
	endgenerate

	wire ap_ok;

	atg_mc_aper #(.ADDR_W(ADDR_W), .LINE_SHIFT(LINE_SHIFT)) aper (
		.line(sel_line), .base(aperture_base), .limit(aperture_limit), .ok(ap_ok)
	);

	wire sel_inside = ap_ok && !sel_outside;

	/* The error response of a refused request. */
	reg err_v;
	reg [RW-1:0] err_route;
	reg [7:0] err_tag;
	reg err_write;

	wire m_req_ready;
	wire m_rsp_valid;
	wire m_rsp_write;
	wire [UW-1:0] m_rsp_user;
	wire [LINE_BITS-1:0] m_rsp_rdata;
	wire m_rsp_error;
	wire m_idle;

	/*
	 * Quiesce holds new packets at the clients' leaves (except
	 * QUIESCE_EXEMPT's); what is already in the tree is granted (drained).
	 * pend counts the requests taken from the clients and not yet granted.
	 */
	wire may_grant = a_full && !err_v;
	wire grant_ok = may_grant && sel_inside && m_req_ready;
	wire grant_bad = may_grant && !sel_inside;
	wire granted = grant_ok || grant_bad;

	/* A flit is taken when the buffer has room for it. */
	assign t_req_ready = !a_full || granted;
	wire t_take = t_req_valid && t_req_ready;

	always @(posedge clk) begin
		if (!rst_n || flush) begin
			a_hdr <= 1'b0;
			a_full <= 1'b0;
			a_head <= {LINE_BITS{1'b0}};
			a_data <= {LINE_BITS{1'b0}};
		end else begin
			if (granted)
				a_full <= 1'b0;
			if (t_take) begin
				if (!a_hdr) begin
					a_head <= t_req_data;
					a_hdr <= !t_req_last;
					a_full <= t_req_last;
				end else begin
					a_data <= t_req_data;
					a_hdr <= 1'b0;
					a_full <= 1'b1;
				end
			end
		end
	end

	/*
	 * Responses into the tree: the AXI master's first, then a refused
	 * request's.  The tree always takes a response (its leaves always do,
	 * and a hop has room whenever the next one has), which the AXI master's
	 * responses need: they cannot wait.
	 */
	wire err_out = err_v && !m_rsp_valid && t_rsp_ready;
	wire [RW-1:0] rsp_route = m_rsp_valid ? m_rsp_user[16 +: RW] : err_route;

	assign t_rsp_valid = m_rsp_valid || err_out;
	assign t_rsp_data = {m_rsp_rdata, rsp_route, m_rsp_valid ? m_rsp_user[7:0] : err_tag,
		m_rsp_valid ? m_rsp_error : 1'b1, m_rsp_valid ? m_rsp_write : err_write};

	reg [7:0] pend;
	integer pk;
	reg [7:0] taken;

	always @(*) begin
		taken = 8'd0;
		for (pk = 0; pk < NCLIENT; pk = pk + 1)
			taken = taken + {7'd0, c_req_valid[pk] && c_req_ready[pk]};
	end

	always @(posedge clk) begin
		if (!rst_n || flush)
			pend <= 8'd0;
		else
			pend <= pend + taken - {7'd0, granted};
	end

	assign axi_idle = m_idle && !err_v && t_rsp_idle && pend == 8'd0;

	always @(posedge clk) begin
		if (!rst_n || flush) begin
			err_v <= 1'b0;
			err_route <= {RW{1'b0}};
			err_tag <= 8'd0;
			err_write <= 1'b0;
			fault <= 1'b0;
			fault_client <= 8'd0;
			fault_addr <= {ADDR_W{1'b0}};
			fault_write <= 1'b0;
		end else begin
			fault <= 1'b0;
			if (grant_bad) begin
				err_v <= 1'b1;
				err_route <= sel_route;
				err_tag <= sel_tag;
				err_write <= sel_write;
				fault <= 1'b1;
				fault_client <= sel_client;
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
		.UW(UW),
		.OUTSTANDING_LOG2(OUTSTANDING_LOG2)
	) axi (
		.clk(clk),
		.rst_n(rst_n),
		.halt(1'b0),
		.idle(m_idle),
		.req_valid(may_grant && sel_inside),
		.req_ready(m_req_ready),
		.req_write(sel_write),
		.req_line(sel_line),
		.req_be(sel_be),
		.req_wdata(a_data),
		.req_user({sel_route, sel_client, sel_tag}),
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

	wire unused_ok = &{1'b0, a_head[3], a_head[0], m_rsp_user[15:8],
		a_head[LINE_BITS-1:HW]};
endmodule

`default_nettype wire
