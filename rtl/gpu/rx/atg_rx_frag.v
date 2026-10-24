/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_frag: the RX's fragment warps (WS288 p009): packs up to 8
 * covered quads of one triangle (from atg_rx_scan, fq_*) into a 32-lane
 * warp of SU 0, copies the triangle's 3 × VARYING_COUNT varying words
 * from the PT into the warp's primitive table (and its primitive map, 0:
 * one triangle per warp), writes r0-r5 of every lane of the quads
 * (b0, b1, b2, z, x + 0.5, y + 0.5) and starts the warp with a new
 * sequence number.
 *
 * Per lane, i = x - bbox x0 and j = y - bbox y0 (fp32), one fmul, one
 * fadd and one fdiv of the RX:
 *   P = (A i + B j) + C for the planes z, 1/w, b0/w, b1/w of atg_rx_setup
 *   (the four lanes interleaved, the planes 8 cycles apart: 44 cycles);
 *   z clamped to [0, 1] like the direct path; r = 1 / (1/w) (fdiv, per
 *   lane); b0 = (b0/w) r, b1 = (b1/w) r, b2 = (1 - b0) - b1.
 * About 200 cycles per quad; one quad at a time (v1).
 *
 * States: COL (quads in) →(8 quads, or the triangle's end after some)→
 * ALLOC (fl_req) →(fl_gnt)→ COPY → (per quad: PL → DIV → BC → WR) → GO →
 * COL.  See spec/gpu/rx/atg_rx_frag.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_frag (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (VARYING_COUNT, 0x05B) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* The set-up triangle (atg_rx_setup's sp_tri, taken with the scan) */
	input wire t_load,
	input wire [767:0] t_tri,
	/* Covered quads from atg_rx_scan */
	input wire fq_valid,
	output wire fq_ready,
	input wire [31:0] fq_xy,
	input wire [3:0] fq_cov,
	input wire fq_end,
	output wire busy,
	/* PT of SU 0 (read port shared with atg_rx_clip, which waits while pt_busy) */
	output wire pt_rd,
	output wire [7:0] pt_idx,
	output wire [5:0] pt_word,
	input wire [31:0] pt_rdata,
	output wire pt_busy,
	/* Fragment warps to the SU (atg_su fl_*) */
	output wire fl_req,
	input wire fl_gnt,
	output wire fl_we,
	output wire [5:0] fl_reg,
	output wire [4:0] fl_lane,
	output wire [31:0] fl_data,
	output wire fl_pw_we,
	output wire [11:0] fl_pw_addr,
	output wire [31:0] fl_pw_data,
	output wire fl_go,
	output wire [31:0] fl_mask,
	output wire [63:0] fl_info,
	/* Sequence numbers (atg_rx_order) */
	output wire sq_req,
	input wire [15:0] sq_seq
);
	`include "ghci_regs.vh"
	localparam [2:0] S_COL = 3'd0, S_ALLOC = 3'd1, S_COPY = 3'd2, S_PL = 3'd3, S_DIV = 3'd4,
		S_BC = 3'd5, S_WR = 3'd6, S_GO = 3'd7;
	localparam [31:0] ONE = 32'h3F800000;
	reg [2:0] st;

	/* a small signed integer to fp32 (exact), as atg_rx_scan */
	function [31:0] i2f;
		input [16:0] v;
		reg [16:0] m;
		reg [4:0] lz;
		integer b;
		begin
			m = v[16] ? -v : v;
			lz = 5'd0;
			for (b = 0; b < 17; b = b + 1)
				if (m[b])
					lz = 5'd16 - b[4:0];
			m = m << lz;
			i2f = m == 17'd0 ? 32'd0 : {v[16], 8'd127 + 8'd16 - {3'd0, lz}, m[15:0], 7'd0};
		end
	endfunction

	reg [5:0] vc;	/* VARYING_COUNT */
	always @(posedge clk)
		if (!rst_n)
			vc <= 6'd0;
		else if (st_we && st_idx == GHCI_S_VARYING_COUNT)
			vc <= st_wdata[5:0] > 6'd32 ? 6'd32 : st_wdata[5:0];

	/* The triangle: 12 plane words (z, 1/w, b0/w, b1/w × A, B, C), bbox origin, PT entries. */
	reg [383:0] pl;
	reg [15:0] bx0, by0;
	reg [23:0] ent;
	reg front;
	always @(posedge clk)
		if (t_load) begin
			pl <= t_tri[735:352];
			bx0 <= t_tri[303:288];
			by0 <= t_tri[319:304];
			ent <= t_tri[759:736];
			front <= t_tri[763];
		end

	/* The warp's quads. */
	reg [127:0] qbx, qby;
	reg [31:0] qbc;
	reg [3:0] n;	/* quads collected */
	reg [2:0] qi;	/* the quad being written */
	assign fq_ready = st == S_COL && n < 4'd8;
	wire fq_take = fq_valid && fq_ready;

	/* Lane offsets of the current quad. */
	wire [15:0] qx = qbx[16 * qi +: 16], qy = qby[16 * qi +: 16];
	reg [5:0] c;	/* step counter */
	wire [1:0] l = c[1:0];
	wire [31:0] fi = i2f({1'b0, qx} + {16'd0, l[0]} - {1'b0, bx0});
	wire [31:0] fj = i2f({1'b0, qy} + {16'd0, l[1]} - {1'b0, by0});

	/* Per-lane values: v[p*4+l] for the planes p (z, 1/w, b0/w, b1/w); t1; r; b0, b1, b2. */
	reg [31:0] v [0:15];
	reg [31:0] t1 [0:3];
	reg [31:0] rw [0:3];
	reg [31:0] b0 [0:3];
	reg [31:0] b1 [0:3];
	reg [31:0] b2 [0:3];

	/* The fp units. */
	wire [1:0] pm = c[4:3];	/* the plane of a multiply in PL */
	wire [1:0] pa = c[4:3] - 2'd1;	/* of an add */
	wire fm_v = (st == S_PL && c < 6'd32) || (st == S_BC && c < 6'd8);
	wire [31:0] fm_a = st == S_BC ? (c[2] ? v[{2'd3, l}] : v[{2'd2, l}]) :
		pl[32 * (3 * pm + (c[2] ? 1 : 0)) +: 32];
	wire [31:0] fm_b = st == S_BC ? rw[l] : c[2] ? fj : fi;
	wire fm_o, fa_o;
	wire [31:0] fm_r, fa_r;
	atg_rx_fmul fmul (.clk(clk), .rst_n(rst_n), .i_valid(fm_v), .i_a(fm_a), .i_b(fm_b),
		.o_valid(fm_o), .o_r(fm_r));
	wire fa_v = (st == S_PL && c >= 6'd8 && c < 6'd40) || (st == S_BC && c >= 6'd4 && c < 6'd12);
	wire [31:0] fa_a = st == S_BC ? (c < 6'd8 ? ONE : fa_r) : c[2] ? fa_r : t1[l];
	wire [31:0] fa_b = st == S_BC ? fm_r : c[2] ? pl[32 * (3 * pa + 2) +: 32] : fm_r;
	atg_rx_fadd fadd (.clk(clk), .rst_n(rst_n), .i_valid(fa_v), .i_a(fa_a), .i_b(fa_b),
		.i_sub(st == S_BC), .o_valid(fa_o), .o_r(fa_r));
	wire [31:0] zcl = fa_r[31] || (fa_r[30:23] == 8'hFF && fa_r[22:0] != 23'd0) ? 32'd0 :
		fa_r > ONE ? ONE : fa_r;
	reg dgo;
	wire fd_busy, fd_done;
	wire [31:0] fd_r;
	atg_rx_fdiv fdiv (.clk(clk), .rst_n(rst_n), .i_start(st == S_DIV && !dgo), .i_a(ONE),
		.i_b(v[{2'd1, l}]), .busy(fd_busy), .o_done(fd_done), .o_r(fd_r));

	/* The copy: reads (cv, cw) → writes the next cycle. */
	reg [1:0] cv;
	reg [5:0] cw;
	reg rd_done, rv_q, map_done;
	reg [1:0] rv_v;
	reg [5:0] rv_w;
	wire rd_now = st == S_COPY && !rd_done;
	assign pt_rd = rd_now;
	assign pt_idx = ent[8 * cv +: 8];
	assign pt_word = 6'd4 + cw;
	assign pt_busy = st == S_COPY;
	wire map_we = st == S_COPY && rd_done && !rv_q && !map_done;
	assign fl_pw_we = rv_q || map_we;
	assign fl_pw_addr = map_we ? 12'hFFF : {1'b0, 3'd0, rv_v, 6'd4 + rv_w};
	assign fl_pw_data = map_we ? 32'd0 : pt_rdata;

	/* The register writes: lane wl of the quad, register wr. */
	reg [1:0] wl;
	reg [2:0] wr;
	wire [15:0] xl = qx + {15'd0, wl[0]}, yl = qy + {15'd0, wl[1]};
	wire [31:0] xc = i2f({1'b0, xl[14:0], 1'b1}) - 32'h00800000;	/* x + 0.5 */
	wire [31:0] yc = i2f({1'b0, yl[14:0], 1'b1}) - 32'h00800000;
	assign fl_we = st == S_WR;
	assign fl_reg = {3'd0, wr};
	assign fl_lane = {qi, wl};
	assign fl_data = wr == 3'd0 ? b0[wl] : wr == 3'd1 ? b1[wl] : wr == 3'd2 ? b2[wl] :
		wr == 3'd3 ? v[{2'd0, wl}] : wr == 3'd4 ? xc : yc;

	assign fl_req = st == S_ALLOC;
	assign fl_go = st == S_GO;
	assign sq_req = st == S_GO;
	reg [31:0] qmask;
	integer k;
	always @(*)
		for (k = 0; k < 8; k = k + 1)
			qmask[4 * k +: 4] = {4{k < n}};
	assign fl_mask = qmask;
	assign fl_info = {15'd0, front, sq_seq, qbc};
	assign busy = st != S_COL || n != 4'd0;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= S_COL;
			n <= 4'd0;
			qbc <= 32'd0;
			rv_q <= 1'b0;
			dgo <= 1'b0;
		end else begin
			rv_q <= rd_now;
			rv_v <= cv;
			rv_w <= cw;
			case (st)
			S_COL:
				if (fq_take) begin
					if (fq_end) begin
						if (n != 4'd0)
							st <= S_ALLOC;
					end else begin
						qbx[16 * n[2:0] +: 16] <= fq_xy[15:0];
						qby[16 * n[2:0] +: 16] <= fq_xy[31:16];
						qbc[4 * n[2:0] +: 4] <= fq_cov;
						n <= n + 4'd1;
						if (n == 4'd7)
							st <= S_ALLOC;
					end
				end
			S_ALLOC:
				if (fl_gnt) begin
					cv <= 2'd0;
					cw <= 6'd0;
					rd_done <= vc == 6'd0;
					map_done <= 1'b0;
					st <= S_COPY;
				end
			S_COPY: begin
				if (rd_now) begin
					if (cw + 6'd1 == vc) begin
						cw <= 6'd0;
						cv <= cv + 2'd1;
						if (cv == 2'd2)
							rd_done <= 1'b1;
					end else
						cw <= cw + 6'd1;
				end
				if (map_we) begin
					map_done <= 1'b1;
					qi <= 3'd0;
					c <= 6'd0;
					st <= S_PL;
				end
			end
			S_PL: begin
				c <= c + 6'd1;
				if (c >= 6'd4 && c < 6'd36 && c[2])
					t1[l] <= fm_r;
				if (c >= 6'd16 && !c[2])
					v[{c[4:3] - 2'd2, l}] <= c[4:3] == 2'd2 ? zcl : fa_r;
				if (c == 6'd43) begin
					c <= 6'd0;
					dgo <= 1'b0;
					st <= S_DIV;
				end
			end
			S_DIV:
				if (!dgo)
					dgo <= 1'b1;
				else if (fd_done) begin
					rw[l] <= fd_r;
					dgo <= 1'b0;
					c <= c + 6'd1;
					if (l == 2'd3) begin
						c <= 6'd0;
						st <= S_BC;
					end
				end
			S_BC: begin
				c <= c + 6'd1;
				if (c >= 6'd4 && c < 6'd8)
					b0[l] <= fm_r;
				if (c >= 6'd8 && c < 6'd12)
					b1[l] <= fm_r;
				if (c >= 6'd12)
					b2[l] <= fa_r;
				if (c == 6'd15) begin
					wl <= 2'd0;
					wr <= 3'd0;
					st <= S_WR;
				end
			end
			S_WR:
				if (wr == 3'd5) begin
					wr <= 3'd0;
					wl <= wl + 2'd1;
					if (wl == 2'd3) begin
						c <= 6'd0;
						if ({1'b0, qi} + 4'd1 == n)
							st <= S_GO;
						else begin
							qi <= qi + 3'd1;
							st <= S_PL;
						end
					end
				end else
					wr <= wr + 3'd1;
			default: begin	/* S_GO */
				n <= 4'd0;
				qbc <= 32'd0;
				st <= S_COL;
			end
			endcase
		end
	end

	wire unused_ok = &{1'b0, st_wdata[31:6], t_tri[767:764], t_tri[762:760], t_tri[351:320],
		t_tri[287:0], fm_o, fa_o, fd_busy, xl[15], yl[15]};
endmodule

`default_nettype wire
