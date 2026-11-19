/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_tmds: DVI/HDMI TMDS encoding (8b/10b with DC balance, control
 * symbols in blanking) of the three channels; the 10-bit symbols are
 * serialised by OSERDESE2 in the board top (vendor primitive).  See
 * spec/gpu/dc/atg_dc_tmds.md.
 *
 * The DVI 1.0 algorithm per channel (Values referenced: DVI 1.0 §3.2.3,
 * the encoder's flow chart): stage 1 makes the transition-minimised q_m
 * (XOR or XNOR chain by the number of ones), stage 2 chooses to invert it
 * by the running disparity cnt and adds bit 9.  Outside DE the channel
 * sends the control symbol of {C1, C0} and cnt is 0: channel 0 (blue)
 * carries {vs, hs}, channels 1 and 2 send {0, 0}.  Symbols are LSB first:
 * tmds[9:0] is channel 0, [19:10] channel 1 (green), [29:20] channel 2
 * (red).  Two cycles of latency.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_tmds (
	input wire clk,
	input wire rst_n,
	input wire [23:0] rgb,
	input wire de,
	input wire hs,
	input wire vs,
	output wire [29:0] tmds
);
	(* keep = "true" *) wire rst_high = !rst_n;

	/* The number of ones of a nibble (pure logic, no ROM or arithmetic). */
	function [2:0] ones4;
		input [3:0] n;
		reg p0, g0, p1, g1;
		begin
			p0 = n[0] ^ n[1];
			g0 = n[0] & n[1];
			p1 = n[2] ^ n[3];
			g1 = n[2] & n[3];
			ones4[0] = p0 ^ p1;
			ones4[1] = (g0 ^ g1) ^ (p0 & p1);
			ones4[2] = g0 & g1;
		end
	endfunction

	reg [8:0] s1_qm [0:2];
	reg [1:0] s1_ctrl [0:2];
	(* max_fanout = 16 *) reg s1_de;

`ifdef SYNTH_KINTEX7
	wire [23:0] rgb_a, rgb_b;
	genvar gi;
	generate
		for (gi = 0; gi < 24; gi = gi + 1) begin : g_rgb_buf
			LUT1 #(.INIT(2'b10)) u_buf_a (.I0(rgb[gi]), .O(rgb_a[gi]));
			LUT1 #(.INIT(2'b10)) u_buf_b (.I0(rgb[gi]), .O(rgb_b[gi]));
		end
	endgenerate
`else
	wire [23:0] rgb_a = rgb;
	wire [23:0] rgb_b = rgb;
`endif

	always @(posedge clk or posedge rst_high) begin
		if (rst_high) begin
			s1_de <= 1'b0;
			s1_ctrl[0] <= 2'd0;
			s1_ctrl[1] <= 2'd0;
			s1_ctrl[2] <= 2'd0;
		end else begin
			s1_de <= de;
			s1_ctrl[0] <= {vs, hs};
			s1_ctrl[1] <= 2'd0;
			s1_ctrl[2] <= 2'd0;
		end
	end

	genvar c;
	generate
	for (c = 0; c < 3; c = c + 1) begin : g_ch
		/* Stage 1: q_m by the number of ones of the byte. */
		wire [7:0] d_a = rgb_a[8*c +: 8];
		wire [7:0] d_b = rgb_b[8*c +: 8];
		wire [3:0] d1;
		/* xnor_ iff d1 > 4 or (d1 == 4 && !d[0]), which is algebraically
		 * identical to (ones3(d_a[3:1]) + ones4(d_a[7:4]) >= 4). */
		wire [1:0] d_c0_3 = {
			(d_a[1] & d_a[2]) | (d_a[1] & d_a[3]) | (d_a[2] & d_a[3]),
			d_a[1] ^ d_a[2] ^ d_a[3]
		};
		wire [2:0] d_c1 = ones4(d_a[7:4]);
		wire d1_co_unused = (d_c0_3 == 2'd0) && (d_c1 == 3'd0);
		assign d1 = {1'b0, d_c1};
		wire xnor_ = (d_c1 >= 3'd4) ||
			(d_c1 == 3'd3 && d_c0_3 >= 2'd1) ||
			(d_c1 == 3'd2 && d_c0_3 >= 2'd2) ||
			(d_c1 == 3'd1 && d_c0_3 == 2'd3);

		/* Balanced <= 3-level XOR trees for qm_xor[7:0] */
		wire px_01 = d_b[0] ^ d_b[1];
		wire px_23 = d_b[2] ^ d_b[3];
		wire px_45 = d_b[4] ^ d_b[5];
		wire px_67 = d_b[6] ^ d_b[7];
		wire px_03 = px_01 ^ px_23;
		wire [7:0] qm_xor;
		assign qm_xor[0] = d_b[0];
		assign qm_xor[1] = px_01;
		assign qm_xor[2] = px_01 ^ d_b[2];
		assign qm_xor[3] = px_03;
		assign qm_xor[4] = px_03 ^ d_b[4];
		assign qm_xor[5] = px_03 ^ px_45;
		assign qm_xor[6] = px_03 ^ px_45 ^ d_b[6];
		assign qm_xor[7] = px_03 ^ (px_45 ^ px_67);

		wire [8:0] next_qm = {
			!xnor_,
			qm_xor[7] ^ xnor_,
			qm_xor[6],
			qm_xor[5] ^ xnor_,
			qm_xor[4],
			qm_xor[3] ^ xnor_,
			qm_xor[2],
			qm_xor[1] ^ xnor_,
			qm_xor[0]
		};

		wire [2:0] n_even = ones4({qm_xor[6], qm_xor[4], qm_xor[2], qm_xor[0]});
		wire [2:0] n_odd_xor = ones4({qm_xor[7], qm_xor[5], qm_xor[3], qm_xor[1]});
		wire [2:0] n_odd_xnor = ones4(~{qm_xor[7], qm_xor[5], qm_xor[3], qm_xor[1]});

		wire [3:0] n1_xor, n1_xnor;
		wire n1_xor_co_unused, n1_xnor_co_unused;
		am_add #(.W(4)) a_n1_xor (
			.a({1'b0, n_even}), .b({1'b0, n_odd_xor}), .ci(1'b0),
			.s(n1_xor), .co(n1_xor_co_unused)
		);
		am_add #(.W(4)) a_n1_xnor (
			.a({1'b0, n_even}), .b({1'b0, n_odd_xnor}), .ci(1'b0),
			.s(n1_xnor), .co(n1_xnor_co_unused)
		);
		wire [3:0] next_n1 = xnor_ ? n1_xnor : n1_xor;

		reg [3:0] s1_n1_r;
		always @(posedge clk or posedge rst_high) begin
			if (rst_high) begin
				s1_qm[c] <= 9'd0;
				s1_n1_r  <= 4'd0;
			end else begin
				s1_qm[c] <= next_qm;
				s1_n1_r  <= next_n1;
			end
		end
		wire [8:0] q = s1_qm[c];
		wire [3:0] n1 = s1_n1_r;
		wire n1_co_unused = n1_xor_co_unused ^ n1_xnor_co_unused;
		reg [4:0] cnt;	/* running disparity, signed, even */
		reg [9:0] out;
		/* n1 in 0..8 -> diff = 2*n1 - 8 (even); delta_half = delta/2 in [-5..5] (4b) */
		wire n1_eq4 = (n1 == 4'd4);
		wire n1_gt4 = n1[3] || (n1[2] && (|n1[1:0]));
		wire n1_lt4 = !n1[3] && !n1[2];
		wire balanced  = (cnt == 5'd0) || n1_eq4;
		wire same_sign = (cnt != 5'd0) && ((!cnt[4] && n1_gt4) || (cnt[4] && n1_lt4));

		/* Precompute 4-bit half-delta candidates directly from n1[3:0] and select in 1 mux:
		 *   pos_h   = n1 - 4
		 *   pos_m1h = n1 - 5
		 *   neg_h   = 4 - n1
		 *   neg_p1h = 5 - n1 */
		wire [3:0] dh_pos, dh_pos_m1, dh_neg, dh_neg_p1;
		wire [3:0] dh_unused;
		am_sub #(.W(4)) s_dh_p  (.a(n1),   .b(4'd4), .bi(1'b0), .d(dh_pos),    .bo(dh_unused[0]));
		am_sub #(.W(4)) s_dh_pm (.a(n1),   .b(4'd5), .bi(1'b0), .d(dh_pos_m1), .bo(dh_unused[1]));
		am_sub #(.W(4)) s_dh_n  (.a(4'd4), .b(n1),   .bi(1'b0), .d(dh_neg),    .bo(dh_unused[2]));
		am_sub #(.W(4)) s_dh_np (.a(4'd5), .b(n1),   .bi(1'b0), .d(dh_neg_p1), .bo(dh_unused[3]));

		wire [3:0] delta_h = balanced  ? (q[8] ? dh_pos    : dh_neg) :
		                     same_sign ? (q[8] ? dh_neg_p1 : dh_neg) :
		                                 (q[8] ? dh_pos    : dh_pos_m1);
		wire [4:0] cnt_next;
		wire cnt_next_co_unused;
		am_add #(.W(4)) a_cnt (.a(cnt[4:1]), .b(delta_h), .ci(1'b0), .s(cnt_next[4:1]), .co(cnt_next_co_unused));
		assign cnt_next[0] = 1'b0;
		assign tmds[10*c +: 10] = out;

		always @(posedge clk or posedge rst_high) begin
			if (rst_high) begin
				cnt <= 5'd0;
				out <= 10'd0;
			end else if (!s1_de) begin
				cnt <= 5'd0;
				case (s1_ctrl[c])
				2'b00: out <= 10'b1101010100;
				2'b01: out <= 10'b0010101011;
				2'b10: out <= 10'b0101010100;
				default: out <= 10'b1010101011;
				endcase
			end else if (balanced) begin
				out <= {!q[8], q[8], q[8] ? q[7:0] : ~q[7:0]};
				cnt <= cnt_next;
			end else if (same_sign) begin
				out <= {1'b1, q[8], ~q[7:0]};
				cnt <= cnt_next;
			end else begin
				out <= {1'b0, q[8], q[7:0]};
				cnt <= cnt_next;
			end
		end

		wire unused_ok = &{1'b0, d1, d1_co_unused, n1_co_unused, dh_unused, cnt_next_co_unused};
	end
	endgenerate
endmodule

`default_nettype wire
