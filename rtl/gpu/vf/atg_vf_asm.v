/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_asm: VF warp and primitive assembly: packs vertices into 32-lane
 * vertex warps (one SU slot and 32 PT entries each), starts the warps, and
 * builds the primitive list (points, lines, strips, fans, triangles,
 * restart) as PT entries for the RX, with last-use flags.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_asm (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* Index stream (atg_vf_index → atg_vf_asm) */
	input wire iv_valid,
	output wire iv_ready,
	input wire [31:0] iv_index,
	input wire [31:0] iv_inst,
	input wire iv_restart,
	input wire iv_last,
	/* Vertices of a warp (atg_vf_asm → atg_vf_fetch) */
	output reg vb_valid,
	input wire vb_ready,
	output reg [31:0] vb_index,
	output reg [31:0] vb_inst,
	output reg [4:0] vb_lane,
	output reg vb_last,
	input wire conv_done,
	/* Vertex warps to the SU (atg_su vl_*) */
	output wire vl_req,
	input wire vl_gnt,
	input wire [7:0] vl_ptbase,
	output reg vl_go,
	output reg [31:0] vl_mask,
	/* Primitives to the RX */
	output wire prim_valid,
	input wire prim_ready,
	output wire [25:0] prim_vtx,	/* [25:24] kind: 0 point, 1 line, 2 triangle */
	output wire [2:0] prim_free,
	output wire prim_last,
	output wire busy
);
	`include "ghci_regs.vh"

	/* Named synchronous reset net so asic-lint excludes it from data fanout checks */
	(* keep = "true" *) wire rst_sync = !rst_n;

	/* STATE: TOPOLOGY 0x020, INDEX_FORMAT 0x022, VERTEX_OFFSET 0x028, PROVOKING 0x05D. */
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [2:0] s_topo_0;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [2:0] s_topo_1;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [2:0] s_topo_2;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [2:0] s_topo_3;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [2:0] s_topo_4;
	reg s_ind;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg s_last_0;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg s_last_1;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg s_last_2;
	reg [31:0] s_voff;

	wire we_topo = st_we && (st_idx == GHCI_S_TOPOLOGY);
	wire we_ifmt = st_we && (st_idx == GHCI_S_INDEX_FORMAT);
	wire we_voff = st_we && (st_idx == GHCI_S_VERTEX_OFFSET);
	wire we_prov = st_we && (st_idx == GHCI_S_PROVOKING);

	wire [1:0] we_voff_b;
	wire [1:0] s_ind_b;

	genvar gb;
	generate
		for (gb = 0; gb < 2; gb = gb + 1) begin : g_st_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_vo (.O(we_voff_b[gb]), .I0(we_voff));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_si (.O(s_ind_b[gb]),   .I0(s_ind));
`else
			assign we_voff_b[gb] = we_voff;
			assign s_ind_b[gb]   = s_ind;
`endif
		end
	endgenerate

	always @(posedge clk) begin
		if (rst_sync) begin
			s_topo_0 <= 3'd0;
			s_topo_1 <= 3'd0;
			s_topo_2 <= 3'd0;
			s_topo_3 <= 3'd0;
			s_topo_4 <= 3'd0;
			s_ind <= 1'b0;
			s_voff <= 32'd0;
			s_last_0 <= 1'b0;
			s_last_1 <= 1'b0;
			s_last_2 <= 1'b0;
		end else begin
			if (we_topo) begin
				s_topo_0 <= st_wdata[2:0];
				s_topo_1 <= st_wdata[2:0];
				s_topo_2 <= st_wdata[2:0];
				s_topo_3 <= st_wdata[2:0];
				s_topo_4 <= st_wdata[2:0];
			end
			if (we_ifmt)       s_ind         <= st_wdata[1:0] != 2'd0;
			if (we_voff_b[0])  s_voff[15:0]  <= st_wdata[15:0];
			if (we_voff_b[1])  s_voff[31:16] <= st_wdata[31:16];
			if (we_prov) begin
				s_last_0 <= st_wdata[0];
				s_last_1 <= st_wdata[0];
				s_last_2 <= st_wdata[0];
			end
		end
	end

	/*
	 * 2-entry input skid buffer (sk0, sk1) on iv_* followed by 1-entry
	 * pre-added vertex stage (in_*).
	 * iv_ready = !sk1_v (0 combinational paths from any input or ready port).
	 */
	reg sk0_v, sk1_v;
	reg [31:0] sk0_idx, sk0_inst;
	reg sk0_rst, sk0_last;
	reg [31:0] sk1_idx, sk1_inst;
	reg sk1_rst, sk1_last;

	reg in_v;
	reg [31:0] in_vidx, in_inst;
	reg in_rst, in_last;
	reg in_inst_ne;

	assign iv_ready = !sk1_v;

	wire sk_pop = sk0_v && !in_v;
	wire ce_sk0 = (!sk0_v && iv_valid) || (sk_pop && (sk1_v || iv_valid));
	wire ce_sk1 = sk0_v && !sk_pop && !sk1_v && iv_valid;
	wire ce_in  = sk0_v && !in_v;

	wire [1:0] ce_sk0_idx_b, ce_sk0_inst_b, sel_sk0_idx_b, sel_sk0_inst_b;
	wire [1:0] ce_sk1_idx_b, ce_sk1_inst_b;
	wire [1:0] ce_in_idx_b, ce_in_inst_b;
	generate
		for (gb = 0; gb < 2; gb = gb + 1) begin : g_sk_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_c0i (.O(ce_sk0_idx_b[gb]),   .I0(ce_sk0));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_c0n (.O(ce_sk0_inst_b[gb]),  .I0(ce_sk0));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_s0i (.O(sel_sk0_idx_b[gb]),  .I0(sk1_v));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_s0n (.O(sel_sk0_inst_b[gb]), .I0(sk1_v));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_c1i (.O(ce_sk1_idx_b[gb]),   .I0(ce_sk1));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_c1n (.O(ce_sk1_inst_b[gb]),  .I0(ce_sk1));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_cii (.O(ce_in_idx_b[gb]),    .I0(ce_in));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_cin (.O(ce_in_inst_b[gb]),   .I0(ce_in));
`else
			assign ce_sk0_idx_b[gb]   = ce_sk0;
			assign ce_sk0_inst_b[gb]  = ce_sk0;
			assign sel_sk0_idx_b[gb]  = sk1_v;
			assign sel_sk0_inst_b[gb] = sk1_v;
			assign ce_sk1_idx_b[gb]   = ce_sk1;
			assign ce_sk1_inst_b[gb]  = ce_sk1;
			assign ce_in_idx_b[gb]    = ce_in;
			assign ce_in_inst_b[gb]   = ce_in;
