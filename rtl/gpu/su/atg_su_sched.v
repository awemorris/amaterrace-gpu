/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_sched: The SU's warp scheduler: warp slots and their PCs, slot
 * allocation for vertex warps (VF), fragment warps (RX) and compute
 * workgroups (DISPATCH), round-robin selection of a ready warp for fetch,
 * and the warp-info word for special operands.
 *
 * The behaviour, and where it differs from
 * the design: spec/gpu/su/atg_su_sched.md (§10 Status).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_sched #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter NSU = 1,	/* Number of SUs (compute workgroups are shared out: this SU takes wg_id % NSU == SU_INDEX) */
	parameter SU_INDEX = 0,	/* This SU's number */
	parameter FRAG_RESERVE = 1,	/* Slots kept for fragment warps (design §3.8; KC705 2) */
	parameter GTO = 1	/* Scheduling policy: 1 = Greedy-Then-Oldest, 0 = Round-Robin */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire cs_kick,
	/* Vertex warp allocation (VF, via atg_su ports vl_*) */
	input wire vl_req,
	output wire vl_gnt,
	output wire [WARP_W-1:0] vl_slot,
	input wire vl_go,
	input wire [31:0] vl_mask,
	/* Fragment warp allocation (RX, via atg_su ports fl_*) */
	input wire fl_req,
	output wire fl_gnt,
	output wire [WARP_W-1:0] fl_slot,
	input wire fl_go,
	input wire [31:0] fl_mask,
	input wire [63:0] fl_info,
	/* Fetch (to atg_su_fetch) */
	output wire f_valid,
	input wire f_ready,
	output wire [WARP_W-1:0] f_warp,
	output wire [15:0] f_pc,
	output wire [31:0] f_addr,
	/* Feedback (from atg_su_sb and atg_su_exec) */
	input wire fb_valid,
	input wire [WARP_W-1:0] fb_warp,
	input wire [1:0] fb_kind,
	input wire [NWARPS-1:0] wake,
	input wire [NWARPS-1:0] warp_ready,
	input wire wc_valid,
	input wire [WARP_W-1:0] wc_warp,
	input wire [1:0] wc_op,
	input wire [15:0] wc_pc,
	/* Warp information */
	input wire [WARP_W-1:0] q_warp,
	output wire [159:0] q_info,
	output wire init_valid,
	output wire [WARP_W-1:0] init_warp,
	output wire [31:0] init_mask,
	input wire pt_ok,
	input wire xr_valid,
	input wire [WARP_W-1:0] xr_warp,
	output wire busy
);
`include "atg_su_uop.vh"
`include "ghci_regs.vh"

	localparam G = 32 / NPHYS;
	localparam GAP_W = 3;
	localparam [2:0] S_FREE = 3'd0, S_ALLOC = 3'd1, S_READY = 3'd2, S_FETCH = 3'd3,
		S_WC = 3'd4, S_REPLAY = 3'd5, S_BAR = 3'd6, S_ENDED = 3'd7;
	localparam [1:0] K_VERT = 2'd0, K_FRAG = 2'd1, K_COMP = 2'd2;

	wire rst_p = !rst_n;

	/* STATE: program bases, WG_SIZE, the DISPATCH grid. */
	reg [31:0] vs_base, fs_base, cs_base;
	reg [7:0] wg_x, wg_y, wg_z;
	reg [15:0] grid_x, grid_y, grid_z;
	reg [15:0] grid_x_m1, grid_y_m1, grid_z_m1;
	wire [15:0] st_wdata_m1;
	wire wdata_m1_bo_unused;
	am_sub #(.W(16)) u_wdata_m1 (.a(st_wdata[15:0]), .b(16'd0), .bi(1'b1), .d(st_wdata_m1), .bo(wdata_m1_bo_unused));
	(* keep = "true" *) wire we_vs_lo = st_we && (st_idx == GHCI_S_VS_BASE);
	(* keep = "true" *) wire we_vs_hi = st_we && (st_idx == GHCI_S_VS_BASE);
	(* keep = "true" *) wire we_fs_lo = st_we && (st_idx == GHCI_S_FS_BASE);
	(* keep = "true" *) wire we_fs_hi = st_we && (st_idx == GHCI_S_FS_BASE);
	(* keep = "true" *) wire we_cs_lo = st_we && (st_idx == GHCI_S_CS_BASE);
	(* keep = "true" *) wire we_cs_hi = st_we && (st_idx == GHCI_S_CS_BASE);
	(* keep = "true" *) wire we_wgsz  = st_we && (st_idx == GHCI_S_WG_SIZE);
	(* keep = "true" *) wire we_gx    = st_we && (st_idx == GHCI_S_GRID_X);
	(* keep = "true" *) wire we_gx_m1 = st_we && (st_idx == GHCI_S_GRID_X);
	(* keep = "true" *) wire we_gy    = st_we && (st_idx == GHCI_S_GRID_Y);
	(* keep = "true" *) wire we_gy_m1 = st_we && (st_idx == GHCI_S_GRID_Y);
	(* keep = "true" *) wire we_gz    = st_we && (st_idx == GHCI_S_GRID_Z);
	(* keep = "true" *) wire we_gz_m1 = st_we && (st_idx == GHCI_S_GRID_Z);
	always @(posedge clk) begin
		if (rst_p) begin
			{vs_base, fs_base, cs_base} <= 96'd0;
			{wg_x, wg_y, wg_z} <= {8'd1, 8'd1, 8'd1};
			{grid_x, grid_y, grid_z} <= {16'd1, 16'd1, 16'd1};
			{grid_x_m1, grid_y_m1, grid_z_m1} <= {16'd0, 16'd0, 16'd0};
		end else begin
			if (we_vs_lo) vs_base[15:0]  <= st_wdata[15:0];
			if (we_vs_hi) vs_base[31:16] <= st_wdata[31:16];
			if (we_fs_lo) fs_base[15:0]  <= st_wdata[15:0];
			if (we_fs_hi) fs_base[31:16] <= st_wdata[31:16];
			if (we_cs_lo) cs_base[15:0]  <= st_wdata[15:0];
			if (we_cs_hi) cs_base[31:16] <= st_wdata[31:16];
			if (we_wgsz)  {wg_z, wg_y, wg_x} <= st_wdata[23:0];
			if (we_gx)    grid_x    <= st_wdata[15:0];
			if (we_gx_m1) grid_x_m1 <= st_wdata_m1;
			if (we_gy)    grid_y    <= st_wdata[15:0];
			if (we_gy_m1) grid_y_m1 <= st_wdata_m1;
			if (we_gz)    grid_z    <= st_wdata[15:0];
			if (we_gz_m1) grid_z_m1 <= st_wdata_m1;
		end
	end

	/* The warp-info word (ATG_WI_* of include/atg_su_uop.vh). */
	function [159:0] wi;
		input [47:0] wg, nwg;
		input [7:0] lid;
		input [1:0] kind;
		input front;
		input [15:0] seq;
		input [31:0] mask;
		wi = {mask, seq, 5'd0, front, kind, lid, nwg, wg};
	endfunction

	/* Per slot. */
	reg [NWARPS*3-1:0] st;
	reg [NWARPS-1:0] st_free_r, st_free_r_out;
	reg [NWARPS-1:0] st_rdy_r;
	reg [NWARPS-1:0] st_rof_r;
	reg [NWARPS*16-1:0] pc;
	reg [NWARPS*GAP_W-1:0] gap;
	reg [NWARPS-1:0] gap_z_r;
	wire [NWARPS*160-1:0] info;
	reg [NWARPS*4-1:0] tag;	/* workgroup of a compute warp (barriers) */

	/* Compute launch: the next workgroup id, its warps, and whose it is. */
	reg cs_act;
	reg [15:0] id_x, id_y, id_z;
	reg [7:0] rot;	/* linear id % NSU */
	reg [3:0] wg_tag;
	reg [3:0] wk;	/* next warp of the workgroup being launched */
	reg launching;
	/* Compute workgroup size pipelined over 5 cycles (DSP LAT=2 + fabric output reg) */
	reg [7:0] wg_z_r1, wg_z_r2;
	wire [15:0] lanes_xy;
	wire [23:0] lanes;
	(* dont_touch = "true" *) reg [23:0] lanes_r;
	(* dont_touch = "true" *) reg [4:0]  lanes_r_b;
	am_mul #(.AW(8), .BW(8), .LAT(2)) u_lxy (.clk(clk), .en(1'b1), .a(wg_x), .b(wg_y), .p(lanes_xy));
	am_mul #(.AW(16), .BW(8), .LAT(2)) u_lanes (.clk(clk), .en(1'b1), .a(lanes_xy), .b(wg_z_r2), .p(lanes));

	/* Pure-LUT ceil(lanes_r / 32) clamped to NWARPS (0 CARRY4s, <= 3 LUTs) */
	wire [3:0] q_lanes = lanes_r[8:5];
	wire       rem_nz  = |lanes_r[4:0];
	wire       hi_nz   = |lanes_r[23:9];
	wire [3:0] q_p1    = {q_lanes[3] ^ (&q_lanes[2:0]), q_lanes[2] ^ (&q_lanes[1:0]), q_lanes[1] ^ q_lanes[0], ~q_lanes[0]};
	wire [3:0] nw_cand = rem_nz ? q_p1 : q_lanes;
	wire       nw_ovf  = hi_nz || (rem_nz && (&q_lanes)) || ({28'd0, nw_cand} > NWARPS);
	reg [3:0] nw;
	always @(posedge clk) begin
		if (rst_p) begin
			wg_z_r1   <= 8'd1;
			wg_z_r2   <= 8'd1;
			lanes_r   <= 24'd1;
			lanes_r_b <= 5'd1;
			nw        <= 4'd1;
		end else begin
			wg_z_r1   <= wg_z;
			wg_z_r2   <= wg_z_r1;
			lanes_r   <= lanes;
			lanes_r_b <= lanes[4:0];
			nw        <= nw_ovf ? NWARPS[3:0] : nw_cand;
		end
	end
	wire mine_wg = {24'd0, rot} == SU_INDEX;
	wire [15:0] id_x1, id_y1, id_z1;	/* the ids + 1 */
	wire ix_co_unused, iy_co_unused, iz_co_unused;
	am_add #(.W(16)) u_idx1 (.a(id_x), .b(16'd0), .ci(1'b1), .s(id_x1), .co(ix_co_unused));
	am_add #(.W(16)) u_idy1 (.a(id_y), .b(16'd0), .ci(1'b1), .s(id_y1), .co(iy_co_unused));
	am_add #(.W(16)) u_idz1 (.a(id_z), .b(16'd0), .ci(1'b1), .s(id_z1), .co(iz_co_unused));
	wire id_x_last_raw = (id_x == grid_x_m1);
	wire id_x_last, id_x_last_y, id_x_last_z;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_idxl  (.I0(id_x_last_raw), .O(id_x_last));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_idxly (.I0(id_x_last_raw), .O(id_x_last_y));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_idxlz (.I0(id_x_last_raw), .O(id_x_last_z));
`else
	assign id_x_last   = id_x_last_raw;
	assign id_x_last_y = id_x_last_raw;
	assign id_x_last_z = id_x_last_raw;
`endif
	(* keep = "true" *) wire id_y_last = (id_y == grid_y_m1);
	(* keep = "true" *) wire id_z_last = (id_z == grid_z_m1);
	wire last_id = id_x_last && id_y_last && id_z_last;

	/* Free slots directly from registered 1-bit flags st_free_r (0 LUTs!). */
	wire [NWARPS-1:0] slot_free = st_free_r_out;
	wire any_free = |slot_free;
	wire [WARP_W-1:0] free_slot;
	wire [4:0] n_free;
	wire n_free_ge_nw;
	wire n_free_gt_frag;
	generate
		if (NWARPS == 4) begin : g_nfree4
			assign free_slot = slot_free[0] ? 2'd0 : slot_free[1] ? 2'd1 : slot_free[2] ? 2'd2 : 2'd3;
			assign n_free[0] = ^slot_free;
			assign n_free[1] = (slot_free[0] & slot_free[1]) ^ (slot_free[2] & slot_free[3]) ^
			                   ((slot_free[0] ^ slot_free[1]) & (slot_free[2] ^ slot_free[3]));
			assign n_free[2] = &slot_free;
			assign n_free[4:3] = 2'b00;
			(* keep = "true" *) wire [2:0] nf3 = n_free[2:0];
			assign n_free_ge_nw   = (nf3 >= nw[2:0]);
			assign n_free_gt_frag = ({27'd0, n_free} > FRAG_RESERVE);
		end else begin : g_nfree_gen
			reg [WARP_W-1:0] fs_r;
			reg [4:0] nf_r;
			integer fi;
			always @(*) begin
				fs_r = {WARP_W{1'b0}};
				nf_r = 5'd0;
				for (fi = NWARPS - 1; fi >= 0; fi = fi - 1)
					if (slot_free[fi]) begin
						fs_r = fi[WARP_W-1:0];
						nf_r = {nf_r[4:1] ^ {nf_r[3] & (&nf_r[2:0]), nf_r[2] & (&nf_r[1:0]), nf_r[1] & nf_r[0], nf_r[0]}, ~nf_r[0]};
					end
			end
			assign free_slot = fs_r;
			assign n_free = nf_r;
			assign n_free_ge_nw   = ({1'b0, n_free} >= {2'b00, nw});
			assign n_free_gt_frag = ({27'd0, n_free} > FRAG_RESERVE);
		end
	endgenerate

	/* Grants (one outstanding per source); compute launches hold them off (<= 3 LUTs from FFs). */
	reg vl_wait, fl_wait;
	reg vl_gnt_r, fl_gnt_r;
	reg [WARP_W-1:0] vl_s, fl_s;
	(* keep = "true" *) wire cs_try  = cs_act && !launching && mine_wg && n_free_ge_nw;
	(* keep = "true" *) wire cs_skip = cs_act && !launching && !mine_wg;
	wire fl_req_can = fl_req && !fl_wait && any_free;
	wire vl_req_can = vl_req && !vl_wait && pt_ok && n_free_gt_frag;
	wire fl_g = fl_req_can && !launching && !cs_try;
	wire vl_g = vl_req_can && !fl_req_can && !launching && !cs_try;
	assign fl_gnt = fl_gnt_r;
	assign vl_gnt = vl_gnt_r;
	assign fl_slot = fl_s;
	assign vl_slot = vl_s;

	/* Initial EXEC: vertex/fragment go, else the next compute warp (0 CARRY4s, fanout <= 16). */
	reg [31:0] lmask;	/* (1 << lanes_r[4:0]) - 1 */
	integer li;
	always @(*) begin
		for (li = 0; li < 16; li = li + 1)
			lmask[li] = li < {27'd0, lanes_r[4:0]};
		for (li = 16; li < 32; li = li + 1)
			lmask[li] = li < {27'd0, lanes_r_b};
	end
	(* keep = "true" *) wire wl_ge32_lo = hi_nz || (q_lanes > wk);
	(* keep = "true" *) wire wl_ge32_hi = hi_nz || (q_lanes > wk);
	(* keep = "true" *) wire [15:0] cmask_lo = wl_ge32_lo ? 16'hFFFF : lmask[15:0];
	(* keep = "true" *) wire [15:0] cmask_hi = wl_ge32_hi ? 16'hFFFF : lmask[31:16];
	wire [31:0] cmask = {cmask_hi, cmask_lo};
	(* keep = "true" *) wire cs_launch = launching && !vl_go && !fl_go && any_free;
	assign init_valid = vl_go || fl_go || cs_launch;
	assign init_warp = vl_go ? vl_s : fl_go ? fl_s : free_slot;
	(* keep = "true" *) wire vl_go_lo = vl_go, vl_go_hi = vl_go;
	(* keep = "true" *) wire fl_go_lo = fl_go, fl_go_hi = fl_go;
	assign init_mask = {
		vl_go_hi ? vl_mask[31:16] : (fl_go_hi ? fl_mask[31:16] : cmask_hi),
		vl_go_lo ? vl_mask[15:0]  : (fl_go_lo ? fl_mask[15:0]  : cmask_lo)
	};

	/* Candidates: slots that are READY, out of gap, and warp_ready from scoreboard (1 LUT3 per warp!) */
	wire [NWARPS-1:0] slot_rdy_nogap = st_rdy_r & gap_z_r;
	(* keep = "true" *) wire [NWARPS-1:0] cand = st_rdy_r & gap_z_r & warp_ready;
	genvar gc;

	/* Registered pairwise relative ages for GTO Oldest policy (0 CARRY4s, 0 Pre-LUTs!) */
	reg cmp01_r, cmp02_r, cmp03_r, cmp12_r, cmp13_r, cmp23_r;
	always @(posedge clk) begin
		if (rst_p) begin
			{cmp01_r, cmp02_r, cmp03_r, cmp12_r, cmp13_r, cmp23_r} <= 6'd0;
		end else begin
			if (!cand[1])      cmp01_r <= 1'b0;
			else if (!cand[0]) cmp01_r <= 1'b1;
			if (!cand[2])      cmp02_r <= 1'b0;
			else if (!cand[0]) cmp02_r <= 1'b1;
			if (!cand[3])      cmp03_r <= 1'b0;
			else if (!cand[0]) cmp03_r <= 1'b1;
			if (!cand[2])      cmp12_r <= 1'b0;
			else if (!cand[1]) cmp12_r <= 1'b1;
			if (!cand[3])      cmp13_r <= 1'b0;
			else if (!cand[1]) cmp13_r <= 1'b1;
			if (!cand[3])      cmp23_r <= 1'b0;
			else if (!cand[2]) cmp23_r <= 1'b1;
		end
	end

	/* Selection: GTO (Greedy-Then-Oldest, <= 3 LUTs from FFs) or Round-Robin */
	reg [WARP_W-1:0] rr;
	reg [WARP_W-1:0] last_warp;
	reg active_valid;
	reg hold_v;
	reg [WARP_W-1:0] hold_w;

	wire [NWARPS-1:0] slot_rdy_or_fetch = st_rof_r;
	wire active_st_ok = slot_rdy_or_fetch[last_warp];
	wire [WARP_W-1:0] fixed_w = hold_v ? hold_w : last_warp;

	(* keep = "true" *) wire active_live = active_valid && active_st_ok && warp_ready[last_warp];
	(* keep = "true" *) wire use_fixed   = hold_v || active_live;
	wire w0_ok03 = cand[0] && !(cand[3] && cmp03_r);
	wire w0_ok12 = !(cand[1] && cmp01_r) && !(cand[2] && cmp02_r);
	wire w1_ok13 = cand[1] && !(cand[3] && cmp13_r);
	wire w1_ok02 = !(cand[0] && !cmp01_r) && !(cand[2] && cmp12_r);
	wire w2_ok23 = cand[2] && !(cand[3] && cmp23_r);
	wire w2_ok01 = !(cand[0] && !cmp02_r) && !(cand[1] && !cmp12_r);

	(* keep = "true" *) wire w0_win = w0_ok03 && w0_ok12;
	(* keep = "true" *) wire w1_win = w1_ok13 && w1_ok02;
	(* keep = "true" *) wire w2_win = w2_ok23 && w2_ok01;

	wire [WARP_W-1:0] fsel;
	wire fsel_v;
	generate
		if (GTO != 0 && NWARPS == 4) begin : g_sel_gto4
			assign fsel[1] = use_fixed ? fixed_w[1] : (!w0_win && !w1_win);
			assign fsel[0] = use_fixed ? fixed_w[0] : (!w0_win && !w2_win);
			assign fsel_v  = hold_v || (active_live ? cand[last_warp] : (|cand));
		end else begin : g_sel_rr
			reg [WARP_W-1:0] sel_rr;
			reg sel_v_rr;
			integer k, c, r;
			always @(*) begin
				sel_v_rr = 1'b0;
				sel_rr = {WARP_W{1'b0}};
				for (r = 0; r < NWARPS; r = r + 1)
					if (rr == r[WARP_W-1:0])
						for (k = NWARPS - 1; k >= 0; k = k - 1) begin
							c = (r + k) % NWARPS;
							if (cand[c]) begin
								sel_v_rr = 1'b1;
								sel_rr = c[WARP_W-1:0];
							end
						end
			end
			assign fsel   = hold_v ? hold_w : sel_rr;
			assign fsel_v = hold_v || sel_v_rr;
		end
	endgenerate
	wire [159:0] q_info_out;
	genvar gqi;
	generate
		for (gqi = 0; gqi < 10; gqi = gqi + 1) begin : g_qinfo_sl
			wire [WARP_W-1:0] q_warp_sl;
			genvar gqb;
			for (gqb = 0; gqb < WARP_W; gqb = gqb + 1) begin : g_qw_buf
`ifdef SYNTH_KINTEX7
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_qw (.I0(q_warp[gqb]), .O(q_warp_sl[gqb]));
`else
				assign q_warp_sl[gqb] = q_warp[gqb];
`endif
			end
			reg [15:0] q_i_sl;
			integer y;
			always @(*) begin
				q_i_sl = 16'd0;
				for (y = 0; y < NWARPS; y = y + 1) begin
					if (q_warp_sl == y[WARP_W-1:0])
						q_i_sl = info[y*160 + gqi*16 +: 16];
				end
			end
			assign q_info_out[gqi*16 +: 16] = q_i_sl;
		end
	endgenerate
	assign q_info = q_info_out;

	/* Precompute fetch address per warp independently from selection tournament */
	wire [NWARPS-1:0] w_fa_co_unused;
	wire [NWARPS*32-1:0] w_f_addr;
	genvar g_fa;
	generate
		for (g_fa = 0; g_fa < NWARPS; g_fa = g_fa + 1) begin : g_faddr
			wire [1:0] w_sk_raw = info[g_fa*160 + ATG_WI_KIND +: 2];
			wire [1:0] w_sk_b0, w_sk_b1, w_sk_b2, w_sk_b3;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fadb0_0 (.I0(w_sk_raw[0]), .O(w_sk_b0[0]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fadb0_1 (.I0(w_sk_raw[1]), .O(w_sk_b0[1]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fadb1_0 (.I0(w_sk_raw[0]), .O(w_sk_b1[0]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fadb1_1 (.I0(w_sk_raw[1]), .O(w_sk_b1[1]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fadb2_0 (.I0(w_sk_raw[0]), .O(w_sk_b2[0]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fadb2_1 (.I0(w_sk_raw[1]), .O(w_sk_b2[1]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fadb3_0 (.I0(w_sk_raw[0]), .O(w_sk_b3[0]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fadb3_1 (.I0(w_sk_raw[1]), .O(w_sk_b3[1]));
`else
			assign w_sk_b0 = w_sk_raw;
			assign w_sk_b1 = w_sk_raw;
			assign w_sk_b2 = w_sk_raw;
			assign w_sk_b3 = w_sk_raw;
`endif
			wire [31:0] w_base = {
				w_sk_b3 == K_VERT ? vs_base[31:24] : w_sk_b3 == K_FRAG ? fs_base[31:24] : cs_base[31:24],
				w_sk_b2 == K_VERT ? vs_base[23:16] : w_sk_b2 == K_FRAG ? fs_base[23:16] : cs_base[23:16],
				w_sk_b1 == K_VERT ? vs_base[15:8]  : w_sk_b1 == K_FRAG ? fs_base[15:8]  : cs_base[15:8],
				w_sk_b0 == K_VERT ? vs_base[7:0]   : w_sk_b0 == K_FRAG ? fs_base[7:0]   : cs_base[7:0]
			};
			am_add #(.W(32)) u_fa_w (
				.a(w_base),
				.b({13'd0, pc[g_fa*16 +: 16], 3'd0}),
				.ci(1'b0),
				.s(w_f_addr[g_fa*32 +: 32]),
				.co(w_fa_co_unused[g_fa])
			);
		end
	endgenerate

	wire [WARP_W-1:0] fsel_out, fsel_pc, fsel_fa_lo, fsel_fa_hi, fsel_st;
	wire fsel_v_out, fsel_v_st;
`ifdef SYNTH_KINTEX7
	genvar g_fsb;
	for (g_fsb = 0; g_fsb < WARP_W; g_fsb = g_fsb + 1) begin : g_fsel_buf
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fso (.I0(fsel[g_fsb]), .O(fsel_out[g_fsb]));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fsp (.I0(fsel[g_fsb]), .O(fsel_pc[g_fsb]));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fsl (.I0(fsel[g_fsb]), .O(fsel_fa_lo[g_fsb]));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fsh (.I0(fsel[g_fsb]), .O(fsel_fa_hi[g_fsb]));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fss (.I0(fsel[g_fsb]), .O(fsel_st[g_fsb]));
	end
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fsv_o (.I0(fsel_v), .O(fsel_v_out));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fsv_s (.I0(fsel_v), .O(fsel_v_st));
`else
	assign fsel_out   = fsel;
	assign fsel_pc    = fsel;
	assign fsel_fa_lo = fsel;
	assign fsel_fa_hi = fsel;
	assign fsel_st    = fsel;
	assign fsel_v_out = fsel_v;
	assign fsel_v_st  = fsel_v;
`endif

	assign f_valid = fsel_v_out;
	assign f_warp = fsel_out;
	assign f_pc = pc[(fsel_pc)*16 +: 16];
	assign f_addr = {w_f_addr[{fsel_fa_hi, 5'd16} +: 16], w_f_addr[{fsel_fa_lo, 5'd0} +: 16]};

	/* Per slot: the gap and pc counted down / up; rr, rot, wk and the tag + 1. */
	/* verilator lint_off WIDTHTRUNC */
	localparam [GAP_W-1:0] GAP_INIT = (G > 0) ? (G - 1) : 0;
	localparam [31:0] NSU_M1 = (NSU > 0) ? (NSU - 1) : 0;
	/* verilator lint_on WIDTHTRUNC */
	wire [NWARPS*GAP_W-1:0] gap_m1;
	wire [NWARPS*16-1:0] pc_p1;
	genvar gw;
	generate
		for (gw = 0; gw < NWARPS; gw = gw + 1) begin : g_w
			wire p_co_unused;
			wire [2:0] g_cur = gap[gw*GAP_W +: GAP_W];
			assign gap_m1[gw*GAP_W +: GAP_W] = {
				g_cur[2] ^ (~|g_cur[1:0]),
				g_cur[1] ^ (~g_cur[0]),
				~g_cur[0]
			};
			am_add #(.W(16)) u_pc (.a(pc[gw*16 +: 16]), .b(16'd0), .ci(1'b1), .s(pc_p1[gw*16 +: 16]),
				.co(p_co_unused));
		end
	endgenerate
	wire [WARP_W-1:0] rr_next;
	generate
		if (WARP_W == 2) begin : g_rr2
			assign rr_next = {fsel[1] ^ fsel[0], ~fsel[0]};
		end else begin : g_rr_gen
			wire rr_co_unused;
			am_add #(.W(WARP_W)) u_rr (.a(fsel), .b({WARP_W{1'b0}}), .ci(1'b1), .s(rr_next), .co(rr_co_unused));
		end
	endgenerate
	wire [8:0] rot1;
	wire rot_co_unused;
	am_add #(.W(9)) u_rot (.a({1'b0, rot}), .b(9'd0), .ci(1'b1), .s(rot1), .co(rot_co_unused));
	(* keep = "true" *) wire rot_last = ({24'd0, rot} == NSU_M1);
	wire [3:0] wk1  = {wk[3] ^ (&wk[2:0]), wk[2] ^ (&wk[1:0]), wk[1] ^ wk[0], ~wk[0]};
	wire [3:0] tag1 = {wg_tag[3] ^ (&wg_tag[2:0]), wg_tag[2] ^ (&wg_tag[1:0]), wg_tag[1] ^ wg_tag[0], ~wg_tag[0]};

	/* Barrier: every warp of the workgroup is parked (level-pinned <= 3 LUTs). */
	(* keep = "true" *) wire [NWARPS-1:0] w_bar_blk;
	generate
		for (gc = 0; gc < NWARPS; gc = gc + 1) begin : g_bar_blk
			assign w_bar_blk[gc] = (info[gc*160 + ATG_WI_KIND +: 2] == K_COMP) &&
				!st_free_r[gc] && (st[gc*3 +: 3] != S_BAR) && (st[gc*3 +: 3] != S_ENDED);
		end
	endgenerate
	reg [NWARPS-1:0] bar_go;
	integer a, b;
	always @(*) begin
		for (a = 0; a < NWARPS; a = a + 1) begin
			bar_go[a] = st[(a)*3 +: 3] == S_BAR;
			for (b = 0; b < NWARPS; b = b + 1)
				if (b != a && (tag[(b)*4 +: 4] == tag[(a)*4 +: 4]) && w_bar_blk[b])
					bar_go[a] = 1'b0;
		end
	end

	assign busy = cs_act || launching || (!(&slot_free));

	wire [159:0] wi_vl = wi(48'd0, 48'd0, 8'd0, K_VERT, 1'b0, 16'd0, vl_mask);
	wire [159:0] wi_fl = wi(48'd0, 48'd0, 8'd0, K_FRAG, fl_info[48], fl_info[47:32], fl_info[31:0]);
	wire [159:0] wi_cs = wi({id_z, id_y, id_x}, {grid_z, grid_y, grid_x}, {wk[2:0], 5'd0}, K_COMP, 1'b0, 16'd0, cmask);
	genvar gwi, gws;
	generate
	for (gwi = 0; gwi < NWARPS; gwi = gwi + 1) begin : g_info_w
		wire [9:0] vl_we_g;
		wire [9:0] fl_we_g;
		wire [9:0] cs_we_g;
		genvar gwe;
		for (gwe = 0; gwe < 10; gwe = gwe + 1) begin : g_we_buf
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_vl (.I0(vl_go && (vl_s == gwi[WARP_W-1:0])), .O(vl_we_g[gwe]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fl (.I0(fl_go && (fl_s == gwi[WARP_W-1:0])), .O(fl_we_g[gwe]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_cs (.I0(cs_launch && (free_slot == gwi[WARP_W-1:0])), .O(cs_we_g[gwe]));
`else
			assign vl_we_g[gwe] = vl_go && (vl_s == gwi[WARP_W-1:0]);
			assign fl_we_g[gwe] = fl_go && (fl_s == gwi[WARP_W-1:0]);
			assign cs_we_g[gwe] = cs_launch && (free_slot == gwi[WARP_W-1:0]);
`endif
		end
		for (gws = 0; gws < 20; gws = gws + 1) begin : g_info_sl
			wire vl_we_s = vl_we_g[gws / 2];
			wire fl_we_s = fl_we_g[gws / 2];
			wire cs_we_s = cs_we_g[gws / 2];
			(* shreg_extract = "no" *) reg [7:0] info_sl_r;
			always @(posedge clk) begin
				if (rst_p)
					info_sl_r <= 8'd0;
				else if (cs_we_s)
					info_sl_r <= wi_cs[gws*8 +: 8];
				else if (fl_we_s)
					info_sl_r <= wi_fl[gws*8 +: 8];
				else if (vl_we_s)
					info_sl_r <= wi_vl[gws*8 +: 8];
			end
			assign info[gwi*160 + gws*8 +: 8] = info_sl_r;
		end
	end
	endgenerate

	/* Level-pinned state transitions per warp (strictly <= 4 LUTs on all paths) */
	(* keep = "true" *) wire vf_any_req = !launching && (fl_req_can || vl_req_can);
	(* keep = "true" *) wire [NWARPS-1:0] s_rdy_free;
	(* keep = "true" *) wire [NWARPS-1:0] s_alloc_free;
	(* keep = "true" *) wire [NWARPS*3-1:0] nxt_st_nonfree;
	generate
		for (gc = 0; gc < NWARPS; gc = gc + 1) begin : g_nxt_st
			assign s_rdy_free[gc] = (cs_launch && (free_slot == gc[WARP_W-1:0])) ||
				(vl_go && (vl_s == gc[WARP_W-1:0])) || (fl_go && (fl_s == gc[WARP_W-1:0]));
			assign s_alloc_free[gc] = !s_rdy_free[gc] && vf_any_req && !cs_try && (free_slot == gc[WARP_W-1:0]);

			reg [2:0] nf_st;
			always @(*) begin
				nf_st = st[gc*3 +: 3];
				case (st[gc*3 +: 3])
				S_ALLOC:
					if ((vl_go && vl_s == gc[WARP_W-1:0]) || (fl_go && fl_s == gc[WARP_W-1:0]))
						nf_st = S_READY;
				S_READY:
					if (fsel_v_st && f_ready && (fsel_st == gc[WARP_W-1:0]))
						nf_st = S_FETCH;
				S_FETCH:
					if (fb_valid && fb_warp == gc[WARP_W-1:0]) begin
						if (fb_kind == 2'd0)
							nf_st = S_READY;
						else if (fb_kind == 2'd1)
							nf_st = S_WC;
						else
							nf_st = wake[gc] ? S_READY : S_REPLAY;
					end
				S_REPLAY:
					if (wake[gc])
						nf_st = S_READY;
				S_WC:
					if (wc_valid && wc_warp == gc[WARP_W-1:0])
						nf_st = wc_op == 2'd1 ? S_ENDED : wc_op == 2'd2 ? S_BAR : S_READY;
				S_BAR:
					if (bar_go[gc])
						nf_st = S_READY;
				S_ENDED:
					if (xr_valid && xr_warp == gc[WARP_W-1:0])
						nf_st = S_FREE;
				default: ;
				endcase
			end
			assign nxt_st_nonfree[gc*3 +: 3] = nf_st;
		end
	endgenerate

	wire cs_adv_id_raw = cs_skip || (cs_launch && (wk1 == nw));
	wire cs_adv_id_x;
	wire cs_adv_id_y;
	wire cs_adv_id_z;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_adv_x (.I0(cs_adv_id_raw), .O(cs_adv_id_x));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_adv_y (.I0(cs_adv_id_raw), .O(cs_adv_id_y));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_adv_z (.I0(cs_adv_id_raw), .O(cs_adv_id_z));
`else
	assign cs_adv_id_x = cs_adv_id_raw;
	assign cs_adv_id_y = cs_adv_id_raw;
	assign cs_adv_id_z = cs_adv_id_raw;
`endif

	integer w;
	reg [2:0] nxt_st_w;
	always @(posedge clk) begin
		if (rst_p) begin
			st <= {NWARPS{S_FREE}};
			st_free_r     <= {NWARPS{1'b1}};
			st_free_r_out <= {NWARPS{1'b1}};
			st_rdy_r  <= {NWARPS{1'b0}};
			st_rof_r  <= {NWARPS{1'b0}};
			gap <= {(NWARPS*GAP_W){1'b0}};
			gap_z_r <= {NWARPS{1'b1}};
			tag <= {(NWARPS*4){1'b0}};
			{rr, hold_v, hold_w} <= {(2*WARP_W+1){1'b0}};
			last_warp <= {WARP_W{1'b0}};
			active_valid <= 1'b0;
			{vl_wait, fl_wait, vl_s, fl_s} <= {(2*WARP_W+2){1'b0}};
			{vl_gnt_r, fl_gnt_r} <= 2'b00;
			{cs_act, launching} <= 2'b00;
			{id_x, id_y, id_z} <= 48'd0;
			rot <= 8'd0;
			wg_tag <= 4'd0;
			wk <= 4'd0;
		end else begin
			for (w = 0; w < NWARPS; w = w + 1) begin
				if (fsel_v_st && f_ready && (fsel_st == w[WARP_W-1:0])) begin
					gap[w*GAP_W +: GAP_W] <= GAP_INIT;
					gap_z_r[w] <= (GAP_INIT == {GAP_W{1'b0}});
				end else if (!gap_z_r[w]) begin
					gap[(w)*GAP_W +: GAP_W] <= gap_m1[(w)*GAP_W +: GAP_W];
					gap_z_r[w] <= (gap[(w)*GAP_W +: GAP_W] == 3'd1);
				end

				nxt_st_w = st_free_r[w] ? {1'b0, s_rdy_free[w], s_alloc_free[w]} : nxt_st_nonfree[w*3 +: 3];
				st[(w)*3 +: 3] <= nxt_st_w;
				st_free_r[w]     <= (nxt_st_w == S_FREE);
				st_free_r_out[w] <= (nxt_st_w == S_FREE);
				st_rdy_r[w]    <= (nxt_st_w == S_READY);
				st_rof_r[w]    <= (nxt_st_w == S_READY) || (nxt_st_w == S_FETCH);

				if (st_free_r[w])
					tag[(w)*4 +: 4] <= wg_tag;
			end
			hold_v <= fsel_v_st && !f_ready;
			hold_w <= fsel_st;
			if (fsel_v_st && f_ready) begin
				rr <= rr_next;
				last_warp <= fsel_st;
				active_valid <= 1'b1;
			end
			/* Vertex and fragment slots. */
			vl_gnt_r <= vl_g;
			fl_gnt_r <= fl_g;
			if (vl_g) begin
				vl_s <= free_slot;
				vl_wait <= 1'b1;
			end
			if (fl_g) begin
				fl_s <= free_slot;
				fl_wait <= 1'b1;
			end
			if (vl_go)
				vl_wait <= 1'b0;
			if (fl_go)
				fl_wait <= 1'b0;
			/* Compute. */
			if (cs_kick && !cs_act) begin
				cs_act <= 1'b1;
				{id_x, id_y, id_z} <= 48'd0;
				rot <= 8'd0;
			end
			if (cs_try) begin
				launching <= 1'b1;
				wk <= 4'd0;
			end
			if (cs_try || cs_skip) begin
				rot <= rot_last ? 8'd0 : rot1[7:0];
				if (last_id)
					cs_act <= 1'b0;
			end
			if (cs_adv_id_x) begin
				id_x <= id_x_last ? 16'd0 : id_x1;
			end
			if (cs_adv_id_y && id_x_last_y) begin
				id_y <= id_y_last ? 16'd0 : id_y1;
			end
			if (cs_adv_id_z && id_x_last_z && id_y_last) begin
				id_z <= id_z1;
			end
			if (cs_launch) begin
				wk <= wk1;
				if (wk1 == nw) begin
					launching <= 1'b0;
					wg_tag <= tag1;
				end
			end
		end
	end

	genvar gwp;
	generate
		for (gwp = 0; gwp < NWARPS; gwp = gwp + 1) begin : g_pc_ctrl
			wire clr_raw   = st_free_r[gwp] || (st[gwp*3 +: 3] == S_ALLOC);
			wire fetch_raw = (st[gwp*3 +: 3] == S_FETCH) && fb_valid && (fb_warp == gwp[WARP_W-1:0]) && (fb_kind == 2'd0);
			wire wc_raw    = (st[gwp*3 +: 3] == S_WC) && wc_valid && (wc_warp == gwp[WARP_W-1:0]);
			wire clr_lo, clr_hi, fetch_lo, fetch_hi, wc_lo, wc_hi;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_pclr0 (.I0(clr_raw), .O(clr_lo));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_pclr1 (.I0(clr_raw), .O(clr_hi));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_pfet0 (.I0(fetch_raw), .O(fetch_lo));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_pfet1 (.I0(fetch_raw), .O(fetch_hi));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_pwc0  (.I0(wc_raw), .O(wc_lo));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_pwc1  (.I0(wc_raw), .O(wc_hi));
`else
			assign clr_lo   = clr_raw;
			assign clr_hi   = clr_raw;
			assign fetch_lo = fetch_raw;
			assign fetch_hi = fetch_raw;
			assign wc_lo    = wc_raw;
			assign wc_hi    = wc_raw;
`endif
			always @(posedge clk) begin
				if (rst_p) begin
					pc[gwp*16 +: 8]     <= 8'd0;
					pc[gwp*16 + 8 +: 8] <= 8'd0;
				end else begin
					if (clr_lo)
						pc[gwp*16 +: 8] <= 8'd0;
					else if (fetch_lo)
						pc[gwp*16 +: 8] <= pc_p1[gwp*16 +: 8];
					else if (wc_lo)
						pc[gwp*16 +: 8] <= wc_pc[7:0];

					if (clr_hi)
						pc[gwp*16 + 8 +: 8] <= 8'd0;
					else if (fetch_hi)
						pc[gwp*16 + 8 +: 8] <= pc_p1[gwp*16 + 8 +: 8];
					else if (wc_hi)
						pc[gwp*16 + 8 +: 8] <= wc_pc[15:8];
				end
			end
		end
	endgenerate

	wire unused_ok = &{1'b0, fl_info[63:49], wk[3], lanes_r[23:9], rot1[8], slot_rdy_nogap,
		w_fa_co_unused, wdata_m1_bo_unused, ix_co_unused, iy_co_unused, iz_co_unused,
		rot_co_unused, (NSU != 0)};
endmodule

`default_nettype wire
