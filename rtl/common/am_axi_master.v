/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_axi_master: turns memory-line requests into AXI bursts.  One request
 * is one line of LINE_BYTES: a read returns the line, a write sends it with
 * per-byte enables.  A line is one INCR burst of LINE_BYTES * 8 / DATA_W
 * beats of DATA_W bits (4 beats of 64 bits for a 32-byte line on a Zynq HP
 * port; 1 beat of 512 bits for a 64-byte line on the KC705's MIG).  Lines
 * are aligned, so no burst crosses a 4 KiB boundary.
 *
 * Every request carries UW bits of user data (the MC puts the client and
 * its tag there) that come back with its response.  Every request has
 * exactly one response: a read's with the line, a write's after its BRESP.
 * error is set for SLVERR and DECERR.  There is no back-pressure on
 * responses: the receiver takes rsp_valid when it comes.  R is always
 * ready; B waits for a cycle in which no read response is made.
 *
 * IDs (ws288 p039): each request names one of NID AXI IDs (req_id; the MC
 * uses one per destination, docs/ghci.md section 11.2).  The bursts of one
 * ID are answered in order (AXI), reads and writes separately; those of
 * different IDs may be answered in any order, and the read beats of
 * different IDs may interleave (each ID has its own line buffer).  The
 * order key (req_key, the MC's client): a request is not accepted while a
 * burst of the same direction and key is outstanding on another ID, so the
 * requests of one key are answered in order, reads and writes each (a read
 * and a write are not ordered against each other).  NID = 1: one ID, 0.
 *
 * Up to 2^OUTSTANDING_LOG2 reads and as many writes are in flight per ID.  A write
 * is accepted when its address and all of its beats can go out, and its
 * beats follow from a line buffer, so W never waits for a request.
 *
 * Quiesce: while halt is 1 no new request is accepted (req_ready is 0);
 * an accepted write still sends all of its beats and every outstanding
 * burst still gets its response.  idle is 1 when every accepted request's
 * response has been delivered (rsp_valid included).
 *
 * The AXI signals follow AXI4; an AXI3 port (a Zynq HP port) takes the low
 * four bits of m_awlen/m_arlen and the low two of m_awsize/m_arsize, and
 * its WID is 0 (and its AxID the low bits of m_awid/m_arid).  AxCACHE is 0011 (normal, non-cacheable, bufferable),
 * AxPROT 000, AxBURST INCR.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_axi_master #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter DATA_W = 64,
	parameter UW = 16,
	parameter OUTSTANDING_LOG2 = 2,	/* per ID and direction */
	parameter NID = 1,	/* AXI IDs used: 1 (ID 0) or 2^ID_W */
	parameter ID_W = 1,	/* AxID bits */
	parameter KEY_W = 8	/* order key bits */
) (
	input wire clk,
	input wire rst_n,

	input wire halt,
	output wire idle,

	input wire req_valid,
	output wire req_ready,
	input wire req_write,
	input wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	input wire [LINE_BYTES-1:0] req_be,
	input wire [LINE_BYTES*8-1:0] req_wdata,
	input wire [UW-1:0] req_user,
	input wire [ID_W-1:0] req_id,
	input wire [KEY_W-1:0] req_key,

	output reg rsp_valid,
	output reg rsp_write,
	output reg [UW-1:0] rsp_user,
	output reg [LINE_BYTES*8-1:0] rsp_rdata,
	output reg rsp_error,

	output wire [ID_W-1:0] m_awid,
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
	input wire [ID_W-1:0] m_bid,
	input wire [1:0] m_bresp,
	input wire m_bvalid,
	output wire m_bready,
	output wire [ID_W-1:0] m_arid,
	output wire [ADDR_W-1:0] m_araddr,
	output wire [7:0] m_arlen,
	output wire [2:0] m_arsize,
	output wire [1:0] m_arburst,
	output wire [3:0] m_arcache,
	output wire [2:0] m_arprot,
	output wire m_arvalid,
	input wire m_arready,
	input wire [ID_W-1:0] m_rid,
	input wire [DATA_W-1:0] m_rdata,
	input wire [1:0] m_rresp,
	input wire m_rlast,
	input wire m_rvalid,
	output wire m_rready
);
	localparam LINE_BITS = LINE_BYTES * 8;
	localparam BEATS = LINE_BITS / DATA_W;
	/* verilator lint_off WIDTHTRUNC */
	localparam [7:0] AXLEN = BEATS - 1;
	/* verilator lint_on WIDTHTRUNC */
	localparam [2:0] AXSIZE = DATA_W == 8 ? 3'd0 : DATA_W == 16 ? 3'd1 :
		DATA_W == 32 ? 3'd2 : DATA_W == 64 ? 3'd3 : DATA_W == 128 ? 3'd4 :
		DATA_W == 256 ? 3'd5 : DATA_W == 512 ? 3'd6 : 3'd7;
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam O = OUTSTANDING_LOG2;

	/* The burst attributes. */
	assign m_awlen = AXLEN;
	assign m_arlen = AXLEN;
	assign m_awsize = AXSIZE;
	assign m_arsize = AXSIZE;
	assign m_awburst = 2'b01;
	assign m_arburst = 2'b01;
	assign m_awcache = 4'b0011;
	assign m_arcache = 4'b0011;
	assign m_awprot = 3'b000;
	assign m_arprot = 3'b000;

	/* The IDs as indices (NID = 1: all 0). */
	wire [ID_W-1:0] q_id = NID > 1 ? req_id : {ID_W{1'b0}};
	wire [ID_W-1:0] b_id = NID > 1 ? m_bid : {ID_W{1'b0}};
	wire [ID_W-1:0] r_id = NID > 1 ? m_rid : {ID_W{1'b0}};

	/* Users of the outstanding bursts, in order, per ID: their room
	 * (wq_rdy/rq_rdy), the key's presence (wq_has/rq_has), the oldest's
	 * user (wq_user/rq_user) and whether any is outstanding. */
	wire [NID-1:0] wq_rdy, wq_has, wq_any, rq_rdy, rq_has, rq_any;
	wire [NID*UW-1:0] wq_user, rq_user;

	/* Write path: the address register, the line buffer and the beat. */
	reg aw_v;
	reg [LA_W-1:0] aw_line;
	reg [ID_W-1:0] aw_id;
	reg w_busy;
	reg [7:0] w_beat;
	reg [LINE_BITS-1:0] w_buf;
	reg [LINE_BYTES-1:0] w_be;

	/* Read path. */
	reg ar_v;
	reg [LA_W-1:0] ar_line;
	reg [ID_W-1:0] ar_id;

	/* A burst of the key on another ID (same direction). */
`ifdef MUT_AXI_NOKEY
	wire w_other = 1'b0, r_other = 1'b0;
`else
	wire w_other = |(wq_has & ~({{(NID-1){1'b0}}, 1'b1} << q_id));
	wire r_other = |(rq_has & ~({{(NID-1){1'b0}}, 1'b1} << q_id));
`endif

	wire wr_can = !halt && !aw_v && !w_busy && wq_rdy[q_id] && !w_other;
	wire rd_can = !halt && !ar_v && rq_rdy[q_id] && !r_other;

	assign req_ready = rst_n && (req_write ? wr_can : rd_can);
	wire wr_take = req_valid && req_ready && req_write;
	wire rd_take = req_valid && req_ready && !req_write;

	assign idle = !aw_v && !w_busy && !ar_v && !(|wq_any) && !(|rq_any) && !rsp_valid;

	assign m_awid = aw_id;
	assign m_awaddr = {aw_line, {LINE_SHIFT{1'b0}}};
	assign m_awvalid = aw_v;
	assign m_wdata = w_buf[DATA_W-1:0];
	assign m_wstrb = w_be[DATA_W/8-1:0];
	assign m_wlast = w_beat == AXLEN;
	assign m_wvalid = w_busy;

	assign m_arid = ar_id;
	assign m_araddr = {ar_line, {LINE_SHIFT{1'b0}}};
	assign m_arvalid = ar_v;
	assign m_rready = 1'b1;

	wire r_done = m_rvalid && m_rlast;
	assign m_bready = !r_done;
	wire b_fire = m_bvalid && m_bready;

	/* Per ID: the user FIFOs and the line being read (beat 0 lowest: the
	 * beats so far are kept in the top of r_buf and shifted down as the
	 * next one arrives), with its error. */
	wire [NID*LINE_BITS-1:0] r_lines;
	wire [NID-1:0] r_errs;

	genvar g;
	generate
		for (g = 0; g < NID; g = g + 1) begin : ids
			localparam [ID_W-1:0] GID = g;
			wire [O:0] wq_count, rq_count;
			wire wq_out_valid, rq_out_valid;
			wire me_r = m_rvalid && r_id == GID;
			reg r_err;

			am_fifo_key #(.W(UW), .KEY_W(KEY_W), .DEPTH_LOG2(O)) wq (
				.clk(clk), .rst_n(rst_n),
				.in_valid(wr_take && q_id == GID), .in_ready(wq_rdy[g]),
				.in_data(req_user), .in_key(req_key),
				.out_valid(wq_out_valid), .out_ready(b_fire && b_id == GID),
				.out_data(wq_user[g*UW +: UW]), .count(wq_count), .key(req_key),
				.has(wq_has[g])
			);
			am_fifo_key #(.W(UW), .KEY_W(KEY_W), .DEPTH_LOG2(O)) rq (
				.clk(clk), .rst_n(rst_n),
				.in_valid(rd_take && q_id == GID), .in_ready(rq_rdy[g]),
				.in_data(req_user), .in_key(req_key),
				.out_valid(rq_out_valid), .out_ready(r_done && r_id == GID),
				.out_data(rq_user[g*UW +: UW]), .count(rq_count), .key(req_key),
				.has(rq_has[g])
			);

			assign wq_any[g] = wq_count != {(O + 1){1'b0}};
			assign rq_any[g] = rq_count != {(O + 1){1'b0}};

			if (BEATS == 1) begin : one_beat
				assign r_lines[g*LINE_BITS +: LINE_BITS] = m_rdata;
			end else begin : beats
				reg [LINE_BITS-DATA_W-1:0] r_buf;

				assign r_lines[g*LINE_BITS +: LINE_BITS] = {m_rdata, r_buf};

				always @(posedge clk) begin
					if (!rst_n)
						r_buf <= {(LINE_BITS - DATA_W){1'b0}};
					else if (me_r)
						r_buf <= r_lines[g*LINE_BITS+DATA_W +: LINE_BITS-DATA_W];
				end
			end

			always @(posedge clk) begin
				if (!rst_n)
					r_err <= 1'b0;
				else if (me_r)
					r_err <= m_rlast ? 1'b0 : r_err | m_rresp[1];
			end

			assign r_errs[g] = r_err;

			/* A response with nothing outstanding is a broken slave; the
			 * FIFOs do not underflow on it (sim/models/axi_mem.v checks the
			 * slave). */
			wire unused_q = &{1'b0, wq_out_valid, rq_out_valid};
		end
	endgenerate

	always @(posedge clk) begin
		if (!rst_n) begin
			aw_v <= 1'b0;
			aw_line <= {LA_W{1'b0}};
			aw_id <= {ID_W{1'b0}};
			w_busy <= 1'b0;
			w_beat <= 8'd0;
			w_buf <= {LINE_BITS{1'b0}};
			w_be <= {LINE_BYTES{1'b0}};
		end else begin
			if (wr_take) begin
				aw_v <= 1'b1;
				aw_line <= req_line;
				aw_id <= q_id;
				w_busy <= 1'b1;
				w_beat <= 8'd0;
				w_buf <= req_wdata;
				w_be <= req_be;
			end else begin
				if (aw_v && m_awready)
					aw_v <= 1'b0;
				if (w_busy && m_wready) begin
					w_beat <= w_beat + 8'd1;
					w_buf <= w_buf >> DATA_W;
					w_be <= w_be >> (DATA_W / 8);
					if (m_wlast)
						w_busy <= 1'b0;
				end
			end
		end
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			ar_v <= 1'b0;
			ar_line <= {LA_W{1'b0}};
			ar_id <= {ID_W{1'b0}};
		end else begin
			if (rd_take) begin
				ar_v <= 1'b1;
				ar_line <= req_line;
				ar_id <= q_id;
			end else if (ar_v && m_arready) begin
				ar_v <= 1'b0;
			end
		end
	end

	/* One response per cycle: a finished read first, else a BRESP. */
	always @(posedge clk) begin
		if (!rst_n) begin
			rsp_valid <= 1'b0;
			rsp_write <= 1'b0;
			rsp_user <= {UW{1'b0}};
			rsp_rdata <= {LINE_BITS{1'b0}};
			rsp_error <= 1'b0;
		end else if (r_done) begin
			rsp_valid <= 1'b1;
			rsp_write <= 1'b0;
			rsp_user <= rq_user[r_id*UW +: UW];
			rsp_rdata <= r_lines[r_id*LINE_BITS +: LINE_BITS];
			rsp_error <= r_errs[r_id] | m_rresp[1];
		end else if (b_fire) begin
			rsp_valid <= 1'b1;
			rsp_write <= 1'b1;
			rsp_user <= wq_user[b_id*UW +: UW];
			rsp_error <= m_bresp[1];
		end else begin
			rsp_valid <= 1'b0;
		end
	end

	wire unused_ok = &{1'b0, m_bresp[0], m_rresp[0]};
endmodule

`default_nettype wire
