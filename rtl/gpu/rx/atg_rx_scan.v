/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_scan: RX quad traversal & Fine Rasterizer.
 *
 * Traverses bounding boxes via Coarse Tile Rasterizer (atg_rx_coarse,
 * 8x8 pixel tiles) and evaluates coverage of 2x2 quads. Empty tiles outside
 * the triangle are skipped in 1 cycle. Trivially accepted tiles bypass edge
 * testing.
 *
 * In boundary tiles, MSAA 4x coverage (16 sample locations across 4 lanes)
 * is evaluated in parallel using 48 addsub units, resolving fq_scov and
 * fq_ccov in a single clock cycle without serialization.
 *
 * Strict Guardrails: Verilog-2005 only, zero raw arithmetic operators.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_scan #(
	parameter HAS_SU = 1	/* 1: fragment warps to the SU; 0: quads straight to the ROP with DEBUG_COLOR */
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
	localparam [3:0] S_IDLE = 4'd0, S_SEQ = 4'd1, S_TILE_WAIT = 4'd2, S_WALK = 4'd3,
		S_Z = 4'd4, S_EMIT = 4'd5, S_LAST = 4'd6, S_FREE = 4'd7, S_FQ = 4'd8;
	reg [3:0] st;
	reg wm;		/* warp mode: a non-raw triangle with an SU */
	reg fend;	/* S_FQ: the end marker (no quad) */

	/* The triangle. */
	reg signed [47:0] a8 [0:2];	/* A << 8: one pixel in x */
	reg signed [47:0] b8 [0:2];
	reg signed [47:0] er [0:2];	/* the edges at the tile's current quad row */
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
			ms4 <= (st_wdata[3:0] == 4'd2);
		else if (st_we && st_idx == GHCI_S_SAMPLE_KILL)
			kill <= st_wdata[3:0];

	/* Coarse Tile Rasterizer Interface */
	reg coarse_tri_valid;
	wire coarse_tri_ready;
	wire coarse_tile_valid;
	reg coarse_tile_ready;
	wire [15:0] coarse_tile_x, coarse_tile_y;
	wire [47:0] coarse_tile_e0, coarse_tile_e1, coarse_tile_e2;
	wire coarse_tile_trivial, coarse_tile_last, coarse_busy;

	reg [15:0] cur_tx, cur_ty;
	reg cur_trivial;
	reg cur_last_tile;

	/* The edges back to the quad origin (S_IDLE), one quad right (ec + 2 A) and
	 * one row down (er + 2 B); */
	wire [47:0] er0 [0:2];
	wire [47:0] ec_n [0:2];
	wire [47:0] er_n [0:2];
	wire [11:0] ed_carry_unused;
	genvar ge;
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

	/* Sample offsets generator */
	wire [143:0] eb_cov_unused;
	wire [143:0] lowmv;
	wire [143:0] cov_op, cov_oq;
	atg_rx_cov cv (
		.clk(clk),
		.i_load(st == S_IDLE && sp_valid),
		.i_ab({sp_tri[192 +: 48], sp_tri[96 +: 48], sp_tri[0 +: 48]}),
		.i_ec({ec[2], ec[1], ec[0]}),
		.i_start(1'b0),
		.i_step(1'b0),
		.i_sc(2'd0),
		.i_samp(1'b0),
		.o_eb(eb_cov_unused),
		.o_lowm(lowmv),
		.o_op(cov_op),
		.o_oq(cov_oq)
	);

	atg_rx_coarse u_coarse (
		.clk(clk),
		.rst_n(rst_n),
		.tri_valid(coarse_tri_valid),
		.tri_ready(coarse_tri_ready),
		.bbox_min_x(sp_tri[303:288]),
		.bbox_min_y(sp_tri[319:304]),
		.bbox_max_x(sp_tri[335:320]),
		.bbox_max_y(sp_tri[351:336]),
		.e0_a8({{16{sp_tri[23]}}, sp_tri[0 +: 24], 8'd0}),
		.e0_b8({{16{sp_tri[47]}}, sp_tri[24 +: 24], 8'd0}),
		.e0_er(er0[0]),
		.e1_a8({{16{sp_tri[96 + 23]}}, sp_tri[96 +: 24], 8'd0}),
		.e1_b8({{16{sp_tri[96 + 47]}}, sp_tri[96 + 24 +: 24], 8'd0}),
		.e1_er(er0[1]),
		.e2_a8({{16{sp_tri[192 + 23]}}, sp_tri[192 +: 24], 8'd0}),
		.e2_b8({{16{sp_tri[192 + 47]}}, sp_tri[192 + 24 +: 24], 8'd0}),
		.e2_er(er0[2]),
		.lowm0(ms4 ? lowmv[0 +: 48] : 48'd0),
		.lowm1(ms4 ? lowmv[48 +: 48] : 48'd0),
		.lowm2(ms4 ? lowmv[96 +: 48] : 48'd0),
		.tile_valid(coarse_tile_valid),
		.tile_ready(coarse_tile_ready),
		.tile_x(coarse_tile_x),
		.tile_y(coarse_tile_y),
		.tile_e0(coarse_tile_e0),
		.tile_e1(coarse_tile_e1),
		.tile_e2(coarse_tile_e2),
		.tile_trivial(coarse_tile_trivial),
		.tile_last(coarse_tile_last),
		.busy(coarse_busy)
	);

	/* Quad lane coordinate stepping */
	wire [16:0] qx1, qy1, qx2, qy2;
	wire [3:0] qstep_carry_unused;
	am_add #(.W(17)) u_qx1 (.a({1'b0, qx}), .b(17'd0), .ci(1'b1), .s(qx1), .co(qstep_carry_unused[0]));
	am_add #(.W(17)) u_qy1 (.a({1'b0, qy}), .b(17'd0), .ci(1'b1), .s(qy1), .co(qstep_carry_unused[1]));
	am_add #(.W(17)) u_qx2 (.a({1'b0, qx}), .b(17'd2), .ci(1'b0), .s(qx2), .co(qstep_carry_unused[2]));
	am_add #(.W(17)) u_qy2 (.a({1'b0, qy}), .b(17'd2), .ci(1'b0), .s(qy2), .co(qstep_carry_unused[3]));

	/* Lane edge values at pixel centre: ec, + A, + B, + A + B */
	wire [12*48-1:0] lve;
	wire [8:0] lve_carry_unused;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_lv
		assign lve[48 * (4 * ge) +: 48] = ec[ge];
		am_add #(.W(48)) u_la (.a(ec[ge]), .b(a8[ge]), .ci(1'b0), .s(lve[48 * (4 * ge + 1) +: 48]),
			.co(lve_carry_unused[3 * ge + 0]));
		am_add #(.W(48)) u_lb (.a(ec[ge]), .b(b8[ge]), .ci(1'b0), .s(lve[48 * (4 * ge + 2) +: 48]),
			.co(lve_carry_unused[3 * ge + 1]));
		am_add #(.W(48)) u_lab (.a(lve[48 * (4 * ge + 1) +: 48]), .b(b8[ge]), .ci(1'b0),
			.s(lve[48 * (4 * ge + 3) +: 48]),
			.co(lve_carry_unused[3 * ge + 2]));
	end
	endgenerate

	/* Parallel 16-sample evaluation: 3 edges x 4 lanes x 4 samples = 48 addsubs */
	wire [47:0] esamp_sign;
	wire [47:0] esamp_carry_unused;
	wire [48*47-1:0] esamp_unused;
	genvar gk, gs;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_samp_e
		wire signed [47:0] ope = cov_op[48 * ge +: 48];
		wire signed [47:0] oqe = cov_oq[48 * ge +: 48];
		for (gk = 0; gk < 4; gk = gk + 1) begin : g_samp_k
			wire signed [47:0] lve_val = lve[48 * (4 * ge + gk) +: 48];
			for (gs = 0; gs < 4; gs = gs + 1) begin : g_samp_s
				localparam integer idx = 16 * ge + 4 * gk + gs;
				wire signed [47:0] s_off = (gs == 0 || gs == 3) ? ope : oqe;
`ifdef MUT_SAMPLE_SWAP
				wire s_sub = (gs == 0 || gs == 1);
`else
				wire s_sub = (gs == 0 || gs == 2);
`endif
				wire [47:0] s_val;
				am_addsub #(.W(48)) u_esamp (
					.a(lve_val),
					.b(s_off),
					.sub(s_sub),
					.s(s_val),
					.co(esamp_carry_unused[idx])
				);
				assign esamp_sign[idx] = s_val[47];
				assign esamp_unused[47 * idx +: 47] = s_val[46:0];
			end
		end
	end
	endgenerate

	/* Coverage logic */
	reg [3:0] inb;
	reg [3:0] cov_edge;
	reg [3:0] ccov_comb;
	reg [15:0] scov_comb;
	reg [2:0] far_edge;
	integer e, ln, sm;

	always @(*) begin
		far_edge = 3'b111;
		for (ln = 0; ln < 4; ln = ln + 1) begin
			inb[ln] = !((ln[0] ? qx1 : {1'b0, qx}) < {1'b0, bx0} ||
			            (ln[0] ? qx1 : {1'b0, qx}) >= {1'b0, bx1} ||
			            (ln[1] ? qy1 : {1'b0, qy}) < {1'b0, by0} ||
			            (ln[1] ? qy1 : {1'b0, qy}) >= {1'b0, by1});
			cov_edge[ln] = inb[ln];
			ccov_comb[ln] = inb[ln];
			for (e = 0; e < 3; e = e + 1) begin
				if (lve[48 * (4 * e + ln) + 47]) begin
					cov_edge[ln] = 1'b0;
					ccov_comb[ln] = 1'b0;
				end
				if (inb[ln] && !(lve[48 * (4 * e + ln) + 47] &&
				    (lve[48 * (4 * e + ln) +: 48] | lowmv[48 * e +: 48]) != {48{1'b1}}))
					far_edge[e] = 1'b0;
			end

			for (sm = 0; sm < 4; sm = sm + 1) begin
				scov_comb[4 * ln + sm] = inb[ln] && !kill[sm] &&
					!esamp_sign[16 * 0 + 4 * ln + sm] &&
					!esamp_sign[16 * 1 + 4 * ln + sm] &&
					!esamp_sign[16 * 2 + 4 * ln + sm];
			end
		end
	end

	wire skip_samp = (far_edge != 3'b000);

	/* Trivial accept quad coverage */
	reg [3:0] cov_triv;
	reg [15:0] scov_triv;
	always @(*) begin
		for (ln = 0; ln < 4; ln = ln + 1) begin
			cov_triv[ln] = inb[ln];
			for (sm = 0; sm < 4; sm = sm + 1)
				scov_triv[4 * ln + sm] = inb[ln] && !kill[sm];
		end
	end

	/* Combined quad evaluation results */
	wire [3:0] cur_cov = cur_trivial ? cov_triv : cov_edge;
	wire [3:0] cur_ccov = cur_trivial ? cov_triv : ccov_comb;
	wire [15:0] cur_scov = cur_trivial ? scov_triv : (skip_samp ? 16'd0 : scov_comb);
	wire [3:0] cov1 = cur_cov & ~{4{kill[0]}};

	reg [15:0] scov_reg;
	reg [3:0] ccov_reg;
	reg [3:0] cov_reg;

	wire w_empty = wm ? (ms4 ? cur_scov == 16'd0 : cov1 == 4'd0) : cur_cov == 4'd0;

	/* Stepping within 8x8 coarse tile */
	wire [15:0] cur_tx_end, cur_ty_end;
	wire [1:0] tend_carry_unused;
	am_add #(.W(16)) u_tx_end (.a(cur_tx), .b(16'd8), .ci(1'b0), .s(cur_tx_end), .co(tend_carry_unused[0]));
	am_add #(.W(16)) u_ty_end (.a(cur_ty), .b(16'd8), .ci(1'b0), .s(cur_ty_end), .co(tend_carry_unused[1]));

	wire tile_row_end = (qx2 >= {1'b0, cur_tx_end}) || (qx2 >= {1'b0, bx1});
	wire tile_quads_end = tile_row_end && ((qy2 >= {1'b0, cur_ty_end}) || (qy2 >= {1'b0, by1}));

	/* Depth: z = (Az i + Bz j) + Cz, i = x - bx0, j = y - by0, clamped to [0, 1]. */
	reg [4:0] zc;
	reg [3:0] zmask;
	reg [31:0] t1 [0:3];
	reg [127:0] zv;
	wire [1:0] zl = zc[1:0];
	wire zi = zc < 5'd4;
	wire [16:0] lq, lij;
	wire [31:0] fm_b;
	wire [1:0] lij_carry_unused;
	am_add #(.W(17)) u_lq (.a({1'b0, zi ? qx : qy}), .b(17'd0), .ci(zi ? zl[0] : zl[1]), .s(lq),
		.co(lij_carry_unused[0]));
	am_sub #(.W(17)) u_lij (.a(lq), .b({1'b0, zi ? bx0 : by0}), .bi(1'b0), .d(lij),
		.bo(lij_carry_unused[1]));
	am_fp_fix2f #(.W(17), .F(0), .SIGNED(1)) u_fm_b (.v(lij), .f(fm_b));
	wire fm_v = (st == S_Z) && (zc < 5'd8);
	wire [31:0] fm_a = zi ? az : bz;
	wire fa_v = (st == S_Z) && (zc >= 5'd8) && (zc < 5'd16);
	wire fm_o, fa_o;
	wire [31:0] fm_r, fa_r;
	wire [31:0] fa_a = (zc < 5'd12) ? t1[zl] : fa_r;
	wire [31:0] fa_b = (zc < 5'd12) ? fm_r : cz;
	am_fp_mul #(.LAT(4)) fmul (.clk(clk), .rst_n(rst_n), .i_valid(fm_v), .i_a(fm_a), .i_b(fm_b),
		.o_valid(fm_o), .o_r(fm_r));
	am_fp_add #(.LAT(4)) fadd (.clk(clk), .rst_n(rst_n), .i_valid(fa_v), .i_a(fa_a), .i_b(fa_b),
		.i_sub(1'b0), .o_valid(fa_o), .o_r(fa_r));
	wire [31:0] zcl = fa_r[31] || (fa_r[30:23] == 8'hFF && fa_r[22:0] != 23'd0) ? 32'd0 :
		fa_r > 32'h3F800000 ? 32'h3F800000 : fa_r;

	wire [1:0] fi1;
	wire [4:0] zc1;
	wire [1:0] ct_carry_unused;
	am_add #(.W(2)) u_fi1 (.a(fi), .b(2'd0), .ci(1'b1), .s(fi1), .co(ct_carry_unused[0]));
	am_add #(.W(5)) u_zc1 (.a(zc), .b(5'd0), .ci(1'b1), .s(zc1), .co(ct_carry_unused[1]));

	/* The quad that waits for its successor */
	reg pend;
	reg [31:0] p_xy;
	reg [3:0] p_mask;
	reg [127:0] p_z;
	reg [15:0] seq;

	assign sp_ready = (st == S_IDLE);
	assign sq_req = (st == S_SEQ && !wm);
	assign fq_valid = (st == S_FQ);
	assign fq_xy = {qy, qx};
	assign fq_scov = fend ? 16'd0 : ms4 ? scov_reg :
		{3'd0, cov_reg[3] & ~kill[0], 3'd0, cov_reg[2] & ~kill[0], 3'd0, cov_reg[1] & ~kill[0], 3'd0, cov_reg[0] & ~kill[0]};
	assign fq_ccov = fend ? 4'd0 : ms4 ? ccov_reg : cov_reg;
	assign fq_end = fend;
	assign busy = (st != S_IDLE);

	always @(posedge clk) begin
		pt_free <= 1'b0;
		if (!rst_n) begin
			st <= S_IDLE;
			dx_valid <= 1'b0;
			coarse_tri_valid <= 1'b0;
			coarse_tile_ready <= 1'b0;
			cur_tx <= 16'd0;
			cur_ty <= 16'd0;
			cur_trivial <= 1'b0;
			cur_last_tile <= 1'b0;
			scov_reg <= 16'd0;
			ccov_reg <= 4'd0;
			cov_reg <= 4'd0;
			fend <= 1'b0;
			pend <= 1'b0;
			fi <= 2'd0;
			zc <= 5'd0;
			zmask <= 4'd0;
			zv <= 128'd0;
			p_xy <= 32'd0;
			p_mask <= 4'd0;
			p_z <= 128'd0;
			seq <= 16'd0;
			dx_seq <= 16'd0;
			dx_xy <= 32'd0;
			dx_mask <= 4'd0;
			dx_depth <= 128'd0;
			dx_last <= 1'b0;
		end else case (st)
		S_IDLE: begin
			coarse_tile_ready <= 1'b0;
			if (sp_valid) begin
				for (k = 0; k < 3; k = k + 1) begin
					a8[k] <= {{16{sp_tri[96 * k + 23]}}, sp_tri[96 * k +: 24], 8'd0};
					b8[k] <= {{16{sp_tri[96 * k + 47]}}, sp_tri[96 * k + 24 +: 24], 8'd0};
					er[k] <= er0[k];
					ec[k] <= er0[k];
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
				wm <= (HAS_SU != 0) && !sp_tri[764];
				fend <= 1'b0;
				pend <= 1'b0;
				fi <= 2'd0;
				coarse_tri_valid <= 1'b1;
				if (sp_tri[335:320] > sp_tri[303:288] && sp_tri[351:336] > sp_tri[319:304])
					st <= S_SEQ;
				else begin
					coarse_tri_valid <= 1'b0;
					st <= S_FREE;
				end
			end
		end

		S_SEQ: begin
			coarse_tri_valid <= 1'b0;
			coarse_tile_ready <= 1'b0;
			seq <= sq_seq;
			st <= S_TILE_WAIT;
		end

		S_TILE_WAIT: begin
			coarse_tile_ready <= 1'b0;
			if (coarse_tile_valid) begin
				coarse_tile_ready <= 1'b1;
				cur_tx <= coarse_tile_x;
				cur_ty <= coarse_tile_y;
				cur_trivial <= coarse_tile_trivial;
				cur_last_tile <= coarse_tile_last;
				qx <= coarse_tile_x;
				qy <= coarse_tile_y;
				er[0] <= coarse_tile_e0; ec[0] <= coarse_tile_e0;
				er[1] <= coarse_tile_e1; ec[1] <= coarse_tile_e1;
				er[2] <= coarse_tile_e2; ec[2] <= coarse_tile_e2;
				st <= S_WALK;
			end else if (!coarse_busy) begin
				/* Traversal of all tiles complete */
				fend <= wm;
				st <= wm ? S_FQ : S_LAST;
			end
		end

		S_WALK: begin
			coarse_tile_ready <= 1'b0;
			scov_reg <= cur_scov;
			ccov_reg <= cur_ccov;
			cov_reg <= cur_cov;
			if (!w_empty && wm) begin
				st <= S_FQ;
			end else if (!w_empty) begin
				zmask <= cur_cov;
				zc <= 5'd0;
				zv <= 128'd0;
				st <= S_Z;
			end else if (tile_quads_end) begin
				/* End of quads in this coarse tile */
				if (cur_last_tile) begin
					fend <= wm;
					st <= wm ? S_FQ : S_LAST;
				end else if (coarse_tile_valid) begin
					/* Immediate switch to next pre-fetched tile */
					coarse_tile_ready <= 1'b1;
					cur_tx <= coarse_tile_x;
					cur_ty <= coarse_tile_y;
					cur_trivial <= coarse_tile_trivial;
					cur_last_tile <= coarse_tile_last;
					qx <= coarse_tile_x;
					qy <= coarse_tile_y;
					er[0] <= coarse_tile_e0; ec[0] <= coarse_tile_e0;
					er[1] <= coarse_tile_e1; ec[1] <= coarse_tile_e1;
					er[2] <= coarse_tile_e2; ec[2] <= coarse_tile_e2;
					st <= S_WALK;
				end else begin
					st <= S_TILE_WAIT;
				end
			end else begin
				/* Step to next quad within tile */
				if (tile_row_end) begin
					qx <= cur_tx;
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

		S_FQ: begin
			coarse_tile_ready <= 1'b0;
			if (fq_ready) begin
				if (fend) begin
					st <= S_FREE;
				end else if (tile_quads_end) begin
					if (cur_last_tile) begin
						fend <= wm;
						st <= S_FQ;
					end else if (coarse_tile_valid) begin
						coarse_tile_ready <= 1'b1;
						cur_tx <= coarse_tile_x;
						cur_ty <= coarse_tile_y;
						cur_trivial <= coarse_tile_trivial;
						cur_last_tile <= coarse_tile_last;
						qx <= coarse_tile_x;
						qy <= coarse_tile_y;
						er[0] <= coarse_tile_e0; ec[0] <= coarse_tile_e0;
						er[1] <= coarse_tile_e1; ec[1] <= coarse_tile_e1;
						er[2] <= coarse_tile_e2; ec[2] <= coarse_tile_e2;
						st <= S_WALK;
					end else begin
						st <= S_TILE_WAIT;
					end
				end else begin
					/* Step to next quad */
					if (tile_row_end) begin
						qx <= cur_tx;
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
					st <= S_WALK;
				end
			end
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

		S_EMIT: begin
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
				if (tile_quads_end) begin
					if (cur_last_tile) begin
						st <= S_LAST;
					end else if (coarse_tile_valid) begin
						coarse_tile_ready <= 1'b1;
						cur_tx <= coarse_tile_x;
						cur_ty <= coarse_tile_y;
						cur_trivial <= coarse_tile_trivial;
						cur_last_tile <= coarse_tile_last;
						qx <= coarse_tile_x;
						qy <= coarse_tile_y;
						er[0] <= coarse_tile_e0; ec[0] <= coarse_tile_e0;
						er[1] <= coarse_tile_e1; ec[1] <= coarse_tile_e1;
						er[2] <= coarse_tile_e2; ec[2] <= coarse_tile_e2;
						st <= S_WALK;
					end else begin
						st <= S_TILE_WAIT;
					end
				end else begin
					/* Step to next quad */
					if (tile_row_end) begin
						qx <= cur_tx;
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
					st <= S_WALK;
				end
			end
		end

		S_LAST: begin
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
		end

		default: if (!f_busy) begin	/* S_FREE */
			fi <= fi1;
			if (fi < 2'd3 && fl[fi] && !raw) begin
				pt_free <= 1'b1;
				pt_free_idx <= ent[8 * fi +: 8];
			end
			if (fi == 2'd3)
				st <= S_IDLE;
		end
		endcase
	end

	wire unused_ok = &{1'b0, st_wdata[31:4], sp_last, fm_o, fa_o,
		sp_tri[767:765], sp_tri[735:448], lij[16], qx1[16], qy1[16], qx2[16], qy2[16],
		HAS_SU != 0, coarse_tri_ready, cur_last_tile, eb_cov_unused,
		esamp_carry_unused, esamp_unused, lve_carry_unused, qstep_carry_unused, tend_carry_unused};
endmodule

`default_nettype wire
