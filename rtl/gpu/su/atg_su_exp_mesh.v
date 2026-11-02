/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_exp_mesh: Unified Meshlet Primitive Export Sequencer.
 *
 * Reads culled primitive topology and corresponding vertex attributes directly
 * from Local Data Share (LDS) via a dedicated read port (Port B), formats each
 * primitive into a 702-bit triangle package (compatible with atg_rx_setup cl_tri),
 * and streams it directly to the rasterizer via a 2-stage skid buffer.
 *
 * Features:
 *   - Meshlet size: up to 64 vertices, 126 primitives.
 *   - Autonomous LDS burst DMA export upon Mesh Shader completion.
 *   - Fast hardware culling skip (culled primitives take 1 cycle to discard).
 *   - 2-stage Skid Buffer for full wire-speed throughput and backpressure handling.
 *   - Zero additional Block RAM overhead (shares existing LDS).
 *
 * See spec/gpu/su/atg_su_exp.md and plan/ws004/phase001/mesh_shader_proposal.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_exp_mesh #(
	parameter AW = 10,		/* LDS word address width (10 for 4 KiB, 12 for 16 KiB) */
	parameter DATA_W = 32		/* LDS word data width */
) (
	input wire clk,
	input wire rst_n,

	/* Kick & Configuration Interface */
	input wire kick_valid,
	input wire [15:0] kick_mesh_id,
	input wire [7:0] kick_prim_count,
	input wire [7:0] kick_vert_count,
	input wire [AW-1:0] kick_prim_base,
	input wire [AW-1:0] kick_pos_base,
	input wire [AW-1:0] kick_var_base,
	output wire busy,
	output reg done,

	/* LDS Port B Read Interface */
	output reg lds_rd_en,
	output reg [AW-1:0] lds_rd_addr,
	input wire [DATA_W-1:0] lds_rd_data,

	/* Mesh Stream Output to RX (atg_rx_setup) */
	output wire mesh_valid,
	input wire mesh_ready,
	output wire [701:0] mesh_tri,
	output wire mesh_last,
	output wire [15:0] mesh_id
);

	/* State Machine */
	localparam [3:0]
		S_IDLE        = 4'd0,
		S_PRIM_REQ    = 4'd1,
		S_PRIM_WAIT   = 4'd2,
		S_PRIM_LATCH  = 4'd3,
		S_VERT_REQ    = 4'd4,
		S_VERT_WAIT   = 4'd5,
		S_SKID_WAIT   = 4'd6,
		S_DRAIN_WAIT  = 4'd7,
		S_PRIM_WAIT2  = 4'd8;

	(* max_fanout = 12 *) reg [3:0] st;

	/* Latched Meshlet parameters */
	(* max_fanout = 12 *) reg [15:0] mesh_id_reg;
	reg [7:0] prim_count_reg;
	reg [7:0] cur_prim_idx;
	reg [AW-1:0] base_prim;
	reg [AW-1:0] base_pos;
	reg [AW-1:0] base_var;

	/* Current primitive under assembly */
	reg [7:0] v0_idx, v1_idx, v2_idx;
	reg [7:0] prim_flags;
	(* max_fanout = 12 *) reg [4:0] req_w;	/* 0..20: words requested */
	(* max_fanout = 12 *) reg [4:0] cap_w;	/* 0..21: words captured */
	reg lds_rd_en_d1;
	(* max_fanout = 12 *) reg lds_rd_en_d2;
	wire lds_data_v = lds_rd_en_d2;

	/* 21 words of triangle vertex data */
	wire [31:0] tri_words [0:20];

	/* Arithmetic helper wires using am_add */
	wire [7:0] next_prim_idx;
	wire co_prim;
	am_add #(.W(8)) u_next_prim (.a(cur_prim_idx), .b(8'd0), .ci(1'b1), .s(next_prim_idx), .co(co_prim));

	wire [4:0] next_req_w;
	wire co_req_w;
	am_add #(.W(5)) u_next_req_w (.a(req_w), .b(5'd0), .ci(1'b1), .s(next_req_w), .co(co_req_w));

	wire [4:0] next_cap_w;
	wire co_cap_w;
	am_add #(.W(5)) u_next_cap_w (.a(cap_w), .b(5'd0), .ci(1'b1), .s(next_cap_w), .co(co_cap_w));

	/* Primitive Index Address Calculation: base_prim + cur_prim_idx */
	wire [AW-1:0] prim_addr_calc;
	wire co_paddr;
	wire [AW-1:0] prim_off = {{(AW > 8 ? AW - 8 : 0){1'b0}}, cur_prim_idx[AW > 8 ? 7 : AW-1 : 0]};
	am_add #(.W(AW)) u_prim_addr (.a(base_prim), .b(prim_off), .ci(1'b0),
		.s(prim_addr_calc), .co(co_paddr));

	/* Vertex Word Address Generation for req_w (0..20) */
	wire [7:0] cur_v = (req_w < 5'd7) ? v0_idx : (req_w < 5'd14) ? v1_idx : v2_idx;
	wire is_var = (req_w >= 5'd4 && req_w <= 5'd6) ||
	              (req_w >= 5'd11 && req_w <= 5'd13) ||
	              (req_w >= 5'd18 && req_w <= 5'd20);

	reg [1:0] comp_off;
	always @(*) begin
		case (req_w)
		5'd0, 5'd7, 5'd14: comp_off = 2'd0;
		5'd1, 5'd8, 5'd15: comp_off = 2'd1;
		5'd2, 5'd9, 5'd16: comp_off = 2'd2;
		5'd3, 5'd10, 5'd17: comp_off = 2'd3;
		5'd4, 5'd11, 5'd18: comp_off = 2'd0;
		5'd5, 5'd12, 5'd19: comp_off = 2'd1;
		default:            comp_off = 2'd2;	/* 6, 13, 20 */
		endcase
	end

	wire [AW-1:0] cur_base = is_var ? base_var : base_pos;
	wire [9:0] v_scaled_10 = {cur_v, comp_off};
	wire [AW-1:0] v_scaled = {{(AW > 10 ? AW - 10 : 0){1'b0}}, v_scaled_10[AW > 10 ? 9 : AW-1 : 0]};

	wire [AW-1:0] vert_word_addr;
	wire co_bpv;
	wire co_vwa = 1'b0;
	am_add #(.W(AW)) u_bpv (.a(cur_base), .b(v_scaled), .ci(1'b0), .s(vert_word_addr), .co(co_bpv));

	/* Skid Buffer Signals */
	(* max_fanout = 12 *) reg skid_push_valid;
	reg skid_push_last;
	wire [701:0] skid_push_data;
	wire skid_push_ready;
	wire skid_empty;

	/* Assembled 702-bit Triangle Data */
	assign skid_push_data = {
		2'd2,			/* kind: 2 = triangle */
		prim_flags[3],		/* raw screen-space flag */
		prim_flags[2:0],	/* control flags */
		v2_idx, v1_idx, v0_idx,	/* index triplet (24 bits) */
		tri_words[20], tri_words[19], tri_words[18],	/* V2 Varying (96 bits) */
		tri_words[13], tri_words[12], tri_words[11],	/* V1 Varying (96 bits) */
		tri_words[6],  tri_words[5],  tri_words[4],	/* V0 Varying (96 bits) */
		tri_words[17], tri_words[16], tri_words[15], tri_words[14],	/* V2 Pos (128 bits) */
		tri_words[10], tri_words[9],  tri_words[8],  tri_words[7],	/* V1 Pos (128 bits) */
		tri_words[3],  tri_words[2],  tri_words[1],  tri_words[0]	/* V0 Pos (128 bits) */
	};

	assign busy = (st != S_IDLE);

	(* dont_touch = "true" *) wire prim_latch_en0 = (st == S_PRIM_LATCH);
	(* dont_touch = "true" *) wire prim_latch_en1 = (st == S_PRIM_LATCH);
	(* dont_touch = "true" *) wire kick_en0 = (st == S_IDLE) && kick_valid;
	(* dont_touch = "true" *) wire kick_en1 = (st == S_IDLE) && kick_valid;
	(* dont_touch = "true" *) wire kick_en2 = (st == S_IDLE) && kick_valid;
	(* dont_touch = "true" *) wire rst_p = !rst_n;
	(* dont_touch = "true" *) wire [31:0] lds_d_a = lds_rd_data;
	(* dont_touch = "true" *) wire [31:0] lds_d_b = lds_rd_data;
	(* dont_touch = "true" *) wire lds_dv_a = lds_data_v;
	(* dont_touch = "true" *) wire lds_dv_b = lds_data_v;
	(* dont_touch = "true" *) wire [4:0] cap_w_a = cap_w;
	(* dont_touch = "true" *) wire [4:0] cap_w_b = cap_w;
	genvar gtw;
	generate
		for (gtw = 0; gtw < 21; gtw = gtw + 1) begin : g_tw_we
			wire [31:0] tw_din = (gtw < 11) ? lds_d_a : lds_d_b;
			wire tw_dv         = (gtw < 11) ? lds_dv_a : lds_dv_b;
			wire [4:0] tw_cw   = (gtw < 11) ? cap_w_a : cap_w_b;
			(* dont_touch = "true" *) wire tw_we_lo_s = tw_dv && (tw_cw == gtw[4:0]);
			(* dont_touch = "true" *) wire tw_we_hi_s = tw_dv && (tw_cw == gtw[4:0]);
			(* shreg_extract = "no" *) reg [15:0] tw_lo_r, tw_hi_r;
			always @(posedge clk) begin
				if (tw_we_lo_s)
					tw_lo_r <= tw_din[15:0];
				if (tw_we_hi_s)
					tw_hi_r <= tw_din[31:16];
			end
			assign tri_words[gtw] = {tw_hi_r, tw_lo_r};
		end
	endgenerate

	always @(posedge clk) begin
		if (rst_p) begin
			st <= S_IDLE;
			done <= 1'b0;
			lds_rd_en <= 1'b0;
			lds_rd_addr <= {AW{1'b0}};
		end else begin
			done <= 1'b0;
			case (st)
			S_IDLE: begin
				if (kick_valid) begin
					if (kick_prim_count == 8'd0) begin
						done <= 1'b1;
						st <= S_IDLE;
					end else begin
						st <= S_PRIM_REQ;
					end
				end
			end
			S_PRIM_REQ: begin
				lds_rd_en <= 1'b1;
				lds_rd_addr <= prim_addr_calc;
				st <= S_PRIM_WAIT;
			end
			S_PRIM_WAIT: begin
				lds_rd_en <= 1'b0;
				st <= S_PRIM_WAIT2;
			end
			S_PRIM_WAIT2: begin
				st <= S_PRIM_LATCH;
			end
			S_PRIM_LATCH: begin
				if (lds_d_b[31]) begin
					if (next_prim_idx == prim_count_reg)
						st <= S_DRAIN_WAIT;
					else
						st <= S_PRIM_REQ;
				end else begin
					st <= S_VERT_REQ;
				end
			end
			S_VERT_REQ: begin
				lds_rd_en <= 1'b1;
				lds_rd_addr <= vert_word_addr;
				if (req_w == 5'd20)
					st <= S_VERT_WAIT;
			end
			S_VERT_WAIT: begin
				lds_rd_en <= 1'b0;
				if (cap_w == 5'd21)
					st <= S_SKID_WAIT;
			end
			S_SKID_WAIT: begin
				if (skid_push_ready) begin
					if (next_prim_idx == prim_count_reg)
						st <= S_DRAIN_WAIT;
					else
						st <= S_PRIM_REQ;
				end
			end
			S_DRAIN_WAIT: begin
				if (skid_empty) begin
					done <= 1'b1;
					st <= S_IDLE;
				end
			end
			default: st <= S_IDLE;
			endcase
		end

		if (rst_p) begin
			mesh_id_reg <= 16'd0;
			prim_count_reg <= 8'd0;
		end else if (kick_en0) begin
			mesh_id_reg <= kick_mesh_id;
			prim_count_reg <= kick_prim_count;
		end

		if (rst_p) begin
			cur_prim_idx <= 8'd0;
			base_prim <= {AW{1'b0}};
		end else begin
			if (kick_en1) begin
				cur_prim_idx <= 8'd0;
				base_prim <= kick_prim_base;
			end else if ((st == S_PRIM_LATCH && lds_d_b[31] && next_prim_idx != prim_count_reg) ||
			             (st == S_SKID_WAIT && skid_push_ready && next_prim_idx != prim_count_reg)) begin
				cur_prim_idx <= next_prim_idx;
			end
		end

		if (rst_p) begin
			base_pos <= {AW{1'b0}};
			base_var <= {AW{1'b0}};
		end else if (kick_en2) begin
			base_pos <= kick_pos_base;
			base_var <= kick_var_base;
		end

		if (rst_p) begin
			v0_idx <= 8'd0;
			v1_idx <= 8'd0;
			v2_idx <= 8'd0;
		end else begin
			if (prim_latch_en0) begin
				v0_idx <= lds_d_b[7:0];
				v1_idx <= lds_d_b[15:8];
			end
			if (prim_latch_en1)
				v2_idx <= lds_d_b[23:16];
		end

		if (rst_p) begin
			prim_flags <= 8'd0;
			req_w <= 5'd0;
			cap_w <= 5'd0;
			lds_rd_en_d1 <= 1'b0;
			lds_rd_en_d2 <= 1'b0;
			skid_push_valid <= 1'b0;
			skid_push_last <= 1'b0;
		end else begin
			skid_push_valid <= 1'b0;
			lds_rd_en_d1 <= lds_rd_en && (st == S_VERT_REQ || st == S_VERT_WAIT);
			lds_rd_en_d2 <= lds_rd_en_d1;

			if (prim_latch_en1)
				prim_flags <= lds_d_b[31:24];

			if (st == S_PRIM_LATCH && !lds_d_b[31]) begin
				req_w <= 5'd0;
				cap_w <= 5'd0;
			end else begin
				if (st == S_VERT_REQ)
					req_w <= next_req_w;
				if (lds_data_v)
					cap_w <= next_cap_w;
			end

			if (st == S_SKID_WAIT && skid_push_ready) begin
				skid_push_valid <= 1'b1;
				skid_push_last <= (next_prim_idx == prim_count_reg);
			end
		end
	end

	/* ----------------------------------------------------------------
	 * 2-Stage Skid Buffer (Full wire-speed output & backpressure)
	 * ---------------------------------------------------------------- */
	wire [701:0] s0_tri;
	reg s0_last;
	(* max_fanout = 12 *) reg s0_valid;

	wire [701:0] s1_tri;
	reg s1_last;
	(* max_fanout = 12 *) reg s1_valid;

	(* max_fanout = 12 *) wire w_mesh_ready = mesh_ready;
	(* dont_touch = "true" *) wire m_rdy0 = mesh_ready;
	(* dont_touch = "true" *) wire m_rdy1 = mesh_ready;
	(* dont_touch = "true" *) wire m_rdy2 = mesh_ready;
	(* dont_touch = "true" *) wire push_v_d0 = (st == S_SKID_WAIT) && skid_push_ready;
	(* dont_touch = "true" *) wire push_v_d1 = (st == S_SKID_WAIT) && skid_push_ready;
	(* dont_touch = "true" *) wire push_v_d2 = (st == S_SKID_WAIT) && skid_push_ready;
	assign skid_push_ready = !s0_valid || w_mesh_ready;
	assign skid_empty = !s0_valid && !s1_valid;

	assign mesh_valid = s1_valid;
	assign mesh_tri = s1_tri;
	assign mesh_last = s1_last;
	assign mesh_id = mesh_id_reg;

	genvar gsl;
	generate
		for (gsl = 0; gsl < 44; gsl = gsl + 1) begin : g_skid_sl
			localparam SL_B = gsl * 16;
			localparam SL_W = (SL_B + 16 <= 702) ? 16 : (702 - SL_B);
			wire sl_mrdy   = (gsl < 15) ? m_rdy0    : (gsl < 30) ? m_rdy1    : m_rdy2;
			wire sl_push_d = (gsl < 15) ? push_v_d0 : (gsl < 30) ? push_v_d1 : push_v_d2;
			(* dont_touch = "true" *) reg s0_v_sl, s1_v_sl, push_v_sl;
			always @(posedge clk) begin
				if (rst_p) begin
					s0_v_sl   <= 1'b0;
					s1_v_sl   <= 1'b0;
					push_v_sl <= 1'b0;
				end else begin
					push_v_sl <= sl_push_d;
					if (sl_mrdy && s1_v_sl) begin
						if (s0_v_sl) begin
							s1_v_sl <= 1'b1;
							s0_v_sl <= 1'b0;
						end else begin
							s1_v_sl <= 1'b0;
						end
					end
					if (push_v_sl) begin
						if (!s1_v_sl || (sl_mrdy && s1_v_sl && !s0_v_sl))
							s1_v_sl <= 1'b1;
						else
							s0_v_sl <= 1'b1;
					end
				end
			end
			(* dont_touch = "true" *) wire s0_we_s = push_v_sl && s1_v_sl && !(sl_mrdy && !s0_v_sl);
			(* dont_touch = "true" *) wire s1_we_s = (sl_mrdy && s1_v_sl && s0_v_sl) ||
				(push_v_sl && (!s1_v_sl || (sl_mrdy && s1_v_sl && !s0_v_sl)));
			(* dont_touch = "true" *) wire s1_from_s0_s = !push_v_sl;
			(* shreg_extract = "no" *) reg [SL_W-1:0] s0_sl_r, s1_sl_r;
			always @(posedge clk) begin
				if (s0_we_s)
					s0_sl_r <= skid_push_data[SL_B +: SL_W];
				if (s1_we_s)
					s1_sl_r <= s1_from_s0_s ? s0_sl_r : skid_push_data[SL_B +: SL_W];
			end
			assign s0_tri[SL_B +: SL_W] = s0_sl_r;
			assign s1_tri[SL_B +: SL_W] = s1_sl_r;
		end
	endgenerate

	always @(posedge clk) begin
		if (rst_p) begin
			s0_valid <= 1'b0;
			s0_last <= 1'b0;
			s1_valid <= 1'b0;
			s1_last <= 1'b0;
		end else begin
			/* Stage 1 drain / advance */
			if (w_mesh_ready && s1_valid) begin
				if (s0_valid) begin
					s1_last <= s0_last;
					s1_valid <= 1'b1;
					s0_valid <= 1'b0;
				end else begin
					s1_valid <= 1'b0;
				end
			end

			/* Stage 0 / Stage 1 load */
			if (skid_push_valid) begin
				if (!s1_valid || (w_mesh_ready && s1_valid && !s0_valid)) begin
					s1_last <= skid_push_last;
					s1_valid <= 1'b1;
				end else begin
					s0_last <= skid_push_last;
					s0_valid <= 1'b1;
				end
			end
		end
	end

	wire unused_ok = &{1'b0, kick_vert_count, prim_flags[7:4], co_prim, co_req_w, co_cap_w, co_paddr, co_bpv, co_vwa,
		v_scaled_10};
endmodule

`default_nettype wire
