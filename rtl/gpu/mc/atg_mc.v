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
 * Destinations (ws288 p039, docs/ghci.md section 11.2): a granted request
 * (a walk too) whose line is in [LOCAL_BASE, LOCAL_BASE + LOCAL_BYTES) is
 * local and goes out with AXI ID 0; every other is a host access with ID 1
 * (LOCAL_BYTES = 0: everything is ID 0).  The board routes by the address
 * (am_axi_split with the same range).  am_axi_master keeps each client's
 * order (its key is the client, 0xFF for a walk): a request of a client
 * that has requests of the same direction outstanding at the other
 * destination waits at the root until they are answered.
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
	parameter [ADDR_W-1:0] LOCAL_BASE = {ADDR_W{1'b0}},	/* local memory (the MEM capability) */
	parameter [ADDR_W-1:0] LOCAL_BYTES = {ADDR_W{1'b0}},	/* 0: none, one AXI ID */
	parameter [NCLIENT-1:0] UNIT_MASK = {NCLIENT{1'b0}},	/* clients counted by unit_idle */
	parameter HAS_PROT = 0,	/* session protection */
	parameter [NCLIENT-1:0] RMW_MASK = {NCLIENT{1'b0}},	/* reads judged as writes (atomics) */
	parameter PROT_PLB = 4,	/* PLB lines */
	parameter PROT_PLB_W = 2,	/* clog2(PROT_PLB) */
	parameter PROT_GRANTS = 8,	/* grant CAM entries */
	parameter PROT_GIDX_W = 3,	/* clog2(PROT_GRANTS) */
	parameter HAS_L2 = 0,		/* 256 KiB 16-way L2 cache (LLC) */
	parameter L2_WAYS = 16,
	parameter L2_SET_W = 8
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
	input wire l2_flush,
	output wire l2_flush_done,
	output wire l2_idle_out,
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
	output wire [3:0] fsm,
	/* Display Controller watermark preemption signals (ws001-p039) */
	input wire dc_urgent,
	input wire dc_panic,

	/* Session protection, from the CP. */
	input wire [ADDR_W-1:0] prot_tbase,
	input wire prot_inv_valid,
	input wire [ADDR_W-13:0] prot_inv_g,
	input wire [31:0] prot_inv_n,
	output wire prot_inv_pending,
	input wire prot_gw_valid,
	input wire [PROT_GIDX_W-1:0] prot_gw_idx,
	input wire [49:0] prot_gw_data,

	output wire m_awid,	/* 0 local, 1 host */
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
	input wire m_bid,
	input wire [1:0] m_bresp,
	input wire m_bvalid,
	output wire m_bready,
	output wire m_arid,
	output wire [ADDR_W-1:0] m_araddr,
	output wire [7:0] m_arlen,
	output wire [2:0] m_arsize,
	output wire [1:0] m_arburst,
	output wire [3:0] m_arcache,
	output wire [2:0] m_arprot,
	output wire m_arvalid,
	input wire m_arready,
	input wire m_rid,
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
	localparam HAS_LOCAL = LOCAL_BYTES != {ADDR_W{1'b0}} ? 1 : 0;
	localparam [ADDR_W:0] LOCAL_END = {1'b0, LOCAL_BASE} + {1'b0, LOCAL_BYTES};

	/* The tree. */
	wire t_req_valid, t_req_ready, t_req_last;
	wire [LINE_BITS-1:0] t_req_data;
	wire t_rsp_valid, t_rsp_ready, t_rsp_idle;
	wire [RFW-1:0] t_rsp_data;
	wire s_req_valid, s_req_ready, s_req_last, s_rsp_valid;
	wire [LINE_BITS-1:0] s_req_data;
	wire [RFW-1:0] s_rsp_data;

	/* DC preemption: when dc_urgent or dc_panic is asserted AND DC is requesting,
	 * hold other rendering clients (exempting Client 0: CP). */
	wire [NCLIENT-1:0] dc_preempt = (HAS_DC != 0 && (dc_urgent || dc_panic) && c_req_valid[RC]) ?
		(~({{(NCLIENT-1){1'b0}}, 1'b1} << RC) & ~{{(NCLIENT-1){1'b0}}, 1'b1}) : {NCLIENT{1'b0}};

	reg [NCLIENT-1:0] tree_hold_r;
	always @(posedge clk) begin
		if (!rst_n)
			tree_hold_r <= {NCLIENT{1'b0}};
		else
			tree_hold_r <= ({NCLIENT{quiesce}} & ~QUIESCE_EXEMPT) | dc_preempt;
	end

	wire [NCLIENT-1:0] tree_hold = tree_hold_r;
	wire [NCLIENT-1:0] c_req_ready_raw;
	wire m_bready_raw;

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire mc_rst_sync, mc_rst_sync1, mc_rst_sync2;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_mc_rst0 (.I0(rst_n), .O(mc_rst_sync));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_mc_rst1 (.I0(rst_n), .O(mc_rst_sync1));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_mc_rst2 (.I0(rst_n), .O(mc_rst_sync2));

	reg [NCLIENT-1:0] c_req_ready_r;
	reg m_bready_r;
	always @(posedge clk) begin
		if (mc_rst_sync) begin
			c_req_ready_r <= {NCLIENT{1'b0}};
			m_bready_r <= 1'b0;
		end else begin
			c_req_ready_r <= c_req_ready_raw;
			m_bready_r <= m_bready_raw;
		end
	end
	assign c_req_ready = c_req_ready_r;
	assign m_bready = m_bready_r;
`else
	assign c_req_ready = c_req_ready_raw;
	assign m_bready = m_bready_raw;
`endif

	atg_mc_tree #(
		.NCLIENT(NCLIENT), .HIGH_MASK(HIGH_MASK), .HAS_ROOT(HAS_ROOT), .ROOT_SPLIT(HAS_DC),
		.ROOT_KEEP(HAS_KEEP), .ROOT_CLIENT(RC), .TREE_L(TREE_L), .RW(RW), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .VRAM_AW(VRAM_AW), .VRAM_BASE(VRAM_BASE)
	) tree (
		.clk(clk), .rst_n(rst_n), .flush(flush), .hold(tree_hold),
		.c_req_valid(c_req_valid), .c_req_ready(c_req_ready_raw), .c_req_write(c_req_write),
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
	 * own (D, HAS_DC; without it D stays empty).  Aperture check is computed
	 * on the incoming header flit and registered alongside head in atg_mc_asm.
	 */
	function [LA_W-1:0] mc_line_of;
		input [LAW-1:0] off;
		begin
			mc_line_of = {LA_W{1'b0}};
			mc_line_of[LAW-1:0] = off;
			if (VRAM_AW < ADDR_W)
				mc_line_of = mc_line_of | (VRAM_BASE[ADDR_W-1:LINE_SHIFT] &
					~{{(ADDR_W-VRAM_AW){1'b0}}, {LAW{1'b1}}});
		end
	endfunction

	wire [LA_W-1:0] t_req_line = mc_line_of(t_req_data[20+RW +: LAW]);
	wire [LA_W-1:0] s_req_line = mc_line_of(s_req_data[20+RW +: LAW]);
	wire t_req_ap, s_req_ap, a_ap, d_ap;

	atg_mc_aper #(.ADDR_W(ADDR_W), .LINE_SHIFT(LINE_SHIFT)) aper_a (
		.line(t_req_line), .base(aperture_base), .limit(aperture_limit), .ok(t_req_ap)
	);
	atg_mc_aper #(.ADDR_W(ADDR_W), .LINE_SHIFT(LINE_SHIFT)) aper_d (
		.line(s_req_line), .base(aperture_base), .limit(aperture_limit), .ok(s_req_ap)
	);

	wire a_full, d_full, a_take, a_take_raw, d_take, t_req_ready_raw;
	wire [LINE_BITS-1:0] a_head, a_data, d_head, d_data;

	atg_mc_asm #(.LINE_BYTES(LINE_BYTES)) asm_a (
		.clk(clk), .rst_n(rst_n), .flush(flush), .t_valid(t_req_valid), .t_ready(t_req_ready_raw),
		.t_data(t_req_data), .t_last(t_req_last), .t_ap(t_req_ap), .full(a_full), .head(a_head),
		.data(a_data), .ap_ok(a_ap), .take(a_take)
	);
	atg_mc_asm #(.LINE_BYTES(LINE_BYTES)) asm_d (
		.clk(clk), .rst_n(rst_n), .flush(flush && HAS_KEEP == 0), .t_valid(HAS_DC != 0 && s_req_valid),
		.t_ready(s_req_ready), .t_data(s_req_data), .t_last(s_req_last), .t_ap(s_req_ap), .full(d_full),
		.head(d_head), .data(d_data), .ap_ok(d_ap), .take(d_take)
	);

	/* The error response of a refused request. */
	reg err_v, bad_r;
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

	/* Responses from L2 cache / AXI master subsystem */
	wire l2_rsp_valid;
	wire l2_rsp_write;
	wire [UW-1:0] l2_rsp_user;
	wire [LINE_BITS-1:0] l2_rsp_rdata;
	wire l2_rsp_error;
	wire l2_idle;
	wire m_idle;
	wire l2_walk = l2_rsp_user[15:8] == 8'hFF;

	atg_mc_prot #(
		.HAS_PROT(HAS_PROT), .HAS_DC(HAS_DC), .NCLIENT(NCLIENT), .RMW_MASK(RMW_MASK),
		.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .VRAM_AW(VRAM_AW),
		.VRAM_BASE(VRAM_BASE), .RW(RW), .PLB(PROT_PLB), .PLB_W(PROT_PLB_W),
		.NGRANT(PROT_GRANTS), .GIDX_W(PROT_GIDX_W)
	) grant (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.a_valid(a_full && !(HAS_DC != 0 && dc_panic && d_full)), .a_head(a_head), .a_data(a_data),
		.a_ap(a_ap), .a_take(a_take_raw),
		.d_valid(d_full), .d_head(d_head), .d_data(d_data), .d_ap(d_ap), .d_take(d_take),
		.aperture_base(aperture_base), .aperture_limit(aperture_limit),
		.g_valid(g_valid), .g_ready(g_ready), .g_write(g_write), .g_line(g_line), .g_be(g_be),
		.g_wdata(g_wdata), .g_user(g_user),
		.err_busy(err_v || bad_r), .bad(bad), .bad_head(bad_head), .bad_line(bad_line),
		.bad_prot(bad_prot), .bad_mem(bad_mem), .done(done), .done_chk(done_chk),
		.w_valid(l2_rsp_valid && l2_walk), .w_error(l2_rsp_error), .w_rdata(l2_rsp_rdata),
		.tbase(prot_tbase), .inv_valid(prot_inv_valid), .inv_g(prot_inv_g),
		.inv_n(prot_inv_n), .inv_pending(prot_inv_pending),
		.gw_valid(prot_gw_valid), .gw_idx(prot_gw_idx), .gw_data(prot_gw_data)
	);

`ifdef SYNTH_KINTEX7
	generate
		if (HAS_PROT == 0 && HAS_DC == 0) begin : g_fast_atake
			(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h44444404)) u_atake (
				.I0(err_v), .I1(a_full), .I2(a_ap), .I3(a_head[2]), .I4(g_ready),
				.O(a_take)
			);
			(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h77777737)) u_trdy (
				.I0(err_v), .I1(a_full), .I2(a_ap), .I3(a_head[2]), .I4(g_ready),
				.O(t_req_ready)
			);
			wire unused_at_raw = &{1'b0, a_take_raw, t_req_ready_raw};
		end else begin : g_gen_atake
			assign a_take = a_take_raw;
			assign t_req_ready = t_req_ready_raw;
		end
	endgenerate
`else
	assign a_take = a_take_raw;
	assign t_req_ready = t_req_ready_raw;
`endif

	/*
	 * Responses: the L2/AXI subsystem's first (a walk's goes to atg_mc_prot), then
	 * a refused request's.  Route bit 0 = 0 with HAS_DC is the DC's own
	 * entry.  The tree always takes a response (its leaves always do, and a
	 * hop has room whenever the next one has), which the AXI master's
	 * responses need: they cannot wait.
	 */
	wire m_out = l2_rsp_valid && !l2_walk;
	wire err_out = err_v && !m_out && t_rsp_ready;
	wire [RW-1:0] rsp_route = m_out ? l2_rsp_user[16 +: RW] : err_route;
	wire rsp_dc = HAS_DC != 0 && !rsp_route[0];
`ifdef MUT_PROT_DATA
	wire [LINE_BITS-1:0] rsp_line = l2_rsp_rdata;
	wire [RFW-1:0] rsp_flit = {rsp_line, rsp_route, m_out ? l2_rsp_user[7:0] : err_tag,
		m_out ? l2_rsp_error : 1'b1, m_out ? l2_rsp_write : err_write};
`else
`ifdef SYNTH_KINTEX7
	localparam RSP_NSLICE = LINE_BITS / 16;
	wire [RSP_NSLICE:0] m_out_b;
	wire [LINE_BITS-1:0] rsp_line;
	genvar grs;
	generate
		for (grs = 0; grs < RSP_NSLICE; grs = grs + 1) begin : g_mout_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_mo (
				.I0(m_out), .O(m_out_b[grs])
			);
			assign rsp_line[grs*16 +: 16] = m_out_b[grs] ? l2_rsp_rdata[grs*16 +: 16] : 16'd0;
		end
	endgenerate
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_mo_hdr (
		.I0(m_out), .O(m_out_b[RSP_NSLICE])
	);
	wire [RW-1:0] rsp_route_b = m_out_b[RSP_NSLICE] ? l2_rsp_user[16 +: RW] : err_route;
	wire [RFW-1:0] rsp_flit = {rsp_line, rsp_route_b, m_out_b[RSP_NSLICE] ? l2_rsp_user[7:0] : err_tag,
		m_out_b[RSP_NSLICE] ? l2_rsp_error : 1'b1, m_out_b[RSP_NSLICE] ? l2_rsp_write : err_write};
`else
	wire [LINE_BITS-1:0] rsp_line = m_out ? l2_rsp_rdata : {LINE_BITS{1'b0}};
	wire [RFW-1:0] rsp_flit = {rsp_line, rsp_route, m_out ? l2_rsp_user[7:0] : err_tag,
		m_out ? l2_rsp_error : 1'b1, m_out ? l2_rsp_write : err_write};
`endif
`endif

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
	wire l2_keep = HAS_KEEP != 0 && !l2_walk && !l2_rsp_user[16];
	wire bad_keep = HAS_KEEP != 0 && !bad_head[20];
	wire err_keep = HAS_KEEP != 0 && !err_route[0];
	wire ax_zero;

	atg_mc_cnt #(.NCLIENT(NCLIENT), .UNIT_MASK(UNIT_MASK), .KEEP_MASK(KEEP_MASK)) cnt (
		.clk(clk), .rst_n(rst_n), .flush(flush), .take(c_req_valid & c_req_ready_raw),
		.take_chk(HAS_PROT != 0 ? c_req_chk : {NCLIENT{1'b0}}), .rsp(rsp_valid), .done(done),
		.done_chk(done_chk), .done_keep(g_valid && g_ready ? g_keep : bad && bad_keep),
		.ax_inc(g_valid && g_ready && !g_keep), .ax_dec(l2_rsp_valid && !l2_keep),
		.pend_zero(pend_zero), .chk_idle(chk_idle), .unit_idle(unit_idle), .ax_zero(ax_zero)
	);

	assign axi_idle = (HAS_KEEP != 0 ? ax_zero && !(err_v && !err_keep) :
		(m_idle && l2_idle) && !err_v) && t_rsp_idle && pend_zero;

	/* flush drops a refusal's response, but not the root client's (ROOT_KEEP). */
	reg [HPW-1:0] bad_head_r;
	reg [LA_W-1:0] bad_line_r;
	reg bad_prot_r, bad_mem_r;

	always @(posedge clk) begin
		if (!rst_n) begin
			bad_r <= 1'b0;
			bad_head_r <= {HPW{1'b0}};
			bad_line_r <= {LA_W{1'b0}};
			bad_prot_r <= 1'b0;
			bad_mem_r <= 1'b0;
		end else begin
			bad_r <= bad && (!flush || bad_keep);
			bad_head_r <= bad_head;
			bad_line_r <= bad_line;
			bad_prot_r <= bad_prot;
			bad_mem_r <= bad_mem;
		end
	end

`ifdef SYNTH_KINTEX7
	wire err_load_raw = bad_r;
	wire [3:0] err_load_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_el0 (.I0(err_load_raw), .O(err_load_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_el1 (.I0(err_load_raw), .O(err_load_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_el2 (.I0(err_load_raw), .O(err_load_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_el3 (.I0(err_load_raw), .O(err_load_b[3]));

	always @(posedge clk) begin
		if (mc_rst_sync) begin
			err_v <= 1'b0;
			fault <= 1'b0;
		end else begin
			fault <= 1'b0;
			if (err_load_raw) begin
				err_v <= 1'b1;
				fault <= 1'b1;
			end else if (err_out || flush && !err_keep) begin
				err_v <= 1'b0;
			end
		end
	end
	always @(posedge clk) begin
		if (err_load_b[0]) begin
			err_route <= bad_head_r[20 +: RW];
			err_tag <= bad_head_r[11:4];
			err_write <= bad_head_r[1];
		end
		if (err_load_b[1]) begin
			fault_client <= bad_head_r[19:12];
			fault_write <= bad_head_r[1];
			fault_prot <= bad_prot_r;
			fault_slot <= bad_head_r[HW+1 +: 6];
			fault_mem <= bad_mem_r;
		end
		if (err_load_b[2]) begin
			fault_addr[15:0] <= {bad_line_r[15-LINE_SHIFT:0], {LINE_SHIFT{1'b0}}};
		end
		if (err_load_b[3]) begin
			fault_addr[ADDR_W-1:16] <= bad_line_r[LA_W-1:16-LINE_SHIFT];
		end
	end
`else
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
			if (bad_r) begin
				err_v <= 1'b1;
				err_route <= bad_head_r[20 +: RW];
				err_tag <= bad_head_r[11:4];
				err_write <= bad_head_r[1];
				fault <= 1'b1;
				fault_client <= bad_head_r[19:12];
				fault_addr <= {bad_line_r, {LINE_SHIFT{1'b0}}};
				fault_write <= bad_head_r[1];
				fault_prot <= bad_prot_r;
				fault_slot <= bad_head_r[HW+1 +: 6];
				fault_mem <= bad_mem_r;
			end else if (err_out || flush && !err_keep) begin
				err_v <= 1'b0;
			end
		end
	end
`endif

	/* The destination: local (ID 0) or host (ID 1). */
	wire [ADDR_W:0] g_addr = {1'b0, g_line, {LINE_SHIFT{1'b0}}};
	wire g_host = HAS_LOCAL != 0 && !(g_addr >= {1'b0, LOCAL_BASE} && g_addr < LOCAL_END);

	/* Downstream AXI request/response wires */
	wire axi_req_valid, axi_req_ready, axi_req_write, axi_req_id;
	wire [LA_W-1:0] axi_req_line;
	wire [LINE_BYTES-1:0] axi_req_be;
	wire [LINE_BITS-1:0] axi_req_wdata;
	wire [UW-1:0] axi_req_user;
	wire [7:0] axi_req_key;

	wire ax_rsp_valid, ax_rsp_write, ax_rsp_error;
	wire [UW-1:0] ax_rsp_user;
	wire [LINE_BITS-1:0] ax_rsp_rdata;

	generate
	if (HAS_L2 != 0) begin : g_l2
		wire s_high = HAS_DC != 0 && !g_user[16];
		wire l2_ctrl_inv_done;
		wire [3:0] l2_fsm;

		localparam SKID_W = 1 + LA_W + LINE_BYTES + LINE_BITS + UW + 3;
		wire l2_s_req_valid, l2_s_req_ready;
		wire [SKID_W-1:0] l2_s_req_data;

		am_skid #(
			.WIDTH(SKID_W)
		) u_l2_skid (
			.clk(clk),
			.rst_n(rst_n && !flush),
			.in_valid(g_valid),
			.in_ready(g_ready),
			.in_data({g_write, g_line, g_be, g_wdata, g_user, g_host, g_host, s_high}),
			.out_valid(l2_s_req_valid),
			.out_ready(l2_s_req_ready),
			.out_data(l2_s_req_data)
		);

		wire l2_req_write = l2_s_req_data[SKID_W-1];
		wire [LA_W-1:0] l2_req_line = l2_s_req_data[SKID_W-2 -: LA_W];
		wire [LINE_BYTES-1:0] l2_req_be = l2_s_req_data[SKID_W-2-LA_W -: LINE_BYTES];
		wire [LINE_BITS-1:0] l2_req_wdata = l2_s_req_data[UW+3 +: LINE_BITS];
		wire [UW-1:0] l2_req_user = l2_s_req_data[3 +: UW];
		wire l2_req_id = l2_s_req_data[2];
		wire l2_req_nc = l2_s_req_data[1];
		wire l2_req_high = l2_s_req_data[0];

		atg_mc_l2 #(
			.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
			.UW(UW), .WAYS(L2_WAYS), .SET_W(L2_SET_W)
		) l2 (
			.clk(clk), .rst_n(rst_n), .flush(flush), .quiesce(quiesce),
			.s_req_valid(l2_s_req_valid), .s_req_ready(l2_s_req_ready), .s_req_write(l2_req_write),
			.s_req_line(l2_req_line), .s_req_be(l2_req_be), .s_req_wdata(l2_req_wdata),
			.s_req_user(l2_req_user), .s_req_id(l2_req_id), .s_req_nc(l2_req_nc),
			.s_req_high(l2_req_high),
			.s_rsp_valid(l2_rsp_valid), .s_rsp_write(l2_rsp_write), .s_rsp_user(l2_rsp_user),
			.s_rsp_rdata(l2_rsp_rdata), .s_rsp_error(l2_rsp_error),
			.m_req_valid(axi_req_valid), .m_req_ready(axi_req_ready), .m_req_write(axi_req_write),
			.m_req_line(axi_req_line), .m_req_be(axi_req_be), .m_req_wdata(axi_req_wdata),
			.m_req_user(axi_req_user), .m_req_id(axi_req_id), .m_req_key(axi_req_key),
			.m_rsp_valid(ax_rsp_valid), .m_rsp_write(ax_rsp_write), .m_rsp_user(ax_rsp_user),
			.m_rsp_rdata(ax_rsp_rdata), .m_rsp_error(ax_rsp_error),
			.ctrl_inv_valid(l2_flush), .ctrl_inv_clean(1'b1), .ctrl_inv_range(1'b0),
			.ctrl_inv_base({LA_W{1'b0}}), .ctrl_inv_limit({LA_W{1'b0}}),
			.ctrl_inv_done(l2_ctrl_inv_done),
			.idle(l2_idle), .fsm(l2_fsm)
		);
		assign l2_flush_done = l2_ctrl_inv_done;
		wire unused_l2 = &{1'b0, l2_fsm};
	end else begin : g_no_l2
		assign g_ready = axi_req_ready;
		assign axi_req_valid = g_valid;
		assign axi_req_write = g_write;
		assign axi_req_line = g_line;
		assign axi_req_be = g_be;
		assign axi_req_wdata = g_wdata;
		assign axi_req_user = g_user;
		assign axi_req_id = g_host;
		assign axi_req_key = g_user[15:8];

		assign l2_rsp_valid = ax_rsp_valid;
		assign l2_rsp_write = ax_rsp_write;
		assign l2_rsp_user = ax_rsp_user;
		assign l2_rsp_rdata = ax_rsp_rdata;
		assign l2_rsp_error = ax_rsp_error;
		assign l2_idle = 1'b1;
		assign l2_flush_done = 1'b1;
	end
	endgenerate

`ifdef SYNTH_KINTEX7
	localparam AX_NID = HAS_LOCAL != 0 ? 2 : 1;
	localparam AX_BEATS = LINE_BITS / DATA_W;
	/* verilator lint_off WIDTHTRUNC */
	localparam [7:0] AX_AXLEN = AX_BEATS - 1;
	/* verilator lint_on WIDTHTRUNC */
	localparam [2:0] AX_AXSIZE = DATA_W == 8 ? 3'd0 : DATA_W == 16 ? 3'd1 :
		DATA_W == 32 ? 3'd2 : DATA_W == 64 ? 3'd3 : DATA_W == 128 ? 3'd4 :
		DATA_W == 256 ? 3'd5 : DATA_W == 512 ? 3'd6 : 3'd7;
	localparam AX_O = OUTSTANDING_LOG2;
	localparam AX_D = 1 << AX_O;
	localparam [AX_O:0] AX_DEPTH = AX_D;
	localparam AX_SKW = 1 + LA_W;

	assign m_awlen = AX_AXLEN;
	assign m_arlen = AX_AXLEN;
	assign m_awsize = AX_AXSIZE;
	assign m_arsize = AX_AXSIZE;
	assign m_awburst = 2'b01;
	assign m_arburst = 2'b01;
	assign m_awcache = 4'b0011;
	assign m_arcache = 4'b0011;
	assign m_awprot = 3'b000;
	assign m_arprot = 3'b000;

	wire ax_q_id = AX_NID > 1 ? axi_req_id : 1'b0;
	wire ax_b_id = AX_NID > 1 ? m_bid : 1'b0;
	wire ax_r_id = AX_NID > 1 ? m_rid : 1'b0;

	wire [AX_NID-1:0] ax_wq_rdy, ax_wq_has, ax_wq_any, ax_rq_rdy, ax_rq_has, ax_rq_any;
	wire [AX_NID*UW-1:0] ax_wq_user, ax_rq_user;

	reg ax_w_busy;
	reg [7:0] ax_w_beat;
	reg [LINE_BITS-1:0] ax_w_buf;
	reg [LINE_BYTES-1:0] ax_w_be;

	wire ax_aw_in_ready, ax_aw_out_valid;
	wire [AX_SKW-1:0] ax_aw_in_data = {ax_q_id, axi_req_line};
	wire [AX_SKW-1:0] ax_aw_out_data;
	wire ax_ar_in_ready, ax_ar_out_valid;
	wire [AX_SKW-1:0] ax_ar_in_data = {ax_q_id, axi_req_line};
	wire [AX_SKW-1:0] ax_ar_out_data;

	wire ax_w_other = (AX_NID == 2) ? (ax_q_id ? ax_wq_has[0] : ax_wq_has[1]) :
		|(ax_wq_has & ~({{(AX_NID-1){1'b0}}, 1'b1} << ax_q_id));
	wire ax_r_other = (AX_NID == 2) ? (ax_q_id ? ax_rq_has[0] : ax_rq_has[1]) :
		|(ax_rq_has & ~({{(AX_NID-1){1'b0}}, 1'b1} << ax_q_id));
	wire ax_wr_can = ax_aw_in_ready && !ax_w_busy && ax_wq_rdy[ax_q_id] && !ax_w_other;
	wire ax_rd_can = ax_ar_in_ready && ax_rq_rdy[ax_q_id] && !ax_r_other;

	reg aw_sk_in_rdy, aw_sk_out_val, aw_sk_val;
	reg [AX_SKW-1:0] aw_sk_out_d, aw_sk_d;
	reg ar_sk_in_rdy, ar_sk_out_val, ar_sk_val;
	reg [AX_SKW-1:0] ar_sk_out_d, ar_sk_d;

	wire [2:0] wv_g, wr_g, wb_g, mw_g;
	wire rv_g, rr_g;
	genvar g_wg;
	generate
		for (g_wg = 0; g_wg < 3; g_wg = g_wg + 1) begin : g_w_ctrl_grp
			if (HAS_PROT == 0 && HAS_DC == 0 && HAS_L2 == 0) begin : g_wv_direct
				(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h00400000)) u_wv (
					.I0(err_v), .I1(a_full), .I2(a_ap), .I3(a_head[2]), .I4(a_head[1]),
					.O(wv_g[g_wg])
				);
			end else begin : g_wv_gen
				(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_wv (
					.I0(axi_req_valid), .I1(axi_req_write), .O(wv_g[g_wg])
				);
			end
			if (AX_NID == 1) begin : g_wr_direct
				(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h4000)) u_wr (
					.I0(ax_w_busy), .I1(aw_sk_in_rdy), .I2(ax_wq_rdy[0]), .I3(rst_n),
					.O(wr_g[g_wg])
				);
			end else begin : g_wr_gen
				(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_wr (
					.I0(ax_wr_can), .I1(rst_n), .O(wr_g[g_wg])
				);
			end
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wb (.I0(ax_w_busy), .O(wb_g[g_wg]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_mw (.I0(m_wready),  .O(mw_g[g_wg]));
		end
		if (HAS_PROT == 0 && HAS_DC == 0 && HAS_L2 == 0) begin : g_rv_direct
			(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h00000040)) u_rv (
				.I0(err_v), .I1(a_full), .I2(a_ap), .I3(a_head[2]), .I4(a_head[1]),
				.O(rv_g)
			);
		end else begin : g_rv_gen
			(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h2)) u_rv (
				.I0(axi_req_valid), .I1(axi_req_write), .O(rv_g)
			);
		end
		if (AX_NID == 1) begin : g_rr_direct
			(* DONT_TOUCH = "TRUE" *) LUT3 #(.INIT(8'h80)) u_rr (
				.I0(ar_sk_in_rdy), .I1(ax_rq_rdy[0]), .I2(rst_n),
				.O(rr_g)
			);
		end else begin : g_rr_gen
			(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_rr (
				.I0(ax_rd_can), .I1(rst_n), .O(rr_g)
			);
		end
	endgenerate

	wire ax_wr_take, ax_rd_take;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_ax_wt (.I0(wv_g[0]), .I1(wr_g[0]), .O(ax_wr_take));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_ax_rt (.I0(rv_g),    .I1(rr_g),    .O(ax_rd_take));
	generate
		if (AX_NID == 1) begin : g_rdy_direct
			(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'h40404040FF000000)) u_ax_rdy (
				.I0(ax_w_busy), .I1(aw_sk_in_rdy), .I2(ax_wq_rdy[0]),
				.I3(ar_sk_in_rdy), .I4(ax_rq_rdy[0]), .I5(axi_req_write),
				.O(axi_req_ready)
			);
		end else begin : g_rdy_gen
			(* DONT_TOUCH = "TRUE" *) LUT3 #(.INIT(8'hCA)) u_ax_rdy (
				.I0(rr_g), .I1(wr_g[0]), .I2(axi_req_write), .O(axi_req_ready)
			);
		end
	endgenerate

	/* 2-slice buffered AW skid (14 bits per slice -> fanout <= 14) */
	assign ax_aw_in_ready = aw_sk_in_rdy;
	assign ax_aw_out_valid = aw_sk_out_val;
	assign ax_aw_out_data = aw_sk_out_d;
	always @(posedge clk) begin
		if (mc_rst_sync1) begin
			aw_sk_in_rdy <= 1'b1;
			aw_sk_out_val <= 1'b0;
			aw_sk_val <= 1'b0;
		end else begin
			if (aw_sk_val) begin
				if (m_awready) begin
					aw_sk_out_val <= 1'b1;
					aw_sk_val <= 1'b0;
					aw_sk_in_rdy <= 1'b1;
				end
			end else begin
				if (m_awready || !aw_sk_out_val)
					aw_sk_out_val <= ax_wr_take;
				else if (ax_wr_take && aw_sk_in_rdy) begin
					aw_sk_val <= 1'b1;
					aw_sk_in_rdy <= 1'b0;
				end
			end
		end
	end
	wire [1:0] aw_lo_b, aw_ls_b, aw_ss_b;
	genvar g_aws, g_awb;
	generate
		for (g_aws = 0; g_aws < 2; g_aws = g_aws + 1) begin : g_aw_skid_s
			localparam B0 = g_aws * 14;
			localparam BW = (B0 + 14 <= AX_SKW) ? 14 : (AX_SKW - B0);
			(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'hF8CC)) u_lo (
				.I0(aw_sk_out_val), .I1(m_awready), .I2(ax_wr_take), .I3(aw_sk_val),
				.O(aw_lo_b[g_aws])
			);
			(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_ls (
				.I0(ax_wr_take), .I1(aw_sk_in_rdy), .O(aw_ls_b[g_aws])
			);
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_ss (
				.I0(aw_sk_val), .O(aw_ss_b[g_aws])
			);
			wire [BW-1:0] aw_nxt;
			for (g_awb = 0; g_awb < BW; g_awb = g_awb + 1) begin : g_aw_bit
				(* DONT_TOUCH = "TRUE" *) LUT3 #(.INIT(8'hCA)) u_mx (
					.I0(ax_aw_in_data[B0 + g_awb]), .I1(aw_sk_d[B0 + g_awb]), .I2(aw_ss_b[g_aws]),
					.O(aw_nxt[g_awb])
				);
			end
			always @(posedge clk) begin
				if (aw_lo_b[g_aws])
					aw_sk_out_d[B0 +: BW] <= aw_nxt;
				if (aw_ls_b[g_aws])
					aw_sk_d[B0 +: BW] <= ax_aw_in_data[B0 +: BW];
			end
		end
	endgenerate

	/* 2-slice buffered AR skid (14 bits per slice -> fanout <= 14) */
	assign ax_ar_in_ready = ar_sk_in_rdy;
	assign ax_ar_out_valid = ar_sk_out_val;
	assign ax_ar_out_data = ar_sk_out_d;
	always @(posedge clk) begin
		if (mc_rst_sync1) begin
			ar_sk_in_rdy <= 1'b1;
			ar_sk_out_val <= 1'b0;
			ar_sk_val <= 1'b0;
		end else begin
			if (ar_sk_val) begin
				if (m_arready) begin
					ar_sk_out_val <= 1'b1;
					ar_sk_val <= 1'b0;
					ar_sk_in_rdy <= 1'b1;
				end
			end else begin
				if (m_arready || !ar_sk_out_val)
					ar_sk_out_val <= ax_rd_take;
				else if (ax_rd_take && ar_sk_in_rdy) begin
					ar_sk_val <= 1'b1;
					ar_sk_in_rdy <= 1'b0;
				end
			end
		end
	end
	wire [1:0] ar_lo_b, ar_ls_b, ar_ss_b;
	genvar g_ars, g_arb;
	generate
		for (g_ars = 0; g_ars < 2; g_ars = g_ars + 1) begin : g_ar_skid_s
			localparam B0 = g_ars * 14;
			localparam BW = (B0 + 14 <= AX_SKW) ? 14 : (AX_SKW - B0);
			(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'hF8CC)) u_lo (
				.I0(ar_sk_out_val), .I1(m_arready), .I2(ax_rd_take), .I3(ar_sk_val),
				.O(ar_lo_b[g_ars])
			);
			(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_ls (
				.I0(ax_rd_take), .I1(ar_sk_in_rdy), .O(ar_ls_b[g_ars])
			);
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_ss (
				.I0(ar_sk_val), .O(ar_ss_b[g_ars])
			);
			wire [BW-1:0] ar_nxt;
			for (g_arb = 0; g_arb < BW; g_arb = g_arb + 1) begin : g_ar_bit
				(* DONT_TOUCH = "TRUE" *) LUT3 #(.INIT(8'hCA)) u_mx (
					.I0(ax_ar_in_data[B0 + g_arb]), .I1(ar_sk_d[B0 + g_arb]), .I2(ar_ss_b[g_ars]),
					.O(ar_nxt[g_arb])
				);
			end
			always @(posedge clk) begin
				if (ar_lo_b[g_ars])
					ar_sk_out_d[B0 +: BW] <= ar_nxt;
				if (ar_ls_b[g_ars])
					ar_sk_d[B0 +: BW] <= ax_ar_in_data[B0 +: BW];
			end
		end
	endgenerate

	reg ax_rsp_valid_r, ax_rsp_write_r, ax_rsp_error_r;
	reg [UW-1:0] ax_rsp_user_r;
	reg [LINE_BITS-1:0] ax_rsp_rdata_r;
	assign ax_rsp_valid = ax_rsp_valid_r;
	assign ax_rsp_write = ax_rsp_write_r;
	assign ax_rsp_user = ax_rsp_user_r;
	assign ax_rsp_rdata = ax_rsp_rdata_r;
	assign ax_rsp_error = ax_rsp_error_r;

	assign m_idle = !ax_aw_out_valid && !ax_w_busy && !ax_ar_out_valid &&
		!(|ax_wq_any) && !(|ax_rq_any) && !ax_rsp_valid_r;

	assign m_awid = ax_aw_out_data[LA_W];
	assign m_awaddr = {ax_aw_out_data[LA_W-1:0], {LINE_SHIFT{1'b0}}};
	assign m_awvalid = ax_aw_out_valid;
	assign m_wdata = ax_w_buf[DATA_W-1:0];
	assign m_wstrb = ax_w_be[DATA_W/8-1:0];
	assign m_wlast = ax_w_beat == AX_AXLEN;
	assign m_wvalid = ax_w_busy;

	assign m_arid = ax_ar_out_data[LA_W];
	assign m_araddr = {ax_ar_out_data[LA_W-1:0], {LINE_SHIFT{1'b0}}};
	assign m_arvalid = ax_ar_out_valid;
	assign m_rready = 1'b1;

	wire m_rv_g0, m_rv_g1;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_mrv0 (.I0(m_rvalid), .O(m_rv_g0));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_mrv1 (.I0(m_rvalid), .O(m_rv_g1));
	wire ax_r_done, ax_r_done_u;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_rdone  (.I0(m_rv_g1), .I1(m_rlast), .O(ax_r_done));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_rdoneu (.I0(m_rv_g1), .I1(m_rlast), .O(ax_r_done_u));
	assign m_bready_raw = !ax_r_done;
	wire ax_b_fire = m_bvalid && m_bready_raw;

	wire [AX_NID*LINE_BITS-1:0] ax_r_lines;
	wire [AX_NID-1:0] ax_r_errs;

	genvar g_id, g_fe, g_rs;
	generate
		for (g_id = 0; g_id < AX_NID; g_id = g_id + 1) begin : g_ax_ids
			localparam GID = g_id[0];

			/* WQ FIFO (register-based, buffered per-entry enables -> fanout <= 16) */
			(* ram_style = "registers" *) reg [UW-1:0] wq_mem [0:AX_D-1];
			reg [AX_D*8-1:0] wq_keys;
			reg [AX_D-1:0] wq_full;
			reg [AX_O:0] wq_wp, wq_rp;
			wire [AX_O:0] wq_wp_nxt, wq_rp_nxt;
			wire wq_wco, wq_rco;
			am_add #(.W(AX_O + 1)) u_wq_w (.a(wq_wp), .b({(AX_O+1){1'b0}}), .ci(1'b1), .s(wq_wp_nxt), .co(wq_wco));
			am_add #(.W(AX_O + 1)) u_wq_r (.a(wq_rp), .b({(AX_O+1){1'b0}}), .ci(1'b1), .s(wq_rp_nxt), .co(wq_rco));
			assign ax_wq_rdy[g_id] = !((wq_wp[AX_O] != wq_rp[AX_O]) && (wq_wp[AX_O-1:0] == wq_rp[AX_O-1:0]));
			wire wq_oval = wq_wp != wq_rp;
			assign ax_wq_any[g_id] = wq_oval;
			wire wq_push = (ax_wr_take && ax_q_id == GID) && ax_wq_rdy[g_id];
			wire wq_pop = wq_oval && (ax_b_fire && ax_b_id == GID);
			wire [AX_O-1:0] wq_rp_b;
			for (g_fe = 0; g_fe < AX_O; g_fe = g_fe + 1) begin : g_wq_rpb
				(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rpb (.I0(wq_rp[g_fe]), .O(wq_rp_b[g_fe]));
			end
			assign ax_wq_user[g_id*UW +: UW] = wq_mem[wq_rp_b];
			wire [AX_D-1:0] wq_entry_match;
			for (g_fe = 0; g_fe < AX_D; g_fe = g_fe + 1) begin : g_wq_m
				assign wq_entry_match[g_fe] = wq_full[g_fe] && (wq_keys[g_fe*8 +: 8] == axi_req_key);
			end
			assign ax_wq_has[g_id] = |wq_entry_match;
			always @(posedge clk) begin
				if (mc_rst_sync2) begin
					wq_wp <= {(AX_O + 1){1'b0}};
					wq_rp <= {(AX_O + 1){1'b0}};
				end else begin
					if (wq_push)
						wq_wp <= wq_wp_nxt;
					if (wq_pop)
						wq_rp <= wq_rp_nxt;
				end
			end
			for (g_fe = 0; g_fe < AX_D; g_fe = g_fe + 1) begin : g_wq_ent
				wire wq_hit_w = wq_push && (wq_wp[AX_O-1:0] == g_fe[AX_O-1:0]);
				wire wq_hit_r = wq_pop && (wq_rp[AX_O-1:0] == g_fe[AX_O-1:0]);
				wire wq_we_m, wq_we_k;
				if (AX_NID == 1 && AX_O == 2) begin : g_wq_we_fast
					localparam [15:0] WQ_HIT_INIT = (16'h0008 << (g_fe * 4));
					(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(WQ_HIT_INIT)) u_wm (
						.I0(wv_g[0]), .I1(wr_g[0]), .I2(wq_wp[0]), .I3(wq_wp[1]),
						.O(wq_we_m)
					);
					(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(WQ_HIT_INIT)) u_wk (
						.I0(wv_g[0]), .I1(wr_g[0]), .I2(wq_wp[0]), .I3(wq_wp[1]),
						.O(wq_we_k)
					);
					wire unused_wq_hw = wq_hit_w;
				end else if (AX_NID == 2 && AX_O == 2) begin : g_wq_we_fast2
					localparam [31:0] WQ_HIT_INIT = (32'h00000001 << {g_fe[1:0], GID, 2'b11});
					(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(WQ_HIT_INIT)) u_wm (
						.I0(wv_g[0]), .I1(wr_g[0]), .I2(ax_q_id), .I3(wq_wp[0]), .I4(wq_wp[1]),
						.O(wq_we_m)
					);
					(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(WQ_HIT_INIT)) u_wk (
						.I0(wv_g[0]), .I1(wr_g[0]), .I2(ax_q_id), .I3(wq_wp[0]), .I4(wq_wp[1]),
						.O(wq_we_k)
					);
					wire unused_wq_hw = wq_hit_w;
				end else begin : g_wq_we_gen
					(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wm (.I0(wq_hit_w), .O(wq_we_m));
					(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wk (.I0(wq_hit_w), .O(wq_we_k));
				end
				always @(posedge clk) begin
					if (mc_rst_sync2) begin
						wq_full[g_fe] <= 1'b0;
					end else begin
						if (wq_hit_r)
							wq_full[g_fe] <= 1'b0;
						if (wq_we_k)
							wq_full[g_fe] <= 1'b1;
					end
					if (wq_we_k) begin
						wq_keys[g_fe*8 +: 8] <= axi_req_key;
						wq_mem[g_fe][UW-1:16] <= axi_req_user[UW-1:16];
					end
					if (wq_we_m)
						wq_mem[g_fe][15:0] <= axi_req_user[15:0];
				end
			end

			/* RQ FIFO (register-based, buffered per-entry enables -> fanout <= 16) */
			(* ram_style = "registers" *) reg [UW-1:0] rq_mem [0:AX_D-1];
			reg [AX_D*8-1:0] rq_keys;
			reg [AX_D-1:0] rq_full;
			reg [AX_O:0] rq_wp, rq_rp;
			wire [AX_O:0] rq_wp_nxt, rq_rp_nxt;
			wire rq_wco, rq_rco;
			am_add #(.W(AX_O + 1)) u_rq_w (.a(rq_wp), .b({(AX_O+1){1'b0}}), .ci(1'b1), .s(rq_wp_nxt), .co(rq_wco));
			am_add #(.W(AX_O + 1)) u_rq_r (.a(rq_rp), .b({(AX_O+1){1'b0}}), .ci(1'b1), .s(rq_rp_nxt), .co(rq_rco));
			assign ax_rq_rdy[g_id] = !((rq_wp[AX_O] != rq_rp[AX_O]) && (rq_wp[AX_O-1:0] == rq_rp[AX_O-1:0]));
			wire rq_oval = rq_wp != rq_rp;
			assign ax_rq_any[g_id] = rq_oval;
			wire rq_push = (ax_rd_take && ax_q_id == GID) && ax_rq_rdy[g_id];
			wire rq_pop = rq_oval && (ax_r_done && ax_r_id == GID);
			wire [AX_O-1:0] rq_rp_b;
			for (g_fe = 0; g_fe < AX_O; g_fe = g_fe + 1) begin : g_rq_rpb
				(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rpb (.I0(rq_rp[g_fe]), .O(rq_rp_b[g_fe]));
			end
			assign ax_rq_user[g_id*UW +: UW] = rq_mem[rq_rp_b];
			wire [AX_D-1:0] rq_entry_match;
			for (g_fe = 0; g_fe < AX_D; g_fe = g_fe + 1) begin : g_rq_m
				assign rq_entry_match[g_fe] = rq_full[g_fe] && (rq_keys[g_fe*8 +: 8] == axi_req_key);
			end
			assign ax_rq_has[g_id] = |rq_entry_match;
			always @(posedge clk) begin
				if (mc_rst_sync2) begin
					rq_wp <= {(AX_O + 1){1'b0}};
					rq_rp <= {(AX_O + 1){1'b0}};
				end else begin
					if (rq_push)
						rq_wp <= rq_wp_nxt;
					if (rq_pop)
						rq_rp <= rq_rp_nxt;
				end
			end
			for (g_fe = 0; g_fe < AX_D; g_fe = g_fe + 1) begin : g_rq_ent
				wire rq_hit_w = rq_push && (rq_wp[AX_O-1:0] == g_fe[AX_O-1:0]);
				wire rq_hit_r = rq_pop && (rq_rp[AX_O-1:0] == g_fe[AX_O-1:0]);
				wire rq_we_m, rq_we_k;
				if (AX_NID == 1 && AX_O == 2) begin : g_rq_we_fast
					localparam [15:0] RQ_HIT_INIT = (16'h0008 << (g_fe * 4));
					(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(RQ_HIT_INIT)) u_wm (
						.I0(rv_g), .I1(rr_g), .I2(rq_wp[0]), .I3(rq_wp[1]),
						.O(rq_we_m)
					);
					(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(RQ_HIT_INIT)) u_wk (
						.I0(rv_g), .I1(rr_g), .I2(rq_wp[0]), .I3(rq_wp[1]),
						.O(rq_we_k)
					);
					wire unused_rq_hw = rq_hit_w;
				end else if (AX_NID == 2 && AX_O == 2) begin : g_rq_we_fast2
					localparam [31:0] RQ_HIT_INIT = (32'h00000001 << {g_fe[1:0], GID, 2'b11});
					(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(RQ_HIT_INIT)) u_wm (
						.I0(rv_g), .I1(rr_g), .I2(ax_q_id), .I3(rq_wp[0]), .I4(rq_wp[1]),
						.O(rq_we_m)
					);
					(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(RQ_HIT_INIT)) u_wk (
						.I0(rv_g), .I1(rr_g), .I2(ax_q_id), .I3(rq_wp[0]), .I4(rq_wp[1]),
						.O(rq_we_k)
					);
					wire unused_rq_hw = rq_hit_w;
				end else begin : g_rq_we_gen
					(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wm (.I0(rq_hit_w), .O(rq_we_m));
					(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wk (.I0(rq_hit_w), .O(rq_we_k));
				end
				always @(posedge clk) begin
					if (mc_rst_sync2) begin
						rq_full[g_fe] <= 1'b0;
					end else begin
						if (rq_hit_r)
							rq_full[g_fe] <= 1'b0;
						if (rq_we_k)
							rq_full[g_fe] <= 1'b1;
					end
					if (rq_we_k) begin
						rq_keys[g_fe*8 +: 8] <= axi_req_key;
						rq_mem[g_fe][UW-1:16] <= axi_req_user[UW-1:16];
					end
					if (rq_we_m)
						rq_mem[g_fe][15:0] <= axi_req_user[15:0];
				end
			end

			wire me_r = m_rv_g0 && ax_r_id == GID;
			reg r_err;
			if (AX_BEATS == 1) begin : g_one_beat
				assign ax_r_lines[g_id*LINE_BITS +: LINE_BITS] = m_rdata;
			end else begin : g_multi_beats
				localparam RBUF_W = LINE_BITS - DATA_W;
				localparam RBUF_S = RBUF_W / 16;
				reg [RBUF_W-1:0] r_buf;
				wire [RBUF_S-1:0] me_r_b;
				assign ax_r_lines[g_id*LINE_BITS +: LINE_BITS] = {m_rdata, r_buf};
				for (g_rs = 0; g_rs < RBUF_S; g_rs = g_rs + 1) begin : g_rbuf_s
					(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_mer (
						.I0(me_r), .O(me_r_b[g_rs])
					);
					always @(posedge clk) begin
						if (me_r_b[g_rs])
							r_buf[g_rs*16 +: 16] <= ax_r_lines[g_id*LINE_BITS + DATA_W + g_rs*16 +: 16];
					end
				end
			end
			always @(posedge clk) begin
				if (mc_rst_sync2)
					r_err <= 1'b0;
				else if (me_r)
					r_err <= m_rlast ? 1'b0 : r_err | m_rresp[1];
			end
			assign ax_r_errs[g_id] = r_err;
			wire unused_ax_id = &{1'b0, wq_wco, wq_rco, rq_wco, rq_rco};
		end
	endgenerate

	wire [7:0] ax_w_beat_n;
	wire unused_ax_wb_co;
	am_add #(.W(8)) u_ax_w_beat (
		.a(ax_w_beat), .b(8'd1), .ci(1'b0), .s(ax_w_beat_n), .co(unused_ax_wb_co)
	);

	/* 18-slice buffered w_buf (256 bits) + w_be (32 bits) -> <= 3 LUTs, fanout <= 16 */

	wire [LINE_BITS-1:0] w_buf_shifted = ax_w_buf >> DATA_W;
	wire [LINE_BYTES-1:0] w_be_shifted = ax_w_be >> (DATA_W / 8);
	wire [17:0] w_en_b, w_sel_b;
	genvar g_ws, g_wb;
	generate
		for (g_ws = 0; g_ws < 16; g_ws = g_ws + 1) begin : g_wbuf_s
			localparam GRP = (g_ws >= 12) ? 2 : ((g_ws >= 6) ? 1 : 0);
			(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'hF888)) u_we (
				.I0(wv_g[GRP]), .I1(wr_g[GRP]), .I2(wb_g[GRP]), .I3(mw_g[GRP]),
				.O(w_en_b[g_ws])
			);
			(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_ws (
				.I0(wv_g[GRP]), .I1(wr_g[GRP]), .O(w_sel_b[g_ws])
			);
			wire [15:0] wbuf_nxt;
			for (g_wb = 0; g_wb < 16; g_wb = g_wb + 1) begin : g_wbuf_b
				(* DONT_TOUCH = "TRUE" *) LUT3 #(.INIT(8'hCA)) u_mx (
					.I0(w_buf_shifted[g_ws*16 + g_wb]),
					.I1(axi_req_wdata[g_ws*16 + g_wb]),
					.I2(w_sel_b[g_ws]),
					.O(wbuf_nxt[g_wb])
				);
			end
			always @(posedge clk) begin
				if (w_en_b[g_ws])
					ax_w_buf[g_ws*16 +: 16] <= wbuf_nxt;
			end
		end
		for (g_ws = 0; g_ws < 2; g_ws = g_ws + 1) begin : g_wbe_s
			(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'hF888)) u_we (
				.I0(wv_g[2]), .I1(wr_g[2]), .I2(wb_g[2]), .I3(mw_g[2]),
				.O(w_en_b[16 + g_ws])
			);
			(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_ws (
				.I0(wv_g[2]), .I1(wr_g[2]), .O(w_sel_b[16 + g_ws])
			);
			wire [15:0] wbe_nxt;
			for (g_wb = 0; g_wb < 16; g_wb = g_wb + 1) begin : g_wbe_b
				(* DONT_TOUCH = "TRUE" *) LUT3 #(.INIT(8'hCA)) u_mx (
					.I0(w_be_shifted[g_ws*16 + g_wb]),
					.I1(axi_req_be[g_ws*16 + g_wb]),
					.I2(w_sel_b[16 + g_ws]),
					.O(wbe_nxt[g_wb])
				);
			end
			always @(posedge clk) begin
				if (w_en_b[16 + g_ws])
					ax_w_be[g_ws*16 +: 16] <= wbe_nxt;
			end
		end
	endgenerate

	wire [7:0] ax_w_beat_mux;
	generate
		for (g_wb = 0; g_wb < 8; g_wb = g_wb + 1) begin : g_wbeat_mx
			(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h2)) u_bm (
				.I0(ax_w_beat_n[g_wb]), .I1(w_sel_b[0]), .O(ax_w_beat_mux[g_wb])
			);
		end
	endgenerate

	always @(posedge clk) begin
		if (mc_rst_sync1) begin
			ax_w_busy <= 1'b0;
			ax_w_beat <= 8'd0;
		end else begin
			if (w_en_b[0])
				ax_w_beat <= ax_w_beat_mux;
			if (ax_wr_take) begin
				ax_w_busy <= 1'b1;
			end else if (ax_w_busy && m_wready && m_wlast) begin
				ax_w_busy <= 1'b0;
			end
		end
	end

	/* 16-slice buffered rsp_rdata (256 bits) -> fanout <= 16 */
	wire [1:0] r_done_g;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_rdg0 (.I0(m_rv_g1), .I1(m_rlast), .O(r_done_g[0]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_rdg1 (.I0(m_rv_g1), .I1(m_rlast), .O(r_done_g[1]));
	wire [15:0] r_done_b;
	wire [LINE_BITS-1:0] r_line_sel = ax_r_lines[ax_r_id*LINE_BITS +: LINE_BITS];
	generate
		for (g_ws = 0; g_ws < 16; g_ws = g_ws + 1) begin : g_rsp_d_s
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rd (
				.I0(r_done_g[g_ws >= 8 ? 1 : 0]), .O(r_done_b[g_ws])
			);
			always @(posedge clk) begin
				if (r_done_b[g_ws])
					ax_rsp_rdata_r[g_ws*16 +: 16] <= r_line_sel[g_ws*16 +: 16];
			end
		end
	endgenerate

	wire ax_rsp_hdr_en;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_rhe (
		.I0(ax_r_done), .I1(ax_b_fire), .O(ax_rsp_hdr_en)
	);
	always @(posedge clk) begin
		if (mc_rst_sync) begin
			ax_rsp_valid_r <= 1'b0;
		end else begin
			ax_rsp_valid_r <= ax_r_done || ax_b_fire;
		end
		if (ax_rsp_hdr_en) begin
			ax_rsp_write_r <= !ax_r_done;
			ax_rsp_user_r <= ax_r_done_u ? ax_rq_user[ax_r_id*UW +: UW] : ax_wq_user[ax_b_id*UW +: UW];
			ax_rsp_error_r <= ax_r_done ? (ax_r_errs[ax_r_id] | m_rresp[1]) : m_bresp[1];
		end
	end
	wire unused_ax_ok = &{1'b0, unused_ax_wb_co, m_bresp[0], m_rresp[0]};
`else
	am_axi_master #(
		.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
		.DATA_W(DATA_W), .UW(UW), .OUTSTANDING_LOG2(OUTSTANDING_LOG2),
		.NID(HAS_LOCAL != 0 ? 2 : 1), .ID_W(1), .KEY_W(8)
	) axi (
		.clk(clk), .rst_n(rst_n), .halt(1'b0), .idle(m_idle), .req_valid(axi_req_valid),
		.req_ready(axi_req_ready), .req_write(axi_req_write), .req_line(axi_req_line), .req_be(axi_req_be),
		.req_wdata(axi_req_wdata), .req_user(axi_req_user), .req_id(axi_req_id),
		.req_key(axi_req_key), .rsp_valid(ax_rsp_valid), .rsp_write(ax_rsp_write),
		.rsp_user(ax_rsp_user), .rsp_rdata(ax_rsp_rdata), .rsp_error(ax_rsp_error),
		.m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
		.m_awburst(m_awburst), .m_awcache(m_awcache), .m_awprot(m_awprot),
		.m_awvalid(m_awvalid), .m_awready(m_awready), .m_wdata(m_wdata),
		.m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
		.m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready_raw),
		.m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
		.m_arburst(m_arburst), .m_arcache(m_arcache), .m_arprot(m_arprot),
		.m_arvalid(m_arvalid), .m_arready(m_arready), .m_rid(m_rid), .m_rdata(m_rdata),
		.m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready)
	);
`endif

	assign l2_idle_out = l2_idle;
	assign fsm = {!(m_idle && l2_idle), !axi_idle, !chk_idle, !unit_idle};
	wire unused_ok = &{1'b0, bad_head, s_req_valid};
endmodule

`default_nettype wire
