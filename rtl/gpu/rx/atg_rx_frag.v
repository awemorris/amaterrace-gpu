/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_frag: the RX's fragment warps: packs up to 8
 * covered quads of one triangle (from atg_rx_scan, fq_*) into a 32-lane
 * warp of SU 0, copies the triangle's 3 × VARYING_COUNT varying words
 * from the PT into the warp's primitive table (and its primitive map, 0:
 * one triangle per warp), writes the registers of every lane of the quads
 * and starts the warp with a new sequence number.
 *
 * Per lane (atg_rx_bary does the arithmetic, about 200 cycles a quad):
 * r0-r2 = b0, b1, b2 and r3 = z at the pixel centre (z clamped to [0, 1]
 * with one sample, not clamped with four: the render output adds each
 * sample's depth slope and clamps; not clamped with DEPTH_CLAMP[1]), r4, r5 = x + 0.5, y + 0.5, r6 = the
 * lane's samples (fq_scov, after the sample mask test; 0 in a helper
 * lane), and with MS_CTRL[4] (CENTROID) r7-r9 = b0, b1, b2 at the
 * centroid: the centre when it is inside the triangle (fq_ccov) or the
 * lane has no sample, else the covered sample of the lowest index.
 * With four samples (MS_CTRL[3:0] = 2), once per triangle (the first warp)
 * the depth slopes d_s of the samples (atg_rx_bary), sent with every warp
 * as primitive table words 0xFF8-0xFFB after the map (atg_su_exp keeps
 * them for the render output; atg_su_lda ignores them).
 *
 * States: COL (quads in) →(8 quads, or the triangle's end after some)→
 * ALLOC (fl_req) →(fl_gnt)→ [DZ] → COPY → per quad: [BARY at the
 * centroid] → BARY → WR → GO → COL.  See spec/gpu/rx/atg_rx_frag.md.
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
	input wire [15:0] fq_scov,
	input wire [3:0] fq_ccov,
	input wire fq_end,
	output wire busy,
	/* PT of SU 0 (read port shared with atg_rx_clip, which waits while pt_busy) */
	output wire pt_rd,
	output wire [7:0] pt_idx,
	output wire [6:0] pt_word,
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
	localparam [2:0] S_COL = 3'd0, S_ALLOC = 3'd1, S_COPY = 3'd2, S_DZ = 3'd3, S_BARYC = 3'd4,
		S_BARY = 3'd5, S_WR = 3'd6, S_GO = 3'd7;
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

	reg [6:0] vc;	/* VARYING_COUNT, 0-64 */
	reg ms4;	/* MS_CTRL[3:0] = 2 */
	reg cent;	/* MS_CTRL[4] */
	reg dclip;	/* DEPTH_CLAMP[1] (CAPS[30]): r3 not clamped */
	always @(posedge clk)
		if (!rst_n)
			dclip <= 1'b0;
		else if (st_we && st_idx == GHCI_S_DEPTH_CLAMP)
			dclip <= st_wdata[1];
	always @(posedge clk)
		if (!rst_n) begin
			vc <= 7'd0;
			ms4 <= 1'b0;
			cent <= 1'b0;
		end else if (st_we && st_idx == GHCI_S_VARYING_COUNT)
			vc <= st_wdata > 32'd64 ? 7'd64 : st_wdata[6:0];
		else if (st_we && st_idx == GHCI_S_MS_CTRL) begin
			ms4 <= st_wdata[3:0] == 4'd2;
			cent <= st_wdata[4];
		end

	/* The triangle: 12 plane words (z, 1/w, b0/w, b1/w × A, B, C), bbox origin, PT entries. */
	reg [383:0] pl;
	reg [15:0] bx0, by0;
	reg [23:0] ent;
	reg front;
	reg dz_done;	/* the samples' depth slopes of this triangle are made */
	always @(posedge clk)
		if (t_load) begin
			pl <= t_tri[735:352];
			bx0 <= t_tri[303:288];
			by0 <= t_tri[319:304];
			ent <= t_tri[759:736];
			front <= t_tri[763];
		end

	/* The warp's quads: position, samples, centres. */
	reg [127:0] qbx, qby, qbs;
	reg [31:0] qcc;
	reg [3:0] n;	/* quads collected */
	reg [2:0] qi;	/* the quad being written */
	assign fq_ready = st == S_COL && n < 4'd8;
	wire fq_take = fq_valid && fq_ready;
	reg [31:0] qbc;	/* the lanes with a sample (fl_info's coverage) */
	integer k;
	always @(*)
		for (k = 0; k < 32; k = k + 1)
			qbc[k] = qbs[4 * k +: 4] != 4'd0;

	wire [15:0] qx = qbx[16 * qi +: 16], qy = qby[16 * qi +: 16];
	wire [15:0] s4q = qbs[16 * qi +: 16];	/* the quad's samples */
	wire [3:0] ccq = qcc[4 * qi +: 4];

	/* The centroid offsets of the quad's lanes: 0 the centre, 1 + s sample s. */
	reg [11:0] osel;
	reg needc;	/* a lane's centroid is not its centre */
	reg [3:0] s4;
	always @(*) begin
		needc = 1'b0;
		for (k = 0; k < 4; k = k + 1) begin
			s4 = s4q[4 * k +: 4];
			osel[3 * k +: 3] = ccq[k] || s4 == 4'd0 ? 3'd0 :
				s4[0] ? 3'd1 : s4[1] ? 3'd2 : s4[2] ? 3'd3 : 3'd4;
			if (osel[3 * k +: 3] != 3'd0)
				needc = 1'b1;
		end
	end

	/* The lane arithmetic. */
	reg bgo;
	wire b_busy, b_done;
	wire [127:0] ob0, ob1, ob2, oz, ods;
	atg_rx_bary bary (.clk(clk), .rst_n(rst_n), .i_start(bgo && st != S_DZ),
		.i_dz(bgo && st == S_DZ), .i_pl(pl), .i_qx(qx), .i_qy(qy), .i_bx0(bx0), .i_by0(by0),
		.i_osel(st == S_BARYC ? osel : 12'd0), .busy(b_busy), .o_done(b_done), .o_b0(ob0),
		.o_b1(ob1), .o_b2(ob2), .o_z(oz), .o_ds(ods));
	reg [127:0] cb0, cb1, cb2;	/* the centroid's barycentrics */
	reg [127:0] dsv;		/* the triangle's d_s */

	/* The copy: reads (cv, cw) → writes the next cycle; then the map, then d_s. */
	reg [1:0] cv;
	reg [6:0] cw;
	reg rd_done, rv_q, map_done;
	reg [2:0] dsn;	/* d_s words written */
	reg [1:0] rv_v;
	reg [6:0] rv_w;
	wire rd_now = st == S_COPY && !rd_done;
	assign pt_rd = rd_now;
	assign pt_idx = ent[8 * cv +: 8];
	assign pt_word = 7'd4 + cw;
	assign pt_busy = st == S_COPY;
	wire map_we = st == S_COPY && rd_done && !rv_q && !map_done;
	wire ds_we = st == S_COPY && map_done && ms4 && dsn != 3'd4;
	assign fl_pw_we = rv_q || map_we || ds_we;
	assign fl_pw_addr = map_we ? 12'hFFF : ds_we ? {10'h3FE, dsn[1:0]} :
		{1'b0, 3'd0, rv_v, rv_w[5:0]};
	assign fl_pw_data = map_we ? 32'd0 : ds_we ? dsv[32 * dsn[1:0] +: 32] : pt_rdata;
	wire copy_end = map_done && (!ms4 || dsn == 3'd4);

	/* The register writes: lane wl of the quad, register wr. */
	reg [1:0] wl;
	reg [3:0] wr;
	wire [3:0] nreg = cent ? 4'd10 : 4'd7;
	wire [15:0] xl = qx + {15'd0, wl[0]}, yl = qy + {15'd0, wl[1]};
	wire [31:0] xc = i2f({1'b0, xl[14:0], 1'b1}) - 32'h00800000;	/* x + 0.5 */
	wire [31:0] yc = i2f({1'b0, yl[14:0], 1'b1}) - 32'h00800000;
	wire [31:0] zr = oz[32 * wl +: 32];
`ifdef MUT_R3_CLAMP
	wire zclamp = 1'b1;
`else
`ifdef MUT_RX_DCLIP
	wire zclamp = !ms4;
`else
	wire zclamp = !ms4 && !dclip;
`endif
`endif
	wire [31:0] zcl = !zclamp ? zr : zr[31] || (zr[30:23] == 8'hFF && zr[22:0] != 23'd0) ? 32'd0 :
		zr > ONE ? ONE : zr;
	wire [127:0] c0 = needc ? cb0 : ob0, c1 = needc ? cb1 : ob1, c2 = needc ? cb2 : ob2;
	assign fl_we = st == S_WR;
	assign fl_reg = {2'd0, wr};
	assign fl_lane = {qi, wl};
	assign fl_data = wr == 4'd0 ? ob0[32 * wl +: 32] : wr == 4'd1 ? ob1[32 * wl +: 32] :
		wr == 4'd2 ? ob2[32 * wl +: 32] : wr == 4'd3 ? zcl : wr == 4'd4 ? xc :
		wr == 4'd5 ? yc : wr == 4'd6 ? {28'd0, s4q[4 * wl +: 4]} :
		wr == 4'd7 ? c0[32 * wl +: 32] : wr == 4'd8 ? c1[32 * wl +: 32] : c2[32 * wl +: 32];

	assign fl_req = st == S_ALLOC;
	assign fl_go = st == S_GO;
	assign sq_req = st == S_GO;
	reg [31:0] qmask;
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
			qbs <= 128'd0;
			qcc <= 32'd0;
			rv_q <= 1'b0;
			bgo <= 1'b0;
			dz_done <= 1'b0;
		end else begin
			rv_q <= rd_now;
			rv_v <= cv;
			rv_w <= cw;
			bgo <= 1'b0;
			if (t_load)
				dz_done <= 1'b0;
			case (st)
			S_COL:
				if (fq_take) begin
					if (fq_end) begin
						if (n != 4'd0)
							st <= S_ALLOC;
					end else begin
						qbx[16 * n[2:0] +: 16] <= fq_xy[15:0];
						qby[16 * n[2:0] +: 16] <= fq_xy[31:16];
						qbs[16 * n[2:0] +: 16] <= fq_scov;
						qcc[4 * n[2:0] +: 4] <= fq_ccov;
						n <= n + 4'd1;
						if (n == 4'd7)
							st <= S_ALLOC;
					end
				end
			S_ALLOC:
				if (fl_gnt) begin
					cv <= 2'd0;
					cw <= 7'd0;
					rd_done <= vc == 7'd0;
					map_done <= 1'b0;
					dsn <= 3'd0;
					qi <= 3'd0;
					if (ms4 && !dz_done) begin
						bgo <= 1'b1;
						st <= S_DZ;
					end else
						st <= S_COPY;
				end
			S_DZ:
				if (b_done) begin
					dsv <= ods;
					dz_done <= 1'b1;
					st <= S_COPY;
				end
			S_COPY: begin
				if (rd_now) begin
					if (cw + 7'd1 == vc) begin
						cw <= 7'd0;
						cv <= cv + 2'd1;
						if (cv == 2'd2)
							rd_done <= 1'b1;
					end else
						cw <= cw + 7'd1;
				end
				if (map_we)
					map_done <= 1'b1;
				if (ds_we)
					dsn <= dsn + 3'd1;
				if (copy_end) begin
					bgo <= 1'b1;
					st <= cent && ms4 && needc ? S_BARYC : S_BARY;
				end
			end
			S_BARYC:
				if (b_done) begin
					cb0 <= ob0;
					cb1 <= ob1;
					cb2 <= ob2;
					bgo <= 1'b1;
					st <= S_BARY;
				end
			S_BARY:
				if (b_done) begin
					wl <= 2'd0;
					wr <= 4'd0;
					st <= S_WR;
				end
			S_WR:
				if (wr + 4'd1 == nreg) begin
					wr <= 4'd0;
					wl <= wl + 2'd1;
					if (wl == 2'd3) begin
						if ({1'b0, qi} + 4'd1 == n)
							st <= S_GO;
						else begin
							qi <= qi + 3'd1;
							st <= S_COPY;	/* copy_end holds: on to the next quad */
						end
					end
				end else
					wr <= wr + 4'd1;
			default: begin	/* S_GO */
				n <= 4'd0;
				qbs <= 128'd0;
				qcc <= 32'd0;
				st <= S_COL;
			end
			endcase
		end
	end

	wire unused_ok = &{1'b0, rv_w[6], t_tri[767:764], t_tri[762:760], t_tri[351:320],
		t_tri[287:0], b_busy, xl[15], yl[15]};
endmodule

`default_nettype wire
