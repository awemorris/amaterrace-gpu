/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_dcache: The SU's data cache: 1 KiB direct-mapped (32 lines of 32
 * bytes), write-through, read-allocate, flash-invalidated; between the
 * LSU's line requests and the MC.
 *
 * One request at a time (u_req_ready only in IDLE).  Read hit: the
 * response the next cycle.  Read miss: the line is read from the MC,
 * filled (unless inv came meanwhile or the MC answered an error) and
 * returned.  Write: through to the MC with the byte enables; a line that
 * is present when the MC answers is updated with the written bytes; the
 * response follows the MC's.  inv clears every valid bit at once.  The
 * response carries the request's tag; m_req_tag is 0 (one outstanding).
 *
 * States: IDLE →(hit)→ RESP → IDLE; IDLE →(miss / write)→ MREQ
 * →(m_req_ready)→ MWAIT →(m_rsp)→ RESP → IDLE.
*/

`timescale 1ns / 1ps
`default_nettype none

module atg_su_dcache #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter DC_BYTES = 1024	/* Size in bytes */
) (
	input wire clk,
	input wire rst_n,
	input wire inv,
	/* AMB client port (design §4.1) */
	input wire u_req_valid,
	output wire u_req_ready,
	input wire u_req_write,
	input wire [ADDR_W-LINE_SHIFT-1:0] u_req_line,
	input wire [LINE_BYTES-1:0] u_req_be,
	input wire [LINE_BYTES*8-1:0] u_req_wdata,
	input wire [7:0] u_req_tag,
	output wire u_rsp_valid,
	output wire u_rsp_write,
	output wire [7:0] u_rsp_tag,
	output wire [LINE_BYTES*8-1:0] u_rsp_rdata,
	output wire u_rsp_error,
	/* AMB client port (design §4.1) */
	output wire m_req_valid,
	input wire m_req_ready,
	output wire m_req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] m_req_line,
	output wire [LINE_BYTES-1:0] m_req_be,
	output wire [LINE_BYTES*8-1:0] m_req_wdata,
	output wire [7:0] m_req_tag,
	input wire m_rsp_valid,
	input wire m_rsp_write,
	input wire [7:0] m_rsp_tag,
	input wire [LINE_BYTES*8-1:0] m_rsp_rdata,
	input wire m_rsp_error
);
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LB = LINE_BYTES * 8;
	localparam NL = DC_BYTES / LINE_BYTES;
	localparam IW = NL > 1 ? $clog2(NL) : 1;
	localparam TW = LA_W - IW;
	localparam [1:0] IDLE = 2'd0, MREQ = 2'd1, MWAIT = 2'd2, RESP = 2'd3;

	reg [1:0] st;
	reg [NL-1:0] valid;
	reg [TW-1:0] tags [0:NL-1];
	reg [LB-1:0] data [0:NL-1];
	/* The request in progress. */
	reg q_write, q_drop;
	reg [LA_W-1:0] q_line;
	reg [LINE_BYTES-1:0] q_be;
	reg [LB-1:0] q_wdata;
	reg [7:0] q_tag;
	/* The response. */
	reg r_write, r_error;
	reg [LB-1:0] r_rdata;

	wire [IW-1:0] u_idx = u_req_line[IW-1:0];
	wire u_hit = valid[u_idx] && tags[u_idx] == u_req_line[LA_W-1:IW];
	wire [IW-1:0] q_idx = q_line[IW-1:0];
	wire q_hit = valid[q_idx] && tags[q_idx] == q_line[LA_W-1:IW];
	wire take = st == IDLE && u_req_valid;

	/* The data are read synchronously (block RAM): d_q is the request's
	 * line, read when it is taken; nothing else writes the line until the
	 * request's own fill or merge. */
	reg [LB-1:0] d_q;
	reg r_hit;	/* the response is d_q (a read hit) */
	always @(posedge clk)
		if (take)
			d_q <= data[u_idx];
	/* The line with the written bytes merged. */
	wire [LB-1:0] q_old = d_q;
	reg [LB-1:0] merged;
	integer b;
	always @(*) begin
		merged = q_old;
		for (b = 0; b < LINE_BYTES; b = b + 1)
			if (q_be[b])
				merged[b*8 +: 8] = q_wdata[b*8 +: 8];
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
			valid <= {NL{1'b0}};
			q_drop <= 1'b0;
			r_write <= 1'b0;
			r_error <= 1'b0;
			r_hit <= 1'b0;
		end else begin
			case (st)
			IDLE: if (take) begin
				q_write <= u_req_write;
				q_line <= u_req_line;
				q_be <= u_req_be;
				q_wdata <= u_req_wdata;
				q_tag <= u_req_tag;
				q_drop <= 1'b0;
				r_write <= u_req_write;
				r_error <= 1'b0;
				r_hit <= !u_req_write && u_hit;
				if (!u_req_write && u_hit)
					st <= RESP;
				else
					st <= MREQ;
			end
			MREQ: if (m_req_ready)
				st <= MWAIT;
			MWAIT: if (m_rsp_valid) begin
				r_error <= m_rsp_error;
				r_rdata <= m_rsp_rdata;
				if (!m_rsp_error && !q_drop && !inv) begin
					if (!q_write) begin
						valid[q_idx] <= 1'b1;
						tags[q_idx] <= q_line[LA_W-1:IW];
						data[q_idx] <= m_rsp_rdata;
					end else if (q_hit)
						data[q_idx] <= merged;
				end
				st <= RESP;
			end
			default: st <= IDLE;
			endcase
			if (inv) begin
				valid <= {NL{1'b0}};
				q_drop <= 1'b1;
			end
		end
	end

	assign u_req_ready = st == IDLE;
	assign u_rsp_valid = st == RESP;
	assign u_rsp_write = r_write;
	assign u_rsp_tag = q_tag;
	assign u_rsp_rdata = r_hit ? d_q : r_rdata;
	assign u_rsp_error = r_error;
	assign m_req_valid = st == MREQ;
	assign m_req_write = q_write;
	assign m_req_line = q_line;
	assign m_req_be = q_be;
	assign m_req_wdata = q_wdata;
	assign m_req_tag = 8'd0;

	wire unused_ok = &{1'b0, m_rsp_write, m_rsp_tag};
endmodule

`default_nettype wire
