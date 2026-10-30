/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_dbg: the asynchronous debug memory port DBG_ADDR/DBG_DATA/
 * DBG_STATUS: one word read or written through the CP's AMB port.
 *
 * Writing DBG_ADDR (when not busy) sets the word address (4-byte aligned)
 * and starts a read; writing DBG_DATA (when not busy) stores the value and
 * starts a write of it, with its byte strobes, to DBG_ADDR.  Writes while
 * busy are dropped.  The request is held until req_ready; its response
 * (tag 0) clears busy, sets DBG_STATUS.error = rsp_error (a refusal is not
 * a device fault) and, for a read, loads DBG_DATA; ev_done pulses.  It
 * works in every CP state: atg_cp lifts the MC's quiesce for the CP's own
 * requests.  dbg_busy (STATUS[0]) is DBG_STATUS.busy.  rst_n is the core
 * reset (CTRL.RESET clears the port).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_dbg #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	/* HCR register snoop (from atg_cp_regs) */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output wire [31:0] hcr_rdata,
	output wire ev_done,
	output wire dbg_busy,
	/* AMB client port (design §4.1) */
	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	`include "ghci_regs.vh"

	localparam WS = LINE_SHIFT - 2;	/* log2(words per line) */
	localparam [9:0] I_ADDR = GHCI_DBG_ADDR[11:2];
	localparam [9:0] I_DATA = GHCI_DBG_DATA[11:2];
	localparam [9:0] I_STATUS = GHCI_DBG_STATUS[11:2];

	reg busy;
	reg err;
	reg [31:0] addr;
	reg [31:0] data;
	reg q_valid;
	reg q_write;
	reg [31:0] q_word;
	reg [3:0] q_strb;

	wire wr_addr = hcr_we && hcr_widx == I_ADDR;
	wire wr_data = hcr_we && hcr_widx == I_DATA;
	wire [31:0] wmerge_a = (addr & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
	wire [31:0] wmerge_d = (data & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
	wire [WS-1:0] word = addr[LINE_SHIFT-1:2];

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire dbg_rst_high;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_dbg_rst (.I0(rst_n), .O(dbg_rst_high));

	wire addr_we = !busy && wr_addr;
	wire [1:0] addr_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_awe0 (.I0(addr_we), .O(addr_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_awe1 (.I0(addr_we), .O(addr_we_b[1]));

	wire data_we_host = !busy && wr_data;
	wire [1:0] q_word_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_qw0 (.I0(data_we_host), .O(q_word_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_qw1 (.I0(data_we_host), .O(q_word_we_b[1]));

	wire data_we_rsp = rsp_valid && busy && !rsp_write && !rsp_error;
	wire [3:0] data_we_rsp_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_dwr0 (.I0(data_we_rsp), .O(data_we_rsp_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_dwr1 (.I0(data_we_rsp), .O(data_we_rsp_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_dwr2 (.I0(data_we_rsp), .O(data_we_rsp_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_dwr3 (.I0(data_we_rsp), .O(data_we_rsp_b[3]));

	wire [3:0] data_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_dwe0 (.I0(data_we_host), .I1(data_we_rsp), .O(data_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_dwe1 (.I0(data_we_host), .I1(data_we_rsp), .O(data_we_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_dwe2 (.I0(data_we_host), .I1(data_we_rsp), .O(data_we_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_dwe3 (.I0(data_we_host), .I1(data_we_rsp), .O(data_we_b[3]));

	wire [1:0] rd_addr_b, rd_data_b;
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'h0000010000000000)) u_rda0 (
		.I0(hcr_ridx[0]), .I1(hcr_ridx[1]), .I2(hcr_ridx[2]), .I3(hcr_ridx[3]), .I4(hcr_ridx[4]), .I5(hcr_ridx[5]),
		.O(rd_addr_b[0])
	);
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'h0000010000000000)) u_rda1 (
		.I0(hcr_ridx[0]), .I1(hcr_ridx[1]), .I2(hcr_ridx[2]), .I3(hcr_ridx[3]), .I4(hcr_ridx[4]), .I5(hcr_ridx[5]),
		.O(rd_addr_b[1])
	);
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'h0000020000000000)) u_rdd0 (
		.I0(hcr_ridx[0]), .I1(hcr_ridx[1]), .I2(hcr_ridx[2]), .I3(hcr_ridx[3]), .I4(hcr_ridx[4]), .I5(hcr_ridx[5]),
		.O(rd_data_b[0])
	);
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'h0000020000000000)) u_rdd1 (
		.I0(hcr_ridx[0]), .I1(hcr_ridx[1]), .I2(hcr_ridx[2]), .I3(hcr_ridx[3]), .I4(hcr_ridx[4]), .I5(hcr_ridx[5]),
		.O(rd_data_b[1])
	);
	wire rd_stat_dbg;
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'h0000040000000000)) u_rds (
		.I0(hcr_ridx[0]), .I1(hcr_ridx[1]), .I2(hcr_ridx[2]), .I3(hcr_ridx[3]), .I4(hcr_ridx[4]), .I5(hcr_ridx[5]),
		.O(rd_stat_dbg)
	);

	wire [WS-1:0] word_be;
	wire [WS-1:0] word_b0, word_b1, word_b2, word_b3;
	genvar g_wb;
	generate
		for (g_wb = 0; g_wb < WS; g_wb = g_wb + 1) begin : g_word_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wbe (.I0(word[g_wb]), .O(word_be[g_wb]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wb0 (.I0(word[g_wb]), .O(word_b0[g_wb]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wb1 (.I0(word[g_wb]), .O(word_b1[g_wb]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wb2 (.I0(word[g_wb]), .O(word_b2[g_wb]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wb3 (.I0(word[g_wb]), .O(word_b3[g_wb]));
		end
	endgenerate
`endif

	assign req_valid = q_valid;
	assign req_write = q_write;
	assign req_line = addr[ADDR_W-1:LINE_SHIFT];
	assign req_wdata = {(LINE_BYTES / 4){q_word}};
	/* The word's byte enables in the line: q_strb at word (a constant place per word). */
	reg [LINE_BYTES-1:0] be_w;
	integer bw;
	always @(*)
		for (bw = 0; bw < LINE_BYTES / 4; bw = bw + 1)
