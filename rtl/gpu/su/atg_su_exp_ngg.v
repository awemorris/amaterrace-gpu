/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_exp_ngg: Next-Generation Geometry (NGG) Meshlet Primitive Export Sequencer.
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
 * See spec/gpu/su/atg_su_exp.md and plan/ws004/phase001/ngg_mesh_shader_proposal.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_exp_ngg #(
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

	/* NGG Stream Output to RX (atg_rx_setup) */
	output wire ngg_valid,
	input wire ngg_ready,
	output wire [701:0] ngg_tri,
	output wire ngg_last,
	output wire [15:0] ngg_mesh_id
);

	/* State Machine */
	localparam [2:0]
		S_IDLE        = 3'd0,
		S_PRIM_REQ    = 3'd1,
		S_PRIM_WAIT   = 3'd2,
		S_PRIM_LATCH  = 3'd3,
		S_VERT_REQ    = 3'd4,
		S_VERT_WAIT   = 3'd5,
		S_SKID_WAIT   = 3'd6,
		S_DRAIN_WAIT  = 3'd7;

	reg [2:0] st;

	/* Latched Meshlet parameters */
	reg [15:0] mesh_id_reg;
	reg [7:0] prim_count_reg;
	reg [7:0] cur_prim_idx;
	reg [AW-1:0] base_prim;
	reg [AW-1:0] base_pos;
	reg [AW-1:0] base_var;

	/* Current primitive under assembly */
	reg [7:0] v0_idx, v1_idx, v2_idx;
	reg [7:0] prim_flags;
	reg [4:0] req_w;	/* 0..20: words requested */
	reg [4:0] cap_w;	/* 0..21: words captured */
	reg lds_rd_en_d1;
	wire lds_data_v = lds_rd_en_d1;

	/* 21 words of triangle vertex data */
	reg [31:0] tri_words [0:20];

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
	am_add #(.W(AW)) u_prim_addr (.a(base_prim), .b({{(AW-8){1'b0}}, cur_prim_idx}), .ci(1'b0),
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
	wire [AW-1:0] v_scaled = {{(AW-10){1'b0}}, cur_v, 2'b00};	/* v * 4 words */

	wire [AW-1:0] base_plus_v;
	wire co_bpv;
	am_add #(.W(AW)) u_bpv (.a(cur_base), .b(v_scaled), .ci(1'b0), .s(base_plus_v), .co(co_bpv));

	wire [AW-1:0] vert_word_addr;
	wire co_vwa;
	am_add #(.W(AW)) u_vwa (.a(base_plus_v), .b({{(AW-2){1'b0}}, comp_off}), .ci(1'b0),
		.s(vert_word_addr), .co(co_vwa));

	/* Skid Buffer Signals */
	reg skid_push_valid;
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

	integer i;
	always @(posedge clk) begin
		if (!rst_n) begin
			st <= S_IDLE;
			done <= 1'b0;
			lds_rd_en <= 1'b0;
			lds_rd_addr <= {AW{1'b0}};
			mesh_id_reg <= 16'd0;
			prim_count_reg <= 8'd0;
			cur_prim_idx <= 8'd0;
			base_prim <= {AW{1'b0}};
			base_pos <= {AW{1'b0}};
			base_var <= {AW{1'b0}};
			v0_idx <= 8'd0;
			v1_idx <= 8'd0;
			v2_idx <= 8'd0;
			prim_flags <= 8'd0;
			req_w <= 5'd0;
			cap_w <= 5'd0;
			lds_rd_en_d1 <= 1'b0;
			skid_push_valid <= 1'b0;
			skid_push_last <= 1'b0;
			for (i = 0; i < 21; i = i + 1)
				tri_words[i] <= 32'd0;
		end else begin
			done <= 1'b0;
			skid_push_valid <= 1'b0;
			lds_rd_en_d1 <= lds_rd_en && (st == S_VERT_REQ || st == S_VERT_WAIT);

			if (lds_data_v) begin
				tri_words[cap_w] <= lds_rd_data;
				cap_w <= next_cap_w;
			end

			case (st)
			S_IDLE: begin
				if (kick_valid) begin
					mesh_id_reg <= kick_mesh_id;
					prim_count_reg <= kick_prim_count;
					cur_prim_idx <= 8'd0;
					base_prim <= kick_prim_base;
					base_pos <= kick_pos_base;
					base_var <= kick_var_base;
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
				st <= S_PRIM_LATCH;
			end

			S_PRIM_LATCH: begin
				v0_idx <= lds_rd_data[7:0];
				v1_idx <= lds_rd_data[15:8];
				v2_idx <= lds_rd_data[23:16];
				prim_flags <= lds_rd_data[31:24];

				/* Check hardware backface / frustum cull bit (bit 7) */
				if (lds_rd_data[31]) begin
					/* Culled: skip reading vertices */
					if (next_prim_idx == prim_count_reg) begin
						st <= S_DRAIN_WAIT;
					end else begin
						cur_prim_idx <= next_prim_idx;
						st <= S_PRIM_REQ;
					end
				end else begin
					/* Valid triangle: start burst vertex read */
					req_w <= 5'd0;
					cap_w <= 5'd0;
					st <= S_VERT_REQ;
				end
			end

			S_VERT_REQ: begin
				lds_rd_en <= 1'b1;
				lds_rd_addr <= vert_word_addr;
				req_w <= next_req_w;

				if (req_w == 5'd20) begin
					st <= S_VERT_WAIT;
				end
			end

			S_VERT_WAIT: begin
				lds_rd_en <= 1'b0;
				if (cap_w == 5'd21) begin
					st <= S_SKID_WAIT;
				end
			end

			S_SKID_WAIT: begin
				if (skid_push_ready) begin
					skid_push_valid <= 1'b1;
					skid_push_last <= (next_prim_idx == prim_count_reg);
					if (next_prim_idx == prim_count_reg) begin
						st <= S_DRAIN_WAIT;
					end else begin
						cur_prim_idx <= next_prim_idx;
						st <= S_PRIM_REQ;
					end
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
	end

	/* ----------------------------------------------------------------
	 * 2-Stage Skid Buffer (Full wire-speed output & backpressure)
	 * ---------------------------------------------------------------- */
	reg [701:0] s0_tri;
	reg s0_last;
	reg s0_valid;

	reg [701:0] s1_tri;
	reg s1_last;
	reg s1_valid;

	assign skid_push_ready = !s0_valid || ngg_ready;
	assign skid_empty = !s0_valid && !s1_valid;

	assign ngg_valid = s1_valid;
	assign ngg_tri = s1_tri;
	assign ngg_last = s1_last;
	assign ngg_mesh_id = mesh_id_reg;

	always @(posedge clk) begin
		if (!rst_n) begin
			s0_valid <= 1'b0;
			s0_tri <= 702'd0;
			s0_last <= 1'b0;
			s1_valid <= 1'b0;
			s1_tri <= 702'd0;
			s1_last <= 1'b0;
		end else begin
			/* Stage 1 drain / advance */
			if (ngg_ready && s1_valid) begin
				if (s0_valid) begin
					s1_tri <= s0_tri;
					s1_last <= s0_last;
					s1_valid <= 1'b1;
					s0_valid <= 1'b0;
				end else begin
					s1_valid <= 1'b0;
				end
			end

			/* Stage 0 / Stage 1 load */
			if (skid_push_valid) begin
				if (!s1_valid || (ngg_ready && s1_valid && !s0_valid)) begin
					s1_tri <= skid_push_data;
					s1_last <= skid_push_last;
					s1_valid <= 1'b1;
				end else begin
					s0_tri <= skid_push_data;
					s0_last <= skid_push_last;
					s0_valid <= 1'b1;
				end
			end
		end
	end

	wire unused_ok = &{1'b0, kick_vert_count, prim_flags[7:4], co_prim, co_req_w, co_cap_w, co_paddr, co_bpv, co_vwa};
endmodule

`default_nettype wire
