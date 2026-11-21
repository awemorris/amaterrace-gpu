/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_ex_rt: K-way pipelined fragment export router (SU -> ROP).
 *
 * Bridges K child fragment export buses (ex_*) up to one parent port toward
 * spine atg_rop with strict flop-to-flop am_skid boundaries.
 * Arbitrates with ex_seq == ex_next priority (prevents head-of-line stalling
 * across multiple SUs) and fair round-robin fallback, locking each multi-beat
 * quad export packet until ex_last passes.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_ex_rt #(
	parameter K = 4
) (
	input wire clk,
	input wire rst_n,

	/* Child SU export ports (packed, child 0 in low bits) */
	input wire [K-1:0] c_ex_valid,
	output wire [K-1:0] c_ex_ready,
	input wire [K*16-1:0] c_ex_seq,
	input wire [K*32-1:0] c_ex_xy,
	input wire [K*4-1:0] c_ex_mask,
	input wire [K*512-1:0] c_ex_color,
	input wire [K*512-1:0] c_ex_color1,
	input wire [K-1:0] c_ex_has_src1,
	input wire [K*128-1:0] c_ex_depth,
	input wire [K-1:0] c_ex_last,
	input wire [K*155-1:0] c_ex_aux,
	output reg [15:0] c_ex_next,

	/* Parent port toward Spine ROP */
	output wire p_ex_valid,
	input wire p_ex_ready,
	output wire [15:0] p_ex_seq,
	output wire [31:0] p_ex_xy,
	output wire [3:0] p_ex_mask,
	output wire [511:0] p_ex_color,
	output wire [511:0] p_ex_color1,
	output wire p_ex_has_src1,
	output wire [127:0] p_ex_depth,
	output wire p_ex_last,
	output wire [154:0] p_ex_aux,
	input wire [15:0] p_ex_next
);
	localparam KW   = (K > 2) ? 2 : 1;
	localparam EX_W = 16 + 32 + 4 + 512 + 512 + 1 + 128 + 155 + 1; /* 1361 bits */

	wire [K-1:0] sk_v, sk_r;
	wire [K*EX_W-1:0] sk_d_flat;
	wire [K-1:0] sk_match_next;
	wire [K-1:0] sk_last;

	genvar gk;
	generate
		for (gk = 0; gk < K; gk = gk + 1) begin : g_ex_sk
			wire [EX_W-1:0] in_vec = {
				c_ex_seq[gk*16 +: 16],
				c_ex_xy[gk*32 +: 32],
				c_ex_mask[gk*4 +: 4],
				c_ex_color[gk*512 +: 512],
				c_ex_color1[gk*512 +: 512],
				c_ex_has_src1[gk],
				c_ex_depth[gk*128 +: 128],
				c_ex_aux[gk*155 +: 155],
				c_ex_last[gk]
			};
			am_skid #(.WIDTH(EX_W), .RST_DATA(0)) u_ex_sk (
				.clk(clk), .rst_n(rst_n),
				.in_valid(c_ex_valid[gk]), .in_ready(c_ex_ready[gk]),
				.in_data(in_vec),
				.out_valid(sk_v[gk]), .out_ready(sk_r[gk]),
				.out_data(sk_d_flat[gk*EX_W +: EX_W])
			);
			assign sk_match_next[gk] = sk_v[gk] && (sk_d_flat[gk*EX_W + EX_W - 1 -: 16] == c_ex_next);
			assign sk_last[gk]       = sk_d_flat[gk*EX_W];
		end
	endgenerate

	/* Only forward quads matching p_ex_next to prevent head-of-line stalling atg_rop_order. */
	wire [K-1:0] cand = sk_match_next;

	reg          lock;
	reg [KW-1:0] owner, last_won;
	reg [KW-1:0] rr_pick;
	integer      st, ii;

	always @(*) begin
		rr_pick = {KW{1'b0}};
		for (st = K - 1; st >= 0; st = st - 1) begin
			for (ii = 0; ii < K; ii = ii + 1) begin
				if (last_won == ii[KW-1:0] && cand[(ii + 1 + st) % K])
					rr_pick = ((ii + 1 + st) % K);
			end
		end
	end

	wire [KW-1:0] pick = lock ? owner : rr_pick;
	wire pick_valid = lock ? sk_v[owner] : (|sk_match_next);
	wire pick_last  = sk_last[pick];

	wire out_in_ready;
	wire fire = pick_valid && out_in_ready;

	generate
		for (gk = 0; gk < K; gk = gk + 1) begin : g_ex_rdy
			assign sk_r[gk] = out_in_ready && pick_valid && (pick == gk[KW-1:0]);
		end
	endgenerate

	localparam integer SL_W = 64;
	localparam integer N_SL = (EX_W + SL_W - 1) / SL_W;
	wire [EX_W-1:0] mux_ex;
	genvar gs;
	generate
		for (gs = 0; gs < N_SL; gs = gs + 1) begin : g_ex_mux
			localparam integer B0 = gs * SL_W;
			localparam integer BW = (B0 + SL_W <= EX_W) ? SL_W : (EX_W - B0);
			(* max_fanout = 16 *) wire [KW-1:0] sel_sl = pick;
			reg [BW-1:0] sl_v;
			integer mi;
			always @(*) begin
				sl_v = sk_d_flat[B0 +: BW];
				for (mi = 1; mi < K; mi = mi + 1)
					if (sel_sl == mi[KW-1:0])
						sl_v = sk_d_flat[mi*EX_W + B0 +: BW];
			end
			assign mux_ex[B0 +: BW] = sl_v;
		end
	endgenerate

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			lock      <= 1'b0;
			owner     <= {KW{1'b0}};
			last_won  <= {KW{1'b0}};
			c_ex_next <= 16'd0;
		end else begin
			c_ex_next <= p_ex_next;
			if (fire) begin
				if (!lock)
					last_won <= pick;
				if (pick_last) begin
					lock <= 1'b0;
				end else begin
					lock  <= 1'b1;
					owner <= pick;
				end
			end
		end
	end

	am_skid #(.WIDTH(EX_W), .RST_DATA(0)) u_ex_out_sk (
		.clk(clk), .rst_n(rst_n),
		.in_valid(pick_valid), .in_ready(out_in_ready),
		.in_data(mux_ex),
		.out_valid(p_ex_valid), .out_ready(p_ex_ready),
		.out_data({p_ex_seq, p_ex_xy, p_ex_mask, p_ex_color, p_ex_color1,
		           p_ex_has_src1, p_ex_depth, p_ex_aux, p_ex_last})
	);
endmodule

`default_nettype wire