`endif
		end
	endgenerate

	wire [31:0] v_off;
	wire vo_co_unused;
	am_add #(.W(32)) u_voff (.a(sk0_idx), .b(s_voff), .ci(1'b0), .s(v_off), .co(vo_co_unused));

	/* TOPOLOGY: 0 points, 1 lines, 2 line strip, 3 triangles, 4 strip, 5 fan
	 * (6, 7 reserved: points). */
	localparam [2:0] T_LINES = 3'd1, T_LSTRIP = 3'd2, T_TRIS = 3'd3, T_STRIP = 3'd4,
		T_FAN = 3'd5;

	/* One-hot FSM state registers */
	reg st_is_idle;
	reg st_is_next;
	reg st_is_alloc;
	reg st_is_send;
	reg st_is_close;
	reg st_is_wait;
	reg st_is_go;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg st_is_prims;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg st_is_prims_1;
	reg fin;	/* this warp is the draw's last */

	/* Assembly: up to two earlier vertices of the open primitive, strip or fan
	 * (A older, or the fan's centre; B newer), their lanes in this warp. */
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [1:0] cnt_0;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [1:0] cnt_1;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [1:0] cnt_2;
	reg [31:0] a_idx, a_inst, b_idx, b_inst, cur_inst;
	reg [4:0] a_lane, b_lane;
	reg par;	/* strip: odd triangle */

	/* Precomputed 32-bit inequality sk0_inst != cur_inst (3 LUT levels into FF in_inst_ne) */
	(* keep = "true" *) wire [10:0] sk_ne_p;
	generate
		for (gb = 0; gb < 10; gb = gb + 1) begin : g_skne_p
			assign sk_ne_p[gb] = (sk0_inst[3*gb +: 3] != cur_inst[3*gb +: 3]);
		end
	endgenerate
	assign sk_ne_p[10] = (sk0_inst[31:30] != cur_inst[31:30]);
	(* keep = "true" *) wire sk_ne_lo = |sk_ne_p[5:0];
	(* keep = "true" *) wire sk_ne_hi = |sk_ne_p[10:6];
	wire sk_inst_ne = sk_ne_lo || sk_ne_hi;

	/* The warp. */
	reg [5:0] lane;	/* next lane, 0..32 */
	wire [1:0] lane0_b;
	reg lane_early_r;
	reg lane_is31_r;
	reg [31:0] used;	/* lanes used by a primitive */
	reg u_add_v;		/* 1-cycle delayed pulse to OR p_l lanes into used */
	reg [7:0] ptbase;
	reg [1:0] carry;	/* carried vertices still to send */
	reg carry_z;
	reg sg_v;	/* the vertex held back from vb */
	reg [31:0] sg_idx, sg_inst;
	reg [4:0] sg_lane;

`ifdef SYNTH_KINTEX7
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_l0_0 (.O(lane0_b[0]), .I0(lane[0]));
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_l0_1 (.O(lane0_b[1]), .I0(lane[0]));
`else
	assign lane0_b[0] = lane[0];
	assign lane0_b[1] = lane[0];
`endif

	/* The open primitive (its free flags not final) and the warp's list. */
	reg p_v;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [14:0] p_l_0;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [14:0] p_l_1;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [14:0] p_l_2;
	reg [2:0] p_fa, p_fl;
	reg [8:0] f_mem_lo [0:31];
	reg [8:0] f_mem_hi [0:31];
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [4:0] f_wp_0;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [4:0] f_wp_1;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [4:0] f_wp_c;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [4:0] f_rp_0;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [4:0] f_rp_1;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [4:0] f_rp_c;
	reg [5:0] f_n;
	/* The primitive offered to the RX. */
	reg h_v;
	reg [23:0] h_vtx;
	reg [2:0] h_free;

	/* The new primitive when vertex V goes to lane L (g_*); lanes s0..s2. */
	wire [4:0] L = {lane[4:1], lane0_b[0]};
	wire [4:0] L_g0, L_g1;
	generate
		for (gb = 0; gb < 5; gb = gb + 1) begin : g_l_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_lg0 (.O(L_g0[gb]), .I0(L[gb]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_lg1 (.O(L_g1[gb]), .I0(L[gb]));
`else
			assign L_g0[gb] = L[gb];
			assign L_g1[gb] = L[gb];
`endif
		end
	endgenerate
	wire [1:0] cnt_inc;
	wire ci_co_unused;
	am_add #(.W(2)) u_cnt (.a(cnt_0), .b(2'd0), .ci(1'b1), .s(cnt_inc), .co(ci_co_unused));

	/*
	 * When a primitive is emitted (ce_pl_b), g0/g1/g2 each select from {a_lane, b_lane, L}.
	 * Because emission only occurs when the primitive is complete (cnt != 0 for lines,
	 * cnt == 2 for tris/strip/fan), the mux selects depend ONLY on 5 FF bits:
	 * s_topo_0[2:0], s_last_0, and par (1 LUT5 each, fanout 5 each).
	 */
	(* keep = "true" *) wire g0_sel_a = !s_last_0 &&
		(s_topo_0 == T_LINES || s_topo_0 == T_LSTRIP || s_topo_0 == T_TRIS || s_topo_0 == T_STRIP);
	(* keep = "true" *) wire g0_sel_b = !s_last_0 && (s_topo_0 == T_FAN);

	(* keep = "true" *) wire g1_sel_a = s_last_0 &&
		(s_topo_0 == T_LINES || s_topo_0 == T_LSTRIP || s_topo_0 == T_TRIS ||
		 (s_topo_0 == T_STRIP && !par) || s_topo_0 == T_FAN);
	(* keep = "true" *) wire g1_sel_b =
		(s_topo_0 == T_TRIS && !s_last_0) ||
		(s_topo_0 == T_STRIP && (s_last_0 ? par : !par));

	(* keep = "true" *) wire g2_sel_a =
		((s_topo_0 == T_LINES || s_topo_0 == T_LSTRIP) && s_last_0) ||
		(s_topo_0 == T_STRIP && s_last_0 && par) ||
		(s_topo_0 == T_FAN && !s_last_0);
	(* keep = "true" *) wire g2_sel_b =
		(s_topo_0 == T_TRIS && s_last_0) ||
		(s_topo_0 == T_STRIP && (s_last_0 ^ par)) ||
		(s_topo_0 == T_FAN && s_last_0);

	(* keep = "true" *) wire [4:0] g0 = g0_sel_a ? a_lane : (g0_sel_b ? b_lane : L_g0);
	(* keep = "true" *) wire [4:0] g1 = g1_sel_a ? a_lane : (g1_sel_b ? b_lane : L_g0);
	(* keep = "true" *) wire [4:0] g2 = g2_sel_a ? a_lane : (g2_sel_b ? b_lane : L_g1);
	(* keep = "true" *) wire [14:0] g_l_w = {g2, g1, g0};

	(* keep = "true" *) wire [1:0] g_cnt =
		(s_topo_1 == T_LINES)  ? {1'b0, cnt_0 == 2'd0} :
		(s_topo_1 == T_LSTRIP) ? 2'd1 :
		(s_topo_1 == T_TRIS)   ? (cnt_0 == 2'd2 ? 2'd0 : cnt_inc) :
		(s_topo_1 == T_STRIP || s_topo_1 == T_FAN) ? (cnt_0 == 2'd0 ? 2'd1 : 2'd2) :
		2'd0;

	/* Direct 1-LUT decode from FFs s_topo_2 and cnt_2 */
	(* keep = "true" *) wire g_wa_w = (s_topo_2 == T_LINES && cnt_2 == 2'd0) ||
		(s_topo_2 == T_LSTRIP) ||
		((s_topo_2 == T_TRIS || s_topo_2 == T_STRIP || s_topo_2 == T_FAN) && cnt_2 == 2'd0);
	(* keep = "true" *) wire g_wa_sh_w = (s_topo_2 == T_LINES && cnt_2 == 2'd0) ||
		(s_topo_2 == T_LSTRIP) ||
		(s_topo_2 == T_TRIS && cnt_2 == 2'd0) ||
		(s_topo_2 == T_STRIP && (cnt_2 == 2'd0 || cnt_2 == 2'd2)) ||
		(s_topo_2 == T_FAN && cnt_2 == 2'd0);
	(* keep = "true" *) wire g_wb_w = (s_topo_2 == T_TRIS && cnt_2 == 2'd1) ||
		((s_topo_2 == T_STRIP || s_topo_2 == T_FAN) && cnt_2 != 2'd0);
	(* keep = "true" *) wire g_emit_w = (s_topo_2 == T_LINES && cnt_2 != 2'd0) ||
		(s_topo_2 == T_LSTRIP && cnt_2 != 2'd0) ||
		((s_topo_2 == T_TRIS || s_topo_2 == T_STRIP || s_topo_2 == T_FAN) && cnt_2 == 2'd2) ||
		(s_topo_2 != T_LINES && s_topo_2 != T_LSTRIP && s_topo_2 != T_TRIS && s_topo_2 != T_STRIP && s_topo_2 != T_FAN);

	(* keep = "true" *) wire [2:0] g_fa_w =
		(s_topo_3 == T_LINES)  ? 3'b011 :
		(s_topo_3 == T_LSTRIP) ? (s_last_2 ? 3'b010 : 3'b001) :
		(s_topo_3 == T_TRIS)   ? 3'b111 :
		(s_topo_3 == T_STRIP)  ? (!s_last_2 ? 3'b001 : (par ? 3'b100 : 3'b010)) :
		(s_topo_3 == T_FAN)    ? (s_last_2 ? 3'b100 : 3'b001) :
		3'b001;
	(* keep = "true" *) wire [2:0] g_fl_w =
		(s_topo_3 == T_LSTRIP) ? (s_last_2 ? 3'b001 : 3'b010) :
		(s_topo_3 == T_STRIP)  ? (!s_last_2 ? 3'b110 : (par ? 3'b011 : 3'b101)) :
		(s_topo_3 == T_FAN)    ? (s_last_2 ? 3'b011 : 3'b110) :
		3'b000;

	/* SEND: what happens to the item on in_*. */
	wire vfree = !vb_valid || vb_ready;
	wire inst_chg = in_inst_ne && (cnt_2 != 2'd0);
	wire early = lane_early_r && (cnt_2 == 2'd0);
	wire c_put = st_is_send && vfree && !carry_z;
	(* keep = "true" *) wire s_go = st_is_send && vfree && carry_z && in_v;
	wire s_rst = s_go && in_rst;
	(* keep = "true" *) wire s_put = s_go && !in_rst && !inst_chg && !early;
	wire n_rst = st_is_next && in_v && in_rst;
	wire in_take = s_rst || s_put || n_rst;
	wire seg_end = s_rst || (s_go && !in_rst && inst_chg);

	assign vl_req = st_is_alloc;
	assign busy = !st_is_idle || sk0_v || sk1_v || in_v;
	assign prim_valid = h_v && st_is_prims_1 && (f_n != 6'd0 || fin);
	/* The kind from TOPOLOGY (its SET_REG waits while the VF is busy). */
	wire [1:0] p_kind = s_topo_3 == T_LINES || s_topo_3 == T_LSTRIP ? 2'd1 :
		s_topo_3 == T_TRIS || s_topo_3 == T_STRIP || s_topo_3 == T_FAN ? 2'd2 : 2'd0;
	assign prim_vtx = {p_kind, h_vtx};
	assign prim_free = h_free;
	assign prim_last = fin && f_n == 6'd0;
	wire h_take = prim_valid && prim_ready;
	wire [17:0] f_top = {f_mem_hi[f_rp_1], f_mem_lo[f_rp_0]};

	/* Push the open primitive: superseded (fa) or final (fa | fl). */
	(* keep = "true" *) wire send_push_cond = in_rst || inst_chg || (!early && g_emit_w);
	(* keep = "true" *) wire p_push_raw = p_v && ((s_go && send_push_cond) || (st_is_close && vfree));
	wire p_final = seg_end || st_is_close;
	wire [2:0] p_push_b;
	generate
		for (gb = 0; gb < 3; gb = gb + 1) begin : g_ppush_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_pp (.O(p_push_b[gb]), .I0(p_push_raw));
`else
			assign p_push_b[gb] = p_push_raw;
`endif
		end
	endgenerate

	wire f_pop = st_is_prims_1 && f_n != 6'd0 && (!h_v || h_take);
	(* keep = "true" *) wire ce_fn = p_push_raw || f_pop;
	wire [4:0] f_wp_next;
	wire [4:0] f_rp_next;
	wire [5:0] f_n_inc;
	wire [5:0] f_n_dec;
	wire [5:0] lane_next;
	wire [1:0] carry_next;
	wire fw_co_unused, fr_co_unused, fni_co_unused, fnd_bo_unused, ln_co_unused, cy_bo_unused;
	am_add #(.W(5)) u_f_wp (.a(f_wp_c), .b(5'd0), .ci(1'b1), .s(f_wp_next), .co(fw_co_unused));
	am_add #(.W(5)) u_f_rp (.a(f_rp_c), .b(5'd0), .ci(1'b1), .s(f_rp_next), .co(fr_co_unused));
	am_add #(.W(6)) u_fn_inc (.a(f_n), .b(6'd0), .ci(1'b1), .s(f_n_inc), .co(fni_co_unused));
	am_sub #(.W(6)) u_fn_dec (.a(f_n), .b(6'd0), .bi(1'b1), .d(f_n_dec), .bo(fnd_bo_unused));
	am_add #(.W(6)) u_lane (.a(lane), .b(6'd0), .ci(1'b1), .s(lane_next), .co(ln_co_unused));
	am_sub #(.W(2)) u_carry (.a(carry), .b(2'd0), .bi(1'b1), .d(carry_next), .bo(cy_bo_unused));

	/* Decode p_l (registered!) into 32 lane-use bits in 2 LUT levels */
	wire [31:0] pl_used;
	generate
		for (gb = 0; gb < 16; gb = gb + 1) begin : g_pl_used_lo
			(* keep = "true" *) wire m0 = (p_l_0[4:0]   == gb[4:0]);
			(* keep = "true" *) wire m1 = (p_l_0[9:5]   == gb[4:0]);
			(* keep = "true" *) wire m2 = (p_l_0[14:10] == gb[4:0]);
			assign pl_used[gb] = m0 || m1 || m2;
		end
		for (gb = 16; gb < 32; gb = gb + 1) begin : g_pl_used_hi
			(* keep = "true" *) wire m0 = (p_l_1[4:0]   == gb[4:0]);
			(* keep = "true" *) wire m1 = (p_l_1[9:5]   == gb[4:0]);
			(* keep = "true" *) wire m2 = (p_l_1[14:10] == gb[4:0]);
			assign pl_used[gb] = m0 || m1 || m2;
		end
	endgenerate

	wire [7:0] pt0;
	wire [7:0] pt1;
	wire [7:0] pt2;
	wire p0_co_unused, p1_co_unused, p2_co_unused;
	am_add #(.W(8)) u_pt0 (.a(ptbase), .b({3'd0, f_top[4:0]}), .ci(1'b0),
		.s(pt0), .co(p0_co_unused));
	am_add #(.W(8)) u_pt1 (.a(ptbase), .b({3'd0, f_top[9:5]}), .ci(1'b0),
		.s(pt1), .co(p1_co_unused));
	am_add #(.W(8)) u_pt2 (.a(ptbase), .b({3'd0, f_top[14:10]}), .ci(1'b0),
		.s(pt2), .co(p2_co_unused));

	/* Low-depth (<= 3 LUTs), fanout-buffered CEs and mux selects */
	wire ce_step = c_put || s_put;
	wire ce_vb_all = ce_step || (st_is_close && vfree);
	wire alloc_gnt = st_is_alloc && vl_gnt;
	wire ce_used_all = alloc_gnt || u_add_v;
	wire ce_vlmask_all = st_is_wait && conv_done;
	wire ce_hvtx_all = f_pop;
	(* keep = "true" *) wire ce_p_emit = s_put && g_emit_w;
	(* keep = "true" *) wire ce_a_lane = (st_is_close && vfree) || (s_put && g_wa_sh_w);
	(* keep = "true" *) wire ce_b_lane = (st_is_close && vfree) || (s_put && g_wb_w);

	wire [1:0] ce_vb_idx_b, ce_vb_inst_b;
	wire [1:0] ce_sg_idx_b, ce_sg_inst_b, sel_cput_idx_b, sel_cput_inst_b, sel_l0_idx_b, sel_l0_inst_b;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) wire [1:0] ce_a_idx_b;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) wire [1:0] ce_a_inst_b;
	wire [1:0] sel_gwa_idx_b, sel_gwa_inst_b;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) wire [1:0] ce_b_idx_b;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) wire [1:0] ce_b_inst_b;
	wire [1:0] ce_cur_inst_b;
	wire [1:0] ce_used_b, sel_used_clr_b;
	wire [1:0] ce_vlmask_b;
	wire [1:0] ce_hvtx_b;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) wire [2:0] ce_pl_b;

	generate
		for (gb = 0; gb < 3; gb = gb + 1) begin : g_pl_ce
			assign ce_pl_b[gb] = s_put && g_emit_w;
		end
		for (gb = 0; gb < 2; gb = gb + 1) begin : g_dp_buf
			assign ce_a_idx_b[gb]  = s_put && g_wa_sh_w;
			assign ce_a_inst_b[gb] = s_put && g_wa_sh_w;
			assign ce_b_idx_b[gb]  = s_put && g_wb_w;
			assign ce_b_inst_b[gb] = s_put && g_wb_w;
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_vbi (.O(ce_vb_idx_b[gb]),     .I0(ce_vb_all));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_vbn (.O(ce_vb_inst_b[gb]),    .I0(ce_vb_all));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_sgi (.O(ce_sg_idx_b[gb]),     .I0(ce_step));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_sgn (.O(ce_sg_inst_b[gb]),    .I0(ce_step));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_sci (.O(sel_cput_idx_b[gb]),  .I0(c_put));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_scn (.O(sel_cput_inst_b[gb]), .I0(c_put));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_sli (.O(sel_l0_idx_b[gb]),    .I0(lane0_b[1]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_sln (.O(sel_l0_inst_b[gb]),   .I0(lane0_b[1]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_gwi (.O(sel_gwa_idx_b[gb]),   .I0(g_wa_w));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_gwn (.O(sel_gwa_inst_b[gb]),  .I0(g_wa_w));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_ci  (.O(ce_cur_inst_b[gb]),   .I0(s_put));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_us  (.O(ce_used_b[gb]),       .I0(ce_used_all));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_usc (.O(sel_used_clr_b[gb]),  .I0(alloc_gnt));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_vlm (.O(ce_vlmask_b[gb]),     .I0(ce_vlmask_all));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_hvx (.O(ce_hvtx_b[gb]),       .I0(ce_hvtx_all));
`else
			assign ce_vb_idx_b[gb]     = ce_vb_all;
			assign ce_vb_inst_b[gb]    = ce_vb_all;
			assign ce_sg_idx_b[gb]     = ce_step;
			assign ce_sg_inst_b[gb]    = ce_step;
			assign sel_cput_idx_b[gb]  = c_put;
			assign sel_cput_inst_b[gb] = c_put;
			assign sel_l0_idx_b[gb]    = lane0_b[1];
			assign sel_l0_inst_b[gb]   = lane0_b[1];
			assign sel_gwa_idx_b[gb]   = g_wa_w;
			assign sel_gwa_inst_b[gb]  = g_wa_w;
			assign ce_cur_inst_b[gb]   = s_put;
			assign ce_used_b[gb]       = ce_used_all;
			assign sel_used_clr_b[gb]  = alloc_gnt;
			assign ce_vlmask_b[gb]     = ce_vlmask_all;
			assign ce_hvtx_b[gb]       = ce_hvtx_all;
`endif
		end
	endgenerate

	wire [17:0] f_wdata_ord = {p_final ? (p_fa | p_fl) : p_fa, p_l_2};
	wire [23:0] h_vtx_next = {pt2, pt1, pt0};

	always @(posedge clk) begin
		if (p_push_b[0])
			f_mem_lo[f_wp_0] <= f_wdata_ord[8:0];
		if (p_push_b[1])
			f_mem_hi[f_wp_1] <= f_wdata_ord[17:9];
	end

	always @(posedge clk) begin
		vl_go <= 1'b0;
		if (rst_sync) begin
			sk0_v <= 1'b0;
			sk1_v <= 1'b0;
			sk0_idx <= 32'd0;
			sk0_inst <= 32'd0;
			sk0_rst <= 1'b0;
			sk0_last <= 1'b0;
			sk1_idx <= 32'd0;
			sk1_inst <= 32'd0;
			sk1_rst <= 1'b0;
			sk1_last <= 1'b0;
			in_v <= 1'b0;
			in_vidx <= 32'd0;
			in_inst <= 32'd0;
			in_rst <= 1'b0;
			in_last <= 1'b0;
			in_inst_ne <= 1'b0;
			st_is_idle  <= 1'b1;
			st_is_next  <= 1'b0;
			st_is_alloc <= 1'b0;
			st_is_send  <= 1'b0;
			st_is_close <= 1'b0;
			st_is_wait  <= 1'b0;
			st_is_go    <= 1'b0;
			st_is_prims <= 1'b0;
			st_is_prims_1 <= 1'b0;
			vb_valid <= 1'b0;
			vb_index <= 32'd0;
			vb_inst <= 32'd0;
			vb_lane <= 5'd0;
			vb_last <= 1'b0;
			cnt_0 <= 2'd0;
			cnt_1 <= 2'd0;
			cnt_2 <= 2'd0;
			par <= 1'b0;
			fin <= 1'b0;
			a_idx <= 32'd0;
			a_inst <= 32'd0;
			b_idx <= 32'd0;
			b_inst <= 32'd0;
			cur_inst <= 32'd0;
			a_lane <= 5'd0;
			b_lane <= 5'd0;
			lane <= 6'd0;
			lane_early_r <= 1'b0;
			lane_is31_r <= 1'b0;
			used <= 32'd0;
			u_add_v <= 1'b0;
			ptbase <= 8'd0;
			carry <= 2'd0;
			carry_z <= 1'b1;
			sg_v <= 1'b0;
			sg_idx <= 32'd0;
			sg_inst <= 32'd0;
			sg_lane <= 5'd0;
			p_v <= 1'b0;
			p_l_0 <= 15'd0;
			p_l_1 <= 15'd0;
			p_l_2 <= 15'd0;
			p_fa <= 3'd0;
			p_fl <= 3'd0;
			h_v <= 1'b0;
			h_vtx <= 24'd0;
			h_free <= 3'd0;
			f_wp_0 <= 5'd0;
			f_wp_1 <= 5'd0;
			f_wp_c <= 5'd0;
			f_rp_0 <= 5'd0;
			f_rp_1 <= 5'd0;
			f_rp_c <= 5'd0;
			f_n <= 6'd0;
			vl_mask <= 32'd0;
		end else begin
			u_add_v <= ce_p_emit;

			/* Skid buffer sk0 / sk1 */
			if (ce_sk0_idx_b[0])  sk0_idx[15:0]   <= sel_sk0_idx_b[0]  ? sk1_idx[15:0]   : iv_index[15:0];
			if (ce_sk0_idx_b[1])  sk0_idx[31:16]  <= sel_sk0_idx_b[1]  ? sk1_idx[31:16]  : iv_index[31:16];
			if (ce_sk0_inst_b[0]) sk0_inst[15:0]  <= sel_sk0_inst_b[0] ? sk1_inst[15:0]  : iv_inst[15:0];
			if (ce_sk0_inst_b[1]) sk0_inst[31:16] <= sel_sk0_inst_b[1] ? sk1_inst[31:16] : iv_inst[31:16];
			if (ce_sk0) begin
				sk0_rst  <= sk1_v ? sk1_rst  : iv_restart;
				sk0_last <= sk1_v ? sk1_last : iv_last;
			end
			if (ce_sk1_idx_b[0])  sk1_idx[15:0]   <= iv_index[15:0];
			if (ce_sk1_idx_b[1])  sk1_idx[31:16]  <= iv_index[31:16];
			if (ce_sk1_inst_b[0]) sk1_inst[15:0]  <= iv_inst[15:0];
			if (ce_sk1_inst_b[1]) sk1_inst[31:16] <= iv_inst[31:16];
			if (ce_sk1) begin
				sk1_rst  <= iv_restart;
				sk1_last <= iv_last;
			end
			if (sk_pop) begin
				if (sk1_v) begin
					sk1_v <= 1'b0;
					sk0_v <= 1'b1;
				end else begin
					sk0_v <= iv_valid;
				end
			end else if (!sk0_v) begin
				sk0_v <= iv_valid;
			end else if (!sk1_v) begin
				sk1_v <= iv_valid;
			end

			/* Pre-added vertex stage in_* */
			if (ce_in_idx_b[0])  in_vidx[15:0]  <= s_ind_b[0] ? v_off[15:0]  : sk0_idx[15:0];
			if (ce_in_idx_b[1])  in_vidx[31:16] <= s_ind_b[1] ? v_off[31:16] : sk0_idx[31:16];
			if (ce_in_inst_b[0]) in_inst[15:0]  <= sk0_inst[15:0];
			if (ce_in_inst_b[1]) in_inst[31:16] <= sk0_inst[31:16];
			if (ce_in) begin
				in_rst     <= sk0_rst;
				in_last    <= sk0_last;
				in_inst_ne <= sk_inst_ne;
			end
			if (in_v) begin
				if (in_take)
					in_v <= 1'b0;
			end else if (sk0_v) begin
				in_v <= 1'b1;
			end

			/* Top-level datapath updates (un-nested from FSM case to keep CE <= 3 LUTs) */
			if (ce_vb_idx_b[0])  vb_index[15:0]  <= sg_idx[15:0];
			if (ce_vb_idx_b[1])  vb_index[31:16] <= sg_idx[31:16];
			if (ce_vb_inst_b[0]) vb_inst[15:0]   <= sg_inst[15:0];
			if (ce_vb_inst_b[1]) vb_inst[31:16]  <= sg_inst[31:16];
			if (ce_vb_all) begin
				vb_lane <= sg_lane;
				vb_last <= st_is_close;
			end

			if (ce_sg_idx_b[0])  sg_idx[15:0]  <= sel_cput_idx_b[0]  ? (sel_l0_idx_b[0]  ? b_idx[15:0]   : a_idx[15:0])   : in_vidx[15:0];
			if (ce_sg_idx_b[1])  sg_idx[31:16] <= sel_cput_idx_b[1]  ? (sel_l0_idx_b[1]  ? b_idx[31:16]  : a_idx[31:16])  : in_vidx[31:16];
			if (ce_sg_inst_b[0]) sg_inst[15:0] <= sel_cput_inst_b[0] ? (sel_l0_inst_b[0] ? b_inst[15:0]  : a_inst[15:0])  : in_inst[15:0];
			if (ce_sg_inst_b[1]) sg_inst[31:16] <= sel_cput_inst_b[1] ? (sel_l0_inst_b[1] ? b_inst[31:16] : a_inst[31:16]) : in_inst[31:16];

			if (ce_a_idx_b[0])   a_idx[15:0]   <= sel_gwa_idx_b[0]   ? in_vidx[15:0]  : b_idx[15:0];
			if (ce_a_idx_b[1])   a_idx[31:16]  <= sel_gwa_idx_b[1]   ? in_vidx[31:16] : b_idx[31:16];
			if (ce_a_inst_b[0])  a_inst[15:0]  <= sel_gwa_inst_b[0]  ? in_inst[15:0]  : b_inst[15:0];
			if (ce_a_inst_b[1])  a_inst[31:16] <= sel_gwa_inst_b[1]  ? in_inst[31:16] : b_inst[31:16];

			if (ce_b_idx_b[0])   b_idx[15:0]   <= in_vidx[15:0];
			if (ce_b_idx_b[1])   b_idx[31:16]  <= in_vidx[31:16];
			if (ce_b_inst_b[0])  b_inst[15:0]  <= in_inst[15:0];
			if (ce_b_inst_b[1])  b_inst[31:16] <= in_inst[31:16];

			if (ce_cur_inst_b[0]) cur_inst[15:0]  <= in_inst[15:0];
			if (ce_cur_inst_b[1]) cur_inst[31:16] <= in_inst[31:16];

			if (ce_used_b[0])    used[15:0]    <= sel_used_clr_b[0]  ? 16'd0 : (used[15:0]  | pl_used[15:0]);
			if (ce_used_b[1])    used[31:16]   <= sel_used_clr_b[1]  ? 16'd0 : (used[31:16] | pl_used[31:16]);

			if (ce_vlmask_b[0])  vl_mask[15:0]  <= used[15:0];
			if (ce_vlmask_b[1])  vl_mask[31:16] <= used[31:16];

			if (ce_hvtx_b[0])    h_vtx[11:0]   <= h_vtx_next[11:0];
			if (ce_hvtx_b[1])    h_vtx[23:12]  <= h_vtx_next[23:12];

			if (ce_pl_b[0])      p_l_0         <= g_l_w;
			if (ce_pl_b[1])      p_l_1         <= g_l_w;
			if (ce_pl_b[2])      p_l_2         <= g_l_w;
			if (ce_p_emit) begin
				p_fa <= g_fa_w;
				p_fl <= g_fl_w;
			end

			if (ce_a_lane)       a_lane        <= st_is_close ? 5'd0 : (g_wa_w ? L : b_lane);
			if (ce_b_lane)       b_lane        <= st_is_close ? 5'd1 : L;

			if (ce_vb_all)
				vb_valid <= st_is_close ? 1'b1 : sg_v;
			else if (vb_valid && vb_ready)
				vb_valid <= 1'b0;

			if (st_is_close && vfree)
				sg_v <= 1'b0;
			else if (ce_step) begin
				sg_v <= 1'b1;
				sg_lane <= L;
			end

			if (alloc_gnt) begin
				ptbase <= vl_ptbase;
				lane <= 6'd0;
				lane_early_r <= 1'b0;
				lane_is31_r <= 1'b0;
				carry <= cnt_2;
				carry_z <= (cnt_2 == 2'd0);
			end else if (ce_step) begin
				lane <= lane_next;
				lane_is31_r <= (lane == 6'd30);
				lane_early_r <= (s_topo_3 == T_LINES && lane >= 6'd30) ||
					(s_topo_3 == T_TRIS && lane >= 6'd29);
				if (c_put) begin
					carry <= carry_next;
					carry_z <= (carry == 2'd1);
				end
			end

			if (p_push_b[2]) begin
				f_wp_0 <= f_wp_next;
				f_wp_1 <= f_wp_next;
				f_wp_c <= f_wp_next;
			end
			if (ce_fn)
				f_n <= st_is_prims_1 ? f_n_dec : f_n_inc;

			if (seg_end || (st_is_close && vfree))
				p_v <= 1'b0;
			else if (ce_p_emit)
				p_v <= 1'b1;

			if (seg_end) begin
				cnt_0 <= 2'd0;
				cnt_1 <= 2'd0;
				cnt_2 <= 2'd0;
				par <= 1'b0;
			end else if (s_put) begin
				cnt_0 <= g_cnt;
				cnt_1 <= g_cnt;
				cnt_2 <= g_cnt;
				if (s_topo_1 == T_STRIP && cnt_1 == 2'd2)
					par <= !par;
			end

			/* One-hot state transitions (independent if blocks, no priority chain) */
			if (st_is_idle && in_v) begin
				st_is_idle <= 1'b0;
				st_is_next <= 1'b1;
			end
			if (st_is_next && in_v) begin
				/* Between warps: open the next one only for a real vertex. */
				if (in_rst || (in_inst_ne && cnt_2 != 2'd0)) begin
					cnt_0 <= 2'd0;
					cnt_1 <= 2'd0;
					cnt_2 <= 2'd0;
					par <= 1'b0;
					if (in_rst && in_last) begin
						fin <= 1'b1;
						st_is_next    <= 1'b0;
						st_is_prims   <= 1'b1;
						st_is_prims_1 <= 1'b1;
					end
				end else begin
					st_is_next  <= 1'b0;
					st_is_alloc <= 1'b1;
				end
			end
			if (st_is_alloc && vl_gnt) begin
				st_is_alloc <= 1'b0;
				st_is_send  <= 1'b1;
			end
			if (st_is_send) begin
				if (s_rst) begin
					if (in_last) begin
						fin <= 1'b1;
						st_is_send  <= 1'b0;
						st_is_close <= 1'b1;
					end
				end else if (s_go && !in_rst && early) begin
					st_is_send  <= 1'b0;
					st_is_close <= 1'b1;
				end else if (s_put) begin
					if (in_last) begin
						fin <= 1'b1;
						st_is_send  <= 1'b0;
						st_is_close <= 1'b1;
					end else if (lane_is31_r) begin
						st_is_send  <= 1'b0;
						st_is_close <= 1'b1;
					end
				end
			end
			if (st_is_close && vfree) begin
				st_is_close <= 1'b0;
				st_is_wait  <= 1'b1;
			end
			if (st_is_wait && conv_done) begin
				vl_go <= 1'b1;
				st_is_wait <= 1'b0;
				st_is_go   <= 1'b1;
			end
			if (st_is_go) begin
				st_is_go      <= 1'b0;
				st_is_prims   <= 1'b1;
				st_is_prims_1 <= 1'b1;
			end
			if (st_is_prims) begin
				/* PRIMS: the list in order; the last one waits for its successor. */
				if (f_n != 6'd0 && (!h_v || h_take)) begin
					h_v <= 1'b1;
					h_free <= f_top[17:15];
					f_rp_0 <= f_rp_next;
					f_rp_1 <= f_rp_next;
					f_rp_c <= f_rp_next;
				end else if (h_take) begin
					h_v <= 1'b0;
				end
				if (f_n == 6'd0) begin
					if (!fin) begin
						st_is_prims   <= 1'b0;
						st_is_prims_1 <= 1'b0;
						st_is_next    <= 1'b1;
					end else if (!h_v || h_take) begin
						st_is_prims   <= 1'b0;
						st_is_prims_1 <= 1'b0;
						st_is_idle    <= 1'b1;
						fin <= 1'b0;
						cnt_0 <= 2'd0;
						cnt_1 <= 2'd0;
						cnt_2 <= 2'd0;
						par <= 1'b0;
					end
				end
			end
		end
	end

	wire unused_ok = &{1'b0, lane[5], ci_co_unused, vo_co_unused,
		fw_co_unused, fr_co_unused, fni_co_unused, fnd_bo_unused, ln_co_unused, cy_bo_unused,
		p0_co_unused, p1_co_unused, p2_co_unused};
endmodule

`default_nettype wire
