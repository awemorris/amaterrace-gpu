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
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter ENABLE_SCALE = 1,
	parameter ENABLE_BLEND = 1,
	parameter ENABLE_TILE = 1
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
`ifdef SYNTH_KINTEX7
	wire rst_b2d_high = !rst_n;
`else
	wire rst_b2d_high = !rst_n;
`endif
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

	atg_blt_cfg #(
		.LINE_BYTES(LINE_BYTES),
		.ENABLE_BLEND(ENABLE_BLEND),
		.ENABLE_TILE(ENABLE_TILE)
	) cfg (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.op(o_op), .op2(c_op2), .resolve(c_resolve), .blend(o_blend), .rev(o_rev), .psl(o_psl), .keep(o_keep), .op_ok(op_ok),
		.x0(clip_x0), .y0(clip_y0), .x1(clip_x1), .y1(clip_y1), .dx(dx), .dy(dy),
		.src_xy(s_src_xy), .dbase(dbase_u), .sbase(sbase_u), .dstride(dstride_u),
		.sstride(sstride_u), .src_slice(src_slice_u), .dst_slice(dst_slice_u), .depth(depth_u), .fill_line(fill_line)
	);

	/* The mode of the blit in progress, taken at the kick. */
`ifdef SYNTH_KINTEX7
	reg m_copy;		/* reads a source: COPY, TILE, UNTILE */
	reg m_blend;
	reg m_rev;
	reg m_dtile, m_stile;	/* the destination (TILE), the source (UNTILE) is tiled */
	reg [2:0] psl;		/* log2 of the pixel's bytes */
	reg [3:0] m_keep;
	reg m_burst;
`else
	reg m_copy;		/* reads a source: COPY, TILE, UNTILE */
	reg m_blend;
	reg m_rev;
	reg m_dtile, m_stile;	/* the destination (TILE), the source (UNTILE) is tiled */
	reg [2:0] psl;		/* log2 of the pixel's bytes */
	reg [3:0] m_keep;
	reg m_burst;
`endif

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

	localparam [4:0] S_IDLE  = 5'd0;
	localparam [4:0] S_CLIP  = 5'd1;	/* size and source origin */
	localparam [4:0] S_START = 5'd2;	/* the first row and pixel */
	localparam [4:0] S_MUL   = 5'd3;	/* row addresses: y * stride */
	localparam [4:0] S_SA    = 5'd4;	/* segment: the pixel's addresses */
	localparam [4:0] S_SB    = 5'd5;	/* segment: compute room */
	localparam [4:0] S_SB1   = 5'd6;	/* segment: compute sn from rem and room */
	localparam [4:0] S_SC    = 5'd7;	/* segment: its first byte */
	localparam [4:0] S_SD    = 5'd8;	/* segment: lines and shift */
	localparam [4:0] S_CRD   = 5'd9;	/* read the source lines */
	localparam [4:0] S_CWAIT = 5'd10;	/* wait for them */
	localparam [4:0] S_DRD   = 5'd11;	/* blend: read the destination line */
	localparam [4:0] S_DWAIT = 5'd12;	/* wait for it */
	localparam [4:0] S_BLEND = 5'd13;	/* blend the line */
	localparam [4:0] S_WR    = 5'd14;	/* queue the segment's write */
	localparam [4:0] S_DRAIN = 5'd15;	/* wait for every response */
	localparam [4:0] S_BURST = 5'd16;	/* decoupled streaming burst DMA */
	localparam [4:0] S_INIT  = 5'd17;	/* burst setup pipeline */
	localparam [4:0] S_START1 = 5'd18;	/* accumulator trigger */
	localparam [4:0] S_INIT1  = 5'd19;	/* burst setup pipeline stage 1 */

`ifdef SYNTH_KINTEX7
	reg [4:0] state;
	reg r_busy_q;
	reg is_burst;
	wire state_b4_0, state_b4_1;
	assign state_b4_0 = state[4];
	assign state_b4_1 = state[4];
`else
	reg [4:0] state;
	reg r_busy_q;
	reg is_burst;
	wire state_b4_0 = state[4];
	wire state_b4_1 = state[4];
`endif

	/* The rectangle. */
`ifdef SYNTH_KINTEX7
	reg [16:0] x0, y0, x1, y1;
`else
	reg [16:0] x0, y0, x1, y1;
`endif
	wire empty;
	reg [16:0] width;
	reg [16:0] rows;	/* rows: left after this one */
	reg [16:0] width_m1;
	reg r_mr_px, r_mr_spx;
	reg [16:0] sx0, sy0;	/* the source pixel of x0, y0 */
	reg [16:0] px_row, spx_row;	/* the first pixel of every row */

	/* Row walking: the row's y modulo 4 (tiles); the rows' byte addresses
	 * (base + y stride, then + the step a row) in atg_blt_acc. */
	reg [1:0] ydl, ysl;
	reg [16:0] px, spx;	/* the next pixel (rightmost reversed), its source pixel */
	reg [16:0] rem;		/* pixels left in the row */
	reg rows_is_zero;

	/* The segment. */
	reg [ADDR_W-1:0] da, sa;	/* byte addresses of px, spx */
	reg [US:0] sn, snu;	/* pixels, bytes */
	reg [US:0] r_leg_room;
`ifdef SYNTH_KINTEX7
	reg [ADDR_W-1:0] dlo, slo;	/* first destination and source bytes */
`else
	reg [ADDR_W-1:0] dlo, slo;	/* first destination and source bytes */
`endif
	reg [LA_W-1:0] seg_line;
	reg [US-1:0] seg_p0;
	reg [US-1:0] src_off;
	reg [LA_W-1:0] src_n0, src_n1;
	reg n0_slot;
`ifdef SYNTH_KINTEX7
	reg rd_first;
	reg rd_second;	/* the first, a needed second source read is to go */
`else
	reg rd_first, rd_second;	/* the first, a needed second source read is to go */
`endif

	/*
	 * =========================================================================
	 * Burst Engine Signals & Registers
	 * =========================================================================
	 */
`ifndef SYNTH_KINTEX7
	/* 1 KiB RAM (32 slots) */
	reg [LINE_BITS-1:0] pp_ram [0:31];
`endif

	/* Bank Metadata (2 Banks, up to 8 segments each, full D-FF registers) */
	(* ram_style = "registers" *) reg [6:0] meta_dline_0_0 [0:7];
	(* ram_style = "registers" *) reg [6:0] meta_dline_0_1 [0:7];
	(* ram_style = "registers" *) reg [6:0] meta_dline_0_2 [0:7];
	(* ram_style = "registers" *) reg [LA_W-22:0] meta_dline_0_3 [0:7];
	(* ram_style = "registers" *) reg [6:0] meta_dline_1_0 [0:7];
	(* ram_style = "registers" *) reg [6:0] meta_dline_1_1 [0:7];
	(* ram_style = "registers" *) reg [6:0] meta_dline_1_2 [0:7];
	(* ram_style = "registers" *) reg [LA_W-22:0] meta_dline_1_3 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_0_0 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_0_1 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_0_2 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_0_3 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_0_4 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_0_5 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_0_6 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_0_7 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_1_0 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_1_1 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_1_2 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_1_3 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_1_4 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_1_5 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_1_6 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_be_1_7 [0:7];
	(* ram_style = "registers" *) reg [US-1:0] meta_off_0 [0:7];
	(* ram_style = "registers" *) reg [US-1:0] meta_off_1 [0:7];
	(* ram_style = "registers" *) reg [3:0] meta_slot0_0 [0:7];
	(* ram_style = "registers" *) reg [3:0] meta_slot0_1 [0:7];
	(* ram_style = "registers" *) reg [3:0] meta_slot1_0 [0:7];
	(* ram_style = "registers" *) reg [3:0] meta_slot1_1 [0:7];
	(* ram_style = "registers" *) reg [7:0] meta_n0slot_0;
	(* ram_style = "registers" *) reg [7:0] meta_n0slot_1;
	reg [7:0] bw_seg_onehot;
	reg [3:0] bank_num_segs_0, bank_num_segs_1;
	reg [1:0] bank_is_last;
	reg [1:0] bank_active;
	reg [1:0] bank_closed;
	reg [1:0] bank_ready;
	reg [4:0] bank_rd_pending_0, bank_rd_pending_1;
	reg rows_b_zero;

	/* Burst Walk & Prefetch registers */
`ifdef SYNTH_KINTEX7
	reg bw_bank;
`else
	reg bw_bank;
`endif
	reg [2:0] bw_seg_idx;
	reg [3:0] bw_slot_cnt;
	reg bw_sub;
	reg bw_done_all;
	reg bw_walk_done;
	reg [16:0] px_b, spx_b, rem_b;
	reg [16:0] rows_b;
	reg [US:0] rem_line_b;
	reg [US:0] rem_line_row;
	reg [US:0] r_rem_line_init;
	reg [US-1:0] cur_da_row;
	reg [1:0] ydl_b, ysl_b;
	reg ydl_b_is_3_lo, ydl_b_is_3_hi, ysl_b_is_3;
	reg [ADDR_W-1:0] dst_row_b, src_row_b;
	reg [ADDR_W-1:0] r_dst_back, r_src_back;
	reg [ADDR_W-1:0] r_dst_neg, r_src_neg;
	reg [ADDR_W-1:0] r_tile_step;
	reg [31:0] r_dstride, r_sstride, r_dbase, r_sbase;
	reg r_seg_last;
	reg [31:0] r_d_first, r_s_first;
	reg [16:0] r_yd_start, r_ys_start;
	reg [ADDR_W-1:0] r_dst_delta_norm, r_dst_delta_back;
	reg [ADDR_W-1:0] r_src_delta_norm, r_src_delta_back;
`ifdef SYNTH_KINTEX7
	reg [2:0] psl_w;
	reg [US:0] line_pixels_b;
	reg rem_b_small;
	reg [US:0] cur_bst_room;
	wire [US-1:0] cur_b_dst_delta_lo = ydl_b_is_3_lo ? r_dst_delta_back[US-1:0] : r_dst_delta_norm[US-1:0];

	/* Burst segment pipeline registers: 3-stage pipeline */
	/* Stage 1 -> Stage 2: Geom pipeline registers */
	reg g_valid;
	reg [ADDR_W-1:0] g_da_full, g_sa_full;
	reg [US:0] g_seg_n;
	reg [US:0] g_seg_bytes;
	reg [US-1:0] g_back_lo;
	reg g_seg_last;
	reg g_rows_b_zero;
`else
	reg [2:0] psl_w;
	reg [US:0] line_pixels_b;
	reg rem_b_small;
	reg [US:0] cur_bst_room;
	wire [US-1:0] cur_b_dst_delta_lo = ydl_b_is_3_lo ? r_dst_delta_back[US-1:0] : r_dst_delta_norm[US-1:0];

	reg g_valid;
	reg [ADDR_W-1:0] g_da_full, g_sa_full;
	reg [US:0] g_seg_n;
	reg [US:0] g_seg_bytes;
	reg [US-1:0] g_back_lo;
	reg g_seg_last;
	reg g_rows_b_zero;
`endif

	/* Stage 2 -> Stage 3 (Issue pipeline registers via am_skid) */
	wire p_valid;
	wire [LA_W-1:0] p_dline;
	wire [US:0] p_seg_n;
	wire [US:0] p_seg_bytes;
	wire [US-1:0] p_dlo_lo;
	wire [US-1:0] p_off;
	wire [LA_W-1:0] p_src_n0;
	wire [LA_W-1:0] p_src_n1;
	wire p_two_lines;
	wire p_n0_slot;
	wire p_seg_last;
	wire p_rows_b_zero;

	/* Burst Write & Commit registers */
`ifdef SYNTH_KINTEX7
	reg br_bank;
	reg [2:0] br_seg_idx;
	reg br_active;
`else
	reg br_bank;
	reg [2:0] br_seg_idx;
	reg br_active;
`endif
	reg b_draining;
	reg [4:0] burst_wr_out;

	/* Mux inputs to address and segment logic */
	wire bw_slot_full_p = p_two_lines ? (bw_slot_cnt >= SLOT_LIMIT2) : (bw_slot_cnt >= SLOT_LIMIT1);
	wire bank_close_cond = (p_seg_last && p_rows_b_zero) || (bw_seg_idx == MAX_SEGS_M1) || bw_slot_full_p;
	wire bank_close_fire_0, bank_close_fire_1, bank_close_fire;
`ifdef SYNTH_KINTEX7
	wire [15:0] ib_buf;
	genvar g_ibi;
	generate
		for (g_ibi = 0; g_ibi < 16; g_ibi = g_ibi + 1) begin : g_ib_buf
			assign ib_buf[g_ibi] = is_burst;
		end
	endgenerate
	wire is_burst_port  = ib_buf[0];
	wire is_burst_fsm   = ib_buf[1];
	wire is_burst_walk  = ib_buf[2];
	wire is_burst_bank0 = ib_buf[3];
	wire is_burst_bank1 = ib_buf[4];
	wire is_burst_bk0   = ib_buf[5];
	wire is_burst_bk1   = ib_buf[6];
	wire is_burst_bk2   = ib_buf[7];
	wire is_burst_bk3   = ib_buf[8];
	wire is_burst_meta0 = ib_buf[9];
	wire is_burst_meta1 = ib_buf[10];
	wire is_burst_ctl0  = ib_buf[11];
	wire is_burst_ctl1  = ib_buf[12];
	wire is_burst_ctl2  = ib_buf[13];
	wire is_burst_ctl3  = ib_buf[14];
	wire is_burst_ctl4  = ib_buf[15];
`else
	wire is_burst_port  = is_burst;
	wire is_burst_fsm   = is_burst;
	wire is_burst_walk  = is_burst;
	wire is_burst_bank0 = is_burst;
	wire is_burst_bank1 = is_burst;
	wire is_burst_bk0   = is_burst;
	wire is_burst_bk1   = is_burst;
	wire is_burst_bk2   = is_burst;
	wire is_burst_bk3   = is_burst;
	wire is_burst_meta0 = is_burst;
	wire is_burst_meta1 = is_burst;
	wire is_burst_ctl0  = is_burst;
	wire is_burst_ctl1  = is_burst;
	wire is_burst_ctl2  = is_burst;
	wire is_burst_ctl3  = is_burst;
	wire is_burst_ctl4  = is_burst;
`endif

	/*
	 * =========================================================================
	 * Segment Geometry & Addresses: Common Combinational Datapath
	 * =========================================================================
	 */
	wire [ADDR_W-1:0] cur_da_full = d_addr;
	wire [ADDR_W-1:0] cur_sa_full = s_addr;

	/* The segment's geometry (atg_blt_seg, combinational). */
	wire [US:0] seg_n = leg_seg_n;
	wire [ADDR_W-1:0] back, src_base_u;
	reg [ADDR_W-1:0] r_leg_back;
	wire [LA_W-1:0] last_line;
	wire [LINE_BYTES-1:0] seg_be;


	/* verilator lint_off WIDTHTRUNC */
	localparam [US:0] LB_V = LINE_BYTES;
	/* verilator lint_on WIDTHTRUNC */

	wire mdt_px_row = m_dtile, mdt_px_b = m_dtile, mdt_px = m_dtile;
	wire mst_px_row = m_stile, mst_px_b = m_stile, mst_px = m_stile;
	wire mdt_bstep0 = m_dtile, mdt_bstep1 = m_dtile, mdt_step0 = m_dtile, mdt_step1 = m_dtile;
	wire mst_bstep0 = m_stile, mst_bstep1 = m_stile, mst_step0 = m_stile, mst_step1 = m_stile;
	wire mdt_ctl = m_dtile, mdt_h = m_dtile, mdt_acc = m_dtile;
	wire mst_ctl = m_stile, mst_h = m_stile, mst_acc = m_stile;

	wire [2:0] psl_dx = psl, psl_sx = psl, psl_ctl = psl, psl_leg = psl;
	wire [2:0] pslw_dxb0 = psl_w, pslw_dxb1 = psl_w;
	wire [2:0] pslw_sxb0 = psl_w, pslw_sxb1 = psl_w;
	wire [2:0] pslw_gbk0 = psl_w, pslw_ctl = psl_w;

	wire [US:0] calc_line_pixels = (psl_ctl == 3'd4) ? {4'b0000, LB_V[US:4]} :
	                               (psl_ctl == 3'd3) ? {3'b000, LB_V[US:3]}  :
	                               (psl_ctl == 3'd2) ? {2'b00, LB_V[US:2]}   :
	                               (psl_ctl == 3'd1) ? {1'b0, LB_V[US:1]}    : LB_V;

