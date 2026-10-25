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
 * am_amb_to_rt leaves, atg_rt routers, design §4.1), one register stage
 * per hop each way.  A
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
 *
 * Session protection (HAS_PROT, spec/gpu/mc/atg_mc_prot.md, docs/ghci.md
 * section 11.6): each client gives its requests chk, tbl and a 6-bit slot
 * with the request (held like the rest); the root's grant (atg_mc_prot)
 * checks those with chk against the protection table at prot_tbase and
 * the grant CAM, and refuses a write into the table without tbl.  A
 * refusal for protection pulses fault with fault_prot and fault_slot; a
 * table read with an AXI error refuses its request with fault_mem.  With
 * HAS_PROT, ROOT_CLIENT (the DC) has its own entry at the root and is not
 * held by a stall of the tree.  chk_idle: no request with chk is in the
 * tree or the root.  unit_idle: every request that UNIT_MASK's clients
 * gave the MC has been answered (counted from the leaf to the response).
 * A refused read returns zeros.
 *
 * ROOT_KEEP (with ROOT_CLIENT; the KC705's DC, design §18.2): ROOT_CLIENT
 * has its own entry at the root (as with HAS_PROT) that flush does not
 * empty, and axi_idle does not wait for its requests (it counts the other
 * clients' requests from the leaf to the root, those the root granted to
 * the AXI master until its response, and a refusal's response).  The caller
 * puts it in QUIESCE_EXEMPT: its scan-out reads go on through HALTED,
 * FAULTED and the GPU's reset.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc #(
	parameter NCLIENT = 2,
	parameter [NCLIENT-1:0] HIGH_MASK = {NCLIENT{1'b0}},
	parameter [NCLIENT-1:0] QUIESCE_EXEMPT = {NCLIENT{1'b0}},	/* clients that quiesce does not hold */
	parameter ROOT_CLIENT = -1,	/* the client one hop from the root, or -1 */
	parameter ROOT_KEEP = 0,	/* 1: flush and axi_idle leave ROOT_CLIENT alone */
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter DATA_W = 64,
	parameter OUTSTANDING_LOG2 = 2,
	parameter VRAM_AW = 32,	/* address bits carried in the tree */
	parameter [ADDR_W-1:0] VRAM_BASE = {ADDR_W{1'b0}},
	parameter [NCLIENT-1:0] UNIT_MASK = {NCLIENT{1'b0}},	/* clients counted by unit_idle */
	parameter HAS_PROT = 0,	/* session protection */
	parameter [NCLIENT-1:0] RMW_MASK = {NCLIENT{1'b0}},	/* reads judged as writes (atomics) */
	parameter PROT_PLB = 4,	/* PLB lines */
	parameter PROT_PLB_W = 2,	/* clog2(PROT_PLB) */
	parameter PROT_GRANTS = 8,	/* grant CAM entries */
	parameter PROT_GIDX_W = 3	/* clog2(PROT_GRANTS) */
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
	input wire [NCLIENT-1:0] c_req_chk,
	input wire [NCLIENT-1:0] c_req_tbl,
	input wire [NCLIENT*6-1:0] c_req_slot,

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
	output reg fault_prot,	/* the refusal was for protection (FAULT_INFO[9]) */
	output reg [5:0] fault_slot,
	output reg fault_mem,	/* a protection table read had an AXI error (kind 5) */
	output wire chk_idle,
	output wire unit_idle,

	/* Session protection, from the CP. */
	input wire [ADDR_W-1:0] prot_tbase,
	input wire prot_inv_valid,
	input wire [ADDR_W-13:0] prot_inv_g,
	input wire [31:0] prot_inv_n,
	output wire prot_inv_pending,
	input wire prot_gw_valid,
	input wire [PROT_GIDX_W-1:0] prot_gw_idx,
	input wire [49:0] prot_gw_data,

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
	localparam HAS_KEEP = ROOT_KEEP != 0 && HAS_ROOT != 0 ? 1 : 0;
	localparam HAS_DC = (HAS_PROT != 0 || HAS_KEEP != 0) && HAS_ROOT != 0 ? 1 : 0;
	localparam [NCLIENT-1:0] KEEP_MASK = HAS_KEEP != 0 ?
		{{(NCLIENT-1){1'b0}}, 1'b1} << RC : {NCLIENT{1'b0}};
	localparam HPW = HW + 7;

	/* The tree. */
	wire t_req_valid, t_req_ready, t_req_last;
	wire [LINE_BITS-1:0] t_req_data;
	wire t_rsp_valid, t_rsp_ready, t_rsp_idle;
	wire [RFW-1:0] t_rsp_data;
	wire s_req_valid, s_req_ready, s_req_last, s_rsp_valid;
	wire [LINE_BITS-1:0] s_req_data;
	wire [RFW-1:0] s_rsp_data;

	atg_mc_tree #(
		.NCLIENT(NCLIENT), .HIGH_MASK(HIGH_MASK), .HAS_ROOT(HAS_ROOT), .ROOT_SPLIT(HAS_DC),
		.ROOT_KEEP(HAS_KEEP), .ROOT_CLIENT(RC), .TREE_L(TREE_L), .RW(RW), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .VRAM_AW(VRAM_AW), .VRAM_BASE(VRAM_BASE)
	) tree (
		.clk(clk), .rst_n(rst_n), .flush(flush), .hold({NCLIENT{quiesce}} & ~QUIESCE_EXEMPT),
		.c_req_valid(c_req_valid), .c_req_ready(c_req_ready), .c_req_write(c_req_write),
		.c_req_line(c_req_line), .c_req_be(c_req_be), .c_req_wdata(c_req_wdata),
		.c_req_tag(c_req_tag),
		.c_req_chk(HAS_PROT != 0 ? c_req_chk : {NCLIENT{1'b0}}),
		.c_req_tbl(HAS_PROT != 0 ? c_req_tbl : {NCLIENT{1'b0}}),
		.c_req_slot(HAS_PROT != 0 ? c_req_slot : {6*NCLIENT{1'b0}}),
		.c_rsp_valid(rsp_valid), .c_rsp_write(rsp_write), .c_rsp_tag(rsp_tag),
		.c_rsp_rdata(rsp_rdata), .c_rsp_error(rsp_error),
		.r_req_valid(t_req_valid), .r_req_ready(t_req_ready), .r_req_data(t_req_data),
		.r_req_last(t_req_last),
		.r_rsp_valid(t_rsp_valid), .r_rsp_ready(t_rsp_ready), .r_rsp_data(t_rsp_data),
		.s_req_valid(s_req_valid), .s_req_ready(s_req_ready), .s_req_data(s_req_data),
		.s_req_last(s_req_last), .s_rsp_valid(s_rsp_valid), .s_rsp_data(s_rsp_data),
		.rsp_idle(t_rsp_idle)
	);

	/*
	 * The requests being assembled at the root: the tree's (A) and the DC's
	 * own (D, HAS_DC; without it D stays empty).
	 */
	wire a_full, d_full, a_take, d_take;
	wire [LINE_BITS-1:0] a_head, a_data, d_head, d_data;

	atg_mc_asm #(.LINE_BYTES(LINE_BYTES)) asm_a (
		.clk(clk), .rst_n(rst_n), .flush(flush), .t_valid(t_req_valid), .t_ready(t_req_ready),
		.t_data(t_req_data), .t_last(t_req_last), .full(a_full), .head(a_head), .data(a_data),
		.take(a_take)
	);
	atg_mc_asm #(.LINE_BYTES(LINE_BYTES)) asm_d (
		.clk(clk), .rst_n(rst_n), .flush(flush && HAS_KEEP == 0), .t_valid(HAS_DC != 0 && s_req_valid),
		.t_ready(s_req_ready), .t_data(s_req_data), .t_last(s_req_last), .full(d_full),
		.head(d_head), .data(d_data), .take(d_take)
	);

	/* The error response of a refused request. */
	reg err_v;
	reg [RW-1:0] err_route;
	reg [7:0] err_tag;
	reg err_write;

	wire g_valid, g_ready, g_write;
	wire [LA_W-1:0] g_line;
	wire [LINE_BYTES-1:0] g_be;
	wire [LINE_BITS-1:0] g_wdata;
	wire [UW-1:0] g_user;
	wire bad, bad_prot, bad_mem, done, done_chk;
	wire [HPW-1:0] bad_head;
	wire [LA_W-1:0] bad_line;

	wire m_rsp_valid;
	wire m_rsp_write;
	wire [UW-1:0] m_rsp_user;
	wire [LINE_BITS-1:0] m_rsp_rdata;
	wire m_rsp_error;
	wire m_idle;
	wire m_walk = m_rsp_user[15:8] == 8'hFF;

	atg_mc_prot #(
		.HAS_PROT(HAS_PROT), .HAS_DC(HAS_DC), .NCLIENT(NCLIENT), .RMW_MASK(RMW_MASK),
		.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .VRAM_AW(VRAM_AW),
		.VRAM_BASE(VRAM_BASE), .RW(RW), .PLB(PROT_PLB), .PLB_W(PROT_PLB_W),
		.NGRANT(PROT_GRANTS), .GIDX_W(PROT_GIDX_W)
	) grant (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.a_valid(a_full), .a_head(a_head), .a_data(a_data), .a_take(a_take),
		.d_valid(d_full), .d_head(d_head), .d_data(d_data), .d_take(d_take),
		.aperture_base(aperture_base), .aperture_limit(aperture_limit),
		.g_valid(g_valid), .g_ready(g_ready), .g_write(g_write), .g_line(g_line), .g_be(g_be),
		.g_wdata(g_wdata), .g_user(g_user),
		.err_busy(err_v), .bad(bad), .bad_head(bad_head), .bad_line(bad_line),
		.bad_prot(bad_prot), .bad_mem(bad_mem), .done(done), .done_chk(done_chk),
		.w_valid(m_rsp_valid && m_walk), .w_error(m_rsp_error), .w_rdata(m_rsp_rdata),
		.tbase(prot_tbase), .inv_valid(prot_inv_valid), .inv_g(prot_inv_g),
		.inv_n(prot_inv_n), .inv_pending(prot_inv_pending),
		.gw_valid(prot_gw_valid), .gw_idx(prot_gw_idx), .gw_data(prot_gw_data)
	);

	/*
	 * Responses: the AXI master's first (a walk's goes to atg_mc_prot), then
	 * a refused request's.  Route bit 0 = 0 with HAS_DC is the DC's own
	 * entry.  The tree always takes a response (its leaves always do, and a
	 * hop has room whenever the next one has), which the AXI master's
	 * responses need: they cannot wait.
	 */
	wire m_out = m_rsp_valid && !m_walk;
	wire err_out = err_v && !m_out && t_rsp_ready;
	wire [RW-1:0] rsp_route = m_out ? m_rsp_user[16 +: RW] : err_route;
	wire rsp_dc = HAS_DC != 0 && !rsp_route[0];
`ifdef MUT_PROT_DATA
	wire [LINE_BITS-1:0] rsp_line = m_rsp_rdata;
`else
	wire [LINE_BITS-1:0] rsp_line = m_out ? m_rsp_rdata : {LINE_BITS{1'b0}};
`endif
	wire [RFW-1:0] rsp_flit = {rsp_line, rsp_route, m_out ? m_rsp_user[7:0] : err_tag,
		m_out ? m_rsp_error : 1'b1, m_out ? m_rsp_write : err_write};

	assign t_rsp_valid = (m_out || err_out) && !rsp_dc;
	assign t_rsp_data = rsp_flit;
	assign s_rsp_valid = (m_out || err_out) && rsp_dc;
	assign s_rsp_data = rsp_flit;

	/* The requests in the tree and the root (pend), with chk, of the units. */
	wire pend_zero;

	/*
	 * ROOT_KEEP: the root client's grants (route bit 0 = 0, not a walk),
	 * responses and refusals, left out of axi_idle.
	 */
	wire g_keep = HAS_KEEP != 0 && g_user[15:8] != 8'hFF && !g_user[16];
	wire m_keep = HAS_KEEP != 0 && !m_walk && !m_rsp_user[16];
	wire bad_keep = HAS_KEEP != 0 && !bad_head[20];
	wire err_keep = HAS_KEEP != 0 && !err_route[0];
	wire ax_zero;

	atg_mc_cnt #(.NCLIENT(NCLIENT), .UNIT_MASK(UNIT_MASK), .KEEP_MASK(KEEP_MASK)) cnt (
		.clk(clk), .rst_n(rst_n), .flush(flush), .take(c_req_valid & c_req_ready),
		.take_chk(HAS_PROT != 0 ? c_req_chk : {NCLIENT{1'b0}}), .rsp(rsp_valid), .done(done),
		.done_chk(done_chk), .done_keep(g_valid && g_ready ? g_keep : bad && bad_keep),
		.ax_inc(g_valid && g_ready && !g_keep), .ax_dec(m_rsp_valid && !m_keep),
		.pend_zero(pend_zero), .chk_idle(chk_idle), .unit_idle(unit_idle), .ax_zero(ax_zero)
	);

	assign axi_idle = (HAS_KEEP != 0 ? ax_zero && !(err_v && !err_keep) :
		m_idle && !err_v) && t_rsp_idle && pend_zero;

	/* flush drops a refusal's response, but not the root client's (ROOT_KEEP). */
	always @(posedge clk) begin
		if (!rst_n) begin
			err_v <= 1'b0;
			err_route <= {RW{1'b0}};
			err_tag <= 8'd0;
			err_write <= 1'b0;
			fault <= 1'b0;
			fault_client <= 8'd0;
			fault_addr <= {ADDR_W{1'b0}};
			fault_write <= 1'b0;
			fault_prot <= 1'b0;
			fault_slot <= 6'd0;
			fault_mem <= 1'b0;
		end else begin
			fault <= 1'b0;
			if (bad && (!flush || bad_keep)) begin
				err_v <= 1'b1;
				err_route <= bad_head[20 +: RW];
				err_tag <= bad_head[11:4];
				err_write <= bad_head[1];
				fault <= 1'b1;
				fault_client <= bad_head[19:12];
				fault_addr <= {bad_line, {LINE_SHIFT{1'b0}}};
				fault_write <= bad_head[1];
				fault_prot <= bad_prot;
				fault_slot <= bad_head[HW+1 +: 6];
				fault_mem <= bad_mem;
			end else if (err_out || flush && !err_keep) begin
				err_v <= 1'b0;
			end
		end
	end

	am_axi_master #(
		.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .DATA_W(DATA_W),
		.UW(UW), .OUTSTANDING_LOG2(OUTSTANDING_LOG2)
	) axi (
		.clk(clk), .rst_n(rst_n), .halt(1'b0), .idle(m_idle), .req_valid(g_valid),
		.req_ready(g_ready), .req_write(g_write), .req_line(g_line), .req_be(g_be),
		.req_wdata(g_wdata), .req_user(g_user), .rsp_valid(m_rsp_valid),
		.rsp_write(m_rsp_write), .rsp_user(m_rsp_user), .rsp_rdata(m_rsp_rdata),
		.rsp_error(m_rsp_error), .m_awaddr(m_awaddr), .m_awlen(m_awlen),
		.m_awsize(m_awsize), .m_awburst(m_awburst), .m_awcache(m_awcache),
		.m_awprot(m_awprot), .m_awvalid(m_awvalid), .m_awready(m_awready),
		.m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid),
		.m_wready(m_wready), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
		.m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst),
		.m_arcache(m_arcache), .m_arprot(m_arprot), .m_arvalid(m_arvalid),
		.m_arready(m_arready), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
		.m_rvalid(m_rvalid), .m_rready(m_rready)
	);

	wire unused_ok = &{1'b0, bad_head, s_req_valid};
endmodule

`default_nettype wire
