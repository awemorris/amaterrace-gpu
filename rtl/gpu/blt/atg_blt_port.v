/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_port: the AMB port of the blitter's 2D engine (atg_blt_2d): the
 * request register, the outstanding reads and writes, the three line
 * buffers that the read responses fill (by tag: 0 and 1 the source lines,
 * 2 the destination line), and the error flag.
 *
 * issue (taken only while free, i.e. no request is held) loads the
 * request; it is held on req_* until the MC takes it.  rd_idle and wr_idle
 * are 1 when no read, no write is outstanding (the request register
 * included only once taken).  An error response sets fail until clr (the
 * kick).  The tag is {5'd0, write, slot}.  See spec/gpu/blt/atg_blt_port.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_port #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	input wire clr,
	/* The engine's request */
	input wire issue,
	input wire i_write,
	input wire [ADDR_W-LINE_SHIFT-1:0] i_line,
	input wire [1:0] i_slot,
	input wire [LINE_BYTES-1:0] i_be,
	input wire [LINE_BYTES*8-1:0] i_wdata,
	output reg free,
	output wire rd_idle,
	output wire wr_idle,
`ifdef SYNTH_KINTEX7
	(* max_fanout = 16 *) output reg fail,
`else
	output reg fail,
`endif
	output reg [LINE_BYTES*8-1:0] buf0,
	output reg [LINE_BYTES*8-1:0] buf1,
	output reg [LINE_BYTES*8-1:0] bufd,
	/* The AMB port */
	output reg req_valid,
	input wire req_ready,
	output reg req_write,
	output reg [ADDR_W-LINE_SHIFT-1:0] req_line,
	(* extract_reset = "no" *) output reg [LINE_BYTES-1:0] req_be,
	output reg [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	localparam LA_W = ADDR_W - LINE_SHIFT;
	(* max_fanout = 16 *) reg [1:0] slot;
	(* max_fanout = 16 *) reg [3:0] wr_out;
	(* max_fanout = 16 *) reg [1:0] rd_out;
	(* max_fanout = 16 *) reg rd_idle_q, wr_idle_q;
	(* max_fanout = 16 *) wire q_fire = req_valid && req_ready;
	(* keep = "true" *) wire rsp_rd = rsp_valid && !rsp_write;
	(* keep = "true" *) wire rsp_wr = rsp_valid && rsp_write;
`ifdef SYNTH_KINTEX7
	(* max_fanout = 16 *) wire can_issue_ctrl = issue;
	(* max_fanout = 16 *) wire can_issue_lo   = issue;
	(* max_fanout = 16 *) wire can_issue_hi   = issue;
`else
	wire can_issue_ctrl = issue && free;
	wire can_issue_lo = issue && free;
	wire can_issue_hi = issue && free;
`endif

	assign rd_idle = rd_idle_q;
	assign wr_idle = wr_idle_q;
	assign req_tag = {5'd0, req_write, slot};

	/* The writes and the reads outstanding: one more for a request, one fewer for a response. */
	wire [3:0] wr_up, wr_next;
	wire [1:0] rd_up, rd_next;
	wire [3:0] out_co_unused;

	am_add #(.W(4)) a_wr (.a(wr_out), .b(4'd0), .ci(q_fire && req_write), .s(wr_up), .co(out_co_unused[0]));
	am_sub #(.W(4)) s_wr (.a(wr_up), .b(4'd0), .bi(rsp_wr), .d(wr_next), .bo(out_co_unused[1]));
	am_add #(.W(2)) a_rd (.a(rd_out), .b(2'd0), .ci(q_fire && !req_write), .s(rd_up), .co(out_co_unused[2]));
	am_sub #(.W(2)) s_rd (.a(rd_up), .b(2'd0), .bi(rsp_rd), .d(rd_next), .bo(out_co_unused[3]));

`ifdef SYNTH_KINTEX7
	localparam NUM_SLICES = (LINE_BYTES * 8) / 16;

	(* keep = "true", dont_touch = "true" *) wire ce_b0_root, ce_b1_root, ce_bd_root;
	LUT4 #(.INIT(16'h0002)) u_root_b0 (.I0(rsp_valid), .I1(rsp_write), .I2(rsp_tag[0]), .I3(rsp_tag[1]), .O(ce_b0_root));
	LUT4 #(.INIT(16'h0020)) u_root_b1 (.I0(rsp_valid), .I1(rsp_write), .I2(rsp_tag[0]), .I3(rsp_tag[1]), .O(ce_b1_root));
	LUT4 #(.INIT(16'h2200)) u_root_bd (.I0(rsp_valid), .I1(rsp_write), .I2(rsp_tag[0]), .I3(rsp_tag[1]), .O(ce_bd_root));

	(* keep = "true", dont_touch = "true" *) wire iss_lo_root, iss_hi_root;
	LUT1 #(.INIT(2'b10)) u_iss_lo (.I0(i_write), .O(iss_lo_root));
	LUT1 #(.INIT(2'b10)) u_iss_hi (.I0(i_write), .O(iss_hi_root));

	genvar si;
	generate
		for (si = 0; si < NUM_SLICES; si = si + 1) begin : g_buf_slice
			(* keep = "true", dont_touch = "true" *) wire ce_b0;
			(* keep = "true", dont_touch = "true" *) wire ce_b1;
			(* keep = "true", dont_touch = "true" *) wire ce_bd;
			(* keep = "true", dont_touch = "true" *) wire ce_iss;

			LUT1 #(.INIT(2'b10)) u_buf_b0 (.I0(ce_b0_root), .O(ce_b0));
			LUT1 #(.INIT(2'b10)) u_buf_b1 (.I0(ce_b1_root), .O(ce_b1));
			LUT1 #(.INIT(2'b10)) u_buf_bd (.I0(ce_bd_root), .O(ce_bd));
			LUT1 #(.INIT(2'b10)) u_buf_iss (.I0(si < 8 ? iss_lo_root : iss_hi_root), .O(ce_iss));

			always @(posedge clk) begin
				if (ce_b0)
					buf0[si*16 +: 16] <= rsp_rdata[si*16 +: 16];
				if (ce_b1)
					buf1[si*16 +: 16] <= rsp_rdata[si*16 +: 16];
				if (ce_bd)
					bufd[si*16 +: 16] <= rsp_rdata[si*16 +: 16];
				if (ce_iss)
					req_wdata[si*16 +: 16] <= i_wdata[si*16 +: 16];
			end
		end
	endgenerate

	(* max_fanout = 16 *) wire can_issue_be0 = issue;
	(* max_fanout = 16 *) wire can_issue_be1 = issue;

	always @(posedge clk) begin
		if (can_issue_be0)
			req_be[LINE_BYTES/2-1:0] <= i_be[LINE_BYTES/2-1:0];
		if (can_issue_be1)
			req_be[LINE_BYTES-1:LINE_BYTES/2] <= i_be[LINE_BYTES-1:LINE_BYTES/2];
	end
`endif

	always @(posedge clk) begin
		if (can_issue_lo)
			req_line[15:0] <= i_line[15:0];
		if (can_issue_hi)
			req_line[LA_W-1:16] <= i_line[LA_W-1:16];
		if (can_issue_ctrl) begin
			slot <= i_slot;
`ifndef SYNTH_KINTEX7
			req_be <= i_be;
			req_wdata <= i_wdata;
`endif
		end
`ifndef SYNTH_KINTEX7
		if (rsp_rd) begin
			case (rsp_tag[1:0])
			2'd0: buf0 <= rsp_rdata;
			2'd1: buf1 <= rsp_rdata;
			default: bufd <= rsp_rdata;
			endcase
		end
`endif
	end

	(* keep = "true", dont_touch = "true" *) wire rst_port_high = !rst_n;

	always @(posedge clk) begin
		if (rst_port_high) begin
			req_valid <= 1'b0;
			free <= 1'b1;
			req_write <= 1'b0;
			wr_out <= 4'd0;
			rd_out <= 2'd0;
			wr_idle_q <= 1'b1;
			rd_idle_q <= 1'b1;
			fail <= 1'b0;
		end else begin
			wr_out <= wr_next;
			rd_out <= rd_next;
			wr_idle_q <= (wr_next == 4'd0);
			rd_idle_q <= (rd_next == 2'd0);
			if (clr)
				fail <= 1'b0;
			else if (rsp_valid && rsp_error)
				fail <= 1'b1;
			if (q_fire) begin
				req_valid <= 1'b0;
				free <= 1'b1;
			end
			if (can_issue_ctrl) begin
				req_valid <= 1'b1;
				free <= 1'b0;
				req_write <= i_write;
			end
		end
	end

	wire unused_ok = &{1'b0, rsp_tag[7:2], out_co_unused};
endmodule

`default_nettype wire
