/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_pk_tb: atg_su_pk (NPHYS 8) with PACKED = 1 and PACKED = 0 against
 * the vectors of tools/gsi1fp.py --pk-vec (sim/tb/su/pk_vec.hex: op, rm,
 * hsel, sub, sat, a, b, c and the exact model's result).  One vector per
 * group in every lane, a random EXEC mask; the result SHORT_LAT cycles
 * later with rd and the mask.
 *   pack:  packh/unpackh/swaph on both units;
 *   arith: the packed arithmetic on the PACKED unit;
 *   shared: every vector on a PK_SHARED pair, atg_su_pk and atg_su_fpu
 *          (the fp16 operations on the FPU, two cycles a group: the
 *          vectors wait for x_ready), the results from either s_* port,
 *          then ffma2 cases that a fp32 result rounded to nearest would
 *          round twice wrongly (the fp32 rounding is to odd).
 * The PACKED unit and the PK_SHARED pair are also built with NPHYS 4 (the
 * KC705's, GRP_W 3) on the low 4 lanes of the same inputs; their outputs
 * must equal those lanes of the NPHYS 8 units every cycle (nphys4).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_pk_tb;
`include "atg_su_uop.vh"

	localparam NPHYS = 8;
	localparam DW = NPHYS * 32;
	localparam LAT = 6;
	localparam NV = 4000;
	localparam ND = 6;	/* the ffma2 double-rounding cases: a, b, c, the result */
	reg [63:0] dvec [0:ND-1];
	initial begin
		dvec[0] = 64'h104b_3d63_1fb4_2037;
		dvec[1] = 64'h6d80_3d9c_0415_6fb7;
		dvec[2] = 64'h5c69_4a00_8677_6a9d;
		dvec[3] = 64'h0e31_336e_a0e7_a0db;
		dvec[4] = 64'h6600_479e_0969_71b7;
		dvec[5] = 64'hf3e8_332b_9ffb_eb15;
	end

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg x_valid = 1'b0;
	reg [103:0] x_uop = 0;
	reg [DW-1:0] x_a = 0, x_b = 0, x_c = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	wire r1, r0, v1, v0;
	wire [1:0] w1, w0, g1, g0;
	wire [6:0] rd1, rd0;
	wire [DW-1:0] d1, d0;
	wire [NPHYS-1:0] m1, m0;

	atg_su_pk #(.NPHYS(NPHYS), .SHORT_LAT(LAT), .PACKED(1)) pk1 (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(2'd2), .x_grp(2'd1),
		.x_last(1'b1), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
		.x_c(x_c), .x_mask(x_mask), .x_info(32'd0), .x_ready(r1),
		.s_valid(v1), .s_warp(w1), .s_grp(g1), .s_rd(rd1), .s_data(d1), .s_lanes(m1)
	);
	atg_su_pk #(.NPHYS(NPHYS), .SHORT_LAT(LAT), .PACKED(0)) pk0 (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(2'd2), .x_grp(2'd1),
		.x_last(1'b1), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
		.x_c(x_c), .x_mask(x_mask), .x_info(32'd0), .x_ready(r0),
		.s_valid(v0), .s_warp(w0), .s_grp(g0), .s_rd(rd0), .s_data(d0), .s_lanes(m0)
	);

	/* The PK_SHARED pair. */
	reg xs_valid = 1'b0;
	reg [103:0] xs_uop = 0;
	reg [DW-1:0] xs_a = 0, xs_b = 0, xs_c = 0;
	reg [2*NPHYS-1:0] xs_mask = 0;
	wire rs_p, rs_f, vs_p, vs_f;
	wire [1:0] ws_p, ws_f, gs_p, gs_f;
	wire [6:0] rds_p, rds_f;
	wire [DW-1:0] ds_p, ds_f;
	wire [NPHYS-1:0] ms_p, ms_f;
	atg_su_pk #(.NPHYS(NPHYS), .SHORT_LAT(LAT), .PACKED(1), .PK_SHARED(1)) pks (
		.clk(clk), .rst_n(rst_n), .x_valid(xs_valid), .x_warp(2'd2), .x_grp(2'd1),
		.x_last(1'b1), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(xs_uop), .x_a(xs_a), .x_b(xs_b),
		.x_c(xs_c), .x_mask(xs_mask), .x_info(32'd0), .x_ready(rs_p),
		.s_valid(vs_p), .s_warp(ws_p), .s_grp(gs_p), .s_rd(rds_p), .s_data(ds_p), .s_lanes(ms_p)
	);
	atg_su_fpu #(.NPHYS(NPHYS), .SHORT_LAT(LAT), .PACKED(1), .PK_SHARED(1)) fpus (
		.clk(clk), .rst_n(rst_n), .x_valid(xs_valid), .x_warp(2'd2), .x_grp(2'd1),
		.x_last(1'b1), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(xs_uop), .x_a(xs_a), .x_b(xs_b),
		.x_c(xs_c), .x_mask(xs_mask), .x_info(32'd0), .x_ready(rs_f),
		.s_valid(vs_f), .s_warp(ws_f), .s_grp(gs_f), .s_rd(rds_f), .s_data(ds_f), .s_lanes(ms_f)
	);
	wire vs = vs_p || vs_f;
	wire [6:0] rds = vs_f ? rds_f : rds_p;
	wire [DW-1:0] dss = vs_f ? ds_f : ds_p;
	wire [NPHYS-1:0] mss = vs_f ? ms_f : ms_p;
	wire [1:0] wss = vs_f ? ws_f : ws_p, gss = vs_f ? gs_f : gs_p;
	reg [NPHYS-1:0] want_ms [0:NV+ND-1];
	integer err_s, ns_out, is, ts;

	/* NPHYS 4: the low 4 lanes. */
	localparam DW4 = 4 * 32;
	wire r1_4, v1_4, rs_p4, rs_f4, vs_p4, vs_f4;
	wire [1:0] w1_4, ws_p4, ws_f4;
	wire [2:0] g1_4, gs_p4, gs_f4;
	wire [6:0] rd1_4, rds_p4, rds_f4;
	wire [DW4-1:0] d1_4, ds_p4, ds_f4;
	wire [3:0] m1_4, ms_p4, ms_f4;
	atg_su_pk #(.NPHYS(4), .GRP_W(3), .SHORT_LAT(LAT), .PACKED(1)) pk1_4 (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(2'd2), .x_grp(3'd5),
		.x_last(1'b1), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a[DW4-1:0]),
		.x_b(x_b[DW4-1:0]), .x_c(x_c[DW4-1:0]), .x_mask({x_mask[NPHYS +: 4], x_mask[3:0]}),
		.x_info(32'd0), .x_ready(r1_4),
		.s_valid(v1_4), .s_warp(w1_4), .s_grp(g1_4), .s_rd(rd1_4), .s_data(d1_4), .s_lanes(m1_4)
	);
	atg_su_pk #(.NPHYS(4), .GRP_W(3), .SHORT_LAT(LAT), .PACKED(1), .PK_SHARED(1)) pks_4 (
		.clk(clk), .rst_n(rst_n), .x_valid(xs_valid), .x_warp(2'd2), .x_grp(3'd5),
		.x_last(1'b1), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(xs_uop), .x_a(xs_a[DW4-1:0]),
		.x_b(xs_b[DW4-1:0]), .x_c(xs_c[DW4-1:0]), .x_mask({xs_mask[NPHYS +: 4], xs_mask[3:0]}),
		.x_info(32'd0), .x_ready(rs_p4),
		.s_valid(vs_p4), .s_warp(ws_p4), .s_grp(gs_p4), .s_rd(rds_p4), .s_data(ds_p4),
		.s_lanes(ms_p4)
	);
	atg_su_fpu #(.NPHYS(4), .GRP_W(3), .SHORT_LAT(LAT), .PACKED(1), .PK_SHARED(1)) fpus_4 (
		.clk(clk), .rst_n(rst_n), .x_valid(xs_valid), .x_warp(2'd2), .x_grp(3'd5),
		.x_last(1'b1), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(xs_uop), .x_a(xs_a[DW4-1:0]),
		.x_b(xs_b[DW4-1:0]), .x_c(xs_c[DW4-1:0]), .x_mask({xs_mask[NPHYS +: 4], xs_mask[3:0]}),
		.x_info(32'd0), .x_ready(rs_f4),
		.s_valid(vs_f4), .s_warp(ws_f4), .s_grp(gs_f4), .s_rd(rds_f4), .s_data(ds_f4),
		.s_lanes(ms_f4)
	);
	integer err_4;
	initial
		err_4 = 0;
	always @(posedge clk)
		if (rst_n && ({r1_4, v1_4, w1_4, rd1_4, m1_4, rs_p4, rs_f4, vs_p4, vs_f4, ws_p4, ws_f4,
		    rds_p4, rds_f4, ms_p4, ms_f4} !== {r1, v1, w1, rd1, m1[3:0], rs_p, rs_f, vs_p, vs_f,
		    ws_p, ws_f, rds_p, rds_f, ms_p[3:0], ms_f[3:0]} ||
		    (v1 && (g1_4 !== 3'd5 || d1_4 !== d1[DW4-1:0])) ||
		    (vs_p && (gs_p4 !== 3'd5 || ds_p4 !== ds_p[DW4-1:0])) ||
		    (vs_f && (gs_f4 !== 3'd5 || ds_f4 !== ds_f[DW4-1:0])))) begin
			if (err_4 < 10)
				$display("FAIL atg_su_pk: the NPHYS 4 units differ (vector %0d, shared %0d)",
					n_out, ns_out);
			err_4 = err_4 + 1;
		end

	always @(posedge clk) begin
		if (rst_n && vs) begin
			if ((vs_p && vs_f) || rds !== ns_out % 63 || mss !== want_ms[ns_out] ||
			    wss !== 2'd2 || gss !== 2'd1) begin
				$display("FAIL atg_su_pk: shared vector %0d fields", ns_out);
				err_s = err_s + 1;
			end
			for (ts = 0; ts < NPHYS; ts = ts + 1)
				if (want_ms[ns_out][ts] && dss[ts*32 +: 32] !== want[ns_out]) begin
					if (err_s < 10)
						$display("FAIL atg_su_pk: shared vector %0d op %0d: %h want %h",
							ns_out, want_op[ns_out], dss[ts*32 +: 32], want[ns_out]);
					err_s = err_s + 1;
				end
			ns_out = ns_out + 1;
		end
	end

	initial begin
		err_s = 0;
		ns_out = 0;
		wait (rst_n);
		for (is = 0; is < NV; is = is + 1) begin
			@(negedge clk);
			xs_valid = 1'b1;
			xs_uop = 0;
			xs_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_PK;
			xs_uop[ATG_UOP_WRD] = 1'b1;
			xs_uop[ATG_UOP_RD +: 7] = is % 63;
			xs_uop[ATG_UOP_OP +: 8] = vec[is][147:144];
			xs_uop[ATG_UOP_RM +: 3] = vec[is][142:140];
			xs_uop[ATG_UOP_HSEL +: 2] = vec[is][137:136];
			xs_uop[ATG_UOP_SUB +: 5] = vec[is][132];
			xs_uop[ATG_UOP_MOD + 6] = vec[is][128];
			xs_mask = $random(seed);
			for (l = 0; l < NPHYS; l = l + 1) begin
				xs_a[l*32 +: 32] = vec[is][127:96];
				xs_b[l*32 +: 32] = vec[is][95:64];
				xs_c[l*32 +: 32] = vec[is][63:32];
			end
			want_ms[is] = xs_mask[NPHYS-1:0];
			/* held while the pair is busy (x_ready is read at the edge) */
			while (!(rs_p && rs_f))
				@(negedge clk);
		end
		for (is = NV; is < NV + ND; is = is + 1) begin
			@(negedge clk);
			xs_uop[ATG_UOP_RD +: 7] = is % 63;
			xs_uop[ATG_UOP_OP +: 8] = ATG_PK_FFMA2;
			xs_uop[ATG_UOP_RM +: 3] = 3'd0;
			xs_uop[ATG_UOP_HSEL +: 2] = 2'd0;
			xs_uop[ATG_UOP_SUB +: 5] = 5'd0;
			xs_uop[ATG_UOP_MOD + 6] = 1'b0;
			xs_mask = {2*NPHYS{1'b1}};
			for (l = 0; l < NPHYS; l = l + 1) begin
				xs_a[l*32 +: 32] = {2{dvec[is - NV][63:48]}};
				xs_b[l*32 +: 32] = {2{dvec[is - NV][47:32]}};
				xs_c[l*32 +: 32] = {2{dvec[is - NV][31:16]}};
			end
			want[is] = {2{dvec[is - NV][15:0]}};
			want_op[is] = ATG_PK_FFMA2[3:0];
			want_ms[is] = {NPHYS{1'b1}};
			while (!(rs_p && rs_f))
				@(negedge clk);
		end
		@(negedge clk);
		xs_valid = 1'b0;
	end

	reg [147:0] vec [0:NV-1];
	reg [31:0] want [0:NV+ND-1];
	reg [NPHYS-1:0] want_m [0:NV-1];
	reg [3:0] want_op [0:NV+ND-1];
	integer err_p, err_a, seed, i, l, n_out, t;

	always @(posedge clk) begin
		if (rst_n && v1) begin
			if (!v0 || rd1 !== n_out % 63 || m1 !== want_m[n_out] || w1 !== 2'd2 ||
			    g1 !== 2'd1 || rd0 !== rd1 || m0 !== m1) begin
				$display("FAIL atg_su_pk: vector %0d fields", n_out);
				err_p = err_p + 1;
			end
			for (t = 0; t < NPHYS; t = t + 1)
				if (want_m[n_out][t]) begin
					if (d1[t*32 +: 32] !== want[n_out]) begin
						if (err_p + err_a < 10)
							$display("FAIL atg_su_pk: vector %0d op %0d: %h want %h", n_out,
								want_op[n_out], d1[t*32 +: 32], want[n_out]);
						if (want_op[n_out] >= 4'd13)
							err_p = err_p + 1;
						else
							err_a = err_a + 1;
					end
					if (want_op[n_out] >= 4'd13 && d0[t*32 +: 32] !== want[n_out]) begin
						$display("FAIL atg_su_pk: PACKED 0 vector %0d op %0d", n_out,
							want_op[n_out]);
						err_p = err_p + 1;
					end
				end
			n_out = n_out + 1;
		end
	end

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		err_p = 0;
		err_a = 0;
		n_out = 0;
		$readmemh("sim/tb/su/pk_vec.hex", vec);
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		for (i = 0; i < NV; i = i + 1) begin
			@(negedge clk);
			x_valid = 1'b1;
			x_uop = 0;
			x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_PK;
			x_uop[ATG_UOP_WRD] = 1'b1;
			x_uop[ATG_UOP_RD +: 7] = i % 63;
			x_uop[ATG_UOP_OP +: 8] = vec[i][147:144];
			x_uop[ATG_UOP_RM +: 3] = vec[i][142:140];
			x_uop[ATG_UOP_HSEL +: 2] = vec[i][137:136];
			x_uop[ATG_UOP_SUB +: 5] = vec[i][132];
			x_uop[ATG_UOP_MOD + 6] = vec[i][128];
			x_mask = $random(seed);
			for (l = 0; l < NPHYS; l = l + 1) begin
				x_a[l*32 +: 32] = vec[i][127:96];
				x_b[l*32 +: 32] = vec[i][95:64];
				x_c[l*32 +: 32] = vec[i][63:32];
			end
			want[i] = vec[i][31:0];
			want_m[i] = x_mask[NPHYS-1:0];
			want_op[i] = vec[i][147:144];
			if (!r1 || !r0) begin
				$display("FAIL atg_su_pk: x_ready 0");
				err_p = err_p + 1;
			end
		end
		@(negedge clk);
		x_valid = 1'b0;
		wait (!xs_valid);
		repeat (LAT + 3) @(posedge clk);
		if (ns_out != NV + ND) begin
			$display("FAIL atg_su_pk: %0d shared results for %0d groups", ns_out, NV + ND);
			err_s = err_s + 1;
		end
		if (n_out != NV) begin
			$display("FAIL atg_su_pk: %0d results for %0d groups", n_out, NV);
			err_p = err_p + 1;
		end
		if (err_p == 0) $display("PASS atg_su_pk.pack");
		if (err_a == 0) $display("PASS atg_su_pk.arith");
		if (err_s == 0) $display("PASS atg_su_pk.shared");
		if (err_4 == 0) $display("PASS atg_su_pk.nphys4");
		if (err_p + err_a + err_s + err_4 == 0) $display("PASS atg_su_pk");
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL atg_su_pk timeout");
		$finish;
	end
endmodule

`default_nettype wire
