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

	(* keep = "true" *) wire rst_p = !rst_n;

	/* STATE: program bases, WG_SIZE, the DISPATCH grid. */
	reg [31:0] vs_base, fs_base, cs_base;
	reg [7:0] wg_x, wg_y, wg_z;
	reg [15:0] grid_x, grid_y, grid_z;
	reg [15:0] grid_x_m1, grid_y_m1, grid_z_m1;
	wire [15:0] st_wdata_m1;
	wire wdata_m1_bo_unused;
	am_sub #(.W(16)) u_wdata_m1 (.a(st_wdata[15:0]), .b(16'd0), .bi(1'b1), .d(st_wdata_m1), .bo(wdata_m1_bo_unused));
	always @(posedge clk) begin
		if (rst_p) begin
			{vs_base, fs_base, cs_base} <= 96'd0;
			{wg_x, wg_y, wg_z} <= {8'd1, 8'd1, 8'd1};
			{grid_x, grid_y, grid_z} <= {16'd1, 16'd1, 16'd1};
			{grid_x_m1, grid_y_m1, grid_z_m1} <= {16'd0, 16'd0, 16'd0};
		end else if (st_we) begin
			case (st_idx)
			GHCI_S_VS_BASE: vs_base <= st_wdata;
			GHCI_S_FS_BASE: fs_base <= st_wdata;
			GHCI_S_CS_BASE: cs_base <= st_wdata;
			GHCI_S_WG_SIZE: {wg_z, wg_y, wg_x} <= st_wdata[23:0];
			GHCI_S_GRID_X: begin grid_x <= st_wdata[15:0]; grid_x_m1 <= st_wdata_m1; end
			GHCI_S_GRID_Y: begin grid_y <= st_wdata[15:0]; grid_y_m1 <= st_wdata_m1; end
			GHCI_S_GRID_Z: begin grid_z <= st_wdata[15:0]; grid_z_m1 <= st_wdata_m1; end
			default: ;
			endcase
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
	(* max_fanout = 12 *) reg [NWARPS*3-1:0] st;
	(* max_fanout = 12 *) reg [NWARPS*16-1:0] pc;
	(* max_fanout = 12 *) reg [NWARPS*GAP_W-1:0] gap;
	wire [NWARPS*160-1:0] info;
	(* max_fanout = 12 *) reg [NWARPS*4-1:0] tag;	/* workgroup of a compute warp (barriers) */

	/* Compute launch: the next workgroup id, its warps, and whose it is. */
	(* max_fanout = 12 *) reg cs_act;
	(* max_fanout = 12 *) reg [15:0] id_x, id_y, id_z;
	(* max_fanout = 12 *) reg [7:0] rot;	/* linear id % NSU */
	(* max_fanout = 12 *) reg [3:0] wg_tag;
	(* max_fanout = 12 *) reg [3:0] wk;	/* next warp of the workgroup being launched */
	(* max_fanout = 12 *) reg launching;
	/* Compute workgroup size pipelined over 5 cycles (DSP LAT=2 + fabric output reg) */
	reg [7:0] wg_z_r1, wg_z_r2;
	wire [15:0] lanes_xy;
	wire [23:0] lanes;
	(* dont_touch = "true" *) reg [23:0] lanes_r;
	am_mul #(.AW(8), .BW(8), .LAT(2)) u_lxy (.clk(clk), .en(1'b1), .a(wg_x), .b(wg_y), .p(lanes_xy));
	am_mul #(.AW(16), .BW(8), .LAT(2)) u_lanes (.clk(clk), .en(1'b1), .a(lanes_xy), .b(wg_z_r2), .p(lanes));

	/* Pure-LUT ceil(lanes_r / 32) clamped to NWARPS (0 CARRY4s, <= 3 LUTs) */
	wire [3:0] q_lanes = lanes_r[8:5];
	wire       rem_nz  = |lanes_r[4:0];
	wire       hi_nz   = |lanes_r[23:9];
	wire [3:0] q_p1    = {q_lanes[3] ^ (&q_lanes[2:0]), q_lanes[2] ^ (&q_lanes[1:0]), q_lanes[1] ^ q_lanes[0], ~q_lanes[0]};
	wire [3:0] nw_cand = rem_nz ? q_p1 : q_lanes;
	wire       nw_ovf  = hi_nz || (rem_nz && (&q_lanes)) || ({28'd0, nw_cand} > NWARPS);
	(* max_fanout = 12 *) reg [3:0] nw;
	always @(posedge clk) begin
		if (rst_p) begin
			wg_z_r1 <= 8'd1;
			wg_z_r2 <= 8'd1;
			lanes_r <= 24'd1;
			nw      <= 4'd1;
		end else begin
			wg_z_r1 <= wg_z;
			wg_z_r2 <= wg_z_r1;
			lanes_r <= lanes;
			nw      <= nw_ovf ? NWARPS[3:0] : nw_cand;
		end
	end
	wire mine_wg = {24'd0, rot} == SU_INDEX;
	wire [15:0] id_x1, id_y1, id_z1;	/* the ids + 1 */
	wire ix_co_unused, iy_co_unused, iz_co_unused;
	am_add #(.W(16)) u_idx1 (.a(id_x), .b(16'd0), .ci(1'b1), .s(id_x1), .co(ix_co_unused));
	am_add #(.W(16)) u_idy1 (.a(id_y), .b(16'd0), .ci(1'b1), .s(id_y1), .co(iy_co_unused));
	am_add #(.W(16)) u_idz1 (.a(id_z), .b(16'd0), .ci(1'b1), .s(id_z1), .co(iz_co_unused));
	(* keep = "true" *) wire id_x_last = (id_x == grid_x_m1);
	(* keep = "true" *) wire id_y_last = (id_y == grid_y_m1);
	(* keep = "true" *) wire id_z_last = (id_z == grid_z_m1);
	wire last_id = id_x_last && id_y_last && id_z_last;

	/* Free slots (pure LUTs, 0 CARRY4s, <= 2 LUT levels from st). */
	(* keep = "true" *) wire [NWARPS-1:0] slot_free;
	genvar gf;
	generate
		for (gf = 0; gf < NWARPS; gf = gf + 1) begin : g_free
			assign slot_free[gf] = (st[gf*3 +: 3] == S_FREE);
		end
	endgenerate
	(* keep = "true", max_fanout = 12 *) wire any_free = |slot_free;
	(* keep = "true", max_fanout = 12 *) wire [WARP_W-1:0] free_slot;
	(* keep = "true", max_fanout = 12 *) wire [4:0] n_free;
	generate
		if (NWARPS == 4) begin : g_nfree4
			assign free_slot = slot_free[0] ? 2'd0 : slot_free[1] ? 2'd1 : slot_free[2] ? 2'd2 : 2'd3;
			assign n_free[0] = ^slot_free;
			assign n_free[1] = (slot_free[0] & slot_free[1]) ^ (slot_free[2] & slot_free[3]) ^
			                   ((slot_free[0] ^ slot_free[1]) & (slot_free[2] ^ slot_free[3]));
			assign n_free[2] = &slot_free;
			assign n_free[4:3] = 2'b00;
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
		end
	endgenerate

	/* Grants (one outstanding per source); compute launches hold them off. */
	(* max_fanout = 12 *) reg vl_wait, fl_wait;
	(* max_fanout = 12 *) reg vl_gnt_r, fl_gnt_r;
	(* max_fanout = 12 *) reg [WARP_W-1:0] vl_s, fl_s;
	(* keep = "true", max_fanout = 12 *) wire cs_try = cs_act && !launching && mine_wg && ({1'b0, n_free} >= {2'b00, nw});
	(* keep = "true", max_fanout = 12 *) wire cs_skip = cs_act && !launching && !mine_wg;
	(* keep = "true", max_fanout = 12 *) wire fl_g = fl_req && !fl_wait && any_free && !launching && !cs_try;
	(* keep = "true", max_fanout = 12 *) wire vl_g = vl_req && !vl_wait && !fl_g && pt_ok && !launching && !cs_try &&
		({27'd0, n_free} > FRAG_RESERVE);
	assign fl_gnt = fl_gnt_r;
	assign vl_gnt = vl_gnt_r;
	assign fl_slot = fl_s;
	assign vl_slot = vl_s;

	/* Initial EXEC: vertex/fragment go, else the next compute warp (0 CARRY4s). */
	reg [31:0] lmask;	/* (1 << lanes_r[4:0]) - 1 */
	integer li;
	always @(*)
		for (li = 0; li < 32; li = li + 1)
			lmask[li] = li < {27'd0, lanes_r[4:0]};
	wire wl_ge32 = hi_nz || (q_lanes > wk);
	wire [31:0] cmask = wl_ge32 ? 32'hFFFFFFFF : lmask;
	(* keep = "true", max_fanout = 12 *) wire cs_launch = launching && !vl_go && !fl_go && any_free;
	assign init_valid = vl_go || fl_go || cs_launch;
	assign init_warp = vl_go ? vl_s : fl_go ? fl_s : free_slot;
	assign init_mask = vl_go ? vl_mask : fl_go ? fl_mask : cmask;

	/* Candidates: slots that are READY, out of gap, and warp_ready from scoreboard */
	(* keep = "true" *) wire [NWARPS-1:0] slot_rdy_nogap;
	(* max_fanout = 12 *) wire [NWARPS-1:0] cand;
	genvar gc;
	generate
		for (gc = 0; gc < NWARPS; gc = gc + 1) begin : g_cand
			assign slot_rdy_nogap[gc] = (st[gc*3 +: 3] == S_READY) && (gap[gc*GAP_W +: GAP_W] == {GAP_W{1'b0}});
			assign cand[gc] = slot_rdy_nogap[gc] && warp_ready[gc];
		end
	endgenerate

	/* Registered pairwise relative ages for GTO Oldest policy (0 CARRY4s, 0 Pre-LUTs!) */
	(* max_fanout = 12 *) reg cmp01_r, cmp02_r, cmp03_r, cmp12_r, cmp13_r, cmp23_r;
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

	/* Selection: GTO (Greedy-Then-Oldest, level-pinned 3-LUT) or Round-Robin */
	reg [WARP_W-1:0] rr;
	reg [WARP_W-1:0] last_warp;
	reg active_valid;
	(* max_fanout = 12 *) reg hold_v;
	(* max_fanout = 12 *) reg [WARP_W-1:0] hold_w;

	/* Level 1 wires for GTO / active warp check */
	(* keep = "true" *) wire [NWARPS-1:0] slot_rdy_or_fetch;
	generate
		for (gc = 0; gc < NWARPS; gc = gc + 1) begin : g_rof
			assign slot_rdy_or_fetch[gc] = (st[gc*3 +: 3] == S_READY) || (st[gc*3 +: 3] == S_FETCH);
		end
	endgenerate
	(* keep = "true" *) wire active_st_ok = slot_rdy_or_fetch[last_warp];
	(* keep = "true" *) wire [WARP_W-1:0] fixed_w = hold_v ? hold_w : last_warp;

	/* Level 2 wires for GTO tournament (each <= 6 Level-1 inputs -> 1 LUT6) */
	(* keep = "true" *) wire active_live = active_valid && active_st_ok && warp_ready[last_warp];
	(* keep = "true" *) wire use_fixed   = hold_v || (active_valid && active_st_ok && warp_ready[last_warp]);
	(* keep = "true" *) wire w0_ok03 = (slot_rdy_nogap[0] && warp_ready[0]) && !(slot_rdy_nogap[3] && warp_ready[3] && cmp03_r);
	(* keep = "true" *) wire w0_ok12 = !(slot_rdy_nogap[1] && warp_ready[1] && cmp01_r) && !(slot_rdy_nogap[2] && warp_ready[2] && cmp02_r);
	(* keep = "true" *) wire w1_ok13 = (slot_rdy_nogap[1] && warp_ready[1]) && !(slot_rdy_nogap[3] && warp_ready[3] && cmp13_r);
	(* keep = "true" *) wire w1_ok02 = !(slot_rdy_nogap[0] && warp_ready[0] && !cmp01_r) && !(slot_rdy_nogap[2] && warp_ready[2] && cmp12_r);
	(* keep = "true" *) wire w2_ok23 = (slot_rdy_nogap[2] && warp_ready[2]) && !(slot_rdy_nogap[3] && warp_ready[3] && cmp23_r);
	(* keep = "true" *) wire w2_ok01 = !(slot_rdy_nogap[0] && warp_ready[0] && !cmp02_r) && !(slot_rdy_nogap[1] && warp_ready[1] && !cmp12_r);

	(* keep = "true", max_fanout = 12 *) wire [WARP_W-1:0] fsel;
	(* keep = "true", max_fanout = 12 *) wire fsel_v;
	generate
		if (GTO != 0 && NWARPS == 4) begin : g_sel_gto4
			/* Level 3 (each <= 6 Level-2 inputs -> 1 LUT6) */
			assign fsel[1] = use_fixed ? fixed_w[1] : (!(w0_ok03 && w0_ok12) && !(w1_ok13 && w1_ok02));
			assign fsel[0] = use_fixed ? fixed_w[0] : (!(w0_ok03 && w0_ok12) && !(w2_ok23 && w2_ok01));
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
	reg [159:0] q_i;
	integer y;
	always @(*) begin
		q_i = 160'd0;
		for (y = 0; y < NWARPS; y = y + 1) begin
			if (q_warp == y[WARP_W-1:0])
				q_i = info[y*160 +: 160];
		end
	end
	assign q_info = q_i;

	/* Precompute fetch address per warp independently from selection tournament */
	wire [NWARPS-1:0] w_fa_co_unused;
	wire [NWARPS*32-1:0] w_f_addr;
	genvar g_fa;
	generate
		for (g_fa = 0; g_fa < NWARPS; g_fa = g_fa + 1) begin : g_faddr
			wire [1:0] w_sk = info[g_fa*160 + ATG_WI_KIND +: 2];
			wire [31:0] w_base = w_sk == K_VERT ? vs_base : w_sk == K_FRAG ? fs_base : cs_base;
			am_add #(.W(32)) u_fa_w (
				.a(w_base),
				.b({13'd0, pc[g_fa*16 +: 16], 3'd0}),
				.ci(1'b0),
				.s(w_f_addr[g_fa*32 +: 32]),
				.co(w_fa_co_unused[g_fa])
			);
		end
	endgenerate

	assign f_valid = fsel_v;
	assign f_warp = fsel;
	assign f_pc = pc[(fsel)*16 +: 16];
	assign f_addr = w_f_addr[fsel*32 +: 32];

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

	/* Barrier: every warp of the workgroup is parked. */
	reg [NWARPS-1:0] bar_go;
	integer a, b;
	always @(*) begin
		for (a = 0; a < NWARPS; a = a + 1) begin
			bar_go[a] = st[(a)*3 +: 3] == S_BAR;
			for (b = 0; b < NWARPS; b = b + 1)
				if (b != a && tag[(b)*4 +: 4] == tag[(a)*4 +: 4] && info[(b)*160 + ATG_WI_KIND +: 2] == K_COMP &&
				    st[(b)*3 +: 3] != S_FREE && st[(b)*3 +: 3] != S_BAR && st[(b)*3 +: 3] != S_ENDED)
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
		for (gws = 0; gws < 10; gws = gws + 1) begin : g_info_sl
			(* keep = "true" *) wire vl_we_s = vl_go && (vl_s == gwi[WARP_W-1:0]);
			(* keep = "true" *) wire fl_we_s = fl_go && (fl_s == gwi[WARP_W-1:0]);
			(* keep = "true" *) wire cs_we_s = cs_launch && (free_slot == gwi[WARP_W-1:0]);
			(* shreg_extract = "no" *) reg [15:0] info_sl_r;
			always @(posedge clk) begin
				if (rst_p)
					info_sl_r <= 16'd0;
				else if (cs_we_s)
					info_sl_r <= wi_cs[gws*16 +: 16];
				else if (fl_we_s)
					info_sl_r <= wi_fl[gws*16 +: 16];
				else if (vl_we_s)
					info_sl_r <= wi_vl[gws*16 +: 16];
			end
			assign info[gwi*160 + gws*16 +: 16] = info_sl_r;
		end
	end
	endgenerate

	integer w;
	always @(posedge clk) begin
		if (rst_p) begin
			st <= {NWARPS{S_FREE}};
			pc <= {(NWARPS*16){1'b0}};
			gap <= {(NWARPS*GAP_W){1'b0}};
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
				if (fsel_v && f_ready && (fsel == w[WARP_W-1:0]))
					gap[w*GAP_W +: GAP_W] <= GAP_INIT;
				else if (gap[(w)*GAP_W +: GAP_W] != {GAP_W{1'b0}})
					gap[(w)*GAP_W +: GAP_W] <= gap_m1[(w)*GAP_W +: GAP_W];

				/* Single flat per-state transition case (<= 4 LUTs) */
				case (st[(w)*3 +: 3])
				S_FREE: begin
					pc[(w)*16 +: 16] <= 16'd0;
					tag[(w)*4 +: 4]  <= wg_tag;
					if (cs_launch && (free_slot == w[WARP_W-1:0]))
						st[(w)*3 +: 3] <= S_READY;
					else if ((vl_go && vl_s == w[WARP_W-1:0]) || (fl_go && fl_s == w[WARP_W-1:0]))
						st[(w)*3 +: 3] <= S_READY;
					else if ((vl_g || fl_g) && (free_slot == w[WARP_W-1:0]))
						st[(w)*3 +: 3] <= S_ALLOC;
				end
				S_ALLOC: begin
					pc[(w)*16 +: 16] <= 16'd0;
					if ((vl_go && vl_s == w[WARP_W-1:0]) || (fl_go && fl_s == w[WARP_W-1:0]))
						st[(w)*3 +: 3] <= S_READY;
				end
				S_READY: begin
					if (fsel_v && f_ready && (fsel == w[WARP_W-1:0]))
						st[(w)*3 +: 3] <= S_FETCH;
				end
				S_FETCH:
					if (fb_valid && fb_warp == w[WARP_W-1:0]) begin
						if (fb_kind == 2'd0) begin
							st[(w)*3 +: 3] <= S_READY;
							pc[(w)*16 +: 16] <= pc_p1[(w)*16 +: 16];
						end else if (fb_kind == 2'd1)
							st[(w)*3 +: 3] <= S_WC;
						else
							st[(w)*3 +: 3] <= wake[w] ? S_READY : S_REPLAY;
					end
				S_REPLAY:
					if (wake[w])
						st[(w)*3 +: 3] <= S_READY;
				S_WC:
					if (wc_valid && wc_warp == w[WARP_W-1:0]) begin
						pc[(w)*16 +: 16] <= wc_pc;
						st[(w)*3 +: 3] <= wc_op == 2'd1 ? S_ENDED : wc_op == 2'd2 ? S_BAR : S_READY;
					end
				S_BAR:
					if (bar_go[w])
						st[(w)*3 +: 3] <= S_READY;
				S_ENDED:
					if (xr_valid && xr_warp == w[WARP_W-1:0])
						st[(w)*3 +: 3] <= S_FREE;
				default: ;
				endcase
			end
			hold_v <= fsel_v && !f_ready;
			hold_w <= fsel;
			if (fsel_v && f_ready) begin
				rr <= rr_next;
				last_warp <= fsel;
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
			if (cs_skip || (cs_launch && (wk1 == nw))) begin
				id_x <= id_x_last ? 16'd0 : id_x1;
				if (id_x_last) begin
					id_y <= id_y_last ? 16'd0 : id_y1;
					if (id_y_last)
						id_z <= id_z1;
				end
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

	wire unused_ok = &{1'b0, fl_info[63:49], wk[3], lanes_r[23:9], rot1[8],
		w_fa_co_unused, wdata_m1_bo_unused, ix_co_unused, iy_co_unused, iz_co_unused,
		rot_co_unused, (NSU != 0)};
endmodule

`default_nettype wire
