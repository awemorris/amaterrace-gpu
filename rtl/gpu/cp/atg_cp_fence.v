/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_fence: writes fences and results to memory, polls WAIT_FENCE
 * words, keeps FENCE_LAST and raises the FENCE interrupt; memory through
 * the CP's AMB port.
 *
 * One request at a time (f_ready in IDLE only):
 *   FENCE (op 0): write f_value to the word at f_addr (that word's byte
 *     enables); on the write's response FENCE_LAST = value and, with f_irq,
 *     ev_fence pulses.
 *   RESULT (op 1): write {f_value, f_aux} to the 8 bytes at f_addr.
 *   WAIT_FENCE (op 2): read the word at f_addr until
 *     (int32)(mem - f_value) >= 0, POLL cycles between reads.
 * f_busy is 1 from the request until its last response.  The sequencer
 * has already waited for the blocks; this unit only orders its own write
 * response before FENCE_LAST/ev_fence.  An error response is a fault of
 * kind 1 (aperture or AXI error) with the address; the unit then stops
 * until the core reset (rst_n).  FENCE_LAST (0x070) is also written by
 * the host (the driver restores it after RESET).  Session protection:
 * f_chk and f_slot come with the request (a firmware µop of a protected
 * session that is not SELF) and go with its memory requests (req_chk,
 * req_slot).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_fence #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter POLL = 64	/* WAIT_FENCE: cycles between two reads */
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
	/* Requests (from atg_cp_seq) */
	input wire f_valid,
	output wire f_ready,
	input wire [1:0] f_op,
	input wire [ADDR_W-1:0] f_addr,
	input wire [31:0] f_value,
	input wire [31:0] f_aux,
	input wire f_irq,
	input wire f_chk,
	input wire [5:0] f_slot,
	output wire f_busy,
	/* Events */
	output wire ev_fence,
	output wire [31:0] fence_last,
	/* Fault report to atg_cp_ctl (one source of its `src_*` vectors) */
	output wire fault,
	output wire [3:0] fault_kind,
	output wire [31:0] fault_addr,
	output wire [7:0] fault_tag,
	/* AMB client port (design §4.1) */
	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	output reg req_chk,
	output reg [5:0] req_slot,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	`include "ghci_regs.vh"

	localparam WS = LINE_SHIFT - 2;
	localparam [9:0] I_LAST = GHCI_FENCE_LAST[11:2];

	localparam [2:0] F_IDLE = 3'd0;
	localparam [2:0] F_REQ = 3'd1;	/* request held until ready */
	localparam [2:0] F_RSP = 3'd2;	/* wait for the response */
	localparam [2:0] F_GAP = 3'd3;	/* WAIT_FENCE: before the next read */
	localparam [2:0] F_DEAD = 3'd4;	/* after an error, until reset */

	reg [2:0] st;
	reg [1:0] op;
	reg [ADDR_W-1:0] addr;
	reg [31:0] value;
	reg [31:0] aux;
	reg irq_on;
	reg [31:0] last;
	reg [7:0] gap;

	wire [WS-1:0] word = addr[LINE_SHIFT-1:2];
	wire is_read = op == 2'd2;

	assign f_ready = st == F_IDLE;
	assign f_busy = st != F_IDLE && st != F_DEAD;
	assign req_valid = st == F_REQ;
	assign req_write = !is_read;
	assign req_line = addr[ADDR_W-1:LINE_SHIFT];
	assign req_wdata = op == 2'd1 ? {(LINE_BYTES / 8){aux, value}} : {(LINE_BYTES / 4){value}};
	/* FENCE: the word; RESULT: the 8-byte pair (8-byte aligned). */
	reg [LINE_BYTES-1:0] be_word, be_pair;
	integer bw;
	always @(*)
		for (bw = 0; bw < LINE_BYTES / 4; bw = bw + 1) begin
			be_word[bw*4 +: 4] = {{(32 - WS){1'b0}}, word} == bw ? 4'hF : 4'h0;
			be_pair[bw*4 +: 4] = {{(33 - WS){1'b0}}, word[WS-1:1]} == bw / 2 ? 4'hF : 4'h0;
		end
	assign req_be = is_read ? {LINE_BYTES{1'b0}} : op == 2'd1 ? be_pair : be_word;
	assign req_tag = 8'd0;

	wire [31:0] mem_word = rsp_rdata[{word, 5'd0} +: 32];
	wire [31:0] diff;
	wire diff_bo;

	am_sub #(.W(32)) diff_sub (.a(mem_word), .b(value), .bi(1'b0), .d(diff), .bo(diff_bo));

	/* The gap's count - 1. */
	wire [7:0] gap_n;
	wire gap_bo;

	am_sub #(.W(8)) gap_sub (.a(gap), .b(8'd0), .bi(1'b1), .d(gap_n), .bo(gap_bo));
	wire passed = !diff[31];

	assign fault = st == F_RSP && rsp_valid && rsp_error;
	assign fault_kind = GHCI_FAULT_APERTURE;
	assign fault_addr = addr[31:0];
	assign fault_tag = 8'd0;
	assign ev_fence = st == F_RSP && rsp_valid && !rsp_error && op == 2'd0 && irq_on;
	assign fence_last = last;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= F_IDLE;
			op <= 2'd0;
			addr <= {ADDR_W{1'b0}};
			value <= 32'd0;
			aux <= 32'd0;
			irq_on <= 1'b0;
			req_chk <= 1'b0;
			req_slot <= 6'd0;
			last <= 32'd0;
			gap <= 8'd0;
		end else begin
			if (hcr_we && hcr_widx == I_LAST)
				last <= (last & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
			case (st)
			F_IDLE:
				if (f_valid) begin
					op <= f_op;
					addr <= f_op == 2'd1 ? {f_addr[ADDR_W-1:3], 3'b000} : {f_addr[ADDR_W-1:2], 2'b00};
					value <= f_value;
					aux <= f_aux;
					irq_on <= f_irq;
					req_chk <= f_chk;
					req_slot <= f_slot;
					st <= F_REQ;
				end
			F_REQ:
				if (req_ready)
					st <= F_RSP;
			F_RSP:
				if (rsp_valid) begin
					if (rsp_error) begin
						st <= F_DEAD;
					end else if (is_read) begin
						if (passed) begin
							st <= F_IDLE;
						end else begin
							gap <= POLL[7:0];
							st <= F_GAP;
						end
					end else begin
						if (op == 2'd0)
							last <= value;
						st <= F_IDLE;
					end
				end
			F_GAP:
				if (gap <= 8'd1)
					st <= F_REQ;
				else
					gap <= gap_n;
			default:
				;
			endcase
		end
	end

	assign hcr_rdata = hcr_ridx == I_LAST ? last : 32'd0;

	wire unused_ok = &{1'b0, rsp_write, rsp_tag, diff[30:0], diff_bo, gap_bo, f_addr[2:0]};
endmodule

`default_nettype wire
