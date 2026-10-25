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
 *
 * One warp at a time: NEXT (a vertex waits on iv) → ALLOC (vl_req until
 * vl_gnt, PT base) → SEND (lane by lane on vb: first the vertices carried
 * from the previous warp, then iv) → CLOSE → WAIT (conv_done) → GO (vl_go,
 * vl_mask) → PRIMS (the warp's primitives, one per cycle).  Every iv vertex
 * gets its own lane (no reuse); vb_index = iv_index + VERTEX_OFFSET for
 * indexed draws.  A vertex is held one item back so that vb_last is known.
 * A warp closes when its 32 lanes are used (the vertices that later
 * primitives need, at most two, are carried into the next warp's lanes 0
 * and 1), before a list primitive that no longer fits, or at the draw's
 * last item.  Primitive restart and a change of instance end the strip,
 * fan or incomplete list primitive.  Primitives use PT entries ptbase +
 * lane, v0 the provoking vertex (PROVOKING, RX STATE 0x05D: first or last,
 * the winding kept by rotation); a point is (p, p, p), a line (a, b, b).
 * prim_free marks each PT entry's last use within its warp; vl_mask has the
 * lanes that some primitive uses (the entries of the other lanes are never
 * named on prim_*).  The last primitive is held back until the next one
 * exists or the draw ends, so that prim_last is right; a draw without a
 * primitive sends none.  See spec/gpu/vf/atg_vf_asm.md.
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
	/* STATE: TOPOLOGY 0x020, INDEX_FORMAT 0x022, VERTEX_OFFSET 0x028, PROVOKING 0x05D. */
	reg [2:0] s_topo;
	reg s_ind, s_last;
	reg [31:0] s_voff;
	always @(posedge clk)
		if (!rst_n) begin
			s_topo <= 3'd0;
			s_ind <= 1'b0;
			s_voff <= 32'd0;
			s_last <= 1'b0;
		end else if (st_we) begin
			if (st_idx == GHCI_S_TOPOLOGY)
				s_topo <= st_wdata[2:0];
			if (st_idx == GHCI_S_INDEX_FORMAT)
				s_ind <= st_wdata[1:0] != 2'd0;
			if (st_idx == GHCI_S_VERTEX_OFFSET)
				s_voff <= st_wdata;
			if (st_idx == GHCI_S_PROVOKING)
				s_last <= st_wdata[0];
		end

	/* TOPOLOGY: 0 points, 1 lines, 2 line strip, 3 triangles, 4 strip, 5 fan
	 * (6, 7 reserved: points). */
	localparam [2:0] T_LINES = 3'd1, T_LSTRIP = 3'd2, T_TRIS = 3'd3, T_STRIP = 3'd4,
		T_FAN = 3'd5;
	wire t_list = s_topo == T_LINES || s_topo == T_TRIS;
	wire [5:0] t_need = s_topo == T_TRIS ? 6'd3 : 6'd2;	/* vertices of a list primitive */

	localparam [2:0] ST_IDLE = 3'd0, ST_NEXT = 3'd1, ST_ALLOC = 3'd2, ST_SEND = 3'd3,
		ST_CLOSE = 3'd4, ST_WAIT = 3'd5, ST_GO = 3'd6, ST_PRIMS = 3'd7;
	reg [2:0] st;
	reg fin;	/* this warp is the draw's last */

	/* Assembly: up to two earlier vertices of the open primitive, strip or fan
	 * (A older, or the fan's centre; B newer), their lanes in this warp. */
	reg [1:0] cnt;
	reg [31:0] a_idx, a_inst, b_idx, b_inst, cur_inst;
	reg [4:0] a_lane, b_lane;
	reg par;	/* strip: odd triangle */

	/* The warp. */
	reg [5:0] lane;	/* next lane, 0..32 */
	reg [31:0] used;	/* lanes used by a primitive */
	reg [7:0] ptbase;
	reg [1:0] carry;	/* carried vertices still to send */
	reg sg_v;	/* the vertex held back from vb */
	reg [31:0] sg_idx, sg_inst;
	reg [4:0] sg_lane;

	/* The open primitive (its free flags not final) and the warp's list. */
	reg p_v;
	reg [14:0] p_l;
	reg [2:0] p_fa, p_fl;
	reg [17:0] f_mem [0:31];
	reg [4:0] f_wp, f_rp;
	reg [5:0] f_n;
	/* The primitive offered to the RX. */
	reg h_v;
	reg [23:0] h_vtx;
	reg [2:0] h_free;

	/* The new primitive when vertex V goes to lane L (g_*); lanes s0..s2. */
	wire [4:0] L = lane[4:0];
	reg g_emit, g_wa, g_wb, g_sh;	/* g_wa/g_wb: V becomes A/B; g_sh: A <= B */
	reg [1:0] g_cnt;
	reg [4:0] g0, g1, g2;
	reg [2:0] g_fa, g_fl;
	wire [1:0] cnt_inc;
	wire ci_co_unused;
	am_add #(.W(2)) u_cnt (.a(cnt), .b(2'd0), .ci(1'b1), .s(cnt_inc), .co(ci_co_unused));
	always @(*) begin
		g_emit = 1'b0;
		g0 = L;
		g1 = L;
		g2 = L;
		g_fa = 3'b001;
		g_fl = 3'b000;
		g_wa = cnt == 2'd0;
		g_wb = 1'b0;
		g_sh = 1'b0;
		g_cnt = 2'd0;
		case (s_topo)
		T_LINES, T_LSTRIP: begin
			/* (A, V, V); last: (V, A, A) */
			g_wa = s_topo == T_LSTRIP || cnt == 2'd0;
			g_cnt = {1'b0, g_wa};
			if (cnt != 2'd0) begin
				g_emit = 1'b1;
				g0 = s_last ? L : a_lane;
				g1 = s_last ? a_lane : L;
				g2 = g1;
				g_fa = s_topo == T_LINES ? 3'b011 : s_last ? 3'b010 : 3'b001;
				g_fl = 3'b011 & ~g_fa;
			end
		end
		T_TRIS: begin
			/* (A, B, V); last: (V, A, B) */
			g_wb = cnt == 2'd1;
			g_cnt = cnt == 2'd2 ? 2'd0 : cnt_inc;
			if (cnt == 2'd2) begin
				g_emit = 1'b1;
				g0 = s_last ? L : a_lane;
				g1 = s_last ? a_lane : b_lane;
				g2 = s_last ? b_lane : L;
				g_fa = 3'b111;
			end
		end
		T_STRIP, T_FAN: begin
			g_wb = cnt != 2'd0;
			g_sh = cnt == 2'd2 && s_topo == T_STRIP;
			g_cnt = cnt == 2'd0 ? 2'd1 : 2'd2;
			if (cnt == 2'd2 && s_topo == T_STRIP) begin
				/* first: even (A, B, V), odd (A, V, B); last: even (V, A, B), odd (V, B, A) */
				g_emit = 1'b1;
				g0 = s_last ? L : a_lane;
				g1 = s_last ? (par ? b_lane : a_lane) : (par ? L : b_lane);
				g2 = s_last ? (par ? a_lane : b_lane) : (par ? b_lane : L);
				g_fa = !s_last ? 3'b001 : par ? 3'b100 : 3'b010;
				g_fl = ~g_fa;
			end else if (cnt == 2'd2) begin
				/* fan, A the centre: first (B, V, A); last (V, A, B) */
				g_emit = 1'b1;
				g0 = s_last ? L : b_lane;
				g1 = s_last ? a_lane : L;
				g2 = s_last ? b_lane : a_lane;
				g_fa = s_last ? 3'b100 : 3'b001;
				g_fl = ~g_fa;
			end
		end
		default: begin
			g_emit = 1'b1;
			g_wa = 1'b0;
		end
		endcase
	end

	/* SEND: what happens to the item on iv. */
	wire vfree = !vb_valid || vb_ready;
	wire inst_chg = iv_inst != cur_inst && cnt != 2'd0;
	wire [5:0] lanes_left;
	wire ll_bo_unused;
	am_sub #(.W(6)) u_left (.a(6'd32), .b(lane), .bi(1'b0), .d(lanes_left), .bo(ll_bo_unused));
	wire early = t_list && cnt == 2'd0 && lanes_left < t_need;
	wire c_put = st == ST_SEND && vfree && carry != 2'd0;
	wire s_go = st == ST_SEND && vfree && carry == 2'd0 && iv_valid;
	wire s_rst = s_go && iv_restart;
	wire s_put = s_go && !iv_restart && !inst_chg && !early;
	wire n_rst = st == ST_NEXT && iv_valid && iv_restart;
	assign iv_ready = s_rst || s_put || n_rst;
	wire [31:0] v_off;
	wire vo_co_unused;
	am_add #(.W(32)) u_voff (.a(iv_index), .b(s_voff), .ci(1'b0), .s(v_off), .co(vo_co_unused));
	wire [31:0] v_idx = s_ind ? v_off : iv_index;
	wire seg_end = s_rst || (s_go && !iv_restart && inst_chg);

	assign vl_req = st == ST_ALLOC;
	assign busy = st != ST_IDLE;
	assign prim_valid = h_v && st == ST_PRIMS && (f_n != 6'd0 || fin);
	/* The kind from TOPOLOGY (its SET_REG waits while the VF is busy). */
	wire [1:0] p_kind = s_topo == T_LINES || s_topo == T_LSTRIP ? 2'd1 :
		s_topo == T_TRIS || s_topo == T_STRIP || s_topo == T_FAN ? 2'd2 : 2'd0;
	assign prim_vtx = {p_kind, h_vtx};
	assign prim_free = h_free;
	assign prim_last = fin && f_n == 6'd0;
	wire h_take = prim_valid && prim_ready;
	wire [17:0] f_top = f_mem[f_rp];

	/* Push the open primitive: superseded (fa) or final (fa | fl). */
	wire p_push = p_v && (seg_end || st == ST_CLOSE && vfree || s_put && g_emit);
	wire p_final = seg_end || st == ST_CLOSE;

	/*
	 * The counters: the list's write and read places and its entries (+1,
	 * -1), the next lane and the carried vertices left; the lanes a
	 * primitive uses (one-hot); a listed primitive's PT entries (ptbase +
	 * lane).
	 */
	wire f_pop = st == ST_PRIMS && f_n != 6'd0 && (!h_v || h_take);
	wire [4:0] f_wp_next;
	wire [4:0] f_rp_next;
	wire [5:0] f_n_next;
	wire [5:0] lane_next;
	wire [1:0] carry_next;
	wire fw_co_unused, fr_co_unused, fn_co_unused, ln_co_unused, cy_bo_unused;
	am_add #(.W(5)) u_f_wp (.a(f_wp), .b(5'd0), .ci(1'b1), .s(f_wp_next), .co(fw_co_unused));
	am_add #(.W(5)) u_f_rp (.a(f_rp), .b(5'd0), .ci(1'b1), .s(f_rp_next), .co(fr_co_unused));
	am_add #(.W(6)) u_f_n (.a(f_n), .b({{5{f_pop && !p_push}}, p_push ^ f_pop}), .ci(1'b0),
		.s(f_n_next),
		.co(fn_co_unused));
	am_add #(.W(6)) u_lane (.a(lane), .b(6'd0), .ci(1'b1), .s(lane_next), .co(ln_co_unused));
	am_sub #(.W(2)) u_carry (.a(carry), .b(2'd0), .bi(1'b1), .d(carry_next), .bo(cy_bo_unused));
	reg [31:0] g_used;
	integer gi;
	always @(*)
		for (gi = 0; gi < 32; gi = gi + 1)
			g_used[gi] = g0 == gi[4:0] || g1 == gi[4:0] || g2 == gi[4:0];
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

	always @(posedge clk) begin
		vl_go <= 1'b0;
		if (!rst_n) begin
			st <= ST_IDLE;
			vb_valid <= 1'b0;
			cnt <= 2'd0;
			par <= 1'b0;
			fin <= 1'b0;
			p_v <= 1'b0;
			h_v <= 1'b0;
			f_wp <= 5'd0;
			f_rp <= 5'd0;
			f_n <= 6'd0;
			sg_v <= 1'b0;
		end else begin
			if (vb_valid && vb_ready)
				vb_valid <= 1'b0;
			if (p_push) begin
				f_mem[f_wp] <= {p_final ? p_fa | p_fl : p_fa, p_l};
				f_wp <= f_wp_next;
			end
			if (seg_end) begin
				p_v <= 1'b0;
				cnt <= 2'd0;
				par <= 1'b0;
			end
			case (st)
			ST_IDLE:
				if (iv_valid)
					st <= ST_NEXT;
			ST_NEXT:
				/* Between warps: open the next one only for a real vertex. */
				if (iv_valid) begin
					if (iv_restart || iv_inst != cur_inst && cnt != 2'd0) begin
						cnt <= 2'd0;
						par <= 1'b0;
						if (iv_restart && iv_last) begin
							fin <= 1'b1;
							st <= ST_PRIMS;
						end
					end else
						st <= ST_ALLOC;
				end
			ST_ALLOC:
				if (vl_gnt) begin
					ptbase <= vl_ptbase;
					lane <= 6'd0;
					used <= 32'd0;
					carry <= cnt;
					st <= ST_SEND;
				end
			ST_SEND: begin
				if (c_put || s_put) begin
					/* The held vertex goes to vb, the new one is held. */
					vb_valid <= sg_v;
					vb_index <= sg_idx;
					vb_inst <= sg_inst;
					vb_lane <= sg_lane;
					vb_last <= 1'b0;
					sg_v <= 1'b1;
					sg_idx <= c_put ? (lane[0] ? b_idx : a_idx) : v_idx;
					sg_inst <= c_put ? (lane[0] ? b_inst : a_inst) : iv_inst;
					sg_lane <= L;
					lane <= lane_next;
				end
				if (c_put)
					/* The carried vertices (A at lane 0, B at lane 1). */
					carry <= carry_next;
				else if (s_rst) begin
					if (iv_last) begin
						fin <= 1'b1;
						st <= ST_CLOSE;
					end
				end else if (s_go && !iv_restart && early)
					st <= ST_CLOSE;
				else if (s_put) begin
					cur_inst <= iv_inst;
					/* assembly */
					if (g_emit) begin
						p_v <= 1'b1;
						p_l <= {g2, g1, g0};
						p_fa <= g_fa;
						p_fl <= g_fl;
						used <= used | g_used;
					end
					cnt <= g_cnt;
					if (g_wa) begin
						a_idx <= v_idx;
						a_inst <= iv_inst;
						a_lane <= L;
					end else if (g_sh) begin
						a_idx <= b_idx;
						a_inst <= b_inst;
						a_lane <= b_lane;
						par <= !par;
					end
					if (g_wb) begin
						b_idx <= v_idx;
						b_inst <= iv_inst;
						b_lane <= L;
					end
					if (iv_last) begin
						fin <= 1'b1;
						st <= ST_CLOSE;
					end else if (lane == 6'd31)
						st <= ST_CLOSE;
				end
			end
			ST_CLOSE:
				if (vfree) begin
					vb_valid <= 1'b1;
					vb_index <= sg_idx;
					vb_inst <= sg_inst;
					vb_lane <= sg_lane;
					vb_last <= 1'b1;
					sg_v <= 1'b0;
					p_v <= 1'b0;
					/* the carried vertices go to lanes 0 and 1 of the next warp */
					a_lane <= 5'd0;
					b_lane <= 5'd1;
					st <= ST_WAIT;
				end
			ST_WAIT:
				if (conv_done) begin
					vl_go <= 1'b1;
					vl_mask <= used;
					st <= ST_GO;
				end
			ST_GO:
				st <= ST_PRIMS;
			default: begin
				/* PRIMS: the list in order; the last one waits for its successor. */
				if (f_n != 6'd0 && (!h_v || h_take)) begin
					h_v <= 1'b1;
					h_vtx <= {pt2, pt1, pt0};
					h_free <= f_top[17:15];
					f_rp <= f_rp_next;
				end else if (h_take)
					h_v <= 1'b0;
				if (f_n == 6'd0) begin
					if (!fin)
						st <= ST_NEXT;
					else if (!h_v || h_take) begin
						st <= ST_IDLE;
						fin <= 1'b0;
						cnt <= 2'd0;
						par <= 1'b0;
					end
				end
			end
			endcase
			f_n <= f_n_next;
		end
	end

	wire unused_ok = &{1'b0, st_wdata[31:3]};
endmodule

`default_nettype wire
