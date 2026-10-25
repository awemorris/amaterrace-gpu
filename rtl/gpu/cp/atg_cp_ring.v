/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_ring: the command ring: RING_BASE/SIZE/WPTR/RPTR, line reads of
 * the ring through the CP's AMB port, the packet envelope of design
 * §2.4.2 (version 3): class N packets (0 standard, 1 vendor µops) go to
 * the sequencer dword by dword, class V packets (2) to the CPU or, without
 * one (CLASS_V = 0), are a fault of kind 2, class 3 padding is skipped.
 *
 * Registers: RING_BASE (32-byte aligned) and RING_SIZE (log2 bytes,
 * clamped to 10..20 when written) are written only when open and survive
 * the core reset (rst_n); RING_WPTR (the doorbell, kept mod the ring's
 * dword count) and RING_RPTR (read only) are cleared by the core reset.
 *
 * Fetch: with run (or once per step) and RPTR != WPTR, the header at RPTR
 * is decoded; halt is looked at only between packets.  One line buffer,
 * one read outstanding.  A doorbell marks the buffer stale for the next
 * header (design §2.7: the line at RPTR is read again, nothing fetched
 * before the doorbell is used for a new packet); the dwords of a packet
 * already accepted lie below WPTR and are read as they are.  A packet
 * whose end passes WPTR or the ring's end is a fault of kind 3 with the
 * header's address; nothing of it is handed over.  A read error is a
 * fault of kind 1 with the line's address.  After a fault the ring stays
 * stopped until the core reset.  RPTR moves past a packet when it has been
 * handed over (class N: its last dword taken; V: v_done; padding at once)
 * and retire pulses.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_ring #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter CLASS_V = 1	/* 1: class V packets go to the CPU; 0: fault kind 2 */
) (
	input wire clk,
	input wire rst_n,
	input wire core_rst_n,
	/* HCR register snoop (from atg_cp_regs) */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output wire [31:0] hcr_rdata,
	/* Control (from atg_cp_ctl) */
	input wire run,
	input wire halt,
	input wire step,
	input wire open,
	/* Class N packets (to atg_cp_seq) */
	output wire n_valid,
	input wire n_ready,
	output wire [31:0] n_data,
	output wire n_last,
	/* Class V packets (to atg_cpu) */
	output wire v_valid,
	output wire [31:0] v_addr,
	output wire [15:0] v_dwords,
	output wire [7:0] v_tag,
	input wire v_done,
	/* Status */
	output wire empty,
	output wire retire,
	output wire busy,
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

	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam WS = LINE_SHIFT - 2;
	localparam [9:0] I_BASE = GHCI_RING_BASE[11:2];
	localparam [9:0] I_SIZE = GHCI_RING_SIZE[11:2];
	localparam [9:0] I_WPTR = GHCI_RING_WPTR[11:2];
	localparam [9:0] I_RPTR = GHCI_RING_RPTR[11:2];

	localparam [2:0] R_IDLE = 3'd0;
	localparam [2:0] R_HDR = 3'd1;	/* decode the header at cur */
	localparam [2:0] R_N = 3'd2;	/* stream a class N packet */
	localparam [2:0] R_V = 3'd3;	/* a class V packet waits for v_done */
	localparam [2:0] R_ADV = 3'd4;	/* move RPTR past the packet */
	localparam [2:0] R_REQ = 3'd5;	/* line read request */
	localparam [2:0] R_RSP = 3'd6;	/* line read response */
	localparam [2:0] R_FAULT = 3'd7;

	reg [31:0] base;
	reg [4:0] size;
	reg [17:0] wptr;
	reg [17:0] rptr;

	/*
	 * The ring's dword count - 1 (size 10..20: 2^8..2^18 dwords) and the
	 * count: bit i of the mask is i < size - 2, the count's only bit is
	 * size - 2 (comparisons with constants; size is never below 10).
	 */
	reg [17:0] mask;
	reg [18:0] nwords;
	integer mi;
	always @(*) begin
		for (mi = 0; mi < 18; mi = mi + 1)
			mask[mi] = {27'd0, size} > mi + 2;
		for (mi = 0; mi < 19; mi = mi + 1)
			nwords[mi] = {27'd0, size} == mi + 2;
	end

	reg [2:0] st;
	reg ret_n;	/* the read is for R_N (else R_HDR) */
	reg [17:0] cur;	/* the header's dword index */
	reg [15:0] n;	/* dwords after the header */
	reg [15:0] k;	/* R_N: dword of the packet on n_data (0 = header) */
	reg [7:0] tag;
	reg step_pend;
	reg stale;
	reg buf_ok;
	reg [LA_W-1:0] buf_line;
	reg [LINE_BYTES*8-1:0] buf_data;

	/*
	 * The dword wanted (the header, or dword k of the packet) as a byte
	 * address in a register, so that the line compare and the dword's
	 * select need no adder (the timing path into the sequencer and the
	 * blocks' state).  A packet never crosses the ring's end.
	 */
	reg [31:0] pa;
	wire [31:0] want_addr = pa;
	wire [LA_W-1:0] want_line = want_addr[ADDR_W-1:LINE_SHIFT];
	wire [WS-1:0] want_word = want_addr[LINE_SHIFT-1:2];
	wire [31:0] want_data = buf_data[{want_word, 5'd0} +: 32];
	wire hit = buf_ok && buf_line == want_line;

	wire go = (run && !halt) || step_pend;
	wire doorbell = hcr_we && hcr_widx == I_WPTR;
	wire [17:0] wptr_new = ((wptr & ~hcr_wmask[17:0]) | (hcr_wdata[17:0] & hcr_wmask[17:0])) &
		mask;

	/* Header decode. */
	wire [1:0] h_class = want_data[31:30];
	wire [15:0] h_n = h_class[1] ? want_data[15:0] : {8'd0, want_data[7:0]};
	/*
	 * The dwords written from cur; the header's end cur + h_n + 1 (R_HDR)
	 * and the packet's end cur + n + 1 (R_ADV) from one adder, as they are
	 * never needed in the same cycle; h_n + 1 > avail as h_n >= avail.
	 */
	wire [17:0] avail_d, avail;
	wire [18:0] end_s;
	wire avail_bo, end_co;

	am_sub #(.W(18)) avail_sub (.a(wptr), .b(cur), .bi(1'b0), .d(avail_d), .bo(avail_bo));
	assign avail = avail_d & mask;	/* dwords written from cur */
	am_add #(.W(19)) end_add (
		.a({1'b0, cur}), .b({3'd0, st == R_ADV ? n : h_n}), .ci(1'b1), .s(end_s), .co(end_co)
	);
	wire [18:0] h_end = end_s;
	wire h_bad = h_end > nwords || {3'd0, h_n} >= {1'b0, avail};
	wire h_novf = h_class == 2'd2 && CLASS_V == 0;
	wire [17:0] p_end = end_s[17:0] & mask;	/* after the packet */

	/* pa + 4 (R_N's next dword, and v_addr), the header's address base + 4 rptr, k + 1. */
	wire [31:0] pa_4, pa_hdr;
	wire [15:0] k_n;
	wire pa_4_co, pa_hdr_co, k_co;

	am_add #(.W(32)) pa_4_add (.a(pa), .b(32'd4), .ci(1'b0), .s(pa_4), .co(pa_4_co));
	am_add #(.W(32)) pa_hdr_add (
		.a(base), .b({12'd0, rptr, 2'b00}), .ci(1'b0), .s(pa_hdr), .co(pa_hdr_co)
	);
	am_add #(.W(16)) k_add (.a(k), .b(16'd0), .ci(1'b1), .s(k_n), .co(k_co));

	reg f_pulse;
	reg [3:0] f_kind;
	reg [31:0] f_addr;
	reg ret_pulse;

	assign fault = f_pulse;
	assign fault_kind = f_kind;
	assign fault_addr = f_addr;
	assign fault_tag = tag;
	assign retire = ret_pulse;
	assign empty = wptr == rptr;
	assign busy = st != R_IDLE && st != R_FAULT;

	assign n_valid = st == R_N && hit;
	assign n_data = want_data;
	assign n_last = k == n;

	assign v_valid = st == R_V;
	assign v_addr = pa_4;	/* pa is the header's address in R_V */
	assign v_dwords = n;
	assign v_tag = tag;

	assign req_valid = st == R_REQ;
	assign req_write = 1'b0;
	assign req_line = want_line;
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {(LINE_BYTES * 8){1'b0}};
	assign req_tag = 8'd0;

	/* The registers that survive CTRL.RESET. */
	always @(posedge clk) begin
		if (!rst_n) begin
			base <= 32'd0;
			size <= 5'd12;
		end else if (hcr_we && open) begin
			if (hcr_widx == I_BASE)
				base <= ((base & ~hcr_wmask) | (hcr_wdata & hcr_wmask)) & 32'hFFFFFFE0;
			if (hcr_widx == I_SIZE && hcr_wmask[0])
				size <= hcr_wdata[4:0] < 5'd10 ? 5'd10 :
					hcr_wdata[4:0] > 5'd20 ? 5'd20 : hcr_wdata[4:0];
		end
	end

	always @(posedge clk) begin
		if (!core_rst_n) begin
			wptr <= 18'd0;
			rptr <= 18'd0;
			st <= R_IDLE;
			ret_n <= 1'b0;
			pa <= 32'd0;
			cur <= 18'd0;
			n <= 16'd0;
			k <= 16'd0;
			tag <= 8'd0;
			step_pend <= 1'b0;
			stale <= 1'b0;
			buf_ok <= 1'b0;
			buf_line <= {LA_W{1'b0}};
			buf_data <= {(LINE_BYTES * 8){1'b0}};
			f_pulse <= 1'b0;
			f_kind <= 4'd0;
			f_addr <= 32'd0;
			ret_pulse <= 1'b0;
		end else begin
			f_pulse <= 1'b0;
			ret_pulse <= 1'b0;
			if (doorbell) begin
				wptr <= wptr_new;
				stale <= 1'b1;
			end
			if (step)
				step_pend <= 1'b1;
			else if (run && !halt)
				step_pend <= 1'b0;

			case (st)
			R_IDLE:
				if (go && rptr != wptr) begin
					cur <= rptr;
					pa <= pa_hdr;
					step_pend <= 1'b0;
					st <= R_HDR;
				end
			R_HDR:
				if (!hit || stale) begin
					ret_n <= 1'b0;
					stale <= doorbell;
					st <= R_REQ;
				end else begin
					tag <= want_data[23:16];
					n <= h_n;
					k <= 16'd0;
					if (h_bad || h_novf) begin
						f_pulse <= 1'b1;
						f_kind <= h_bad ? GHCI_FAULT_RING : GHCI_FAULT_OPCODE;
						f_addr <= want_addr;
						st <= R_FAULT;
					end else begin
						case (h_class)
						2'd2: st <= R_V;
						2'd3: st <= R_ADV;
						default: st <= R_N;
						endcase
					end
				end
			R_N:
				if (!hit) begin
					ret_n <= 1'b1;
					st <= R_REQ;
				end else if (n_ready) begin
					if (k == n) begin
						st <= R_ADV;
					end else begin
						k <= k_n;
						pa <= pa_4;
					end
				end
			R_V:
				if (v_done)
					st <= R_ADV;
			R_ADV: begin
				rptr <= p_end;
				ret_pulse <= 1'b1;
				st <= R_IDLE;
			end
			R_REQ:
				if (req_ready)
					st <= R_RSP;
			R_RSP:
				if (rsp_valid) begin
					if (rsp_error) begin
						f_pulse <= 1'b1;
						f_kind <= GHCI_FAULT_APERTURE;
						f_addr <= {want_line, {LINE_SHIFT{1'b0}}};
						st <= R_FAULT;
					end else begin
						buf_ok <= 1'b1;
						buf_line <= want_line;
						buf_data <= rsp_rdata;
						st <= ret_n ? R_N : R_HDR;
					end
				end
			default:
				;
			endcase
		end
	end

	assign hcr_rdata = hcr_ridx == I_BASE ? base : hcr_ridx == I_SIZE ? {27'd0, size} :
		hcr_ridx == I_WPTR ? {14'd0, wptr} : hcr_ridx == I_RPTR ? {14'd0, rptr} : 32'd0;

	wire unused_ok = &{1'b0, rsp_write, rsp_tag, h_end[18], avail_bo, end_co, pa_4_co,
		pa_hdr_co, k_co};
endmodule

`default_nettype wire
