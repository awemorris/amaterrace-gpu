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

(* keep_hierarchy = "yes" *)
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

	wire rst_sync = !rst_n;
	(* max_fanout = 16 *) reg [2:0] st;

	reg [6:0] vc;	/* VARYING_COUNT, 0-64 */
	reg ms4;	/* MS_CTRL[3:0] = 2 */
	reg cent;	/* MS_CTRL[4] */
	reg dclip;	/* DEPTH_CLAMP[1] (CAPS[30]): r3 not clamped when depth clip and not clamp */

	/* Zero-CARRY4 saturation check: st_wdata > 64 */
	(* keep = "true" *) wire vc_hi0 = |st_wdata[12:7];
	(* keep = "true" *) wire vc_hi1 = |st_wdata[18:13];
	(* keep = "true" *) wire vc_hi2 = |st_wdata[24:19];
	(* keep = "true" *) wire vc_hi3 = |st_wdata[31:25];
	(* keep = "true" *) wire vc_lo_nz = |st_wdata[5:0];
	wire vc_gt_64 = vc_hi0 || vc_hi1 || vc_hi2 || vc_hi3 || (st_wdata[6] && vc_lo_nz);

	always @(posedge clk)
		if (rst_sync)
			dclip <= 1'b0;
		else if (st_we && st_idx == GHCI_S_DEPTH_CLAMP)
			dclip <= st_wdata[1] && !st_wdata[0];
	always @(posedge clk)
		if (rst_sync) begin
			vc <= 7'd0;
			ms4 <= 1'b0;
			cent <= 1'b0;
		end else if (st_we && st_idx == GHCI_S_VARYING_COUNT)
			vc <= vc_gt_64 ? 7'd64 : st_wdata[6:0];
		else if (st_we && st_idx == GHCI_S_MS_CTRL) begin
			ms4 <= st_wdata[3:0] == 4'd2;
			cent <= st_wdata[4];
		end

	/* The triangle: 12 plane words (z, 1/w, b0/w, b1/w × A, B, C), bbox origin, PT entries. */
	(* extract_reset = "no" *) reg [383:0] pl;
	(* extract_reset = "no" *) reg [15:0] bx0, by0;
	(* extract_reset = "no" *) reg [23:0] ent;
	reg front;
	reg dz_done;	/* the samples' depth slopes of this triangle are made */
	(* dont_touch = "true" *) reg r_fl_we;
	(* max_fanout = 16 *) reg r_fl_we_int;

	wire [1:0] t_load_r;
	wire [27:0] t_load_b;
	genvar gi_t;
	generate
	for (gi_t = 0; gi_t < 2; gi_t = gi_t + 1) begin : g_tload_root
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_tlr (.I0(t_load), .O(t_load_r[gi_t]));
`else
		assign t_load_r[gi_t] = t_load;
`endif
	end
	for (gi_t = 0; gi_t < 28; gi_t = gi_t + 1) begin : g_tload_buf
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_tl (.I0(t_load_r[gi_t / 14]), .O(t_load_b[gi_t]));
`else
		assign t_load_b[gi_t] = t_load_r[gi_t / 14];
`endif
	end
	for (gi_t = 0; gi_t < 24; gi_t = gi_t + 1) begin : g_pl_load
		always @(posedge clk) begin
			if (t_load_b[gi_t])
				pl[16 * gi_t +: 16] <= t_tri[352 + 16 * gi_t +: 16];
		end
	end
	endgenerate

	always @(posedge clk) begin
		if (t_load_b[24])
			bx0 <= t_tri[303:288];
		if (t_load_b[25])
			by0 <= t_tri[319:304];
		if (t_load_b[26])
			ent[15:0] <= t_tri[751:736];
		if (t_load_b[27]) begin
			ent[23:16] <= t_tri[759:752];
			front <= t_tri[763];
		end
	end

	/* The warp's quads: position, samples, centres. */
	(* extract_reset = "no" *) reg [15:0] qbx_arr [0:7];
	(* extract_reset = "no" *) reg [15:0] qby_arr [0:7];
	reg [15:0] qbs_arr [0:7];
	reg [31:0] qcc;
	(* max_fanout = 16 *) reg [3:0] n;	/* quads collected */
	(* max_fanout = 16 *) reg [2:0] qi;	/* the quad being written */
	(* dont_touch = "true", extract_reset = "no" *) reg [2:0] r_qi_rep [0:6];
	assign fq_ready = (st == S_COL) && !n[3];
	wire fq_take = fq_valid && fq_ready;

	/* Buffered fq_xy for 8 quad array entries (fanout 8) */
	wire [31:0] fq_xy_b;
	generate
	for (gi_t = 0; gi_t < 32; gi_t = gi_t + 1) begin : g_fqxy_buf
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xy (.I0(fq_xy[gi_t]), .O(fq_xy_b[gi_t]));
`else
		assign fq_xy_b[gi_t] = fq_xy[gi_t];
`endif
	end
	for (gi_t = 0; gi_t < 8; gi_t = gi_t + 1) begin : g_quad_arr
		(* dont_touch = "true" *) wire q_we_x  = (st == S_COL) && fq_valid && !n[3] && !fq_end && (n[2:0] == gi_t[2:0]);
		(* dont_touch = "true" *) wire q_we_y  = (st == S_COL) && fq_valid && !n[3] && !fq_end && (n[2:0] == gi_t[2:0]);
		(* dont_touch = "true" *) wire q_we_s  = (st == S_COL) && fq_valid && !n[3] && !fq_end && (n[2:0] == gi_t[2:0]);
		(* dont_touch = "true" *) wire q_clr_s = rst_sync || (st == S_GO && !r_fl_we_int);
		always @(posedge clk) begin
			if (q_we_x)
				qbx_arr[gi_t] <= fq_xy_b[15:0];
			if (q_we_y)
				qby_arr[gi_t] <= fq_xy_b[31:16];
			if (q_clr_s)
				qbs_arr[gi_t] <= 16'd0;
			else if (q_we_s)
				qbs_arr[gi_t] <= fq_scov;
		end
	end
	endgenerate

	wire [31:0] qbc;	/* the lanes with a sample (fl_info's coverage) */
	genvar gi_l;
	generate
	for (gi_t = 0; gi_t < 8; gi_t = gi_t + 1) begin : g_qbc_q
		for (gi_l = 0; gi_l < 4; gi_l = gi_l + 1) begin : g_qbc_l
			assign qbc[4 * gi_t + gi_l] = (qbs_arr[gi_t][4 * gi_l +: 4] != 4'd0);
		end
	end
	endgenerate

	integer k;

	wire [15:0] qx  = {qbx_arr[r_qi_rep[1]][15:8], qbx_arr[r_qi_rep[0]][7:0]};
	wire [15:0] qy  = {qby_arr[r_qi_rep[3]][15:8], qby_arr[r_qi_rep[2]][7:0]};
	wire [15:0] s4q = {qbs_arr[r_qi_rep[5]][15:8], qbs_arr[r_qi_rep[4]][7:0]};	/* the quad's samples */
	wire [3:0]  ccq = qcc[4 * r_qi_rep[6] +: 4];

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
	(* extract_reset = "no" *) reg [127:0] cb0, cb1, cb2;	/* the centroid's barycentrics */
	(* extract_reset = "no" *) reg [127:0] dsv;		/* the triangle's d_s */

	/* Pre-computed lane coordinates x + 0.5, y + 0.5 during S_BARY (LAT = 5 + 1 = 6 cycles, BARY takes > 40 cycles) */
	wire [31:0] x2_p [0:1];
	wire [31:0] y2_p [0:1];
	(* extract_reset = "no" *) reg [31:0] r_xc [0:1];
	(* extract_reset = "no" *) reg [31:0] r_yc [0:1];
	wire [3:0] xy_bo_unused;
	generate
	for (gi_t = 0; gi_t < 2; gi_t = gi_t + 1) begin : g_xy_pipe
		wire [15:0] xl_w = {qx[15:1], (gi_t == 1) ? 1'b1 : qx[0]};
		wire [15:0] yl_w = {qy[15:1], (gi_t == 1) ? 1'b1 : qy[0]};
		atg_rx_fix2f_pipe #(.W(17), .F(0), .SIGNED(1)) u_x2 (.clk(clk), .i_v({1'b0, xl_w[14:0], 1'b1}), .o_f(x2_p[gi_t]));
		atg_rx_fix2f_pipe #(.W(17), .F(0), .SIGNED(1)) u_y2 (.clk(clk), .i_v({1'b0, yl_w[14:0], 1'b1}), .o_f(y2_p[gi_t]));

		/* Subtract 1 from exponent (bits [30:23]) via 8-bit am_sub (0 Pre-LUTs, 0 Post-LUTs) */
		wire [7:0] exp_x_m1, exp_y_m1;
		am_sub #(.W(8)) u_ex (.a(x2_p[gi_t][30:23]), .b(8'd1), .bi(1'b0), .d(exp_x_m1), .bo(xy_bo_unused[2 * gi_t + 0]));
		am_sub #(.W(8)) u_ey (.a(y2_p[gi_t][30:23]), .b(8'd1), .bi(1'b0), .d(exp_y_m1), .bo(xy_bo_unused[2 * gi_t + 1]));

		always @(posedge clk) begin
			r_xc[gi_t] <= {x2_p[gi_t][31], exp_x_m1, x2_p[gi_t][22:0]};
			r_yc[gi_t] <= {y2_p[gi_t][31], exp_y_m1, y2_p[gi_t][22:0]};
		end
	end
	endgenerate

	/* Pre-computed clamped Z per lane on b_done (0 CARRY4s on fl_data path) */
	wire [3:0] z_gt_one_bo, z_gt_one_unused;
	wire [123:0] z_sub_d_unused;
	(* extract_reset = "no" *) reg [31:0] r_zcl [0:3];
`ifdef MUT_R3_CLAMP
	wire zclamp = 1'b1;
`else
`ifdef MUT_RX_DCLIP
	wire zclamp = !ms4;
`else
	wire zclamp = !ms4 && !dclip;
`endif
`endif
	generate
	for (gi_t = 0; gi_t < 4; gi_t = gi_t + 1) begin : g_zcl_lane
		wire [31:0] z_lane = oz[32 * gi_t +: 32];
		/* ONE < z_lane <==> borrow of (ONE[30:0] - z_lane[30:0]) */
		am_sub #(.W(31)) u_zgt1 (
			.a(ONE[30:0]),
			.b(z_lane[30:0]),
			.bi(1'b0),
			.d(z_sub_d_unused[31 * gi_t +: 31]),
			.bo(z_gt_one_bo[gi_t])
		);
		assign z_gt_one_unused[gi_t] = 1'b0;
		(* keep = "true" *) wire z_ef = &z_lane[30:23];
		(* keep = "true" *) wire z_m0 = |z_lane[5:0];
		(* keep = "true" *) wire z_m1 = |z_lane[11:6];
		(* keep = "true" *) wire z_m2 = |z_lane[17:12];
		(* keep = "true" *) wire z_m3 = |z_lane[22:18];
		(* dont_touch = "true" *) reg r_z_zero_lo, r_z_zero_hi, r_z_gt1_lo, r_z_gt1_hi;
		wire z_we_raw = (st == S_BARY) && b_done;
		wire z_we_lo, z_we_hi;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_zwl (.I0(z_we_raw), .O(z_we_lo));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_zwh (.I0(z_we_raw), .O(z_we_hi));
`else
		assign z_we_lo = z_we_raw;
		assign z_we_hi = z_we_raw;
`endif
		always @(posedge clk) begin
			r_z_zero_lo <= zclamp && (z_lane[31] || (z_ef && (z_m0 || z_m1 || z_m2 || z_m3)));
			r_z_zero_hi <= zclamp && (z_lane[31] || (z_ef && (z_m0 || z_m1 || z_m2 || z_m3)));
			r_z_gt1_lo  <= zclamp && z_gt_one_bo[gi_t];
			r_z_gt1_hi  <= zclamp && z_gt_one_bo[gi_t];
			if (z_we_lo)
				r_zcl[gi_t][15:0]  <= r_z_zero_lo ? 16'd0 : (r_z_gt1_lo ? ONE[15:0]  : z_lane[15:0]);
			if (z_we_hi)
				r_zcl[gi_t][31:16] <= r_z_zero_hi ? 16'd0 : (r_z_gt1_hi ? ONE[31:16] : z_lane[31:16]);
		end
	end
	endgenerate

	/* The copy: reads (cv, cw) → writes the next cycle; then the map, then d_s. */
	(* extract_reset = "no" *) reg [1:0] cv;
	(* extract_reset = "no" *) reg [6:0] cw;
	reg rd_done, rv_q, map_done;
	(* max_fanout = 16 *) reg [2:0] dsn;	/* d_s words written */
	(* dont_touch = "true", extract_reset = "no" *) reg [1:0] r_dsn_sel [0:1];
	reg [1:0] rv_v;
	reg [6:0] rv_w;
	wire rd_now = st == S_COPY && !rd_done;
	assign pt_rd = rd_now;
	assign pt_idx = ent[8 * cv +: 8];
	wire [7:0] fc_carry_unused;
	am_add #(.W(7)) u_pt_word (.a(cw), .b(7'd4), .ci(1'b0), .s(pt_word), .co(fc_carry_unused[0]));
	assign pt_busy = st == S_COPY;
	(* dont_touch = "true" *) wire map_we    = st == S_COPY && rd_done && !rv_q && !map_done;
	(* dont_touch = "true" *) wire map_we_ad = st == S_COPY && rd_done && !rv_q && !map_done;
	(* dont_touch = "true" *) wire map_we_lo = st == S_COPY && rd_done && !rv_q && !map_done;
	(* dont_touch = "true" *) wire map_we_hi = st == S_COPY && rd_done && !rv_q && !map_done;
	(* dont_touch = "true" *) wire ds_we     = st == S_COPY && map_done && ms4 && dsn != 3'd4;
	(* dont_touch = "true" *) wire ds_we_ad  = st == S_COPY && map_done && ms4 && dsn != 3'd4;
	(* dont_touch = "true" *) wire ds_we_lo  = st == S_COPY && map_done && ms4 && dsn != 3'd4;
	(* dont_touch = "true" *) wire ds_we_hi  = st == S_COPY && map_done && ms4 && dsn != 3'd4;
	assign fl_pw_we = rv_q || map_we || ds_we;
	assign fl_pw_addr = map_we_ad ? 12'hFFF : ds_we_ad ? {10'h3FE, dsn[1:0]} :
		{1'b0, 3'd0, rv_v, rv_w[5:0]};
	wire [31:0] dsv_mux = {dsv[{r_dsn_sel[1], 1'b1, 4'd0} +: 16], dsv[{r_dsn_sel[0], 5'd0} +: 16]};
	assign fl_pw_data[15:0]  = map_we_lo ? 16'd0 : ds_we_lo ? dsv_mux[15:0]  : pt_rdata[15:0];
	assign fl_pw_data[31:16] = map_we_hi ? 16'd0 : ds_we_hi ? dsv_mux[31:16] : pt_rdata[31:16];
	wire copy_end = map_done && (!ms4 || dsn == 3'd4);

	/* The register writes: lane wl of the quad, register wr (pipelined 1 cycle for 0-LUT outputs) */
	(* max_fanout = 16 *) reg [1:0] wl;
	(* max_fanout = 16 *) reg [3:0] wr;
	(* dont_touch = "true", extract_reset = "no" *) reg [1:0] r_wl_s [0:15];
	(* dont_touch = "true", extract_reset = "no" *) reg [3:0] r_wr_s [0:15];
	(* dont_touch = "true", extract_reset = "no" *) reg [15:0] r_needc_s;

	wire [3:0] nreg = cent ? 4'd10 : 4'd7;
	/* the counters + 1 */
	wire [3:0] n1, wr1, qi1;
	wire [6:0] cw1;
	wire [1:0] cv1, wl1;
	wire [2:0] dsn1;
	am_add #(.W(4)) u_n1 (.a(n), .b(4'd0), .ci(1'b1), .s(n1), .co(fc_carry_unused[1]));
	am_add #(.W(4)) u_wr1 (.a(wr), .b(4'd0), .ci(1'b1), .s(wr1), .co(fc_carry_unused[2]));
	am_add #(.W(4)) u_qi1 (.a({1'b0, qi}), .b(4'd0), .ci(1'b1), .s(qi1), .co(fc_carry_unused[3]));
	am_add #(.W(7)) u_cw1 (.a(cw), .b(7'd0), .ci(1'b1), .s(cw1), .co(fc_carry_unused[4]));
	am_add #(.W(2)) u_cv1 (.a(cv), .b(2'd0), .ci(1'b1), .s(cv1), .co(fc_carry_unused[5]));
	am_add #(.W(2)) u_wl1 (.a(wl), .b(2'd0), .ci(1'b1), .s(wl1), .co(fc_carry_unused[6]));
	am_add #(.W(3)) u_dsn1 (.a(dsn), .b(3'd0), .ci(1'b1), .s(dsn1), .co(fc_carry_unused[7]));

	/* Sliced fl_data mux (16 slices x 2 bits -> fanout of r_wl_s/r_wr_s <= 16!) and registered output */
	wire [31:0] fl_data_comb;
	generate
	for (gi_t = 0; gi_t < 16; gi_t = gi_t + 1) begin : g_fld_slice
		wire [1:0] wl_s = r_wl_s[gi_t];
		wire [3:0] wr_s = r_wr_s[gi_t];
		wire nc_s       = r_needc_s[gi_t];
		wire [1:0] b0_s = ob0[{wl_s, gi_t[3:0], 1'b0} +: 2];
		wire [1:0] b1_s = ob1[{wl_s, gi_t[3:0], 1'b0} +: 2];
		wire [1:0] b2_s = ob2[{wl_s, gi_t[3:0], 1'b0} +: 2];
		wire [1:0] c0_s = nc_s ? cb0[{wl_s, gi_t[3:0], 1'b0} +: 2] : b0_s;
		wire [1:0] c1_s = nc_s ? cb1[{wl_s, gi_t[3:0], 1'b0} +: 2] : b1_s;
		wire [1:0] c2_s = nc_s ? cb2[{wl_s, gi_t[3:0], 1'b0} +: 2] : b2_s;
		wire [1:0] zc_s = r_zcl[wl_s][2 * gi_t +: 2];
		wire [1:0] xc_s = r_xc[wl_s[0]][2 * gi_t +: 2];
		wire [1:0] yc_s = r_yc[wl_s[1]][2 * gi_t +: 2];
		wire [1:0] s4_s = (gi_t < 2) ? s4q[{wl_s, gi_t[0], 1'b0} +: 2] : 2'd0;

		(* keep = "true" *) wire [1:0] m_03 = wr_s[1] ?
			(wr_s[0] ? zc_s : b2_s) :
			(wr_s[0] ? b1_s : b0_s);
		(* keep = "true" *) wire [1:0] m_47 = wr_s[1] ?
			(wr_s[0] ? c0_s : s4_s) :
			(wr_s[0] ? yc_s : xc_s);
		(* keep = "true" *) wire [1:0] m_89 = wr_s[0] ? c2_s : c1_s;
		assign fl_data_comb[2 * gi_t +: 2] = wr_s[3] ? m_89 : (wr_s[2] ? m_47 : m_03);
	end
	endgenerate

	reg [5:0] r_fl_reg;
	reg [4:0] r_fl_lane;
	(* extract_reset = "no" *) reg [31:0] r_fl_data;
	always @(posedge clk) begin
		if (rst_sync) begin
			r_fl_we     <= 1'b0;
			r_fl_we_int <= 1'b0;
			r_fl_reg    <= 6'd0;
			r_fl_lane   <= 5'd0;
		end else begin
			r_fl_we     <= (st == S_WR);
			r_fl_we_int <= (st == S_WR);
			r_fl_reg    <= {2'd0, wr};
			r_fl_lane   <= {qi, wl};
		end
		r_fl_data <= fl_data_comb;
	end

	assign fl_we = r_fl_we;
	assign fl_reg = r_fl_reg;
	assign fl_lane = r_fl_lane;
	assign fl_data = r_fl_data;

	assign fl_req = st == S_ALLOC;
	assign fl_go = (st == S_GO) && !r_fl_we_int;
	assign sq_req = (st == S_GO) && !r_fl_we_int;
	reg [31:0] qmask;
	always @(*)
		for (k = 0; k < 8; k = k + 1)
			qmask[4 * k +: 4] = {4{k < n}};
	assign fl_mask = qmask;
	assign fl_info = {15'd0, front, sq_seq, qbc};
	assign busy = st != S_COL || n != 4'd0;

	/* Next-cycle replicas for qi, wl, wr, needc, dsn */
	wire [2:0] qi_nxt = (st == S_ALLOC && fl_gnt) ? 3'd0 :
		((st == S_WR && wr1 == nreg && wl == 2'd3 && qi1 != n) ? qi1[2:0] : qi);
	wire [1:0] wl_nxt = (st == S_BARY && b_done) ? 2'd0 :
		((st == S_WR && wr1 == nreg) ? wl1 : wl);
	wire [3:0] wr_nxt = (st == S_BARY && b_done) ? 4'd0 :
		((st == S_WR) ? ((wr1 == nreg) ? 4'd0 : wr1) : wr);
	wire [1:0] dsn_nxt_sel = (st == S_ALLOC && fl_gnt) ? 2'd0 :
		(ds_we ? dsn1[1:0] : dsn[1:0]);

	always @(posedge clk) begin
		r_needc_s <= {16{needc}};
		r_dsn_sel[0] <= dsn_nxt_sel;
		r_dsn_sel[1] <= dsn_nxt_sel;
		for (k = 0; k < 7; k = k + 1)
			r_qi_rep[k] <= qi_nxt;
		for (k = 0; k < 16; k = k + 1) begin
			r_wl_s[k] <= wl_nxt;
			r_wr_s[k] <= wr_nxt;
		end
	end

	wire cb_we_root = (st == S_BARYC) && b_done;
	wire [1:0] cb_we_mid;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cbm0 (.I0(cb_we_root), .O(cb_we_mid[0]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cbm1 (.I0(cb_we_root), .O(cb_we_mid[1]));
`else
	assign cb_we_mid = {2{cb_we_root}};
`endif
	generate
	for (gi_t = 0; gi_t < 8; gi_t = gi_t + 1) begin : g_cbdsv_slice
		wire cb_we_raw = cb_we_mid[gi_t / 4];
		wire ds_we_raw = (st == S_DZ) && b_done;
		wire cb0_we_s, cb1_we_s, cb2_we_s, dsv_we_s;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cb0 (.I0(cb_we_raw), .O(cb0_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cb1 (.I0(cb_we_raw), .O(cb1_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_cb2 (.I0(cb_we_raw), .O(cb2_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_dsv (.I0(ds_we_raw), .O(dsv_we_s));
`else
		assign cb0_we_s = cb_we_raw;
		assign cb1_we_s = cb_we_raw;
		assign cb2_we_s = cb_we_raw;
		assign dsv_we_s = ds_we_raw;
`endif
		always @(posedge clk) begin
			if (cb0_we_s)
				cb0[16 * gi_t +: 16] <= ob0[16 * gi_t +: 16];
			if (cb1_we_s)
				cb1[16 * gi_t +: 16] <= ob1[16 * gi_t +: 16];
			if (cb2_we_s)
				cb2[16 * gi_t +: 16] <= ob2[16 * gi_t +: 16];
			if (dsv_we_s)
				dsv[16 * gi_t +: 16] <= ods[16 * gi_t +: 16];
		end
	end
	endgenerate

	always @(posedge clk) begin
		if (rst_sync) begin
			st <= S_COL;
			n <= 4'd0;
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
						qcc[4 * n[2:0] +: 4] <= fq_ccov;
						n <= n1;
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
					dz_done <= 1'b1;
					st <= S_COPY;
				end
			S_COPY: begin
				if (rd_now) begin
					if (cw1 == vc) begin
						cw <= 7'd0;
						cv <= cv1;
						if (cv == 2'd2)
							rd_done <= 1'b1;
					end else
						cw <= cw1;
				end
				if (map_we)
					map_done <= 1'b1;
				if (ds_we)
					dsn <= dsn1;
				if (copy_end) begin
					bgo <= 1'b1;
					st <= cent && ms4 && needc ? S_BARYC : S_BARY;
				end
			end
			S_BARYC:
				if (b_done) begin
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
				if (wr1 == nreg) begin
					wr <= 4'd0;
					wl <= wl1;
					if (wl == 2'd3) begin
						if (qi1 == n)
							st <= S_GO;
						else begin
							qi <= qi1[2:0];
							st <= S_COPY;	/* copy_end holds: on to the next quad */
						end
					end
				end else
					wr <= wr1;
			default: begin	/* S_GO: wait 1 cycle for r_fl_we to drain, then pulse fl_go */
				if (!r_fl_we_int) begin
					n <= 4'd0;
					qcc <= 32'd0;
					st <= S_COL;
				end
			end
			endcase
		end
	end

	wire unused_ok = &{1'b0, rv_w[6], t_tri[767:764], t_tri[762:760], t_tri[351:320],
		t_tri[287:0], b_busy, fc_carry_unused, xy_bo_unused, z_gt_one_unused, z_sub_d_unused};
endmodule

`default_nettype wire