`ifdef SYNTH_KINTEX7
	reg [US:0] r_da_px_leg;
	wire [US:0] in_da_px_wire = r_da_px_leg;
	wire use_in_da_px_wire = 1'b1;
`else
	wire [US:0] in_da_px_wire = {(US+1){1'b0}};
	wire use_in_da_px_wire = 1'b0;
`endif

	/* Legacy FSM Segment Engine (completely isolated from burst) */
	wire [US:0] leg_room;
	wire [US:0] leg_seg_n;
	wire leg_seg_last;
	atg_blt_seg #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) seg (
		.psl(psl_leg), .line_pix(calc_line_pixels), .rev(m_rev), .dtile(mdt_ctl), .stile(mst_ctl), .keep(m_keep),
		.da(da[US-1:0]), .px(px[1:0]), .spx(spx[1:0]), .rem(rem),
		.in_room(r_leg_room), .use_in_room(state == S_SB1),
		.in_da_px(in_da_px_wire), .use_in_da_px(use_in_da_px_wire),
		.sn(sn), .snu(snu), .dlo(dlo[US-1:0]), .slo(slo),
		.p0(seg_p0), .seg_n(leg_seg_n), .seg_last(leg_seg_last), .room(leg_room), .back(back), .src_base(src_base_u),
		.last_line(last_line), .be(seg_be)
	);
	wire [LA_W-1:0] src_lo = src_base_u[ADDR_W-1:US];
	wire leg_rem_done = (!(|rem[16:US+1])) && (rem[US:0] <= r_leg_room);
	wire [US:0] leg_sn = leg_rem_done ? rem[US:0] : r_leg_room;
`ifdef SYNTH_KINTEX7
	/* Precompute rem_back_val in S_SA / S_SB so rem carry chain is completely isolated */
	wire [US:0] rem_bn;
	wire rem_bn_co;
	am_sub #(.W(US + 1)) s_rem_bn (.a(rem[US:0]), .b({(US + 1){1'b0}}), .bi(1'b1), .d(rem_bn), .bo(rem_bn_co));
	wire [ADDR_W-1:0] rem_back_val = (psl == 3'd4) ? {{(ADDR_W - US - 5){1'b0}}, rem_bn, 4'b0000} :
	                                 (psl == 3'd3) ? {{(ADDR_W - US - 4){1'b0}}, rem_bn, 3'b000}  :
	                                 (psl == 3'd2) ? {{(ADDR_W - US - 3){1'b0}}, rem_bn, 2'b00}   :
	                                 (psl == 3'd1) ? {{(ADDR_W - US - 2){1'b0}}, rem_bn, 1'b0}    :
	                                                 {{(ADDR_W - US - 1){1'b0}}, rem_bn};
	reg [ADDR_W-1:0] r_rem_back_val;
	reg r_rem_hi_zero;
	always @(posedge clk) begin
		if (state == S_SA || state == S_SB) begin
			r_rem_back_val <= rem_back_val;
			r_rem_hi_zero  <= !(|rem[16:US+1]);
		end
	end

	wire leg_cmp_lo    = (rem[2:0] <= r_leg_room[2:0]);
	wire leg_cmp_hi_lt = (rem[US:3] < r_leg_room[US:3]);
	wire leg_cmp_hi_eq = (rem[US:3] == r_leg_room[US:3]);
	wire leg_rem_done_lo, leg_rem_done_hi;
	LUT4 #(.INIT(16'hF800)) u_lrd_lo (
		.I0(leg_cmp_lo), .I1(leg_cmp_hi_eq), .I2(leg_cmp_hi_lt), .I3(r_rem_hi_zero),
		.O(leg_rem_done_lo)
	);
	LUT4 #(.INIT(16'hF800)) u_lrd_hi (
		.I0(leg_cmp_lo), .I1(leg_cmp_hi_eq), .I2(leg_cmp_hi_lt), .I3(r_rem_hi_zero),
		.O(leg_rem_done_hi)
	);

	wire [US:0] room_bn;
	wire room_bn_co;
	am_sub #(.W(US + 1)) s_room_bn (.a(r_leg_room), .b({(US + 1){1'b0}}), .bi(1'b1), .d(room_bn), .bo(room_bn_co));
	wire [ADDR_W-1:0] room_back_val = (psl == 3'd4) ? {{(ADDR_W - US - 5){1'b0}}, room_bn, 4'b0000} :
	                                  (psl == 3'd3) ? {{(ADDR_W - US - 4){1'b0}}, room_bn, 3'b000}  :
	                                  (psl == 3'd2) ? {{(ADDR_W - US - 3){1'b0}}, room_bn, 2'b00}   :
	                                  (psl == 3'd1) ? {{(ADDR_W - US - 2){1'b0}}, room_bn, 1'b0}    :
	                                                  {{(ADDR_W - US - 1){1'b0}}, room_bn};
	wire [ADDR_W-1:0] leg_back_val = {
		leg_rem_done_hi ? r_rem_back_val[ADDR_W-1:16] : room_back_val[ADDR_W-1:16],
		leg_rem_done_lo ? r_rem_back_val[15:0]        : room_back_val[15:0]
	};
`else
	wire [US:0] leg_back_n;
	wire leg_bn_co_unused;
	am_sub #(.W(US + 1)) s_leg_bn (.a(leg_sn), .b({(US + 1){1'b0}}), .bi(1'b1), .d(leg_back_n), .bo(leg_bn_co_unused));
	wire [ADDR_W-1:0] leg_back_val = (psl == 3'd4) ? {{(ADDR_W - US - 5){1'b0}}, leg_back_n, 4'b0000} :
	                                 (psl == 3'd3) ? {{(ADDR_W - US - 4){1'b0}}, leg_back_n, 3'b000}  :
	                                 (psl == 3'd2) ? {{(ADDR_W - US - 3){1'b0}}, leg_back_n, 2'b00}   :
	                                 (psl == 3'd1) ? {{(ADDR_W - US - 2){1'b0}}, leg_back_n, 1'b0}    :
	                                                 {{(ADDR_W - US - 1){1'b0}}, leg_back_n};
`endif

	/*
	 * =================================================================
	 * Burst Engine: 3-Stage Pipeline (Walk -> Geom/Address -> Issue)
	 * =================================================================
	 */
	/* Stage 1: Walk Stage (Computes only bst_seg_n for coordinate walking) */
	wire [ADDR_W-1:0] d_px_row = x_pixels(px_row, mdt_px_row);
	wire [US-1:0] d_xb_row_comb = (psl_ctl == 3'd4) ? {d_px_row[US-5:0], 4'b0000} :
	                              (psl_ctl == 3'd3) ? {d_px_row[US-4:0], 3'b000}  :
	                              (psl_ctl == 3'd2) ? {d_px_row[US-3:0], 2'b00}   :
	                              (psl_ctl == 3'd1) ? {d_px_row[US-2:0], 1'b0}    : d_px_row[US-1:0];
`ifdef SYNTH_KINTEX7
	reg [US-1:0] r_d_xb_row;
	always @(posedge clk) begin
		if (state == S_START1)
			r_d_xb_row <= d_xb_row_comb;
	end
	wire [US-1:0] d_xb_row = r_d_xb_row;
`else
	wire [US-1:0] d_xb_row = d_xb_row_comb;
`endif
	wire [US-1:0] cur_da_init;
	wire co_da_init;
	am_add #(.W(US)) a_da_init (.a(dst_row[US-1:0]), .b(d_xb_row), .ci(1'b0), .s(cur_da_init), .co(co_da_init));


	wire [US-1:0] cur_da_row_next;
	wire co_da_row;
	am_add #(.W(US)) a_da_row (.a(cur_da_row), .b(cur_b_dst_delta_lo), .ci(1'b0), .s(cur_da_row_next), .co(co_da_row));

`ifdef SYNTH_KINTEX7
	reg [US:0] r_da_px_init;
	wire [US:0] da_px_init = r_da_px_init;
`else
	wire [US:0] da_px_init = (psl_ctl == 3'd4) ? {5'b00000, cur_da_row[US-1:4]} :
	                         (psl_ctl == 3'd3) ? {4'b0000, cur_da_row[US-1:3]}  :
	                         (psl_ctl == 3'd2) ? {3'b000, cur_da_row[US-1:2]}   :
	                         (psl_ctl == 3'd1) ? {2'b00, cur_da_row[US-1:1]}    : {1'b0, cur_da_row};
`endif
	wire [US:0] rem_line_init_f, rem_line_init_r;
	wire [1:0] rem_line_init_co;
	am_sub #(.W(US + 1)) s_rli_f (.a(calc_line_pixels), .b(da_px_init), .bi(1'b0), .d(rem_line_init_f), .bo(rem_line_init_co[0]));
	am_add #(.W(US + 1)) a_rli_r (.a(da_px_init), .b({(US + 1){1'b0}}), .ci(1'b1), .s(rem_line_init_r), .co(rem_line_init_co[1]));
	wire [US:0] rem_line_init = mr_walk_rlr_init ? rem_line_init_r : rem_line_init_f;

`ifdef SYNTH_KINTEX7
	wire [US:0] delta_px = ydl_b_is_3_lo ? r_delta_px_back : r_delta_px_norm;
	reg r_is_init1;
	reg r_mr_rlr_sub;
	wire [US:0] rlr_curr = r_is_init1 ? r_rem_line_init : rem_line_row;
	wire [US:0] rlr_cand;
	wire [0:0] rlr_co_unused;
	am_addsub #(.W(US+1)) a_rlr (.a(rlr_curr), .b(delta_px), .sub(r_mr_rlr_sub), .s(rlr_cand), .co(rlr_co_unused[0]));
`else
	wire [US:0] delta_px = ydl_b_is_3_lo ? r_delta_px_back : r_delta_px_norm;
	wire [US:0] rlr_curr = rem_line_row;
	wire [US:0] rlr_diff, rlr_sum;
	wire [1:0] rlr_co_unused;
	am_sub #(.W(US+1)) s_rlr_step (.a(rlr_curr), .b(delta_px), .bi(1'b0), .d(rlr_diff), .bo(rlr_co_unused[0]));
	am_add #(.W(US+1)) a_rlr_step (.a(rlr_curr), .b(delta_px), .ci(1'b0), .s(rlr_sum),  .co(rlr_co_unused[1]));
	wire [US:0] rlr_cand = mr_walk_rlr_step ? rlr_sum : rlr_diff;
`endif

`ifdef SYNTH_KINTEX7
	wire [US:0] rem_line_row_next;
	assign rem_line_row_next[0] = rlr_cand[0];
	genvar g_rlr;
	generate
		for (g_rlr = 1; g_rlr < US; g_rlr = g_rlr + 1) begin : g_rlr_bits
			wire is_lp_k = line_pixels_b[g_rlr];
			wire lt_lp_k = |line_pixels_b[US:g_rlr+1];
			wire eq_zero_k = (rlr_cand[g_rlr-1:0] == {g_rlr{1'b0}});
			assign rem_line_row_next[g_rlr] = is_lp_k ? eq_zero_k : (lt_lp_k ? rlr_cand[g_rlr] : 1'b0);
		end
		assign rem_line_row_next[US] = line_pixels_b[US] ? (rlr_cand[US-1:0] == {US{1'b0}}) : 1'b0;
	endgenerate
`else
	wire [US:0] mask_k;
	genvar g_mk;
	generate
		for (g_mk = 0; g_mk < US; g_mk = g_mk + 1) begin : g_mask_bits
			assign mask_k[g_mk] = |line_pixels_b[US:g_mk+1];
		end
	endgenerate
	assign mask_k[US] = 1'b0;

	wire [US:0] rlr_masked = rlr_cand & mask_k;
	wire [US:0] rem_line_row_next = (|rlr_masked) ? rlr_masked : line_pixels_b;
`endif

	/* m_rev buffer tree */
`ifdef SYNTH_KINTEX7
	reg [63:0] r_mr_buf;
	wire [3:0] o_rev_buf;
	assign o_rev_buf[0] = o_rev;
	assign o_rev_buf[1] = o_rev;
	assign o_rev_buf[2] = o_rev;
	assign o_rev_buf[3] = o_rev;

	genvar g_mri;
	generate
		for (g_mri = 0; g_mri < 64; g_mri = g_mri + 1) begin : g_mr_reg
			always @(posedge clk) begin
				if (rst_b2d_high)
					r_mr_buf[g_mri] <= 1'b0;
				else if (ik_cfg_copy)
					r_mr_buf[g_mri] <= o_rev_buf[g_mri / 16];
			end
		end
	endgenerate
	always @(posedge clk) begin
		if (rst_b2d_high)
			r_mr_rlr_sub <= 1'b0;
		else if (ik_cfg_copy)
			r_mr_rlr_sub <= !o_rev;
	end
	wire [63:0] mr_buf = r_mr_buf;
	wire mr_geom        = mr_buf[0];
	wire mr_walk        = mr_buf[1];
	wire mr_leg         = mr_buf[2];
	wire mr_walk_px     = mr_buf[3];
	wire mr_walk_spx    = mr_buf[4];
	wire mr_walk_lo     = mr_buf[5];
	wire mr_walk_rlr_init = mr_buf[6];
	wire mr_walk_rlr_step = mr_buf[47];
	wire mr_walk_dt0    = mr_buf[7];
	wire mr_walk_dt1    = mr_buf[8];
	wire mr_walk_dt2    = mr_buf[9];
	wire mr_walk_dt3    = mr_buf[10];
	wire mr_walk_st0    = mr_buf[11];
	wire mr_walk_st1    = mr_buf[12];
	wire mr_dacc_lo     = mr_buf[13];
	wire mr_dacc_hi     = mr_buf[14];
	wire mr_sacc_lo     = mr_buf[15];
	wire mr_sacc_h0     = mr_buf[16];
	wire mr_sacc_h1     = mr_buf[48];
	wire mr_sacc_hi     = mr_buf[16];
	wire mr_geom_dlo    = mr_buf[17];
	wire mr_geom_slo    = mr_buf[18];
	wire mr_geom_lin_d0 = mr_buf[19];
	wire mr_geom_lin_d1 = mr_buf[20];
	wire mr_geom_lin_s0 = mr_buf[21];
	wire mr_geom_lin_s1 = mr_buf[22];
	wire mr_geom_lin_p1_lo = mr_buf[23];
	wire mr_geom_lin_p1_hi = mr_buf[46];
	wire mr_px_row      = mr_buf[24];
	wire mr_spx_row     = mr_buf[25];
	wire mr_dlo_lo      = mr_buf[26];
	wire mr_dlo_hi      = mr_buf[27];
	wire mr_slo_lo      = mr_buf[28];
	wire mr_slo_hi      = mr_buf[29];
	wire mr_yd0         = mr_buf[30];
	wire mr_ys0         = mr_buf[31];
	wire mr_px          = mr_buf[32];
	wire mr_spx         = mr_buf[33];
	wire mr_walk_px_hi  = mr_buf[34];
	wire mr_walk_spx_hi = mr_buf[35];
	wire mr_px_hi       = mr_buf[36];
	wire mr_spx_hi      = mr_buf[37];
	wire mr_dacc_m0     = mr_buf[38];
	wire mr_dacc_m1     = mr_buf[39];
	wire mr_sacc_m0     = mr_buf[40];
	wire mr_sacc_m1     = mr_buf[41];
	wire mr_walk_st2    = mr_buf[42];
	wire mr_walk_st3    = mr_buf[43];
	wire mr_yd1         = mr_buf[44];
	wire mr_ys1         = mr_buf[45];
`else
	wire mr_geom = m_rev, mr_walk = m_rev, mr_leg = m_rev;
	wire mr_walk_px = m_rev, mr_walk_spx = m_rev, mr_walk_lo = m_rev;
	wire mr_walk_rlr_init = m_rev, mr_walk_rlr_step = m_rev;
	wire mr_walk_dt0 = m_rev, mr_walk_dt1 = m_rev, mr_walk_dt2 = m_rev, mr_walk_dt3 = m_rev;
	wire mr_walk_st0 = m_rev, mr_walk_st1 = m_rev, mr_walk_st2 = m_rev, mr_walk_st3 = m_rev;
	wire mr_yd0 = m_rev, mr_yd1 = m_rev, mr_ys0 = m_rev, mr_ys1 = m_rev;
	wire mr_yd = m_rev, mr_ys = m_rev;
	wire mr_dacc_lo = m_rev, mr_dacc_m0 = m_rev, mr_dacc_hi = m_rev;
	wire mr_sacc_lo = m_rev, mr_sacc_m0 = m_rev, mr_sacc_hi = m_rev, mr_sacc_h0 = m_rev, mr_sacc_h1 = m_rev;
	wire mr_geom_dlo = m_rev, mr_geom_slo = m_rev;
	wire mr_geom_lin_d0 = m_rev, mr_geom_lin_d1 = m_rev, mr_geom_lin_s0 = m_rev, mr_geom_lin_s1 = m_rev;
	wire mr_geom_lin_p1_lo = m_rev, mr_geom_lin_p1_hi = m_rev;
	wire mr_px = m_rev, mr_spx = m_rev;
	wire mr_px_row = m_rev, mr_spx_row = m_rev;
	wire mr_dlo_lo = m_rev, mr_dlo_hi = m_rev;
	wire mr_slo_lo = m_rev, mr_slo_hi = m_rev;
`endif

	/* Burst Segment Geometry */
	wire [3:0] unused_2b_co;
	reg [2:0] tile_room_b;
	wire [US:0] bst_room_t = {{(US - 2){1'b0}}, tile_room_b};
	wire bst_tiled = mdt_ctl || mst_ctl;
	wire [US:0] bst_room = cur_bst_room;

`ifdef SYNTH_KINTEX7
	wire cmp_lo_le = (rem_b[2:0] <= cur_bst_room[2:0]);
	wire cmp_hi_lt = (rem_b[US:3] < cur_bst_room[US:3]);
	wire cmp_hi_eq = (rem_b[US:3] == cur_bst_room[US:3]);
	wire cmp_last_le = cmp_hi_lt || (cmp_hi_eq && cmp_lo_le);
	wire cmp_last_bo = !cmp_hi_lt && (!cmp_hi_eq || !cmp_lo_le);
	wire bst_seg_last_raw = rem_b_small && cmp_last_le;

	wire [12:0] bsl_buf = {13{bst_seg_last_raw}};
	wire bsl_px_hi   = bsl_buf[0];
	wire bsl_px_lo   = bsl_buf[1];
	wire bsl_spx_hi  = bsl_buf[2];
	wire bsl_spx_lo  = bsl_buf[3];
	wire bsl_rem_lo  = bsl_buf[4];
	wire bsl_rem_hi  = bsl_buf[5];
	wire bsl_seg     = bsl_buf[6];
	wire bsl_ctl     = bsl_buf[7];
	wire bsl_room    = bsl_buf[8];
	wire bsl_rline   = bsl_buf[9];
	wire bsl_step0   = bsl_buf[10];
	wire bsl_step1   = bsl_buf[11];
	wire bsl_back    = bsl_buf[12];
	wire bst_seg_last = bsl_buf[7];
`else
	wire bst_seg_last = rem_b_small && (rem_b[US:0] <= cur_bst_room);
	wire bst_seg_last_raw = bst_seg_last;
	wire bsl_px_hi   = bst_seg_last;
	wire bsl_px_lo   = bst_seg_last;
	wire bsl_spx_hi  = bst_seg_last;
	wire bsl_spx_lo  = bst_seg_last;
	wire bsl_rem_lo  = bst_seg_last;
	wire bsl_rem_hi  = bst_seg_last;
	wire bsl_seg     = bst_seg_last;
	wire bsl_ctl     = bst_seg_last;
	wire bsl_room    = bst_seg_last;
	wire bsl_rline   = bst_seg_last;
	wire bsl_step0   = bst_seg_last;
	wire bsl_step1   = bst_seg_last;
	wire bsl_back    = bst_seg_last;
`endif

	wire [US:0] bst_seg_n = bsl_seg ? rem_b[US:0] : cur_bst_room;
	wire [US:0] rem_bytes = (pslw_ctl == 3'd4) ? {rem_b[US-4:0], 4'b0000} :
	                        (pslw_ctl == 3'd3) ? {rem_b[US-3:0], 3'b000}  :
	                        (pslw_ctl == 3'd2) ? {rem_b[US-2:0], 2'b00}   :
	                        (pslw_ctl == 3'd1) ? {rem_b[US-1:0], 1'b0}    : rem_b[US:0];
	wire [US:0] room_bytes = (pslw_ctl == 3'd4) ? {cur_bst_room[US-4:0], 4'b0000} :
	                         (pslw_ctl == 3'd3) ? {cur_bst_room[US-3:0], 3'b000}  :
	                         (pslw_ctl == 3'd2) ? {cur_bst_room[US-2:0], 2'b00}   :
	                         (pslw_ctl == 3'd1) ? {cur_bst_room[US-1:0], 1'b0}    : cur_bst_room;
`ifdef SYNTH_KINTEX7
	wire [US:0] bst_seg_bytes;
	genvar g_sb;
	generate
		for (g_sb = 0; g_sb <= US; g_sb = g_sb + 1) begin : g_bst_sb
			LUT3 #(.INIT(8'hCA)) u_bsb (
				.I0(room_bytes[g_sb]),
				.I1(rem_bytes[g_sb]),
				.I2(bsl_seg),
				.O(bst_seg_bytes[g_sb])
			);
		end
	endgenerate
`else
	wire [US:0] bst_seg_bytes = bsl_seg ? rem_bytes : room_bytes;
`endif

	wire [US:0] rem_back_n, room_back_n;
`ifdef SYNTH_KINTEX7
	wire [US:0] rb_z;
	assign rb_z[0] = ~cur_bst_room[0];
	genvar g_rb;
	generate
		for (g_rb = 1; g_rb <= US; g_rb = g_rb + 1) begin : g_rb_bits
			assign rb_z[g_rb] = rb_z[g_rb - 1] & (~cur_bst_room[g_rb]);
		end
	endgenerate
	assign room_back_n[0] = ~cur_bst_room[0];
	generate
		for (g_rb = 1; g_rb <= US; g_rb = g_rb + 1) begin : g_room_bn
			assign room_back_n[g_rb] = cur_bst_room[g_rb] ^ rb_z[g_rb - 1];
		end
	endgenerate

	wire [US:0] mb_z;
	assign mb_z[0] = ~rem_b[0];
	generate
		for (g_rb = 1; g_rb <= US; g_rb = g_rb + 1) begin : g_mb_bits
			assign mb_z[g_rb] = mb_z[g_rb - 1] & (~rem_b[g_rb]);
		end
	endgenerate
	assign rem_back_n[0] = ~rem_b[0];
	generate
		for (g_rb = 1; g_rb <= US; g_rb = g_rb + 1) begin : g_rem_bn
			assign rem_back_n[g_rb] = rem_b[g_rb] ^ mb_z[g_rb - 1];
		end
	endgenerate
`else
	wire [1:0] bst_back_co;
	am_sub #(.W(US + 1)) s_rem_bn (.a(rem_b[US:0]), .b({(US + 1){1'b0}}), .bi(1'b1), .d(rem_back_n), .bo(bst_back_co[0]));
	am_sub #(.W(US + 1)) s_room_bn (.a(cur_bst_room), .b({(US + 1){1'b0}}), .bi(1'b1), .d(room_back_n), .bo(bst_back_co[1]));
`endif
	wire [15:0] rem_back_16 = (pslw_gbk0 == 3'd4) ? {{(11-US){1'b0}}, rem_back_n, 4'b0000} :
	                          (pslw_gbk0 == 3'd3) ? {{(12-US){1'b0}}, rem_back_n, 3'b000}  :
	                          (pslw_gbk0 == 3'd2) ? {{(13-US){1'b0}}, rem_back_n, 2'b00}   :
	                          (pslw_gbk0 == 3'd1) ? {{(14-US){1'b0}}, rem_back_n, 1'b0}    : {{(15-US){1'b0}}, rem_back_n};
	wire [15:0] room_back_16 = (pslw_gbk0 == 3'd4) ? {{(11-US){1'b0}}, room_back_n, 4'b0000} :
	                           (pslw_gbk0 == 3'd3) ? {{(12-US){1'b0}}, room_back_n, 3'b000}  :
	                           (pslw_gbk0 == 3'd2) ? {{(13-US){1'b0}}, room_back_n, 2'b00}   :
	                           (pslw_gbk0 == 3'd1) ? {{(14-US){1'b0}}, room_back_n, 1'b0}    : {{(15-US){1'b0}}, room_back_n};
`ifdef SYNTH_KINTEX7
	wire [US-1:0] bst_back_lo;
	generate
		for (g_sb = 0; g_sb < US; g_sb = g_sb + 1) begin : g_bst_bk
			LUT3 #(.INIT(8'hCA)) u_bbk (
				.I0(room_back_16[g_sb]),
				.I1(rem_back_16[g_sb]),
				.I2(bsl_back),
				.O(bst_back_lo[g_sb])
			);
		end
	endgenerate
`else
	wire [US-1:0] bst_back_lo = bsl_back ? rem_back_16[US-1:0] : room_back_16[US-1:0];
