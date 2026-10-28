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

	/* STATE: program bases, WG_SIZE, the DISPATCH grid. */
	reg [31:0] vs_base, fs_base, cs_base;
	reg [7:0] wg_x, wg_y, wg_z;
	reg [15:0] grid_x, grid_y, grid_z;
	always @(posedge clk) begin
		if (!rst_n) begin
			{vs_base, fs_base, cs_base} <= 96'd0;
			{wg_x, wg_y, wg_z} <= {8'd1, 8'd1, 8'd1};
			{grid_x, grid_y, grid_z} <= {16'd1, 16'd1, 16'd1};
		end else if (st_we) begin
			case (st_idx)
			GHCI_S_VS_BASE: vs_base <= st_wdata;
			GHCI_S_FS_BASE: fs_base <= st_wdata;
			GHCI_S_CS_BASE: cs_base <= st_wdata;
			GHCI_S_WG_SIZE: {wg_z, wg_y, wg_x} <= st_wdata[23:0];
			GHCI_S_GRID_X: grid_x <= st_wdata[15:0];
			GHCI_S_GRID_Y: grid_y <= st_wdata[15:0];
			GHCI_S_GRID_Z: grid_z <= st_wdata[15:0];
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
	reg [NWARPS*3-1:0] st;
	reg [NWARPS*16-1:0] pc;
	reg [NWARPS*GAP_W-1:0] gap;
	reg [NWARPS*160-1:0] info;
	reg [NWARPS*4-1:0] tag;	/* workgroup of a compute warp (barriers) */

	/* Compute launch: the next workgroup id, its warps, and whose it is. */
	reg cs_act;
	reg [15:0] id_x, id_y, id_z;
	reg [7:0] rot;	/* linear id % NSU */
	reg [3:0] wg_tag;
	reg [3:0] wk;	/* next warp of the workgroup being launched */
	reg launching;
	/* Compute workgroup size pipelined over 3 cycles */
	reg [7:0] wg_z_r1;
	wire [15:0] lanes_xy;
	wire [23:0] lanes;
	am_mul #(.AW(8), .BW(8), .LAT(1)) u_lxy (.clk(clk), .en(1'b1), .a(wg_x), .b(wg_y), .p(lanes_xy));
	am_mul #(.AW(16), .BW(8), .LAT(1)) u_lanes (.clk(clk), .en(1'b1), .a(lanes_xy), .b(wg_z_r1), .p(lanes));
	wire [23:0] lanes31;
	wire l31_co_unused, ix_co_unused, iy_co_unused, iz_co_unused;
	am_add #(.W(24)) u_l31 (.a(lanes), .b(24'd31), .ci(1'b0), .s(lanes31), .co(l31_co_unused));
	wire [23:0] nw_full = lanes31 >> 5;
	reg [3:0] nw;
	always @(posedge clk) begin
		if (!rst_n) begin
			wg_z_r1 <= 8'd1;
			nw      <= 4'd1;
		end else begin
			wg_z_r1 <= wg_z;
			nw      <= nw_full > NWARPS ? NWARPS[3:0] : nw_full[3:0];
		end
	end
	wire mine_wg = {24'd0, rot} == SU_INDEX;
	wire [15:0] id_x1, id_y1, id_z1;	/* the ids + 1 */
	am_add #(.W(16)) u_idx1 (.a(id_x), .b(16'd0), .ci(1'b1), .s(id_x1), .co(ix_co_unused));
	am_add #(.W(16)) u_idy1 (.a(id_y), .b(16'd0), .ci(1'b1), .s(id_y1), .co(iy_co_unused));
	am_add #(.W(16)) u_idz1 (.a(id_z), .b(16'd0), .ci(1'b1), .s(id_z1), .co(iz_co_unused));
	wire last_id = id_x1 == grid_x && id_y1 == grid_y && id_z1 == grid_z;

	/* Free slots. */
	reg [WARP_W-1:0] free_slot;
	reg any_free;
	reg [4:0] n_free;
	integer i;
	always @(*) begin
		any_free = 1'b0;
		free_slot = {WARP_W{1'b0}};
		n_free = 5'd0;
		for (i = NWARPS - 1; i >= 0; i = i - 1)
			if (st[(i)*3 +: 3] == S_FREE) begin
				any_free = 1'b1;
				free_slot = i[WARP_W-1:0];
				n_free = n_free + 5'd1;
			end
	end

	/* Grants (one outstanding per source); compute launches hold them off. */
	reg vl_wait, fl_wait;
	reg [WARP_W-1:0] vl_s, fl_s;
	wire cs_try = cs_act && !launching && mine_wg && {1'b0, n_free} >= {2'b00, nw};
	wire cs_skip = cs_act && !launching && !mine_wg;
	wire fl_g = fl_req && !fl_wait && any_free && !launching && !cs_try;
	wire vl_g = vl_req && !vl_wait && !fl_g && pt_ok && !launching && !cs_try &&
		{27'd0, n_free} > FRAG_RESERVE;
	assign fl_gnt = fl_g;
	assign vl_gnt = vl_g;
	assign fl_slot = fl_g ? free_slot : fl_s;
	assign vl_slot = vl_g ? free_slot : vl_s;

	/* Initial EXEC: vertex/fragment go, else the next compute warp. */
	wire [31:0] wlanes;
	wire wl_bo_unused;
	am_sub #(.W(32)) u_wl (.a({8'd0, lanes}), .b({23'd0, wk, 5'd0}), .bi(1'b0), .d(wlanes), .bo(wl_bo_unused));
	reg [31:0] lmask;	/* (1 << wlanes[4:0]) - 1 */
	integer li;
	always @(*)
		for (li = 0; li < 32; li = li + 1)
			lmask[li] = li < {27'd0, wlanes[4:0]};
	wire [31:0] cmask = wlanes >= 32 ? 32'hFFFFFFFF : lmask;
	wire cs_launch = launching && !vl_go && !fl_go && any_free;
	assign init_valid = vl_go || fl_go || cs_launch;
	assign init_warp = vl_go ? vl_s : fl_go ? fl_s : free_slot;
	assign init_mask = vl_go ? vl_mask : fl_go ? fl_mask : cmask;

	/* Candidates: slots that are READY, out of gap, and warp_ready from scoreboard */
	wire [NWARPS-1:0] cand;
	genvar gc;
	generate
		for (gc = 0; gc < NWARPS; gc = gc + 1) begin : g_cand
			assign cand[gc] = (st[gc*3 +: 3] == S_READY) && (gap[gc*GAP_W +: GAP_W] == {GAP_W{1'b0}}) && warp_ready[gc];
		end
	endgenerate

	/* Wait ages for GTO Oldest policy */
	reg [NWARPS*16-1:0] wait_age;
	wire [NWARPS*16-1:0] age_p1;
	genvar ga;
	generate
		for (ga = 0; ga < NWARPS; ga = ga + 1) begin : g_age
			wire age_co_unused;
			am_add #(.W(16)) u_age_add (
				.a(wait_age[ga*16 +: 16]),
				.b(16'd0),
				.ci(1'b1),
				.s(age_p1[ga*16 +: 16]),
				.co(age_co_unused)
			);
		end
	endgenerate

	/* Selection: GTO (Greedy-Then-Oldest) or Round-Robin */
	reg [WARP_W-1:0] rr, sel;
	reg [WARP_W-1:0] last_warp;
	reg active_valid;
	reg sel_v;
	integer k, c, r;
	reg found_cand;
	reg [15:0] max_age;
	integer w_idx, ga_i;
	reg active_st_ok;
	reg active_warp_ready;
	reg t_sel01, t_sel23, t_sel_top;
	reg [1:0] t_w01, t_w23;
	reg [15:0] t_a01, t_a23;
	reg t_c01, t_c23;

	always @(*) begin
		active_st_ok = 1'b0;
		active_warp_ready = 1'b0;
		for (ga_i = 0; ga_i < NWARPS; ga_i = ga_i + 1) begin
			if (last_warp == ga_i[WARP_W-1:0]) begin
				active_st_ok = (st[ga_i*3 +: 3] == S_READY) || (st[ga_i*3 +: 3] == S_FETCH);
				active_warp_ready = warp_ready[ga_i];
			end
		end
	end
	wire active_live = active_valid && active_warp_ready && active_st_ok;

	always @(*) begin
		sel_v = 1'b0;
		sel = {WARP_W{1'b0}};
		found_cand = 1'b0;
		max_age = 16'd0;
		c = 0;
		if (GTO != 0) begin
			if (active_live) begin
				if (cand[last_warp]) begin
					sel_v = 1'b1;
					sel = last_warp;
				end
			end else begin
				if (NWARPS == 4) begin
					t_sel01 = !cand[0] || (cand[1] && (wait_age[1*16 +: 16] > wait_age[0*16 +: 16]));
					t_w01 = t_sel01 ? 2'd1 : 2'd0;
					t_a01 = t_sel01 ? wait_age[1*16 +: 16] : wait_age[0*16 +: 16];
					t_c01 = cand[0] || cand[1];

					t_sel23 = !cand[2] || (cand[3] && (wait_age[3*16 +: 16] > wait_age[2*16 +: 16]));
					t_w23 = t_sel23 ? 2'd3 : 2'd2;
					t_a23 = t_sel23 ? wait_age[3*16 +: 16] : wait_age[2*16 +: 16];
					t_c23 = cand[2] || cand[3];

					t_sel_top = !t_c01 || (t_c23 && (t_a23 > t_a01));
					sel = t_sel_top ? t_w23[WARP_W-1:0] : t_w01[WARP_W-1:0];
					sel_v = t_c01 || t_c23;
				end else begin
					for (w_idx = 0; w_idx < NWARPS; w_idx = w_idx + 1) begin
						if (cand[w_idx]) begin
							if (!found_cand || wait_age[w_idx*16 +: 16] > max_age) begin
								found_cand = 1'b1;
								max_age = wait_age[w_idx*16 +: 16];
								sel = w_idx[WARP_W-1:0];
							end
						end
					end
					sel_v = found_cand;
				end
			end
		end else begin
			for (r = 0; r < NWARPS; r = r + 1)
				if (rr == r[WARP_W-1:0])
					for (k = NWARPS - 1; k >= 0; k = k - 1) begin
						c = (r + k) % NWARPS;
						if (cand[c]) begin
							sel_v = 1'b1;
							sel = c[WARP_W-1:0];
						end
					end
		end
	end
	/* A fetch that is not taken keeps its warp (valid/ready). */
	reg hold_v;
	reg [WARP_W-1:0] hold_w;
	wire [WARP_W-1:0] fsel = hold_v ? hold_w : sel;
	wire fsel_v = hold_v || sel_v;
	reg [1:0] sk;
	reg [159:0] q_i;
	integer y;
	always @(*) begin
		sk = 2'd0;
		q_i = 160'd0;
		for (y = 0; y < NWARPS; y = y + 1) begin
			if (fsel == y[WARP_W-1:0])
				sk = info[y*160 + ATG_WI_KIND +: 2];
			if (q_warp == y[WARP_W-1:0])
				q_i = info[y*160 +: 160];
		end
	end
	wire [31:0] base = sk == K_VERT ? vs_base : sk == K_FRAG ? fs_base : cs_base;
	wire fa_co_unused;
	assign f_valid = fsel_v;
	assign f_warp = fsel;
	assign f_pc = pc[(fsel)*16 +: 16];
	am_add #(.W(32)) u_fa (.a(base), .b({13'd0, pc[(fsel)*16 +: 16], 3'd0}), .ci(1'b0), .s(f_addr),
		.co(fa_co_unused));
	assign q_info = q_i;

	/* Per slot: the gap and pc counted down / up; rr, rot, wk and the tag + 1. */
	wire [NWARPS*GAP_W-1:0] gap_m1;
	wire [NWARPS*16-1:0] pc_p1;
	genvar gw;
	generate
		for (gw = 0; gw < NWARPS; gw = gw + 1) begin : g_w
			wire g_bo_unused, p_co_unused;
			am_sub #(.W(GAP_W)) u_gap (.a(gap[gw*GAP_W +: GAP_W]), .b({GAP_W{1'b0}}), .bi(1'b1), .d(gap_m1[gw*GAP_W +: GAP_W]),
				.bo(g_bo_unused));
			am_add #(.W(16)) u_pc (.a(pc[gw*16 +: 16]), .b(16'd0), .ci(1'b1), .s(pc_p1[gw*16 +: 16]),
				.co(p_co_unused));
		end
	endgenerate
	wire [WARP_W-1:0] rr_next;
	wire [8:0] rot1;
	wire [3:0] wk1, tag1;
	wire rr_co_unused, rot_co_unused, wk_co_unused, tag_co_unused;
	am_add #(.W(WARP_W)) u_rr (.a(fsel), .b({WARP_W{1'b0}}), .ci(1'b1), .s(rr_next), .co(rr_co_unused));
	am_add #(.W(9)) u_rot (.a({1'b0, rot}), .b(9'd0), .ci(1'b1), .s(rot1), .co(rot_co_unused));
	am_add #(.W(4)) u_wk (.a(wk), .b(4'd0), .ci(1'b1), .s(wk1), .co(wk_co_unused));
	am_add #(.W(4)) u_tag (.a(wg_tag), .b(4'd0), .ci(1'b1), .s(tag1), .co(tag_co_unused));

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

	reg busy_r;
	always @(*) begin
		busy_r = cs_act || launching;
		for (a = 0; a < NWARPS; a = a + 1)
			if (st[(a)*3 +: 3] != S_FREE)
				busy_r = 1'b1;
	end
	assign busy = busy_r;

	integer w;
	always @(posedge clk) begin
		if (!rst_n) begin
			st <= {NWARPS{S_FREE}};
			pc <= {(NWARPS*16){1'b0}};
			gap <= {(NWARPS*GAP_W){1'b0}};
			info <= {(NWARPS*160){1'b0}};
			tag <= {(NWARPS*4){1'b0}};
			{rr, hold_v, hold_w} <= {(2*WARP_W+1){1'b0}};
			last_warp <= {WARP_W{1'b0}};
			active_valid <= 1'b0;
			wait_age <= {(NWARPS*16){1'b0}};
			{vl_wait, fl_wait, vl_s, fl_s} <= {(2*WARP_W+2){1'b0}};
			{cs_act, launching} <= 2'b00;
			{id_x, id_y, id_z} <= 48'd0;
			rot <= 8'd0;
			wg_tag <= 4'd0;
			wk <= 4'd0;
		end else begin
			for (w = 0; w < NWARPS; w = w + 1) begin
				if (gap[(w)*GAP_W +: GAP_W] != {GAP_W{1'b0}})
					gap[(w)*GAP_W +: GAP_W] <= gap_m1[(w)*GAP_W +: GAP_W];
				/* Feedback and warp control. */
				case (st[(w)*3 +: 3])
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
				for (w = 0; w < NWARPS; w = w + 1)
					if (fsel == w[WARP_W-1:0]) begin
						st[w*3 +: 3] <= S_FETCH;
						gap[w*GAP_W +: GAP_W] <= G[GAP_W-1:0] - {{(GAP_W-1){1'b0}}, 1'b1};
					end
				rr <= rr_next;
				last_warp <= fsel;
				active_valid <= 1'b1;
			end
			for (w = 0; w < NWARPS; w = w + 1) begin
				if (cand[w]) begin
					if (wait_age[w*16 +: 16] != 16'hFFFF)
						wait_age[w*16 +: 16] <= age_p1[w*16 +: 16];
				end else begin
					wait_age[w*16 +: 16] <= 16'd0;
				end
			end
			/* Vertex and fragment slots. */
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
			for (w = 0; w < NWARPS; w = w + 1) begin
				if ((vl_g || fl_g) && free_slot == w[WARP_W-1:0])
					st[w*3 +: 3] <= S_ALLOC;
				if (vl_go && vl_s == w[WARP_W-1:0]) begin
					st[w*3 +: 3] <= S_READY;
					pc[w*16 +: 16] <= 16'd0;
					info[w*160 +: 160] <= wi(48'd0, 48'd0, 8'd0, K_VERT, 1'b0, 16'd0, vl_mask);
				end
				if (fl_go && fl_s == w[WARP_W-1:0]) begin
					st[w*3 +: 3] <= S_READY;
					pc[w*16 +: 16] <= 16'd0;
					info[w*160 +: 160] <= wi(48'd0, 48'd0, 8'd0, K_FRAG, fl_info[48], fl_info[47:32],
						fl_info[31:0]);
				end
			end
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
				rot <= {23'd0, rot1} == NSU ? 8'd0 : rot1[7:0];
				if (last_id)
					cs_act <= 1'b0;
			end
			if (cs_skip || (cs_launch && wk1 == nw)) begin
				if (id_x1 != grid_x)
					id_x <= id_x1;
				else begin
					id_x <= 16'd0;
					if (id_y1 != grid_y)
						id_y <= id_y1;
					else begin
						id_y <= 16'd0;
						id_z <= id_z1;
					end
				end
			end
			if (cs_launch) begin
				for (w = 0; w < NWARPS; w = w + 1)
					if (free_slot == w[WARP_W-1:0]) begin
						st[w*3 +: 3] <= S_READY;
						info[w*160 +: 160] <= wi({id_z, id_y, id_x}, {grid_z, grid_y, grid_x},
							{wk[2:0], 5'd0}, K_COMP, 1'b0, 16'd0, cmask);
					end
				pc[(free_slot)*16 +: 16] <= 16'd0;
				tag[(free_slot)*4 +: 4] <= wg_tag;
				wk <= wk1;
				if (wk1 == nw) begin
					launching <= 1'b0;
					wg_tag <= tag1;
				end
			end
		end
	end

	wire unused_ok = &{1'b0, fl_info[63:49], wk[3], lanes[23:16], nw_full, wlanes[31:5], c, rot1[8],
		(NSU != 0)};
endmodule

`default_nettype wire
