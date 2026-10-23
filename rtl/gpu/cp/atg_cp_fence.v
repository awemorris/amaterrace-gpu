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
 * the host (the driver restores it after RESET).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_fence #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
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
	input wire [31:0] f_addr,
	input wire [31:0] f_value,
	input wire [31:0] f_aux,
	input wire f_irq,
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
	reg [31:0] addr;
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
	assign req_be = is_read ? {LINE_BYTES{1'b0}} : op == 2'd1 ?
		{{(LINE_BYTES - 8){1'b0}}, 8'hFF} << {word[WS-1:1], 3'd0} :
		{{(LINE_BYTES - 4){1'b0}}, 4'hF} << {word, 2'd0};
	assign req_tag = 8'd0;

	wire [31:0] mem_word = rsp_rdata[{word, 5'd0} +: 32];
	wire [31:0] diff = mem_word - value;
	wire passed = !diff[31];

	assign fault = st == F_RSP && rsp_valid && rsp_error;
	assign fault_kind = GHCI_FAULT_APERTURE;
	assign fault_addr = addr;
	assign fault_tag = 8'd0;
	assign ev_fence = st == F_RSP && rsp_valid && !rsp_error && op == 2'd0 && irq_on;
	assign fence_last = last;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= F_IDLE;
			op <= 2'd0;
			addr <= 32'd0;
			value <= 32'd0;
			aux <= 32'd0;
			irq_on <= 1'b0;
			last <= 32'd0;
			gap <= 8'd0;
		end else begin
			if (hcr_we && hcr_widx == I_LAST)
				last <= (last & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
			case (st)
			F_IDLE:
				if (f_valid) begin
					op <= f_op;
					addr <= f_op == 2'd1 ? f_addr & 32'hFFFFFFF8 : f_addr & 32'hFFFFFFFC;
					value <= f_value;
					aux <= f_aux;
					irq_on <= f_irq;
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
					gap <= gap - 8'd1;
			default:
				;
			endcase
		end
	end

	assign hcr_rdata = hcr_ridx == I_LAST ? last : 32'd0;

	wire unused_ok = &{1'b0, rsp_write, rsp_tag, diff[30:0]};
endmodule

`default_nettype wire
