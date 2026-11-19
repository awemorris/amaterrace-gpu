/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_rsv_px: the pixel path of the blitter's RESOLVE (atg_blt_rsv,
 * docs/ghci.md section 8.2).  It takes row descriptors and the source
 * lines of those rows in order, averages the four samples of each pixel
 * (atg_blt_avg) and assembles the destination lines, which it hands back
 * to atg_blt_rsv as writes.
 *
 * A row descriptor (rd_*, valid/ready, a FIFO of two) is {off0, nlines,
 * w, x, drow}: the byte offset of the row's first source byte in its first
 * line, the number of source lines of the row, the row's pixels, its first
 * destination x, and the destination row's address (linear: base + y
 * stride; tiled: base + (y / 4) stride + (y % 4) 4 ps).  The source lines
 * (ln_push, ln_data) arrive in the order the descriptors name them; there
 * is no ready: atg_blt_rsv reads a line only when the FIFO (2^DEPTH_LOG2
 * lines, ln_count) has room for it.  Pixels are 2^psl bytes (1 to 16).
 *
 * Per row, the window holds up to two source lines (w0, w1) and the byte
 * pointer of the next sample group.  Each cycle one group goes through: n
 * consecutive destination pixels, n <= 4, n <= max(1, LINE_BYTES / (4 ps))
 * (the group's 4 n ps source bytes fit the two lines; a 16-byte pixel's
 * 64-byte aligned samples fill two 32-byte lines), n <= the row's rest,
 * inside one destination line (linear) or inside one tile row (tiled: 4 -
 * x % 4).  A line is loaded into the window only while the row still has
 * lines to load, so exactly nlines are taken per row; at the row's end the
 * window is emptied.  The group's average (atg_blt_avg the same cycle, or
 * atg_blt_favg for sRGB and the floats, while no other group goes) is
 * registered (stage A) and
 * merged into the assembly line (stage B), which becomes a write
 * (wr_*, valid/ready, held until taken) when a group of another line
 * comes, or when nothing more is queued.  Byte enables cover the written
 * pixels only; rows that share a line merge.
 *
 * stop (a level) empties everything at once, the FIFOs included, and
 * stops the writes; idle is 1 when nothing is queued or held.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_rsv_px #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter DEPTH_LOG2 = 4,	/* source line FIFO: 2^DEPTH_LOG2 lines */
	parameter RD_W = 32 + 17 + 17 + 17 + 5	/* ADDR_W + 51 + LINE_SHIFT */
) (
	input wire clk,
	input wire rst_n,
	input wire stop,

	input wire [2:0] psl,	/* log2 of the pixel's bytes */
	input wire [2:0] fmt,
	input wire tiled,

	input wire rd_valid,
	output wire rd_ready,
	input wire [RD_W-1:0] rd_data,

	input wire ln_push,
	input wire [LINE_BYTES*8-1:0] ln_data,
	output wire [DEPTH_LOG2:0] ln_count,
	output wire ln_pop,

	output reg wr_valid,
	input wire wr_ready,
	output reg [ADDR_W-LINE_SHIFT-1:0] wr_line,
	output reg [LINE_BYTES-1:0] wr_be,
	output reg [LINE_BYTES*8-1:0] wr_data,

	output wire idle
);
	localparam LB = LINE_BYTES;
	localparam LBITS = LINE_BYTES * 8;
	localparam LS = LINE_SHIFT;
	localparam LA_W = ADDR_W - LINE_SHIFT;

	/* verilator lint_off WIDTHTRUNC */
	localparam [LS:0] LB_V = LB;
	/* verilator lint_on WIDTHTRUNC */

	wire frst_n = rst_n && !stop;

	/* The row descriptors. */
	wire rq_valid;
	wire rq_pop;
	wire [RD_W-1:0] rq_data;
	wire [1:0] rq_count;

	am_fifo #(.W(RD_W), .DEPTH_LOG2(1)) rq (
		.clk(clk),
		.rst_n(frst_n),
		.in_valid(rd_valid),
		.in_ready(rd_ready),
		.in_data(rd_data),
		.out_valid(rq_valid),
		.out_ready(rq_pop),
		.out_data(rq_data),
		.count(rq_count)
	);

	/* The source lines (1-cycle registered input stage isolates MC tree from lq.mem Check 4). */
	reg ln_push_r;
	reg [LBITS-1:0] ln_data_r;
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n)
			ln_push_r <= 1'b0;
		else if (stop)
			ln_push_r <= 1'b0;
		else
			ln_push_r <= ln_push;
	end
	always @(posedge clk) begin
		ln_data_r <= ln_data;
	end

	wire lq_valid;
	wire lq_pop;
	wire [LBITS-1:0] lq_data;
	wire lq_ready;
	wire [DEPTH_LOG2:0] lq_fifo_count;
	wire lncnt_co_unused;

	am_fifo #(.W(LBITS), .DEPTH_LOG2(DEPTH_LOG2)) lq (
		.clk(clk),
		.rst_n(frst_n),
		.in_valid(ln_push_r && !stop),
		.in_ready(lq_ready),
		.in_data(ln_data_r),
		.out_valid(lq_valid),
		.out_ready(lq_pop),
		.out_data(lq_data),
		.count(lq_fifo_count)
	);
	am_add #(.W(DEPTH_LOG2 + 1)) a_lncnt (
		.a(lq_fifo_count),
		.b({{DEPTH_LOG2{1'b0}}, ln_push_r && !stop}),
		.ci(1'b0),
		.s(ln_count),
		.co(lncnt_co_unused)
	);

	wire [ADDR_W-1:0] d_drow = rq_data[ADDR_W-1:0];
	wire [16:0] d_x = rq_data[ADDR_W +: 17];
	wire [16:0] d_w = rq_data[ADDR_W + 17 +: 17];
	wire [16:0] d_nl = rq_data[ADDR_W + 34 +: 17];
	wire [LS-1:0] d_off = rq_data[ADDR_W + 51 +: LS];

	/* The row in progress. */
	reg active;
	reg [16:0] x;
	reg [16:0] rem;
	reg rem_has_high;
	reg [ADDR_W-1:0] drow;
	reg [16:0] lines_left;
	reg lines_left_nz;
	reg [LBITS-1:0] buf0;
	reg [LBITS-1:0] buf1;
	reg head;
	(* keep = "true" *) reg [15:0] head_rep;
	localparam integer HSZ = LBITS / 16;
	wire [LBITS-1:0] w0, w1;
	genvar ghs;
	generate
		for (ghs = 0; ghs < 16; ghs = ghs + 1) begin : g_head_sl
			assign w0[ghs*HSZ +: HSZ] = head_rep[ghs] ? buf1[ghs*HSZ +: HSZ] : buf0[ghs*HSZ +: HSZ];
			assign w1[ghs*HSZ +: HSZ] = head_rep[ghs] ? buf0[ghs*HSZ +: HSZ] : buf1[ghs*HSZ +: HSZ];
		end
	endgenerate
	reg v0;
	reg v1;
	reg [LS-1:0] ptr;
	(* keep = "true" *) reg [8*LS-1:0] ptr_rep;

	/* The group: n pixels at x. */
	wire [2:0] sh4;	/* log2 of 4 ps, modulo 8 as the 3-bit sum was */
	wire [LS:0] nfit;
	wire [ADDR_W-1:0] x_b, daddr;
	wire [2:0] room_t;
	wire [3:0] grp_co_unused;

	am_add #(.W(3)) a_sh4 (.a(psl), .b(3'd2), .ci(1'b0), .s(sh4), .co(grp_co_unused[0]));
	am_shift #(.W(LS + 1), .SW(3)) h_fit (.a(LB_V), .amt(sh4), .left(1'b0), .arith(1'b0), .y(nfit));
	wire [2:0] nmax = nfit == {(LS + 1){1'b0}} ? 3'd1 : nfit >= 4 ? 3'd4 : nfit[2:0];
	reg [2:0] sh4_r, nmax_r, psl_r, n_geom_r;
	/* The pixel's bytes in the row (direct 5-way shift on psl <= 4 + 16+16 carry-select add). */
	wire [18:0] x_t_in = tiled ? {x[16:2], 2'b00, x[1:0]} : {2'b00, x};
	wire [22:0] x_t_sh = (psl == 3'd0) ? {4'd0, x_t_in} :
		(psl == 3'd1) ? {3'd0, x_t_in, 1'b0} :
		(psl == 3'd2) ? {2'd0, x_t_in, 2'b00} :
		(psl == 3'd3) ? {1'b0, x_t_in, 3'b000} : {x_t_in, 4'b0000};
	assign x_b = {{(ADDR_W - 23){1'b0}}, x_t_sh};
	wire [15:0] da_lo, da_hi0, da_hi1;
	wire da_c0, da_c10, da_c11;
	am_add #(.W(16)) a_da_lo  (.a(drow[15:0]),  .b(x_b[15:0]),  .ci(1'b0), .s(da_lo),  .co(da_c0));
	am_add #(.W(16)) a_da_hi0 (.a(drow[31:16]), .b(x_b[31:16]), .ci(1'b0), .s(da_hi0), .co(da_c10));
	am_add #(.W(16)) a_da_hi1 (.a(drow[31:16]), .b(x_b[31:16]), .ci(1'b1), .s(da_hi1), .co(da_c11));
	assign daddr = {da_c0 ? da_hi1 : da_hi0, da_lo};
	assign grp_co_unused[1] = da_c0 ? da_c11 : da_c10;
	assign grp_co_unused[2] = 1'b0;
	am_sub #(.W(3)) s_rt (.a(3'd4), .b({1'b0, x[1:0]}), .bi(1'b0), .d(room_t), .bo(grp_co_unused[3]));
	wire [2:0] rem_limit = rem_has_high ? 3'd4 : rem[2:0];

	reg [LS-1:0] daddr_ls_lin_r;
	wire [LS-1:0] daddr_ls_step;

	wire [ADDR_W-1:0] d_x_b_lin;
	am_shift #(.W(ADDR_W), .SW(3)) h_dx_lin (.a({{(ADDR_W - 17){1'b0}}, d_x}), .amt(psl), .left(1'b1), .arith(1'b0), .y(d_x_b_lin));
	wire [LS-1:0] daddr_ls_init;
	wire dals_init_co;
	am_add #(.W(LS)) a_dals_init (.a(d_drow[LS-1:0]), .b(d_x_b_lin[LS-1:0]), .ci(1'b0), .s(daddr_ls_init), .co(dals_init_co));

	wire [7:0] daddr_ls_pad = {{(8 - LS){1'b0}}, daddr_ls_lin_r};

	function [2:0] sub4_2b;
		input [1:0] b;
		case (b)
		2'd0: sub4_2b = 3'd4;
		2'd1: sub4_2b = 3'd3;
		2'd2: sub4_2b = 3'd2;
		2'd3: sub4_2b = 3'd1;
		endcase
	endfunction

	function [2:0] get_room_l_limit;
		input [7:0] pad;
		input [2:0] p_psl;
		begin
			if (LS >= 6) begin
				case (p_psl)
				3'd0: get_room_l_limit = (pad[5:2] == 4'b1111) ? sub4_2b(pad[1:0]) : 3'd4;
				3'd1: get_room_l_limit = (pad[5:3] == 3'b111)  ? sub4_2b(pad[2:1]) : 3'd4;
				3'd2: get_room_l_limit = (pad[5:4] == 2'b11)   ? sub4_2b(pad[3:2]) : 3'd4;
				3'd3: get_room_l_limit = pad[5]                ? sub4_2b(pad[4:3]) : 3'd4;
				3'd4: get_room_l_limit = sub4_2b(pad[5:4]);
				default: get_room_l_limit = 3'd4;
				endcase
			end else begin
				case (p_psl)
				3'd0: get_room_l_limit = (pad[4:2] == 3'b111)  ? sub4_2b(pad[1:0]) : 3'd4;
				3'd1: get_room_l_limit = (pad[4:3] == 2'b11)   ? sub4_2b(pad[2:1]) : 3'd4;
				3'd2: get_room_l_limit = pad[4]                ? sub4_2b(pad[3:2]) : 3'd4;
				3'd3: get_room_l_limit = sub4_2b(pad[4:3]);
				3'd4: get_room_l_limit = (pad[4] ? 3'd1 : 3'd2);
				default: get_room_l_limit = 3'd4;
				endcase
			end
		end
	endfunction

	reg [2:0] room_l_limit_r;
	reg [2:0] n;

	always @(*) begin
		if (rem_has_high || rem[2:0] >= n_geom_r)
			n = n_geom_r;
		else
			n = rem[2:0];
	end

	wire [6:0] gb_init_k [1:4];
	wire [7:0] need2_lim_w [1:4];
	wire [7:0] two_lim_w [1:4];
	wire [4:0] grp_nb_init_k [1:4];
	reg  [27:0] gb_r_v;
	reg  [31:0] need2_lim_v;
	reg  [31:0] two_lim_v;
	reg  [3:0]  need2_gt_lb_r;
	reg  [3:0]  need2_ge_lb_r;
	reg  [3:0]  two_ge_2lb_r;
	reg  [19:0] grp_nb_r_v;
	wire [6:0] gb_k [1:4];
	wire [LS-1:0] nptr_k [1:4];
	wire [3:0] need2_k, shift_ge_k, two_used_k;
	wire [4:0] grp_nb_k [1:4];
	wire [LS-1:0] dals_step_k [1:4];
	wire [2:0] room_l_k [1:4];
	wire [2:0] room_t_k [1:4];
	wire [2:0] n_geom_k [1:4];
	wire [3:0] gend_k_co_unused, dals_k_co_unused, n2l_bo_unused, twl_bo_unused;
	wire [1:0] x_p_k [1:4];
	assign x_p_k[1] = (x[1:0] == 2'd0) ? 2'd1 : (x[1:0] == 2'd1) ? 2'd2 : (x[1:0] == 2'd2) ? 2'd3 : 2'd0;
	assign x_p_k[2] = {~x[1], x[0]};
	assign x_p_k[3] = (x[1:0] == 2'd0) ? 2'd3 : (x[1:0] == 2'd1) ? 2'd0 : (x[1:0] == 2'd2) ? 2'd1 : 2'd2;
	assign x_p_k[4] = x[1:0];

	/* verilator lint_off WIDTH */
	localparam [7:0] LB_8  = LB;
	localparam [7:0] LB2_8 = 2 * LB;
	/* verilator lint_on WIDTH */

	genvar gk;
	generate
		for (gk = 1; gk <= 4; gk = gk + 1) begin : g_spec_k
			am_shift #(.W(7), .SW(3)) h_gb_k (.a(gk[6:0]), .amt(sh4), .left(1'b1), .arith(1'b0), .y(gb_init_k[gk]));
			am_sub #(.W(8)) s_n2l (.a(LB_8),  .b({1'b0, gb_init_k[gk]}), .bi(1'b0), .d(need2_lim_w[gk]), .bo(n2l_bo_unused[gk-1]));
			am_sub #(.W(8)) s_twl (.a(LB2_8), .b({1'b0, gb_init_k[gk]}), .bi(1'b0), .d(two_lim_w[gk]),   .bo(twl_bo_unused[gk-1]));
			am_shift #(.W(5), .SW(3)) h_nb_k (.a(gk[4:0]), .amt(psl), .left(1'b1), .arith(1'b0), .y(grp_nb_init_k[gk]));

			assign gb_k[gk] = gb_r_v[(gk-1)*7 +: 7];
			assign grp_nb_k[gk] = grp_nb_r_v[(gk-1)*5 +: 5];
			am_add #(.W(LS)) a_gend_k (.a(ptr), .b(gb_k[gk][LS-1:0]), .ci(1'b0), .s(nptr_k[gk]), .co(gend_k_co_unused[gk-1]));
			assign need2_k[gk-1]    = need2_gt_lb_r[gk-1] || ({{(8-LS){1'b0}}, ptr} > need2_lim_v[(gk-1)*8 +: 8]);
			assign shift_ge_k[gk-1] = need2_ge_lb_r[gk-1] || ({{(8-LS){1'b0}}, ptr} >= need2_lim_v[(gk-1)*8 +: 8]);
			assign two_used_k[gk-1] = two_ge_2lb_r[gk-1]  || ({{(8-LS){1'b0}}, ptr} >= two_lim_v[(gk-1)*8 +: 8]);

			am_add #(.W(LS)) a_dals_k (.a(daddr_ls_lin_r), .b({{(LS-5){1'b0}}, grp_nb_k[gk]}), .ci(1'b0), .s(dals_step_k[gk]), .co(dals_k_co_unused[gk-1]));
			assign room_l_k[gk] = get_room_l_limit({{(8 - LS){1'b0}}, dals_step_k[gk]}, psl_r);
			assign room_t_k[gk] = sub4_2b(x_p_k[gk]);
			assign n_geom_k[gk] = tiled ? (room_t_k[gk] < nmax_r ? room_t_k[gk] : nmax_r) :
`ifndef MUT_RSV_SPLIT
				(room_l_k[gk] < nmax_r ? room_l_k[gk] : nmax_r);
`else
				nmax_r;
`endif
		end
	endgenerate

	/* The group's source bytes: 4 n ps, at ptr of the window (selected from parallel k=1..4 paths). */
	wire [LS-1:0] nptr_sel = (n == 3'd1) ? nptr_k[1] : (n == 3'd2) ? nptr_k[2] : (n == 3'd3) ? nptr_k[3] : nptr_k[4];
	wire need2 = (n == 3'd1) ? need2_k[0] : (n == 3'd2) ? need2_k[1] : (n == 3'd3) ? need2_k[2] : need2_k[3];
	wire [1:0] gb_co_unused = 2'd0;

	/* Split 512-bit window extraction across 8 x 64-bit shifters with replicated ptr_rep (FO <= 320). */
	localparam integer WIN_SL_W = LBITS + 64;
	wire [1023:0] win_padded;
	generate
		if (2 * LBITS < 1024) begin : g_wpad_s
			assign win_padded = {{(1024 - 2 * LBITS){1'b0}}, w1, w0};
		end else begin : g_wpad_f
			assign win_padded = {w1, w0};
		end
	endgenerate
	wire [1024+WIN_SL_W-1:0] win_src_ext = {{WIN_SL_W{1'b0}}, win_padded};
	wire [511:0] win_512;
	genvar gw_sl;
	generate
		for (gw_sl = 0; gw_sl < 8; gw_sl = gw_sl + 1) begin : g_win_sl
			wire [WIN_SL_W-1:0] sl_out;
			am_shift #(.W(WIN_SL_W), .SW(LS + 3), .DIR(1)) h_win_sl (
				.a(win_src_ext[gw_sl*64 +: WIN_SL_W]),
				.amt({ptr_rep[gw_sl*LS +: LS], 3'b000}),
				.left(1'b0), .arith(1'b0), .y(sl_out)
			);
			assign win_512[gw_sl*64 +: 64] = sl_out[63:0];
		end
	endgenerate
	wire [1023:0] win = {512'd0, win_512};

	wire [127:0] avg, favg;
	wire slow = fmt == 3'd3 || fmt == 3'd4 || fmt == 3'd5;	/* sRGB, the floats */
	reg a_pend;	/* a slow group is being averaged */
	wire f_valid, f_ready;

	/* Stage P: Pipeline register between window extraction and average computation */
	reg p_v;
	reg [511:0] p_win;
	reg [LA_W-1:0] p_line;
	reg [LS-1:0] p_off;
	reg [4:0] p_nb;
	(* max_fanout = 16 *) reg [2:0] p_fmt;
	(* max_fanout = 16 *) reg [2:0] p_psl;
	reg p_is_s0;

	wire [191:0] avg_csa_s, avg_csa_c;
	wire [127:0] s0_val;

	atg_blt_avg_s1 av_s1 (
		.fmt(p_fmt),
		.psl(p_psl),
		.in_s(p_win),
		.csa_s_out(avg_csa_s),
		.csa_c_out(avg_csa_c),
		.s0_only(s0_val)
	);

	/* Stage P1: Pipeline register between CSA unpack and final rounding/format pack */
	reg p1_v;
	reg [LA_W-1:0] p1_line;
	reg [LS-1:0] p1_off;
	reg [4:0] p1_nb;
	reg [2:0] p1_fmt;
	reg [2:0] p1_psl;
	reg p1_is_s0;
	reg [191:0] p1_csa_s;
	reg [191:0] p1_csa_c;
	reg [127:0] p1_s0;

	atg_blt_avg_s2 av_s2 (
		.fmt(p1_fmt),
		.psl(p1_psl),
		.csa_s_in(p1_csa_s),
		.csa_c_in(p1_csa_c),
		.avg_only(avg)
	);

	/* Stage A: the average of the group. */
	reg a_v;
	reg [1:0] a_src;	/* 0: avg, 1: s0, 2: flt */
	reg [LA_W-1:0] a_line;
	reg [LS-1:0] a_off;
	(* keep = "true" *) reg [5*LS-1:0] a_off_rep;
	reg [4:0] a_nb;		/* bytes */
	reg [127:0] a_px_avg;
	reg [127:0] a_px_s0;
	reg [127:0] a_px_flt;
	wire [127:0] a_px = (a_src == 2'd2) ? a_px_flt : (a_src == 2'd1 ? a_px_s0 : a_px_avg);

	/* Stage B: the line being assembled. */
	reg b_v;
	reg [LA_W-1:0] b_line;
	reg [LBITS-1:0] b_d;
	reg [LB-1:0] b_be;

	wire wr_free = !wr_valid || wr_ready;
	wire a_same = b_v && b_line == a_line;
	wire a_take = a_v && (!b_v || a_same || wr_free);
	wire a_free = !a_v || !b_v || (b_line == a_line) || wr_free;
	wire p1_free = !p1_v || a_free;
	wire p_free = !p_v || p1_free;
	wire fire_cond = active && v0 && (!need2 || v1) && (slow ? (!p_v && !p1_v && a_free) : p_free) && !a_pend;
	(* max_fanout = 16 *) wire fire_data = fire_cond;
	wire fire_ctrl = fire_cond;

	reg fv_start;
	reg [2:0] fv_n;
	reg [511:0] fv_in_s;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			fv_start <= 1'b0;
		end else if (stop) begin
			fv_start <= 1'b0;
		end else begin
			fv_start <= fire_ctrl && slow;
		end
	end

	always @(posedge clk) begin
		fv_n <= n;
		fv_in_s <= win[511:0];
	end

	atg_blt_favg fv (
		.clk(clk), .rst_n(frst_n), .i_valid(fv_start), .i_ready(f_ready), .fmt(fmt), .psl(psl),
		.npx(fv_n), .in_s(fv_in_s), .o_valid(f_valid), .o_ready(1'b1), .out_p(favg)
	);
	wire rem_fits = rem[2:0] <= n_geom_r;
	wire is_last_group = !rem_has_high && rem_fits;
	wire row_end = fire_ctrl && is_last_group;

	/* gend less one or two lines (the window's lines the group used up; only one is taken in a cycle). */
	wire shift_ge = (n == 3'd1) ? shift_ge_k[0] : (n == 3'd2) ? shift_ge_k[1] : (n == 3'd3) ? shift_ge_k[2] : shift_ge_k[3];
	wire two_used = (n == 3'd1) ? two_used_k[0] : (n == 3'd2) ? two_used_k[1] : (n == 3'd3) ? two_used_k[2] : two_used_k[3];
	wire shift_win = fire_ctrl && shift_ge && !two_used;
	wire drop_both = fire_ctrl && (two_used || row_end);

	/* The window after this cycle's group (before a load). */
	wire [LS-1:0] nptr = fire_ctrl ? nptr_sel : ptr;

	wire wr_buf0 = lq_pop && (head == v0);
	wire wr_buf1 = lq_pop && (head != v0);

	wire may_load = active && lines_left_nz;
	assign lq_pop = may_load && lq_valid && (!v0 || !v1);
	assign ln_pop = lq_valid && lq_pop;
	assign rq_pop = !active && !p_v && !a_pend && rq_valid;

	/* The merge: 8B-align (W=88) + 64b-slot placement cuts a_off_rep fanout from ~1090 to <= 150. */
	localparam integer NSLOT = LB / 8;
	wire [LBITS-1:0] a_shf_w [0:3];
	genvar gsw, gss;
	generate
		for (gsw = 0; gsw < 4; gsw = gsw + 1) begin : g_shf_w
			wire [LS-1:0] w_off = a_off_rep[(gsw + 1)*LS +: LS];
			wire [87:0] al_w;
			am_shift #(.W(88), .SW(6), .DIR(2)) h_al_w (
				.a({56'd0, a_px[gsw*32 +: 32]}),
				.amt({w_off[2:0], 3'b000}),
				.left(1'b1), .arith(1'b0), .y(al_w)
			);
			for (gss = 0; gss < NSLOT; gss = gss + 1) begin : g_slot
				localparam integer SM1 = (gss > 0) ? (gss - 1) : 0;
				wire hit0 = (w_off[LS-1:3] == gss[LS-4:0]);
				wire hit1 = (gss > 0) && (w_off[LS-1:3] == SM1[LS-4:0]);
				assign a_shf_w[gsw][gss*64 +: 64] =
					(hit0 ? al_w[63:0] : 64'd0) |
					(hit1 ? {40'd0, al_w[87:64]} : 64'd0);
			end
		end
	endgenerate
	wire [LBITS-1:0] a_shf = a_shf_w[0] |
		{a_shf_w[1][LBITS-33:0], 32'd0} |
		{a_shf_w[2][LBITS-65:0], 64'd0} |
		{a_shf_w[3][LBITS-97:0], 96'd0};
	wire [2*LB-1:0] a_ones;	/* the lowest a_nb bits set (a_nb < 2 LB): 2^a_nb - 1 */
	wire [LB-1:0] a_be;

	genvar ob;
	generate
		for (ob = 0; ob < 2 * LB; ob = ob + 1) begin : g_ones
			assign a_ones[ob] = ob < a_nb;
		end
	endgenerate
	am_shift #(.W(LB), .SW(LS)) h_be (.a(a_ones[LB-1:0]), .amt(a_off_rep[0*LS +: LS]), .left(1'b1), .arith(1'b0), .y(a_be));

	/* The row's counts: the lines left, the next pixel and the pixels left; a group's bytes. */
	wire [16:0] ll_dec, x_next, rem_next;
	wire [4:0] grp_nb = (n == 3'd1) ? grp_nb_k[1] : (n == 3'd2) ? grp_nb_k[2] : (n == 3'd3) ? grp_nb_k[3] : grp_nb_k[4];
	wire [2:0] row_co_unused;

	am_sub #(.W(17)) s_ll (.a(lines_left), .b(17'd0), .bi(1'b1), .d(ll_dec), .bo(row_co_unused[0]));
	am_add #(.W(17)) a_x (.a(x), .b({14'd0, n}), .ci(1'b0), .s(x_next), .co(row_co_unused[1]));
	am_sub #(.W(17)) s_rem (.a(rem), .b({14'd0, n}), .bi(1'b0), .d(rem_next), .bo(row_co_unused[2]));

	assign daddr_ls_step = (n == 3'd1) ? dals_step_k[1] : (n == 3'd2) ? dals_step_k[2] : (n == 3'd3) ? dals_step_k[3] : dals_step_k[4];
	wire [2:0] room_l_next = (n == 3'd1) ? room_l_k[1] : (n == 3'd2) ? room_l_k[2] : (n == 3'd3) ? room_l_k[3] : room_l_k[4];
	wire [2:0] n_geom_next = (n == 3'd1) ? n_geom_k[1] : (n == 3'd2) ? n_geom_k[2] : (n == 3'd3) ? n_geom_k[3] : n_geom_k[4];

	wire [2:0] room_l_init = get_room_l_limit({{(8 - LS){1'b0}}, daddr_ls_init}, psl);
	wire [2:0] room_t_init = sub4_2b(d_x[1:0]);
	wire [2:0] n_geom_init = tiled ? (room_t_init < nmax ? room_t_init : nmax) :
`ifndef MUT_RSV_SPLIT
		(room_l_init < nmax ? room_l_init : nmax);
`else
		nmax;
`endif
	reg [LBITS-1:0] a_sh;	/* only the group's bytes: the average's other pixels are 0 */
	integer i;

	always @(*) begin
		for (i = 0; i < LB; i = i + 1)
			a_sh[8 * i +: 8] = a_be[i] ? a_shf[8 * i +: 8] : 8'd0;
	end

	wire idle_now = !active && !rq_valid && !p_v && !p1_v && !a_v && !a_pend;
	assign idle = idle_now && !b_v && !wr_valid;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			active <= 1'b0;
			x <= 17'd0;
			rem <= 17'd0;
			rem_has_high <= 1'b0;
			drow <= {ADDR_W{1'b0}};
			lines_left <= 17'd0;
			lines_left_nz <= 1'b0;
			daddr_ls_lin_r <= {LS{1'b0}};
			room_l_limit_r <= 3'd4;
			n_geom_r <= 3'd4;
			sh4_r <= 3'd2;
			nmax_r <= 3'd4;
			psl_r <= 3'd0;
			gb_r_v <= 28'd0;
			need2_lim_v <= 32'd0;
			two_lim_v <= 32'd0;
			need2_gt_lb_r <= 4'd0;
			need2_ge_lb_r <= 4'd0;
			two_ge_2lb_r <= 4'd0;
			grp_nb_r_v <= 20'd0;
			head <= 1'b0;
			head_rep <= 16'd0;
			v0 <= 1'b0;
			v1 <= 1'b0;
			ptr <= {LS{1'b0}};
			ptr_rep <= {(8*LS){1'b0}};
			p_v <= 1'b0;
			p_line <= {LA_W{1'b0}};
			p_off <= {LS{1'b0}};
			p_nb <= 5'd0;
			p_fmt <= 3'd0;
			p_psl <= 3'd0;
			p_is_s0 <= 1'b0;
			p1_v <= 1'b0;
			p1_line <= {LA_W{1'b0}};
			p1_off <= {LS{1'b0}};
			p1_nb <= 5'd0;
			p1_fmt <= 3'd0;
			p1_psl <= 3'd0;
			p1_is_s0 <= 1'b0;
			p1_csa_s <= 192'd0;
			p1_csa_c <= 192'd0;
			p1_s0 <= 128'd0;
			a_v <= 1'b0;
			a_src <= 2'd0;
			a_pend <= 1'b0;
			a_line <= {LA_W{1'b0}};
			a_off <= {LS{1'b0}};
			a_off_rep <= {(5*LS){1'b0}};
			a_nb <= 5'd0;
			b_v <= 1'b0;
			b_line <= {LA_W{1'b0}};
			b_be <= {LB{1'b0}};
			wr_valid <= 1'b0;
			wr_line <= {LA_W{1'b0}};
			wr_be <= {LB{1'b0}};
		end else if (stop) begin
			active <= 1'b0;
			x <= 17'd0;
			rem <= 17'd0;
			rem_has_high <= 1'b0;
			drow <= {ADDR_W{1'b0}};
			lines_left <= 17'd0;
			lines_left_nz <= 1'b0;
			daddr_ls_lin_r <= {LS{1'b0}};
			room_l_limit_r <= 3'd4;
			n_geom_r <= 3'd4;
			sh4_r <= 3'd2;
			nmax_r <= 3'd4;
			psl_r <= 3'd0;
			gb_r_v <= 28'd0;
			need2_lim_v <= 32'd0;
			two_lim_v <= 32'd0;
			need2_gt_lb_r <= 4'd0;
			need2_ge_lb_r <= 4'd0;
			two_ge_2lb_r <= 4'd0;
			grp_nb_r_v <= 20'd0;
			head <= 1'b0;
			head_rep <= 16'd0;
			v0 <= 1'b0;
			v1 <= 1'b0;
			ptr <= {LS{1'b0}};
			ptr_rep <= {(8*LS){1'b0}};
			p_v <= 1'b0;
			p_line <= {LA_W{1'b0}};
			p_off <= {LS{1'b0}};
			p_nb <= 5'd0;
			p_fmt <= 3'd0;
			p_psl <= 3'd0;
			p_is_s0 <= 1'b0;
			p1_v <= 1'b0;
			p1_line <= {LA_W{1'b0}};
			p1_off <= {LS{1'b0}};
			p1_nb <= 5'd0;
			p1_fmt <= 3'd0;
			p1_psl <= 3'd0;
			p1_is_s0 <= 1'b0;
			p1_csa_s <= 192'd0;
			p1_csa_c <= 192'd0;
			p1_s0 <= 128'd0;
			a_v <= 1'b0;
			a_src <= 2'd0;
			a_pend <= 1'b0;
			a_line <= {LA_W{1'b0}};
			a_off <= {LS{1'b0}};
			a_off_rep <= {(5*LS){1'b0}};
			a_nb <= 5'd0;
			b_v <= 1'b0;
			b_line <= {LA_W{1'b0}};
			b_be <= {LB{1'b0}};
			wr_valid <= 1'b0;
			wr_line <= {LA_W{1'b0}};
			wr_be <= {LB{1'b0}};
		end else begin
			/* A new row. */
			if (rq_pop) begin
				active <= 1'b1;
				x <= d_x;
				rem <= d_w;
				rem_has_high <= |d_w[16:3];
				drow <= d_drow;
				lines_left <= d_nl;
				lines_left_nz <= (d_nl != 17'd0);
				daddr_ls_lin_r <= daddr_ls_init;
				room_l_limit_r <= room_l_init;
				n_geom_r <= n_geom_init;
				sh4_r <= sh4;
				nmax_r <= nmax;
				psl_r <= psl;
				gb_r_v <= {gb_init_k[4], gb_init_k[3], gb_init_k[2], gb_init_k[1]};
				need2_lim_v <= {need2_lim_w[4], need2_lim_w[3], need2_lim_w[2], need2_lim_w[1]};
				two_lim_v   <= {two_lim_w[4], two_lim_w[3], two_lim_w[2], two_lim_w[1]};
				need2_gt_lb_r <= {({1'b0, gb_init_k[4]} > LB_8), ({1'b0, gb_init_k[3]} > LB_8),
					({1'b0, gb_init_k[2]} > LB_8), ({1'b0, gb_init_k[1]} > LB_8)};
				need2_ge_lb_r <= {({1'b0, gb_init_k[4]} >= LB_8), ({1'b0, gb_init_k[3]} >= LB_8),
					({1'b0, gb_init_k[2]} >= LB_8), ({1'b0, gb_init_k[1]} >= LB_8)};
				two_ge_2lb_r  <= {({1'b0, gb_init_k[4]} >= LB2_8), ({1'b0, gb_init_k[3]} >= LB2_8),
					({1'b0, gb_init_k[2]} >= LB2_8), ({1'b0, gb_init_k[1]} >= LB2_8)};
				grp_nb_r_v <= {grp_nb_init_k[4], grp_nb_init_k[3], grp_nb_init_k[2], grp_nb_init_k[1]};
				ptr <= d_off;
				ptr_rep <= {8{d_off}};
				v0 <= 1'b0;
				v1 <= 1'b0;
				head <= 1'b0;
				head_rep <= 16'd0;
				p_v <= 1'b0;
				p_fmt <= fmt;
				p_psl <= psl;
				p_is_s0 <= (fmt != 3'd0 && fmt != 3'd1 && fmt != 3'd6 && fmt != 3'd7);
			end else begin
				/* The window: load into ping-pong buffers */
				ptr <= nptr;
				ptr_rep <= {8{nptr}};
				if (wr_buf0)
					buf0 <= lq_data;
				if (wr_buf1)
					buf1 <= lq_data;
				if (drop_both) begin
					head <= 1'b0;
					head_rep <= 16'd0;
					v0 <= 1'b0;
					v1 <= 1'b0;
				end else if (shift_win) begin
					head <= ~head;
					head_rep <= {16{~head}};
					v0 <= v1 | lq_pop;
					v1 <= 1'b0;
				end else if (lq_pop) begin
					if (!v0)
						v0 <= 1'b1;
					else
						v1 <= 1'b1;
				end
				if (lq_pop) begin
					lines_left <= ll_dec;
					lines_left_nz <= (ll_dec != 17'd0);
				end
				if (fire_ctrl) begin
					x <= x_next;
					rem <= rem_next;
					rem_has_high <= |rem_next[16:3];
					daddr_ls_lin_r <= daddr_ls_step;
					room_l_limit_r <= room_l_next;
					n_geom_r <= n_geom_next;
					if (row_end)
						active <= 1'b0;
				end
			end

			/* The write being handed over. */
			if (wr_valid && wr_ready)
				wr_valid <= 1'b0;

			/* Stage B. */
			if (a_take) begin
				if (b_v && !a_same) begin
					wr_valid <= 1'b1;
					wr_line <= b_line;
					wr_be <= b_be;
					wr_data <= b_d;
				end
				b_v <= 1'b1;
				b_line <= a_line;
				if (a_same) begin
					b_d <= b_d | a_sh;
					b_be <= b_be | a_be;
				end else begin
					b_d <= a_sh;
					b_be <= a_be;
				end
			end else if (!a_v && b_v && idle_now && wr_free) begin
				wr_valid <= 1'b1;
				wr_line <= b_line;
				wr_be <= b_be;
				wr_data <= b_d;
				b_v <= 1'b0;
			end

			/* Stage P. */
			if (fire_data) begin
				p_win <= win[511:0];
				p_line <= daddr[ADDR_W-1:LS];
				p_off <= daddr[LS-1:0];
				p_nb <= grp_nb;
			end
			if (fire_ctrl && !slow) begin
				p_v <= 1'b1;
			end else if (p1_free) begin
				p_v <= 1'b0;
			end

			/* Stage P1. */
			if (p_v && p1_free) begin
				p1_v <= 1'b1;
				p1_line <= p_line;
				p1_off <= p_off;
				p1_nb <= p_nb;
				p1_fmt <= p_fmt;
				p1_psl <= p_psl;
				p1_is_s0 <= p_is_s0;
				p1_csa_s <= avg_csa_s;
				p1_csa_c <= avg_csa_c;
				p1_s0 <= s0_val;
			end else if (a_free) begin
				p1_v <= 1'b0;
			end

			/* Stage A. */
			if (p1_v && a_free) begin
				a_v <= 1'b1;
				a_line <= p1_line;
				a_off <= p1_off;
				a_off_rep <= {5{p1_off}};
				a_nb <= p1_nb;
				if (p1_is_s0) begin
					a_src <= 2'd1;
					a_px_s0 <= p1_s0;
				end else begin
					a_src <= 2'd0;
					a_px_avg <= avg;
				end
			end else if (a_pend && f_valid) begin
				a_v <= 1'b1;
				a_src <= 2'd2;
				a_pend <= 1'b0;
				a_line <= p_line;
				a_off <= p_off;
				a_off_rep <= {5{p_off}};
				a_nb <= p_nb;
				a_px_flt <= favg;
			end else if (a_take) begin
				a_v <= 1'b0;
			end

			if (fire_ctrl && slow) begin
				a_pend <= 1'b1;
			end
		end
	end

`ifdef RSV_TRACE
	always @(posedge clk)
		if (fire_ctrl)
			$display("%m t=%0t group daddr %h n %0d ptr %0d v %b%b avg %h win0 %h", $time, daddr,
				n, ptr, v0, v1, avg[63:0], win[127:0]);
`endif

	wire unused_ok = &{1'b0, f_ready, lq_ready, rq_count, win[1023:512], a_ones[2*LB-1:LB],
		a_shf_w[1][LBITS-1:LBITS-32], a_shf_w[2][LBITS-1:LBITS-64], a_shf_w[3][LBITS-1:LBITS-96],
		grp_co_unused, gb_co_unused, row_co_unused, dals_init_co, n2l_bo_unused, twl_bo_unused,
		lncnt_co_unused, gend_k_co_unused, dals_k_co_unused, rem_limit, room_t, room_l_limit_r,
		a_off, sh4_r};
endmodule

`default_nettype wire