`endif

	wire [US:0] rem_line_sub;
	wire rem_line_bo;
	am_sub #(.W(US + 1)) s_rline (.a(rem_line_b), .b(cur_bst_room), .bi(1'b0), .d(rem_line_sub), .bo(rem_line_bo));
	wire [US:0] rem_line_seg_next = (cur_bst_room == rem_line_b) ? line_pixels_b : rem_line_sub;
	wire [US:0] rem_line_b_d = bsl_rline ? rem_line_row : rem_line_seg_next;

	/* Clean 17-bit Addsub for Coordinates */
	/* 1. px_next */
	wire [16:0] px_step;
	wire px_co;
	am_addsub #(.W(17)) as_px_b (.a(px_b), .b({{(16-US){1'b0}}, cur_bst_room}), .sub(mr_walk_px), .s(px_step), .co(px_co));
	wire [16:0] px_b_next = {bsl_px_hi ? px_row[16:8] : px_step[16:8], bsl_px_lo ? px_row[7:0] : px_step[7:0]};

	/* 2. spx_next */
	wire [16:0] spx_step;
	wire spx_co;
	am_addsub #(.W(17)) as_spx_b (.a(spx_b), .b({{(16-US){1'b0}}, cur_bst_room}), .sub(mr_walk_spx), .s(spx_step), .co(spx_co));
	wire [16:0] spx_b_next = {bsl_spx_hi ? spx_row[16:8] : spx_step[16:8], bsl_spx_lo ? spx_row[7:0] : spx_step[7:0]};

	/* Precomputed tile_room for next segment (using 2-bit LUT addsub, independent of bsl) */
`ifdef SYNTH_KINTEX7
	assign unused_2b_co = 4'd0;
	wire [1:0] px_2b_next = {
		px_b[1] ^ cur_bst_room[1] ^ ((r_mr_walk_lo ? ~px_b[0] : px_b[0]) & cur_bst_room[0]),
		px_b[0] ^ cur_bst_room[0]
	};
	wire [1:0] spx_2b_next = {
		spx_b[1] ^ cur_bst_room[1] ^ ((r_mr_walk_lo ? ~spx_b[0] : spx_b[0]) & cur_bst_room[0]),
		spx_b[0] ^ cur_bst_room[0]
	};
	wire [2:0] td_walk = {px_2b_next == 2'b00, px_2b_next[1] ^ px_2b_next[0], px_2b_next[0]};
	wire [2:0] ts_walk = {spx_2b_next == 2'b00, spx_2b_next[1] ^ spx_2b_next[0], spx_2b_next[0]};
	wire [2:0] tile_room_walk = mdt_ctl ? td_walk : ts_walk;
`else
	wire [1:0] px_2b_add, px_2b_sub;
	am_add #(.W(2)) a_px2 (.a(px_b[1:0]), .b(cur_bst_room[1:0]), .ci(1'b0), .s(px_2b_add), .co(unused_2b_co[0]));
	am_sub #(.W(2)) s_px2 (.a(px_b[1:0]), .b(cur_bst_room[1:0]), .bi(1'b0), .d(px_2b_sub), .bo(unused_2b_co[1]));
	wire [1:0] px_2b_next = r_mr_walk_lo ? px_2b_sub : px_2b_add;

	wire [1:0] spx_2b_add, spx_2b_sub;
	am_add #(.W(2)) a_spx2 (.a(spx_b[1:0]), .b(cur_bst_room[1:0]), .ci(1'b0), .s(spx_2b_add), .co(unused_2b_co[2]));
	am_sub #(.W(2)) s_spx2 (.a(spx_b[1:0]), .b(cur_bst_room[1:0]), .bi(1'b0), .d(spx_2b_sub), .bo(unused_2b_co[3]));
	wire [1:0] spx_2b_next = r_mr_walk_lo ? spx_2b_sub : spx_2b_add;

	wire [2:0] td_walk = {px_2b_next == 2'b00, px_2b_next[1] ^ px_2b_next[0], px_2b_next[0]};
	wire [2:0] ts_walk = {spx_2b_next == 2'b00, spx_2b_next[1] ^ spx_2b_next[0], spx_2b_next[0]};
	wire [2:0] tmin_walk = (td_walk < ts_walk) ? td_walk : ts_walk;
	wire [2:0] tile_room_walk = (mdt_ctl && mst_ctl) ? tmin_walk : (mdt_ctl ? td_walk : ts_walk);
`endif

	wire [2:0] td_init = {px_row[1:0] == 2'b00, px_row[1] ^ px_row[0], px_row[0]};
	wire [2:0] ts_init = {spx_row[1:0] == 2'b00, spx_row[1] ^ spx_row[0], spx_row[0]};
	wire [2:0] tmin_init = (td_init < ts_init) ? td_init : ts_init;
	wire [2:0] tile_room_init = (mdt_ctl && mst_ctl) ? tmin_init : (mdt_ctl ? td_init : ts_init);
	wire [US:0] bst_room_t_init = {{(US - 2){1'b0}}, tile_room_init};
	wire [US:0] bst_room_init = (bst_tiled && (bst_room_t_init < rem_line_init)) ? bst_room_t_init : rem_line_init;

	wire [2:0] tile_room_step = bsl_room ? tile_room_init : tile_room_walk;

	/* 3. rem_next: Clean 17-bit Subtractor (Pre-LUTs: 1, Post-LUTs: 1) */
	wire [16:0] rem_sub;
	wire rem_sub_bo;
	am_sub #(.W(17)) s_brem (.a(rem_b), .b({{(16 - US){1'b0}}, cur_bst_room}), .bi(1'b0), .d(rem_sub), .bo(rem_sub_bo));
	wire [16:0] rem_b_next = {bsl_rem_hi ? width[16:8] : rem_sub[16:8], bsl_rem_lo ? width[7:0] : rem_sub[7:0]};

	wire [US:0] bst_room_t_next = {{(US - 2){1'b0}}, tile_room_step};
	wire [US:0] bst_room_next_val = bst_tiled ? bst_room_t_next : (bsl_room ? rem_line_row : line_pixels_b);

	wire rem_b_cand = (rem_b[16:US+2] == 0) && rem_b[US+1];
	wire rem_borrow_hi = rem_b[US:0] < cur_bst_room;
	wire rem_b_small_walk = rem_b_small || (rem_b_cand && rem_borrow_hi);


	/* Stage 1: Walk Stage (Computes bst_seg_n and coordinates) */
	wire [ADDR_W-1:0] d_px_b = x_pixels(px_b, mdt_px_b);
	wire [ADDR_W-1:0] s_px_b = x_pixels(spx_b, mst_px_b);
	wire [15:0] d_xb_b_lo = (pslw_dxb0 == 3'd4) ? {d_px_b[11:0], 4'b0000} :
	                        (pslw_dxb0 == 3'd3) ? {d_px_b[12:0], 3'b000}  :
	                        (pslw_dxb0 == 3'd2) ? {d_px_b[13:0], 2'b00}   :
	                        (pslw_dxb0 == 3'd1) ? {d_px_b[14:0], 1'b0}    : d_px_b[15:0];
	wire [ADDR_W-17:0] d_xb_b_hi = (pslw_dxb1 == 3'd4) ? d_px_b[ADDR_W-5:12] :
	                               (pslw_dxb1 == 3'd3) ? d_px_b[ADDR_W-4:13] :
	                               (pslw_dxb1 == 3'd2) ? d_px_b[ADDR_W-3:14] :
	                               (pslw_dxb1 == 3'd1) ? d_px_b[ADDR_W-2:15] : d_px_b[ADDR_W-1:16];
	wire [ADDR_W-1:0] d_xb_b = {d_xb_b_hi, d_xb_b_lo};

	wire [15:0] s_xb_b_lo = (pslw_sxb0 == 3'd4) ? {s_px_b[11:0], 4'b0000} :
	                        (pslw_sxb0 == 3'd3) ? {s_px_b[12:0], 3'b000}  :
	                        (pslw_sxb0 == 3'd2) ? {s_px_b[13:0], 2'b00}   :
	                        (pslw_sxb0 == 3'd1) ? {s_px_b[14:0], 1'b0}    : s_px_b[15:0];
	wire [ADDR_W-17:0] s_xb_b_hi = (pslw_sxb1 == 3'd4) ? s_px_b[ADDR_W-5:12] :
	                               (pslw_sxb1 == 3'd3) ? s_px_b[ADDR_W-4:13] :
	                               (pslw_sxb1 == 3'd2) ? s_px_b[ADDR_W-3:14] :
	                               (pslw_sxb1 == 3'd1) ? s_px_b[ADDR_W-2:15] : s_px_b[ADDR_W-1:16];
	wire [ADDR_W-1:0] s_xb_b = {s_xb_b_hi, s_xb_b_lo};

	wire [ADDR_W-1:0] g_da_full_next, g_sa_full_next;
	wire [1:0] g_full_co_next;
	am_add #(.W(ADDR_W)) a_bda (.a(dst_row_b), .b(d_xb_b), .ci(1'b0), .s(g_da_full_next), .co(g_full_co_next[0]));
	am_add #(.W(ADDR_W)) a_bsa (.a(src_row_b), .b(s_xb_b), .ci(1'b0), .s(g_sa_full_next), .co(g_full_co_next[1]));

	always @(posedge clk) begin
		if (g_len_da0) g_da_full[15:0] <= g_da_full_next[15:0];
		if (g_len_da1) g_da_full[ADDR_W-1:16] <= g_da_full_next[ADDR_W-1:16];
		if (g_len_sa0) g_sa_full[15:0] <= g_sa_full_next[15:0];
		if (g_len_sa1) g_sa_full[ADDR_W-1:16] <= g_sa_full_next[ADDR_W-1:16];
	end

	/* Stage 2: Geom / Address Engine (Computed from g_* registers in next cycle) */
	wire [US-1:0] g_da_lo = g_da_full[US-1:0];
	wire [US-1:0] g_sa_lo = g_sa_full[US-1:0];

	wire [US-1:0] g_dlo_lo_rev;
	wire g_dlo_lo_bo;
	am_sub #(.W(US)) s_dlo_lo (.a(g_da_lo), .b(g_back_lo), .bi(1'b0), .d(g_dlo_lo_rev), .bo(g_dlo_lo_bo));
	wire [US-1:0] g_dlo_lo = mr_geom_dlo ? g_dlo_lo_rev : g_da_lo;

	wire [US-1:0] g_slo_lo_rev;
	wire g_slo_lo_bo;
	am_sub #(.W(US)) s_slo_lo (.a(g_sa_lo), .b(g_back_lo), .bi(1'b0), .d(g_slo_lo_rev), .bo(g_slo_lo_bo));
	wire [US-1:0] g_slo_lo = mr_geom_slo ? g_slo_lo_rev : g_sa_lo;

	wire [LA_W-1:0] s_line = g_sa_full[ADDR_W-1:US];
	wire [LA_W-1:0] s_line_p1, s_line_m1;
	wire [1:0] s_line_co;
	am_add #(.W(LA_W)) a_s_p1 (.a(s_line), .b({LA_W{1'b0}}), .ci(1'b1), .s(s_line_p1), .co(s_line_co[0]));
	am_sub #(.W(LA_W)) s_s_m1 (.a(s_line), .b({LA_W{1'b0}}), .bi(1'b1), .d(s_line_m1), .bo(s_line_co[1]));

	wire [LA_W-1:0] d_line = g_da_full[ADDR_W-1:US];
	wire [LA_W-1:0] d_line_m1;
	wire d_line_bo;
	am_sub #(.W(LA_W)) s_d_m1 (.a(d_line), .b({LA_W{1'b0}}), .bi(1'b1), .d(d_line_m1), .bo(d_line_bo));

	wire slo_borrow = g_slo_lo_bo;
	wire dlo_borrow = g_dlo_lo_bo;

`ifdef SYNTH_KINTEX7
	wire [1:0] dlo_bor_buf, slo_bor_buf;
	assign dlo_bor_buf[0] = dlo_borrow;
	assign dlo_bor_buf[1] = dlo_borrow;
	assign slo_bor_buf[0] = slo_borrow;
	assign slo_bor_buf[1] = slo_borrow;
	wire dlo_borrow_lo = dlo_bor_buf[0];
	wire dlo_borrow_hi = dlo_bor_buf[1];
	wire slo_borrow_lo = slo_bor_buf[0];
	wire slo_borrow_hi = slo_bor_buf[1];
`else
	wire dlo_borrow_lo = dlo_borrow;
	wire dlo_borrow_hi = dlo_borrow;
	wire slo_borrow_lo = slo_borrow;
	wire slo_borrow_hi = slo_borrow;
`endif

	wire [LA_W-1:0] g_seg_line = {
		mr_geom_lin_d1 ? (dlo_borrow_hi ? d_line_m1[LA_W-1:14] : d_line[LA_W-1:14]) : d_line[LA_W-1:14],
		mr_geom_lin_d0 ? (dlo_borrow_lo ? d_line_m1[13:0]       : d_line[13:0])       : d_line[13:0]
	};
	wire [LA_W-1:0] g_src_n0 = {
		mr_geom_lin_s1 ? (slo_borrow_hi ? s_line_m1[LA_W-1:14] : s_line[LA_W-1:14]) : s_line[LA_W-1:14],
		mr_geom_lin_s0 ? (slo_borrow_lo ? s_line_m1[13:0]       : s_line[13:0])       : s_line[13:0]
	};
	wire [LA_W-1:0] g_src_n1 = {
		mr_geom_lin_p1_hi ? s_line[LA_W-1:16] : s_line_p1[LA_W-1:16],
		mr_geom_lin_p1_lo ? s_line[15:0]      : s_line_p1[15:0]
	};

	wire [US:0] g_s_end;
	wire g_send_co;
	am_add #(.W(US + 1)) a_bst_send (.a({1'b0, g_sa_lo}), .b(g_seg_bytes), .ci(1'b0), .s(g_s_end), .co(g_send_co));
	wire g_s_end_gt = g_s_end[US] && (|g_s_end[US-1:0]);
	wire g_two_lines = mr_geom_slo ? slo_borrow : g_s_end_gt;

	wire [US:0] g_p_end;
	wire g_pend_co;
	am_add #(.W(US + 1)) a_g_pe (.a({1'b0, g_dlo_lo}), .b(g_seg_bytes), .ci(1'b0), .s(g_p_end), .co(g_pend_co));

	wire [US-1:0] off_fwd;
	wire          bo_fwd, bo_rev;
	wire [US-1:0] off_rev_unused;
	am_sub #(.W(US)) s_off_fwd (.a(g_sa_lo), .b(g_da_lo), .bi(1'b0), .d(off_fwd), .bo(bo_fwd));
	am_sub #(.W(US)) s_off_rev (.a(g_slo_lo_rev), .b(g_dlo_lo_rev), .bi(1'b0), .d(off_rev_unused), .bo(bo_rev));
	wire [US-1:0] g_src_off = off_fwd;
	wire          g_n0_slot = mr_geom_slo ? bo_rev : bo_fwd;

	localparam SKID_W = 3 * LA_W + 3 * (US + 1) + 2 * US + 4;
	wire [SKID_W-1:0] skid_in_data = {
		g_seg_line, g_src_n0, g_src_n1, g_seg_n, g_seg_bytes, g_p_end,
		g_dlo_lo, g_src_off, g_two_lines, g_n0_slot, g_seg_last, g_rows_b_zero
	};
	wire [SKID_W-1:0] skid_out_data;
	wire [US:0] p_p_end;
	assign {
		p_dline, p_src_n0, p_src_n1, p_seg_n, p_seg_bytes, p_p_end,
		p_dlo_lo, p_off, p_two_lines, p_n0_slot, p_seg_last, p_rows_b_zero
	} = skid_out_data;

	wire skid_rst_n = rst_n && (state_b4_1 && state[3:0] == S_BURST[3:0]);
	wire skid_in_ready;
	wire issue_rdy;

	atg_blt_skid #(.W(SKID_W)) u_skid_p (
		.clk(clk),
		.rst_n(skid_rst_n),
		.in_valid(g_valid),
		.in_ready(skid_in_ready),
		.in_data(skid_in_data),
		.out_valid(p_valid),
		.out_ready(issue_rdy),
		.out_data(skid_out_data)
	);

`ifdef SYNTH_KINTEX7
	wire [2:0] pv_buf;
	assign pv_buf[0] = p_valid;
	assign pv_buf[1] = p_valid;
	assign pv_buf[2] = p_valid;
	wire p_valid_fill = pv_buf[0];
	wire p_valid_iss0 = pv_buf[1];
	wire p_valid_iss1 = pv_buf[2];
`else
	wire p_valid_fill = p_valid;
	wire p_valid_iss0 = p_valid;
	wire p_valid_iss1 = p_valid;
`endif

	/* The port: the request, the outstanding requests, the line buffers. */
	wire q_free, rd_idle, wr_idle, fail_raw;
`ifdef SYNTH_KINTEX7
	/* fail_raw buffer tree: 8 leaves, each <= 14 loads */
	wire [7:0] fail_buf;
	genvar g_fbi;
	generate
		for (g_fbi = 0; g_fbi < 8; g_fbi = g_fbi + 1) begin : g_fail_b
			assign fail_buf[g_fbi] = fail_raw;
		end
	endgenerate
	wire fail_port   = fail_buf[0];
	wire fail_bst_rd = fail_buf[1];
	wire fail_bst_wr = fail_buf[2];
	wire fail_burst  = fail_buf[3];
	wire fail_fsm0   = fail_buf[4];
	wire fail_fsm1   = fail_buf[5];
	wire fail_fsm2   = fail_buf[6];
	wire fail_fsm3   = fail_buf[7];
	wire fail        = fail_raw;
`else
	wire fail_port   = fail_raw;
	wire fail_bst_rd = fail_raw;
	wire fail_bst_wr = fail_raw;
	wire fail_burst  = fail_raw;
	wire fail_fsm0   = fail_raw;
	wire fail_fsm1   = fail_raw;
	wire fail_fsm2   = fail_raw;
	wire fail_fsm3   = fail_raw;
	wire fail        = fail_raw;
`endif
	wire [LINE_BITS-1:0] buf0, buf1, bufd;

	wire crd_cond = (state == S_CRD && q_free && wr_idle && !fail_raw);
	wire crd_c0 = crd_cond;
	wire crd_c1 = crd_cond;
	wire crd_c2 = crd_cond;
	wire rd_go_lo = crd_c0 && (rd_first || rd_second);
	wire rd_go_hi = crd_c1 && (rd_first || rd_second);
	wire rd_go_ctl = crd_c2 && (rd_first || rd_second);
	wire rd_go = rd_go_ctl;
	wire drd_go = state == S_DRD && q_free && wr_idle && !fail_raw;
	wire can_wr = q_free && !fail_raw;
	wire wr_go = state == S_WR && can_wr;

	wire leg_req_needed = (state == S_WR) || (wr_idle && ((state == S_DRD) || (state == S_CRD && (rd_first || rd_second))));
	wire leg_issue = q_free && !fail_raw && leg_req_needed;
	wire wr_go_ctl = wr_go;

	wire mc_fsm = m_copy, mc_issue = m_copy, mc_bk0 = m_copy, mc_bk1 = m_copy;

	/* The copied line: the source window shifted by whole bytes via atg_blt_align. */
	wire [2*LINE_BITS-1:0] both = {buf1, buf0};
	wire [LINE_BITS-1:0] copy_line;

	generate
	if (ENABLE_SCALE != 0) begin : gen_leg_align
		atg_blt_align #(
			.LINE_BYTES(LINE_BYTES),
			.LINE_SHIFT(LINE_SHIFT)
		) leg_align (
			.in_data(both),
			.off(src_off),
			.out_data(copy_line)
		);
	end else begin : gen_no_leg_align
		assign copy_line = buf0;
	end
	endgenerate

	/* Blend-over. */
	wire bl_done;
	wire [LINE_BITS-1:0] bl_out;
	reg bl_go;

`ifdef SYNTH_KINTEX7
	localparam NUM_LEG_BYTE_BUFS = LINE_BYTES;
	wire [LINE_BITS-1:0] bl_src;
	wire [LINE_BITS-1:0] leg_wdata;
	wire [NUM_LEG_BYTE_BUFS-1:0] mc_bl_slice;
	wire [NUM_LEG_BYTE_BUFS-1:0] mb_bl_slice;
	genvar bsi;
	generate
		for (bsi = 0; bsi < NUM_LEG_BYTE_BUFS; bsi = bsi + 1) begin : g_bl_src
			assign mc_bl_slice[bsi] = m_copy;
			assign mb_bl_slice[bsi] = m_blend;
			assign bl_src[bsi*8 +: 8] = mc_bl_slice[bsi] ? copy_line[bsi*8 +: 8] : fill_line[bsi*8 +: 8];
			assign leg_wdata[bsi*8 +: 8] = mb_bl_slice[bsi] ? bl_out[bsi*8 +: 8] :
				(mc_bl_slice[bsi] ? copy_line[bsi*8 +: 8] : fill_line[bsi*8 +: 8]);
		end
	endgenerate
`else
	localparam NUM_WD_BUFS = LINE_BITS / 16;
	wire [LINE_BITS-1:0] bl_src;
	genvar bsi;
	generate
		for (bsi = 0; bsi < NUM_WD_BUFS; bsi = bsi + 1) begin : g_bl_src
			assign bl_src[bsi*16 +: 16] = m_copy ? copy_line[bsi*16 +: 16] : fill_line[bsi*16 +: 16];
		end
	endgenerate
`endif

`ifdef SYNTH_KINTEX7
	reg [LINE_BITS-1:0] r_bl_src;
	wire ce_bl_raw = (state == S_DWAIT || state == S_CWAIT);
	wire [15:0] bl_ce_buf;
	genvar g_bli;
	generate
		for (g_bli = 0; g_bli < 16; g_bli = g_bli + 1) begin : g_bl_ce
			assign bl_ce_buf[g_bli] = ce_bl_raw;
			always @(posedge clk) begin
				if (bl_ce_buf[g_bli])
					r_bl_src[g_bli*16 +: 16] <= bl_src[g_bli*16 +: 16];
			end
		end
	endgenerate
`endif

	generate
	if (ENABLE_BLEND != 0) begin : gen_bl
`ifdef SYNTH_KINTEX7
		atg_blt_blend #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) bl (
			.clk(clk), .rst_n(rst_n), .go(bl_go), .src(r_bl_src),
			.dst(bufd), .done(bl_done), .out(bl_out)
		);
`else
		atg_blt_blend #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) bl (
			.clk(clk), .rst_n(rst_n), .go(bl_go), .src(bl_src),
			.dst(bufd), .done(bl_done), .out(bl_out)
		);
`endif
	end else begin : gen_no_bl
		assign bl_done = 1'b1;
		assign bl_out = {LINE_BITS{1'b0}};
	end
	endgenerate

	/* Legacy port instance */
	wire leg_req_valid, leg_req_write;
	wire [LA_W-1:0] leg_req_line;
	wire [LINE_BYTES-1:0] leg_req_be;
	wire [LINE_BITS-1:0] leg_req_wdata;
	wire [7:0] leg_req_tag;

`ifdef SYNTH_KINTEX7
	wire rd_first_lo, rd_first_hi;
	wire rd_go_line_lo, rd_go_line_hi;
	assign rd_first_lo = rd_first;
	assign rd_first_hi = rd_first;
	assign rd_go_line_lo = rd_go_lo;
	assign rd_go_line_hi = rd_go_hi;

	wire [LA_W-1:0] port_i_line = {
		rd_go_line_hi ? (rd_first_hi ? src_n0[LA_W-1:14] : src_n1[LA_W-1:14]) : seg_line[LA_W-1:14],
		rd_go_line_lo ? (rd_first_lo ? src_n0[13:0] : src_n1[13:0]) : seg_line[13:0]
	};
`else
	wire [LA_W-1:0] port_i_line = {
		rd_go_hi ? (rd_first ? src_n0[LA_W-1:14] : src_n1[LA_W-1:14]) : seg_line[LA_W-1:14],
		rd_go_lo ? (rd_first ? src_n0[13:0] : src_n1[13:0]) : seg_line[13:0]
	};

	wire [LINE_BITS-1:0] leg_wdata;
	genvar lwi;
	generate
		for (lwi = 0; lwi < NUM_WD_BUFS; lwi = lwi + 1) begin : g_leg_wd
			assign leg_wdata[lwi*16 +: 16] = m_blend ? bl_out[lwi*16 +: 16] :
				(m_copy ? copy_line[lwi*16 +: 16] : fill_line[lwi*16 +: 16]);
		end
	endgenerate
`endif

	atg_blt_port #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) port (
		.clk(clk), .rst_n(rst_n), .clr(state == S_IDLE && kick),
		.issue(leg_issue), .i_write(wr_go_ctl),
		.i_line(port_i_line),
		.i_slot(rd_go ? (rd_first ? {1'b0, n0_slot} : 2'd1) : drd_go ? 2'd2 : 2'd0),
		.i_be(seg_be),
		.i_wdata(leg_wdata),
		.free(q_free), .rd_idle(rd_idle), .wr_idle(wr_idle), .fail(fail_raw),
		.buf0(buf0), .buf1(buf1), .bufd(bufd),
		.req_valid(leg_req_valid), .req_ready(req_ready && !m_burst), .req_write(leg_req_write),
		.req_line(leg_req_line), .req_be(leg_req_be), .req_wdata(leg_req_wdata), .req_tag(leg_req_tag),
		.rsp_valid(rsp_valid), .rsp_inhibit(m_burst), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	/*
	 * =========================================================================
	 * Burst Engine Read/Write Data Path & Barrel Shifter
	 * =========================================================================
	 */
	/* Read-out from ping-pong RAM (3-stage pipeline: Stage 0 -> s1 -> s2 -> s3) */
	localparam NUM_RAM_SLICES  = LINE_BITS / 4;
	localparam NUM_RAM_GRPS    = NUM_RAM_SLICES / 8;
	localparam NUM_RADDR_REPS  = NUM_RAM_SLICES / 4;
	localparam PP_S1_OUT_BYTES = (LINE_BYTES >= 64) ? (LINE_BYTES + 48) : (LINE_BYTES + 16);
	localparam PP_S0_OUT_BYTES = PP_S1_OUT_BYTES + 12;
	localparam PP_S0_LEAF_CNT  = (PP_S0_OUT_BYTES + 1) / 2;
	localparam PP_S1_LEAF_CNT  = (PP_S1_OUT_BYTES + 1) / 2;
	localparam PP_S2_LEAF_CNT  = (LINE_BYTES + 1) / 2;

	reg s1_valid, s2_valid, s3_valid;
	reg [LA_W-1:0] s1_line, s2_line, s3_line;
	reg [LINE_BYTES-1:0] s1_be, s2_be, s3_be;
	reg [5:2] s1_off_hi;
	reg [LINE_BITS-1:0] s3_wdata;

`ifdef SYNTH_KINTEX7
	wire br_pipe_rdy_raw;
	wire [9:0]   br_rdy_mid;
	wire [149:0] br_rdy_leaf;
	LUT2 #(.INIT(4'hD)) u_bpr_raw (.I0(s3_valid), .I1(req_ready), .O(br_pipe_rdy_raw));
	genvar g_bpr_m, g_bpr_l;
	generate
		for (g_bpr_m = 0; g_bpr_m < 10; g_bpr_m = g_bpr_m + 1) begin : g_bpr_mid
			assign br_rdy_mid[g_bpr_m] = br_pipe_rdy_raw;
		end
		for (g_bpr_l = 0; g_bpr_l < 150; g_bpr_l = g_bpr_l + 1) begin : g_bpr_leaf
			assign br_rdy_leaf[g_bpr_l] = br_rdy_mid[g_bpr_l / 15];
		end
	endgenerate
	wire br_step_en = br_rdy_leaf[146];
`else
	wire br_pipe_rdy = !s3_valid || req_ready;
	wire br_step_en  = br_pipe_rdy;
`endif

`ifdef SYNTH_KINTEX7
	wire br_bank_root0, br_bank_root1;
	assign br_bank_root0 = br_bank;
	assign br_bank_root1 = br_bank;

	wire [3:0] br_bank_ram;
	wire br_bank_l0_lo, br_bank_l0_hi, br_bank_l1_lo, br_bank_l1_hi, br_bank_l2, br_bank_l3;
	wire br_bank_b0, br_bank_b1, br_bank_b2, br_bank_b3;
	wire br_bank_b4, br_bank_b5, br_bank_b6, br_bank_b7;
	wire br_bank_s0, br_bank_s1, br_bank_m0, br_bank_m1;
	assign br_bank_ram[0] = br_bank;
	assign br_bank_ram[1] = br_bank;
	assign br_bank_ram[2] = br_bank;
	assign br_bank_ram[3] = br_bank;
	assign br_bank_l0_lo = br_bank_root0;
	assign br_bank_l0_hi = br_bank_root0;
	assign br_bank_l1_lo = br_bank_root0;
	assign br_bank_l1_hi = br_bank_root0;
	assign br_bank_l2 = br_bank_root0;
	assign br_bank_l3 = br_bank_root0;
	assign br_bank_b0 = br_bank_root0;
	assign br_bank_b1 = br_bank_root0;
	assign br_bank_b2 = br_bank_root0;
	assign br_bank_b3 = br_bank_root0;
	assign br_bank_b4 = br_bank_root1;
	assign br_bank_b5 = br_bank_root1;
	assign br_bank_b6 = br_bank_root1;
	assign br_bank_b7 = br_bank_root1;
	assign br_bank_s0 = br_bank;
	assign br_bank_s1 = br_bank;
	assign br_bank_m0 = br_bank;
	assign br_bank_m1 = br_bank;

	wire [2:0] br_seg_root0, br_seg_root1;
	wire [2:0] br_seg_idx_l0_lo, br_seg_idx_l0_hi;
	wire [2:0] br_seg_idx_l1_lo, br_seg_idx_l1_hi;
	wire [2:0] br_seg_idx_l2_lo, br_seg_idx_l2_hi;
	wire [2:0] br_seg_idx_l3_lo, br_seg_idx_l3_hi;
	wire [2:0] br_seg_idx_b0_lo, br_seg_idx_b0_hi;
	wire [2:0] br_seg_idx_b1_lo, br_seg_idx_b1_hi;
	wire [2:0] br_seg_idx_b2_lo, br_seg_idx_b2_hi;
	wire [2:0] br_seg_idx_b3_lo, br_seg_idx_b3_hi;
	wire [2:0] br_seg_idx_b4_lo, br_seg_idx_b4_hi;
	wire [2:0] br_seg_idx_b5_lo, br_seg_idx_b5_hi;
	wire [2:0] br_seg_idx_b6_lo, br_seg_idx_b6_hi;
	wire [2:0] br_seg_idx_b7_lo, br_seg_idx_b7_hi;
	wire [2:0] br_seg_idx_s0, br_seg_idx_s1, br_seg_idx_m0, br_seg_idx_m1;
	genvar brb;
	generate
		for (brb = 0; brb < 3; brb = brb + 1) begin : g_br_buf
			assign br_seg_root0[brb] = br_seg_idx[brb];
			assign br_seg_root1[brb] = br_seg_idx[brb];

			assign br_seg_idx_l0_lo[brb] = br_seg_root0[brb];
			assign br_seg_idx_l0_hi[brb] = br_seg_root0[brb];
			assign br_seg_idx_l1_lo[brb] = br_seg_root0[brb];
			assign br_seg_idx_l1_hi[brb] = br_seg_root0[brb];
			assign br_seg_idx_l2_lo[brb] = br_seg_root0[brb];
			assign br_seg_idx_l2_hi[brb] = br_seg_root0[brb];
			assign br_seg_idx_l3_lo[brb] = br_seg_root0[brb];
			assign br_seg_idx_l3_hi[brb] = br_seg_root0[brb];

			assign br_seg_idx_b0_lo[brb] = br_seg_root1[brb];
			assign br_seg_idx_b0_hi[brb] = br_seg_root1[brb];
			assign br_seg_idx_b1_lo[brb] = br_seg_root1[brb];
			assign br_seg_idx_b1_hi[brb] = br_seg_root1[brb];
			assign br_seg_idx_b2_lo[brb] = br_seg_root1[brb];
			assign br_seg_idx_b2_hi[brb] = br_seg_root1[brb];
			assign br_seg_idx_b3_lo[brb] = br_seg_root1[brb];
			assign br_seg_idx_b3_hi[brb] = br_seg_root1[brb];
			assign br_seg_idx_b4_lo[brb] = br_seg_root1[brb];
			assign br_seg_idx_b4_hi[brb] = br_seg_root1[brb];
			assign br_seg_idx_b5_lo[brb] = br_seg_root1[brb];
			assign br_seg_idx_b5_hi[brb] = br_seg_root1[brb];
			assign br_seg_idx_b6_lo[brb] = br_seg_root1[brb];
			assign br_seg_idx_b6_hi[brb] = br_seg_root1[brb];
			assign br_seg_idx_b7_lo[brb] = br_seg_root1[brb];
			assign br_seg_idx_b7_hi[brb] = br_seg_root1[brb];

			assign br_seg_idx_s0[brb] = br_seg_idx[brb];
			assign br_seg_idx_s1[brb] = br_seg_idx[brb];
			assign br_seg_idx_m0[brb] = br_seg_idx[brb];
			assign br_seg_idx_m1[brb] = br_seg_idx[brb];
		end
	endgenerate
`else
	wire [3:0] br_bank_ram = {4{br_bank}};
	wire br_bank_l0_lo = br_bank, br_bank_l0_hi = br_bank, br_bank_l1_lo = br_bank, br_bank_l1_hi = br_bank;
	wire br_bank_l2 = br_bank, br_bank_l3 = br_bank;
	wire br_bank_b0 = br_bank, br_bank_b1 = br_bank, br_bank_b2 = br_bank, br_bank_b3 = br_bank;
	wire br_bank_b4 = br_bank, br_bank_b5 = br_bank, br_bank_b6 = br_bank, br_bank_b7 = br_bank;
	wire br_bank_s0 = br_bank, br_bank_s1 = br_bank, br_bank_m0 = br_bank, br_bank_m1 = br_bank;
	wire [2:0] br_seg_idx_l0_lo = br_seg_idx, br_seg_idx_l0_hi = br_seg_idx;
	wire [2:0] br_seg_idx_l1_lo = br_seg_idx, br_seg_idx_l1_hi = br_seg_idx;
	wire [2:0] br_seg_idx_l2_lo = br_seg_idx, br_seg_idx_l2_hi = br_seg_idx;
	wire [2:0] br_seg_idx_l3_lo = br_seg_idx, br_seg_idx_l3_hi = br_seg_idx;
	wire [2:0] br_seg_idx_b0_lo = br_seg_idx, br_seg_idx_b0_hi = br_seg_idx;
	wire [2:0] br_seg_idx_b1_lo = br_seg_idx, br_seg_idx_b1_hi = br_seg_idx;
	wire [2:0] br_seg_idx_b2_lo = br_seg_idx, br_seg_idx_b2_hi = br_seg_idx;
	wire [2:0] br_seg_idx_b3_lo = br_seg_idx, br_seg_idx_b3_hi = br_seg_idx;
	wire [2:0] br_seg_idx_b4_lo = br_seg_idx, br_seg_idx_b4_hi = br_seg_idx;
	wire [2:0] br_seg_idx_b5_lo = br_seg_idx, br_seg_idx_b5_hi = br_seg_idx;
	wire [2:0] br_seg_idx_b6_lo = br_seg_idx, br_seg_idx_b6_hi = br_seg_idx;
	wire [2:0] br_seg_idx_b7_lo = br_seg_idx, br_seg_idx_b7_hi = br_seg_idx;
	wire [2:0] br_seg_idx_s0 = br_seg_idx, br_seg_idx_s1 = br_seg_idx, br_seg_idx_m0 = br_seg_idx, br_seg_idx_m1 = br_seg_idx;
`endif

	wire [3:0] r_slot0 = br_bank_s0 ? meta_slot0_1[br_seg_idx_s0] : meta_slot0_0[br_seg_idx_s0];
	wire [3:0] r_slot1 = br_bank_s1 ? meta_slot1_1[br_seg_idx_s1] : meta_slot1_0[br_seg_idx_s1];
	wire r_n0slot = br_bank_m0 ? meta_n0slot_1[br_seg_idx_m0] : meta_n0slot_0[br_seg_idx_m0];
	wire [US-1:0] r_off = br_bank_m1 ? meta_off_1[br_seg_idx_m1] : meta_off_0[br_seg_idx_m1];

	wire [3:0] r_lo_slot = r_n0slot ? r_slot1 : r_slot0;
	wire [3:0] r_hi_slot = r_n0slot ? r_slot0 : r_slot1;

`ifdef SYNTH_KINTEX7
	/* Partitioned distributed RAM slices with direct FF-driven read addresses (s1_raddr0/1) */
	wire [LINE_BITS-1:0] pp_sdata0;
	wire [LINE_BITS-1:0] pp_sdata1;

	wire [1:0] r_n0slot_b;
	assign r_n0slot_b[0] = r_n0slot;
	assign r_n0slot_b[1] = r_n0slot;

	wire [3:0] r_lo_slot_g [0:3];
	wire [3:0] r_hi_slot_g [0:3];

	genvar tk, ab;
	generate
		for (tk = 0; tk < 4; tk = tk + 1) begin : g_ram_top_buf
			for (ab = 0; ab < 4; ab = ab + 1) begin : g_slot_dup
				LUT3 #(.INIT(8'hCA)) u_rlo (.I0(r_slot0[ab]), .I1(r_slot1[ab]), .I2(r_n0slot_b[tk >> 1]), .O(r_lo_slot_g[tk][ab]));
				LUT3 #(.INIT(8'hAC)) u_rhi (.I0(r_slot0[ab]), .I1(r_slot1[ab]), .I2(r_n0slot_b[tk >> 1]), .O(r_hi_slot_g[tk][ab]));
			end
		end
	endgenerate

	reg [4:0] s1_raddr0 [0:NUM_RADDR_REPS-1];
	reg [4:0] s1_raddr1 [0:NUM_RADDR_REPS-1];
	genvar rrep;
	generate
		for (rrep = 0; rrep < NUM_RADDR_REPS; rrep = rrep + 1) begin : g_s1_raddr
			localparam TK_IDX = rrep / (NUM_RADDR_REPS / 4);
			always @(posedge clk) begin
				if (br_rdy_leaf[rrep / 2]) begin
					s1_raddr0[rrep] <= {br_bank_ram[TK_IDX], r_lo_slot_g[TK_IDX]};
					s1_raddr1[rrep] <= {br_bank_ram[TK_IDX], r_hi_slot_g[TK_IDX]};
				end
			end
		end
	endgenerate

	wire [4:0] grp_waddr [0:NUM_RAM_GRPS-1];
	wire       grp_we    [0:NUM_RAM_GRPS-1];

	genvar gk;
	generate
		for (gk = 0; gk < NUM_RAM_GRPS; gk = gk + 1) begin : g_ram_grp_buf
			for (ab = 0; ab < 5; ab = ab + 1) begin : g_addr_buf
				assign grp_waddr[gk][ab] = rsp_tag[ab];
			end
			LUT4 #(.INIT(16'h0200)) u_we (
				.I0(rsp_valid), .I1(rsp_write), .I2(rsp_tag[7]), .I3(m_burst), .O(grp_we[gk])
			);
		end
	endgenerate

	wire [4:0] sl_waddr [0:NUM_RAM_SLICES-1];
	wire       sl_we    [0:NUM_RAM_SLICES-1];

	genvar sl;
	generate
		for (sl = 0; sl < NUM_RAM_SLICES; sl = sl + 1) begin : g_pp_ram
			for (ab = 0; ab < 5; ab = ab + 1) begin : g_sl_buf
				assign sl_waddr[sl][ab] = grp_waddr[sl / 8][ab];
			end
			assign sl_we[sl] = grp_we[sl / 8];

			(* ram_style = "distributed" *) reg [3:0] ram [0:31];
			always @(posedge clk) begin
				if (sl_we[sl])
					ram[sl_waddr[sl]] <= rsp_rdata[sl*4 +: 4];
			end
			assign pp_sdata0[sl*4 +: 4] = ram[s1_raddr0[sl / 4]];
			assign pp_sdata1[sl*4 +: 4] = ram[s1_raddr1[sl / 4]];
		end
	endgenerate

	/* Stage 1 -> Stage 2 barrel shifter Stage 0 (shift by 0..3 bytes) */
	wire [1:0] r_off_s0_buf [0:3];
	genvar rsb;
	generate
		for (rsb = 0; rsb < 4; rsb = rsb + 1) begin : g_roff_s0_buf
			assign r_off_s0_buf[rsb][0] = r_off[0];
			assign r_off_s0_buf[rsb][1] = r_off[1];
		end
	endgenerate

	reg [1:0] s1_s0_sel [0:PP_S0_LEAF_CNT-1];
	genvar s0l;
	generate
		for (s0l = 0; s0l < PP_S0_LEAF_CNT; s0l = s0l + 1) begin : g_s1_s0_sel
			always @(posedge clk) begin
				if (br_rdy_leaf[16 + (s0l / 8)])
					s1_s0_sel[s0l] <= r_off_s0_buf[s0l / 16];
			end
		end
	endgenerate

	wire [2*LINE_BITS-1:0] pp_both = {pp_sdata1, pp_sdata0};
	wire [7:0] pp_in_b  [0:2*LINE_BYTES-1];
	wire [7:0] pp_st0_b [0:PP_S0_OUT_BYTES-1];
	reg [7:0] s2_st0_b [0:PP_S0_OUT_BYTES-1];

	genvar pui, pi0;
	generate
		for (pui = 0; pui < 2 * LINE_BYTES; pui = pui + 1) begin : g_pp_unpack
			assign pp_in_b[pui] = pp_both[pui*8 +: 8];
		end
		for (pi0 = 0; pi0 < PP_S0_OUT_BYTES; pi0 = pi0 + 1) begin : g_pp_st0
			wire [1:0] sel0 = s1_s0_sel[pi0 / 2];
			assign pp_st0_b[pi0] = (sel0 == 2'd3) ? pp_in_b[pi0 + 3] :
			                       (sel0 == 2'd2) ? pp_in_b[pi0 + 2] :
			                       (sel0 == 2'd1) ? pp_in_b[pi0 + 1] : pp_in_b[pi0];
			always @(posedge clk) begin
				if (br_rdy_leaf[24 + (pi0 / 2)])
					s2_st0_b[pi0] <= pp_st0_b[pi0];
			end
		end
	endgenerate

	/* Stage 2 -> Stage 3 barrel shifter Stages 1 & 2 (shift by 4..12 and 16..48 bytes) */
	wire [1:0] s1_off_s1_buf [0:3];
	wire [1:0] s1_off_s2_buf [0:1];
	generate
		for (rsb = 0; rsb < 4; rsb = rsb + 1) begin : g_s1_off_s1_buf
			assign s1_off_s1_buf[rsb][0] = s1_off_hi[2];
			assign s1_off_s1_buf[rsb][1] = s1_off_hi[3];
		end
		for (rsb = 0; rsb < 2; rsb = rsb + 1) begin : g_s1_off_s2_buf
			assign s1_off_s2_buf[rsb][0] = s1_off_hi[4];
			if (LINE_BYTES >= 64) begin : g_s2o1_64
				assign s1_off_s2_buf[rsb][1] = s1_off_hi[5];
			end else begin : g_s2o1_32
				assign s1_off_s2_buf[rsb][1] = 1'b0;
			end
		end
	endgenerate

	reg [1:0] s2_s1_sel [0:PP_S1_LEAF_CNT-1];
	reg [1:0] s2_s2_sel [0:PP_S2_LEAF_CNT-1];
	genvar s1l, s2l;
	generate
		for (s1l = 0; s1l < PP_S1_LEAF_CNT; s1l = s1l + 1) begin : g_s2_s1_sel
			always @(posedge clk) begin
				if (br_rdy_leaf[86 + (s1l / 8)])
					s2_s1_sel[s1l] <= s1_off_s1_buf[s1l / 16];
			end
		end
		for (s2l = 0; s2l < PP_S2_LEAF_CNT; s2l = s2l + 1) begin : g_s2_s2_sel
			always @(posedge clk) begin
				if (br_rdy_leaf[93 + (s2l / 8)])
					s2_s2_sel[s2l] <= s1_off_s2_buf[s2l / 16];
			end
		end
	endgenerate

	wire [7:0] pp_st1_b [0:PP_S1_OUT_BYTES-1];
	wire [7:0] pp_st2_b [0:LINE_BYTES-1];
	wire [LINE_BITS-1:0] pp_copy_line;
	genvar pi1, pi2;
	generate
		for (pi1 = 0; pi1 < PP_S1_OUT_BYTES; pi1 = pi1 + 1) begin : g_pp_st1
			wire [1:0] sel1 = s2_s1_sel[pi1 / 2];
			assign pp_st1_b[pi1] = (sel1 == 2'd3) ? s2_st0_b[pi1 + 12] :
			                       (sel1 == 2'd2) ? s2_st0_b[pi1 + 8]  :
			                       (sel1 == 2'd1) ? s2_st0_b[pi1 + 4]  : s2_st0_b[pi1];
		end
		for (pi2 = 0; pi2 < LINE_BYTES; pi2 = pi2 + 1) begin : g_pp_st2
			wire [1:0] sel2 = s2_s2_sel[pi2 / 2];
			if (LINE_BYTES >= 64) begin : g_pp_s2_64
				assign pp_st2_b[pi2] = (sel2 == 2'd3) ? pp_st1_b[pi2 + 48] :
				                       (sel2 == 2'd2) ? pp_st1_b[pi2 + 32] :
				                       (sel2 == 2'd1) ? pp_st1_b[pi2 + 16] : pp_st1_b[pi2];
			end else begin : g_pp_s2_32
				assign pp_st2_b[pi2] = sel2[0] ? pp_st1_b[pi2 + 16] : pp_st1_b[pi2];
			end
			assign pp_copy_line[pi2*8 +: 8] = pp_st2_b[pi2];
		end
	endgenerate
`else
	reg [4:0] s1_raddr0_sim, s1_raddr1_sim;
	reg [US-1:0] s1_off_sim, s2_off_sim;
	reg [LINE_BITS-1:0] s2_sdata0_sim, s2_sdata1_sim;
	always @(posedge clk) begin
		if (br_pipe_rdy) begin
			s1_raddr0_sim <= {br_bank, r_lo_slot};
			s1_raddr1_sim <= {br_bank, r_hi_slot};
			s1_off_sim    <= r_off;
			s2_sdata0_sim <= pp_ram[s1_raddr0_sim];
			s2_sdata1_sim <= pp_ram[s1_raddr1_sim];
			s2_off_sim    <= s1_off_sim;
		end
	end
	wire [2*LINE_BITS-1:0] pp_both = {s2_sdata1_sim, s2_sdata0_sim};
	wire [LINE_BITS-1:0] pp_copy_line;

	generate
	if (ENABLE_SCALE != 0) begin : gen_pp_align
		atg_blt_align #(
			.LINE_BYTES(LINE_BYTES),
			.LINE_SHIFT(LINE_SHIFT)
		) pp_align (
			.in_data(pp_both),
			.off(s2_off_sim),
			.out_data(pp_copy_line)
		);
	end else begin : gen_no_pp_align
		assign pp_copy_line = s2_sdata0_sim;
	end
	endgenerate
`endif

	/* Burst requests to AMB */
	wire [US:0] issue_p_end = p_p_end;

`ifdef SYNTH_KINTEX7
	wire [US-1:0] p_dlo_lo_b0, p_dlo_lo_b1, p_dlo_lo_b2, p_dlo_lo_b3;
	wire [US:0] issue_p_end_b0, issue_p_end_b1, issue_p_end_b2, issue_p_end_b3;
	wire [3:0] m_keep_b0, m_keep_b1, m_keep_b2, m_keep_b3;
	genvar g_ib;
	generate
		for (g_ib = 0; g_ib < US; g_ib = g_ib + 1) begin : g_pdl
			assign p_dlo_lo_b0[g_ib] = p_dlo_lo[g_ib];
			assign p_dlo_lo_b1[g_ib] = p_dlo_lo[g_ib];
			assign p_dlo_lo_b2[g_ib] = p_dlo_lo[g_ib];
			assign p_dlo_lo_b3[g_ib] = p_dlo_lo[g_ib];
		end
		for (g_ib = 0; g_ib <= US; g_ib = g_ib + 1) begin : g_ipe
			assign issue_p_end_b0[g_ib] = issue_p_end[g_ib];
			assign issue_p_end_b1[g_ib] = issue_p_end[g_ib];
			assign issue_p_end_b2[g_ib] = issue_p_end[g_ib];
			assign issue_p_end_b3[g_ib] = issue_p_end[g_ib];
		end
		for (g_ib = 0; g_ib < 4; g_ib = g_ib + 1) begin : g_mkb
			assign m_keep_b0[g_ib] = m_keep[g_ib];
			assign m_keep_b1[g_ib] = m_keep[g_ib];
			assign m_keep_b2[g_ib] = m_keep[g_ib];
			assign m_keep_b3[g_ib] = m_keep[g_ib];
		end
	endgenerate
`else
	wire [US-1:0] p_dlo_lo_b0 = p_dlo_lo, p_dlo_lo_b1 = p_dlo_lo, p_dlo_lo_b2 = p_dlo_lo, p_dlo_lo_b3 = p_dlo_lo;
	wire [US:0] issue_p_end_b0 = issue_p_end, issue_p_end_b1 = issue_p_end, issue_p_end_b2 = issue_p_end, issue_p_end_b3 = issue_p_end;
	wire [3:0] m_keep_b0 = m_keep, m_keep_b1 = m_keep, m_keep_b2 = m_keep, m_keep_b3 = m_keep;
`endif

	reg [LINE_BYTES-1:0] issue_be;
	integer ib;
	always @(*) begin
		for (ib = 0; ib < 16; ib = ib + 1)
			issue_be[ib] = ib[US:0] >= {1'b0, p_dlo_lo_b0} && ib[US:0] < issue_p_end_b0 && !m_keep_b0[ib % 4];
		for (ib = 16; ib < 32; ib = ib + 1)
			issue_be[ib] = (ib < LINE_BYTES) ? (ib[US:0] >= {1'b0, p_dlo_lo_b1} && ib[US:0] < issue_p_end_b1 && !m_keep_b1[ib % 4]) : 1'b0;
		for (ib = 32; ib < 48; ib = ib + 1)
			issue_be[ib] = (ib < LINE_BYTES) ? (ib[US:0] >= {1'b0, p_dlo_lo_b2} && ib[US:0] < issue_p_end_b2 && !m_keep_b2[ib % 4]) : 1'b0;
		for (ib = 48; ib < LINE_BYTES; ib = ib + 1)
			issue_be[ib] = (ib < LINE_BYTES) ? (ib[US:0] >= {1'b0, p_dlo_lo_b3} && ib[US:0] < issue_p_end_b3 && !m_keep_b3[ib % 4]) : 1'b0;
	end

	wire bst_can_fill_p = p_valid_fill && (!bank_active[bw_bank] || !bank_closed[bw_bank]);
	wire bst_rd_need = mc_issue;

`ifdef SYNTH_KINTEX7
	wire [2:0] bws_buf;
	assign bws_buf[0] = bw_sub;
	assign bws_buf[1] = bw_sub;
	assign bws_buf[2] = bw_sub;
	wire bw_sub_lo  = bws_buf[0];
	wire bw_sub_hi  = bws_buf[1];
	wire bw_sub_ctl = bws_buf[2];
`else
	wire bw_sub_lo  = bw_sub;
	wire bw_sub_hi  = bw_sub;
	wire bw_sub_ctl = bw_sub;
`endif

	wire [LA_W-1:0] bst_rd_line_w = {
		bw_sub_hi ? p_src_n1[LA_W-1:14] : p_src_n0[LA_W-1:14],
		bw_sub_lo ? p_src_n1[13:0] : p_src_n0[13:0]
	};

	reg bst_rd_valid;
	reg [LA_W-1:0] bst_rd_line;
	reg [7:0] bst_rd_tag;

	always @(*) begin
		bst_rd_valid = 1'b0;
		bst_rd_line = bst_rd_line_w;
		bst_rd_tag = {1'b0, 2'd0, bw_bank, bw_sub_ctl ? bw_slot_p1 : bw_slot_cnt};
		if (state == S_BURST && bst_can_fill_p && bst_rd_need) begin
			bst_rd_valid = 1'b1;
		end
	end

	wire [3:0] bst_wr_line_0_lo = br_bank_l0_lo ? meta_dline_1_0[br_seg_idx_l0_lo][3:0] : meta_dline_0_0[br_seg_idx_l0_lo][3:0];
	wire [2:0] bst_wr_line_0_hi = br_bank_l0_hi ? meta_dline_1_0[br_seg_idx_l0_hi][6:4] : meta_dline_0_0[br_seg_idx_l0_hi][6:4];
	wire [6:0] bst_wr_line_0 = {bst_wr_line_0_hi, bst_wr_line_0_lo};

	wire [3:0] bst_wr_line_1_lo = br_bank_l1_lo ? meta_dline_1_1[br_seg_idx_l1_lo][3:0] : meta_dline_0_1[br_seg_idx_l1_lo][3:0];
	wire [2:0] bst_wr_line_1_hi = br_bank_l1_hi ? meta_dline_1_1[br_seg_idx_l1_hi][6:4] : meta_dline_0_1[br_seg_idx_l1_hi][6:4];
	wire [6:0] bst_wr_line_1 = {bst_wr_line_1_hi, bst_wr_line_1_lo};

	wire [3:0] bst_wr_line_2_lo = br_bank_l2 ? meta_dline_1_2[br_seg_idx_l2_lo][3:0] : meta_dline_0_2[br_seg_idx_l2_lo][3:0];
	wire [2:0] bst_wr_line_2_hi = br_bank_l2 ? meta_dline_1_2[br_seg_idx_l2_hi][6:4] : meta_dline_0_2[br_seg_idx_l2_hi][6:4];
	wire [6:0] bst_wr_line_2 = {bst_wr_line_2_hi, bst_wr_line_2_lo};

	wire [3:0] bst_wr_line_3_lo = br_bank_l3 ? meta_dline_1_3[br_seg_idx_l3_lo][3:0] : meta_dline_0_3[br_seg_idx_l3_lo][3:0];
	wire [LA_W-26:0] bst_wr_line_3_hi = br_bank_l3 ? meta_dline_1_3[br_seg_idx_l3_hi][LA_W-22:4] : meta_dline_0_3[br_seg_idx_l3_hi][LA_W-22:4];
	wire [LA_W-22:0] bst_wr_line_3 = {bst_wr_line_3_hi, bst_wr_line_3_lo};
	wire [LA_W-1:0] bst_wr_line_raw = {bst_wr_line_3, bst_wr_line_2, bst_wr_line_1, bst_wr_line_0};

	wire [3:0] bst_wr_be_0_lo = br_bank_b0 ? meta_be_1_0[br_seg_idx_b0_lo][3:0] : meta_be_0_0[br_seg_idx_b0_lo][3:0];
	wire [3:0] bst_wr_be_0_hi = br_bank_b0 ? meta_be_1_0[br_seg_idx_b0_hi][7:4] : meta_be_0_0[br_seg_idx_b0_hi][7:4];
	wire [7:0] bst_wr_be_0 = {bst_wr_be_0_hi, bst_wr_be_0_lo};

	wire [3:0] bst_wr_be_1_lo = br_bank_b1 ? meta_be_1_1[br_seg_idx_b1_lo][3:0] : meta_be_0_1[br_seg_idx_b1_lo][3:0];
	wire [3:0] bst_wr_be_1_hi = br_bank_b1 ? meta_be_1_1[br_seg_idx_b1_hi][7:4] : meta_be_0_1[br_seg_idx_b1_hi][7:4];
	wire [7:0] bst_wr_be_1 = {bst_wr_be_1_hi, bst_wr_be_1_lo};

	wire [3:0] bst_wr_be_2_lo = br_bank_b2 ? meta_be_1_2[br_seg_idx_b2_lo][3:0] : meta_be_0_2[br_seg_idx_b2_lo][3:0];
	wire [3:0] bst_wr_be_2_hi = br_bank_b2 ? meta_be_1_2[br_seg_idx_b2_hi][7:4] : meta_be_0_2[br_seg_idx_b2_hi][7:4];
	wire [7:0] bst_wr_be_2 = {bst_wr_be_2_hi, bst_wr_be_2_lo};

	wire [3:0] bst_wr_be_3_lo = br_bank_b3 ? meta_be_1_3[br_seg_idx_b3_lo][3:0] : meta_be_0_3[br_seg_idx_b3_lo][3:0];
	wire [3:0] bst_wr_be_3_hi = br_bank_b3 ? meta_be_1_3[br_seg_idx_b3_hi][7:4] : meta_be_0_3[br_seg_idx_b3_hi][7:4];
	wire [7:0] bst_wr_be_3 = {bst_wr_be_3_hi, bst_wr_be_3_lo};

	wire [3:0] bst_wr_be_4_lo = br_bank_b4 ? meta_be_1_4[br_seg_idx_b4_lo][3:0] : meta_be_0_4[br_seg_idx_b4_lo][3:0];
	wire [3:0] bst_wr_be_4_hi = br_bank_b4 ? meta_be_1_4[br_seg_idx_b4_hi][7:4] : meta_be_0_4[br_seg_idx_b4_hi][7:4];
	wire [7:0] bst_wr_be_4 = {bst_wr_be_4_hi, bst_wr_be_4_lo};

	wire [3:0] bst_wr_be_5_lo = br_bank_b5 ? meta_be_1_5[br_seg_idx_b5_lo][3:0] : meta_be_0_5[br_seg_idx_b5_lo][3:0];
	wire [3:0] bst_wr_be_5_hi = br_bank_b5 ? meta_be_1_5[br_seg_idx_b5_hi][7:4] : meta_be_0_5[br_seg_idx_b5_hi][7:4];
	wire [7:0] bst_wr_be_5 = {bst_wr_be_5_hi, bst_wr_be_5_lo};

	wire [3:0] bst_wr_be_6_lo = br_bank_b6 ? meta_be_1_6[br_seg_idx_b6_lo][3:0] : meta_be_0_6[br_seg_idx_b6_lo][3:0];
	wire [3:0] bst_wr_be_6_hi = br_bank_b6 ? meta_be_1_6[br_seg_idx_b6_hi][7:4] : meta_be_0_6[br_seg_idx_b6_hi][7:4];
	wire [7:0] bst_wr_be_6 = {bst_wr_be_6_hi, bst_wr_be_6_lo};

	wire [3:0] bst_wr_be_7_lo = br_bank_b7 ? meta_be_1_7[br_seg_idx_b7_lo][3:0] : meta_be_0_7[br_seg_idx_b7_lo][3:0];
	wire [3:0] bst_wr_be_7_hi = br_bank_b7 ? meta_be_1_7[br_seg_idx_b7_hi][7:4] : meta_be_0_7[br_seg_idx_b7_hi][7:4];
	wire [7:0] bst_wr_be_7 = {bst_wr_be_7_hi, bst_wr_be_7_lo};

	wire [LINE_BYTES-1:0] bst_wr_be_raw;
	generate
		if (LINE_BYTES >= 64) begin : g_be_wr64
			assign bst_wr_be_raw = {bst_wr_be_7, bst_wr_be_6, bst_wr_be_5, bst_wr_be_4,
			                        bst_wr_be_3, bst_wr_be_2, bst_wr_be_1, bst_wr_be_0};
		end else begin : g_be_wr32
			assign bst_wr_be_raw = {bst_wr_be_3, bst_wr_be_2, bst_wr_be_1, bst_wr_be_0};
		end
	endgenerate

	wire [LINE_BITS-1:0] bst_wr_wdata_raw;
`ifdef SYNTH_KINTEX7
	localparam NUM_BST_BYTE_BUFS = LINE_BYTES;
	wire [NUM_BST_BYTE_BUFS-1:0] mc_slice;
	genvar bwi;
	generate
		for (bwi = 0; bwi < NUM_BST_BYTE_BUFS; bwi = bwi + 1) begin : g_bst_wd
			assign mc_slice[bwi] = m_copy;
			assign bst_wr_wdata_raw[bwi*8 +: 8] = mc_slice[bwi] ? pp_copy_line[bwi*8 +: 8] : fill_line[bwi*8 +: 8];
		end
	endgenerate

	always @(posedge clk) begin
		if (br_rdy_leaf[95])  s1_line[13:0]        <= bst_wr_line_raw[13:0];
		if (br_rdy_leaf[96]) begin
			s1_line[LA_W-1:14] <= bst_wr_line_raw[LA_W-1:14];
			s1_off_hi          <= {{(6-US){1'b0}}, r_off[US-1:2]};
		end
		if (br_rdy_leaf[101]) s2_line[13:0]        <= s1_line[13:0];
		if (br_rdy_leaf[102]) s2_line[LA_W-1:14]   <= s1_line[LA_W-1:14];
		if (br_rdy_leaf[107]) s3_line[13:0]        <= s2_line[13:0];
		if (br_rdy_leaf[108]) s3_line[LA_W-1:14]   <= s2_line[LA_W-1:14];
	end
	genvar bpi;
	generate
		for (bpi = 0; bpi < LINE_BYTES / 16; bpi = bpi + 1) begin : g_s_be
			always @(posedge clk) begin
				if (br_rdy_leaf[97 + bpi])  s1_be[bpi*16 +: 16] <= bst_wr_be_raw[bpi*16 +: 16];
				if (br_rdy_leaf[103 + bpi]) s2_be[bpi*16 +: 16] <= s1_be[bpi*16 +: 16];
				if (br_rdy_leaf[109 + bpi]) s3_be[bpi*16 +: 16] <= s2_be[bpi*16 +: 16];
			end
		end
		for (bpi = 0; bpi < LINE_BITS / 16; bpi = bpi + 1) begin : g_s3_wd
			always @(posedge clk) begin
				if (br_rdy_leaf[113 + bpi]) s3_wdata[bpi*16 +: 16] <= bst_wr_wdata_raw[bpi*16 +: 16];
			end
		end
	endgenerate
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			s1_valid <= 1'b0;
			s2_valid <= 1'b0;
			s3_valid <= 1'b0;
		end else if (!is_burst_ctl0 || fail_burst) begin
			s1_valid <= 1'b0;
			s2_valid <= 1'b0;
			s3_valid <= 1'b0;
		end else if (br_rdy_leaf[145]) begin
			s1_valid <= br_active;
			s2_valid <= s1_valid;
			s3_valid <= s2_valid;
		end
	end
`else
	genvar bwi;
	generate
		for (bwi = 0; bwi < NUM_WD_BUFS; bwi = bwi + 1) begin : g_bst_wd
			assign bst_wr_wdata_raw[bwi*16 +: 16] = m_copy ? pp_copy_line[bwi*16 +: 16] : fill_line[bwi*16 +: 16];
		end
	endgenerate
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			s1_valid <= 1'b0;
			s2_valid <= 1'b0;
			s3_valid <= 1'b0;
			s1_line  <= {LA_W{1'b0}};
			s2_line  <= {LA_W{1'b0}};
			s3_line  <= {LA_W{1'b0}};
			s1_be    <= {LINE_BYTES{1'b0}};
			s2_be    <= {LINE_BYTES{1'b0}};
			s3_be    <= {LINE_BYTES{1'b0}};
			s3_wdata <= {LINE_BITS{1'b0}};
		end else if (!is_burst_ctl0 || fail_burst) begin
			s1_valid <= 1'b0;
			s2_valid <= 1'b0;
			s3_valid <= 1'b0;
		end else if (br_pipe_rdy) begin
			s1_valid <= br_active;
			s2_valid <= s1_valid;
			s3_valid <= s2_valid;
			s1_line  <= bst_wr_line_raw;
			s2_line  <= s1_line;
			s3_line  <= s2_line;
			s1_be    <= bst_wr_be_raw;
			s2_be    <= s1_be;
			s3_be    <= s2_be;
			s3_wdata <= bst_wr_wdata_raw;
		end
	end
`endif
	wire bst_wr_valid = s3_valid;
	wire [LA_W-1:0] bst_wr_line = s3_line;
	wire [LINE_BYTES-1:0] bst_wr_be = s3_be;
	wire [LINE_BITS-1:0] bst_wr_wdata = s3_wdata;
	wire [7:0] bst_wr_tag = 8'h80;

`ifdef SYNTH_KINTEX7
	wire [7:0] bwv_buf;
	genvar g_bwv_i;
	generate
		for (g_bwv_i = 0; g_bwv_i < 8; g_bwv_i = g_bwv_i + 1) begin : g_bwv
			assign bwv_buf[g_bwv_i] = bst_wr_valid;
		end
	endgenerate
	wire bwv_ln0 = bwv_buf[0];
	wire bwv_ln1 = bwv_buf[1];
	wire bwv_ln2 = bwv_buf[2];
	wire bwv_ln3 = bwv_buf[3];
	wire bwv_be0 = bwv_buf[4];
	wire bwv_be1 = bwv_buf[5];
	wire bwv_tag = bwv_buf[6];
	wire bwv_ctl = bwv_buf[7];
`else
	wire bwv_ln0 = bst_wr_valid;
	wire bwv_ln1 = bst_wr_valid;
	wire bwv_ln2 = bst_wr_valid;
	wire bwv_ln3 = bst_wr_valid;
	wire bwv_be0 = bst_wr_valid;
	wire bwv_be1 = bst_wr_valid;
	wire bwv_tag = bst_wr_valid;
	wire bwv_ctl = bst_wr_valid;
`endif
	/* AMB Arbiter: write takes precedence over read to clear buffer space */
	wire bst_wr_fire = bwv_ctl && req_ready;
	wire bst_rd_can = bst_rd_need && !bwv_ctl;
	wire bst_rd_fire = bst_rd_can && bst_can_fill_p && req_ready;
	wire bst_req_valid = bwv_ctl || bst_rd_valid;
	wire bst_req_write = bwv_ctl;
	wire [LA_W-1:0] bst_req_line = {
		bwv_ln3 ? bst_wr_line[LA_W-1:21] : bst_rd_line[LA_W-1:21],
		bwv_ln2 ? bst_wr_line[20:14]      : bst_rd_line[20:14],
		bwv_ln1 ? bst_wr_line[13:7]       : bst_rd_line[13:7],
		bwv_ln0 ? bst_wr_line[6:0]        : bst_rd_line[6:0]
	};
	wire [LINE_BYTES-1:0] bst_req_be = {
		bwv_be1 ? bst_wr_be[LINE_BYTES-1:16] : { (LINE_BYTES-16){1'b1} },
		bwv_be0 ? bst_wr_be[15:0] : 16'hFFFF
	};
	wire [LINE_BITS-1:0] bst_req_wdata = bst_wr_wdata;
	wire [7:0] bst_req_tag = bwv_tag ? bst_wr_tag : bst_rd_tag;

	wire bst_bank_ready_0 = !bank_active[0] || !bank_closed[0];
	wire bst_bank_ready_1 = !bank_active[1] || !bank_closed[1];
	wire bst_bank_ready = bw_bank ? bst_bank_ready_1 : bst_bank_ready_0;
	wire bst_rd_rdy_0 = bst_rd_can && bst_bank_ready_0 && req_ready;
	wire bst_rd_rdy_1 = bst_rd_can && bst_bank_ready_1 && req_ready;
	wire bst_rd_rdy   = bst_rd_can && bst_bank_ready && req_ready;
	wire p_two_line_cond = !p_two_lines || bw_sub;
	wire issue_rdy_0 = bst_bank_ready_0 && (!mc_issue || (bst_rd_rdy_0 && p_two_line_cond));
	wire issue_rdy_1 = bst_bank_ready_1 && (!mc_issue || (bst_rd_rdy_1 && p_two_line_cond));
	wire issue_fire_0 = p_valid_iss0 && issue_rdy_0;
	wire issue_fire_1 = p_valid_iss0 && issue_rdy_1;

	wire copy_rd_ready = !mc_issue || (!s3_valid && req_ready && (!p_two_lines || bw_sub));
	assign issue_rdy = bst_bank_ready && copy_rd_ready;
	wire issue_fire = p_valid_iss1 && issue_rdy;
`ifdef SYNTH_KINTEX7
	wire [7:0] if_buf;
	LUT3 #(.INIT(8'h80)) u_if0 (.I0(p_valid_iss1), .I1(bst_bank_ready), .I2(copy_rd_ready), .O(if_buf[0]));
	LUT3 #(.INIT(8'h80)) u_if1 (.I0(p_valid_iss1), .I1(bst_bank_ready), .I2(copy_rd_ready), .O(if_buf[1]));
	LUT3 #(.INIT(8'h80)) u_if2 (.I0(p_valid_iss1), .I1(bst_bank_ready), .I2(copy_rd_ready), .O(if_buf[2]));
	LUT3 #(.INIT(8'h80)) u_if3 (.I0(p_valid_iss1), .I1(bst_bank_ready), .I2(copy_rd_ready), .O(if_buf[3]));
	LUT3 #(.INIT(8'h80)) u_if4 (.I0(p_valid_iss1), .I1(bst_bank_ready), .I2(copy_rd_ready), .O(if_buf[4]));
	LUT3 #(.INIT(8'h80)) u_if5 (.I0(p_valid_iss1), .I1(bst_bank_ready), .I2(copy_rd_ready), .O(if_buf[5]));
	LUT3 #(.INIT(8'h80)) u_if6 (.I0(p_valid_iss1), .I1(bst_bank_ready), .I2(copy_rd_ready), .O(if_buf[6]));
	LUT3 #(.INIT(8'h80)) u_if7 (.I0(p_valid_iss1), .I1(bst_bank_ready), .I2(copy_rd_ready), .O(if_buf[7]));
	wire issue_fire_m0_e01 = if_buf[0];
	wire issue_fire_m0_e23 = if_buf[1];
	wire issue_fire_m0_e45 = if_buf[2];
	wire issue_fire_m0_e67 = if_buf[3];
	wire issue_fire_m1_e01 = if_buf[4];
	wire issue_fire_m1_e23 = if_buf[5];
	wire issue_fire_m1_e45 = if_buf[6];
	wire issue_fire_m1_e67 = if_buf[7];
`else
	wire issue_fire_m0_e01 = issue_fire, issue_fire_m0_e23 = issue_fire;
	wire issue_fire_m0_e45 = issue_fire, issue_fire_m0_e67 = issue_fire;
	wire issue_fire_m1_e01 = issue_fire, issue_fire_m1_e23 = issue_fire;
	wire issue_fire_m1_e45 = issue_fire, issue_fire_m1_e67 = issue_fire;
`endif
	wire issue_fire_m0 = issue_fire_m0_e01;
	wire issue_fire_m1 = issue_fire_m1_e01;

	assign bank_close_fire_0 = issue_fire_0 && bank_close_cond && !bw_bank;
	assign bank_close_fire_1 = issue_fire_1 && bank_close_cond && bw_bank;
	assign bank_close_fire = issue_fire && bank_close_cond;
	wire step_p = skid_in_ready;
	wire g_ready = !g_valid || step_p;
`ifdef SYNTH_KINTEX7
	wire walk_step_ws  = is_burst && !bw_walk_done && g_ready;
	wire walk_step_ctl = is_burst && !bw_walk_done && g_ready;
	wire walk_step_rs  = is_burst && !bw_walk_done && g_ready;

	wire walk_step = walk_step_ctl;
	wire row_step = walk_step_ctl && bsl_ctl;
	wire walk_step_a = walk_step_rs;
	wire walk_step_b = walk_step_ctl;

	wire [4:0] glen_buf;
	wire [5:0] sp_buf;
	wire [5:0] rst_buf;
	wire [11:0] ws_buf;
	genvar g_bi;
	generate
		for (g_bi = 0; g_bi < 5; g_bi = g_bi + 1) begin : g_buf_glen
			assign glen_buf[g_bi] = walk_step_ctl;
		end
		for (g_bi = 0; g_bi < 6; g_bi = g_bi + 1) begin : g_buf6
			assign sp_buf[g_bi] = step_p;
		end
		for (g_bi = 0; g_bi < 6; g_bi = g_bi + 1) begin : g_buf_rs
			LUT3 #(.INIT(8'h40)) u_rs (.I0(cmp_last_bo), .I1(rem_b_small), .I2(walk_step_rs), .O(rst_buf[g_bi]));
		end
		for (g_bi = 0; g_bi < 12; g_bi = g_bi + 1) begin : g_buf_ws
			assign ws_buf[g_bi] = walk_step_ws;
		end
	endgenerate
	wire g_len_da0 = glen_buf[0];
	wire g_len_da1 = glen_buf[1];
	wire g_len_sa0 = glen_buf[2];
	wire g_len_sa1 = glen_buf[3];
	wire g_len_ctl = glen_buf[4];

	wire sp_dl0 = sp_buf[0];
	wire sp_dl1 = sp_buf[1];
	wire sp_s00 = sp_buf[2];
	wire sp_s01 = sp_buf[3];
	wire sp_s10 = sp_buf[4];
	wire sp_s11 = sp_buf[5];
	wire sp_ctl = step_p;

	wire rst_dst0 = rst_buf[0];
	wire rst_dst1 = rst_buf[1];
	wire rst_src0 = rst_buf[2];
	wire rst_src1 = rst_buf[3];
	wire rst_ctl0 = rst_buf[4];
	wire rst_ctl1 = rst_buf[5];
	wire rst_row  = 1'b0;

	wire ws_px0  = ws_buf[0];
	wire ws_px1  = ws_buf[1];
	wire ws_spx0 = ws_buf[2];
	wire ws_spx1 = ws_buf[3];
	wire ws_rem0 = ws_buf[4];
	wire ws_rem1 = ws_buf[5];
	wire ws_ctl  = ws_buf[6];
	wire ws_gctl = ws_buf[7];
	wire ws_dxb0 = ws_buf[8];
	wire ws_dxb1 = ws_buf[9];
	wire ws_sxb0 = ws_buf[10];
	wire ws_sxb1 = ws_buf[11];
	wire ws_walk = walk_step;
`else
	wire walk_step = is_burst && !bw_walk_done && g_ready;
	wire row_step = walk_step && bsl_ctl;
	wire walk_step_a = walk_step, walk_step_b = walk_step;
	wire g_len_da0 = walk_step, g_len_da1 = walk_step;
	wire g_len_sa0 = walk_step, g_len_sa1 = walk_step;
	wire g_len_ctl = walk_step;
	wire sp_dl0 = step_p, sp_dl1 = step_p;
	wire sp_s00 = step_p, sp_s01 = step_p;
	wire sp_s10 = step_p, sp_s11 = step_p;
	wire sp_ctl = step_p;
	wire rst_dst0 = row_step, rst_dst1 = row_step;
	wire rst_src0 = row_step, rst_src1 = row_step;
	wire rst_ctl0 = row_step, rst_ctl1 = row_step;
	wire rst_row  = row_step;
	wire ws_px0  = walk_step, ws_px1  = walk_step;
	wire ws_spx0 = walk_step, ws_spx1 = walk_step;
	wire ws_rem0 = walk_step, ws_rem1 = walk_step;
	wire ws_walk = walk_step;
	wire ws_gctl = walk_step, ws_ctl  = walk_step;
	wire ws_dxb0 = walk_step, ws_dxb1 = walk_step;
	wire ws_sxb0 = walk_step, ws_sxb1 = walk_step;
`endif

	/* Mux external AMB outputs between burst and legacy port */
	assign req_valid = m_burst ? bst_req_valid : leg_req_valid;
	assign req_write = m_burst ? bst_req_write : leg_req_write;
	assign req_line  = m_burst ? bst_req_line  : leg_req_line;
	assign req_be    = m_burst ? bst_req_be    : leg_req_be;
	assign req_tag   = m_burst ? bst_req_tag   : leg_req_tag;

`ifdef SYNTH_KINTEX7
	localparam NUM_REQ_BYTE_BUFS = LINE_BYTES;
	wire [NUM_REQ_BYTE_BUFS-1:0] mb_slice;
	genvar req_i;
	generate
		for (req_i = 0; req_i < NUM_REQ_BYTE_BUFS; req_i = req_i + 1) begin : g_req_wd
			assign mb_slice[req_i] = m_burst;
			assign req_wdata[req_i*8 +: 8] = mb_slice[req_i] ? bst_req_wdata[req_i*8 +: 8] : leg_req_wdata[req_i*8 +: 8];
		end
	endgenerate
`else
	genvar req_i;
	generate
		for (req_i = 0; req_i < NUM_WD_BUFS; req_i = req_i + 1) begin : g_req_wd
			assign req_wdata[req_i*16 +: 16] = m_burst ? bst_req_wdata[req_i*16 +: 16] : leg_req_wdata[req_i*16 +: 16];
		end
	endgenerate
`endif

	assign busy = r_busy_q;
	assign fsm = (state == S_BURST || state == S_INIT || state == S_INIT1) ? 4'd15 : state[3:0];

	/* The segment's end: the next pixel, or the next row. */
	wire [16:0] sn17 = {{(16 - US){1'b0}}, sn};
	wire seg_last = r_seg_last;
	wire [ADDR_W-1:0] ext_dstride = r_dstride;
	wire [ADDR_W-1:0] ext_sstride = r_sstride;
	wire [ADDR_W-1:0] tile_step = tile_bytes(psl_leg, 1'b0);
	wire [ADDR_W-1:0] tile_back = tile_bytes(psl_leg, 1'b1);
	wire [ADDR_W-1:0] dst_back, src_back, dst_neg, src_neg;
	wire [16:0] y1_last, ys_rev;
	wire [5:0] step_co_unused;

	am_sub #(.W(ADDR_W)) s_dback (.a(ext_dstride), .b(tile_back), .bi(1'b0), .d(dst_back), .bo(step_co_unused[0]));
	am_sub #(.W(ADDR_W)) s_sback (.a(ext_sstride), .b(tile_back), .bi(1'b0), .d(src_back), .bo(step_co_unused[1]));
	am_sub #(.W(ADDR_W)) s_dneg (.a({ADDR_W{1'b0}}), .b(ext_dstride), .bi(1'b0), .d(dst_neg), .bo(step_co_unused[2]));
	am_sub #(.W(ADDR_W)) s_sneg (.a({ADDR_W{1'b0}}), .b(ext_sstride), .bi(1'b0), .d(src_neg), .bo(step_co_unused[3]));
	wire [ADDR_W-1:0] dst_step = {
		mdt_step1 ? (ydl == 2'd3 ? r_dst_back[ADDR_W-1:16] : r_tile_step[ADDR_W-1:16]) : ext_dstride[ADDR_W-1:16],
		mdt_step0 ? (ydl == 2'd3 ? r_dst_back[15:0]        : r_tile_step[15:0])        : ext_dstride[15:0]
	};
	wire [ADDR_W-1:0] src_step = {
		mst_step1 ? (ysl == 2'd3 ? r_src_back[ADDR_W-1:16] : r_tile_step[ADDR_W-1:16]) : ext_sstride[ADDR_W-1:16],
		mst_step0 ? (ysl == 2'd3 ? r_src_back[15:0]        : r_tile_step[15:0])        : ext_sstride[15:0]
	};

	/* S_START: the first row (the last one when reversed). */
	am_sub #(.W(17)) s_y1 (.a(y1), .b(17'd0), .bi(1'b1), .d(y1_last), .bo(step_co_unused[4]));
	am_add #(.W(17)) a_ys (.a(sy0), .b(rows), .ci(1'b0), .s(ys_rev), .co(step_co_unused[5]));
	wire [16:0] yd_start = {mr_yd1 ? y1_last[16:8] : y0[16:8], mr_yd0 ? y1_last[7:0] : y0[7:0]};
	wire [16:0] ys_start = {mr_ys1 ? ys_rev[16:8] : sy0[16:8], mr_ys0 ? ys_rev[7:0] : sy0[7:0]};
	wire row_go = (state == S_START1);
`ifdef SYNTH_KINTEX7
	wire d_row_go, s_row_go;
	assign d_row_go = row_go;
	assign s_row_go = row_go;
`else
	wire d_row_go = row_go;
	wire s_row_go = row_go;
`endif
	wire row_add = state == S_WR && wr_go && sl_row;

	wire [ADDR_W-1:0] dst_row, src_row;
	wire d_idle, s_idle;

	/* The first row's address within its tile row: (y mod 4) x 4 pixels, in bytes. */
	wire [31:0] d_first, s_first;
	wire [1:0] first_co_unused;

	wire [7:0] dt_base = mdt_h ? {4'b0000, y0[1:0], 2'b00} : 8'd0;
	wire [7:0] d_in_tile_8_comb = (psl_leg == 3'd4) ? {dt_base[3:0], 4'b0000} :
	                              (psl_leg == 3'd3) ? {dt_base[4:0], 3'b000}  :
	                              (psl_leg == 3'd2) ? {dt_base[5:0], 2'b00}   :
	                              (psl_leg == 3'd1) ? {dt_base[6:0], 1'b0}    : dt_base;

`ifdef SYNTH_KINTEX7
	wire [7:0] st_base_clip = mst_h ? {4'b0000, c_sy0[1:0], 2'b00} : 8'd0;
	wire [7:0] s_in_tile_8_comb = (psl_leg == 3'd4) ? {st_base_clip[3:0], 4'b0000} :
	                              (psl_leg == 3'd3) ? {st_base_clip[4:0], 3'b000}  :
	                              (psl_leg == 3'd2) ? {st_base_clip[5:0], 2'b00}   :
	                              (psl_leg == 3'd1) ? {st_base_clip[6:0], 1'b0}    : st_base_clip;
	reg [7:0] r_d_in_tile_8, r_s_in_tile_8;
	always @(posedge clk) begin
		if (cl_sy) begin
			r_d_in_tile_8 <= d_in_tile_8_comb;
			r_s_in_tile_8 <= s_in_tile_8_comb;
		end
	end
	wire [7:0] d_in_tile_8 = r_d_in_tile_8;
	wire [7:0] s_in_tile_8 = r_s_in_tile_8;
`else
	wire [7:0] st_base = mst_h ? {4'b0000, sy0[1:0], 2'b00} : 8'd0;
	wire [7:0] s_in_tile_8_comb = (psl_leg == 3'd4) ? {st_base[3:0], 4'b0000} :
	                              (psl_leg == 3'd3) ? {st_base[4:0], 3'b000}  :
	                              (psl_leg == 3'd2) ? {st_base[5:0], 2'b00}   :
	                              (psl_leg == 3'd1) ? {st_base[6:0], 1'b0}    : st_base;
	wire [7:0] d_in_tile_8 = d_in_tile_8_comb;
	wire [7:0] s_in_tile_8 = s_in_tile_8_comb;
`endif

	wire d_first_co, s_first_co;
	am_add #(.W(8))  a_df_lo (.a(r_dbase[7:0]), .b(d_in_tile_8), .ci(1'b0), .s(d_first[7:0]), .co(d_first_co));
	am_add #(.W(24)) a_df_hi (.a(r_dbase[31:8]), .b(24'd0), .ci(d_first_co), .s(d_first[31:8]), .co(first_co_unused[0]));
	am_add #(.W(8))  a_sf_lo (.a(r_sbase[7:0]), .b(s_in_tile_8), .ci(1'b0), .s(s_first[7:0]), .co(s_first_co));
	am_add #(.W(24)) a_sf_hi (.a(r_sbase[31:8]), .b(24'd0), .ci(s_first_co), .s(s_first[31:8]), .co(first_co_unused[1]));

	reg [31:0] r_dacc_step, r_sacc_step;
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			r_dacc_step <= 32'd0;
			r_sacc_step <= 32'd0;
		end else begin
			r_dacc_step <= {mr_dacc_hi ? r_dst_neg[31:16] : dst_step[31:16], mr_dacc_m0 ? r_dst_neg[15:8] : dst_step[15:8], mr_dacc_lo ? r_dst_neg[7:0] : dst_step[7:0]};
`ifdef SYNTH_KINTEX7
			r_sacc_step <= {mr_sacc_h1 ? r_src_neg[31:24] : src_step[31:24], mr_sacc_h0 ? r_src_neg[23:16] : src_step[23:16], mr_sacc_m0 ? r_src_neg[15:8] : src_step[15:8], mr_sacc_lo ? r_src_neg[7:0] : src_step[7:0]};
`else
			r_sacc_step <= {mr_sacc_hi ? r_src_neg[31:16] : src_step[31:16], mr_sacc_m0 ? r_src_neg[15:8] : src_step[15:8], mr_sacc_lo ? r_src_neg[7:0] : src_step[7:0]};
`endif
		end
	end

	atg_blt_acc dacc (
		.clk(clk), .rst_n(rst_n), .go(d_row_go),
		.y(r_yd_start), .s(r_dstride),
		.b(r_d_first),
		.add(row_add), .d(r_dacc_step), .r(dst_row), .idle(d_idle)
	);
	atg_blt_acc sacc (
		.clk(clk), .rst_n(rst_n), .go(s_row_go),
		.y(r_ys_start), .s(r_sstride),
		.b(r_s_first),
		.add(row_add), .d(r_sacc_step), .r(src_row), .idle(s_idle)
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
	assign fsm_co_unused[23:20] = 4'd0;
	assign fsm_co_unused[7] = 1'b0;

	wire cx_empty = (x1 <= x0);
	wire cy_empty = (y1 <= y0);
	wire [16:0] unused_x_d;
	am_sub #(.W(17)) s_w (.a(x1), .b(x0), .bi(1'b0), .d(c_width), .bo(fsm_co_unused[0]));
	am_sub #(.W(17)) s_xempty (.a(x1), .b(x0), .bi(1'b1), .d(unused_x_d), .bo(fsm_co_unused[19]));
	am_sub #(.W(17)) s_rows (.a(y1), .b(y0), .bi(1'b1), .d(c_rows), .bo(fsm_co_unused[1]));
	assign empty = cx_empty || cy_empty;
	wire rows_init_zero = (c_rows == 17'd0) || cy_empty;
	am_sub #(.W(17)) s_cdx (.a(x0), .b(dx), .bi(1'b0), .d(c_dx), .bo(fsm_co_unused[2]));
	am_sub #(.W(17)) s_cdy (.a(y0), .b(dy), .bi(1'b0), .d(c_dy), .bo(fsm_co_unused[3]));
	am_add #(.W(17)) a_sx0 (.a({1'b0, s_src_xy[15:0]}), .b(c_dx), .ci(1'b0), .s(c_sx0), .co(fsm_co_unused[4]));
	am_add #(.W(17)) a_sy0 (.a({1'b0, s_src_xy[31:16]}), .b(c_dy), .ci(1'b0), .s(c_sy0), .co(fsm_co_unused[5]));
	am_sub #(.W(17)) s_x1 (.a(x1), .b(17'd0), .bi(1'b1), .d(x1_last), .bo(fsm_co_unused[6]));
	am_add #(.W(17)) a_slast (.a(sx0), .b(width_m1), .ci(1'b0), .s(s_last), .co(fsm_co_unused[8]));
	assign d_px = x_pixels(px, mdt_px);
	assign s_px = x_pixels(spx, mst_px);
	am_shift #(.W(ADDR_W), .SW(3)) h_dx (.a(d_px), .amt(psl_dx), .left(1'b1), .arith(1'b0), .y(d_xb));
	am_shift #(.W(ADDR_W), .SW(3)) h_sx (.a(s_px), .amt(psl_sx), .left(1'b1), .arith(1'b0), .y(s_xb));
	am_add #(.W(ADDR_W)) a_da (.a(dst_row), .b(d_xb), .ci(1'b0), .s(d_addr), .co(fsm_co_unused[9]));
	am_add #(.W(ADDR_W)) a_sa (.a(src_row), .b(s_xb), .ci(1'b0), .s(s_addr), .co(fsm_co_unused[10]));

	am_shift #(.W(US + 1), .SW(3)) h_sn (.a(seg_n), .amt(psl_leg), .left(1'b1), .arith(1'b0), .y(seg_bytes));
	am_sub #(.W(ADDR_W)) s_dlo (.a(da), .b(r_leg_back), .bi(1'b0), .d(d_lo), .bo(fsm_co_unused[11]));
	am_sub #(.W(ADDR_W)) s_slo (.a(sa), .b(r_leg_back), .bi(1'b0), .d(s_lo), .bo(fsm_co_unused[12]));
	wire [LA_W-1:0] dlo_line = dlo[ADDR_W-1:US];
	wire [LA_W-1:0] slo_line = slo[ADDR_W-1:US];
	am_add #(.W(2)) a_ydl (.a(ydl), .b(2'd0), .ci(1'b1), .s(ydl_inc), .co(fsm_co_unused[13]));
	am_add #(.W(2)) a_ysl (.a(ysl), .b(2'd0), .ci(1'b1), .s(ysl_inc), .co(fsm_co_unused[14]));
	am_sub #(.W(17)) s_rdec (.a(rows), .b(17'd0), .bi(1'b1), .d(rows_dec), .bo(fsm_co_unused[15]));
	am_addsub #(.W(17)) as_px (.a(px), .b(sn17), .sub(r_mr_px), .s(px_next), .co(fsm_co_unused[16]));
	am_addsub #(.W(17)) as_spx (.a(spx), .b(sn17), .sub(r_mr_spx), .s(spx_next), .co(fsm_co_unused[17]));
	am_sub #(.W(17)) s_rem (.a(rem), .b(sn17), .bi(1'b0), .d(rem_next), .bo(fsm_co_unused[18]));

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
`ifdef SYNTH_KINTEX7
	wire [2:0] ydl_3_buf, ysl_3_buf;
	assign ydl_3_buf[0] = ydl_b_is_3_hi;
	assign ydl_3_buf[1] = ydl_b_is_3_hi;
	assign ydl_3_buf[2] = ydl_b_is_3_hi;
	assign ysl_3_buf[0] = ysl_b_is_3;
	assign ysl_3_buf[1] = ysl_b_is_3;
	assign ysl_3_buf[2] = ysl_b_is_3;
	wire ydl_is_3_lo  = ydl_3_buf[0];
	wire ydl_is_3_hi  = ydl_3_buf[1];
	wire ydl_is_3_cur = ydl_3_buf[2];
	wire ysl_is_3_lo  = ysl_3_buf[0];
	wire ysl_is_3_hi  = ysl_3_buf[1];
	wire ysl_is_3_cur = ysl_3_buf[2];
`else
	wire ydl_is_3_lo  = ydl_b_is_3_hi;
	wire ydl_is_3_hi  = ydl_b_is_3_hi;
	wire ydl_is_3_cur = ydl_b_is_3_hi;
	wire ysl_is_3_lo  = ysl_b_is_3;
	wire ysl_is_3_hi  = ysl_b_is_3;
	wire ysl_is_3_cur = ysl_b_is_3;
`endif
	wire [ADDR_W-1:0] b_dst_step_norm = {
		mdt_bstep1 ? r_tile_step[ADDR_W-1:16] : ext_dstride[ADDR_W-1:16],
		mdt_bstep0 ? r_tile_step[15:0]        : ext_dstride[15:0]
	};
	wire [ADDR_W-1:0] b_dst_step_back = {
		mdt_bstep1 ? r_dst_back[ADDR_W-1:16]  : ext_dstride[ADDR_W-1:16],
		mdt_bstep0 ? r_dst_back[15:0]         : ext_dstride[15:0]
	};
	wire [ADDR_W-1:0] b_dst_delta_norm = {
		mr_walk_dt1 ? r_dst_neg[ADDR_W-1:16] : b_dst_step_norm[ADDR_W-1:16],
		mr_walk_dt0 ? r_dst_neg[15:0]        : b_dst_step_norm[15:0]
	};
	wire [ADDR_W-1:0] b_dst_delta_back = {
		mr_walk_dt3 ? r_dst_neg[ADDR_W-1:16] : b_dst_step_back[ADDR_W-1:16],
		mr_walk_dt2 ? r_dst_neg[15:0]        : b_dst_step_back[15:0]
	};
	wire [ADDR_W-1:0] b_dst_delta = {
		ydl_is_3_hi ? r_dst_delta_back[ADDR_W-1:16] : r_dst_delta_norm[ADDR_W-1:16],
		ydl_is_3_lo ? r_dst_delta_back[15:0]         : r_dst_delta_norm[15:0]
	};
	wire [ADDR_W-1:0] b_src_step_norm = {
		mst_bstep1 ? r_tile_step[ADDR_W-1:16] : ext_sstride[ADDR_W-1:16],
		mst_bstep0 ? r_tile_step[15:0]        : ext_sstride[15:0]
	};
	wire [ADDR_W-1:0] b_src_step_back = {
		mst_bstep1 ? r_src_back[ADDR_W-1:16]  : ext_sstride[ADDR_W-1:16],
		mst_bstep0 ? r_src_back[15:0]         : ext_sstride[15:0]
	};
	wire [ADDR_W-1:0] b_src_delta_norm = {
		mr_walk_st1 ? r_src_neg[ADDR_W-1:16] : b_src_step_norm[ADDR_W-1:16],
		mr_walk_st0 ? r_src_neg[15:0]        : b_src_step_norm[15:0]
	};
	wire [ADDR_W-1:0] b_src_delta_back = {
		mr_walk_st3 ? r_src_neg[ADDR_W-1:16] : b_src_step_back[ADDR_W-1:16],
		mr_walk_st2 ? r_src_neg[15:0]        : b_src_step_back[15:0]
	};
	wire [ADDR_W-1:0] b_src_delta = {
		ysl_is_3_hi ? r_src_delta_back[ADDR_W-1:16] : r_src_delta_norm[ADDR_W-1:16],
		ysl_is_3_lo ? r_src_delta_back[15:0]         : r_src_delta_norm[15:0]
	};
	am_add #(.W(ADDR_W)) a_drb (.a(dst_row_b), .b(b_dst_delta), .ci(1'b0), .s(dst_row_b_next), .co(bst_co_unused[7]));
	am_add #(.W(ADDR_W)) a_srb (.a(src_row_b), .b(b_src_delta), .ci(1'b0), .s(src_row_b_next), .co(bst_co_unused[8]));

`ifdef SYNTH_KINTEX7
	wire [6:0] bwb_buf;
	genvar bwi_k;
	generate
		for (bwi_k = 0; bwi_k < 7; bwi_k = bwi_k + 1) begin : g_bwb
			assign bwb_buf[bwi_k] = bw_bank;
		end
	endgenerate
	wire bw_bank_meta_e01 = bwb_buf[0];
	wire bw_bank_meta_e23 = bwb_buf[1];
	wire bw_bank_meta_e45 = bwb_buf[2];
	wire bw_bank_meta_e67 = bwb_buf[3];
	wire bw_bank_req      = bwb_buf[4];
	wire bw_bank_br0      = bwb_buf[5];
	wire bw_bank_br1      = bwb_buf[6];
`else
	wire bw_bank_meta_e01 = bw_bank;
	wire bw_bank_meta_e23 = bw_bank;
	wire bw_bank_meta_e45 = bw_bank;
	wire bw_bank_meta_e67 = bw_bank;
	wire bw_bank_req      = bw_bank;
	wire bw_bank_br0      = bw_bank;
	wire bw_bank_br1      = bw_bank;
`endif
	wire bw_bank_meta     = bw_bank_meta_e01;

	wire rsp_rd_bst = rsp_valid && !rsp_write && m_burst && (rsp_tag[7] == 1'b0);
	am_add #(.W(5)) a_brdp0 (.a(bank_rd_pending_0), .b(5'd0), .ci(bst_rd_fire && (bw_bank_br0 == 1'b0)), .s(brdp0_up), .co(bst_co_unused[9]));
	am_sub #(.W(5)) s_brdp0 (.a(brdp0_up), .b(5'd0), .bi(rsp_rd_bst && (rsp_tag[4] == 1'b0)), .d(brdp0_next), .bo(bst_co_unused[10]));
	am_add #(.W(5)) a_brdp1 (.a(bank_rd_pending_1), .b(5'd0), .ci(bst_rd_fire && (bw_bank_br1 == 1'b1)), .s(brdp1_up), .co(bst_co_unused[11]));
	am_sub #(.W(5)) s_brdp1 (.a(brdp1_up), .b(5'd0), .bi(rsp_rd_bst && (rsp_tag[4] == 1'b1)), .d(brdp1_next), .bo(bst_co_unused[12]));

	wire brdp0_is_zero = (bank_rd_pending_0 == 5'd0) ||
	                     (bank_rd_pending_0 == 5'd1 && rsp_rd_bst && (rsp_tag[4] == 1'b0));
	wire brdp1_is_zero = (bank_rd_pending_1 == 5'd0) ||
	                     (bank_rd_pending_1 == 5'd1 && rsp_rd_bst && (rsp_tag[4] == 1'b1));

	wire rsp_wr_bst = rsp_valid && rsp_write && m_burst;
	am_add #(.W(5)) a_bwr (.a(burst_wr_out), .b(5'd0), .ci(bst_wr_fire), .s(bwr_up), .co(bst_co_unused[13]));
	am_sub #(.W(5)) s_bwr (.a(bwr_up), .b(5'd0), .bi(rsp_wr_bst), .d(bwr_next), .bo(bst_co_unused[14]));

`ifdef SYNTH_KINTEX7
	reg r_burst_drain_done;
	always @(posedge clk) begin
		if (rst_b2d_high)
			r_burst_drain_done <= 1'b0;
		else
			r_burst_drain_done <= (state == S_BURST) && b_draining && !s1_valid && !s2_valid && !s3_valid && (burst_wr_out == 5'd0) && !rsp_valid;
	end
	wire burst_drain_done = r_burst_drain_done;
`else
	wire burst_drain_done = b_draining && !s1_valid && !s2_valid && !s3_valid && bwr_next == 5'd0 && !rsp_valid;
`endif

	/* Mode determination at kick */
	wire is_smear = (sbase_u == dbase_u) && !o_rev && ({1'b0, s_src_xy[15:0]} < clip_x0);
	wire op_burst = !o_blend && !is_smear;

`ifdef SYNTH_KINTEX7
	wire [3:0] bsc_b0, bsc_b1;
	wire [3:0] bscp1_b0, bscp1_b1;
	genvar bi;
	generate
		for (bi = 0; bi < 4; bi = bi + 1) begin : g_bsc_buf
			assign bsc_b0[bi] = bw_slot_cnt[bi];
			assign bsc_b1[bi] = bw_slot_cnt[bi];
			assign bscp1_b0[bi] = bw_slot_p1[bi];
			assign bscp1_b1[bi] = bw_slot_p1[bi];
		end
	endgenerate
`else
	wire [3:0] bsc_b0 = bw_slot_cnt;
	wire [3:0] bsc_b1 = bw_slot_cnt;
	wire [3:0] bscp1_b0 = bw_slot_p1;
	wire [3:0] bscp1_b1 = bw_slot_p1;
`endif

	/* Split metadata writes to ensure clock enable fanouts <= 16 */
	wire [63:0] issue_be_64 = {{(64 - LINE_BYTES){1'b0}}, issue_be};

	genvar mk;
	generate
		for (mk = 0; mk < 8; mk = mk + 1) begin : g_meta_entry
			wire mk_bw_meta = (mk < 2) ? bw_bank_meta_e01 :
			                  (mk < 4) ? bw_bank_meta_e23 :
			                  (mk < 6) ? bw_bank_meta_e45 : bw_bank_meta_e67;
			wire mk_if_m0   = (mk < 2) ? issue_fire_m0_e01 :
			                  (mk < 4) ? issue_fire_m0_e23 :
			                  (mk < 6) ? issue_fire_m0_e45 : issue_fire_m0_e67;
			wire mk_if_m1   = (mk < 2) ? issue_fire_m1_e01 :
			                  (mk < 4) ? issue_fire_m1_e23 :
			                  (mk < 6) ? issue_fire_m1_e45 : issue_fire_m1_e67;

`ifdef SYNTH_KINTEX7
			wire we0_dl0, we0_dl1, we0_be0, we0_be1, we0_ct;
			wire we1_dl0, we1_dl1, we1_be0, we1_be1, we1_ct;
			LUT3 #(.INIT(8'h20)) u_w0_dl0 (.I0(bw_seg_onehot[mk]), .I1(mk_bw_meta), .I2(mk_if_m0), .O(we0_dl0));
			LUT3 #(.INIT(8'h20)) u_w0_dl1 (.I0(bw_seg_onehot[mk]), .I1(mk_bw_meta), .I2(mk_if_m0), .O(we0_dl1));
			LUT3 #(.INIT(8'h20)) u_w0_be0 (.I0(bw_seg_onehot[mk]), .I1(mk_bw_meta), .I2(mk_if_m0), .O(we0_be0));
			LUT3 #(.INIT(8'h20)) u_w0_be1 (.I0(bw_seg_onehot[mk]), .I1(mk_bw_meta), .I2(mk_if_m0), .O(we0_be1));
			LUT3 #(.INIT(8'h20)) u_w0_ct  (.I0(bw_seg_onehot[mk]), .I1(mk_bw_meta), .I2(mk_if_m0), .O(we0_ct));

			LUT3 #(.INIT(8'h80)) u_w1_dl0 (.I0(bw_seg_onehot[mk]), .I1(mk_bw_meta), .I2(mk_if_m1), .O(we1_dl0));
			LUT3 #(.INIT(8'h80)) u_w1_dl1 (.I0(bw_seg_onehot[mk]), .I1(mk_bw_meta), .I2(mk_if_m1), .O(we1_dl1));
			LUT3 #(.INIT(8'h80)) u_w1_be0 (.I0(bw_seg_onehot[mk]), .I1(mk_bw_meta), .I2(mk_if_m1), .O(we1_be0));
			LUT3 #(.INIT(8'h80)) u_w1_be1 (.I0(bw_seg_onehot[mk]), .I1(mk_bw_meta), .I2(mk_if_m1), .O(we1_be1));
			LUT3 #(.INIT(8'h80)) u_w1_ct  (.I0(bw_seg_onehot[mk]), .I1(mk_bw_meta), .I2(mk_if_m1), .O(we1_ct));
`else
			wire we0_dl0 = mk_if_m0 && !mk_bw_meta && bw_seg_onehot[mk];
			wire we0_dl1 = mk_if_m0 && !mk_bw_meta && bw_seg_onehot[mk];
			wire we0_be0 = mk_if_m0 && !mk_bw_meta && bw_seg_onehot[mk];
			wire we0_be1 = mk_if_m0 && !mk_bw_meta && bw_seg_onehot[mk];
			wire we0_ct  = mk_if_m0 && !mk_bw_meta && bw_seg_onehot[mk];

			wire we1_dl0 = mk_if_m1 && mk_bw_meta && bw_seg_onehot[mk];
			wire we1_dl1 = mk_if_m1 && mk_bw_meta && bw_seg_onehot[mk];
			wire we1_be0 = mk_if_m1 && mk_bw_meta && bw_seg_onehot[mk];
			wire we1_be1 = mk_if_m1 && mk_bw_meta && bw_seg_onehot[mk];
			wire we1_ct  = mk_if_m1 && mk_bw_meta && bw_seg_onehot[mk];
`endif
			always @(posedge clk) begin
				if (we0_dl0) begin
					meta_dline_0_0[mk] <= p_dline[6:0];
					meta_dline_0_1[mk] <= p_dline[13:7];
				end
				if (we0_dl1) begin
					meta_dline_0_2[mk] <= p_dline[20:14];
					meta_dline_0_3[mk] <= p_dline[LA_W-1:21];
				end
				if (we0_be0) begin
					meta_be_0_0[mk] <= issue_be_64[7:0];
					meta_be_0_1[mk] <= issue_be_64[15:8];
				end
				if (we0_be1) begin
					meta_be_0_2[mk] <= issue_be_64[23:16];
					meta_be_0_3[mk] <= issue_be_64[31:24];
					if (LINE_BYTES >= 64) begin
						meta_be_0_4[mk] <= issue_be_64[39:32];
						meta_be_0_5[mk] <= issue_be_64[47:40];
						meta_be_0_6[mk] <= issue_be_64[55:48];
						meta_be_0_7[mk] <= issue_be_64[63:56];
					end
				end
				if (we0_ct) begin
					meta_slot0_0[mk]  <= bsc_b0;
					meta_slot1_0[mk]  <= p_two_lines ? bscp1_b0 : bsc_b0;
					meta_off_0[mk]    <= p_off;
					meta_n0slot_0[mk] <= p_n0_slot;
				end

				if (we1_dl0) begin
					meta_dline_1_0[mk] <= p_dline[6:0];
					meta_dline_1_1[mk] <= p_dline[13:7];
				end
				if (we1_dl1) begin
					meta_dline_1_2[mk] <= p_dline[20:14];
					meta_dline_1_3[mk] <= p_dline[LA_W-1:21];
				end
				if (we1_be0) begin
					meta_be_1_0[mk] <= issue_be_64[7:0];
					meta_be_1_1[mk] <= issue_be_64[15:8];
				end
				if (we1_be1) begin
					meta_be_1_2[mk] <= issue_be_64[23:16];
					meta_be_1_3[mk] <= issue_be_64[31:24];
					if (LINE_BYTES >= 64) begin
						meta_be_1_4[mk] <= issue_be_64[39:32];
						meta_be_1_5[mk] <= issue_be_64[47:40];
						meta_be_1_6[mk] <= issue_be_64[55:48];
						meta_be_1_7[mk] <= issue_be_64[63:56];
					end
				end
				if (we1_ct) begin
					meta_slot0_1[mk]  <= bsc_b1;
					meta_slot1_1[mk]  <= p_two_lines ? bscp1_b1 : bsc_b1;
					meta_off_1[mk]    <= p_off;
					meta_n0slot_1[mk] <= p_n0_slot;
				end
			end
		end
	endgenerate

`ifdef SYNTH_KINTEX7
	/* S_IDLE enable buffers */
	wire ce_kick = (state == S_IDLE) && kick;
	wire ce_kick_ok = ce_kick && op_ok;

	wire [15:0] ce_k_buf;
	assign ce_k_buf[0] = ce_kick;
	assign ce_k_buf[1] = ce_kick;
	assign ce_k_buf[2] = ce_kick;
	assign ce_k_buf[3] = ce_kick;
	assign ce_k_buf[4] = ce_kick;
	assign ce_k_buf[5] = ce_kick;
	assign ce_k_buf[6] = ce_kick_ok;
	assign ce_k_buf[7] = ce_kick_ok;
	assign ce_k_buf[8] = ce_kick_ok;
	assign ce_k_buf[9] = ce_kick_ok;
	assign ce_k_buf[10] = ce_kick_ok;
	assign ce_k_buf[11] = ce_kick_ok;
	assign ce_k_buf[12] = ce_kick_ok;
	assign ce_k_buf[13] = ce_kick_ok;
	assign ce_k_buf[14] = ce_kick;
	assign ce_k_buf[15] = ce_kick;
	wire ik_cfg_copy   = ce_k_buf[0];
	wire ik_cfg_dtile  = ce_k_buf[1];
	wire ik_cfg_stile  = ce_k_buf[2];
	wire ik_cfg_psl0_0 = ce_k_buf[3];
	wire ik_cfg_psl0_1 = ce_k_buf[14];
	wire ik_cfg_psl0_2 = ce_k_buf[15];
	wire ik_cfg_psl1   = ce_k_buf[4];
	wire ik_cfg_ctl    = ce_k_buf[5];
	wire ik_x0_l = ce_k_buf[6];
	wire ik_x0_h = ce_k_buf[7];
	wire ik_y0_l = ce_k_buf[8];
	wire ik_y0_h = ce_k_buf[9];
	wire ik_x1_l = ce_k_buf[10];
	wire ik_x1_h = ce_k_buf[11];
	wire ik_y1_l = ce_k_buf[12];
	wire ik_y1_h = ce_k_buf[13];

	/* S_SD enable buffers */
	wire ce_sd_raw = (state == S_SD);
	wire [6:0] ce_sd_buf;
	genvar g_sdi;
	generate
		for (g_sdi = 0; g_sdi < 7; g_sdi = g_sdi + 1) begin : g_ce_sd
			assign ce_sd_buf[g_sdi] = ce_sd_raw;
		end
	endgenerate
	wire sd_sl0 = ce_sd_buf[0];
	wire sd_sl1 = ce_sd_buf[1];
	wire sd_s00 = ce_sd_buf[2];
	wire sd_s01 = ce_sd_buf[3];
	wire sd_s10 = ce_sd_buf[4];
	wire sd_s11 = ce_sd_buf[5];
	wire sd_ctl = ce_sd_buf[6];

	/* S_WR enable buffers */
	wire [2:0] wg_buf;
	wire [4:0] sl_buf;
	genvar g_wgi;
	generate
		for (g_wgi = 0; g_wgi < 3; g_wgi = g_wgi + 1) begin : g_ce_wg
			assign wg_buf[g_wgi] = can_wr;
		end
		for (g_wgi = 0; g_wgi < 5; g_wgi = g_wgi + 1) begin : g_ce_wsl
			assign sl_buf[g_wgi] = seg_last;
		end
	endgenerate
	wire wg_px = wg_buf[0], wg_spx = wg_buf[1], wg_rem = wg_buf[2], wg_ctl = can_wr;
	wire sl_px = sl_buf[0], sl_spx = sl_buf[1], sl_rem = sl_buf[2], sl_ctl = sl_buf[3], sl_row = sl_buf[4];
	wire wg_row = can_wr;

	/* 1. S_CLIP: 14 leaves, each driving <= 17 FFs */
	wire ce_clip_raw;
	assign ce_clip_raw = state == S_CLIP;
	wire [13:0] ce_clip_l;
	genvar g_cl;
	generate
		for (g_cl = 0; g_cl < 14; g_cl = g_cl + 1) begin : g_ce_cl
			assign ce_clip_l[g_cl] = ce_clip_raw;
		end
	endgenerate
	wire cl_w   = ce_clip_l[0];
	wire cl_wm1 = ce_clip_l[13];
	wire cl_r   = ce_clip_l[1];
	wire cl_sx  = ce_clip_l[2];
	wire cl_sy  = ce_clip_l[3];
	wire cl_stp = ce_clip_l[4];
	wire cl_ds0 = ce_clip_l[5];
	wire cl_ds1 = ce_clip_l[6];
	wire cl_ss0 = ce_clip_l[7];
	wire cl_ss1 = ce_clip_l[8];
	wire cl_db0 = ce_clip_l[9];
	wire cl_db1 = ce_clip_l[10];
	wire cl_sb0 = ce_clip_l[11];
	wire cl_sb1 = ce_clip_l[12];

	/* 2. S_START: 16 leaves, each driving <= 19 FFs */
	wire ce_start_raw = (state == S_START);
	wire [3:0] ce_start_m;
	wire [15:0] ce_start_l;
	genvar g_sm, g_sl;
	generate
		for (g_sm = 0; g_sm < 4; g_sm = g_sm + 1) begin : g_ce_sm
			assign ce_start_m[g_sm] = ce_start_raw;
		end
		for (g_sl = 0; g_sl < 16; g_sl = g_sl + 1) begin : g_ce_sl
			assign ce_start_l[g_sl] = ce_start_m[g_sl / 4];
		end
	endgenerate
	wire st_px  = ce_start_l[0];
	wire st_spx = ce_start_l[1];
	wire st_db0 = ce_start_l[2];
	wire st_db1 = ce_start_l[3];
	wire st_sb0 = ce_start_l[4];
	wire st_sb1 = ce_start_l[5];
	wire st_dn0 = ce_start_l[6];
	wire st_dn1 = ce_start_l[7];
	wire st_sn0 = ce_start_l[8];
	wire st_sn1 = ce_start_l[9];
	wire st_df0 = ce_start_l[10];
	wire st_df1 = ce_start_l[11];
	wire st_sf0 = ce_start_l[12];
	wire st_sf1 = ce_start_l[13];
	wire st_yd  = ce_start_l[14];
	wire st_ys  = ce_start_l[15];

	/* 3. S_SA: 4 leaves, each driving 16 FFs */
	wire ce_sa_raw = (state == S_SA);
	wire [3:0] ce_sa_l;
	genvar g_sa_i;
	generate
		for (g_sa_i = 0; g_sa_i < 4; g_sa_i = g_sa_i + 1) begin : g_ce_sa
			assign ce_sa_l[g_sa_i] = ce_sa_raw;
		end
	endgenerate
	wire sa_da0 = ce_sa_l[0];
	wire sa_da1 = ce_sa_l[1];
	wire sa_sa0 = ce_sa_l[2];
	wire sa_sa1 = ce_sa_l[3];

	/* 4. S_SC: 4 leaves, each driving 16 FFs */
	wire ce_sc_raw = (state == S_SC);
	wire [3:0] ce_sc_l;
	genvar g_sc_i;
	generate
		for (g_sc_i = 0; g_sc_i < 4; g_sc_i = g_sc_i + 1) begin : g_ce_sc
			assign ce_sc_l[g_sc_i] = ce_sc_raw;
		end
	endgenerate
	wire sc_snu = 1'b1;
	wire sc_dlo0 = ce_sc_l[0];
	wire sc_dlo1 = ce_sc_l[1];
	wire sc_slo0 = ce_sc_l[2];
	wire sc_slo1 = ce_sc_l[3];

	/* 5. S_INIT enable buffers */
	wire ce_init_raw = (state == S_INIT);
	wire [1:0] ce_init_m;
	wire [7:0] ce_init_l;
	genvar g_inm, g_inl;
	generate
		for (g_inm = 0; g_inm < 2; g_inm = g_inm + 1) begin : g_ce_inm
			assign ce_init_m[g_inm] = ce_init_raw;
		end
		for (g_inl = 0; g_inl < 8; g_inl = g_inl + 1) begin : g_ce_inl
			assign ce_init_l[g_inl] = ce_init_m[g_inl / 4];
		end
	endgenerate
	wire in_da0 = 1'b1;
	wire in_da1 = 1'b1;
	wire in_sa0 = 1'b1;
	wire in_sa1 = 1'b1;

`else
	wire ce_kick_sim = (state == S_IDLE) && kick && op_ok;
	wire ik_cfg_copy = ce_kick_sim, ik_cfg_dtile = ce_kick_sim, ik_cfg_stile = ce_kick_sim;
	wire ik_cfg_psl0_0 = ce_kick_sim, ik_cfg_psl0_1 = ce_kick_sim, ik_cfg_psl0_2 = ce_kick_sim;
	wire ik_cfg_psl1 = ce_kick_sim, ik_cfg_ctl = ce_kick_sim;
	wire ik_x0_l = ce_kick_sim, ik_x0_h = ce_kick_sim, ik_y0_l = ce_kick_sim, ik_y0_h = ce_kick_sim;
	wire ik_x1_l = ce_kick_sim, ik_x1_h = ce_kick_sim, ik_y1_l = ce_kick_sim, ik_y1_h = ce_kick_sim;
	wire sd_sl0 = 1'b1, sd_sl1 = 1'b1, sd_s00 = 1'b1, sd_s01 = 1'b1, sd_s10 = 1'b1, sd_s11 = 1'b1, sd_ctl = 1'b1;
	wire wg_px = wr_go, wg_spx = wr_go, wg_rem = wr_go, wg_row = wr_go, wg_ctl = wr_go;
	wire sl_row = seg_last, sl_px = seg_last, sl_spx = seg_last, sl_ctl = seg_last;
	wire cl_w = 1'b1, cl_wm1 = 1'b1, cl_r = 1'b1, cl_sx = 1'b1, cl_sy = 1'b1, cl_stp = 1'b1;
	wire cl_ds0 = 1'b1, cl_ds1 = 1'b1, cl_ss0 = 1'b1, cl_ss1 = 1'b1;
	wire cl_db0 = 1'b1, cl_db1 = 1'b1, cl_sb0 = 1'b1, cl_sb1 = 1'b1;
	wire st_px = 1'b1, st_spx = 1'b1;
	wire st_db0 = 1'b1, st_db1 = 1'b1, st_sb0 = 1'b1, st_sb1 = 1'b1;
	wire st_dn0 = 1'b1, st_dn1 = 1'b1, st_sn0 = 1'b1, st_sn1 = 1'b1;
	wire st_df0 = 1'b1, st_df1 = 1'b1, st_sf0 = 1'b1, st_sf1 = 1'b1, st_yd = 1'b1, st_ys = 1'b1;
	wire sa_da0 = 1'b1, sa_da1 = 1'b1, sa_sa0 = 1'b1, sa_sa1 = 1'b1;
	wire ce_sc_sim = (state == S_SC);
	wire sc_snu = 1'b1, sc_dlo0 = ce_sc_sim, sc_dlo1 = ce_sc_sim, sc_slo0 = ce_sc_sim, sc_slo1 = ce_sc_sim;
	wire [7:0] ce_init_l = {8{state == S_INIT}};
	wire in_da0 = (state == S_INIT), in_da1 = (state == S_INIT), in_sa0 = (state == S_INIT), in_sa1 = (state == S_INIT);
`endif
	wire mb_pos = 1'b1, mb_row = 1'b1, mb_addr = 1'b1, mb_ctl = 1'b1;

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			x0 <= 17'd0;
			y0 <= 17'd0;
			x1 <= 17'd0;
			y1 <= 17'd0;
		end else begin
			if (ik_x0_l) x0[8:0]  <= clip_x0[8:0];
			if (ik_x0_h) x0[16:9] <= clip_x0[16:9];
			if (ik_y0_l) y0[8:0]  <= clip_y0[8:0];
			if (ik_y0_h) y0[16:9] <= clip_y0[16:9];
			if (ik_x1_l) x1[8:0]  <= clip_x1[8:0];
			if (ik_x1_h) x1[16:9] <= clip_x1[16:9];
			if (ik_y1_l) y1[8:0]  <= clip_y1[8:0];
			if (ik_y1_h) y1[16:9] <= clip_y1[16:9];
		end
	end

`ifdef SYNTH_KINTEX7
	wire is_s_mul = (state == S_MUL);
	wire ce_ydl_init_raw = is_s_mul && d_idle && s_idle && m_burst;
	wire ce_ydl_init_lo = ce_ydl_init_raw;
	wire ce_ydl_init_hi = ce_ydl_init_raw;
	wire ce_ydl_init = !state_b4_0;
	wire ce_ydl;
	LUT4 #(.INIT(16'hFF40)) u_ce_ydl (
		.I0(cmp_last_bo),
		.I1(rem_b_small),
		.I2(walk_step_a),
		.I3(ce_ydl_init_lo),
		.O(ce_ydl)
	);
`else
	wire ce_ydl_init = (state == S_MUL) && d_idle && s_idle && m_burst;
	wire ce_ydl_step = (state == S_BURST) && rst_ctl1;
	wire ce_ydl = ce_ydl_init || ce_ydl_step;
`endif
	wire [1:0] ydl_b_next_val = ce_ydl_init ? yd_start[1:0] : ydl_b_inc;
	wire [1:0] ysl_b_next_val = ce_ydl_init ? ys_start[1:0] : ysl_b_inc;

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			ydl_b <= 2'd0;
			ysl_b <= 2'd0;
			ydl_b_is_3_lo <= 1'b0;
			ydl_b_is_3_hi <= 1'b0;
			ysl_b_is_3 <= 1'b0;
		end else if (ce_ydl) begin
			ydl_b <= ydl_b_next_val;
			ysl_b <= ysl_b_next_val;
			ydl_b_is_3_lo <= (ydl_b_next_val == 2'd3);
			ydl_b_is_3_hi <= (ydl_b_next_val == 2'd3);
			ysl_b_is_3 <= (ysl_b_next_val == 2'd3);
		end
	end

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			dlo <= {ADDR_W{1'b0}};
			slo <= {ADDR_W{1'b0}};
		end else begin
			if (sc_dlo0) dlo[15:0] <= mr_dlo_lo ? d_lo[15:0] : da[15:0];
			if (sc_dlo1) dlo[ADDR_W-1:16] <= mr_dlo_hi ? d_lo[ADDR_W-1:16] : da[ADDR_W-1:16];
			if (sc_slo0) slo[15:0] <= mr_slo_lo ? s_lo[15:0] : sa[15:0];
			if (sc_slo1) slo[ADDR_W-1:16] <= mr_slo_hi ? s_lo[ADDR_W-1:16] : sa[ADDR_W-1:16];
		end
	end

	reg r_mr_walk_lo;
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			m_copy <= 1'b0;
			m_blend <= 1'b0;
			m_rev <= 1'b0;
			r_mr_px <= 1'b0;
			r_mr_spx <= 1'b0;
			r_mr_walk_lo <= 1'b0;
		end else if (ik_cfg_copy) begin
			m_copy <= o_op != GHCI_BLT_FILL;
			m_blend <= (ENABLE_BLEND != 0) && o_blend;
			m_rev <= o_rev;
			r_mr_px <= o_rev;
			r_mr_spx <= o_rev;
			r_mr_walk_lo <= o_rev;
		end
	end

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			m_dtile <= 1'b0;
		end else if (ik_cfg_dtile) begin
			m_dtile <= (ENABLE_TILE != 0) && (o_op == GHCI_BLT_TILE);
		end
	end

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			m_stile <= 1'b0;
		end else if (ik_cfg_stile) begin
			m_stile <= (ENABLE_TILE != 0) && (o_op == GHCI_BLT_UNTILE);
		end
	end

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			psl <= 3'd2;
		end else begin
			if (ik_cfg_psl0_0) psl[0] <= o_psl[0];
			if (ik_cfg_psl0_1) psl[1] <= o_psl[1];
			if (ik_cfg_psl0_2) psl[2] <= o_psl[2];
		end
	end

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			psl_w <= 3'd2;
		end else if (ik_cfg_psl1) begin
			psl_w <= o_psl;
		end
	end

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			m_keep <= 4'd0;
		end else if (ik_cfg_ctl) begin
			m_keep <= o_keep;
		end
	end

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			m_burst <= 1'b0;
		end else if (ik_cfg_ctl) begin
			m_burst <= !o_blend;
		end else if (state == S_START) begin
			m_burst <= m_burst && !(r_dbase == r_sbase && !mr_leg && ({1'b0, s_src_xy[15:0]} < x0));
		end
	end

	reg [US:0] r_delta_px_norm, r_delta_px_back;
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			r_dst_delta_norm <= {ADDR_W{1'b0}};
			r_dst_delta_back <= {ADDR_W{1'b0}};
			r_src_delta_norm <= {ADDR_W{1'b0}};
			r_src_delta_back <= {ADDR_W{1'b0}};
			r_delta_px_norm <= {(US+1){1'b0}};
			r_delta_px_back <= {(US+1){1'b0}};
		end else begin
			if (ce_init_l[0]) begin
				r_dst_delta_norm[15:0] <= b_dst_delta_norm[15:0];
				r_delta_px_norm <= (pslw_ctl == 3'd4) ? {5'b00000, b_dst_delta_norm[US-1:4]} :
				                   (pslw_ctl == 3'd3) ? {4'b0000, b_dst_delta_norm[US-1:3]}  :
				                   (pslw_ctl == 3'd2) ? {3'b000, b_dst_delta_norm[US-1:2]}   :
				                   (pslw_ctl == 3'd1) ? {2'b00, b_dst_delta_norm[US-1:1]}    : {1'b0, b_dst_delta_norm[US-1:0]};
			end
			if (ce_init_l[1]) r_dst_delta_norm[ADDR_W-1:16] <= b_dst_delta_norm[ADDR_W-1:16];
			if (ce_init_l[2]) begin
				r_dst_delta_back[15:0] <= b_dst_delta_back[15:0];
				r_delta_px_back <= (pslw_ctl == 3'd4) ? {5'b00000, b_dst_delta_back[US-1:4]} :
				                   (pslw_ctl == 3'd3) ? {4'b0000, b_dst_delta_back[US-1:3]}  :
				                   (pslw_ctl == 3'd2) ? {3'b000, b_dst_delta_back[US-1:2]}   :
				                   (pslw_ctl == 3'd1) ? {2'b00, b_dst_delta_back[US-1:1]}    : {1'b0, b_dst_delta_back[US-1:0]};
			end
			if (ce_init_l[3]) r_dst_delta_back[ADDR_W-1:16] <= b_dst_delta_back[ADDR_W-1:16];
			if (ce_init_l[4]) r_src_delta_norm[15:0] <= b_src_delta_norm[15:0];
			if (ce_init_l[5]) r_src_delta_norm[ADDR_W-1:16] <= b_src_delta_norm[ADDR_W-1:16];
			if (ce_init_l[6]) r_src_delta_back[15:0] <= b_src_delta_back[15:0];
			if (ce_init_l[7]) r_src_delta_back[ADDR_W-1:16] <= b_src_delta_back[ADDR_W-1:16];
		end
	end

	/*
	 * Dedicated Clock Enable and Registers for 'rows'
	 */
	wire ce_rows_s_clip = (state == S_CLIP);
	wire ce_rows_s_wr   = (state == S_WR) && (!fail_fsm3 && wg_ctl && sl_ctl);
	wire ce_rows_raw    = ce_rows_s_clip || ce_rows_s_wr;
	wire [16:0] rows_mux = (state == S_CLIP) ? c_rows : rows_dec;

	wire ce_rows_r_lo = ce_rows_raw;
	wire ce_rows_r_hi = ce_rows_raw;

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			rows <= 17'd0;
		end else begin
			if (ce_rows_r_lo) rows[7:0]  <= rows_mux[7:0];
			if (ce_rows_r_hi) rows[16:8] <= rows_mux[16:8];
		end
	end

	/*
	 * Dedicated Process for 'is_burst'
	 */
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			is_burst <= 1'b0;
		end else begin
			if (state == S_INIT1) begin
				is_burst <= 1'b1;
			end else if (state == S_BURST) begin
				if (fail_burst || burst_drain_done)
					is_burst <= 1'b0;
			end else if (state == S_DRAIN || (state == S_IDLE && !kick) || (state == S_MUL && d_idle && s_idle && !m_burst)) begin
				is_burst <= 1'b0;
			end
		end
	end

	/*
	 * Dedicated Process for 'cur_bst_room'
	 */
	wire ce_bst_room = (state == S_INIT1) || (is_burst && ws_walk);
`ifdef SYNTH_KINTEX7
	reg [US:0] r_init_bst_room;
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			r_init_bst_room <= {(US+1){1'b0}};
		end else if (state == S_INIT) begin
			r_init_bst_room <= (bst_tiled && (bst_room_t_init < rem_line_init)) ? bst_room_t_init : rem_line_init;
		end
	end

	wire [US:0] bst_room_t_walk = {{(US - 2){1'b0}}, tile_room_walk};
	wire [US:0] room_last = bst_tiled ?
		((bst_room_t_init < rem_line_row) ? bst_room_t_init : rem_line_row) : rem_line_row;
	wire [US:0] room_next = bst_tiled ?
		((bst_room_t_walk < rem_line_seg_next) ? bst_room_t_walk : rem_line_seg_next) : line_pixels_b;
	wire bsl_room_fast;
	LUT4 #(.INIT(16'hF800)) u_bsl_room_fast (
		.I0(cmp_lo_le),
		.I1(cmp_hi_eq),
		.I2(cmp_hi_lt),
		.I3(rem_b_small),
		.O(bsl_room_fast)
	);
	wire [US:0] next_bst_room;
	genvar g_nbr;
	generate
		for (g_nbr = 0; g_nbr <= US; g_nbr = g_nbr + 1) begin : g_nbr_bits
			LUT5 #(.INIT(32'hFF00_CACA)) u_nbr (
				.I0(room_next[g_nbr]),
				.I1(room_last[g_nbr]),
				.I2(bsl_room_fast),
				.I3(r_init_bst_room[g_nbr]),
				.I4(r_is_init1),
				.O(next_bst_room[g_nbr])
			);
		end
	endgenerate
`else
	wire [US:0] bst_room_t_walk = {{(US - 2){1'b0}}, tile_room_walk};
	wire [US:0] room_last = bst_tiled ?
		((bst_room_t_init < rem_line_row) ? bst_room_t_init : rem_line_row) : rem_line_row;
	wire [US:0] room_next = bst_tiled ?
		((bst_room_t_walk < rem_line_seg_next) ? bst_room_t_walk : rem_line_seg_next) : line_pixels_b;
	wire [US:0] next_bst_room = (state == S_INIT1) ?
		((bst_tiled && (bst_room_t_init < rem_line_b)) ? bst_room_t_init : rem_line_b) :
		(bsl_room ? room_last : room_next);
`endif

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			cur_bst_room <= {(US+1){1'b0}};
		end else if (ce_bst_room) begin
			cur_bst_room <= next_bst_room;
		end
	end

	/*
	 * Dedicated Process for 'r_leg_room'
	 */
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			r_leg_room <= {(US+1){1'b0}};
		end else if (state == S_SB) begin
			r_leg_room <= leg_room;
		end
	end

	/*
	 * Dedicated Processes for High-Frequency Kintex-7 Pipeline
	 */
`ifdef SYNTH_KINTEX7
	wire ce_rem_line_row;
	LUT4 #(.INIT(16'hFF40)) u_ce_rlr (
		.I0(cmp_last_bo),
		.I1(rem_b_small),
		.I2(walk_step_a),
		.I3(r_is_init1),
		.O(ce_rem_line_row)
	);
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			rem_line_row <= {(US+1){1'b0}};
		end else if (ce_rem_line_row) begin
			rem_line_row <= rem_line_row_next;
		end
	end

	wire ce_cdr_init = ((state == S_MUL && mb_row) || (state == S_INIT));
	wire [US-1:0] cur_da_row_d = ce_cdr_init ? cur_da_init : cur_da_row_next;
	wire ce_cur_da_row;
	LUT5 #(.INIT(32'hFFFF_FF40)) u_ce_cdr (
		.I0(cmp_last_bo),
		.I1(rem_b_small),
		.I2(walk_step_a),
		.I3(r_is_init1),
		.I4(ce_cdr_init),
		.O(ce_cur_da_row)
	);
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			cur_da_row <= {US{1'b0}};
			r_da_px_init <= {(US+1){1'b0}};
			r_is_init1 <= 1'b0;
		end else begin
			r_is_init1 <= (state == S_INIT);
			if (ce_cur_da_row) begin
				cur_da_row <= cur_da_row_d;
			end
			if (ce_cdr_init) begin
				r_da_px_init <= (psl_ctl == 3'd4) ? {5'b00000, cur_da_init[US-1:4]} :
				                (psl_ctl == 3'd3) ? {4'b0000, cur_da_init[US-1:3]}  :
				                (psl_ctl == 3'd2) ? {3'b000, cur_da_init[US-1:2]}   :
				                (psl_ctl == 3'd1) ? {2'b00, cur_da_init[US-1:1]}    : {1'b0, cur_da_init};
			end
		end
	end

	wire ce_rows_init = ce_ydl_init_hi && mb_row;
	wire ce_rows_b_lo, ce_rows_b_hi;
	LUT4 #(.INIT(16'hFF40)) u_ce_rows_b_lo (.I0(cmp_last_bo), .I1(rem_b_small), .I2(walk_step_a), .I3(ce_rows_init), .O(ce_rows_b_lo));
	LUT4 #(.INIT(16'hFF40)) u_ce_rows_b_hi (.I0(cmp_last_bo), .I1(rem_b_small), .I2(walk_step_a), .I3(ce_rows_init), .O(ce_rows_b_hi));

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			rows_b[8:0] <= 9'd0;
		end else if (ce_rows_b_lo) begin
			rows_b[8:0] <= ce_rows_init ? rows[8:0] : rows_b_dec[8:0];
		end
	end

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			rows_b[16:9] <= 8'd0;
		end else if (ce_rows_b_hi) begin
			rows_b[16:9] <= ce_rows_init ? rows[16:9] : rows_b_dec[16:9];
		end
	end

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			rows_b_zero  <= 1'b0;
		end else if (state == S_INIT) begin
			rows_b_zero  <= rows_is_zero;
		end else if (walk_step_a && bst_seg_last_raw) begin
			rows_b_zero  <= (rows_b == 17'd1);
		end
	end

	wire ce_rbs_init = (state == S_MUL) && d_idle && s_idle && m_burst;
	wire ce_rbs_walk = walk_step_b;
	wire ce_rem_b_small = ce_rbs_init || ce_rbs_walk;
	wire width_small = !(|width[16:US+1]);
	wire rem_b_small_next = ce_rbs_init ? width_small :
	                        ((rem_b_small && !cmp_last_bo) ? width_small : rem_b_small_walk);
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			rem_b_small <= 1'b0;
		end else if (ce_rem_b_small) begin
			rem_b_small <= rem_b_small_next;
		end
	end

	wire ce_sb1_lo, ce_sb1_hi;
	LUT5 #(.INIT(32'h0000_0040)) u_ce_sb1_lo (
		.I0(state[0]), .I1(state[1]), .I2(state[2]), .I3(state[3]), .I4(state_b4_0),
		.O(ce_sb1_lo)
	);
	LUT5 #(.INIT(32'h0000_0040)) u_ce_sb1_hi (
		.I0(state[0]), .I1(state[1]), .I2(state[2]), .I3(state[3]), .I4(state_b4_1),
		.O(ce_sb1_hi)
	);
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			r_leg_back <= {ADDR_W{1'b0}};
		end else begin
			if (ce_sb1_lo) r_leg_back[15:0] <= leg_back_val[15:0];
			if (ce_sb1_hi) r_leg_back[ADDR_W-1:16] <= leg_back_val[ADDR_W-1:16];
		end
	end
`endif

	reg [4:0] st_g0_r, st_g1_r, st_g2_r, st_g3_r, st_g4_r;
	always @(*) begin
		case (state[1:0])
		2'd0: st_g0_r = (kick && op_ok) ? S_CLIP : S_IDLE;
		2'd1: st_g0_r = S_IDLE;
		2'd2: st_g0_r = S_START1;
		2'd3: st_g0_r = (d_idle && s_idle) ? (m_burst ? S_INIT : S_SA) : S_MUL;
		endcase
		case (state[1:0])
		2'd0: st_g1_r = fail_fsm0 ? S_DRAIN : S_SB;
		2'd1: st_g1_r = S_SB1;
		2'd2: st_g1_r = S_SC;
		2'd3: st_g1_r = S_SD;
		endcase
		case (state[1:0])
		2'd0: st_g2_r = m_copy ? S_CRD : (m_blend ? S_DRD : S_WR);
		2'd1: st_g2_r = fail_fsm2 ? S_DRAIN : ((q_free && wr_idle && !rd_first && !rd_second) ? S_CWAIT : S_CRD);
		2'd2: st_g2_r = fail_fsm2 ? S_DRAIN : ((q_free && rd_idle) ? (m_blend ? S_DRD : S_WR) : S_CWAIT);
		2'd3: st_g2_r = fail_fsm3 ? S_DRAIN : ((q_free && wr_idle) ? S_DWAIT : S_DRD);
		endcase
		case (state[1:0])
		2'd0: st_g3_r = fail_fsm3 ? S_DRAIN : ((q_free && rd_idle) ? S_BLEND : S_DWAIT);
		2'd1: st_g3_r = bl_done ? S_WR : S_BLEND;
		2'd2: st_g3_r = fail_fsm3 ? S_DRAIN : (q_free ? ((r_seg_last && rows_is_zero) ? S_DRAIN : S_SA) : S_WR);
		2'd3: st_g3_r = (q_free && wr_idle && rd_idle && !rsp_valid) ? S_IDLE : S_DRAIN;
		endcase
		case (state[1:0])
		2'd0: st_g4_r = burst_drain_done ? S_IDLE : (fail_burst ? S_DRAIN : S_BURST);
		2'd1: st_g4_r = S_INIT1;
		2'd2: st_g4_r = S_MUL;
		2'd3: st_g4_r = S_BURST;
		endcase
	end
	wire [4:0] st_g0 = st_g0_r;
	wire [4:0] st_g1 = st_g1_r;
	wire [4:0] st_g2 = st_g2_r;
	wire [4:0] st_g3 = st_g3_r;
	wire [4:0] st_g4 = (state[3:2] == 2'b00) ? st_g4_r : S_IDLE;
	wire [4:0] st_q01 = (state[3:2] == 2'd0) ? st_g0 :
	                                        (state[3:2] == 2'd1) ? st_g1 :
	                                        (state[3:2] == 2'd2) ? st_g2 : st_g3;
	wire [4:0] state_next_no_clip = state[4] ? st_g4 : st_q01;

	reg busy_next_no_clip;
	reg done_next_no_clip;
	always @(*) begin
		busy_next_no_clip = r_busy_q;
		done_next_no_clip = 1'b0;
		case (state)
		S_IDLE: begin
			if (kick && op_ok)
				busy_next_no_clip = 1'b1;
		end
		S_CLIP: begin
			busy_next_no_clip = 1'b0;
			done_next_no_clip = 1'b0;
		end
		S_BURST: begin
			if (burst_drain_done) begin
				busy_next_no_clip = 1'b0;
				done_next_no_clip = 1'b1;
			end
		end
		S_DRAIN: begin
			if (q_free && wr_idle && rd_idle && !rsp_valid) begin
				busy_next_no_clip = 1'b0;
				if (!fail_fsm3)
					done_next_no_clip = 1'b1;
			end
		end
		default: begin
			if (state > S_INIT1)
				busy_next_no_clip = 1'b0;
		end
		endcase
	end

	wire is_s_clip = (state == S_CLIP);
	wire state_d1_nc = state_next_no_clip[1];
	wire busy_d_nc   = busy_next_no_clip;
	wire done_d_nc   = done_next_no_clip;
`ifdef SYNTH_KINTEX7
	wire state_d1;
	wire busy_d;
	wire done_d;
	LUT6 #(.INIT(64'hFFFF_0000_1F10_1F10)) u_state_d1 (
		.I0(cx_empty),
		.I1(cy_empty),
		.I2(is_s_clip),
		.I3(st_q01[1]),
		.I4(st_g4[1]),
		.I5(state[4]),
		.O(state_d1)
	);
	LUT5 #(.INIT(32'h0000_1F10)) u_busy_d (
		.I0(cx_empty),
		.I1(cy_empty),
		.I2(is_s_clip),
		.I3(busy_d_nc),
		.I4(rst_b2d_high),
		.O(busy_d)
	);
	LUT5 #(.INIT(32'h0000_EFE0)) u_done_d (
		.I0(cx_empty),
		.I1(cy_empty),
		.I2(is_s_clip),
		.I3(done_d_nc),
		.I4(rst_b2d_high),
		.O(done_d)
	);
`else
	wire state_d1 = is_s_clip ? (!cx_empty && !cy_empty) : state_d1_nc;
	wire busy_d   = rst_b2d_high ? 1'b0 : (is_s_clip ? (!cx_empty && !cy_empty) : busy_d_nc);
	wire done_d   = rst_b2d_high ? 1'b0 : (is_s_clip ? (cx_empty || cy_empty)   : done_d_nc);
`endif

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			state <= S_IDLE;
		end else begin
			state[0]   <= state_next_no_clip[0];
			state[1]   <= state_d1;
			state[4:2] <= state_next_no_clip[4:2];
		end
		r_busy_q <= busy_d;
		done     <= done_d;
	end

	wire ce_ydl_leg = (state == S_START) || (state == S_WR && !fail_fsm3 && q_free && r_seg_last);
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			ydl <= 2'd0;
			ysl <= 2'd0;
		end else if (ce_ydl_leg) begin
			ydl <= state[3] ? ydl_inc : yd_start[1:0];
			ysl <= state[3] ? ysl_inc : ys_start[1:0];
		end
	end

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			error <= 1'b0;
			error_kind <= 4'd0;
			rd_first <= 1'b0;
			rd_second <= 1'b0;
			bl_go <= 1'b0;
			r_seg_last <= 1'b0;
			bw_bank <= 1'b0;
			bw_seg_idx <= 3'd0;
			bw_seg_onehot <= 8'b00000001;
			bw_slot_cnt <= 4'd0;
			bw_sub <= 1'b0;
			bw_done_all <= 1'b0;
			bw_walk_done <= 1'b0;
			g_valid <= 1'b0;
`ifndef SYNTH_KINTEX7
			rem_b_small <= 1'b0;
`endif
			br_bank <= 1'b0;
			br_seg_idx <= 3'd0;
			br_active <= 1'b0;
			b_draining <= 1'b0;
			bank_active <= 2'b00;
			bank_closed <= 2'b00;
			bank_ready <= 2'b00;
			bank_rd_pending_0 <= 5'd0;
			bank_rd_pending_1 <= 5'd0;
`ifndef SYNTH_KINTEX7
			rows_b_zero <= 1'b0;
`endif
			burst_wr_out <= 5'd0;
			px_b <= 17'd0;
			spx_b <= 17'd0;
			rem_b <= 17'd0;
`ifndef SYNTH_KINTEX7
			rows_b <= 17'd0;
`endif
			tile_room_b <= 3'd4;
`ifndef SYNTH_KINTEX7
			r_leg_back <= {ADDR_W{1'b0}};
`else
			r_da_px_leg <= {(US+1){1'b0}};
`endif
			rem_line_b <= {(US+1){1'b0}};
			r_rem_line_init <= {(US+1){1'b0}};
`ifndef SYNTH_KINTEX7
			rem_line_row <= {(US+1){1'b0}};
			cur_da_row <= {US{1'b0}};
`endif
			line_pixels_b <= {1'b1, {US{1'b0}}};
			rows_is_zero <= 1'b0;
			g_da_full <= {ADDR_W{1'b0}};
			g_sa_full <= {ADDR_W{1'b0}};
			dst_row_b <= {ADDR_W{1'b0}};
			src_row_b <= {ADDR_W{1'b0}};
			r_dst_back <= {ADDR_W{1'b0}};
			r_src_back <= {ADDR_W{1'b0}};
			r_dst_neg <= {ADDR_W{1'b0}};
			r_src_neg <= {ADDR_W{1'b0}};
			r_tile_step <= {ADDR_W{1'b0}};
			r_dstride <= 32'd0;
			r_sstride <= 32'd0;
			r_dbase <= 32'd0;
			r_sbase <= 32'd0;
			r_d_first <= 32'd0;
			r_s_first <= 32'd0;
			r_yd_start <= 17'd0;
			r_ys_start <= 17'd0;
			width <= 17'd0;
			width_m1 <= 17'd0;
			sx0 <= 17'd0;
			sy0 <= 17'd0;
			px_row <= 17'd0;
			spx_row <= 17'd0;
			px <= 17'd0;
			spx <= 17'd0;
			rem <= 17'd0;
			sn <= {(US+1){1'b0}};
			snu <= {(US+1){1'b0}};
			seg_line <= {LA_W{1'b0}};
			src_n0 <= {LA_W{1'b0}};
			src_n1 <= {LA_W{1'b0}};
			seg_p0 <= {US{1'b0}};
			src_off <= {US{1'b0}};
			n0_slot <= 1'b0;
			da <= {ADDR_W{1'b0}};
			sa <= {ADDR_W{1'b0}};
		end else begin
			error <= 1'b0;
			bl_go <= 1'b0;

			/* Track pending read responses in ping-pong RAM */
			if (is_burst_ctl0) begin
				bank_rd_pending_0 <= brdp0_next;
				bank_rd_pending_1 <= brdp1_next;
				burst_wr_out <= bwr_next;
			end else begin
				bank_rd_pending_0 <= 5'd0;
				bank_rd_pending_1 <= 5'd0;
				burst_wr_out <= 5'd0;
			end

`ifndef SYNTH_KINTEX7
			/* Write into ping-pong RAM from AMB read response */
			if (m_burst && rsp_rd_bst) begin
				pp_ram[rsp_tag[4:0]] <= rsp_rdata;
			end
`endif

			case (state)
			S_IDLE: begin
				if (kick) begin
					if (!op_ok) begin
						error <= 1'b1;
						error_kind <= GHCI_FAULT_KIND_INVALID_OP;
					end
				end
			end
			S_CLIP: begin
				if (cl_w)   width <= c_width;
				if (cl_wm1) width_m1 <= unused_x_d;
				if (cl_r) begin
					rows_is_zero <= rows_init_zero;
				end
				if (cl_sx)   sx0 <= c_sx0;
				if (cl_sy)   sy0 <= c_sy0;
				if (cl_stp)  r_tile_step <= tile_step;
				if (cl_ds0)  r_dstride[15:0] <= dstride_u[15:0];
				if (cl_ds1)  r_dstride[31:16] <= dstride_u[31:16];
				if (cl_ss0)  r_sstride[15:0] <= sstride_u[15:0];
				if (cl_ss1)  r_sstride[31:16] <= sstride_u[31:16];
				if (cl_db0)  r_dbase[15:0] <= dbase_u[15:0];
				if (cl_db1)  r_dbase[31:16] <= dbase_u[31:16];
				if (cl_sb0)  r_sbase[15:0] <= sbase_u[15:0];
				if (cl_sb1)  r_sbase[31:16] <= sbase_u[31:16];
			end
			S_START: begin
				if (st_px)  px_row <= mr_px_row ? x1_last : x0;
				if (st_spx) spx_row <= mr_spx_row ? s_last : sx0;
				if (st_yd) begin
					r_yd_start <= mdt_acc ? {2'b00, yd_start[16:2]} : yd_start;
				end
				if (st_ys) begin
					r_ys_start <= mst_acc ? {2'b00, ys_start[16:2]} : ys_start;
				end
				if (st_df0) r_d_first[15:0] <= d_first[15:0];
				if (st_df1) r_d_first[31:16] <= d_first[31:16];
				if (st_sf0) r_s_first[15:0] <= s_first[15:0];
				if (st_sf1) r_s_first[31:16] <= s_first[31:16];
				if (st_db0) r_dst_back[15:0] <= dst_back[15:0];
				if (st_db1) r_dst_back[ADDR_W-1:16] <= dst_back[ADDR_W-1:16];
				if (st_sb0) r_src_back[15:0] <= src_back[15:0];
				if (st_sb1) r_src_back[ADDR_W-1:16] <= src_back[ADDR_W-1:16];
				if (st_dn0) r_dst_neg[15:0] <= dst_neg[15:0];
				if (st_dn1) r_dst_neg[ADDR_W-1:16] <= dst_neg[ADDR_W-1:16];
				if (st_sn0) r_src_neg[15:0] <= src_neg[15:0];
				if (st_sn1) r_src_neg[ADDR_W-1:16] <= src_neg[ADDR_W-1:16];
			end
			S_START1: begin
			end
			S_MUL:
				if (d_idle && s_idle) begin
					if (m_burst) begin
`ifndef SYNTH_KINTEX7
						rem_b_small <= !(|width[16:US+1]);
`endif
						if (mb_pos) begin
							px_b <= px_row;
							spx_b <= spx_row;
							rem_b <= width;
							tile_room_b <= tile_room_init;
						end
						if (mb_row) begin
`ifndef SYNTH_KINTEX7
							rows_b <= rows;
							rows_b_zero <= (rows == 17'd0);
							cur_da_row <= cur_da_init;
`endif
						end
						if (mb_addr) begin
							dst_row_b <= dst_row;
							src_row_b <= src_row;
							line_pixels_b <= calc_line_pixels;
						end
					end else begin
						px <= px_row;
						spx <= spx_row;
						rem <= width;
					end
				end
			S_INIT: begin
				rem_line_b <= rem_line_init;
				r_rem_line_init <= rem_line_init;
`ifndef SYNTH_KINTEX7
				cur_da_row <= cur_da_init;
				rem_line_row <= rem_line_init;
`endif
				bw_bank <= 1'b0;
				bw_seg_idx <= 3'd0;
				bw_seg_onehot <= 8'b00000001;
				bw_slot_cnt <= 4'd0;
				bw_sub <= 1'b0;
				bw_done_all <= 1'b0;
				bw_walk_done <= 1'b0;
				g_valid <= 1'b0;
				br_bank <= 1'b0;
				br_seg_idx <= 3'd0;
				br_active <= 1'b0;
				b_draining <= 1'b0;
				bank_active <= 2'b00;
				bank_closed <= 2'b00;
				bank_ready <= 2'b00;
			end
			S_INIT1: begin
`ifndef SYNTH_KINTEX7
				cur_da_row <= cur_da_row_next;
				rem_line_row <= rem_line_row_next;
`endif
			end

			/*
			 * =================================================================
			 * S_BURST: Streaming Burst DMA Engine (Phase 030)
			 * =================================================================
			 */
			S_BURST: begin
				/*
				 * 1. Bank Read Ready detection:
				 * Once bank is closed, when all read responses arrived (or FILL), mark READY.
				 */
				if (is_burst_bk0 && bank_closed[0] && !bank_ready[0] && (!m_copy || brdp0_is_zero))
					bank_ready[0] <= 1'b1;
				if (is_burst_bk1 && bank_closed[1] && !bank_ready[1] && (!m_copy || brdp1_is_zero))
					bank_ready[1] <= 1'b1;

				/*
				 * 2. Walk & Geom & Issue Pipelines (Concurrent 3-stage pipeline)
				 */
				/* Stage 1 (Walk Stage): advance walk coordinates and latch into g_* */
				if (ws_px0)  px_b[15:0] <= px_b_next[15:0];
				if (ws_px1)  px_b[16]   <= px_b_next[16];
				if (ws_spx0) spx_b[15:0] <= spx_b_next[15:0];
				if (ws_spx1) spx_b[16]   <= spx_b_next[16];
				if (ws_rem0) rem_b[15:0] <= rem_b_next[15:0];
				if (ws_rem1) rem_b[16]   <= rem_b_next[16];
				if (ws_walk) begin
					rem_line_b <= rem_line_b_d;
					tile_room_b <= tile_room_step;
`ifndef SYNTH_KINTEX7
					rem_b_small <= bsl_rem_hi ? !(|width[16:US+1]) : rem_b_small_walk;
`endif
				end
`ifndef SYNTH_KINTEX7
				if (rst_row) begin
					rows_b <= rows_b_dec;
					rows_b_zero <= (rows_b_dec == 17'd0);
				end
`endif
				if (rst_dst0) dst_row_b[15:0] <= dst_row_b_next[15:0];
				if (rst_dst1) dst_row_b[ADDR_W-1:16] <= dst_row_b_next[ADDR_W-1:16];
				if (rst_src0) src_row_b[15:0] <= src_row_b_next[15:0];
				if (rst_src1) src_row_b[ADDR_W-1:16] <= src_row_b_next[ADDR_W-1:16];
`ifndef SYNTH_KINTEX7
				if (rst_ctl0) begin
					cur_da_row <= cur_da_row_next;
					rem_line_row <= rem_line_row_next;
				end
`endif
				if (rst_ctl1) begin
					if (rows_b_zero)
						bw_walk_done <= 1'b1;
				end
				if (walk_step_b)
					g_valid <= 1'b1;
				else if (step_p)
					g_valid <= 1'b0;

					/* Issue & Prefetch Stage: record metadata and issue AMB requests */
					if (bst_can_fill_p) begin
						bank_active[bw_bank] <= 1'b1;

						/* Check if current segment transfer step is complete */
						if (issue_fire) begin
							/* Segment complete: advance metadata pointers */
							bw_sub <= 1'b0;

							/* Advance bank segment and slot count */
							bw_seg_idx <= bw_seg_cnt_next[2:0];
							bw_slot_cnt <= p_two_lines ? bw_slot_p2 : bw_slot_p1;

							/* Check bank close condition */
							if (bank_close_cond) begin
								bank_closed[bw_bank] <= 1'b1;
								bw_bank <= ~bw_bank;
								bw_seg_idx <= 3'd0;
								bw_slot_cnt <= 4'd0;
								bw_seg_onehot <= 8'b00000001;
								if (p_seg_last && p_rows_b_zero)
									bw_done_all <= 1'b1;
							end else begin
								bw_seg_onehot <= {bw_seg_onehot[6:0], bw_seg_onehot[7]};
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
						if (br_step_en) begin
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
				end

			/*
			 * =================================================================
			 * Legacy Sequential Path (Blend & RAW Smear Compatibility)
			 * =================================================================
			 */
			S_SA:
				if (!fail_fsm0) begin
					if (sa_da0) da[15:0] <= d_addr[15:0];
					if (sa_da1) da[ADDR_W-1:16] <= d_addr[ADDR_W-1:16];
					if (sa_sa0) sa[15:0] <= s_addr[15:0];
					if (sa_sa1) sa[ADDR_W-1:16] <= s_addr[ADDR_W-1:16];
`ifdef SYNTH_KINTEX7
					r_da_px_leg <= (psl_leg == 3'd4) ? {5'b00000, d_addr[US-1:4]} :
					               (psl_leg == 3'd3) ? {4'b0000, d_addr[US-1:3]}  :
					               (psl_leg == 3'd2) ? {3'b000, d_addr[US-1:2]}   :
					               (psl_leg == 3'd1) ? {2'b00, d_addr[US-1:1]}    : {1'b0, d_addr[US-1:0]};
`endif
				end
			S_SB: begin
			end
			S_SB1: begin
				sn <= leg_sn;
`ifndef SYNTH_KINTEX7
				r_leg_back <= leg_back_val;
`endif
				r_seg_last <= leg_rem_done;
			end
			S_SC: begin
				if (sc_snu) snu <= (psl == 3'd4) ? {sn[US-4:0], 4'b0000} :
				                   (psl == 3'd3) ? {sn[US-3:0], 3'b000}  :
				                   (psl == 3'd2) ? {sn[US-2:0], 2'b00}   :
				                   (psl == 3'd1) ? {sn[US-1:0], 1'b0}    : sn;
			end
			S_SD: begin
				if (sd_sl0) seg_line[13:0] <= dlo_line[13:0];
				if (sd_sl1) seg_line[LA_W-1:14] <= dlo_line[LA_W-1:14];
				if (sd_s00) src_n0[13:0] <= slo_line[13:0];
				if (sd_s01) src_n0[LA_W-1:14] <= slo_line[LA_W-1:14];
				if (sd_s10) src_n1[13:0] <= last_line[13:0];
				if (sd_s11) src_n1[LA_W-1:14] <= last_line[LA_W-1:14];
				if (sd_ctl) begin
					seg_p0 <= dlo[US-1:0];
					src_off <= src_base_u[US-1:0];
					n0_slot <= slo[ADDR_W-1:US] != src_lo;
					rd_first <= 1'b1;
				end
			end
			S_CRD:
				if (!fail_fsm2 && q_free && wr_idle) begin
					if (rd_first) begin
						rd_first <= 1'b0;
						rd_second <= src_n1 != src_n0;
					end else if (rd_second) begin
						rd_second <= 1'b0;
					end
				end
			S_CWAIT: begin
			end
			S_DRD: begin
			end
			S_DWAIT:
				if (!fail_fsm3 && q_free && rd_idle) begin
					bl_go <= 1'b1;
				end
			S_BLEND: begin
			end
			S_WR:
				if (!fail_fsm3) begin
					if (wg_ctl && sl_ctl) begin
						rows_is_zero <= (rows == 17'd1);
					end
					if (wg_px)  px  <= sl_px ? px_row : px_next;
					if (wg_spx) spx <= sl_spx ? spx_row : spx_next;
					if (wg_rem) rem <= sl_ctl ? width : rem_next;
				end
			S_DRAIN: begin
				if (q_free && wr_idle && rd_idle && !rsp_valid) begin
					if (fail_fsm3) begin
						error <= 1'b1;
						error_kind <= GHCI_FAULT_KIND_AXI_ERROR;
					end
				end
			end
			default: begin
			end
			endcase
		end
	end

`ifdef SYNTH_KINTEX7
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			g_seg_n <= {(US+1){1'b0}};
			g_seg_bytes <= {(US+1){1'b0}};
			g_back_lo <= {US{1'b0}};
			g_seg_last <= 1'b0;
			g_rows_b_zero <= 1'b0;
		end else if (g_len_ctl) begin
			g_seg_n <= bst_seg_n;
			g_seg_bytes <= bst_seg_bytes;
			g_back_lo <= bst_back_lo;
			g_seg_last <= bst_seg_last;
			g_rows_b_zero <= rows_b_zero;
		end
	end
`else
	always @(posedge clk) begin
		if (rst_b2d_high) begin
			g_seg_n <= {(US+1){1'b0}};
			g_seg_bytes <= {(US+1){1'b0}};
			g_back_lo <= {US{1'b0}};
			g_seg_last <= 1'b0;
			g_rows_b_zero <= 1'b0;
		end else if (g_len_ctl) begin
			g_seg_n <= bst_seg_n;
			g_seg_bytes <= bst_seg_bytes;
			g_back_lo <= bst_back_lo;
			g_seg_last <= bst_seg_last;
			g_rows_b_zero <= rows_b_zero;
		end
	end
`endif

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			bank_num_segs_0 <= 4'd0;
			bank_is_last[0] <= 1'b0;
		end else if (bank_close_fire_0) begin
			bank_num_segs_0 <= bw_seg_cnt_next;
			bank_is_last[0] <= (p_seg_last && p_rows_b_zero);
		end
	end

	always @(posedge clk) begin
		if (rst_b2d_high) begin
			bank_num_segs_1 <= 4'd0;
			bank_is_last[1] <= 1'b0;
		end else if (bank_close_fire_1) begin
			bank_num_segs_1 <= bw_seg_cnt_next;
			bank_is_last[1] <= (p_seg_last && p_rows_b_zero);
		end
	end

`ifdef SYNTH_KINTEX7
	wire unused_ok = &{1'b0,
		c_op2, c_resolve, step_co_unused, first_co_unused, fsm_co_unused, bst_co_unused, rlr_co_unused,
		src_slice_u, dst_slice_u, depth_u};
`else
	wire unused_ok = &{1'b0,
		c_op2, c_resolve, step_co_unused, first_co_unused, fsm_co_unused, bst_co_unused, rlr_co_unused,
		src_slice_u, dst_slice_u, depth_u};
`endif
endmodule

`default_nettype wire
