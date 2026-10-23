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
 * spec/dc/atg_dc_tmds.md.
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
	/* Stage 1: q_m of each channel. */
	function [8:0] qm;
		input [7:0] d;
		reg [3:0] n1;
		reg xnor_;
		integer i;
		begin
			n1 = 4'd0;
			for (i = 0; i < 8; i = i + 1)
				n1 = n1 + {3'd0, d[i]};
			xnor_ = n1 > 4'd4 || (n1 == 4'd4 && !d[0]);
			qm[0] = d[0];
			for (i = 1; i < 8; i = i + 1)
				qm[i] = xnor_ ? !(qm[i - 1] ^ d[i]) : qm[i - 1] ^ d[i];
			qm[8] = !xnor_;
		end
	endfunction

	wire [8:0] qm0 = qm(rgb[7:0]);
	wire [8:0] qm1 = qm(rgb[15:8]);
	wire [8:0] qm2 = qm(rgb[23:16]);
	reg [8:0] s1_qm [0:2];
	reg [1:0] s1_ctrl [0:2];
	reg s1_de;

	always @(posedge clk) begin
		if (!rst_n) begin
			s1_de <= 1'b0;
			s1_qm[0] <= 9'd0;
			s1_qm[1] <= 9'd0;
			s1_qm[2] <= 9'd0;
			s1_ctrl[0] <= 2'd0;
			s1_ctrl[1] <= 2'd0;
			s1_ctrl[2] <= 2'd0;
		end else begin
			s1_de <= de;
			s1_qm[0] <= qm0;
			s1_qm[1] <= qm1;
			s1_qm[2] <= qm2;
			s1_ctrl[0] <= {vs, hs};
			s1_ctrl[1] <= 2'd0;
			s1_ctrl[2] <= 2'd0;
		end
	end

	/* Stage 2: the DC balance, per channel. */
	genvar c;
	generate
	for (c = 0; c < 3; c = c + 1) begin : g_ch
		wire [8:0] q = s1_qm[c];
		reg [4:0] cnt;	/* running disparity, signed, even */
		reg [9:0] out;
		wire [3:0] n1 = {3'd0, q[0]} + {3'd0, q[1]} + {3'd0, q[2]} + {3'd0, q[3]} +
			{3'd0, q[4]} + {3'd0, q[5]} + {3'd0, q[6]} + {3'd0, q[7]};
		/* n1 - n0 = 2 * n1 - 8, signed in 5 bits. */
		wire [4:0] diff = {n1, 1'b0} - 5'd8;
		wire balanced = cnt == 5'd0 || n1 == 4'd4;
		wire same_sign = (!cnt[4] && !diff[4] && diff != 5'd0) ||
			(cnt[4] && diff[4]);
		assign tmds[10*c +: 10] = out;

		always @(posedge clk) begin
			if (!rst_n) begin
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
				cnt <= q[8] ? cnt + diff : cnt - diff;
			end else if (same_sign) begin
				out <= {1'b1, q[8], ~q[7:0]};
				cnt <= cnt + {3'd0, q[8], 1'b0} - diff;
			end else begin
				out <= {1'b0, q[8], q[7:0]};
				cnt <= cnt - {3'd0, !q[8], 1'b0} + diff;
			end
		end
	end
	endgenerate
endmodule

`default_nettype wire
