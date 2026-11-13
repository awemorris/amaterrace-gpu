/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_clip: RX primitive input and clipping: reads the vertices'
 * clip-space positions from the PT (or DRAW_RAW's screen-space vertices
 * from STATE 0x1E0-0x1E8), clips points, lines and triangles against the
 * w, near, far and guard-band planes (atg_rx_cpoly), and passes the
 * results to atg_rx_setup with weights relative to the original vertices.
 *
 * A vertex is 7 fp32 words {x, y, z, w, w0, w1, w2}.  prim_vtx[25:24] is
 * the kind (0 point (p, p, p), 1 line (a, b, b), 2 or 3 triangle); 4, 8 or
 * 12 PT words are read.  Planes in order: 0 w >= 2^-16 (always), 1 z >= 0
 * (DEPTH_CLAMP[1] = 0, or [1] without [0]), 2 z <= w ([1] without [0]),
 * 3-6 the guard band (x_off w + x_scale x within +-16383 w, the same in
 * y) when a vertex is not inside the trivial bound below.  Trivial accept
 * (fp32 compares only): every vertex has w >= 2^-16, is inside the depth
 * planes that apply, and has |x|, |y| <= 4 w with |x_off|, |y_off| <= 6144
 * and |x_scale|, |y_scale| <= 2048 (then it lies inside the guard band):
 * the primitive passes unchanged.  Otherwise atg_rx_cpoly cuts by each
 * plane that applies; a triangle comes out as a fan (v0, v_i, v_i+1), a
 * line as one line (a', b', b'); a point is passed when inside planes 0-2
 * as they apply and dropped otherwise (x and y are not clipped).  Nothing
 * left, or RAST_MODE[6] (rasterizer discard, without reading the PT): one
 * empty triangle (positions (0, 0, 0, 1)) with the last-use flags.  Only
 * the last output of a primitive carries prim_free; cl_last is on the last
 * output of the draw's last primitive.  A line's third vertex is its
 * second, a point's three are the vertex.  See spec/gpu/rx/atg_rx_clip.md.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *) module atg_rx_clip #(
	parameter ENABLE_CPOLY = 1
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire raw_kick,
	/* Primitives to the RX */
	input wire prim_valid,
	output wire prim_ready,
	input wire [25:0] prim_vtx,
	input wire [2:0] prim_free,
	input wire prim_last,
	/* PT read (shared with atg_rx_scan in atg_rx: scan has priority) */
	output wire pt_rd,
	output wire [7:0] pt_idx,
	output wire [6:0] pt_word,
	input wire [31:0] pt_rdata,
	input wire pt_busy,
	output wire pt_active,
	/* To atg_rx_setup */
	output reg cl_valid,
	input wire cl_ready,
	output wire [701:0] cl_tri,
	output reg cl_last,
	output wire busy
);
	`include "ghci_regs.vh"
	localparam [31:0] ONE = 32'h3F800000;
	localparam [31:0] EPS = 32'h37800000;	/* 2^-16 */
	localparam [223:0] EMPTY = {96'd0, ONE, 96'd0};	/* (0, 0, 0, 1), weights 0 */

	wire rst_sync = !rst_n;

	/* STATE: VIEWPORT 0x050-0x053 (16-entry array), DEPTH_CLAMP 0x059, RAST_MODE[6],
	 * VIEWPORT_IDX 0x065, and DRAW_RAW's words 0x1E0-0x1E8 (x, y, z of each vertex). */
	(* extract_reset = "no" *) reg [31:0] rw [0:8];
	(* ram_style = "registers", extract_reset = "no" *) reg [15:0] vp_arr [0:7][0:15];
	(* extract_reset = "no" *) reg [15:0] r_vp_l1 [0:7][0:3];
	(* max_fanout = 16 *) reg [3:0] vp_idx;
	(* extract_reset = "no" *) reg [3:0] r_vp_idx_w [0:7];
	(* extract_reset = "no" *) reg [1:0] r_vp_idx_r [0:7][0:3];
	(* extract_reset = "no" *) reg [1:0] r_vp_idx_hi [0:7];
	(* extract_reset = "no" *) reg [127:0] r_vp;
	wire [127:0] vp = r_vp;

	reg [1:0] dc;
	reg discard;
	integer vpi, s_idx, g_idx;

	wire [31:0] st_wdata_rw = st_wdata;
	wire [15:0] st_wdata_vp [0:7];
	genvar g_b, g_rw, g_vs, g_ve;
	generate

	for (g_rw = 0; g_rw < 9; g_rw = g_rw + 1) begin : g_rw_word
		localparam [8:0] WORD_ADDR = GHCI_S_RAW + g_rw;
		wire rw_hit = st_we && (st_idx == WORD_ADDR);
		always @(posedge clk) begin
			if (rw_hit)
				rw[g_rw] <= st_wdata_rw;
		end
	end

	for (g_vs = 0; g_vs < 8; g_vs = g_vs + 1) begin : g_vp_slice
		localparam [8:0] VP_WORD_ADDR = GHCI_S_VIEWPORT + (g_vs / 2);
		localparam integer HI = (g_vs % 2) * 16;
		wire vp_s_we = st_we && (st_idx == VP_WORD_ADDR);
		assign st_wdata_vp[g_vs] = st_wdata[HI +: 16];

		for (g_ve = 0; g_ve < 16; g_ve = g_ve + 1) begin : g_ve_entry
			wire ve_we = vp_s_we && (r_vp_idx_w[g_vs] == g_ve[3:0]);
			always @(posedge clk) begin
				if (rst_sync)
					vp_arr[g_vs][g_ve] <= 16'd0;
				else if (ve_we)
					vp_arr[g_vs][g_ve] <= st_wdata_vp[g_vs];
			end
		end

		for (g_ve = 0; g_ve < 4; g_ve = g_ve + 1) begin : g_vp_mux1
			always @(posedge clk) begin
				r_vp_l1[g_vs][g_ve] <= vp_arr[g_vs][{g_ve[1:0], r_vp_idx_r[g_vs][g_ve]}];
			end
		end

		always @(posedge clk) begin
			r_vp[16 * g_vs +: 16] <= r_vp_l1[g_vs][r_vp_idx_hi[g_vs]];
		end
	end
	endgenerate

	wire [3:0] vp_idx_nxt_lo = rst_sync ? 4'd0 : ((st_we && st_idx == GHCI_S_VIEWPORT_IDX) ? st_wdata[3:0] : vp_idx);
	wire [3:0] vp_idx_nxt_hi = rst_sync ? 4'd0 : ((st_we && st_idx == GHCI_S_VIEWPORT_IDX) ? st_wdata[3:0] : vp_idx);
	wire [1:0] vp_idx_r_lo0  = rst_sync ? 2'd0 : ((st_we && st_idx == GHCI_S_VIEWPORT_IDX) ? st_wdata[1:0] : vp_idx[1:0]);
	wire [1:0] vp_idx_r_lo1  = rst_sync ? 2'd0 : ((st_we && st_idx == GHCI_S_VIEWPORT_IDX) ? st_wdata[1:0] : vp_idx[1:0]);
	wire [1:0] vp_idx_r_hi0  = rst_sync ? 2'd0 : ((st_we && st_idx == GHCI_S_VIEWPORT_IDX) ? st_wdata[1:0] : vp_idx[1:0]);
	wire [1:0] vp_idx_r_hi1  = rst_sync ? 2'd0 : ((st_we && st_idx == GHCI_S_VIEWPORT_IDX) ? st_wdata[1:0] : vp_idx[1:0]);
	always @(posedge clk) begin
		for (s_idx = 0; s_idx < 4; s_idx = s_idx + 1) begin
			r_vp_idx_w[s_idx]  <= vp_idx_nxt_lo;
			r_vp_idx_hi[s_idx] <= r_vp_idx_w[s_idx][3:2];
			r_vp_idx_r[s_idx][0] <= vp_idx_r_lo0;
			r_vp_idx_r[s_idx][1] <= vp_idx_r_lo0;
			r_vp_idx_r[s_idx][2] <= vp_idx_r_lo1;
			r_vp_idx_r[s_idx][3] <= vp_idx_r_lo1;
		end
		for (s_idx = 4; s_idx < 8; s_idx = s_idx + 1) begin
			r_vp_idx_w[s_idx]  <= vp_idx_nxt_hi;
			r_vp_idx_hi[s_idx] <= r_vp_idx_w[s_idx][3:2];
			r_vp_idx_r[s_idx][0] <= vp_idx_r_hi0;
			r_vp_idx_r[s_idx][1] <= vp_idx_r_hi0;
			r_vp_idx_r[s_idx][2] <= vp_idx_r_hi1;
			r_vp_idx_r[s_idx][3] <= vp_idx_r_hi1;
		end
		if (rst_sync) begin
			vp_idx  <= 4'd0;
			dc      <= 2'd0;
			discard <= 1'b0;
		end else if (st_we) begin
			if (st_idx == GHCI_S_VIEWPORT_IDX)
				vp_idx <= st_wdata[3:0];
			if (st_idx == GHCI_S_DEPTH_CLAMP)
				dc <= st_wdata[1:0];
			if (st_idx == GHCI_S_RAST_MODE)
				discard <= st_wdata[6];
		end
	end

	wire p_near = !dc[1] || !dc[0];
`ifdef MUT_FARCLIP
	localparam [6:0] PL_MUT = 7'b1111011;	/* the TB's mutation check: no far plane */
