/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_rsv: the blitter's RESOLVE (BLT_OP[2:0] = 4, docs/ghci.md
 * section 8.2): converts a 4x multisampled source rectangle to one sample
 * per pixel, streaming, through the blitter's AMB port.  It keeps its own
 * copy of the BLT range of STATE (atg_blt_cfg) and runs one resolve per
 * kick (atg_blt routes the kick here when BLT_OP[2] is 1).
 *
 * The source: sample s of pixel (x, y) at SRC_BASE + y SRC_STRIDE + (4 x +
 * s) ps (the multisampled layout of section 12.11, ps of 1 to 16 bytes;
 * the base and the stride lose their bits below 4 ps).  The destination:
 * linear, or 4x4 tiles with BLT_RESOLVE[8] (16- and 32-bit pixels; the
 * bits below ps lost).  The averages (BLT_RESOLVE[7:4], section 8.5):
 * 0 UNORM8 (8, 16, 32 bits), 1 UNORM565 (16), 2 SAMPLE0 (all), 3 SRGB8_A8
 * (32), 4 SFLOAT16 (16, 32, 64), 5 SFLOAT32 (32, 64, 128), 6
 * UNORM2_10_10_10 (32), 7 UNORM1555 (16); atg_blt_avg and atg_blt_favg.
 * The destination rectangle is clipped to [CLIP_MIN, CLIP_MAX) when
 * CLIP_MAX is not 0; the source moves with it.  Anything else (another op,
 * blend, reverse, KEEP, a sample count other than 4, another average or
 * pixel size) is refused at the kick: error of kind OPCODE the next cycle,
 * busy stays 0, no access.
 *
 * The walk: per row, a descriptor to atg_blt_rsv_px (the row's first
 * source byte, its number of source lines, its pixels, the destination
 * row's address), then the reads of the row's source lines, in order.  The
 * one request register holds a request until the MC takes it and takes the
 * next one in the same cycle; atg_blt_rsv_px's writes go before reads.  A
 * read is taken only while the reads in flight, in the register and the
 * lines waiting in atg_blt_rsv_px's FIFO are fewer than its 2^DEPTH_LOG2
 * lines (the responses have no ready; the MC answers a client in order).
 * Source and destination must not overlap (the reads do not wait for the
 * writes).
 *
 * busy is 1 from the kick to done or error.  An error response stops new
 * requests and empties atg_blt_rsv_px (no response is pushed after it);
 * when every request is answered, error of kind AXI.  Under the MC's
 * quiesce the request waits and the walk goes on after it.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_rsv #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter DEPTH_LOG2 = 4
) (
	input wire clk,
	input wire rst_n,

	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,

	input wire kick,
	output wire busy,
	output reg done,
	output reg error,
	output reg [3:0] error_kind,

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

	localparam LBITS = LINE_BYTES * 8;
	localparam LS = LINE_SHIFT;
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam RD_W = ADDR_W + 51 + LINE_SHIFT;
	localparam DEPTH = 1 << DEPTH_LOG2;

	/* The BLT state (atg_blt_cfg). */
	wire [1:0] o_op;
	wire o_op2, o_blend, o_rev;
	wire [2:0] o_psl;
	wire [3:0] o_keep;
	wire [8:0] s_resolve;
	wire [16:0] clip_x0, clip_y0, clip_x1, clip_y1, dx, dy;
	wire [31:0] s_src_xy, dbase, sbase_p, dstride, sstride_p;
	wire [31:0] unused_rsv_src_slice, unused_rsv_dst_slice;
	wire [15:0] unused_rsv_depth;
	wire [LBITS-1:0] c_fill;
	wire c_ok;

	atg_blt_cfg #(.LINE_BYTES(LINE_BYTES)) cfg (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.op(o_op), .op2(o_op2), .resolve(s_resolve), .blend(o_blend), .rev(o_rev),
		.psl(o_psl), .keep(o_keep), .op_ok(c_ok), .x0(clip_x0), .y0(clip_y0), .x1(clip_x1),
		.y1(clip_y1), .dx(dx), .dy(dy), .src_xy(s_src_xy), .dbase(dbase), .sbase(sbase_p),
		.dstride(dstride), .sstride(sstride_p), .src_slice(unused_rsv_src_slice),
		.dst_slice(unused_rsv_dst_slice), .depth(unused_rsv_depth), .fill_line(c_fill)
	);

	/* The combinations taken: the average's pixel sizes (psl). */
	wire [3:0] o_fmt = {1'b0, s_resolve[7:4] > 4'd7 ? 3'd0 : s_resolve[6:4]};
	reg [4:0] sizes;
	always @(*)
		case (s_resolve[7:4])
		GHCI_RSV_UNORM8: sizes = 5'b00111;
		GHCI_RSV_UNORM565, GHCI_RSV_UNORM1555: sizes = 5'b00010;
		GHCI_RSV_SAMPLE0: sizes = 5'b11111;
		GHCI_RSV_SRGB8_A8, GHCI_RSV_UNORM2_10_10_10: sizes = 5'b00100;
		GHCI_RSV_SFLOAT16: sizes = 5'b01110;
		GHCI_RSV_SFLOAT32: sizes = 5'b11100;
		default: sizes = 5'b00000;
		endcase
	wire op_ok = {o_op2, o_op} == GHCI_BLT_RESOLVE && !o_blend && !o_rev && o_keep == 4'd0 &&
		s_resolve[3:0] == 4'd2 && sizes[o_psl] && !(s_resolve[8] && o_psl != 3'd1 &&
		o_psl != 3'd2);

	/* The mode, taken at the kick. */
	reg [2:0] psl, m_fmt;
	reg m_tiled;

	/*
	 * The constants of a pixel size, by table (no shift): 4 ps - 1 (the
	 * bits below four pixels), 4 ps and 12 ps (a tiled row's step and the
	 * step back from the fourth row of a tile).
	 */
	function [31:0] by_size;
		input [2:0] pl;
		input [1:0] which;	/* 0: 4 ps - 1, 1: 4 ps, 2: 12 ps */
		reg [31:0] four, low;
		begin
			case (pl)
			3'd0: begin four = 32'd4; low = 32'd3; end
			3'd1: begin four = 32'd8; low = 32'd7; end
			3'd2: begin four = 32'd16; low = 32'd15; end
			3'd3: begin four = 32'd32; low = 32'd31; end
			3'd4: begin four = 32'd64; low = 32'd63; end
			3'd5: begin four = 32'd128; low = 32'd127; end
			3'd6: begin four = 32'd256; low = 32'd255; end
			default: begin four = 32'd512; low = 32'd511; end
			endcase
			case (which)
			2'd0: by_size = low;
			2'd1: by_size = four;
			default: by_size = {four[30:0], 1'b0} | four;
			endcase
		end
	endfunction

	/* The source's base and stride lose their bits below 4 ps. */
	wire [ADDR_W-1:0] smask = ~by_size(psl, 2'd0);
	wire [ADDR_W-1:0] sbase = sbase_p & smask;
	wire [ADDR_W-1:0] sstride = sstride_p & smask;

	localparam [2:0] S_IDLE = 3'd0;
	localparam [2:0] S_CLIP = 3'd1;		/* size, source origin, multiplier */
	localparam [2:0] S_MUL = 3'd2;		/* row addresses: y * stride */
	localparam [2:0] S_RCALC = 3'd3;	/* the row's source lines */
	localparam [2:0] S_RISSUE = 3'd4;	/* the descriptor and the reads */
	localparam [2:0] S_DRAIN = 3'd5;	/* wait for every response */

	reg [2:0] state;
	reg fail;

	reg [16:0] x0, y0, x1, y1;
	wire empty = x1 <= x0 || y1 <= y0;
	reg [16:0] width, rows;	/* rows: left after this one */
	reg [16:0] sx0;
	reg [1:0] ydl;		/* destination y modulo 4 (tiles) */
	/* The rows' addresses: base + y stride, then the next row's step. */
	wire [ADDR_W-1:0] dst_row, src_row;
	wire d_idle, s_idle;
	wire row_go = state == S_CLIP && !empty;

	/* S_RCALC: the row's source byte range and lines. */
	wire [2:0] sh4;	/* log2 of 4 ps, modulo 8 as the 3-bit sum was */
	wire [ADDR_W-1:0] sx_b, w_b, r_first, r_end, r_last;
	wire [LA_W-1:0] r_span, r_nl;
	wire [5:0] rc_co_unused;

	am_add #(.W(3)) a_sh4 (.a(psl), .b(3'd2), .ci(1'b0), .s(sh4), .co(rc_co_unused[0]));
	am_shift #(.W(ADDR_W), .SW(3)) h_sx (.a({{(ADDR_W - 17){1'b0}}, sx0}), .amt(sh4), .left(1'b1), .arith(1'b0),
		.y(sx_b));
	am_shift #(.W(ADDR_W), .SW(3)) h_w (.a({{(ADDR_W - 17){1'b0}}, width}), .amt(sh4), .left(1'b1), .arith(1'b0),
		.y(w_b));
	am_add #(.W(ADDR_W)) a_first (.a(src_row), .b(sx_b), .ci(1'b0), .s(r_first), .co(rc_co_unused[1]));
	am_add #(.W(ADDR_W)) a_end (.a(r_first), .b(w_b), .ci(1'b0), .s(r_end), .co(rc_co_unused[2]));
	am_sub #(.W(ADDR_W)) s_last (.a(r_end), .b({ADDR_W{1'b0}}), .bi(1'b1), .d(r_last), .bo(rc_co_unused[3]));
	am_sub #(.W(LA_W)) s_span (.a(r_last[ADDR_W-1:LS]), .b(r_first[ADDR_W-1:LS]), .bi(1'b0), .d(r_span),
		.bo(rc_co_unused[4]));
	am_add #(.W(LA_W)) a_nl (.a(r_span), .b({LA_W{1'b0}}), .ci(1'b1), .s(r_nl), .co(rc_co_unused[5]));

	reg desc_pend;
	reg [RD_W-1:0] desc;
	reg [LA_W-1:0] rd_line;
	reg [16:0] rd_left;
	wire row_add = state == S_RISSUE && !fail && !desc_pend && rd_left == 17'd0 &&
		rows != 17'd0;

	/* The tiled destination's next row. */
	wire [ADDR_W-1:0] tile_step = by_size(psl, 2'd1);
	wire [ADDR_W-1:0] tile_back = by_size(psl, 2'd2);
	wire [ADDR_W-1:0] dst_back;
	wire [16:0] c_dy, sy0;
	wire [31:0] d_in_tile, d_first;
	wire [3:0] st_co_unused;

	am_sub #(.W(ADDR_W)) s_back (.a(dstride), .b(tile_back), .bi(1'b0), .d(dst_back), .bo(st_co_unused[0]));
	wire [ADDR_W-1:0] dst_step = m_tiled ? (ydl == 2'd3 ? dst_back : tile_step) :
		dstride;
	am_sub #(.W(17)) s_cdy (.a(y0), .b(dy), .bi(1'b0), .d(c_dy), .bo(st_co_unused[1]));
	am_add #(.W(17)) a_sy0 (.a({1'b0, s_src_xy[31:16]}), .b(c_dy), .ci(1'b0), .s(sy0), .co(st_co_unused[2]));

	/* The first row's address within its tile row: (y mod 4) x 4 pixels, in bytes. */
	am_shift #(.W(32), .SW(3)) h_dt (.a(m_tiled ? {28'd0, y0[1:0], 2'b00} : 32'd0), .amt(psl), .left(1'b1),
		.arith(1'b0), .y(d_in_tile));
	am_add #(.W(32)) a_df (.a(dbase), .b(d_in_tile), .ci(1'b0), .s(d_first), .co(st_co_unused[3]));

	atg_blt_acc dacc (
		.clk(clk), .rst_n(rst_n), .go(row_go), .y(m_tiled ? {2'b00, y0[16:2]} : y0),
		.s(dstride), .b(d_first),
		.add(row_add), .d(dst_step), .r(dst_row), .idle(d_idle)
	);
	atg_blt_acc sacc (
		.clk(clk), .rst_n(rst_n), .go(row_go), .y(sy0), .s(sstride), .b(sbase),
		.add(row_add), .d(sstride), .r(src_row), .idle(s_idle)
	);

	/* The pixel path. */
	wire px_rd_ready;
	wire [DEPTH_LOG2:0] ln_count;
	wire px_wr_valid;
	wire px_wr_ready;
	wire [LA_W-1:0] px_wr_line;
	wire [LINE_BYTES-1:0] px_wr_be;
	wire [LBITS-1:0] px_wr_data;
	wire px_idle;
	wire rsp_rd = rsp_valid && !rsp_write;
	wire rsp_wr = rsp_valid && rsp_write;

	atg_blt_rsv_px #(
		.ADDR_W(ADDR_W),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.DEPTH_LOG2(DEPTH_LOG2),
		.RD_W(RD_W)
	) px (
		.clk(clk),
		.rst_n(rst_n),
		.stop(fail),
		.psl(psl),
		.fmt(m_fmt),
		.tiled(m_tiled),
		.rd_valid(desc_pend),
		.rd_ready(px_rd_ready),
		.rd_data(desc),
		.ln_push(rsp_rd && !rsp_error && !fail),
		.ln_data(rsp_rdata),
		.ln_count(ln_count),
		.wr_valid(px_wr_valid),
		.wr_ready(px_wr_ready),
		.wr_line(px_wr_line),
		.wr_be(px_wr_be),
		.wr_data(px_wr_data),
		.idle(px_idle)
	);

	/* The request register. */
	reg q_valid, q_write;
	reg [LA_W-1:0] q_line;
	reg [LINE_BYTES-1:0] q_be;
	reg [LBITS-1:0] q_wdata;
	reg [DEPTH_LOG2:0] rd_out;
	reg [7:0] wr_out;

	assign req_valid = q_valid;
	assign req_write = q_write;
	assign req_line = q_line;
	assign req_be = q_be;
	assign req_wdata = q_wdata;
	assign req_tag = {7'd0, q_write};

	wire q_fire = q_valid && req_ready;
	wire q_open = (!q_valid || q_fire) && !fail;
	assign px_wr_ready = q_open && px_wr_valid;
	wire [DEPTH_LOG2+1:0] held;
	wire [DEPTH_LOG2:0] rd_up, rd_next;
	wire [7:0] wr_up, wr_next;
	wire [LA_W-1:0] rd_line_inc;
	wire [16:0] rd_left_dec, c_width, c_rows, c_dx, c_sx0, rows_dec;
	wire [1:0] ydl_inc;
	wire [12:0] q_co_unused;

	/* The reads held (in flight, in the line FIFO, queued), and the counts' next values. */
	am_add #(.W(DEPTH_LOG2 + 2)) a_held (.a({1'b0, rd_out}), .b({1'b0, ln_count}), .ci(q_valid && !q_write), .s(held),
		.co(q_co_unused[0]));
	am_add #(.W(DEPTH_LOG2 + 1)) a_rd (.a(rd_out), .b({(DEPTH_LOG2 + 1){1'b0}}), .ci(q_fire && !q_write), .s(rd_up),
		.co(q_co_unused[1]));
	am_sub #(.W(DEPTH_LOG2 + 1)) s_rd (.a(rd_up), .b({(DEPTH_LOG2 + 1){1'b0}}), .bi(rsp_rd), .d(rd_next),
		.bo(q_co_unused[2]));
	am_add #(.W(8)) a_wr (.a(wr_out), .b(8'd0), .ci(q_fire && q_write), .s(wr_up), .co(q_co_unused[3]));
	am_sub #(.W(8)) s_wr (.a(wr_up), .b(8'd0), .bi(rsp_wr), .d(wr_next), .bo(q_co_unused[4]));
	am_add #(.W(LA_W)) a_rl (.a(rd_line), .b({LA_W{1'b0}}), .ci(1'b1), .s(rd_line_inc), .co(q_co_unused[5]));
	am_sub #(.W(17)) s_rl (.a(rd_left), .b(17'd0), .bi(1'b1), .d(rd_left_dec), .bo(q_co_unused[6]));
	am_sub #(.W(17)) s_w (.a(x1), .b(x0), .bi(1'b0), .d(c_width), .bo(q_co_unused[7]));
	am_sub #(.W(17)) s_rows (.a(y1), .b(y0), .bi(1'b1), .d(c_rows), .bo(q_co_unused[8]));
	am_sub #(.W(17)) s_cdx (.a(x0), .b(dx), .bi(1'b0), .d(c_dx), .bo(q_co_unused[9]));
	am_add #(.W(17)) a_sx0 (.a({1'b0, s_src_xy[15:0]}), .b(c_dx), .ci(1'b0), .s(c_sx0), .co(q_co_unused[10]));
	am_sub #(.W(17)) s_rdec (.a(rows), .b(17'd0), .bi(1'b1), .d(rows_dec), .bo(q_co_unused[11]));
	am_add #(.W(2)) a_ydl (.a(ydl), .b(2'd0), .ci(1'b1), .s(ydl_inc), .co(q_co_unused[12]));
`ifdef MUT_RSV_CREDIT
	wire credit = 1'b1;	/* no credit */
`else
	wire credit = held < DEPTH;
`endif
	wire rd_take = q_open && !px_wr_valid && state == S_RISSUE && rd_left != 17'd0 && credit;

	assign busy = state != S_IDLE;

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			fail <= 1'b0;
			done <= 1'b0;
			error <= 1'b0;
			error_kind <= 4'd0;
			psl <= 3'd2;
			m_fmt <= 3'd0;
			m_tiled <= 1'b0;
			x0 <= 17'd0;
			y0 <= 17'd0;
			x1 <= 17'd0;
			y1 <= 17'd0;
			width <= 17'd0;
			rows <= 17'd0;
			sx0 <= 17'd0;
			ydl <= 2'd0;
			desc_pend <= 1'b0;
			desc <= {RD_W{1'b0}};
			rd_line <= {LA_W{1'b0}};
			rd_left <= 17'd0;
			q_valid <= 1'b0;
			q_write <= 1'b0;
			q_line <= {LA_W{1'b0}};
			q_be <= {LINE_BYTES{1'b0}};
			q_wdata <= {LBITS{1'b0}};
			rd_out <= {(DEPTH_LOG2 + 1){1'b0}};
			wr_out <= 8'd0;
		end else begin
			done <= 1'b0;
			error <= 1'b0;

			/* The port and the outstanding requests. */
			rd_out <= rd_next;
			wr_out <= wr_next;
			if (rsp_valid && rsp_error)
				fail <= 1'b1;
			if (q_fire)
				q_valid <= 1'b0;
			if (px_wr_ready) begin
				q_valid <= 1'b1;
				q_write <= 1'b1;
				q_line <= px_wr_line;
				q_be <= px_wr_be;
				q_wdata <= px_wr_data;
			end else if (rd_take) begin
				q_valid <= 1'b1;
				q_write <= 1'b0;
				q_line <= rd_line;
				q_be <= {LINE_BYTES{1'b1}};
				rd_line <= rd_line_inc;
				rd_left <= rd_left_dec;
			end
			if (desc_pend && px_rd_ready)
				desc_pend <= 1'b0;

			case (state)
			S_IDLE:
				if (kick) begin
					fail <= 1'b0;
					psl <= o_psl;
					m_fmt <= o_fmt[2:0];
					m_tiled <= s_resolve[8];
					if (!op_ok) begin
						error <= 1'b1;
						error_kind <= GHCI_FAULT_OPCODE;
					end else begin
						state <= S_CLIP;
						x0 <= clip_x0;
						y0 <= clip_y0;
						x1 <= clip_x1;
						y1 <= clip_y1;
					end
				end
			S_CLIP:
				if (empty) begin
					state <= S_IDLE;
					done <= 1'b1;
				end else begin
					state <= S_MUL;
					width <= c_width;
					rows <= c_rows;
					sx0 <= c_sx0;
					ydl <= y0[1:0];
				end
			S_MUL:
				if (fail)
					state <= S_DRAIN;
				else if (d_idle && s_idle)
					state <= S_RCALC;
			S_RCALC:
				if (fail) begin
					state <= S_DRAIN;
				end else begin
					state <= S_RISSUE;
					desc_pend <= 1'b1;
					desc <= {r_first[LS-1:0], r_nl[16:0], width, x0, dst_row};
					rd_line <= r_first[ADDR_W-1:LS];
					rd_left <= r_nl[16:0];
				end
			S_RISSUE:
				if (fail) begin
					state <= S_DRAIN;
				end else if (!desc_pend && rd_left == 17'd0) begin
					if (rows == 17'd0) begin
						state <= S_DRAIN;
					end else begin
						state <= S_RCALC;
						rows <= rows_dec;
						ydl <= ydl_inc;
					end
				end
			S_DRAIN:
				if ((px_idle || fail) && !q_valid && rd_out == {(DEPTH_LOG2 + 1){1'b0}} &&
				    wr_out == 8'd0 && !rsp_valid) begin
					state <= S_IDLE;
					if (fail) begin
						error <= 1'b1;
						error_kind <= GHCI_FAULT_AXI;
					end else begin
						done <= 1'b1;
					end
				end
			default:
				state <= S_IDLE;
			endcase
		end
	end

`ifdef RSV_TRACE
	always @(posedge clk) begin
		if (q_fire)
			$display("%m t=%0t %s line %h be %h", $time, q_write ? "W" : "R", q_line, q_be);
		if (desc_pend && px_rd_ready)
			$display("%m t=%0t desc off %0d nl %0d w %0d x %0d drow %h", $time,
				desc[RD_W-1 -: LS], desc[ADDR_W + 34 +: 17], desc[ADDR_W + 17 +: 17],
				desc[ADDR_W +: 17], desc[ADDR_W-1:0]);
	end
`endif

	wire unused_ok = &{1'b0, o_fmt[3], c_fill, c_ok, rsp_tag, r_nl[LA_W-1:17], r_last[LS-1:0], rc_co_unused,
		st_co_unused, q_co_unused, unused_rsv_src_slice, unused_rsv_dst_slice, unused_rsv_depth};
endmodule

`default_nettype wire
