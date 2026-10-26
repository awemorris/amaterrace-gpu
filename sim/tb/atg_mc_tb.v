/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_tb: atg_mc in two shapes, each on its own axi_mem: (A) three
 * clients (client 0 with the priority bit, 1 and 2 taking turns) in a
 * two-level router tree; (B) five clients with client 4 one hop from the
 * root (ROOT_CLIENT, the DC's place) and clients 0 and 4 with the priority
 * bit, and a 1 MiB VRAM window (VRAM_AW 20), where some refused requests
 * are outside the window as well.  Each client runs random reads and
 * byte-masked writes on its own lines and checks its responses (data
 * against a reference, tags in order per direction).  Some requests fall
 * outside the aperture: they must get an error response without reaching
 * memory, and the MC's fault pulse must name the client, the line and the
 * direction.  Quiesce is raised at random: no new packet may start under it
 * and axi_idle must come within a bound.  At the end every client must
 * have been granted.  Responses are routed per client through the tree: a
 * response that reached the wrong client fails the data or the order
 * check of the receiver.  The router's priority and turn-taking are
 * checked in detail by atg_rt_tb.  A refused read returns zeros.
 * unit_idle (all clients counted, but D's and E's root) must say whether a request is
 * outstanding, every cycle.  (C) is shape B with session protection
 * built in (HAS_PROT: the root client has its own entry at the root) and
 * every request without chk: it must behave as B.  The protection check
 * itself is atg_mc_prot_tb's.  (D) is shape B with ROOT_KEEP (the DC's
 * place: quiesce-exempt, its own entry) and (E) the same with HAS_PROT:
 * every quiesce that reaches axi_idle ends with a flush pulse, the root
 * client goes on through quiesce and flush and must lose no response, and
 * axi_idle must come at least once while the root client has requests out
 * (it does not wait for them).
 * (F, ws288 p039) is shape B with protection
 * and two destinations: local memory [0x2_0000, 0x4_0000) (LOCAL_BASE/
 * LOCAL_BYTES, AXI ID 0) and the host (ID 1) behind am_axi_split, each on
 * its own axi_mem (the local one slow); half of each client's lines are
 * local (the client's line l + 0x1000 for l >= 16): every client still
 * gets its responses in order per direction, and each memory sees only
 * its own ID.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_client #(
	parameter ID = 0,
	parameter NREQ = 600,
	parameter SEED = 1,
	parameter FAR = 0,	/* some refused requests also outside a 1 MiB VRAM window */
	parameter TWO = 0,	/* lines 16-31 at +0x1000 lines (local memory in case F) */
	parameter BAD_DIV = 40	/* one request in BAD_DIV is refused */
) (
	input wire clk,
	input wire rst_n,
	input wire stop,		/* quiesce in the TB: do not count stalls */
	output reg req_valid,
	input wire req_ready,
	output reg req_write,
	output reg [26:0] req_line,
	output reg [31:0] req_be,
	output reg [255:0] req_wdata,
	output reg [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [255:0] rsp_rdata,
	input wire rsp_error,
	output reg finished,
	output integer errors,
	output integer bad_issued
);
	localparam NLINES = 32;
	localparam [26:0] BASE = 27'h100 + ID * NLINES;	/* inside the aperture */
	localparam [26:0] OUTSIDE = 27'h7000 + ID * NLINES;

	reg [255:0] ref [0:NLINES-1];
	integer rd_pend [0:NLINES-1];
	integer wr_pend [0:NLINES-1];
	reg [255:0] rd_expect [0:127];
	reg rd_bad [0:127];
	reg [4:0] rd_ln [0:127];
	reg wr_bad [0:127];
	reg [4:0] wr_ln [0:127];
	integer rd_seq, wr_seq, rd_next, wr_next, issued, answered;
	integer seed, n, b, line;
	reg wr, bad;
	reg [255:0] mask;

	/* Responses: the good ones in order per direction; a refused
	 * request's error may overtake (atg_mc: it is a device fault). */
	reg rd_done [0:127];
	reg wr_done [0:127];
	integer s0, found;

	always @(posedge clk) begin
		if (rst_n && rsp_valid) begin
			answered = answered + 1;
			found = -1;
			if (rsp_write) begin
				for (s0 = wr_next; s0 < wr_seq; s0 = s0 + 1)
					if (found < 0 && !wr_done[s0 % 128] && wr_bad[s0 % 128] == rsp_error &&
					    (rsp_error ? rsp_tag[6:0] == s0[6:0] : 1'b1))
						found = s0;
				if (found < 0 || rsp_tag !== {1'b1, found[6:0]}) begin
					errors = errors + 1;
					$display("FAIL atg_mc: client %0d write tag %h error %b, expected %h", ID,
						rsp_tag, rsp_error, found);
				end else begin
					wr_done[found % 128] = 1'b1;
					if (!rsp_error)
						wr_pend[wr_ln[found % 128]] = wr_pend[wr_ln[found % 128]] - 1;
				end
				while (wr_next < wr_seq && wr_done[wr_next % 128])
					wr_next = wr_next + 1;
			end else begin
				for (s0 = rd_next; s0 < rd_seq; s0 = s0 + 1)
					if (found < 0 && !rd_done[s0 % 128] && rd_bad[s0 % 128] == rsp_error &&
					    (rsp_error ? rsp_tag[6:0] == s0[6:0] : 1'b1))
						found = s0;
				if (found < 0 || rsp_tag !== {1'b0, found[6:0]}) begin
					errors = errors + 1;
					$display("FAIL atg_mc: client %0d read tag %h error %b, expected %h", ID,
						rsp_tag, rsp_error, found);
				end else begin
					if (!rsp_error && rsp_rdata !== rd_expect[found % 128]) begin
						errors = errors + 1;
						$display("FAIL atg_mc: client %0d read data", ID);
					end
					if (rsp_error && rsp_rdata !== 256'd0) begin
						errors = errors + 1;
						$display("FAIL atg_mc: client %0d refused read data not 0", ID);
					end
					rd_done[found % 128] = 1'b1;
					if (!rsp_error)
						rd_pend[rd_ln[found % 128]] = rd_pend[rd_ln[found % 128]] - 1;
				end
				while (rd_next < rd_seq && rd_done[rd_next % 128])
					rd_next = rd_next + 1;
			end
		end
	end

	initial begin
		req_valid = 1'b0;
		req_write = 1'b0;
		req_line = 0;
		req_be = 0;
		req_wdata = 0;
		req_tag = 0;
		finished = 1'b0;
		errors = 0;
		bad_issued = 0;
		seed = SEED;
		rd_seq = 0;
		wr_seq = 0;
		rd_next = 0;
		wr_next = 0;
		issued = 0;
		answered = 0;
		for (n = 0; n < NLINES; n = n + 1) begin
			ref[n] = 0;
			rd_pend[n] = 0;
			wr_pend[n] = 0;
		end
		wait (rst_n);
		@(posedge clk);
		while (issued < NREQ) begin
			line = $unsigned($random(seed)) % NLINES;
			bad = ($unsigned($random(seed)) % BAD_DIV) == 0;
			wr = $random(seed);
			if (rd_seq - rd_next > 100 || wr_seq - wr_next > 100 ||
			    (wr ? (rd_pend[line] != 0) : (wr_pend[line] != 0))) begin
				@(posedge clk);
			end else begin
				req_write <= wr;
				/* With FAR, half of the refused requests alias a good line of
				 * the 1 MiB window: only the window check refuses them. */
				req_line <= (bad ? ((FAR != 0 && line[0]) ? BASE + 27'h8000 : OUTSIDE) : BASE) +
					line + (TWO != 0 && !bad && line >= 16 ? 27'h1000 : 27'h0);
				for (b = 0; b < 32; b = b + 1)
					req_be[b] <= $random(seed);
				for (b = 0; b < 8; b = b + 1)
					req_wdata[b*32 +: 32] <= $random(seed);
				req_tag <= wr ? {1'b1, wr_seq[6:0]} : {1'b0, rd_seq[6:0]};
				req_valid <= 1'b1;
				@(posedge clk);
				while (!req_ready)
					@(posedge clk);
				if (wr) begin
					wr_bad[wr_seq % 128] = bad;
					wr_done[wr_seq % 128] = 1'b0;
					wr_ln[wr_seq % 128] = line;
					if (!bad) begin
						for (b = 0; b < 32; b = b + 1)
							mask[b*8 +: 8] = {8{req_be[b]}};
						ref[line] = (ref[line] & ~mask) | (req_wdata & mask);
						wr_pend[line] = wr_pend[line] + 1;
					end
					wr_seq = wr_seq + 1;
				end else begin
					rd_bad[rd_seq % 128] = bad;
					rd_done[rd_seq % 128] = 1'b0;
					rd_ln[rd_seq % 128] = line;
					rd_expect[rd_seq % 128] = ref[line];
					if (!bad)
						rd_pend[line] = rd_pend[line] + 1;
					rd_seq = rd_seq + 1;
				end
				if (bad)
					bad_issued = bad_issued + 1;
				issued = issued + 1;
				req_valid <= 1'b0;
			end
		end
		n = 0;
		while (answered < issued && n < 2000) begin
			@(posedge clk);
			n = n + 1;
		end
		if (answered != issued) begin
			errors = errors + 1;
			$display("FAIL atg_mc: client %0d: %0d requests, %0d responses", ID, issued, answered);
		end
		finished = 1'b1;
	end

	wire unused_ok = &{1'b0, stop};
endmodule

module atg_mc_case #(
	parameter N = 3,
	parameter [N-1:0] HIGH = 1,
	parameter ROOT = -1,
	parameter VRAM_AW = 32,
	parameter FAR = 0,
	parameter PROT = 0,
	parameter TWO = 0,	/* two destinations (case F) */
	parameter KEEP = 0,	/* ROOT_KEEP, ROOT in QUIESCE_EXEMPT, flush after each quiesce */
	parameter URGENT = 0,	/* exercise dc_urgent / dc_panic preemption */
	parameter SEED0 = 3
) (
	input wire clk,
	output reg done,
	output integer errors
);
	reg rst_n = 1'b0;
	reg quiesce = 1'b0;
	reg flush = 1'b0;
	reg dc_urgent = 1'b0;
	reg dc_panic = 1'b0;
	integer urgent_pulses = 0;
	integer panic_pulses = 0;
	integer seed;
	localparam [N-1:0] EXEMPT = KEEP != 0 ? {{(N-1){1'b0}}, 1'b1} << ROOT : {N{1'b0}};

	wire [N-1:0] c_req_valid, c_req_ready, c_req_write;
	wire [N*27-1:0] c_req_line;
	wire [N*32-1:0] c_req_be;
	wire [N*256-1:0] c_req_wdata;
	wire [N*8-1:0] c_req_tag;
	wire [N-1:0] rsp_valid, rsp_write, rsp_error;
	wire [N*8-1:0] rsp_tag;
	wire [N*256-1:0] rsp_rdata;
	wire axi_idle, fault, fault_write, unit_idle;
	wire [7:0] fault_client;
	wire [31:0] fault_addr;
	wire [N-1:0] fin;
	wire [31:0] cerr [0:N-1];
	wire [31:0] cbad [0:N-1];

	wire [31:0] awaddr, araddr;
	wire [7:0] awlen, arlen;
	wire [2:0] awsize, arsize, awprot, arprot;
	wire [1:0] awburst, arburst, bresp, rresp;
	wire [3:0] awcache, arcache;
	wire awvalid, awready, wlast, wvalid, wready, bvalid, bready;
	wire arvalid, arready, rlast, rvalid, rready;
	wire [63:0] wdata, rdata;
	wire [7:0] wstrb;

	wire awid, arid, bid, rid;

	atg_mc #(.NCLIENT(N), .HIGH_MASK(HIGH), .ROOT_CLIENT(ROOT), .VRAM_AW(VRAM_AW),
		.UNIT_MASK(~EXEMPT), .HAS_PROT(PROT), .ROOT_KEEP(KEEP),
		.QUIESCE_EXEMPT(EXEMPT),
		.LOCAL_BASE(TWO != 0 ? 32'h00020000 : 32'd0),
		.LOCAL_BYTES(TWO != 0 ? 32'h00020000 : 32'd0)) dut (
		.clk(clk), .rst_n(rst_n),
		.c_req_valid(c_req_valid), .c_req_ready(c_req_ready), .c_req_write(c_req_write),
		.c_req_line(c_req_line), .c_req_be(c_req_be), .c_req_wdata(c_req_wdata),
		.c_req_tag(c_req_tag), .c_req_chk({N{1'b0}}), .c_req_tbl({N{1'b0}}),
		.c_req_slot({6*N{1'b0}}), .rsp_valid(rsp_valid), .rsp_write(rsp_write),
		.rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
		.quiesce(quiesce), .flush(flush),
		.aperture_base(32'h00002000), .aperture_limit(32'h00080000),
		.axi_idle(axi_idle), .fault(fault), .fault_client(fault_client),
		.fault_addr(fault_addr), .fault_write(fault_write), .fault_prot(), .fault_slot(),
		.fault_mem(), .chk_idle(), .unit_idle(unit_idle),
		.dc_urgent(dc_urgent), .dc_panic(dc_panic),
		.prot_tbase(32'd0), .prot_inv_valid(1'b0), .prot_inv_g(20'd0), .prot_inv_n(32'd0),
		.prot_inv_pending(), .prot_gw_valid(1'b0), .prot_gw_idx(3'd0), .prot_gw_data(50'd0),
		.m_awid(awid), .m_bid(bid), .m_arid(arid), .m_rid(rid),
		.m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(awburst),
		.m_awcache(awcache), .m_awprot(awprot), .m_awvalid(awvalid), .m_awready(awready),
		.m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid),
		.m_wready(wready), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
		.m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(arburst),
		.m_arcache(arcache), .m_arprot(arprot), .m_arvalid(arvalid), .m_arready(arready),
		.m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast), .m_rvalid(rvalid),
		.m_rready(rready)
	);

	/* One memory, or two behind am_axi_split (case F: m0 local, m1 host). */
	wire [31:0] mem_errors;

	generate
		if (TWO == 0) begin : one
			axi_mem #(.DATA_W(64), .MEM_BYTES(1 << 20), .SEED(9)) mem (
				.clk(clk), .rst_n(rst_n),
				.awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
				.awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
				.wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp),
				.bvalid(bvalid), .bready(bready), .araddr(araddr), .arlen(arlen),
				.arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
				.rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
			);
			assign bid = 1'b0;
			assign rid = 1'b0;
			assign mem_errors = mem.errors;
		end else begin : two
			wire [31:0] p_awaddr [0:1];
			wire [31:0] p_araddr [0:1];
			wire [7:0] p_awlen [0:1];
			wire [7:0] p_arlen [0:1];
			wire [2:0] p_awsize [0:1];
			wire [2:0] p_arsize [0:1];
			wire [1:0] p_awburst [0:1];
			wire [1:0] p_arburst [0:1];
			wire [1:0] p_bresp [0:1];
			wire [1:0] p_rresp [0:1];
			wire [63:0] p_wdata [0:1];
			wire [63:0] p_rdata [0:1];
			wire [7:0] p_wstrb [0:1];
			wire [1:0] p_awid, p_arid, p_awvalid, p_awready, p_wlast, p_wvalid, p_wready;
			wire [1:0] p_bvalid, p_bready, p_arvalid, p_arready, p_rlast, p_rvalid, p_rready;

			am_axi_split #(
				.A_W(32), .D_W(64), .ID_W(1), .BASE0(32'h00020000), .SIZE0(32'h00020000),
				.BASE1(32'h00000000), .SIZE1(32'h00100000)
			) split (
				.clk(clk), .rst_n(rst_n),
				.s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize),
				.s_awburst(awburst), .s_awcache(awcache), .s_awprot(awprot),
				.s_awvalid(awvalid), .s_awready(awready), .s_wdata(wdata), .s_wstrb(wstrb),
				.s_wlast(wlast), .s_wvalid(wvalid), .s_wready(wready), .s_bid(bid),
				.s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready), .s_arid(arid),
				.s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize), .s_arburst(arburst),
				.s_arcache(arcache), .s_arprot(arprot), .s_arvalid(arvalid),
				.s_arready(arready), .s_rid(rid), .s_rdata(rdata), .s_rresp(rresp),
				.s_rlast(rlast), .s_rvalid(rvalid), .s_rready(rready),
				.m0_awid(p_awid[0]), .m0_awaddr(p_awaddr[0]), .m0_awlen(p_awlen[0]),
				.m0_awsize(p_awsize[0]), .m0_awburst(p_awburst[0]), .m0_awcache(),
				.m0_awprot(), .m0_awvalid(p_awvalid[0]), .m0_awready(p_awready[0]),
				.m0_wdata(p_wdata[0]), .m0_wstrb(p_wstrb[0]), .m0_wlast(p_wlast[0]),
				.m0_wvalid(p_wvalid[0]), .m0_wready(p_wready[0]), .m0_bid(1'b0),
				.m0_bresp(p_bresp[0]), .m0_bvalid(p_bvalid[0]), .m0_bready(p_bready[0]),
				.m0_arid(p_arid[0]), .m0_araddr(p_araddr[0]), .m0_arlen(p_arlen[0]),
				.m0_arsize(p_arsize[0]), .m0_arburst(p_arburst[0]), .m0_arcache(),
				.m0_arprot(), .m0_arvalid(p_arvalid[0]), .m0_arready(p_arready[0]),
				.m0_rid(1'b0), .m0_rdata(p_rdata[0]), .m0_rresp(p_rresp[0]),
				.m0_rlast(p_rlast[0]), .m0_rvalid(p_rvalid[0]), .m0_rready(p_rready[0]),
				.m1_awid(p_awid[1]), .m1_awaddr(p_awaddr[1]), .m1_awlen(p_awlen[1]),
				.m1_awsize(p_awsize[1]), .m1_awburst(p_awburst[1]), .m1_awcache(),
				.m1_awprot(), .m1_awvalid(p_awvalid[1]), .m1_awready(p_awready[1]),
				.m1_wdata(p_wdata[1]), .m1_wstrb(p_wstrb[1]), .m1_wlast(p_wlast[1]),
				.m1_wvalid(p_wvalid[1]), .m1_wready(p_wready[1]), .m1_bid(1'b1),
				.m1_bresp(p_bresp[1]), .m1_bvalid(p_bvalid[1]), .m1_bready(p_bready[1]),
				.m1_arid(p_arid[1]), .m1_araddr(p_araddr[1]), .m1_arlen(p_arlen[1]),
				.m1_arsize(p_arsize[1]), .m1_arburst(p_arburst[1]), .m1_arcache(),
				.m1_arprot(), .m1_arvalid(p_arvalid[1]), .m1_arready(p_arready[1]),
				.m1_rid(1'b1), .m1_rdata(p_rdata[1]), .m1_rresp(p_rresp[1]),
				.m1_rlast(p_rlast[1]), .m1_rvalid(p_rvalid[1]), .m1_rready(p_rready[1])
			);

			genvar m;
			for (m = 0; m < 2; m = m + 1) begin : mems
				/* The local memory (m0) answers slowly: more reordering between the two. */
				axi_mem #(.DATA_W(64), .MEM_BYTES(1 << 20), .SEED(9 + 4 * m),
					.READ_EARLY(m == 0 ? 1 : 0)) mem (
					.clk(clk), .rst_n(rst_n),
					.awaddr(p_awaddr[m]), .awlen(p_awlen[m]), .awsize(p_awsize[m]),
					.awburst(p_awburst[m]), .awvalid(p_awvalid[m]), .awready(p_awready[m]),
					.wdata(p_wdata[m]), .wstrb(p_wstrb[m]), .wlast(p_wlast[m]),
					.wvalid(p_wvalid[m]), .wready(p_wready[m]), .bresp(p_bresp[m]),
					.bvalid(p_bvalid[m]), .bready(p_bready[m]), .araddr(p_araddr[m]),
					.arlen(p_arlen[m]), .arsize(p_arsize[m]), .arburst(p_arburst[m]),
					.arvalid(p_arvalid[m]), .arready(p_arready[m]), .rdata(p_rdata[m]),
					.rresp(p_rresp[m]), .rlast(p_rlast[m]), .rvalid(p_rvalid[m]),
					.rready(p_rready[m])
				);
			end

			/* Each memory sees only its own ID (the MC's destination). */
			always @(posedge clk) begin
				if (rst_n && (p_awvalid[0] && p_awid[0] || p_arvalid[0] && p_arid[0] ||
				    p_awvalid[1] && !p_awid[1] || p_arvalid[1] && !p_arid[1])) begin
					errors = errors + 1;
					$display("FAIL atg_mc: an AXI ID at the wrong memory");
				end
			end

			assign mem_errors = mems[0].mem.errors + mems[1].mem.errors;
		end
	endgenerate

	genvar g;
	generate
		for (g = 0; g < N; g = g + 1) begin : cl
			/* KEEP: the root client's refusals often meet a flush. */
			atg_mc_client #(.ID(g), .SEED(SEED0 * 100 + g), .FAR(FAR), .TWO(TWO),
				.BAD_DIV(KEEP != 0 && g == ROOT ? 4 : 40)) c (
				.clk(clk), .rst_n(rst_n), .stop(quiesce),
				.req_valid(c_req_valid[g]), .req_ready(c_req_ready[g]),
				.req_write(c_req_write[g]), .req_line(c_req_line[g*27 +: 27]),
				.req_be(c_req_be[g*32 +: 32]), .req_wdata(c_req_wdata[g*256 +: 256]),
				.req_tag(c_req_tag[g*8 +: 8]), .rsp_valid(rsp_valid[g]),
				.rsp_write(rsp_write[g]), .rsp_tag(rsp_tag[g*8 +: 8]),
				.rsp_rdata(rsp_rdata[g*256 +: 256]),
				.rsp_error(rsp_error[g]), .finished(fin[g]), .errors(cerr[g]),
				.bad_issued(cbad[g])
			);
		end
	endgenerate

	/* Grants, faults, quiesce. */
	integer grants [0:N-1];
	integer faults [0:N-1];
	integer wait_idle;
	integer q_taken [0:N-1];
	integer k;
	reg [26:0] line_k;
	integer outst, outst_root, idle_root;
	initial for (k = 0; k < N; k = k + 1) q_taken[k] = 0;
	initial outst = 0;
	initial outst_root = 0;
	initial idle_root = 0;

	/* unit_idle against the requests taken and not answered. */
	always @(posedge clk) begin
		if (rst_n) begin
			if (unit_idle !== (outst - (KEEP != 0 ? outst_root : 0) == 0)) begin
				errors = errors + 1;
				$display("FAIL atg_mc: unit_idle %b with %0d outstanding", unit_idle, outst);
			end
			if (axi_idle && outst_root != 0)
				idle_root = idle_root + 1;
			for (k = 0; k < N; k = k + 1)
				outst = outst + (c_req_valid[k] && c_req_ready[k] ? 1 : 0) -
					(rsp_valid[k] ? 1 : 0);
			if (ROOT >= 0)
				outst_root = outst_root + (c_req_valid[ROOT] && c_req_ready[ROOT] ? 1 : 0) -
					(rsp_valid[ROOT] ? 1 : 0);
		end
	end

	always @(posedge clk) begin
		if (rst_n) begin
			/* Under quiesce no new packet starts at a leaf: a client has at
			 * most one request taken (a write whose header was already in
			 * the tree); the tree drains. */
			for (k = 0; k < N; k = k + 1) begin
				if (c_req_ready[k] && c_req_valid[k]) begin
					grants[k] = grants[k] + 1;
					if (quiesce)
						q_taken[k] = q_taken[k] + 1;
				end
				if (!quiesce || EXEMPT[k])
					q_taken[k] = 0;
				if (q_taken[k] > 1) begin
					errors = errors + 1;
					$display("FAIL atg_mc: client %0d taken twice under quiesce", k);
					q_taken[k] = 0;
				end
			end
			/* A refused request: the fault comes one cycle after its
			 * grant and names it. */
			if (fault) begin
				if (fault_client >= N) begin
					errors = errors + 1;
					$display("FAIL atg_mc: fault client %0d", fault_client);
				end else begin
					faults[fault_client] = faults[fault_client] + 1;
					line_k = fault_addr[31:5];
					/* The root reports the window offset over VRAM_BASE (0). */
					if ((line_k < 27'h7000 + fault_client * 32 ||
					    line_k >= 27'h7000 + fault_client * 32 + 32) &&
					    !(FAR != 0 && line_k >= 27'h100 + fault_client * 32 &&
					    line_k < 27'h100 + fault_client * 32 + 32)) begin
						errors = errors + 1;
						$display("FAIL atg_mc: fault address %h for client %0d",
							fault_addr, fault_client);
					end
				end
			end
			if ((awvalid && awaddr >= 32'h00080000) || (arvalid && araddr >= 32'h00080000)) begin
				errors = errors + 1;
				$display("FAIL atg_mc: a refused request reached AXI");
			end
			if (dc_panic && ROOT != -1 && dut.grant.a_valid) begin
				errors = errors + 1;
				$display("FAIL atg_mc: non-root grant valid during dc_panic");
			end
		end
	end

	initial begin
		done = 1'b0;
		errors = 0;
		seed = SEED0;
		if ($value$plusargs("seed=%d", seed))
			seed = seed + SEED0;
		for (k = 0; k < N; k = k + 1) begin
			grants[k] = 0;
			faults[k] = 0;
		end
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		while (fin != {N{1'b1}}) begin
			@(posedge clk);
			if (URGENT != 0 && $unsigned($random(seed)) % 150 == 0 && !quiesce) begin
				dc_urgent <= 1'b1;
				urgent_pulses = urgent_pulses + 1;
				if ($unsigned($random(seed)) % 2 == 0) begin
					dc_panic <= 1'b1;
					panic_pulses = panic_pulses + 1;
				end
				repeat ($unsigned($random(seed)) % 25 + 5) @(posedge clk);
				dc_panic <= 1'b0;
				dc_urgent <= 1'b0;
			end
			if ($unsigned($random(seed)) % 300 == 0) begin
				quiesce <= 1'b1;
				wait_idle = 0;
				@(posedge clk);
				while (!axi_idle && wait_idle < 500) begin
					@(posedge clk);
					wait_idle = wait_idle + 1;
				end
				if (!axi_idle) begin
					errors = errors + 1;
					$display("FAIL atg_mc: no AXI_IDLE under quiesce");
				end
				/* KEEP: flush (the CP's RESET order: with quiesce held, after
				 * axi_idle) in about half of the cycles, so that some hit a
				 * response or refusal of the root client on its way. */
				repeat ($unsigned($random(seed)) % 20) begin
					flush <= KEEP != 0 && axi_idle && $random(seed) % 2 == 0;
					@(posedge clk);
				end
				flush <= 1'b0;
				quiesce <= 1'b0;
			end
		end
		repeat (10) @(posedge clk);
		for (k = 0; k < N; k = k + 1) begin
			errors = errors + cerr[k];
			if (grants[k] == 0) begin
				errors = errors + 1;
				$display("FAIL atg_mc: client %0d never granted", k);
			end
			if (faults[k] != cbad[k]) begin
				errors = errors + 1;
				$display("FAIL atg_mc: client %0d %0d faults for %0d refused", k,
					faults[k], cbad[k]);
			end
		end
		errors = errors + mem_errors;
		if (KEEP != 0 && idle_root == 0) begin
			errors = errors + 1;
			$display("FAIL atg_mc: axi_idle never came with the root client's requests out");
		end
		if (URGENT != 0 && (urgent_pulses == 0 || panic_pulses == 0)) begin
			errors = errors + 1;
			$display("FAIL atg_mc: urgent/panic pulses not injected (%0d / %0d)",
				urgent_pulses, panic_pulses);
		end
		done = 1'b1;
	end
endmodule

module atg_mc_tb;
	reg clk = 1'b0;
	wire done_a, done_b, done_c, done_d, done_e, done_f;
	wire [31:0] err_a, err_b, err_c, err_d, err_e, err_f;

	always #5 clk = !clk;

	atg_mc_case #(.N(3), .HIGH(3'b001), .ROOT(-1), .VRAM_AW(32), .FAR(0), .SEED0(3)) a (
		.clk(clk), .done(done_a), .errors(err_a)
	);
	atg_mc_case #(.N(5), .HIGH(5'b10001), .ROOT(4), .VRAM_AW(20), .FAR(1), .SEED0(7)) b (
		.clk(clk), .done(done_b), .errors(err_b)
	);
	atg_mc_case #(.N(5), .HIGH(5'b10001), .ROOT(4), .VRAM_AW(20), .FAR(1), .PROT(1),
		.SEED0(11)) c (
		.clk(clk), .done(done_c), .errors(err_c)
	);
	atg_mc_case #(.N(5), .HIGH(5'b10001), .ROOT(4), .VRAM_AW(20), .FAR(1), .KEEP(1),
		.URGENT(1), .SEED0(13)) d (
		.clk(clk), .done(done_d), .errors(err_d)
	);
	atg_mc_case #(.N(5), .HIGH(5'b10001), .ROOT(4), .VRAM_AW(20), .FAR(1), .PROT(1),
		.KEEP(1), .SEED0(17)) e (
		.clk(clk), .done(done_e), .errors(err_e)
	);
	atg_mc_case #(.N(5), .HIGH(5'b10001), .ROOT(4), .VRAM_AW(32), .FAR(0), .PROT(1), .TWO(1),
		.SEED0(19)) f (
		.clk(clk), .done(done_f), .errors(err_f)
	);

	initial begin
		wait (done_a && done_b && done_c && done_d && done_e && done_f);
		if (err_a == 0 && err_b == 0 && err_c == 0 && err_d == 0 && err_e == 0 && err_f == 0)
			$display("PASS atg_mc");
		else
			$display("FAIL atg_mc: %0d + %0d + %0d + %0d + %0d + %0d errors", err_a, err_b,
				err_c, err_d, err_e, err_f);
		$finish;
	end

	initial begin
		#40000000;
		$display("FAIL atg_mc: timeout");
		$finish;
	end
endmodule

`default_nettype wire