`elsif MUT_WCLIP
	localparam [6:0] PL_MUT = 7'b1111110;	/* no w plane */
`else
	localparam [6:0] PL_MUT = 7'b1111111;
`endif
	wire p_far = dc[1] && !dc[0];

	localparam [2:0] S_IDLE = 3'd0, S_READ = 3'd1, S_TRIV = 3'd2, S_LOAD = 3'd3,
		S_CMD = 3'd4, S_CWAIT = 3'd5, S_EMIT = 3'd6, S_OUT = 3'd7;
	(* max_fanout = 16 *) reg [2:0] st;
	reg [23:0] ent;
	(* max_fanout = 16 *) reg [2:0] fl;
	(* max_fanout = 16 *) reg [1:0] kind;	/* 0 point, 1 line, 2 triangle */
	reg last, raw;

	/* Vertex positions from PT (3 vertices x 128 bits); weights [223:128] are constant */
	(* extract_reset = "no" *) reg [127:0] vv_pos [0:2];
	wire [223:0] vv0 = {32'd0, 32'd0, ONE, vv_pos[0]};
	wire [223:0] vv1 = {32'd0, ONE, 32'd0, vv_pos[1]};
	wire [223:0] vv2 = {ONE, 32'd0, 32'd0, vv_pos[2]};

	(* max_fanout = 16 *) reg [3:0] rd_n;	/* PT words requested */
	(* shreg_extract = "no", max_fanout = 16 *) reg [2:0] r_rd_v;	/* PT read valid shift pipe (3-cycle latency) */
	(* shreg_extract = "no", max_fanout = 16 *) reg [3:0] r_rd_k1, r_rd_k2, r_rd_k3;	/* which word */
	wire rd_v3 = r_rd_v[2];
	wire [3:0] rd_k3 = r_rd_k3;
	assign pt_active = (st == S_READ) && (|r_rd_v || pt_rd);
	(* extract_reset = "no" *) reg [223:0] o0, o1, o2;	/* the output primitive */
	reg [29:0] r_out_hdr;
	reg ofl;	/* it is the primitive's last output (it carries the flags) */
	(* max_fanout = 16 *) reg [6:0] pl;	/* planes still to cut */
	reg first;
	(* max_fanout = 16 *) reg [3:0] np;	/* the polygon's vertex count */
	(* max_fanout = 16 *) reg [3:0] ti;	/* EMIT: the fan triangle (v0, v_ti, v_ti+1) */
	(* max_fanout = 16 *) reg [2:0] es;	/* EMIT: read step */
	integer k;

	wire [31:0] pt_rdata_b = pt_rdata;
	genvar g_v, g_w;
	generate
	for (g_v = 0; g_v < 3; g_v = g_v + 1) begin : g_vv_vtx
		for (g_w = 0; g_w < 4; g_w = g_w + 1) begin : g_vv_word
			localparam [3:0] WK = {g_v[1:0], g_w[1:0]};
			wire vvw_hit = (st == S_READ) && rd_v3 && (rd_k3 == WK);
			always @(posedge clk) begin
				if (rst_sync) begin
					vv_pos[g_v][32 * g_w +: 16]      <= 16'd0;
					vv_pos[g_v][32 * g_w + 16 +: 16] <= 16'd0;
				end else if (vvw_hit) begin
					vv_pos[g_v][32 * g_w +: 32]      <= pt_rdata_b;
				end
			end
		end
	end
	endgenerate

	wire [3:0] rd_lim = kind == 2'd0 ? 4'd4 : kind == 2'd1 ? 4'd8 : 4'd12;
	wire [3:0] rd_lim_m1 = kind == 2'd0 ? 4'd3 : kind == 2'd1 ? 4'd7 : 4'd11;
	/* rd_n + 1, ld_idx + 1, es + 1, ti + 1, ti + 2 */
	wire [3:0] rd_n1, ld1, ti1, ti2;
	wire [2:0] es1;
	wire [3:0] ld_idx;
	wire [4:0] cnt_carry_unused;
	am_add #(.W(4)) u_rd_n1 (.a(rd_n), .b(4'd0), .ci(1'b1), .s(rd_n1), .co(cnt_carry_unused[0]));
	am_add #(.W(4)) u_ld1 (.a(ld_idx), .b(4'd0), .ci(1'b1), .s(ld1), .co(cnt_carry_unused[1]));
	am_add #(.W(3)) u_es1 (.a(es), .b(3'd0), .ci(1'b1), .s(es1), .co(cnt_carry_unused[2]));
	am_add #(.W(4)) u_ti1 (.a(ti), .b(4'd0), .ci(1'b1), .s(ti1), .co(cnt_carry_unused[3]));
	am_add #(.W(4)) u_ti2 (.a(ti), .b(4'd2), .ci(1'b0), .s(ti2), .co(cnt_carry_unused[4]));
	wire [1:0] nv = kind == 2'd0 ? 2'd1 : kind == 2'd1 ? 2'd2 : 2'd3;

	/*
	 * Pipelined trivial accept & guard-band test (0 Pre-CARRY4 LUTs, 0 Post-CARRY4 LUTs):
	 *   - Viewport guard-band check:
	 *       |x_off| <= 6144 (31'h45C00000), |x_scale| <= 2048 (31'h45000000)
	 *       |y_off| <= 6144 (31'h45C00000), |y_scale| <= 2048 (31'h45000000)
	 *     Since any value <= 31'h45C00000 has exponent <= 8'h8B != 8'hFF, it cannot be NaN.
	 */
	wire [30:0] vp_sub_unused [0:3];
	wire bo_vp_xoff, bo_vp_xsc, bo_vp_yoff, bo_vp_ysc;
	am_sub #(.W(31)) u_vp_xoff (.a(31'h45C00000), .b(r_vp[94:64]),  .bi(1'b0), .d(vp_sub_unused[0]), .bo(bo_vp_xoff));
	am_sub #(.W(31)) u_vp_xsc  (.a(31'h45000000), .b(r_vp[30:0]),   .bi(1'b0), .d(vp_sub_unused[1]), .bo(bo_vp_xsc));
	am_sub #(.W(31)) u_vp_yoff (.a(31'h45C00000), .b(r_vp[126:96]), .bi(1'b0), .d(vp_sub_unused[2]), .bo(bo_vp_yoff));
	am_sub #(.W(31)) u_vp_ysc  (.a(31'h45000000), .b(r_vp[62:32]),  .bi(1'b0), .d(vp_sub_unused[3]), .bo(bo_vp_ysc));

	(* extract_reset = "no" *) reg r_bo_vp_xoff, r_bo_vp_xsc, r_bo_vp_yoff, r_bo_vp_ysc;
	(* extract_reset = "no" *) reg r_okx, r_oky;
	always @(posedge clk) begin
		r_bo_vp_xoff <= bo_vp_xoff;
		r_bo_vp_xsc  <= bo_vp_xsc;
		r_bo_vp_yoff <= bo_vp_yoff;
		r_bo_vp_ysc  <= bo_vp_ysc;
		r_okx        <= !r_bo_vp_xoff && !r_bo_vp_xsc;
		r_oky        <= !r_bo_vp_yoff && !r_bo_vp_ysc;
	end

	/* Per-vertex pipelined comparators for S_TRIV */
	wire [7:0] we_w [0:2];
	wire [2:0] we_co_unused;
	(* extract_reset = "no" *) reg [7:0] r_we [0:2];
	(* extract_reset = "no" *) reg [2:0] r_w_ge_253_lo, r_w_ge_253_hi;
	(* extract_reset = "no" *) reg [2:0] r_w_exp_ff, r_w_exp_nz, r_w_frac_nz;
	(* extract_reset = "no" *) reg [2:0] r_z_exp_ff, r_z_exp_nz, r_z_frac_nz;
	(* extract_reset = "no" *) reg [2:0] r_bo_w_eps, r_bo_w_z, r_bo_z_w;
	(* extract_reset = "no" *) reg [30:0] r_w4 [0:2];
	(* extract_reset = "no" *) reg [2:0] r_wi, r_zi;
	(* extract_reset = "no" *) reg [2:0] r_bo_w4_x, r_bo_w4_y;

	generate
	for (g_v = 0; g_v < 3; g_v = g_v + 1) begin : g_vtest
		wire [31:0] vx = vv_pos[g_v][31:0];
		wire [31:0] vy = vv_pos[g_v][63:32];
		wire [31:0] vz = vv_pos[g_v][95:64];
		wire [31:0] vw = vv_pos[g_v][127:96];

		am_add #(.W(8)) u_we (.a(vw[30:23]), .b(8'd2), .ci(1'b0), .s(we_w[g_v]), .co(we_co_unused[g_v]));

		wire [30:0] vt_sub_unused [0:4];
		wire bo_w_eps_w, bo_w_z_w, bo_z_w_w, bo_w4_x_w, bo_w4_y_w;
		am_sub #(.W(31)) u_w_eps (.a(vw[30:0]),    .b(EPS[30:0]), .bi(1'b0), .d(vt_sub_unused[0]), .bo(bo_w_eps_w));
		am_sub #(.W(31)) u_w_z   (.a(vw[30:0]),    .b(vz[30:0]),  .bi(1'b0), .d(vt_sub_unused[1]), .bo(bo_w_z_w));
		am_sub #(.W(31)) u_z_w   (.a(vz[30:0]),    .b(vw[30:0]),  .bi(1'b0), .d(vt_sub_unused[2]), .bo(bo_z_w_w));
		am_sub #(.W(31)) u_w4_x  (.a(r_w4[g_v]),   .b(vx[30:0]),  .bi(1'b0), .d(vt_sub_unused[3]), .bo(bo_w4_x_w));
		am_sub #(.W(31)) u_w4_y  (.a(r_w4[g_v]),   .b(vy[30:0]),  .bi(1'b0), .d(vt_sub_unused[4]), .bo(bo_w4_y_w));

		/* 2-LUT reductions for exponent/mantissa flags (0 CARRY4s) */
		(* keep = "true" *) wire w_fnz0 = |vw[5:0];
		(* keep = "true" *) wire w_fnz1 = |vw[11:6];
		(* keep = "true" *) wire w_fnz2 = |vw[17:12];
		(* keep = "true" *) wire w_fnz3 = |vw[22:18];
		(* keep = "true" *) wire z_fnz0 = |vz[5:0];
		(* keep = "true" *) wire z_fnz1 = |vz[11:6];
		(* keep = "true" *) wire z_fnz2 = |vz[17:12];
		(* keep = "true" *) wire z_fnz3 = |vz[22:18];
		(* keep = "true" *) wire w_ehi  = &vw[30:25];
		(* keep = "true" *) wire w_elo  = &vw[24:23];
		(* keep = "true" *) wire w_enz0 = |vw[30:27];
		(* keep = "true" *) wire w_enz1 = |vw[26:23];
		(* keep = "true" *) wire z_ehi  = &vz[30:27];
		(* keep = "true" *) wire z_elo  = &vz[26:23];
		(* keep = "true" *) wire z_enz0 = |vz[30:27];
		(* keep = "true" *) wire z_enz1 = |vz[26:23];

		(* keep = "true" *) wire w_nan_s1  = r_w_exp_ff[g_v] && r_w_frac_nz[g_v];
		(* keep = "true" *) wire z_nan_s1  = r_z_exp_ff[g_v] && r_z_frac_nz[g_v];
		(* keep = "true" *) wire zw_zero   = !r_z_exp_nz[g_v] && !r_z_frac_nz[g_v] && !r_w_exp_nz[g_v] && !r_w_frac_nz[g_v];
		(* keep = "true" *) wire cin_z_s1  = !z_nan_s1 && !(vz[31] && r_z_exp_nz[g_v]);
		(* keep = "true" *) wire fle_zw_m  = vz[31] ? (vw[31] ? !r_bo_z_w[g_v] : 1'b1) : (vw[31] ? zw_zero : !r_bo_w_z[g_v]);
		(* keep = "true" *) wire fle_zw_s1 = !z_nan_s1 && !w_nan_s1 && fle_zw_m;

		always @(posedge clk) begin
			/* Stage 0: direct from vv_pos and am_add/am_sub */
			r_we[g_v]        <= we_w[g_v];
			r_bo_w_eps[g_v]  <= bo_w_eps_w;
			r_bo_w_z[g_v]       <= bo_w_z_w;
			r_bo_z_w[g_v]       <= bo_z_w_w;
			r_w_ge_253_lo[g_v]  <= w_ehi && (vw[24] || vw[23]);
			r_w_ge_253_hi[g_v]  <= w_ehi && (vw[24] || vw[23]);
			r_w_exp_ff[g_v]     <= w_ehi && w_elo;
			r_w_exp_nz[g_v]     <= w_enz0 || w_enz1;
			r_w_frac_nz[g_v]    <= w_fnz0 || w_fnz1 || w_fnz2 || w_fnz3;
			r_z_exp_ff[g_v]     <= z_ehi && z_elo;
			r_z_exp_nz[g_v]     <= z_enz0 || z_enz1;
			r_z_frac_nz[g_v]    <= z_fnz0 || z_fnz1 || z_fnz2 || z_fnz3;

			/* Stage 1: w4, wi, zi */
			r_w4[g_v][15:0]     <= r_w_ge_253_lo[g_v] ? 16'h0000 : vw[15:0];
			r_w4[g_v][30:16]    <= r_w_ge_253_hi[g_v] ? 15'h7F80 : {r_we[g_v], vw[22:16]};
			r_wi[g_v]           <= !w_nan_s1 && !vw[31] && !r_bo_w_eps[g_v];
			r_zi[g_v]           <= (!p_near || cin_z_s1) && (!p_far || fle_zw_s1);

			/* Stage 2: direct from r_w4 - vx/vy am_sub */
			r_bo_w4_x[g_v]   <= bo_w4_x_w;
			r_bo_w4_y[g_v]   <= bo_w4_y_w;
		end
	end
	endgenerate

	wire [2:0] t0 = {r_wi[0] && r_okx && r_oky && !r_bo_w4_x[0] && !r_bo_w4_y[0], r_zi[0], r_wi[0]};
	wire [2:0] t1 = {r_wi[1] && r_okx && r_oky && !r_bo_w4_x[1] && !r_bo_w4_y[1], r_zi[1], r_wi[1]};
	wire [2:0] t2 = {r_wi[2] && r_okx && r_oky && !r_bo_w4_x[2] && !r_bo_w4_y[2], r_zi[2], r_wi[2]};
	wire [2:0] ta = t0 & (nv == 2'd1 ? 3'b111 : t1) & (nv == 2'd3 ? t2 : 3'b111);
	wire accept = &ta;
	wire guard = !ta[2];
	(* max_fanout = 16 *) reg [2:0] triv_step;
	reg [2:0] r_t0;
	reg r_accept, r_guard;

	/* The polygon (ld_data sliced into 14 x 16-bit slices for bounded fanout) */
	reg ld_we;
	reg [3:0] r_ld_idx;
	assign ld_idx = r_ld_idx;
	(* extract_reset = "no" *) reg [1:0] r_ld_sel_s [0:13];
	reg [13:0] r_ld_we_s;
	(* extract_reset = "no" *) reg [223:0] ld_data;
	reg cmd_valid;
	reg [2:0] cmd_plane;
	wire cmd_ready, cp_done;
	wire [3:0] n_out;
	reg [3:0] rd_idx;
	wire [223:0] rd_data;

	genvar g_s;
	generate
	for (g_s = 0; g_s < 14; g_s = g_s + 1) begin : g_ld_slice
		wire [15:0] ld_mux = (r_ld_sel_s[g_s] == 2'd0) ? vv0[16 * g_s +: 16] :
			((r_ld_sel_s[g_s] == 2'd1) ? vv1[16 * g_s +: 16] : vv2[16 * g_s +: 16]);
		always @(posedge clk) begin
			if (r_ld_we_s[g_s])
				ld_data[16 * g_s +: 16] <= ld_mux;
		end
	end
	endgenerate

	reg r_ld_line;
	always @(posedge clk)
		r_ld_line <= (kind == 2'd1);

	generate
	if (ENABLE_CPOLY != 0) begin : gen_cpoly
		atg_rx_cpoly cpoly (.clk(clk), .rst_n(rst_n), .vp(vp), .ld_we(ld_we), .ld_idx(ld_idx),
			.ld_data(ld_data), .ld_n({2'd0, nv}), .ld_line(r_ld_line),
			.cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_plane(cmd_plane),
			.cmd_first(first), .done(cp_done), .n_out(n_out), .rd_idx(rd_idx),
			.rd_data(rd_data));
	end else begin : gen_no_cpoly
		assign cmd_ready = 1'b1;
		assign cp_done = 1'b1;
		assign n_out = 4'd0;
		assign rd_data = 224'd0;
	end
	endgenerate

	/* the lowest plane still to cut */
	reg [2:0] pnext;
	always @(*) begin
		pnext = 3'd0;
		for (k = 6; k >= 0; k = k - 1)
			if (pl[k])
				pnext = k[2:0];
	end

	/*
	 * Sliced o0, o1, o2 output primitive registers (14 slices x 16 bits):
	 *   r_osel{0,1,2}_s: 0 = EMPTY, 1 = RAW, 2 = VV, 3 = RD (rd_data)
	 *   r_ovv{1,2}_s:    0 = (vv0, vv0, vv0), 1 = (vv0, vv1, vv1), 2 = (vv0, vv1, vv2)
	 */
	(* extract_reset = "no" *) reg [1:0] r_osel0_s [0:13];
	(* extract_reset = "no" *) reg [1:0] r_osel1_s [0:13];
	(* extract_reset = "no" *) reg [1:0] r_osel2_s [0:13];
	(* extract_reset = "no" *) reg [1:0] r_ovv1_s [0:13];
	(* extract_reset = "no" *) reg [1:0] r_ovv2_s [0:13];
	reg [13:0] r_owe0_s, r_owe1_s, r_owe2_s;

	wire [223:0] raw_o0 = {64'd0, ONE, ONE, rw[2], rw[1], rw[0]};
	wire [223:0] raw_o1 = {32'd0, ONE, 32'd0, ONE, rw[5], rw[4], rw[3]};
	wire [223:0] raw_o2 = {ONE, 64'd0, ONE, rw[8], rw[7], rw[6]};

	generate
	for (g_s = 0; g_s < 14; g_s = g_s + 1) begin : g_out_slice
		wire [15:0] vv_o0 = vv0[16 * g_s +: 16];
		(* keep = "true" *) wire [15:0] vv_o1 = (r_ovv1_s[g_s] == 2'd0) ? vv0[16 * g_s +: 16] : vv1[16 * g_s +: 16];
		(* keep = "true" *) wire [15:0] vv_o2 = (r_ovv2_s[g_s] == 2'd0) ? vv0[16 * g_s +: 16] :
			((r_ovv2_s[g_s] == 2'd1) ? vv1[16 * g_s +: 16] : vv2[16 * g_s +: 16]);

		(* keep = "true" *) wire [15:0] mux_o0 = (r_osel0_s[g_s] == 2'd0) ? EMPTY[16 * g_s +: 16] :
			((r_osel0_s[g_s] == 2'd1) ? raw_o0[16 * g_s +: 16] :
			((r_osel0_s[g_s] == 2'd2) ? vv_o0 : rd_data[16 * g_s +: 16]));
		(* keep = "true" *) wire [15:0] mux_o1 = (r_osel1_s[g_s] == 2'd0) ? EMPTY[16 * g_s +: 16] :
			((r_osel1_s[g_s] == 2'd1) ? raw_o1[16 * g_s +: 16] :
			((r_osel1_s[g_s] == 2'd2) ? vv_o1 : rd_data[16 * g_s +: 16]));
		(* keep = "true" *) wire [15:0] mux_o2 = (r_osel2_s[g_s] == 2'd0) ? EMPTY[16 * g_s +: 16] :
			((r_osel2_s[g_s] == 2'd1) ? raw_o2[16 * g_s +: 16] :
			((r_osel2_s[g_s] == 2'd2) ? vv_o2 : rd_data[16 * g_s +: 16]));

		always @(posedge clk) begin
			if (r_owe0_s[g_s])
				o0[16 * g_s +: 16] <= mux_o0;
			if (r_owe1_s[g_s])
				o1[16 * g_s +: 16] <= mux_o1;
			if (r_owe2_s[g_s])
				o2[16 * g_s +: 16] <= mux_o2;
		end
	end
	endgenerate

	genvar g;
	generate
	for (g = 0; g < 4; g = g + 1) begin : g_pos
		assign cl_tri[32 * g +: 32] = o0[32 * g +: 32];
		assign cl_tri[128 + 32 * g +: 32] = o1[32 * g +: 32];
		assign cl_tri[256 + 32 * g +: 32] = o2[32 * g +: 32];
	end
	for (g = 0; g < 3; g = g + 1) begin : g_wt
		assign cl_tri[384 + 32 * g +: 32] = o0[128 + 32 * g +: 32];
		assign cl_tri[480 + 32 * g +: 32] = o1[128 + 32 * g +: 32];
		assign cl_tri[576 + 32 * g +: 32] = o2[128 + 32 * g +: 32];
	end
	endgenerate
	assign cl_tri[701:672] = r_out_hdr;

	/* PT reads: vertex rd_n / 4, word rd_n % 4, data the next cycle. */
	assign pt_rd = st == S_READ && rd_n < rd_lim && !pt_busy;
	assign pt_idx = rd_n[3:2] == 2'd0 ? ent[7:0] : rd_n[3:2] == 2'd1 ? ent[15:8] : ent[23:16];
	assign pt_word = {5'd0, rd_n[1:0]};
	assign prim_ready = (st == S_IDLE);
	assign busy = (st != S_IDLE);

	/* Pre-computed next control signals for ld_data and o0/o1/o2 slices */
	wire ld_trig_triv = (st == S_TRIV) && (triv_step == 3'd3);
	wire ld_trig_load = (st == S_LOAD) && !ld_we && !r_ld_we_s[0] && (ld1 < {2'd0, nv});
	wire ld_we_nxt = !rst_sync && (ld_trig_triv || ld_trig_load);
	wire [1:0] ld_sel_nxt = (st == S_TRIV) ? 2'd0 : ((r_ld_idx == 4'd0) ? 2'd1 : 2'd2);

	wire out_raw_trig   = (st == S_IDLE) && raw_kick;
	wire out_disc_trig  = (st == S_IDLE) && !raw_kick && prim_valid && discard;
	wire out_pt_ok      = (st == S_TRIV) && (triv_step == 3'd4) && (kind == 2'd0) && (r_t0[1:0] == 2'b11);
	wire out_pt_drop    = (st == S_TRIV) && (triv_step == 3'd4) && (kind == 2'd0) && (r_t0[1:0] != 2'b11);
	wire out_triv_acc   = (st == S_TRIV) && (triv_step == 3'd4) && (kind != 2'd0) && r_accept;
	wire out_poly_drop  = !ENABLE_CPOLY && (st == S_TRIV) && (triv_step == 3'd4) && (kind != 2'd0) && !r_accept;
	wire out_cwait_drop = (st == S_CWAIT) && cp_done && (n_out == 4'd0);
	wire out_all_trig   = out_raw_trig || out_disc_trig || out_pt_ok || out_pt_drop || out_triv_acc || out_poly_drop || out_cwait_drop;

	wire [1:0] osel_nxt_lo = (st == S_EMIT) ? 2'd3 :
		(out_raw_trig ? 2'd1 : ((out_pt_ok || out_triv_acc) ? 2'd2 : 2'd0));
	wire [1:0] osel_nxt_hi = (st == S_EMIT) ? 2'd3 :
		(out_raw_trig ? 2'd1 : ((out_pt_ok || out_triv_acc) ? 2'd2 : 2'd0));
	wire [1:0] ovv_nxt_lo  = out_pt_ok ? 2'd0 : ((kind == 2'd1) ? 2'd1 : 2'd2);
	wire [1:0] ovv_nxt_hi  = out_pt_ok ? 2'd0 : ((kind == 2'd1) ? 2'd1 : 2'd2);
	wire owe0_nxt = !rst_sync && (out_all_trig || (st == S_EMIT && es == 3'd1));
	wire owe1_nxt = !rst_sync && (out_all_trig || (st == S_EMIT && es == 3'd2));
	wire owe2_nxt = !rst_sync && (out_all_trig || (st == S_EMIT && es == 3'd3));

	always @(posedge clk) begin
		r_ld_we_s <= {14{ld_we_nxt}};
		r_owe0_s  <= {14{owe0_nxt}};
		r_owe1_s  <= {14{owe1_nxt}};
		r_owe2_s  <= {14{owe2_nxt}};
		for (s_idx = 0; s_idx < 7; s_idx = s_idx + 1) begin
			r_ld_sel_s[s_idx] <= ld_sel_nxt;
			r_osel0_s[s_idx]  <= osel_nxt_lo;
			r_osel1_s[s_idx]  <= osel_nxt_lo;
			r_osel2_s[s_idx]  <= osel_nxt_lo;
			r_ovv1_s[s_idx]   <= ovv_nxt_lo;
			r_ovv2_s[s_idx]   <= ovv_nxt_lo;
		end
		for (s_idx = 7; s_idx < 14; s_idx = s_idx + 1) begin
			r_ld_sel_s[s_idx] <= ld_sel_nxt;
			r_osel0_s[s_idx]  <= osel_nxt_hi;
			r_osel1_s[s_idx]  <= osel_nxt_hi;
			r_osel2_s[s_idx]  <= osel_nxt_hi;
			r_ovv1_s[s_idx]   <= ovv_nxt_hi;
			r_ovv2_s[s_idx]   <= ovv_nxt_hi;
		end
	end

	wire ent_we_lo = (st == S_IDLE) && (raw_kick || prim_valid);
	wire ent_we_hi = (st == S_IDLE) && (raw_kick || prim_valid);
	wire hdr_we_lo = (st == S_OUT)  && !(cl_valid && cl_ready);
	wire hdr_we_hi = (st == S_OUT)  && !(cl_valid && cl_ready);

	always @(posedge clk) begin
		if (ent_we_lo)
			ent[11:0]  <= raw_kick ? 12'd0 : prim_vtx[11:0];
		if (ent_we_hi)
			ent[23:12] <= raw_kick ? 12'd0 : prim_vtx[23:12];
		if (rst_sync) begin
			r_out_hdr <= 30'd0;
		end else begin
			if (hdr_we_lo)
				r_out_hdr[15:0]  <= ent[15:0];
			if (hdr_we_hi)
				r_out_hdr[29:16] <= {kind, raw, ofl ? fl : 3'd0, ent[23:16]};
		end
	end

	always @(posedge clk) begin
		r_rd_v  <= {r_rd_v[1:0], pt_rd};
		r_rd_k1 <= rd_n;
		r_rd_k2 <= r_rd_k1;
		r_rd_k3 <= r_rd_k2;
		ld_we <= 1'b0;
		if (rst_sync) begin
			r_rd_v  <= 3'b000;
			r_rd_k1 <= 4'd0;
			r_rd_k2 <= 4'd0;
			r_rd_k3 <= 4'd0;
			st <= S_IDLE;
			cl_valid <= 1'b0;
			cl_last <= 1'b0;
			cmd_valid <= 1'b0;
			triv_step <= 3'd0;
			r_t0 <= 3'd0;
			r_accept <= 1'b0;
			r_guard <= 1'b0;
			r_ld_idx <= 4'd0;
		end else case (st)
		S_IDLE:
			if (raw_kick) begin
				fl <= 3'd0;
				ofl <= 1'b1;
				last <= 1'b1;
				raw <= 1'b1;
				kind <= 2'd2;
				st <= S_OUT;
			end else if (prim_valid) begin
				fl <= prim_free;
				ofl <= 1'b1;
				last <= prim_last;
				raw <= 1'b0;
				kind <= prim_vtx[25:24] == 2'd3 ? 2'd2 : prim_vtx[25:24];
				rd_n <= 4'd0;
				if (discard) begin
					kind <= 2'd2;
					st <= S_OUT;
				end else
					st <= S_READ;
			end
		S_READ: begin
			if (pt_rd)
				rd_n <= rd_n1;
			if (rd_v3 && rd_k3 == rd_lim_m1) begin
				triv_step <= 3'd0;
				st <= S_TRIV;
			end
		end
		S_TRIV: begin
			if (triv_step != 3'd4) begin
				triv_step <= {triv_step[2] ^ (triv_step[1] & triv_step[0]),
				              triv_step[1] ^ triv_step[0],
				              ~triv_step[0]};
				if (triv_step == 3'd3) begin
					r_t0 <= t0;
					r_accept <= accept;
					r_guard <= guard;
				end
			end else begin
				triv_step <= 3'd0;
				if (kind == 2'd0) begin
					/* a point: planes 0-2 only */
					if (r_t0[1:0] != 2'b11)
						kind <= 2'd2;
					st <= S_OUT;
				end else if (r_accept) begin
					st <= S_OUT;
				end else if (!ENABLE_CPOLY) begin
					kind <= 2'd2;
					st <= S_OUT;
				end else begin
					pl <= {{4{r_guard}}, p_far, p_near, 1'b1} & PL_MUT;
					first <= 1'b1;
					ld_we <= 1'b1;
					r_ld_idx <= 4'd0;
					st <= S_LOAD;
				end
			end
		end
		S_LOAD:
			if (r_ld_we_s[0]) begin
				ld_we <= 1'b1;
				r_ld_idx <= ld1;
			end else if (!ld_we && !(ld1 < {2'd0, nv})) begin
				st <= S_CMD;
			end
		S_CMD:
			if (cmd_valid) begin
				if (cmd_ready) begin
					cmd_valid <= 1'b0;
					first <= 1'b0;
					pl[cmd_plane] <= 1'b0;
					st <= S_CWAIT;
				end
			end else if (pl == 7'd0) begin
				np <= n_out;
				ti <= 4'd1;
				es <= 3'd0;
				st <= S_EMIT;
			end else begin
				cmd_valid <= 1'b1;
				cmd_plane <= pnext;
			end
		S_CWAIT:
			if (cp_done) begin
				if (n_out == 4'd0) begin
					kind <= 2'd2;
					ofl <= 1'b1;
					st <= S_OUT;
				end else
					st <= S_CMD;
			end
		S_EMIT: begin
			/* read v0, v_ti, v_ti+1 (a line: v0, v1, v1); rd_data is the
			 * word of rd_idx two cycles later */
			es <= es1;
			rd_idx <= es == 3'd0 ? 4'd0 : es == 3'd1 || kind == 2'd1 ? ti : ti1;
			if (es == 3'd4) begin
				ofl <= kind == 2'd1 || ti2 == np;
				st <= S_OUT;
			end
		end
		default:	/* S_OUT */
			if (cl_valid && cl_ready) begin
				cl_valid <= 1'b0;
				if (ofl)
					st <= S_IDLE;
				else begin
					ti <= ti1;
					es <= 3'd0;
					st <= S_EMIT;
				end
			end else begin
				cl_valid <= 1'b1;
				cl_last <= last && ofl;
			end
		endcase
	end
endmodule

`default_nettype wire
