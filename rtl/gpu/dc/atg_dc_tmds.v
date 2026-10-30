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

	/* The number of ones of a nibble, by table (no arithmetic). */
	function [2:0] ones4;
		input [3:0] n;
		begin
			case (n)
			4'h0: ones4 = 3'd0;
			4'h1, 4'h2, 4'h4, 4'h8: ones4 = 3'd1;
			4'h7, 4'hB, 4'hD, 4'hE: ones4 = 3'd3;
			4'hF: ones4 = 3'd4;
			default: ones4 = 3'd2;
			endcase
		end
	endfunction

	/* q_m of a byte: the XOR chain, or the XNOR chain when xnor_ is set; bit 8 says XOR. */
	function [8:0] qm;
		input [7:0] d;
		input xnor_;
		reg [7:0] qm_xor;
		begin
			qm_xor[0] = d[0];
			qm_xor[1] = d[0] ^ d[1];
			qm_xor[2] = qm_xor[1] ^ d[2];
			qm_xor[3] = qm_xor[2] ^ d[3];
			qm_xor[4] = qm_xor[3] ^ d[4];
			qm_xor[5] = qm_xor[4] ^ d[5];
			qm_xor[6] = qm_xor[5] ^ d[6];
			qm_xor[7] = qm_xor[6] ^ d[7];

			qm[0] = qm_xor[0];
			qm[1] = qm_xor[1] ^ xnor_;
			qm[2] = qm_xor[2];
			qm[3] = qm_xor[3] ^ xnor_;
			qm[4] = qm_xor[4];
			qm[5] = qm_xor[5] ^ xnor_;
			qm[6] = qm_xor[6];
			qm[7] = qm_xor[7] ^ xnor_;
			qm[8] = !xnor_;
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

	always @(posedge clk) begin
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
		wire d1_co_unused;

		am_add #(.W(4)) a_d1 (.a({1'b0, ones4(d_a[3:0])}), .b({1'b0, ones4(d_a[7:4])}), .ci(1'b0),
			.s(d1), .co(d1_co_unused));
		wire xnor_ = d1 > 4'd4 || (d1 == 4'd4 && !d_a[0]);

`ifdef SYNTH_KINTEX7
		wire [7:0] qm_xor;
		assign qm_xor[0] = d_b[0];
		assign qm_xor[1] = d_b[0] ^ d_b[1];
		assign qm_xor[2] = qm_xor[1] ^ d_b[2];
		assign qm_xor[3] = qm_xor[2] ^ d_b[3];
		assign qm_xor[4] = qm_xor[3] ^ d_b[4];
		assign qm_xor[5] = qm_xor[4] ^ d_b[5];
		assign qm_xor[6] = qm_xor[5] ^ d_b[6];
		assign qm_xor[7] = qm_xor[6] ^ d_b[7];

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
		always @(posedge clk) begin
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
`else
		always @(posedge clk)
			if (rst_high)
				s1_qm[c] <= 9'd0;
			else
				s1_qm[c] <= qm(d_b, xnor_);

		/* Stage 2: the DC balance. */
		wire [8:0] q = s1_qm[c];
		wire [3:0] n1;
		wire n1_co_unused;

		am_add #(.W(4)) a_n1 (.a({1'b0, ones4(q[3:0])}), .b({1'b0, ones4(q[7:4])}), .ci(1'b0),
			.s(n1), .co(n1_co_unused));
`endif
		reg [4:0] cnt;	/* running disparity, signed, even */
		reg [9:0] out;
		/* n1 - n0 = 2 * n1 - 8, signed in 5 bits. */
		wire [4:0] diff;
		wire diff_bo_unused;

		am_sub #(.W(5)) s_diff (.a({n1, 1'b0}), .b(5'd8), .bi(1'b0), .d(diff), .bo(diff_bo_unused));
		wire balanced = cnt == 5'd0 || n1 == 4'd4;
		wire same_sign = (!cnt[4] && !diff[4] && diff != 5'd0) ||
			(cnt[4] && diff[4]);

		/*
		 * The next disparity: compute delta in parallel with cnt, then single 5-bit adder:
		 * balanced: delta = q[8] ? diff : -diff;
		 * same_sign: delta = 2 q[8] - diff;
		 * otherwise: delta = diff - 2 !q[8].
		 */
		wire [4:0] inv_diff;
		wire inv_diff_bo;
		am_sub #(.W(5)) s_inv_diff (.a(5'd0), .b(diff), .bi(1'b0), .d(inv_diff), .bo(inv_diff_bo));
		wire [4:0] delta_balanced = q[8] ? diff : inv_diff;

		wire [4:0] q8_two = {3'd0, q[8], 1'b0};
		wire [4:0] nq8_two = {3'd0, !q[8], 1'b0};
		wire [4:0] delta_same, delta_diff;
		wire [1:0] delta_bo_unused;
		am_sub #(.W(5)) s_d_same (.a(q8_two), .b(diff), .bi(1'b0), .d(delta_same), .bo(delta_bo_unused[0]));
		am_sub #(.W(5)) s_d_diff (.a(diff), .b(nq8_two), .bi(1'b0), .d(delta_diff), .bo(delta_bo_unused[1]));

		wire [4:0] delta = balanced ? delta_balanced : (same_sign ? delta_same : delta_diff);
		wire [4:0] cnt_next;
		wire cnt_next_co_unused;
		am_add #(.W(5)) a_cnt (.a(cnt), .b(delta), .ci(1'b0), .s(cnt_next), .co(cnt_next_co_unused));
		assign tmds[10*c +: 10] = out;

		always @(posedge clk) begin
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

		wire unused_ok = &{1'b0, d1_co_unused, n1_co_unused, diff_bo_unused, inv_diff_bo, delta_bo_unused,
			cnt_next_co_unused};
	end
	endgenerate
endmodule

`default_nettype wire