`ifdef SYNTH_KINTEX7
			be_w[bw*4 +: 4] = {{(32 - WS){1'b0}}, word_be} == bw ? q_strb : 4'h0;
`else
			be_w[bw*4 +: 4] = {{(32 - WS){1'b0}}, word} == bw ? q_strb : 4'h0;
`endif
	assign req_be = be_w;
	assign req_tag = 8'd0;

`ifdef SYNTH_KINTEX7
	wire [31:0] rsp_word = {
		rsp_rdata[{word_b3, 5'd0} + 24 +: 8],
		rsp_rdata[{word_b2, 5'd0} + 16 +: 8],
		rsp_rdata[{word_b1, 5'd0} + 8 +: 8],
		rsp_rdata[{word_b0, 5'd0} +: 8]
	};
`else
	wire [31:0] rsp_word = rsp_rdata[{word, 5'd0} +: 32];
`endif
	assign ev_done = rsp_valid && busy;
	assign dbg_busy = busy;

	always @(posedge clk) begin
`ifdef SYNTH_KINTEX7
		if (dbg_rst_high) begin
`else
		if (!rst_n) begin
`endif
			busy <= 1'b0;
			err <= 1'b0;
			addr <= 32'd0;
			data <= 32'd0;
			q_valid <= 1'b0;
			q_write <= 1'b0;
			q_word <= 32'd0;
			q_strb <= 4'd0;
		end else begin
			if (q_valid && req_ready)
				q_valid <= 1'b0;
`ifdef SYNTH_KINTEX7
			if (addr_we_b[0]) addr[15:0] <= wmerge_a[15:0] & 16'hFFFC;
			if (addr_we_b[1]) addr[31:16] <= wmerge_a[31:16];
			if (q_word_we_b[0]) q_word[15:0] <= hcr_wdata[15:0];
			if (q_word_we_b[1]) q_word[31:16] <= hcr_wdata[31:16];
			if (!busy && wr_addr) begin
				busy <= 1'b1;
				err <= 1'b0;
				q_valid <= 1'b1;
				q_write <= 1'b0;
			end else if (!busy && wr_data) begin
				busy <= 1'b1;
				err <= 1'b0;
				q_valid <= 1'b1;
				q_write <= 1'b1;
				q_strb <= {hcr_wmask[24], hcr_wmask[16], hcr_wmask[8], hcr_wmask[0]};
			end
			if (data_we_b[0]) data[7:0] <= data_we_rsp_b[0] ? rsp_word[7:0] : wmerge_d[7:0];
			if (data_we_b[1]) data[15:8] <= data_we_rsp_b[1] ? rsp_word[15:8] : wmerge_d[15:8];
			if (data_we_b[2]) data[23:16] <= data_we_rsp_b[2] ? rsp_word[23:16] : wmerge_d[23:16];
			if (data_we_b[3]) data[31:24] <= data_we_rsp_b[3] ? rsp_word[31:24] : wmerge_d[31:24];
			if (rsp_valid && busy) begin
				busy <= 1'b0;
				err <= rsp_error;
			end
`else
			if (!busy && wr_addr) begin
				addr <= wmerge_a & 32'hFFFFFFFC;
				busy <= 1'b1;
				err <= 1'b0;
				q_valid <= 1'b1;
				q_write <= 1'b0;
			end else if (!busy && wr_data) begin
				data <= wmerge_d;
				busy <= 1'b1;
				err <= 1'b0;
				q_valid <= 1'b1;
				q_write <= 1'b1;
				q_word <= hcr_wdata;
				q_strb <= {hcr_wmask[24], hcr_wmask[16], hcr_wmask[8], hcr_wmask[0]};
			end
			if (rsp_valid && busy) begin
				busy <= 1'b0;
				err <= rsp_error;
				if (!rsp_write && !rsp_error)
					data <= rsp_word;
			end
`endif
		end
	end

`ifdef SYNTH_KINTEX7
	assign hcr_rdata = {
		rd_addr_b[1] ? addr[31:16] : rd_data_b[1] ? data[31:16] : 16'd0,
		rd_addr_b[0] ? addr[15:0]  : rd_data_b[0] ? data[15:0]  : (rd_stat_dbg ? {14'd0, err, busy} : 16'd0)
	};
`else
	assign hcr_rdata = hcr_ridx == I_ADDR ? addr : hcr_ridx == I_DATA ? data :
		hcr_ridx == I_STATUS ? {30'd0, err, busy} : 32'd0;
`endif

	wire unused_ok = &{1'b0, rsp_tag, hcr_ridx[9:6]};
endmodule

`default_nettype wire
