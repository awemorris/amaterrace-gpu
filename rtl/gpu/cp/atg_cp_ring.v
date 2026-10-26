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
 * Upgraded in Phase 029 with an 8-entry circular line prefetch cache
 * (64 words / 256 bytes) providing continuous, zero-bubble packet delivery
 * across line boundaries. When streaming Class N packets, next lines are
 * prefetched concurrently in the background, eliminating AMB wait bubbles.
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
	localparam [2:0] R_HDR  = 3'd1;	/* decode the header at cur */
	localparam [2:0] R_N    = 3'd2;	/* stream a class N packet */
	localparam [2:0] R_V    = 3'd3;	/* a class V packet waits for v_done */
	localparam [2:0] R_ADV  = 3'd4;	/* move RPTR past the packet */
	localparam [2:0] R_REQ  = 3'd5;	/* on-demand line read request */
	localparam [2:0] R_RSP  = 3'd6;	/* on-demand line read response */
	localparam [2:0] R_FAULT = 3'd7;

	localparam [1:0] PF_IDLE = 2'd0;
	localparam [1:0] PF_REQ  = 2'd1;
	localparam [1:0] PF_RSP  = 2'd2;

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

	/*
	 * 8-entry circular prefetch line buffer (256 bytes = 64 words for 32B lines)
	 */
	reg [7:0] buf_valid;
	reg [LA_W-1:0] buf_tag [0:7];
	reg [LINE_BYTES*8-1:0] buf_data [0:7];

	/*
	 * The dword wanted (the header, or dword k of the packet) as a byte
	 * address in a register.
	 */
	reg [31:0] pa;
	wire [31:0] want_addr = pa;
	wire [LA_W-1:0] want_line = want_addr[ADDR_W-1:LINE_SHIFT];
	wire [WS-1:0] want_word = want_addr[LINE_SHIFT-1:2];
	wire [2:0] want_idx = want_line[2:0];

	wire hit = buf_valid[want_idx] && (buf_tag[want_idx] == want_line);
	wire [31:0] want_data = buf_data[want_idx][{want_word, 5'd0} +: 32];

	wire go = (run && !halt) || step_pend;
	wire doorbell = hcr_we && hcr_widx == I_WPTR;
	wire [17:0] wptr_new = ((wptr & ~hcr_wmask[17:0]) | (hcr_wdata[17:0] & hcr_wmask[17:0])) & mask;

	/* Header decode */
	wire [1:0] h_class = want_data[31:30];
	wire [15:0] h_n = h_class[1] ? want_data[15:0] : {8'd0, want_data[7:0]};

	wire [17:0] avail_d, avail;
	wire [18:0] end_s;
	wire avail_bo, end_co;

	am_sub #(.W(18)) avail_sub (.a(wptr), .b(cur), .bi(1'b0), .d(avail_d), .bo(avail_bo));
	assign avail = avail_d & mask;
	am_add #(.W(19)) end_add (
		.a({1'b0, cur}), .b({3'd0, st == R_ADV ? n : h_n}), .ci(1'b1), .s(end_s), .co(end_co)
	);
	wire [18:0] h_end = end_s;
	wire h_bad = h_end > nwords || {3'd0, h_n} >= {1'b0, avail};
	wire h_novf = (h_class == 2'd2) && (CLASS_V == 0);
	wire [17:0] p_end = end_s[17:0] & mask;

	wire [31:0] pa_4, pa_hdr;
	wire [15:0] k_n;
	wire pa_4_co, pa_hdr_co, k_co;

	am_add #(.W(32)) pa_4_add (.a(pa), .b(32'd4), .ci(1'b0), .s(pa_4), .co(pa_4_co));
	am_add #(.W(32)) pa_hdr_add (
		.a(base), .b({12'd0, rptr, 2'b00}), .ci(1'b0), .s(pa_hdr), .co(pa_hdr_co)
	);
	am_add #(.W(16)) k_add (.a(k), .b(16'd0), .ci(1'b1), .s(k_n), .co(k_co));

	/*
	 * Background Prefetch Engine
	 */
	wire [LA_W-1:0] next_line;
	wire unused_nl_co;
	am_add #(.W(LA_W)) u_next_line (
		.a(want_line), .b({{(LA_W-1){1'b0}}, 1'b1}), .ci(1'b0), .s(next_line), .co(unused_nl_co)
	);
	wire [2:0] next_idx = next_line[2:0];
	wire next_hit = buf_valid[next_idx] && (buf_tag[next_idx] == next_line);

	reg [1:0] pf_st;
	reg [LA_W-1:0] pf_line;
	wire [2:0] pf_idx = pf_line[2:0];

	// Prefetch next line while executing Class N packet before boundary hit
	wire pf_trigger = (st == R_N) && (k != n) && !next_hit && (pf_st == PF_IDLE) &&
		(st != R_REQ) && (st != R_RSP) && go;

	reg f_pulse;
	reg [3:0] f_kind;
	reg [31:0] f_addr;
	reg ret_pulse;

	assign fault = f_pulse;
	assign fault_kind = f_kind;
	assign fault_addr = f_addr;
	assign fault_tag = tag;
	assign retire = ret_pulse;
	assign empty = (wptr == rptr);
	assign busy = (st != R_IDLE && st != R_FAULT) || (pf_st != PF_IDLE);

	assign n_valid = (st == R_N) && hit;
	assign n_data = want_data;
	assign n_last = (k == n);

	assign v_valid = (st == R_V);
	assign v_addr = pa_4;
	assign v_dwords = n;
	assign v_tag = tag;

	// AMB port multiplexing: on-demand read (st == R_REQ) takes priority over prefetch
	wire demand_req = (st == R_REQ);
	assign req_valid = demand_req || (pf_st == PF_REQ);
	assign req_write = 1'b0;
	assign req_line = demand_req ? want_line : pf_line;
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {(LINE_BYTES * 8){1'b0}};
	assign req_tag = demand_req ? 8'd0 : 8'd1;

	/* Registers surviving CTRL.RESET */
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

	integer bi;

	/* Main sequential logic */
	always @(posedge clk) begin
		if (!core_rst_n) begin
			wptr      <= 18'd0;
			rptr      <= 18'd0;
			st        <= R_IDLE;
			ret_n     <= 1'b0;
			pa        <= 32'd0;
			cur       <= 18'd0;
			n         <= 16'd0;
			k         <= 16'd0;
			tag       <= 8'd0;
			step_pend <= 1'b0;
			stale     <= 1'b0;
			buf_valid <= 8'd0;
			for (bi = 0; bi < 8; bi = bi + 1) begin
				buf_tag[bi]  <= {LA_W{1'b0}};
				buf_data[bi] <= {(LINE_BYTES * 8){1'b0}};
			end
			pf_st     <= PF_IDLE;
			pf_line   <= {LA_W{1'b0}};
			f_pulse   <= 1'b0;
			f_kind    <= 4'd0;
			f_addr    <= 32'd0;
			ret_pulse <= 1'b0;
		end else begin
			f_pulse   <= 1'b0;
			ret_pulse <= 1'b0;

			if (doorbell) begin
				wptr      <= wptr_new;
				stale     <= 1'b1;
				buf_valid <= 8'd0; // Invalidate cache lines on doorbell to prevent stale reads
			end

			if (step)
				step_pend <= 1'b1;
			else if (run && !halt)
				step_pend <= 1'b0;

			// ---------------------------------------------------------
			// Background Prefetcher FSM
			// ---------------------------------------------------------
			case (pf_st)
			PF_IDLE: begin
				if (pf_trigger) begin
					pf_line <= next_line;
					pf_st   <= PF_REQ;
				end
			end
			PF_REQ: begin
				if (req_ready && !demand_req)
					pf_st <= PF_RSP;
			end
			PF_RSP: begin
				if (rsp_valid && (rsp_tag == 8'd1)) begin
					if (!rsp_error) begin
						buf_data[pf_idx]  <= rsp_rdata;
						buf_tag[pf_idx]   <= pf_line;
						buf_valid[pf_idx] <= 1'b1;
					end
					pf_st <= PF_IDLE;
				end
			end
			default: pf_st <= PF_IDLE;
			endcase

			// ---------------------------------------------------------
			// Main Command Execution FSM
			// ---------------------------------------------------------
			case (st)
			R_IDLE: begin
				if (go && rptr != wptr) begin
					cur       <= rptr;
					pa        <= pa_hdr;
					step_pend <= 1'b0;
					st        <= R_HDR;
				end
			end

			R_HDR: begin
				if (!hit || stale) begin
					ret_n <= 1'b0;
					stale <= doorbell;
					st    <= R_REQ;
				end else begin
					tag <= want_data[23:16];
					n   <= h_n;
					k   <= 16'd0;
					if (h_bad || h_novf) begin
						f_pulse <= 1'b1;
						f_kind  <= h_bad ? GHCI_FAULT_RING : GHCI_FAULT_OPCODE;
						f_addr  <= want_addr;
						st      <= R_FAULT;
					end else begin
						case (h_class)
						2'd2:    st <= R_V;
						2'd3:    st <= R_ADV;
						default: st <= R_N;
						endcase
					end
				end
			end

			R_N: begin
				if (!hit) begin
					ret_n <= 1'b1;
					st    <= R_REQ;
				end else if (n_ready) begin
					if (k == n) begin
						st <= R_ADV;
					end else begin
						k  <= k_n;
						pa <= pa_4;
					end
				end
			end

			R_V: begin
				if (v_done)
					st <= R_ADV;
			end

			R_ADV: begin
				rptr      <= p_end;
				ret_pulse <= 1'b1;
				st        <= R_IDLE;
			end

			R_REQ: begin
				if (req_ready && demand_req)
					st <= R_RSP;
			end

			R_RSP: begin
				if (rsp_valid && (rsp_tag == 8'd0)) begin
					if (rsp_error) begin
						f_pulse <= 1'b1;
						f_kind  <= GHCI_FAULT_APERTURE;
						f_addr  <= {want_line, {LINE_SHIFT{1'b0}}};
						st      <= R_FAULT;
					end else begin
						buf_valid[want_idx] <= 1'b1;
						buf_tag[want_idx]   <= want_line;
						buf_data[want_idx]  <= rsp_rdata;
						st <= ret_n ? R_N : R_HDR;
					end
				end
			end

			default: ;
			endcase
		end
	end

	assign hcr_rdata = (hcr_ridx == I_BASE) ? base :
		(hcr_ridx == I_SIZE) ? {27'd0, size} :
		(hcr_ridx == I_WPTR) ? {14'd0, wptr} :
		(hcr_ridx == I_RPTR) ? {14'd0, rptr} : 32'd0;

	wire unused_ok = &{1'b0, rsp_write, h_end[18], avail_bo, end_co, pa_4_co,
		pa_hdr_co, k_co, unused_nl_co};

endmodule

`default_nettype wire
