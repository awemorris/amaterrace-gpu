/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_avg: the integer averages of the blitter's RESOLVE (docs/ghci.md
 * sections 8.2 and 8.5), combinational.  The input holds up to four
 * pixels of four samples each, sample s of pixel p at sample slot 4 p + s,
 * one slot per pixel (ps = 2^psl bytes: slot k at bits 8 ps k); the output
 * holds the pixels' averages, pixel p at bits 8 ps p (as many pixels as
 * fit 128 bits; the rest 0):
 *
 *   fmt 0 UNORM8           every byte an unsigned normalized channel
 *                          (pixels of 1, 2 or 4 bytes)
 *   fmt 1 UNORM565         the fields [15:11], [10:5], [4:0]
 *   fmt 6 UNORM2_10_10_10  the fields [31:30], [29:20], [19:10], [9:0]
 *   fmt 7 UNORM1555        the fields [15], [14:10], [9:5], [4:0]
 *   fmt 2 SAMPLE0 (and 3-5, which atg_blt_favg averages)  sample 0
 *
 * A field's average is the sum of the four samples' codes divided by 4,
 * rounded to the nearest code, ties to even.  See spec/gpu/blt/atg_blt_avg.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_avg (
	input wire [2:0] fmt,
	input wire [2:0] psl,	/* log2 of the pixel's bytes */
	input wire [511:0] in_s,
	output reg [127:0] out_p
);
	/* SAMPLE0: the bytes of sample 0 of each pixel, for a pixel of 2^pl bytes (pl constant). */
	function [127:0] sample0;
		input [2:0] pl;
		input [511:0] x;
		integer p, k, ps;
		reg [127:0] o;
		begin
			o = 128'd0;
			ps = 1 << pl;
			for (p = 0; p < 4; p = p + 1)
				for (k = 0; k < 16; k = k + 1)
					if (k < ps && ps * p + k < 16)
						o[8 * (ps * p + k) +: 8] = x[8 * (ps * 4 * p + k) +: 8];
			sample0 = o;
		end
	endfunction

	/*
	 * Sixteen averagers, one for channel c of pixel p (j = 4 p + c): the
	 * sum of the four samples' codes (at most 4 x 1023) and its quarter,
	 * rounded to the nearest code, ties to even.  The samples' words and
	 * the codes are chosen by the format and the pixel size: UNORM8 byte c
	 * of a pixel of 1, 2 or 4 bytes, or field c of a 16- or 32-bit pixel.
	 */
	wire [159:0] q;	/* average j at bits 10 j */

	(* keep = "true" *) wire [11:0] p_fmt_px = {4{fmt}};
	(* keep = "true" *) wire [11:0] p_psl_px = {4{psl}};

	genvar j, sm;
	generate
	for (j = 0; j < 16; j = j + 1) begin : g_avg
		localparam integer PP = j / 4;
		localparam integer CH = j % 4;
		wire [9:0] v [0:3];

		for (sm = 0; sm < 4; sm = sm + 1) begin : g_s
			localparam integer S_SLOT = 4 * PP + sm;
			wire [7:0] in_b = in_s[8 * S_SLOT +: 8];
			wire [15:0] in_h = in_s[16 * S_SLOT +: 16];
			wire [31:0] in_w = in_s[32 * S_SLOT +: 32];
			reg [9:0] v_val;

			always @(*) begin
				case (p_fmt_px[3 * PP +: 3])
				3'd0: begin
					case (p_psl_px[3 * PP +: 3])
					3'd0: v_val = (CH == 0) ? {2'd0, in_b} : 10'd0;
					3'd1: v_val = (CH == 0) ? {2'd0, in_h[7:0]} : (CH == 1) ? {2'd0, in_h[15:8]} : 10'd0;
					3'd2: v_val = (CH == 0) ? {2'd0, in_w[7:0]} : (CH == 1) ? {2'd0, in_w[15:8]} : (CH == 2) ? {2'd0, in_w[23:16]} : {2'd0, in_w[31:24]};
					default: v_val = 10'd0;
					endcase
				end
				3'd1: begin
					case (CH)
					0: v_val = {5'd0, in_h[4:0]};
					1: v_val = {4'd0, in_h[10:5]};
					2: v_val = {5'd0, in_h[15:11]};
					default: v_val = 10'd0;
					endcase
				end
				3'd6: begin
					case (CH)
					0: v_val = in_w[9:0];
					1: v_val = in_w[19:10];
					2: v_val = in_w[29:20];
					default: v_val = {8'd0, in_w[31:30]};
					endcase
				end
				3'd7: begin
					case (CH)
					0: v_val = {5'd0, in_h[4:0]};
					1: v_val = {5'd0, in_h[9:5]};
					2: v_val = {5'd0, in_h[14:10]};
					default: v_val = {9'd0, in_h[15]};
					endcase
				end
				default: v_val = 10'd0;
				endcase
			end
			assign v[sm] = v_val;
		end

		wire [11:0] s01, s23, sum;
		wire [2:0] sum_co_unused;
		wire q_co_unused;

		am_add #(.W(12)) a_01 (.a({2'd0, v[0]}), .b({2'd0, v[1]}), .ci(1'b0), .s(s01), .co(sum_co_unused[0]));
		am_add #(.W(12)) a_23 (.a({2'd0, v[2]}), .b({2'd0, v[3]}), .ci(1'b0), .s(s23), .co(sum_co_unused[1]));
		am_add #(.W(12)) a_s (.a(s01), .b(s23), .ci(1'b0), .s(sum), .co(sum_co_unused[2]));
`ifdef MUT_RSV_RNE
		wire round_up = sum[1];
`else
		wire round_up = sum[1] && (sum[0] || sum[2]);
`endif
		am_add #(.W(10)) a_q (.a(sum[11:2]), .b(10'd0), .ci(round_up), .s(q[10 * j +: 10]), .co(q_co_unused));

		wire unused_ok = &{1'b0, sum_co_unused, q_co_unused};
	end
	endgenerate

	wire [127:0] px_fields;
	genvar p_gen;
	generate
	for (p_gen = 0; p_gen < 4; p_gen = p_gen + 1) begin : g_fields
		wire [9:0] q0 = q[10 * (4 * p_gen + 0) +: 10];
		wire [9:0] q1 = q[10 * (4 * p_gen + 1) +: 10];
		wire [9:0] q2 = q[10 * (4 * p_gen + 2) +: 10];
		wire [9:0] q3 = q[10 * (4 * p_gen + 3) +: 10];
		assign px_fields[32 * p_gen +: 32] =
			(p_fmt_px[3 * p_gen +: 3] == 3'd6) ? {q3[1:0], q2[9:0], q1[9:0], q0[9:0]} :
			(p_fmt_px[3 * p_gen +: 3] == 3'd1) ? {16'd0, q2[4:0], q1[5:0], q0[4:0]} :
			/* fmt == 3'd7 */ {16'd0, q3[0], q2[4:0], q1[4:0], q0[4:0]};
	end
	endgenerate

	/* The output pixels of each format and pixel size. */
	integer pp, cc;

	always @(*) begin
		out_p = 128'd0;
		case (fmt)
		3'd0: begin
			case (psl)
			3'd0: begin
				for (pp = 0; pp < 4; pp = pp + 1)
					out_p[8 * pp +: 8] = q[10 * (4 * pp) +: 8];
			end
			3'd1: begin
				for (pp = 0; pp < 4; pp = pp + 1)
					for (cc = 0; cc < 2; cc = cc + 1)
						out_p[8 * (2 * pp + cc) +: 8] = q[10 * (4 * pp + cc) +: 8];
			end
			3'd2: begin
				for (pp = 0; pp < 4; pp = pp + 1)
					for (cc = 0; cc < 4; cc = cc + 1)
						out_p[8 * (4 * pp + cc) +: 8] = q[10 * (4 * pp + cc) +: 8];
			end
			default: out_p = 128'd0;
			endcase
		end
		3'd1, 3'd7: begin
			for (pp = 0; pp < 4; pp = pp + 1)
				out_p[16 * pp +: 16] = px_fields[32 * pp +: 16];
		end
		3'd6: begin
			out_p = px_fields;
		end
		default: begin
			case (psl)
			3'd0: out_p = sample0(3'd0, in_s);
			3'd1: out_p = sample0(3'd1, in_s);
			3'd2: out_p = sample0(3'd2, in_s);
			3'd3: out_p = sample0(3'd3, in_s);
			3'd4: out_p = sample0(3'd4, in_s);
			default: out_p = sample0(3'd5, in_s);
			endcase
		end
		endcase
	end

endmodule

`default_nettype wire
