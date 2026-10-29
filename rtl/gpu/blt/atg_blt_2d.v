/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_2d: the blitter's 2D engine (atg_blt routes to it the kicks with
 * BLT_OP[2] = 0): FILL, COPY, TILE (linear to 4x4 tiles) and UNTILE of a
 * rectangle through the blitter's AMB port (atg_mc), one blit per kick,
 * with the state of atg_blt_cfg (STATE 0x000-0x00A, 0x00C-0x00E as the CP
 * writes them, docs/ghci.md sections 8.2 and 8.5): pixels of 8, 16, 32,
 * 64 or 128 bits, blend-over of 32-bit FILL and COPY (atg_blt_blend), the
 * reverse direction of FILL and COPY (the bottom row first, right to
 * left), KEEP (32-bit FILL and COPY: the bytes of each pixel not written),
 * and the clip rectangle.  Other combinations are refused with an error
 * of kind OPCODE.
 *
 * Streaming burst DMA architecture (Phase 030):
 * For COPY, TILE, UNTILE and FILL without blend/RAW smear, a 1 KiB ping-pong
 * buffer (Bank 0 / Bank 1, 512B each) and decoupled prefetch walk decouple
 * source burst reads from destination pipeline writes. Source lines are
 * prefetched into the active filling bank, aligned via a single-cycle barrel
 * shifter on read-out, and written as continuous pipeline bursts without
 * per-segment stop-and-wait roundtrip penalties, achieving 1.0+ GB/s throughput.
 * Blend-over and self-overlapping smear operations fall back to the serial
 * verified path.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_2d #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire kick,
	output wire busy,
	output wire [3:0] fsm,
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

	localparam LINE_BITS = LINE_BYTES * 8;
	localparam US = LINE_SHIFT;		/* log2 of the bytes of a line */
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam [2:0] MAX_SEGS_M1 = (LINE_SHIFT == 5) ? 3'd7 : 3'd3;
	localparam [3:0] SLOT_LIMIT1 = (LINE_SHIFT == 5) ? 4'd15 : 4'd7;
	localparam [3:0] SLOT_LIMIT2 = (LINE_SHIFT == 5) ? 4'd14 : 4'd6;

	/* The state and the operation (atg_blt_cfg). */
	wire [1:0] o_op;
	wire o_blend, o_rev, op_ok;
	wire [2:0] o_psl;
	wire [3:0] o_keep;
	wire [16:0] clip_x0, clip_y0, clip_x1, clip_y1, dx, dy;
	wire [31:0] s_src_xy, dbase_u, sbase_u, dstride_u, sstride_u;
	wire [31:0] src_slice_u, dst_slice_u;
	wire [15:0] depth_u;
	wire [LINE_BITS-1:0] fill_line;
	wire c_op2;
	wire [8:0] c_resolve;

	atg_blt_cfg #(.LINE_BYTES(LINE_BYTES)) cfg (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.op(o_op), .op2(c_op2), .resolve(c_resolve), .blend(o_blend), .rev(o_rev), .psl(o_psl), .keep(o_keep), .op_ok(op_ok),
		.x0(clip_x0), .y0(clip_y0), .x1(clip_x1), .y1(clip_y1), .dx(dx), .dy(dy),
		.src_xy(s_src_xy), .dbase(dbase_u), .sbase(sbase_u), .dstride(dstride_u),
		.sstride(sstride_u), .src_slice(src_slice_u), .dst_slice(dst_slice_u), .depth(depth_u), .fill_line(fill_line)
	);

	/* The mode of the blit in progress, taken at the kick. */
	reg m_copy;		/* reads a source: COPY, TILE, UNTILE */
	reg m_blend;
	reg m_rev;
	reg m_dtile, m_stile;	/* the destination (TILE), the source (UNTILE) is tiled */
	reg [2:0] psl;		/* log2 of the pixel's bytes */
	reg [3:0] m_keep;
	reg m_burst;

	/* The pixel offset of pixel x in a row (linear or in 4x4 tiles); its bytes are this << psl. */
	function [ADDR_W-1:0] x_pixels;
		input [16:0] x;
		input tiled;
		x_pixels = tiled ? {{(ADDR_W - 19){1'b0}}, x[16:2], 2'b00, x[1:0]} :
			{{(ADDR_W - 17){1'b0}}, x};
	endfunction

	/* A tile row's bytes, 4 << psl, and three of them, 12 << psl, by table. */
	function [ADDR_W-1:0] tile_bytes;
		input [2:0] pl;
		input three;
		reg [ADDR_W-1:0] t;
		begin
			case (pl)
			3'd0: t = 4;
			3'd1: t = 8;
			3'd2: t = 16;
			3'd3: t = 32;
			3'd4: t = 64;
			3'd5: t = 128;
			3'd6: t = 256;
			default: t = 512;
			endcase
			tile_bytes = three ? {t[ADDR_W-2:0], 1'b0} | t : t;
		end
	endfunction

	localparam [3:0] S_IDLE = 4'd0;
	localparam [3:0] S_CLIP = 4'd1;		/* size and source origin */
	localparam [3:0] S_START = 4'd2;	/* the first row and pixel */
	localparam [3:0] S_MUL = 4'd3;		/* row addresses: y * stride */
	localparam [3:0] S_SA = 4'd4;		/* segment: the pixel's addresses */
	localparam [3:0] S_SB = 4'd5;		/* segment: its length */
	localparam [3:0] S_SC = 4'd6;		/* segment: its first byte */
	localparam [3:0] S_SD = 4'd7;		/* segment: lines and shift */
	localparam [3:0] S_CRD = 4'd8;		/* read the source lines */
	localparam [3:0] S_CWAIT = 4'd9;	/* wait for them */
	localparam [3:0] S_DRD = 4'd10;		/* blend: read the destination line */
	localparam [3:0] S_DWAIT = 4'd11;	/* wait for it */
	localparam [3:0] S_BLEND = 4'd12;	/* blend the line */
	localparam [3:0] S_WR = 4'd13;		/* queue the segment's write */
	localparam [3:0] S_DRAIN = 4'd14;	/* wait for every response */
	localparam [3:0] S_BURST = 4'd15;	/* decoupled streaming burst DMA */

	reg [3:0] state;

	/* The rectangle. */
	reg [16:0] x0, y0, x1, y1;
	wire empty = x1 <= x0 || y1 <= y0;
	reg [16:0] width, rows;	/* rows: left after this one */
	reg [16:0] sx0, sy0;	/* the source pixel of x0, y0 */
	reg [16:0] px_row, spx_row;	/* the first pixel of every row */

	/* Row walking: the row's y modulo 4 (tiles); the rows' byte addresses
	 * (base + y stride, then + the step a row) in atg_blt_acc. */
	reg [1:0] ydl, ysl;
	reg [16:0] px, spx;	/* the next pixel (rightmost reversed), its source pixel */
	reg [16:0] rem;		/* pixels left in the row */

	/* The segment. */
	reg [ADDR_W-1:0] da, sa;	/* byte addresses of px, spx */
	reg [US:0] sn, snu;	/* pixels, bytes */
	reg [ADDR_W-1:0] dlo, slo;	/* first destination and source bytes */
	reg [LA_W-1:0] seg_line;
	reg [US-1:0] seg_p0;
	reg [US-1:0] src_off;
	reg [LA_W-1:0] src_n0, src_n1;
	reg n0_slot;
	reg rd_first, rd_second;	/* the first, a needed second source read is to go */

	/*
	 * =========================================================================
	 * Burst Engine Signals & Registers
	 * =========================================================================
	 */
	/* 1 KiB RAM (32 slots) */
	reg [LINE_BITS-1:0] pp_ram [0:31];

	/* Bank Metadata (2 Banks, up to 8 segments each, full D-FF registers) */
	(* ram_style = "registers" *) reg [LA_W-1:0] meta_dline_0 [0:7];
	(* ram_style = "registers" *) reg [LA_W-1:0] meta_dline_1 [0:7];
	(* ram_style = "registers" *) reg [LINE_BYTES-1:0] meta_be_0 [0:7];
	(* ram_style = "registers" *) reg [LINE_BYTES-1:0] meta_be_1 [0:7];
	(* ram_style = "registers" *) reg [US-1:0] meta_off_0 [0:7];
	(* ram_style = "registers" *) reg [US-1:0] meta_off_1 [0:7];
	(* ram_style = "registers" *) reg [3:0] meta_slot0_0 [0:7];
	(* ram_style = "registers" *) reg [3:0] meta_slot0_1 [0:7];
	(* ram_style = "registers" *) reg [3:0] meta_slot1_0 [0:7];
	(* ram_style = "registers" *) reg [3:0] meta_slot1_1 [0:7];
	reg [7:0] meta_n0slot_0, meta_n0slot_1;
	reg [3:0] bank_num_segs_0, bank_num_segs_1;
	reg [1:0] bank_is_last;
	reg [1:0] bank_active;
	reg [1:0] bank_closed;
	reg [1:0] bank_ready;
	reg [4:0] bank_rd_pending_0, bank_rd_pending_1;
	reg rows_b_zero;

	/* Burst Walk & Prefetch registers */
	reg bw_bank;
	reg [2:0] bw_seg_idx;
	reg [3:0] bw_slot_cnt;
	reg bw_sub;
	reg bw_done_all;
	reg bw_walk_done;
	(* extract_enable = "no" *) reg [16:0] px_b, spx_b, rem_b;
	reg [16:0] rows_b;
	(* extract_enable = "no" *) reg [US-1:0] cur_da_b, cur_da_row;
	reg [1:0] ydl_b, ysl_b;
	reg [ADDR_W-1:0] dst_row_b, src_row_b;
	(* max_fanout = 8 *) reg [2:0] psl_w;
	reg [US:0] line_pixels_b;

	/* Burst segment pipeline registers: 3-stage pipeline */
	/* Stage 1 -> Stage 2 (Geom pipeline registers) */
	reg g_valid;
	reg [ADDR_W-1:0] g_dst_row, g_src_row;
	reg [16:0] g_px, g_spx;
	reg [US:0] g_seg_n;
	reg g_seg_last;
	reg g_rows_b_zero;

	/* Stage 2 -> Stage 3 (Issue pipeline registers) */
	reg p_valid;
	reg [LA_W-1:0] p_dline;
	reg [US:0] p_seg_n;
	reg [US-1:0] p_dlo_lo;
	reg [US-1:0] p_off;
	reg [LA_W-1:0] p_src_n0;
	reg [LA_W-1:0] p_src_n1;
	reg p_two_lines;
	reg p_n0_slot;
	reg p_seg_last;
	reg p_rows_b_zero;

	/* Burst Write & Commit registers */
	reg br_bank;
	reg [2:0] br_seg_idx;
	reg br_active;
	reg b_draining;
	reg [4:0] burst_wr_out;

	/* Mux inputs to address and segment logic */
	wire bw_slot_full_p = p_two_lines ? (bw_slot_cnt >= SLOT_LIMIT2) : (bw_slot_cnt >= SLOT_LIMIT1);
	wire is_burst_state = (state == S_BURST);
	wire [16:0] cur_px = is_burst_state ? px_b : px;
	wire [16:0] cur_spx = is_burst_state ? spx_b : spx;
	wire [16:0] cur_rem = is_burst_state ? rem_b : rem;
	wire [ADDR_W-1:0] cur_dst_row = is_burst_state ? dst_row_b : dst_row;
	wire [ADDR_W-1:0] cur_src_row = is_burst_state ? src_row_b : src_row;

	/*
	 * =========================================================================
	 * Segment Geometry & Addresses: Common Combinational Datapath
	 * =========================================================================
	 */
	wire [ADDR_W-1:0] cur_da_full = d_addr;
	wire [ADDR_W-1:0] cur_sa_full = s_addr;

	/* The segment's geometry (atg_blt_seg, combinational). */
	wire [US:0] seg_n;
	wire [ADDR_W-1:0] back, src_base_u;
	wire [LA_W-1:0] last_line;
	wire [LINE_BYTES-1:0] seg_be;


	/* verilator lint_off WIDTHTRUNC */
	localparam [US:0] LB_V = LINE_BYTES;
	/* verilator lint_on WIDTHTRUNC */

	wire [US:0] calc_line_pixels = (psl == 3'd4) ? {4'b0000, LB_V[US:4]} :
	                               (psl == 3'd3) ? {3'b000, LB_V[US:3]}  :
	                               (psl == 3'd2) ? {2'b00, LB_V[US:2]}   :
	                               (psl == 3'd1) ? {1'b0, LB_V[US:1]}    : LB_V;

	/* Legacy FSM Segment Engine (completely isolated from burst) */
	atg_blt_seg #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) seg (
		.psl(psl), .line_pix(calc_line_pixels), .rev(m_rev), .dtile(m_dtile), .stile(m_stile), .keep(m_keep),
		.da(da[US-1:0]), .px(px[1:0]), .spx(spx[1:0]), .rem(rem),
		.sn(sn), .snu(snu), .dlo(dlo[US-1:0]), .slo(slo),
		.p0(seg_p0), .seg_n(seg_n), .seg_last(), .back(back), .src_base(src_base_u),
		.last_line(last_line), .be(seg_be)
	);
	wire [LA_W-1:0] src_lo = src_base_u[ADDR_W-1:US];

	/*
	 * =================================================================
	 * Burst Engine: 3-Stage Pipeline (Walk -> Geom/Address -> Issue)
	 * =================================================================
	 */
	/* Stage 1: Walk Stage (Computes only bst_seg_n for coordinate walking) */
	wire [ADDR_W-1:0] d_px_row = x_pixels(px_row, m_dtile);
	wire [US-1:0] d_xb_row = (psl == 3'd4) ? {d_px_row[US-5:0], 4'b0000} :
	                         (psl == 3'd3) ? {d_px_row[US-4:0], 3'b000}  :
	                         (psl == 3'd2) ? {d_px_row[US-3:0], 2'b00}   :
	                         (psl == 3'd1) ? {d_px_row[US-2:0], 1'b0}    : d_px_row[US-1:0];
	wire [US-1:0] cur_da_init;
	wire co_da_init;
	am_add #(.W(US)) a_da_init (.a(dst_row[US-1:0]), .b(d_xb_row), .ci(1'b0), .s(cur_da_init), .co(co_da_init));

	wire [US-1:0] cur_da_row_next;
	wire co_da_row;
	am_add #(.W(US)) a_da_row (.a(dst_row_b_next[US-1:0]), .b(d_xb_row), .ci(1'b0), .s(cur_da_row_next), .co(co_da_row));

	wire [US:0] bst_seg_n;
	wire bst_seg_last;
	atg_blt_seg #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) bst_seg (
		.psl(psl_w), .line_pix(line_pixels_b), .rev(m_rev), .dtile(m_dtile), .stile(m_stile), .keep(m_keep),
		.da(cur_da_b), .px(px_b[1:0]), .spx(spx_b[1:0]), .rem(rem_b),
		.sn({(US+1){1'b0}}), .snu({(US+1){1'b0}}), .dlo({US{1'b0}}), .slo({ADDR_W{1'b0}}),
		.p0({US{1'b0}}), .seg_n(bst_seg_n), .seg_last(bst_seg_last), .back(), .src_base(),
		.last_line(), .be()
	);

	wire [US-1:0] bst_seg_bytes = (psl_w == 3'd4) ? {bst_seg_n[US-5:0], 4'b0000} :
	                              (psl_w == 3'd3) ? {bst_seg_n[US-4:0], 3'b000}  :
	                              (psl_w == 3'd2) ? {bst_seg_n[US-3:0], 2'b00}   :
	                              (psl_w == 3'd1) ? {bst_seg_n[US-2:0], 1'b0}    : bst_seg_n[US-1:0];
	wire [US-1:0] cur_da_seg_next;
	wire co_da_seg;
	am_addsub #(.W(US)) as_da_seg (.a(cur_da_b), .b(bst_seg_bytes), .sub(m_rev), .s(cur_da_seg_next), .co(co_da_seg));
	wire [US-1:0] cur_da_b_d = bst_seg_last ? cur_da_row_next : cur_da_seg_next;
	/* Carry-Select Parallel Split Addsub for Coordinates */
	/* 1. px_next */
	wire [US:0] px_lo_next;
	wire px_lo_co;
	am_addsub #(.W(US + 1)) as_px_lo (.a(px_b[US:0]), .b(bst_seg_n), .sub(m_rev), .s(px_lo_next), .co(px_lo_co));

	wire [16-US-1:0] px_hi = px_b[16:US+1];
	wire [16-US-1:0] px_hi_p1, px_hi_m1;
	wire [1:0] px_hi_co;
	am_add #(.W(16 - US)) a_px_p1 (.a(px_hi), .b({(16-US){1'b0}}), .ci(1'b1), .s(px_hi_p1), .co(px_hi_co[0]));
	am_sub #(.W(16 - US)) s_px_m1 (.a(px_hi), .b({(16-US){1'b0}}), .bi(1'b1), .d(px_hi_m1), .bo(px_hi_co[1]));
	wire [16-US-1:0] px_hi_delta = m_rev ? px_hi_m1 : px_hi_p1;
	wire [16-US-1:0] px_hi_w0 = walk_step ? (bst_seg_last ? px_row[16:US+1] : px_hi)       : px_hi;
	wire [16-US-1:0] px_hi_w1 = walk_step ? (bst_seg_last ? px_row[16:US+1] : px_hi_delta) : px_hi;
	wire [16-US-1:0] px_hi_final = m_rev ? (px_lo_co ? px_hi_w0 : px_hi_w1) : (px_lo_co ? px_hi_w1 : px_hi_w0);
	wire [US:0] px_lo_w = walk_step ? (bst_seg_last ? px_row[US:0] : px_lo_next) : px_b[US:0];
	wire [16:0] px_b_next = {px_hi_final, px_lo_w};

	/* 2. spx_next */
	wire [US:0] spx_lo_next;
	wire spx_lo_co;
	am_addsub #(.W(US + 1)) as_spx_lo (.a(spx_b[US:0]), .b(bst_seg_n), .sub(m_rev), .s(spx_lo_next), .co(spx_lo_co));

	wire [16-US-1:0] spx_hi = spx_b[16:US+1];
	wire [16-US-1:0] spx_hi_p1, spx_hi_m1;
	wire [1:0] spx_hi_co;
	am_add #(.W(16 - US)) a_spx_p1 (.a(spx_hi), .b({(16-US){1'b0}}), .ci(1'b1), .s(spx_hi_p1), .co(spx_hi_co[0]));
	am_sub #(.W(16 - US)) s_spx_m1 (.a(spx_hi), .b({(16-US){1'b0}}), .bi(1'b1), .d(spx_hi_m1), .bo(spx_hi_co[1]));
	wire [16-US-1:0] spx_hi_delta = m_rev ? spx_hi_m1 : spx_hi_p1;
	wire [16-US-1:0] spx_hi_w0 = walk_step ? (bst_seg_last ? spx_row[16:US+1] : spx_hi)       : spx_hi;
	wire [16-US-1:0] spx_hi_w1 = walk_step ? (bst_seg_last ? spx_row[16:US+1] : spx_hi_delta) : spx_hi;
	wire [16-US-1:0] spx_hi_final = m_rev ? (spx_lo_co ? spx_hi_w0 : spx_hi_w1) : (spx_lo_co ? spx_hi_w1 : spx_hi_w0);
	wire [US:0] spx_lo_w = walk_step ? (bst_seg_last ? spx_row[US:0] : spx_lo_next) : spx_b[US:0];
	wire [16:0] spx_b_next = {spx_hi_final, spx_lo_w};

	/* 3. rem_next */
	wire [US:0] rem_lo_next;
	wire rem_lo_bo;
	am_sub #(.W(US + 1)) s_rem_lo (.a(rem_b[US:0]), .b(bst_seg_n), .bi(1'b0), .d(rem_lo_next), .bo(rem_lo_bo));

	wire [16-US-1:0] rem_hi = rem_b[16:US+1];
	wire [16-US-1:0] rem_hi_m1;
	wire rem_hi_bo;
	am_sub #(.W(16 - US)) s_rem_m1 (.a(rem_hi), .b({(16-US){1'b0}}), .bi(1'b1), .d(rem_hi_m1), .bo(rem_hi_bo));
	wire [16-US-1:0] rem_hi_w0 = walk_step ? (bst_seg_last ? width[16:US+1] : rem_hi)    : rem_hi;
	wire [16-US-1:0] rem_hi_w1 = walk_step ? (bst_seg_last ? width[16:US+1] : rem_hi_m1) : rem_hi;
	wire [16-US-1:0] rem_hi_final = rem_lo_bo ? rem_hi_w1 : rem_hi_w0;
	wire [US:0] rem_lo_w = walk_step ? (bst_seg_last ? width[US:0] : rem_lo_next) : rem_b[US:0];
	wire [16:0] rem_b_next = {rem_hi_final, rem_lo_w};

	wire [US-1:0] cur_da_b_next = walk_step ? cur_da_b_d : cur_da_b;

	/* Stage 2: Geom / Address Engine (Computed from g_* registers in next cycle) */
	wire [ADDR_W-1:0] d_px_g = x_pixels(g_px, m_dtile);
	wire [ADDR_W-1:0] s_px_g = x_pixels(g_spx, m_stile);
	wire [ADDR_W-1:0] d_xb_g = (psl_w == 3'd4) ? {d_px_g[ADDR_W-5:0], 4'b0000} :
	                           (psl_w == 3'd3) ? {d_px_g[ADDR_W-4:0], 3'b000}  :
	                           (psl_w == 3'd2) ? {d_px_g[ADDR_W-3:0], 2'b00}   :
	                           (psl_w == 3'd1) ? {d_px_g[ADDR_W-2:0], 1'b0}    : d_px_g;
	wire [ADDR_W-1:0] s_xb_g = (psl_w == 3'd4) ? {s_px_g[ADDR_W-5:0], 4'b0000} :
	                           (psl_w == 3'd3) ? {s_px_g[ADDR_W-4:0], 3'b000}  :
	                           (psl_w == 3'd2) ? {s_px_g[ADDR_W-3:0], 2'b00}   :
	                           (psl_w == 3'd1) ? {s_px_g[ADDR_W-2:0], 1'b0}    : s_px_g;

	wire [US-1:0] g_da_lo, g_sa_lo;
	wire [1:0] g_dsa_co;
	am_add #(.W(US)) a_da_lo (.a(g_dst_row[US-1:0]), .b(d_xb_g[US-1:0]), .ci(1'b0), .s(g_da_lo), .co(g_dsa_co[0]));
	am_add #(.W(US)) a_sa_lo (.a(g_src_row[US-1:0]), .b(s_xb_g[US-1:0]), .ci(1'b0), .s(g_sa_lo), .co(g_dsa_co[1]));

	wire [US:0] g_seg_bytes = (psl_w == 3'd4) ? {g_seg_n[US-4:0], 4'b0000} :
	                          (psl_w == 3'd3) ? {g_seg_n[US-3:0], 3'b000}  :
	                          (psl_w == 3'd2) ? {g_seg_n[US-2:0], 2'b00}   :
	                          (psl_w == 3'd1) ? {g_seg_n[US-1:0], 1'b0}    : g_seg_n;

	wire [US:0] g_back_n;
	wire [1:0] g_back_co;
	am_sub #(.W(US + 1)) s_bn_b (.a(g_seg_n), .b({(US + 1){1'b0}}), .bi(1'b1), .d(g_back_n), .bo(g_back_co[0]));
	wire [ADDR_W-1:0] g_back = (psl_w == 3'd4) ? {{(ADDR_W - US - 5){1'b0}}, g_back_n, 4'b0000} :
	                           (psl_w == 3'd3) ? {{(ADDR_W - US - 4){1'b0}}, g_back_n, 3'b000}  :
	                           (psl_w == 3'd2) ? {{(ADDR_W - US - 3){1'b0}}, g_back_n, 2'b00}   :
	                           (psl_w == 3'd1) ? {{(ADDR_W - US - 2){1'b0}}, g_back_n, 1'b0}    :
	                                             {{(ADDR_W - US - 1){1'b0}}, g_back_n};

	wire [US-1:0] g_dlo_lo_rev;
	wire g_dlo_lo_bo;
	am_sub #(.W(US)) s_dlo_lo (.a(g_da_lo), .b(g_back[US-1:0]), .bi(1'b0), .d(g_dlo_lo_rev), .bo(g_dlo_lo_bo));
	wire [US-1:0] g_dlo_lo = m_rev ? g_dlo_lo_rev : g_da_lo;

	wire [ADDR_W-1:0] g_da_full, g_sa_full;
	wire [1:0] g_full_co;
	am_add #(.W(ADDR_W)) a_bda (.a(g_dst_row), .b(d_xb_g), .ci(1'b0), .s(g_da_full), .co(g_full_co[0]));
	am_add #(.W(ADDR_W)) a_bsa (.a(g_src_row), .b(s_xb_g), .ci(1'b0), .s(g_sa_full), .co(g_full_co[1]));

	wire [LA_W-1:0] s_line = g_sa_full[ADDR_W-1:US];
	wire [LA_W-1:0] s_line_p1, s_line_m1;
	wire [1:0] s_line_co;
	am_add #(.W(LA_W)) a_s_p1 (.a(s_line), .b({LA_W{1'b0}}), .ci(1'b1), .s(s_line_p1), .co(s_line_co[0]));
	am_sub #(.W(LA_W)) s_s_m1 (.a(s_line), .b({LA_W{1'b0}}), .bi(1'b1), .d(s_line_m1), .bo(s_line_co[1]));

	wire [LA_W-1:0] d_line = g_da_full[ADDR_W-1:US];
	wire [LA_W-1:0] d_line_m1;
	wire d_line_bo;
	am_sub #(.W(LA_W)) s_d_m1 (.a(d_line), .b({LA_W{1'b0}}), .bi(1'b1), .d(d_line_m1), .bo(d_line_bo));

	wire slo_borrow = (g_sa_lo < g_back[US-1:0]);
	wire dlo_borrow = (g_da_lo < g_back[US-1:0]);

	wire [LA_W-1:0] g_seg_line = m_rev ? (dlo_borrow ? d_line_m1 : d_line) : d_line;
	wire [LA_W-1:0] g_src_n0   = m_rev ? (slo_borrow ? s_line_m1 : s_line) : s_line;
	wire [LA_W-1:0] g_src_n1   = m_rev ? s_line : s_line_p1;

	wire [US-1:0] g_slo_lo_rev;
	wire g_slo_lo_bo;
	am_sub #(.W(US)) s_slo_lo (.a(g_sa_lo), .b(g_back[US-1:0]), .bi(1'b0), .d(g_slo_lo_rev), .bo(g_slo_lo_bo));
	wire [US-1:0] g_slo_lo = m_rev ? g_slo_lo_rev : g_sa_lo;

	wire [US:0] g_s_end;
	wire g_send_co;
	am_add #(.W(US + 1)) a_bst_send (.a({1'b0, g_slo_lo}), .b(g_seg_bytes), .ci(1'b0), .s(g_s_end), .co(g_send_co));
	wire        g_two_lines = m_rev ? slo_borrow : (g_s_end > {1'b1, {US{1'b0}}});

	wire [US-1:0] g_src_off;
	wire          g_n0_slot;
	am_sub #(.W(US)) s_bst_off (.a(g_slo_lo), .b(g_dlo_lo), .bi(1'b0), .d(g_src_off), .bo(g_n0_slot));

	/* The port: the request, the outstanding requests, the line buffers. */
	wire q_free, rd_idle, wr_idle, fail;
	wire [LINE_BITS-1:0] buf0, buf1, bufd;
	wire rd_go = state == S_CRD && q_free && wr_idle && !fail && (rd_first || rd_second);
	wire drd_go = state == S_DRD && q_free && wr_idle && !fail;
	wire wr_go = state == S_WR && q_free && !fail;

	/* The copied line: the source window shifted by whole bytes. */
	wire [2*LINE_BITS-1:0] both = {buf1, buf0};
	wire [2*LINE_BITS-1:0] shifted;

	am_shift #(.W(2 * LINE_BITS), .SW(US + 3)) h_copy (.a(both), .amt({src_off, 3'd0}), .left(1'b0), .arith(1'b0),
		.y(shifted));
	wire [LINE_BITS-1:0] copy_line = shifted[LINE_BITS-1:0];

	/* Blend-over. */
	wire bl_done;
	wire [LINE_BITS-1:0] bl_out;
	reg bl_go;

	atg_blt_blend #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) bl (
		.clk(clk), .rst_n(rst_n), .go(bl_go), .src(m_copy ? copy_line : fill_line),
		.dst(bufd), .done(bl_done), .out(bl_out)
	);

	/* Legacy port instance */
	wire leg_req_valid, leg_req_write;
	wire [LA_W-1:0] leg_req_line;
	wire [LINE_BYTES-1:0] leg_req_be;
	wire [LINE_BITS-1:0] leg_req_wdata;
	wire [7:0] leg_req_tag;

	atg_blt_port #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) port (
		.clk(clk), .rst_n(rst_n), .clr(state == S_IDLE && kick),
		.issue((rd_go || drd_go || wr_go) && !m_burst), .i_write(wr_go),
		.i_line(rd_go ? (rd_first ? src_n0 : src_n1) : seg_line),
		.i_slot(rd_go ? (rd_first ? {1'b0, n0_slot} : 2'd1) : drd_go ? 2'd2 : 2'd0),
		.i_be(wr_go ? seg_be : {LINE_BYTES{1'b1}}),
		.i_wdata(m_blend ? bl_out : m_copy ? copy_line : fill_line),
		.free(q_free), .rd_idle(rd_idle), .wr_idle(wr_idle), .fail(fail),
		.buf0(buf0), .buf1(buf1), .bufd(bufd),
		.req_valid(leg_req_valid), .req_ready(req_ready && !m_burst), .req_write(leg_req_write),
		.req_line(leg_req_line), .req_be(leg_req_be), .req_wdata(leg_req_wdata), .req_tag(leg_req_tag),
		.rsp_valid(rsp_valid && !m_burst), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	/*
	 * =========================================================================
	 * Burst Engine Read/Write Data Path & Barrel Shifter
	 * =========================================================================
	 */
	/* Read-out from ping-pong RAM */
	wire [3:0] r_slot0 = br_bank ? meta_slot0_1[br_seg_idx] : meta_slot0_0[br_seg_idx];
	wire [3:0] r_slot1 = br_bank ? meta_slot1_1[br_seg_idx] : meta_slot1_0[br_seg_idx];
	wire [LINE_BITS-1:0] pp_sdata0 = pp_ram[{br_bank, r_slot0}];
	wire [LINE_BITS-1:0] pp_sdata1 = pp_ram[{br_bank, r_slot1}];
	wire r_n0slot = br_bank ? meta_n0slot_1[br_seg_idx] : meta_n0slot_0[br_seg_idx];
	wire [US-1:0] r_off = br_bank ? meta_off_1[br_seg_idx] : meta_off_0[br_seg_idx];
	wire [2*LINE_BITS-1:0] pp_both = r_n0slot ? {pp_sdata0, pp_sdata1} : {pp_sdata1, pp_sdata0};
	wire [2*LINE_BITS-1:0] pp_shifted;

	am_shift #(.W(2 * LINE_BITS), .SW(US + 3)) h_pp_shift (
		.a(pp_both), .amt({r_off, 3'd0}), .left(1'b0), .arith(1'b0), .y(pp_shifted)
	);
	wire [LINE_BITS-1:0] pp_copy_line = pp_shifted[LINE_BITS-1:0];

	/* Burst requests to AMB */
	wire [US:0] issue_seg_bytes;
	am_shift #(.W(US + 1), .SW(3)) h_iss_sn (.a(p_seg_n), .amt(psl), .left(1'b1), .arith(1'b0), .y(issue_seg_bytes));

	wire [US:0] issue_p_end;
	wire issue_pend_co;
	am_add #(.W(US + 1)) a_iss_pe (.a({1'b0, p_dlo_lo}), .b(issue_seg_bytes), .ci(1'b0), .s(issue_p_end), .co(issue_pend_co));

	reg [LINE_BYTES-1:0] issue_be;
	integer ib;
	always @(*)
		for (ib = 0; ib < LINE_BYTES; ib = ib + 1)
			issue_be[ib] = ib[US:0] >= {1'b0, p_dlo_lo} && ib[US:0] < issue_p_end && !m_keep[ib % 4];

	wire bst_can_fill_p = p_valid && (!bank_active[bw_bank] || !bank_closed[bw_bank]);
	wire bst_rd_need = m_copy;

	reg bst_rd_valid;
	reg [LA_W-1:0] bst_rd_line;
	reg [7:0] bst_rd_tag;

	always @(*) begin
		bst_rd_valid = 1'b0;
		bst_rd_line = p_src_n0;
		bst_rd_tag = {1'b0, 2'd0, bw_bank, bw_slot_cnt};
		if (state == S_BURST && bst_can_fill_p && bst_rd_need && !fail) begin
			bst_rd_valid = 1'b1;
			if (bw_sub) begin
				bst_rd_line = p_src_n1;
				bst_rd_tag = {1'b0, 2'd0, bw_bank, bw_slot_p1};
			end else begin
				bst_rd_line = p_src_n0;
				bst_rd_tag = {1'b0, 2'd0, bw_bank, bw_slot_cnt};
			end
		end
	end

	wire bst_wr_valid = (state == S_BURST) && br_active && !fail;
	wire [LA_W-1:0] bst_wr_line = br_bank ? meta_dline_1[br_seg_idx] : meta_dline_0[br_seg_idx];
	wire [LINE_BYTES-1:0] bst_wr_be = br_bank ? meta_be_1[br_seg_idx] : meta_be_0[br_seg_idx];
	wire [LINE_BITS-1:0] bst_wr_wdata = m_copy ? pp_copy_line : fill_line;
	wire [7:0] bst_wr_tag = 8'h80;

	/* AMB Arbiter: write takes precedence over read to clear buffer space */
	wire bst_wr_fire = bst_wr_valid && req_ready;
	wire bst_rd_fire = bst_rd_valid && !bst_wr_valid && req_ready;

	wire bst_req_valid = bst_wr_valid || bst_rd_valid;
	wire bst_req_write = bst_wr_valid;
	wire [LA_W-1:0] bst_req_line = bst_wr_valid ? bst_wr_line : bst_rd_line;
	wire [LINE_BYTES-1:0] bst_req_be = bst_wr_valid ? bst_wr_be : {LINE_BYTES{1'b1}};
	wire [LINE_BITS-1:0] bst_req_wdata = bst_wr_wdata;
	wire [7:0] bst_req_tag = bst_wr_valid ? bst_wr_tag : bst_rd_tag;

	wire issue_fire = (state == S_BURST) && bst_can_fill_p && (!m_copy || (p_two_lines ? (bw_sub && bst_rd_fire) : bst_rd_fire));
	wire step_p = !p_valid || issue_fire;
	wire step_g = !g_valid || step_p;
	(* direct_enable = "yes" *) wire walk_step = (state == S_BURST) && !bw_walk_done && step_g;

	/* Mux external AMB outputs between burst and legacy port */
	assign req_valid = m_burst ? bst_req_valid : leg_req_valid;
	assign req_write = m_burst ? bst_req_write : leg_req_write;
	assign req_line = m_burst ? bst_req_line : leg_req_line;
	assign req_be = m_burst ? bst_req_be : leg_req_be;
	assign req_wdata = m_burst ? bst_req_wdata : leg_req_wdata;
	assign req_tag = m_burst ? bst_req_tag : leg_req_tag;

	assign busy = state != S_IDLE;
	assign fsm = state;

	/* The segment's end: the next pixel, or the next row. */
	wire [16:0] sn17 = {{(16 - US){1'b0}}, sn};
	wire seg_last = cur_rem == sn17;
	wire [ADDR_W-1:0] tile_step = tile_bytes(psl, 1'b0);
	wire [ADDR_W-1:0] tile_back = tile_bytes(psl, 1'b1);
	wire [ADDR_W-1:0] dst_back, src_back;
	wire [31:0] dst_neg, src_neg;
	wire [16:0] y1_last, ys_rev;
	wire [5:0] step_co_unused;

	am_sub #(.W(ADDR_W)) s_dback (.a(dstride_u), .b(tile_back), .bi(1'b0), .d(dst_back), .bo(step_co_unused[0]));
	am_sub #(.W(ADDR_W)) s_sback (.a(sstride_u), .b(tile_back), .bi(1'b0), .d(src_back), .bo(step_co_unused[1]));
	am_sub #(.W(32)) s_dneg (.a(32'd0), .b(dstride_u), .bi(1'b0), .d(dst_neg), .bo(step_co_unused[2]));
	am_sub #(.W(32)) s_sneg (.a(32'd0), .b(sstride_u), .bi(1'b0), .d(src_neg), .bo(step_co_unused[3]));
	wire [ADDR_W-1:0] dst_step = m_dtile ? (ydl == 2'd3 ? dst_back : tile_step) :
		dstride_u;
	wire [ADDR_W-1:0] src_step = m_stile ? (ysl == 2'd3 ? src_back : tile_step) :
		sstride_u;

	/* S_START: the first row (the last one when reversed). */
	am_sub #(.W(17)) s_y1 (.a(y1), .b(17'd0), .bi(1'b1), .d(y1_last), .bo(step_co_unused[4]));
	am_add #(.W(17)) a_ys (.a(sy0), .b(rows), .ci(1'b0), .s(ys_rev), .co(step_co_unused[5]));
	wire [16:0] yd_start = m_rev ? y1_last : y0;
	wire [16:0] ys_start = m_rev ? ys_rev : sy0;
	wire row_go = state == S_START;
	wire row_add = state == S_WR && wr_go && seg_last;

	wire [ADDR_W-1:0] dst_row, src_row;
	wire d_idle, s_idle;

	/* The first row's address within its tile row: (y mod 4) x 4 pixels, in bytes. */
	wire [ADDR_W-1:0] d_in_tile, s_in_tile;
	wire [31:0] d_first, s_first;
	wire [1:0] first_co_unused;

	am_shift #(.W(ADDR_W), .SW(3)) h_dt (.a(m_dtile ? {{(ADDR_W - 4){1'b0}}, yd_start[1:0], 2'b00} : {ADDR_W{1'b0}}),
		.amt(psl), .left(1'b1), .arith(1'b0), .y(d_in_tile));
	am_shift #(.W(ADDR_W), .SW(3)) h_st (.a(m_stile ? {{(ADDR_W - 4){1'b0}}, ys_start[1:0], 2'b00} : {ADDR_W{1'b0}}),
		.amt(psl), .left(1'b1), .arith(1'b0), .y(s_in_tile));
	am_add #(.W(32)) a_df (.a(dbase_u), .b(d_in_tile), .ci(1'b0), .s(d_first), .co(first_co_unused[0]));
	am_add #(.W(32)) a_sf (.a(sbase_u), .b(s_in_tile), .ci(1'b0), .s(s_first), .co(first_co_unused[1]));

	atg_blt_acc dacc (
		.clk(clk), .rst_n(rst_n), .go(row_go),
		.y(m_dtile ? {2'b00, yd_start[16:2]} : yd_start), .s(dstride_u),
		.b(d_first),
		.add(row_add), .d(m_rev ? dst_neg : dst_step), .r(dst_row), .idle(d_idle)
	);
	atg_blt_acc sacc (
		.clk(clk), .rst_n(rst_n), .go(row_go),
		.y(m_stile ? {2'b00, ys_start[16:2]} : ys_start), .s(sstride_u),
		.b(s_first),
		.add(row_add), .d(m_rev ? src_neg : src_step), .r(src_row), .idle(s_idle)
	);

	/*
	 * The FSM's sums, each for the state that takes it: the rectangle's
	 * size and source origin (S_CLIP), the rows' first pixels (S_START),
	 * the pixel's addresses (S_SA), the segment's bytes (S_SB), its first
	 * bytes (S_SC), and the next pixel, row and the pixels left (S_WR).
	 */
	wire [16:0] c_width, c_rows, c_dx, c_dy, c_sx0, c_sy0, x1_last, s_end, s_last;
	wire [ADDR_W-1:0] d_px, s_px, d_xb, s_xb, d_addr, s_addr, d_lo, s_lo;
	wire [US:0] seg_bytes;
	wire [1:0] ydl_inc, ysl_inc;
	wire [16:0] rows_dec, px_next, spx_next, rem_next;
	wire [23:0] fsm_co_unused;

	am_sub #(.W(17)) s_w (.a(x1), .b(x0), .bi(1'b0), .d(c_width), .bo(fsm_co_unused[0]));
	am_sub #(.W(17)) s_rows (.a(y1), .b(y0), .bi(1'b1), .d(c_rows), .bo(fsm_co_unused[1]));
	am_sub #(.W(17)) s_cdx (.a(x0), .b(dx), .bi(1'b0), .d(c_dx), .bo(fsm_co_unused[2]));
	am_sub #(.W(17)) s_cdy (.a(y0), .b(dy), .bi(1'b0), .d(c_dy), .bo(fsm_co_unused[3]));
	am_add #(.W(17)) a_sx0 (.a({1'b0, s_src_xy[15:0]}), .b(c_dx), .ci(1'b0), .s(c_sx0), .co(fsm_co_unused[4]));
	am_add #(.W(17)) a_sy0 (.a({1'b0, s_src_xy[31:16]}), .b(c_dy), .ci(1'b0), .s(c_sy0), .co(fsm_co_unused[5]));
	am_sub #(.W(17)) s_x1 (.a(x1), .b(17'd0), .bi(1'b1), .d(x1_last), .bo(fsm_co_unused[6]));
	am_add #(.W(17)) a_send (.a(sx0), .b(width), .ci(1'b0), .s(s_end), .co(fsm_co_unused[7]));
	am_sub #(.W(17)) s_slast (.a(s_end), .b(17'd0), .bi(1'b1), .d(s_last), .bo(fsm_co_unused[8]));
	assign d_px = x_pixels(cur_px, m_dtile);
	assign s_px = x_pixels(cur_spx, m_stile);
	am_shift #(.W(ADDR_W), .SW(3)) h_dx (.a(d_px), .amt(psl), .left(1'b1), .arith(1'b0), .y(d_xb));
	am_shift #(.W(ADDR_W), .SW(3)) h_sx (.a(s_px), .amt(psl), .left(1'b1), .arith(1'b0), .y(s_xb));
	am_add #(.W(ADDR_W)) a_da (.a(cur_dst_row), .b(d_xb), .ci(1'b0), .s(d_addr), .co(fsm_co_unused[9]));
	am_add #(.W(ADDR_W)) a_sa (.a(cur_src_row), .b(s_xb), .ci(1'b0), .s(s_addr), .co(fsm_co_unused[10]));

	am_shift #(.W(US + 1), .SW(3)) h_sn (.a(seg_n), .amt(psl), .left(1'b1), .arith(1'b0), .y(seg_bytes));
	am_sub #(.W(ADDR_W)) s_dlo (.a(da), .b(back), .bi(1'b0), .d(d_lo), .bo(fsm_co_unused[11]));
	am_sub #(.W(ADDR_W)) s_slo (.a(sa), .b(back), .bi(1'b0), .d(s_lo), .bo(fsm_co_unused[12]));
	am_add #(.W(2)) a_ydl (.a(ydl), .b(2'd0), .ci(1'b1), .s(ydl_inc), .co(fsm_co_unused[13]));
	am_add #(.W(2)) a_ysl (.a(ysl), .b(2'd0), .ci(1'b1), .s(ysl_inc), .co(fsm_co_unused[14]));
	am_sub #(.W(17)) s_rdec (.a(rows), .b(17'd0), .bi(1'b1), .d(rows_dec), .bo(fsm_co_unused[15]));
	am_addsub #(.W(17)) as_px (.a(cur_px), .b(sn17), .sub(m_rev), .s(px_next), .co(fsm_co_unused[16]));
	am_addsub #(.W(17)) as_spx (.a(cur_spx), .b(sn17), .sub(m_rev), .s(spx_next), .co(fsm_co_unused[17]));
	am_sub #(.W(17)) s_rem (.a(cur_rem), .b(sn17), .bi(1'b0), .d(rem_next), .bo(fsm_co_unused[18]));

	/*
	 * Burst Engine Arithmetic Instances (Guardrails Compliant)
	 */
	wire [16:0] rows_b_dec;
	wire [3:0] bw_seg_cnt_next;
	wire [3:0] br_seg_cnt_next;
	wire [3:0] bw_slot_p1, bw_slot_p2;
	wire [1:0] ydl_b_inc, ysl_b_inc;
	wire [ADDR_W-1:0] dst_row_b_next, src_row_b_next;
	wire [4:0] brdp0_up, brdp0_next, brdp1_up, brdp1_next;
	wire [4:0] bwr_up, bwr_next;
	wire [14:0] bst_co_unused;

	am_sub #(.W(17)) s_rowsb (.a(rows_b), .b(17'd0), .bi(1'b1), .d(rows_b_dec), .bo(bst_co_unused[0]));
	am_add #(.W(4)) a_bwseg (.a({1'b0, bw_seg_idx}), .b(4'd0), .ci(1'b1), .s(bw_seg_cnt_next), .co(bst_co_unused[1]));
	am_add #(.W(4)) a_bwsp1 (.a(bw_slot_cnt), .b(4'd0), .ci(1'b1), .s(bw_slot_p1), .co(bst_co_unused[2]));
	am_add #(.W(4)) a_bwsp2 (.a(bw_slot_cnt), .b(4'd1), .ci(1'b1), .s(bw_slot_p2), .co(bst_co_unused[3]));
	am_add #(.W(4)) a_brseg (.a({1'b0, br_seg_idx}), .b(4'd0), .ci(1'b1), .s(br_seg_cnt_next), .co(bst_co_unused[4]));
	am_add #(.W(2)) a_ydlb (.a(ydl_b), .b(2'd0), .ci(1'b1), .s(ydl_b_inc), .co(bst_co_unused[5]));
	am_add #(.W(2)) a_yslb (.a(ysl_b), .b(2'd0), .ci(1'b1), .s(ysl_b_inc), .co(bst_co_unused[6]));
	wire [ADDR_W-1:0] b_dst_step = m_dtile ? (ydl_b == 2'd3 ? dst_back : tile_step) : dstride_u;
	wire [ADDR_W-1:0] b_src_step = m_stile ? (ysl_b == 2'd3 ? src_back : tile_step) : sstride_u;
	am_add #(.W(ADDR_W)) a_drb (.a(dst_row_b), .b(m_rev ? dst_neg : b_dst_step), .ci(1'b0), .s(dst_row_b_next), .co(bst_co_unused[7]));
	am_add #(.W(ADDR_W)) a_srb (.a(src_row_b), .b(m_rev ? src_neg : b_src_step), .ci(1'b0), .s(src_row_b_next), .co(bst_co_unused[8]));

	wire rsp_rd_bst = rsp_valid && !rsp_write && m_burst && (rsp_tag[7] == 1'b0);
	am_add #(.W(5)) a_brdp0 (.a(bank_rd_pending_0), .b(5'd0), .ci(bst_rd_fire && (bw_bank == 1'b0)), .s(brdp0_up), .co(bst_co_unused[9]));
	am_sub #(.W(5)) s_brdp0 (.a(brdp0_up), .b(5'd0), .bi(rsp_rd_bst && (rsp_tag[4] == 1'b0)), .d(brdp0_next), .bo(bst_co_unused[10]));
	am_add #(.W(5)) a_brdp1 (.a(bank_rd_pending_1), .b(5'd0), .ci(bst_rd_fire && (bw_bank == 1'b1)), .s(brdp1_up), .co(bst_co_unused[11]));
	am_sub #(.W(5)) s_brdp1 (.a(brdp1_up), .b(5'd0), .bi(rsp_rd_bst && (rsp_tag[4] == 1'b1)), .d(brdp1_next), .bo(bst_co_unused[12]));

	wire rsp_wr_bst = rsp_valid && rsp_write && m_burst;
	am_add #(.W(5)) a_bwr (.a(burst_wr_out), .b(5'd0), .ci(bst_wr_fire), .s(bwr_up), .co(bst_co_unused[13]));
	am_sub #(.W(5)) s_bwr (.a(bwr_up), .b(5'd0), .bi(rsp_wr_bst), .d(bwr_next), .bo(bst_co_unused[14]));

	/* Mode determination at kick */
	wire is_smear = (sbase_u == dbase_u) && !o_rev && ({1'b0, s_src_xy[15:0]} < clip_x0);
	wire op_burst = !o_blend && !is_smear;

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			done <= 1'b0;
			error <= 1'b0;
			error_kind <= 4'd0;
			m_copy <= 1'b0;
			m_blend <= 1'b0;
			m_rev <= 1'b0;
			m_dtile <= 1'b0;
			m_stile <= 1'b0;
			psl <= 3'd2;
			psl_w <= 3'd2;
			m_keep <= 4'd0;
			m_burst <= 1'b0;
			rd_first <= 1'b0;
			rd_second <= 1'b0;
			bl_go <= 1'b0;
			bw_bank <= 1'b0;
			bw_seg_idx <= 3'd0;
			bw_slot_cnt <= 4'd0;
			bw_sub <= 1'b0;
			bw_done_all <= 1'b0;
			bw_walk_done <= 1'b0;
			g_valid <= 1'b0;
			p_valid <= 1'b0;
			br_bank <= 1'b0;
			br_seg_idx <= 3'd0;
			br_active <= 1'b0;
			b_draining <= 1'b0;
			bank_active <= 2'b00;
			bank_closed <= 2'b00;
			bank_ready <= 2'b00;
			bank_rd_pending_0 <= 5'd0;
			bank_rd_pending_1 <= 5'd0;
			bank_num_segs_0 <= 4'd0;
			bank_num_segs_1 <= 4'd0;
			meta_n0slot_0 <= 8'd0;
			meta_n0slot_1 <= 8'd0;
			rows_b_zero <= 1'b0;
			burst_wr_out <= 5'd0;
			px_b <= 17'd0;
			spx_b <= 17'd0;
			rem_b <= 17'd0;
			rows_b <= 17'd0;
			cur_da_b <= {US{1'b0}};
			cur_da_row <= {US{1'b0}};
			line_pixels_b <= {1'b1, {US{1'b0}}};
			ydl_b <= 2'd0;
			ysl_b <= 2'd0;
			dst_row_b <= {ADDR_W{1'b0}};
			src_row_b <= {ADDR_W{1'b0}};
		end else begin
			done <= 1'b0;
			error <= 1'b0;
			bl_go <= 1'b0;

			/* Track pending read responses in ping-pong RAM */
			if (state == S_BURST) begin
				bank_rd_pending_0 <= brdp0_next;
				bank_rd_pending_1 <= brdp1_next;
				burst_wr_out <= bwr_next;
			end else begin
				bank_rd_pending_0 <= 5'd0;
				bank_rd_pending_1 <= 5'd0;
				burst_wr_out <= 5'd0;
			end

			/* Write into ping-pong RAM from AMB read response */
			if (m_burst && rsp_rd_bst) begin
				pp_ram[rsp_tag[4:0]] <= rsp_rdata;
			end

			case (state)
			S_IDLE:
				if (kick) begin
					m_copy <= o_op != GHCI_BLT_FILL;
					m_blend <= o_blend;
					m_rev <= o_rev;
					m_dtile <= o_op == GHCI_BLT_TILE;
					m_stile <= o_op == GHCI_BLT_UNTILE;
					psl <= o_psl;
					m_keep <= o_keep;
					m_burst <= op_burst && op_ok;
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
					state <= S_START;
					width <= c_width;
					rows <= c_rows;
					sx0 <= c_sx0;
					sy0 <= c_sy0;
				end
			S_START: begin
				state <= S_MUL;
				px_row <= m_rev ? x1_last : x0;
				spx_row <= m_rev ? s_last : sx0;
				ydl <= yd_start[1:0];
				ysl <= ys_start[1:0];
			end
			S_MUL:
				if (d_idle && s_idle) begin
					if (m_burst) begin
						state <= S_BURST;
						px_b <= px_row;
						spx_b <= spx_row;
						rem_b <= width;
						rows_b <= rows;
						rows_b_zero <= (rows == 17'd0);
						cur_da_b <= cur_da_init;
						cur_da_row <= cur_da_init;
						ydl_b <= yd_start[1:0];
						ysl_b <= ys_start[1:0];
						dst_row_b <= dst_row;
						src_row_b <= src_row;
						psl_w <= psl;
						line_pixels_b <= calc_line_pixels;
						bw_bank <= 1'b0;
						bw_seg_idx <= 3'd0;
						bw_slot_cnt <= 4'd0;
						bw_sub <= 1'b0;
						bw_done_all <= 1'b0;
						bw_walk_done <= 1'b0;
						g_valid <= 1'b0;
						p_valid <= 1'b0;
						br_bank <= 1'b0;
						br_seg_idx <= 3'd0;
						br_active <= 1'b0;
						b_draining <= 1'b0;
						bank_active <= 2'b00;
						bank_closed <= 2'b00;
						bank_ready <= 2'b00;
					end else begin
						state <= S_SA;
						px <= px_row;
						spx <= spx_row;
						rem <= width;
					end
				end

			/*
			 * =================================================================
			 * S_BURST: Streaming Burst DMA Engine (Phase 030)
			 * =================================================================
			 */
			S_BURST: begin
				if (fail) begin
					state <= S_DRAIN;
				end else begin
					/*
					 * 1. Bank Read Ready detection:
					 * Once bank is closed, when all read responses arrived (or FILL), mark READY.
					 */
					if (bank_closed[0] && !bank_ready[0] && (!m_copy || brdp0_next == 5'd0))
						bank_ready[0] <= 1'b1;
					if (bank_closed[1] && !bank_ready[1] && (!m_copy || brdp1_next == 5'd0))
						bank_ready[1] <= 1'b1;

					/*
					 * 2. Walk & Geom & Issue Pipelines (Concurrent 3-stage pipeline)
					 */
					/* Stage 1 (Walk Stage): advance walk coordinates and latch into g_* */
					if (walk_step) begin
						g_valid <= 1'b1;
						g_dst_row <= dst_row_b;
						g_src_row <= src_row_b;
						g_px <= px_b;
						g_spx <= spx_b;
						g_seg_n <= bst_seg_n;
						g_seg_last <= bst_seg_last;
						g_rows_b_zero <= rows_b_zero;

						/* Advance walk coordinates */
						px_b <= px_b_next;
						spx_b <= spx_b_next;
						rem_b <= rem_b_next;
						cur_da_b <= cur_da_b_next;
						if (bst_seg_last) begin
							rows_b <= rows_b_dec;
							rows_b_zero <= (rows_b_dec == 17'd0);
							ydl_b <= ydl_b_inc;
							ysl_b <= ysl_b_inc;
							dst_row_b <= dst_row_b_next;
							src_row_b <= src_row_b_next;
							cur_da_row <= cur_da_row_next;
							if (rows_b_zero)
								bw_walk_done <= 1'b1;
						end
					end else if (step_g) begin
						g_valid <= 1'b0;
					end

					/* Stage 2 (Geom / Address Stage): compute addresses into p_* */
					if (step_p) begin
						if (g_valid) begin
							p_valid <= 1'b1;
							p_dline <= g_seg_line;
							p_seg_n <= g_seg_n;
							p_dlo_lo <= g_dlo_lo;
							p_off <= g_src_off;
							p_src_n0 <= g_src_n0;
							p_src_n1 <= g_src_n1;
							p_two_lines <= g_two_lines;
							p_n0_slot <= g_n0_slot;
							p_seg_last <= g_seg_last;
							p_rows_b_zero <= g_rows_b_zero;
						end else begin
							p_valid <= 1'b0;
						end
					end

					/* Issue & Prefetch Stage: record metadata and issue AMB requests */
					if (bst_can_fill_p) begin
						bank_active[bw_bank] <= 1'b1;

						/* Check if current segment transfer step is complete */
						if (issue_fire) begin
							/* Segment complete: save metadata */
							if (!bw_bank) begin
								meta_dline_0[bw_seg_idx] <= p_dline;
								meta_be_0[bw_seg_idx] <= issue_be;
								meta_off_0[bw_seg_idx] <= p_off;
								meta_slot0_0[bw_seg_idx] <= bw_slot_cnt;
								meta_slot1_0[bw_seg_idx] <= p_two_lines ? bw_slot_p1 : bw_slot_cnt;
								meta_n0slot_0[bw_seg_idx] <= p_n0_slot;
							end else begin
								meta_dline_1[bw_seg_idx] <= p_dline;
								meta_be_1[bw_seg_idx] <= issue_be;
								meta_off_1[bw_seg_idx] <= p_off;
								meta_slot0_1[bw_seg_idx] <= bw_slot_cnt;
								meta_slot1_1[bw_seg_idx] <= p_two_lines ? bw_slot_p1 : bw_slot_cnt;
								meta_n0slot_1[bw_seg_idx] <= p_n0_slot;
							end
							bw_sub <= 1'b0;

							/* Advance bank segment and slot count */
							bw_seg_idx <= bw_seg_cnt_next[2:0];
							bw_slot_cnt <= p_two_lines ? bw_slot_p2 : bw_slot_p1;

							/* Check bank close condition */
							if ((p_seg_last && p_rows_b_zero) ||
							    (bw_seg_idx == MAX_SEGS_M1) ||
							    bw_slot_full_p) begin
								bank_closed[bw_bank] <= 1'b1;
								if (!bw_bank)
									bank_num_segs_0 <= bw_seg_cnt_next;
								else
									bank_num_segs_1 <= bw_seg_cnt_next;
								bank_is_last[bw_bank] <= (p_seg_last && p_rows_b_zero);
								bw_bank <= ~bw_bank;
								bw_seg_idx <= 3'd0;
								bw_slot_cnt <= 4'd0;
								if (p_seg_last && p_rows_b_zero)
									bw_done_all <= 1'b1;
							end
						end else if (m_copy && p_two_lines && !bw_sub && bst_rd_fire) begin
							/* First of two read beats fired */
							bw_sub <= 1'b1;
						end
					end

					/*
					 * 3. Commit & Write Channel
					 */
					if (!br_active) begin
						if (bank_ready[br_bank]) begin
							br_active <= 1'b1;
							br_seg_idx <= 3'd0;
						end
					end else begin
						if (bst_wr_fire) begin
							if (br_seg_cnt_next == (br_bank ? bank_num_segs_1 : bank_num_segs_0)) begin
								/* Bank write complete: release bank */
								bank_active[br_bank] <= 1'b0;
								bank_closed[br_bank] <= 1'b0;
								bank_ready[br_bank] <= 1'b0;
								br_bank <= ~br_bank;
								br_seg_idx <= 3'd0;
								if (bank_is_last[br_bank]) begin
									br_active <= 1'b0;
									b_draining <= 1'b1;
								end else begin
									/* Switch directly to next bank if already ready */
									br_active <= bank_ready[~br_bank];
								end
							end else begin
								br_seg_idx <= br_seg_cnt_next[2:0];
							end
						end
					end

					/*
					 * 4. Drain & Done Completion
					 */
					if (b_draining && bwr_next == 5'd0 && !rsp_valid) begin
						state <= S_IDLE;
						done <= 1'b1;
					end
				end
			end

			/*
			 * =================================================================
			 * Legacy Sequential Path (Blend & RAW Smear Compatibility)
			 * =================================================================
			 */
			S_SA:
				if (fail) begin
					state <= S_DRAIN;
				end else begin
					state <= S_SB;
					da <= d_addr;
					sa <= s_addr;
				end
			S_SB: begin
				state <= S_SC;
				sn <= seg_n;
				snu <= seg_bytes;
			end
			S_SC: begin
				state <= S_SD;
				dlo <= m_rev ? d_lo : da;
				slo <= m_rev ? s_lo : sa;
			end
			S_SD: begin
				seg_line <= dlo[ADDR_W-1:US];
				seg_p0 <= dlo[US-1:0];
				src_off <= src_base_u[US-1:0];
				src_n0 <= slo[ADDR_W-1:US];
				src_n1 <= last_line;
				n0_slot <= slo[ADDR_W-1:US] != src_lo;
				rd_first <= 1'b1;
				state <= m_copy ? S_CRD : m_blend ? S_DRD : S_WR;
			end
			S_CRD:
				if (fail) begin
					state <= S_DRAIN;
				end else if (q_free && wr_idle) begin
					if (rd_first) begin
						rd_first <= 1'b0;
						rd_second <= src_n1 != src_n0;
					end else if (rd_second) begin
						rd_second <= 1'b0;
					end else begin
						state <= S_CWAIT;
					end
				end
			S_CWAIT:
				if (fail)
					state <= S_DRAIN;
				else if (q_free && rd_idle)
					state <= m_blend ? S_DRD : S_WR;
			S_DRD:
				if (fail)
					state <= S_DRAIN;
				else if (drd_go)
					state <= S_DWAIT;
			S_DWAIT:
				if (fail) begin
					state <= S_DRAIN;
				end else if (q_free && rd_idle) begin
					state <= S_BLEND;
					bl_go <= 1'b1;
				end
			S_BLEND:
				if (bl_done)
					state <= S_WR;
			S_WR:
				if (fail) begin
					state <= S_DRAIN;
				end else if (wr_go) begin
					if (seg_last) begin
						ydl <= ydl_inc;
						ysl <= ysl_inc;
						px <= px_row;
						spx <= spx_row;
						rem <= width;
						rows <= rows_dec;
						state <= rows == 17'd0 ? S_DRAIN : S_SA;
					end else begin
						px <= px_next;
						spx <= spx_next;
						rem <= rem_next;
						state <= S_SA;
					end
				end
			S_DRAIN:
				if (q_free && wr_idle && rd_idle && !rsp_valid) begin
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

	wire unused_ok = &{1'b0, shifted[2*LINE_BITS-1:LINE_BITS], pp_shifted[2*LINE_BITS-1:LINE_BITS],
		c_op2, c_resolve, step_co_unused, first_co_unused, fsm_co_unused, bst_co_unused,
		src_slice_u, dst_slice_u, depth_u};
endmodule

`default_nettype wire
