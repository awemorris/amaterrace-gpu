/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_scan: RX quad traversal: walks the bounding box in 2×2 quads,
 * evaluates the edges for coverage, and sends the covered quads of a
 * non-raw triangle to atg_rx_frag (HAS_SU: it packs them into fragment
 * warps) or the quads straight to the ROP (DRAW_RAW, or no SU); frees PT
 * entries after the triangle.
 *
 * The direct path (quads to the ROP with their depth, one
 * sequence number per triangle; edges step one quad per cycle; a covered
 * quad's depth takes 20 cycles: one fmul and one fadd, the four lanes
 * interleaved).  The warp path (fq_*: one covered quad per
 * handshake, then an end marker; the frees wait for atg_rx_frag's idle,
 * so its copy of the varyings is done).  See spec/gpu/rx/atg_rx_scan.md.
 *
 * Multisampling (MS_CTRL[3:0] = 2, docs/ghci.md section 12.11; the warp
 * path only): after the centre's evaluation (S_WALK) a quad takes four
 * more cycles (S_SAMP), one per sample, each the same edge test at the
 * sample's offset from the pixel centre: the edges at the quad plus the
 * offset (A dx + B dy, two values per edge since the standard locations
 * pair up as opposites, made at the triangle's load), through the lanes'
 * adders.  fq_scov bit 4 l + s: sample s of lane l covered, less the
 * samples of SAMPLE_KILL; fq_ccov: the lanes' centres inside.  A quad goes
 * to atg_rx_frag when one of its samples is covered.  A quad whose lanes
 * are all, for one edge, further outside than the largest offset (to the
 * next power of two) skips the samples.  With one sample fq_scov bit 4 l is
 * the centre's coverage less SAMPLE_KILL[0], and the walk is as before.
 * Values referenced: Vulkan specification, Multisampling, standard sample
 * locations (VK_SAMPLE_COUNT_4_BIT).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_scan #(
	parameter HAS_SU = 1	/* 1: fragment warps to the SU; 0: quads straight to the ROP with DEBUG_COLOR (a GPU without SUs) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* From atg_rx_setup */
	input wire sp_valid,
	output wire sp_ready,
	input wire [767:0] sp_tri,
	input wire sp_last,
	output reg pt_free,
	output reg [7:0] pt_free_idx,
	/* Covered quads of a non-raw triangle to atg_rx_frag (HAS_SU) */
	output wire fq_valid,
	input wire fq_ready,
	output wire [31:0] fq_xy,
	output wire [15:0] fq_scov,
	output wire [3:0] fq_ccov,
	output wire fq_end,
	input wire f_busy,
	/* Direct fragments to the ROP (no SU: DEBUG_COLOR) */
	output reg dx_valid,
	input wire dx_ready,
	output reg [15:0] dx_seq,
	output reg [31:0] dx_xy,
	output reg [3:0] dx_mask,
	output reg [127:0] dx_depth,
	output reg dx_last,
	/* Sequence numbers (atg_rx_order) */
	output wire sq_req,
	input wire [15:0] sq_seq,
	output wire busy
);
	`include "ghci_regs.vh"
	localparam [3:0] S_IDLE = 4'd0, S_SEQ = 4'd1, S_WALK = 4'd2, S_Z = 4'd3, S_EMIT = 4'd4,
		S_LAST = 4'd5, S_FREE = 4'd6, S_FQ = 4'd7, S_SAMP = 4'd8;
	reg [3:0] st;
	reg wm;	/* warp mode: a non-raw triangle with an SU */
	reg fend;	/* S_FQ: the end marker (no quad) */

	/* The triangle. */
	reg signed [47:0] a8 [0:2];	/* A << 8: one pixel in x */
	reg signed [47:0] b8 [0:2];
	reg signed [47:0] er [0:2];	/* the edges at the row's first quad */
	reg signed [47:0] ec [0:2];	/* at the current quad */
	reg [15:0] bx0, by0, bx1, by1, qx, qy;
	reg [31:0] az, bz, cz;
	reg [23:0] ent;
	reg [2:0] fl;
	reg raw;
	reg [1:0] fi;	/* S_FREE: vertex */
	integer k;

	/* Multisampling: MS_CTRL[3:0] = 2 and SAMPLE_KILL[3:0]. */
	reg ms4;
	reg [3:0] kill;
	always @(posedge clk)
		if (!rst_n) begin
			ms4 <= 1'b0;
			kill <= 4'd0;
		end else if (st_we && st_idx == GHCI_S_MS_CTRL)
			ms4 <= st_wdata[3:0] == 4'd2;
		else if (st_we && st_idx == GHCI_S_SAMPLE_KILL)
			kill <= st_wdata[3:0];

	/* The sample offsets (atg_rx_cov) and the samples' coverage so far. */
	reg [1:0] sc;			/* S_SAMP: the sample */
	reg [15:0] scov;
	reg [3:0] ccov;
	wire samp = st == S_SAMP;
	wire [143:0] eb;
	wire [143:0] lowmv;

	atg_rx_cov cv (
		.clk(clk),
		.i_load(st == S_IDLE && sp_valid),
		.i_ab({sp_tri[192 +: 48], sp_tri[96 +: 48], sp_tri[0 +: 48]}),
		.i_ec({ec[2], ec[1], ec[0]}),
		.i_start(st == S_WALK),
		.i_step(samp),
		.i_sc(sc),
		.i_samp(samp),
		.o_eb(eb),
		.o_lowm(lowmv)
	);

	/* Coverage of the current quad (at the centres, or in S_SAMP at the
	 * sample): lane l at (qx + l[0], qy + l[1]); far[e]: every lane of the
	 * bbox is further outside edge e than the offsets reach. */
	/* qx + 1, qy + 1, qx + 2, qy + 2; edge e at the lanes: eb, + A, + B, + A + B */
	wire [16:0] qx1, qy1, qx2, qy2;
	wire [12*48-1:0] lve;	/* lane k of edge e at 48 (4 e + k) */
	wire [12:0] sc_carry_unused;
	am_add #(.W(17)) u_qx1 (.a({1'b0, qx}), .b(17'd0), .ci(1'b1), .s(qx1), .co(sc_carry_unused[0]));
	am_add #(.W(17)) u_qy1 (.a({1'b0, qy}), .b(17'd0), .ci(1'b1), .s(qy1), .co(sc_carry_unused[1]));
	am_add #(.W(17)) u_qx2 (.a({1'b0, qx}), .b(17'd2), .ci(1'b0), .s(qx2), .co(sc_carry_unused[2]));
	am_add #(.W(17)) u_qy2 (.a({1'b0, qy}), .b(17'd2), .ci(1'b0), .s(qy2), .co(sc_carry_unused[3]));
	genvar ge;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_lv
		wire [47:0] ebe = eb[48 * ge +: 48];
		assign lve[48 * (4 * ge) +: 48] = ebe;
		am_add #(.W(48)) u_la (.a(ebe), .b(a8[ge]), .ci(1'b0), .s(lve[48 * (4 * ge + 1) +: 48]),
			.co(sc_carry_unused[4 + 3 * ge]));
		am_add #(.W(48)) u_lb (.a(ebe), .b(b8[ge]), .ci(1'b0), .s(lve[48 * (4 * ge + 2) +: 48]),
			.co(sc_carry_unused[5 + 3 * ge]));
		am_add #(.W(48)) u_lab (.a(lve[48 * (4 * ge + 1) +: 48]), .b(b8[ge]), .ci(1'b0),
			.s(lve[48 * (4 * ge + 3) +: 48]),
			.co(sc_carry_unused[6 + 3 * ge]));
	end
	endgenerate
	reg [3:0] cov;
	reg [2:0] far;
	reg [47:0] lv;
	reg inb;
	integer e;
	always @(*) begin
		far = 3'b111;
		for (k = 0; k < 4; k = k + 1) begin
			cov[k] = 1'b1;
			inb = !((k[0] ? qx1 : {1'b0, qx}) < {1'b0, bx0} ||
			    (k[0] ? qx1 : {1'b0, qx}) >= {1'b0, bx1} ||
			    (k[1] ? qy1 : {1'b0, qy}) < {1'b0, by0} ||
			    (k[1] ? qy1 : {1'b0, qy}) >= {1'b0, by1});
			for (e = 0; e < 3; e = e + 1) begin
				lv = lve[48 * (4 * e + k) +: 48];
				if (lv[47])
					cov[k] = 1'b0;
				if (inb && !(lv[47] && (lv | lowmv[48 * e +: 48]) != {48{1'b1}}))
					far[e] = 1'b0;
			end
			if (!inb)
				cov[k] = 1'b0;
		end
	end
	wire skip = far != 3'b000;
	wire [3:0] cov1 = cov & ~{4{kill[0]}};	/* one sample: less the sample mask test */
	reg [15:0] scov_n;	/* S_SAMP: with this cycle's sample */
	always @(*) begin
		scov_n = scov;
		for (k = 0; k < 16; k = k + 1)
			if (sc == k[1:0])
				scov_n[k] = cov[k / 4] && !kill[sc];
	end
	wire wms = wm && ms4;
	wire w_empty = wm ? (ms4 ? skip : cov1 == 4'd0) : cov == 4'd0;	/* S_WALK: nothing here */
	wire s_last = samp && sc == 2'd3;
	wire s_empty = s_last && scov_n == 16'd0;
	wire row_end = qx2 >= {1'b0, bx1};
	wire walk_end = row_end && qy2 >= {1'b0, by1};

	/* Depth: z = (Az i + Bz j) + Cz, i = x - bx0, j = y - by0, clamped to [0, 1]. */
	reg [4:0] zc;
	reg [3:0] zmask;
	reg [31:0] t1 [0:3];
	reg [127:0] zv;
	wire [1:0] zl = zc[1:0];
	/* i = qx + zl[0] - bx0 (the first four), j = qy + zl[1] - by0 (the next four) */
	wire zi = zc < 5'd4;
	wire [16:0] lq, lij;
	wire [31:0] fm_b;
	wire [1:0] lij_carry_unused;
	am_add #(.W(17)) u_lq (.a({1'b0, zi ? qx : qy}), .b(17'd0), .ci(zi ? zl[0] : zl[1]), .s(lq),
		.co(lij_carry_unused[0]));
	am_sub #(.W(17)) u_lij (.a(lq), .b({1'b0, zi ? bx0 : by0}), .bi(1'b0), .d(lij),
		.bo(lij_carry_unused[1]));
	atg_rx_i2f #(.W(17), .F(0)) u_fm_b (.v(lij), .f(fm_b));
	wire fm_v = st == S_Z && zc < 5'd8;
	wire [31:0] fm_a = zi ? az : bz;
	wire fa_v = st == S_Z && zc >= 5'd8 && zc < 5'd16;
	wire fm_o, fa_o;
	wire [31:0] fm_r, fa_r;
	wire [31:0] fa_a = zc < 5'd12 ? t1[zl] : fa_r;
	wire [31:0] fa_b = zc < 5'd12 ? fm_r : cz;
	am_fp_mul #(.LAT(4)) fmul (.clk(clk), .rst_n(rst_n), .i_valid(fm_v), .i_a(fm_a), .i_b(fm_b),
		.o_valid(fm_o), .o_r(fm_r));
	am_fp_add #(.LAT(4)) fadd (.clk(clk), .rst_n(rst_n), .i_valid(fa_v), .i_a(fa_a), .i_b(fa_b),
		.i_sub(1'b0), .o_valid(fa_o), .o_r(fa_r));
	wire [31:0] zcl = fa_r[31] || (fa_r[30:23] == 8'hFF && fa_r[22:0] != 23'd0) ? 32'd0 :
		fa_r > 32'h3F800000 ? 32'h3F800000 : fa_r;

	/* The edges back to the quad origin (S_IDLE), one quad right (ec + 2 A) and
	 * one row down (er + 2 B); the counters + 1 */
	wire [47:0] er0 [0:2];
	wire [47:0] ec_n [0:2];
	wire [47:0] er_n [0:2];
	wire [11:0] ed_carry_unused;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_er
		wire [47:0] ta8 = {{16{sp_tri[96 * ge + 23]}}, sp_tri[96 * ge +: 24], 8'd0};
		wire [47:0] tb8 = {{16{sp_tri[96 * ge + 47]}}, sp_tri[96 * ge + 24 +: 24], 8'd0};
		wire [47:0] er_a;
		am_sub #(.W(48)) u_er_a (.a(sp_tri[96 * ge + 48 +: 48]), .b(sp_tri[288] ? ta8 : 48'd0),
			.bi(1'b0), .d(er_a), .bo(ed_carry_unused[4 * ge]));
		am_sub #(.W(48)) u_er0 (.a(er_a), .b(sp_tri[304] ? tb8 : 48'd0), .bi(1'b0), .d(er0[ge]),
			.bo(ed_carry_unused[4 * ge + 1]));
		am_add #(.W(48)) u_ec_n (.a(ec[ge]), .b(a8[ge] <<< 1), .ci(1'b0), .s(ec_n[ge]),
			.co(ed_carry_unused[4 * ge + 2]));
		am_add #(.W(48)) u_er_n (.a(er[ge]), .b(b8[ge] <<< 1), .ci(1'b0), .s(er_n[ge]),
			.co(ed_carry_unused[4 * ge + 3]));
	end
	endgenerate
	wire [1:0] sc1, fi1;
	wire [4:0] zc1;
	wire [2:0] ct_carry_unused;
	am_add #(.W(2)) u_sc1 (.a(sc), .b(2'd0), .ci(1'b1), .s(sc1), .co(ct_carry_unused[0]));
	am_add #(.W(2)) u_fi1 (.a(fi), .b(2'd0), .ci(1'b1), .s(fi1), .co(ct_carry_unused[1]));
	am_add #(.W(5)) u_zc1 (.a(zc), .b(5'd0), .ci(1'b1), .s(zc1), .co(ct_carry_unused[2]));

	/* The quad that waits for its successor (to know which is the last). */
	reg pend;
	reg [31:0] p_xy;
	reg [3:0] p_mask;
	reg [127:0] p_z;
	reg [15:0] seq;

	assign sp_ready = st == S_IDLE;
	assign sq_req = st == S_SEQ && !wm;
	assign fq_valid = st == S_FQ;
	assign fq_xy = {qy, qx};
	assign fq_scov = fend ? 16'd0 : ms4 ? scov :
		{3'd0, cov1[3], 3'd0, cov1[2], 3'd0, cov1[1], 3'd0, cov1[0]};
	assign fq_ccov = fend ? 4'd0 : ms4 ? ccov : cov;
	assign fq_end = fend;
	assign busy = st != S_IDLE;

	always @(posedge clk) begin
		pt_free <= 1'b0;
		if (!rst_n) begin
			st <= S_IDLE;
			dx_valid <= 1'b0;
		end else case (st)
		S_IDLE:
			if (sp_valid) begin
				for (k = 0; k < 3; k = k + 1) begin
					a8[k] <= {{16{sp_tri[96 * k + 23]}}, sp_tri[96 * k +: 24], 8'd0};
					b8[k] <= {{16{sp_tri[96 * k + 47]}}, sp_tri[96 * k + 24 +: 24], 8'd0};
					/* back to the quad origin (even x, y) */
					er[k] <= er0[k];
				end
				bx0 <= sp_tri[303:288];
				by0 <= sp_tri[319:304];
				bx1 <= sp_tri[335:320];
				by1 <= sp_tri[351:336];
				qx <= {sp_tri[303:289], 1'b0};
				qy <= {sp_tri[319:305], 1'b0};
				{cz, bz, az} <= sp_tri[447:352];
				ent <= sp_tri[759:736];
				fl <= sp_tri[762:760];
				raw <= sp_tri[764];
				wm <= HAS_SU != 0 && !sp_tri[764];
				fend <= 1'b0;
				pend <= 1'b0;
				fi <= 2'd0;
				st <= sp_tri[335:320] > sp_tri[303:288] && sp_tri[351:336] > sp_tri[319:304] ?
					S_SEQ : S_FREE;
			end
		S_SEQ: begin
			seq <= sq_seq;
			for (k = 0; k < 3; k = k + 1)
				ec[k] <= er[k];
			st <= S_WALK;
		end
		S_WALK:
			if (wms && !skip) begin
				ccov <= cov;
				scov <= 16'd0;
				sc <= 2'd0;
				st <= S_SAMP;
			end else if (!w_empty && wm) begin
				st <= S_FQ;
			end else if (!w_empty) begin
				zmask <= cov;
				zc <= 5'd0;
				zv <= 128'd0;
				st <= S_Z;
			end else if (walk_end) begin
				fend <= wm;
				st <= wm ? S_FQ : S_LAST;
			end else
				st <= S_WALK;
		S_SAMP: begin
			scov <= scov_n;
			sc <= sc1;
			if (s_last) begin
				if (scov_n != 16'd0)
					st <= S_FQ;
				else if (walk_end) begin
					fend <= 1'b1;
					st <= S_FQ;
				end else
					st <= S_WALK;
			end
		end
		S_FQ:	/* a quad (or the end marker) to atg_rx_frag */
			if (fq_ready) begin
				if (fend)
					st <= S_FREE;
				else if (walk_end) begin
					fend <= 1'b1;
				end else
					st <= S_WALK;
			end
		S_Z: begin
			zc <= zc1;
			if (zc >= 5'd4 && zc < 5'd8)
				t1[zl] <= fm_r;
			if (zc >= 5'd16 && zmask[zl])
				zv[32 * zl +: 32] <= zcl;
			if (zc == 5'd19)
				st <= S_EMIT;
		end
		S_EMIT:
			/* the pending quad goes out (not last), this one waits */
			if (pend && !(dx_valid && dx_ready)) begin
				dx_valid <= 1'b1;
				dx_seq <= seq;
				dx_xy <= p_xy;
				dx_mask <= p_mask;
				dx_depth <= p_z;
				dx_last <= 1'b0;
			end else begin
				dx_valid <= 1'b0;
				pend <= 1'b1;
				p_xy <= {qy, qx};
				p_mask <= zmask;
				p_z <= zv;
				st <= walk_end ? S_LAST : S_WALK;
			end
		S_LAST:
			if (dx_valid && dx_ready) begin
				dx_valid <= 1'b0;
				st <= S_FREE;
			end else begin
				dx_valid <= 1'b1;
				dx_seq <= seq;
				dx_xy <= pend ? p_xy : {by0[15:1], 1'b0, bx0[15:1], 1'b0};
				dx_mask <= pend ? p_mask : 4'd0;
				dx_depth <= pend ? p_z : 128'd0;
				dx_last <= 1'b1;
			end
		default: if (!f_busy) begin	/* S_FREE: the flagged PT entries (none for DRAW_RAW),
				 * after atg_rx_frag has copied the triangle's varyings */
			fi <= fi1;
			if (fi < 2'd3 && fl[fi] && !raw) begin
				pt_free <= 1'b1;
				pt_free_idx <= ent[8 * fi +: 8];
			end
			if (fi == 2'd3)
				st <= S_IDLE;
		end
		endcase
		/* the walk: next quad (also after a covered quad's depth) */
		if (rst_n && ((st == S_WALK && w_empty) || s_empty || (st == S_EMIT && !(pend && !(dx_valid && dx_ready))) ||
		    (st == S_FQ && fq_ready && !fend)) && !walk_end) begin
			if (row_end) begin
				qx <= {bx0[15:1], 1'b0};
				qy <= qy2[15:0];
				for (k = 0; k < 3; k = k + 1) begin
					er[k] <= er_n[k];
					ec[k] <= er_n[k];
				end
			end else begin
				qx <= qx2[15:0];
				for (k = 0; k < 3; k = k + 1)
					ec[k] <= ec_n[k];
			end
		end
	end

	wire unused_ok = &{1'b0, st_wdata[31:4], sp_last, fm_o, fa_o,
		lv[46:0], sp_tri[767:765], sp_tri[735:448], lij[16], qx1[16], qy1[16], qx2[16], qy2[16],
		HAS_SU != 0};
endmodule

`default_nettype wire
