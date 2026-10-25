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
	parameter DEPTH_LOG2 = 2,	/* source line FIFO: 2^DEPTH_LOG2 lines */
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

	/* The source lines. */
	wire lq_valid;
	wire lq_pop;
	wire [LBITS-1:0] lq_data;
	wire lq_ready;

	am_fifo #(.W(LBITS), .DEPTH_LOG2(DEPTH_LOG2)) lq (
		.clk(clk),
		.rst_n(frst_n),
		.in_valid(ln_push && !stop),
		.in_ready(lq_ready),
		.in_data(ln_data),
		.out_valid(lq_valid),
		.out_ready(lq_pop),
		.out_data(lq_data),
		.count(ln_count)
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
	reg [ADDR_W-1:0] drow;
	reg [16:0] lines_left;
	reg [LBITS-1:0] w0;
	reg [LBITS-1:0] w1;
	reg v0;
	reg v1;
	reg [LS-1:0] ptr;

	/* The group: n pixels at x. */
	wire [LS:0] nfit = LB_V >> (psl + 3'd2);
	wire [2:0] nmax = nfit == {(LS + 1){1'b0}} ? 3'd1 : nfit >= 4 ? 3'd4 : nfit[2:0];
	wire [ADDR_W-1:0] x_lin = {{(ADDR_W - 17){1'b0}}, x} << psl;
	wire [ADDR_W-1:0] x_til = {{(ADDR_W - 19){1'b0}}, x[16:2], 2'b00, x[1:0]} << psl;
	wire [ADDR_W-1:0] daddr = drow + (tiled ? x_til : x_lin);
	wire [LS:0] room_b = LB_V - {1'b0, daddr[LS-1:0]};
	wire [LS:0] room_l = room_b >> psl;
	wire [2:0] room_t = 3'd4 - {1'b0, x[1:0]};
	reg [2:0] n;

	always @(*) begin
		n = nmax;
		if (rem < {14'd0, n})
			n = rem[2:0];
		if (tiled) begin
			if (room_t < n)
				n = room_t;
		end else begin
`ifndef MUT_RSV_SPLIT
			if (room_l < {{(LS - 2){1'b0}}, n})
				n = room_l[2:0];
`endif
		end
	end

	/* The group's source bytes: 4 n ps, at ptr of the window. */
	wire [6:0] gb = {4'd0, n} << (psl + 3'd2);
	wire [7:0] gend = {{(7 - LS){1'b0}}, ptr} + {1'b0, gb};
	wire need2 = gend > {{(7 - LS){1'b0}}, LB_V};

	wire [1023:0] win;
	generate
		if (2 * LBITS < 1024) begin : g_pad
			assign win = {{(1024 - 2 * LBITS){1'b0}}, w1, w0} >> {ptr, 3'b000};
		end else begin : g_full
			assign win = {w1, w0} >> {ptr, 3'b000};
		end
	endgenerate

	wire [127:0] avg, favg;
	wire slow = fmt == 3'd3 || fmt == 3'd4 || fmt == 3'd5;	/* sRGB, the floats */
	reg a_pend;	/* a slow group is being averaged */
	wire f_valid, f_ready;

	atg_blt_avg av (
		.fmt(fmt),
		.psl(psl),
		.in_s(win[511:0]),
		.out_p(avg)
	);

	/* Stage A: the average of the group. */
	reg a_v;
	reg [LA_W-1:0] a_line;
	reg [LS-1:0] a_off;
	reg [4:0] a_nb;		/* bytes */
	reg [127:0] a_px;

	/* Stage B: the line being assembled. */
	reg b_v;
	reg [LA_W-1:0] b_line;
	reg [LBITS-1:0] b_d;
	reg [LB-1:0] b_be;

	wire wr_free = !wr_valid || wr_ready;
	wire a_same = b_v && b_line == a_line;
	wire a_take = a_v && (!b_v || a_same || wr_free);
	wire a_free = !a_v || a_take;
	wire fire = active && v0 && (!need2 || v1) && a_free && !a_pend;

	atg_blt_favg fv (
		.clk(clk), .rst_n(frst_n), .i_valid(fire && slow), .i_ready(f_ready), .fmt(fmt), .psl(psl),
		.npx(n), .in_s(win[511:0]), .o_valid(f_valid), .o_ready(1'b1), .out_p(favg)
	);
	wire row_end = fire && rem == {14'd0, n};

	/* The window after this cycle's group (before a load). */
	reg [LBITS-1:0] nw0;
	reg nv0;
	reg nv1;
	reg [LS-1:0] nptr;
	reg [7:0] pend;

	always @(*) begin
		nw0 = w0;
		nv0 = v0;
		nv1 = v1;
		nptr = ptr;
		pend = gend;
		if (fire) begin
			if (gend >= {{(6 - LS){1'b0}}, LB_V, 1'b0}) begin
				/* both lines used (16-byte pixels, 32-byte lines) */
				nv0 = 1'b0;
				nv1 = 1'b0;
				pend = gend - {{(6 - LS){1'b0}}, LB_V, 1'b0};
			end else if (gend >= {{(7 - LS){1'b0}}, LB_V}) begin
				nw0 = w1;
				nv0 = v1;
				nv1 = 1'b0;
				pend = gend - {{(7 - LS){1'b0}}, LB_V};
			end
			nptr = pend[LS-1:0];
			if (row_end) begin
				nv0 = 1'b0;
				nv1 = 1'b0;
			end
		end
	end

`ifdef MUT_RSV_ROWEND
	wire may_load = active && !row_end;
`else
	wire may_load = active && !row_end && lines_left != 17'd0;
`endif
	assign lq_pop = may_load && lq_valid && (!nv0 || !nv1);
	assign rq_pop = !active && rq_valid;

	/* The merge: the group's bytes at their offset of the line. */
	wire [LBITS-1:0] a_shf = {{(LBITS - 128){1'b0}}, a_px} << {a_off, 3'b000};
	wire [2*LB-1:0] a_ones = ({{(2 * LB - 1){1'b0}}, 1'b1} << a_nb) - 1'b1;
	wire [LB-1:0] a_be = a_ones[LB-1:0] << a_off;
	reg [LBITS-1:0] a_sh;	/* only the group's bytes: the average's other pixels are 0 */
	integer i;

	always @(*) begin
		for (i = 0; i < LB; i = i + 1)
			a_sh[8 * i +: 8] = a_be[i] ? a_shf[8 * i +: 8] : 8'd0;
	end

	wire idle_now = !active && !rq_valid && !a_v && !a_pend;
	assign idle = idle_now && !b_v && !wr_valid;

	always @(posedge clk) begin
		if (!rst_n || stop) begin
			active <= 1'b0;
			x <= 17'd0;
			rem <= 17'd0;
			drow <= {ADDR_W{1'b0}};
			lines_left <= 17'd0;
			w0 <= {LBITS{1'b0}};
			w1 <= {LBITS{1'b0}};
			v0 <= 1'b0;
			v1 <= 1'b0;
			ptr <= {LS{1'b0}};
			a_v <= 1'b0;
			a_pend <= 1'b0;
			a_line <= {LA_W{1'b0}};
			a_off <= {LS{1'b0}};
			a_nb <= 5'd0;
			a_px <= 128'd0;
			b_v <= 1'b0;
			b_line <= {LA_W{1'b0}};
			b_d <= {LBITS{1'b0}};
			b_be <= {LB{1'b0}};
			wr_valid <= 1'b0;
			wr_line <= {LA_W{1'b0}};
			wr_be <= {LB{1'b0}};
			wr_data <= {LBITS{1'b0}};
		end else begin
			/* A new row. */
			if (rq_pop) begin
				active <= 1'b1;
				x <= d_x;
				rem <= d_w;
				drow <= d_drow;
				lines_left <= d_nl;
				ptr <= d_off;
				v0 <= 1'b0;
				v1 <= 1'b0;
			end else begin
				/* The window: the group, then a load. */
				w0 <= nw0;
				v0 <= nv0;
				v1 <= nv1;
				ptr <= nptr;
				if (lq_pop) begin
					lines_left <= lines_left - 1'b1;
					if (!nv0) begin
						w0 <= lq_data;
						v0 <= 1'b1;
					end else begin
						w1 <= lq_data;
						v1 <= 1'b1;
					end
				end
				if (fire) begin
					x <= x + {14'd0, n};
					rem <= rem - {14'd0, n};
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

			/* Stage A. */
			if (fire) begin
				a_v <= !slow;
				a_pend <= slow;
				a_line <= daddr[ADDR_W-1:LS];
				a_off <= daddr[LS-1:0];
				a_nb <= {2'd0, n} << psl;
				a_px <= avg;
			end else if (a_pend && f_valid) begin
				a_v <= 1'b1;
				a_pend <= 1'b0;
				a_px <= favg;
			end else if (a_take) begin
				a_v <= 1'b0;
			end
		end
	end

`ifdef RSV_TRACE
	always @(posedge clk)
		if (fire)
			$display("%m t=%0t group daddr %h n %0d ptr %0d v %b%b avg %h win0 %h", $time, daddr,
				n, ptr, v0, v1, avg[63:0], win[127:0]);
`endif

	wire unused_ok = &{1'b0, f_ready, lq_ready, rq_count, win[1023:512], a_ones[2*LB-1:LB], room_b[1:0], pend};
endmodule

`default_nettype wire
