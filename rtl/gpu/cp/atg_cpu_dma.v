/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_dma: The CPU's line DMA between GPU memory (AMB) and IMEM/DMEM:
 * the firmware's heap <-> DMEM copies (window DMA_*) and the CPFW image
 * load (from atg_cpu_fw).
 *
 * Window (sub-bus, data at once): 0x10 DMA_AMB and 0x11 DMA_MEM (RW,
 * line aligned; the low bits are ignored), 0x12 DMA_GO (W: [15:0] lines,
 * [16] 1 = DMEM -> memory, [17] chk: session protection checks the
 * copy's memory accesses for dma_slot, the slot of the class V packet the
 * firmware works on (none when that slot is 0), [18] tbl: the copy writes
 * the protection table; ignored while busy or with 0 lines), 0x13
 * DMA_STATUS (R: [0] busy, [1] error of the last copy, [15:8] writes not
 * yet answered).  An image load (ld_start) copies ld_words words from
 * ld_addr to offset 0 of IMEM or DMEM; it waits until a window copy has
 * finished, then pulses ld_done (with ld_error).
 *
 * Reads: up to 4 line reads outstanding (tags 0-3, one line buffer each:
 * a read is issued only for a free buffer, so the responses, which have
 * no back-pressure, always have a place), each line stored into the BRAM
 * one word per cycle.  Writes: a line is gathered from DMEM (one word per
 * cycle), then written (all bytes); the writes are counted until their
 * responses.  An error response stops the copy: no more requests, the
 * ones in flight are waited for and dropped, and error is set.  The AMB
 * request holds its payload until req_ready, and req_chk, req_tbl and
 * req_slot those of its copy (an image load: 0).
 * See spec/gpu/cp/atg_cpu_dma.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_dma #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	/* Window sub-bus (from atg_cpu_win) */
	input wire sb_we,
	input wire sb_re,
	input wire [5:0] sb_idx,
	input wire [31:0] sb_wdata,
	output reg [31:0] sb_rdata,
	/* Image load (from atg_cpu_fw) */
	input wire ld_start,
	input wire ld_imem,
	input wire [31:0] ld_addr,
	input wire [31:0] ld_words,
	output reg ld_done,
	output reg ld_error,
	/* Memory port (atg_cpu_mem x_*) */
	output wire x_en,
	output wire x_we,
	output wire x_imem,
	output wire [31:0] x_addr,
	output wire [31:0] x_wdata,
	input wire [31:0] x_rdata,
	output wire wait_amb,
	/* AMB client port (design §4.1) */
	output reg req_valid,
	input wire req_ready,
	output reg req_write,
	output reg [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output reg [7:0] req_tag,
	output wire req_chk,	/* session protection, held with the copy */
	output wire req_tbl,
	output wire [5:0] req_slot,
	input wire [5:0] dma_slot,	/* the class V packet's protection slot */
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	localparam WPL = LINE_BYTES / 4;	/* words per line */
	localparam WS = LINE_SHIFT - 2;	/* log2(WPL) */
	localparam LW = ADDR_W - LINE_SHIFT;

	localparam [5:0] W_AMB = 6'h10;
	localparam [5:0] W_MEM = 6'h11;
	localparam [5:0] W_GO = 6'h12;
	localparam [5:0] W_STATUS = 6'h13;

	localparam [1:0] S_IDLE = 2'd0;
	localparam [1:0] S_READ = 2'd1;	/* issue reads, store lines */
	localparam [1:0] S_GATHER = 2'd2;	/* read a line from DMEM */
	localparam [1:0] S_WRITE = 2'd3;	/* write it */

	reg [1:0] state;
	reg [31:0] dma_amb, dma_mem;
	reg err;
	reg [7:0] wr_out;	/* writes not yet answered */
	reg ld_pend, ld_job;	/* an image load waits / runs */
	reg ld_pimem;
	reg [31:0] ld_paddr, ld_pwords;

	/* The current copy. */
	reg j_imem;
	reg [LW-1:0] j_line;	/* next line to request */
	reg [31:0] j_mem;	/* BRAM byte offset of that line */
	reg [31:0] j_rem;	/* words not yet requested */
	reg j_chk, j_tbl;	/* session protection of the copy */
	reg [5:0] j_slot;

	assign req_chk = j_chk;
	assign req_tbl = j_tbl;
	assign req_slot = j_slot;

	/* Read side: 4 line buffers. */
	reg [LINE_BYTES*8-1:0] lbuf [0:3];
	reg [3:0] s_busy;	/* requested, not yet stored */
	reg [3:0] s_full;	/* data arrived */
	reg [31:0] s_dst [0:3];
	reg [WS:0] s_nw [0:3];	/* words to store */
	reg st_act;
	reg [1:0] st_slot;
	reg [WS:0] st_w;

	/* Write side: the gathered line. */
	reg [LINE_BYTES*8-1:0] wline;
	reg [WS:0] g_w;	/* next word to read */
	reg g_cap;	/* x_rdata holds word g_w - 1 (captured into wline) */

	wire busy = state != S_IDLE;
	wire go = sb_we && sb_idx == W_GO && !busy && !ld_pend && sb_wdata[15:0] != 16'd0;

	/* A free buffer for the next read. */
	reg [1:0] free_s;
	reg have_free;
	reg [1:0] full_s;
	reg have_full;
	integer k;

	always @(*) begin
		have_free = 1'b0;
		free_s = 2'd0;
		have_full = 1'b0;
		full_s = 2'd0;
		for (k = 3; k >= 0; k = k - 1) begin
			if (!s_busy[k]) begin
				have_free = 1'b1;
				free_s = k[1:0];
			end
			if (s_full[k]) begin
				have_full = 1'b1;
				full_s = k[1:0];
			end
		end
	end

	wire [WS:0] words_now = (j_rem >= WPL) ? WPL[WS:0] : j_rem[WS:0];
	wire rd_issue = state == S_READ && !req_valid && j_rem != 32'd0 && have_free && !err;
	wire rd_rsp = rsp_valid && !rsp_write;
	wire wr_rsp = rsp_valid && rsp_write;

	/* Memory port: storing (read copies) or gathering (write copies). */
	wire st_we = st_act;
	wire g_en = state == S_GATHER && g_w != WPL[WS:0];
	wire [31:0] st_word = lbuf[st_slot][{st_w[WS-1:0], 5'd0} +: 32];

	assign x_en = st_we || g_en;
	assign x_we = st_we;
	assign x_imem = j_imem;
	/*
	 * The arithmetic, one instance each: the BRAM address (the storing
	 * slot's line or the gathered line, plus the word), st_w + 1, g_w + 1,
	 * the copy's next line and BRAM offset, the words left (less this
	 * read's, or a written line's: never in the same cycle), and the
	 * writes in flight +- 1.
	 */
	wire [31:0] x_addr_s, j_mem_n, j_rem_n;
	wire [WS:0] st_w_n, g_w_n;
	wire [LW-1:0] j_line_n;
	wire [7:0] wr_out_n;
	wire [7:0] ar_co;
	wire wr_inc = req_valid && req_ready && req_write && !wr_rsp;
	wire wr_dec = !(req_valid && req_ready && req_write) && wr_rsp && wr_out != 8'd0;

	am_add #(.W(32)) x_addr_add (
		.a(st_we ? s_dst[st_slot] : j_mem),
		.b({{(29 - WS){1'b0}}, st_we ? st_w : g_w, 2'b00}), .ci(1'b0), .s(x_addr_s),
		.co(ar_co[0])
	);
	am_add #(.W(WS + 1)) st_w_add (
		.a(st_w), .b({(WS + 1){1'b0}}), .ci(1'b1), .s(st_w_n), .co(ar_co[1])
	);
	am_add #(.W(WS + 1)) g_w_add (
		.a(g_w), .b({(WS + 1){1'b0}}), .ci(1'b1), .s(g_w_n), .co(ar_co[2])
	);
	am_add #(.W(LW)) j_line_add (
		.a(j_line), .b({LW{1'b0}}), .ci(1'b1), .s(j_line_n), .co(ar_co[3])
	);
	am_add #(.W(32)) j_mem_add (
		.a(j_mem), .b(LINE_BYTES), .ci(1'b0), .s(j_mem_n), .co(ar_co[4])
	);
	am_sub #(.W(32)) j_rem_sub (
		.a(j_rem), .b(rd_issue ? {{(31 - WS){1'b0}}, words_now} : WPL), .bi(1'b0),
		.d(j_rem_n), .bo(ar_co[5])
	);
	am_add #(.W(8)) wr_out_add (
		.a(wr_out), .b({{7{wr_dec && !wr_inc}}, wr_inc ^ wr_dec}), .ci(1'b0), .s(wr_out_n),
		.co(ar_co[6])
	);
	assign ar_co[7] = 1'b0;

	assign x_addr = x_addr_s;
	assign x_wdata = st_word;

	assign req_be = {LINE_BYTES{1'b1}};
	assign req_wdata = wline;
	assign wait_amb = s_busy != 4'd0 || wr_out != 8'd0 || req_valid;

	always @(*) begin
		case (sb_idx)
		W_AMB: sb_rdata = dma_amb;
		W_MEM: sb_rdata = dma_mem;
		W_STATUS: sb_rdata = {16'd0, wr_out, 6'd0, err, busy};
		default: sb_rdata = 32'd0;
		endcase
		if (!sb_re)
			sb_rdata = 32'd0;
	end

	always @(posedge clk) begin
		if (rd_rsp && s_busy[rsp_tag[1:0]])
			lbuf[rsp_tag[1:0]] <= rsp_rdata;
		/* The captured word is word g_w - 1 (mod WPL): a constant place per word. */
		for (k = 0; k < WPL; k = k + 1)
			if (g_cap && {{(32 - WS){1'b0}}, g_w[WS-1:0]} == (k + 1) % WPL)
				wline[k*32 +: 32] <= x_rdata;
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			dma_amb <= 32'd0;
			dma_mem <= 32'd0;
			err <= 1'b0;
			wr_out <= 8'd0;
			ld_pend <= 1'b0;
			ld_job <= 1'b0;
			ld_done <= 1'b0;
			ld_error <= 1'b0;
			req_valid <= 1'b0;
			req_write <= 1'b0;
			req_tag <= 8'd0;
			j_chk <= 1'b0;
			j_tbl <= 1'b0;
			j_slot <= 6'd0;
			s_busy <= 4'd0;
			s_full <= 4'd0;
			st_act <= 1'b0;
			g_cap <= 1'b0;
		end else begin
			ld_done <= 1'b0;
			if (sb_we && sb_idx == W_AMB)
				dma_amb <= sb_wdata;
			if (sb_we && sb_idx == W_MEM)
				dma_mem <= sb_wdata;
			if (ld_start) begin
				ld_pend <= 1'b1;
				ld_pimem <= ld_imem;
				ld_paddr <= ld_addr;
				ld_pwords <= ld_words;
			end
			/* Write responses count down whenever they come. */
			if (wr_rsp && rsp_error)
				err <= 1'b1;
			if (wr_inc || wr_dec)
				wr_out <= wr_out_n;
			if (req_valid && req_ready)
				req_valid <= 1'b0;
			/* Read side: responses and storing. */
			if (rd_rsp && s_busy[rsp_tag[1:0]]) begin
				if (rsp_error || err) begin
					err <= 1'b1;
					s_busy[rsp_tag[1:0]] <= 1'b0;
				end else begin
					s_full[rsp_tag[1:0]] <= 1'b1;
				end
			end
			if (st_act) begin
				if (st_w_n == s_nw[st_slot]) begin	/* st_w is the last word */
					st_act <= 1'b0;
					s_busy[st_slot] <= 1'b0;
					s_full[st_slot] <= 1'b0;
				end
				st_w <= st_w_n;
			end else if (have_full) begin
				st_act <= 1'b1;
				st_slot <= full_s;
				st_w <= {(WS + 1){1'b0}};
			end
			if (rd_issue) begin
				req_valid <= 1'b1;
				req_write <= 1'b0;
				req_line <= j_line;
				req_tag <= {6'd0, free_s};
				s_busy[free_s] <= 1'b1;
				s_dst[free_s] <= j_mem;
				s_nw[free_s] <= words_now;
				j_line <= j_line_n;
				j_mem <= j_mem_n;
				j_rem <= j_rem_n;
			end
			/* Write side: gather WPL words, then the request. */
			g_cap <= g_en;
			if (g_en)
				g_w <= g_w_n;
			case (state)
			S_IDLE:
				if (go) begin
					err <= 1'b0;
					j_imem <= 1'b0;
`ifdef MUT_CPPROT_DMACHK
					j_chk <= 1'b0;
`else
					j_chk <= sb_wdata[17] && dma_slot != 6'd0;
`endif
					j_tbl <= sb_wdata[18];
					j_slot <= dma_slot;
					j_line <= dma_amb[ADDR_W-1:LINE_SHIFT];
					j_mem <= {dma_mem[31:LINE_SHIFT], {LINE_SHIFT{1'b0}}};
					j_rem <= {{(16 - WS){1'b0}}, sb_wdata[15:0], {WS{1'b0}}};
					g_w <= {(WS + 1){1'b0}};
					state <= sb_wdata[16] ? S_GATHER : S_READ;
				end else if (ld_pend) begin
					ld_pend <= 1'b0;
					ld_job <= 1'b1;
					err <= 1'b0;
					j_chk <= 1'b0;
					j_tbl <= 1'b0;
					j_slot <= 6'd0;
					j_imem <= ld_pimem;
					j_line <= ld_paddr[ADDR_W-1:LINE_SHIFT];
					j_mem <= 32'd0;
					j_rem <= ld_pwords;
					state <= S_READ;
				end
			S_READ:
				/* Done when nothing is left to request, in flight or to store. */
				if ((j_rem == 32'd0 || err) && !req_valid && s_busy == 4'd0 && !rd_issue) begin
					state <= S_IDLE;
					if (ld_job) begin
						ld_job <= 1'b0;
						ld_done <= 1'b1;
						ld_error <= err;
					end
				end
			S_GATHER:
				if (err) begin
					state <= S_IDLE;
				end else if (!g_cap && g_w == WPL[WS:0] && wr_out != 8'hFF) begin
					req_valid <= 1'b1;
					req_write <= 1'b1;
					req_line <= j_line;
					req_tag <= 8'h80;
					state <= S_WRITE;
				end
			default:	/* S_WRITE */
				if (req_ready) begin
					j_line <= j_line_n;
					j_mem <= j_mem_n;
					j_rem <= j_rem_n;
					g_w <= {(WS + 1){1'b0}};
					state <= (j_rem == WPL) ? S_IDLE : S_GATHER;
				end
			endcase
		end
	end

	wire unused_ok = &{1'b0, rsp_tag[7:2], dma_mem[LINE_SHIFT-1:0], dma_amb[LINE_SHIFT-1:0],
		ld_paddr[LINE_SHIFT-1:0], ar_co};
endmodule

`default_nettype wire
