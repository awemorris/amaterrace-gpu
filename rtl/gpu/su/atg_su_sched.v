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
 * Implemented in WS288 p008.  The behaviour, and where it differs from
 * the design: spec/gpu/su/atg_su_sched.md (§10 Status).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_sched #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter NSU = 1,	/* Number of SUs (compute workgroups are shared out: this SU takes wg_id % NSU == SU_INDEX) */
	parameter SU_INDEX = 0,	/* This SU's number */
	parameter FRAG_RESERVE = 1	/* Slots kept for fragment warps (design §3.8; KC705 2) */
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
	localparam [2:0] S_FREE = 3'd0, S_ALLOC = 3'd1, S_READY = 3'd2, S_FETCH = 3'd3,
		S_WC = 3'd4, S_REPLAY = 3'd5, S_BAR = 3'd6, S_ENDED = 3'd7;
	localparam [1:0] K_VERT = 2'd0, K_FRAG = 2'd1, K_COMP = 2'd2;

	/* STATE: program bases, WG_SIZE, the DISPATCH grid. */
	reg [31:0] vs_base, fs_base, cs_base;
	reg [7:0] wg_x, wg_y, wg_z;
	reg [15:0] grid_x, grid_y, grid_z;
	always @(posedge clk) begin
		if (!rst_n) begin
			vs_base <= 32'd0;
			fs_base <= 32'd0;
			cs_base <= 32'd0;
			wg_x <= 8'd1;
			wg_y <= 8'd1;
			wg_z <= 8'd1;
			grid_x <= 16'd1;
			grid_y <= 16'd1;
			grid_z <= 16'd1;
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

	function wq;
		input [WARP_W-1:0] x;
		input integer y;
		wq = {{(32-WARP_W){1'b0}}, x} == y;
	endfunction

	/* Per slot. */
	reg [NWARPS*3-1:0] st;
	reg [NWARPS*16-1:0] pc;
	reg [NWARPS*2-1:0] gap;
	reg [NWARPS*160-1:0] info;
	reg [NWARPS*4-1:0] tag;	/* workgroup of a compute warp (barriers) */

	/* Compute launch: the next workgroup id, its warps, and whose it is. */
	reg cs_act;
	reg [15:0] id_x, id_y, id_z;
	reg [7:0] rot;	/* linear id % NSU */
	reg [3:0] wg_tag;
	reg [3:0] wk;	/* next warp of the workgroup being launched */
	reg launching;
	wire [23:0] lanes = {16'd0, wg_x} * {16'd0, wg_y} * {16'd0, wg_z};
	wire [23:0] nw_full = (lanes + 24'd31) >> 5;
	wire [3:0] nw = nw_full > NWARPS ? NWARPS[3:0] : nw_full[3:0];
	wire mine_wg = {24'd0, rot} == SU_INDEX;
	wire last_id = id_x + 16'd1 == grid_x && id_y + 16'd1 == grid_y && id_z + 16'd1 == grid_z;

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
	wire [31:0] wlanes = {8'd0, lanes} - {23'd0, wk, 5'd0};
	wire [31:0] cmask = wlanes >= 32 ? 32'hFFFFFFFF : (32'd1 << wlanes[4:0]) - 32'd1;
	wire cs_launch = launching && !vl_go && !fl_go && any_free;
	assign init_valid = vl_go || fl_go || cs_launch;
	assign init_warp = vl_go ? vl_s : fl_go ? fl_s : free_slot;
	assign init_mask = vl_go ? vl_mask : fl_go ? fl_mask : cmask;

	/* Selection: round-robin over ready slots out of their gap. */
	reg [WARP_W-1:0] rr, sel;
	reg sel_v;
	integer k, c;
	always @(*) begin
		sel_v = 1'b0;
		sel = {WARP_W{1'b0}};
		for (k = NWARPS - 1; k >= 0; k = k - 1) begin
			c = ({{(32-WARP_W){1'b0}}, rr} + k) % NWARPS;
			if (st[(c)*3 +: 3] == S_READY && gap[(c)*2 +: 2] == 2'd0) begin
				sel_v = 1'b1;
				sel = c[WARP_W-1:0];
			end
		end
	end
	/* A fetch that is not taken keeps its warp (valid/ready). */
	reg hold_v;
	reg [WARP_W-1:0] hold_w;
	wire [WARP_W-1:0] fsel = hold_v ? hold_w : sel;
	wire fsel_v = hold_v || sel_v;
	wire [1:0] sk = info[(fsel)*160 + ATG_WI_KIND +: 2];
	wire [31:0] base = sk == K_VERT ? vs_base : sk == K_FRAG ? fs_base : cs_base;
	assign f_valid = fsel_v;
	assign f_warp = fsel;
	assign f_pc = pc[(fsel)*16 +: 16];
	assign f_addr = base + {13'd0, pc[(fsel)*16 +: 16], 3'd0};
	assign q_info = info[(q_warp)*160 +: 160];

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
			for (w = 0; w < NWARPS; w = w + 1) begin
				st[(w)*3 +: 3] <= S_FREE;
				pc[(w)*16 +: 16] <= 16'd0;
				gap[(w)*2 +: 2] <= 2'd0;
				info[(w)*160 +: 160] <= 160'd0;
				tag[(w)*4 +: 4] <= 4'd0;
			end
			rr <= {WARP_W{1'b0}};
			hold_v <= 1'b0;
			hold_w <= {WARP_W{1'b0}};
			vl_wait <= 1'b0;
			fl_wait <= 1'b0;
			vl_s <= {WARP_W{1'b0}};
			fl_s <= {WARP_W{1'b0}};
			cs_act <= 1'b0;
			launching <= 1'b0;
			id_x <= 16'd0;
			id_y <= 16'd0;
			id_z <= 16'd0;
			rot <= 8'd0;
			wg_tag <= 4'd0;
			wk <= 4'd0;
		end else begin
			for (w = 0; w < NWARPS; w = w + 1) begin
				if (gap[(w)*2 +: 2] != 2'd0)
					gap[(w)*2 +: 2] <= gap[(w)*2 +: 2] - 2'd1;
				/* Feedback and warp control. */
				case (st[(w)*3 +: 3])
				S_FETCH:
					if (fb_valid && wq(fb_warp, w)) begin
						if (fb_kind == 2'd0) begin
							st[(w)*3 +: 3] <= S_READY;
							pc[(w)*16 +: 16] <= pc[(w)*16 +: 16] + 16'd1;
						end else if (fb_kind == 2'd1)
							st[(w)*3 +: 3] <= S_WC;
						else
							st[(w)*3 +: 3] <= wake[w] ? S_READY : S_REPLAY;
					end
				S_REPLAY:
					if (wake[w])
						st[(w)*3 +: 3] <= S_READY;
				S_WC:
					if (wc_valid && wq(wc_warp, w)) begin
						pc[(w)*16 +: 16] <= wc_pc;
						st[(w)*3 +: 3] <= wc_op == 2'd1 ? S_ENDED : wc_op == 2'd2 ? S_BAR : S_READY;
					end
				S_BAR:
					if (bar_go[w])
						st[(w)*3 +: 3] <= S_READY;
				S_ENDED:
					if (xr_valid && wq(xr_warp, w))
						st[(w)*3 +: 3] <= S_FREE;
				default: ;
				endcase
			end
			hold_v <= fsel_v && !f_ready;
			hold_w <= fsel;
			if (fsel_v && f_ready) begin
				st[(fsel)*3 +: 3] <= S_FETCH;
				gap[(fsel)*2 +: 2] <= G[1:0] - 2'd1;
				rr <= fsel + 1'b1;
			end
			/* Vertex and fragment slots. */
			if (vl_g) begin
				st[(free_slot)*3 +: 3] <= S_ALLOC;
				vl_s <= free_slot;
				vl_wait <= 1'b1;
			end
			if (fl_g) begin
				st[(free_slot)*3 +: 3] <= S_ALLOC;
				fl_s <= free_slot;
				fl_wait <= 1'b1;
			end
			if (vl_go) begin
				vl_wait <= 1'b0;
				st[(vl_s)*3 +: 3] <= S_READY;
				pc[(vl_s)*16 +: 16] <= 16'd0;
				info[(vl_s)*160 +: 160] <= wi(48'd0, 48'd0, 8'd0, K_VERT, 1'b0, 16'd0, vl_mask);
			end
			if (fl_go) begin
				fl_wait <= 1'b0;
				st[(fl_s)*3 +: 3] <= S_READY;
				pc[(fl_s)*16 +: 16] <= 16'd0;
				info[(fl_s)*160 +: 160] <= wi(48'd0, 48'd0, 8'd0, K_FRAG, fl_info[48], fl_info[47:32],
					fl_info[31:0]);
			end
			/* Compute. */
			if (cs_kick && !cs_act) begin
				cs_act <= 1'b1;
				id_x <= 16'd0;
				id_y <= 16'd0;
				id_z <= 16'd0;
				rot <= 8'd0;
			end
			if (cs_try) begin
				launching <= 1'b1;
				wk <= 4'd0;
			end
			if (cs_try || cs_skip) begin
				rot <= {24'd0, rot} + 1 == NSU ? 8'd0 : rot + 8'd1;
				if (last_id)
					cs_act <= 1'b0;
			end
			if (cs_skip || (cs_launch && wk + 4'd1 == nw)) begin
				if (id_x + 16'd1 != grid_x)
					id_x <= id_x + 16'd1;
				else begin
					id_x <= 16'd0;
					if (id_y + 16'd1 != grid_y)
						id_y <= id_y + 16'd1;
					else begin
						id_y <= 16'd0;
						id_z <= id_z + 16'd1;
					end
				end
			end
			if (cs_launch) begin
				st[(free_slot)*3 +: 3] <= S_READY;
				pc[(free_slot)*16 +: 16] <= 16'd0;
				tag[(free_slot)*4 +: 4] <= wg_tag;
				info[(free_slot)*160 +: 160] <= wi({id_z, id_y, id_x}, {grid_z, grid_y, grid_x},
					{wk[2:0], 5'd0}, K_COMP, 1'b0, 16'd0, cmask);
				wk <= wk + 4'd1;
				if (wk + 4'd1 == nw) begin
					launching <= 1'b0;
					wg_tag <= wg_tag + 4'd1;
				end
			end
		end
	end

	wire unused_ok = &{1'b0, fl_info[63:49], wk[3], lanes[23:16], nw_full, wlanes[31:5], c, (NSU != 0)};
endmodule

`default_nettype wire
