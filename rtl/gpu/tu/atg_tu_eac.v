/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_eac: one EAC block's value of a texel for atg_tu_etc (the Khronos
 * Data Format Specification's EAC text; tools/etcmodel.py the reference,
 * bit for bit): i_w the block as its 64-bit big-endian integer, i_k =
 * {column, row}; i_r11: R11 (else RGBA8's 8-bit alpha), i_sg signed R11.
 * 8-bit alpha: base + modifier x multiplier, clamped to [0, 255]; R11:
 * base x 8 + 4 + modifier x multiplier x 8 (multiplier 0: the modifier
 * alone), clamped to [0, 2047]; signed R11: base x 8 (base -128 as -127)
 * + the same, clamped to [-1023, 1023] (two's complement).
 *
 * Pipelined, no stall: the inputs in cycle 0; E1 the modifier (the table
 * and the index) and the base, R1; E1b the modifier times the multiplier
 * (shifts and adds), R2; E2 the sum and the clamp: o_v in cycle 2,
 * combinational (atg_tu_etc registers it).
 * See spec/gpu/tu/atg_tu_etc.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_eac (
	input wire clk,
	input wire [63:0] i_w,
	input wire [3:0] i_k,
	input wire i_r11,
	input wire i_sg,
	output wire [10:0] o_v
);
	/* -x as 5 bits (x below 16). */
	function [4:0] neg5;
		input [3:0] x;
		case (x)
		4'd0: neg5 = 5'h00;
		4'd1: neg5 = 5'h1F;
		4'd2: neg5 = 5'h1E;
		4'd3: neg5 = 5'h1D;
		4'd4: neg5 = 5'h1C;
		4'd5: neg5 = 5'h1B;
		4'd6: neg5 = 5'h1A;
		4'd7: neg5 = 5'h19;
		4'd8: neg5 = 5'h18;
		4'd9: neg5 = 5'h17;
		4'd10: neg5 = 5'h16;
		4'd11: neg5 = 5'h15;
		4'd12: neg5 = 5'h14;
		4'd13: neg5 = 5'h13;
		4'd14: neg5 = 5'h12;
		default: neg5 = 5'h11;
		endcase
	endfunction

	/* The EAC modifier of table ti, index ix (signed). */
	function [4:0] eacm;
		input [3:0] ti;
		input [2:0] ix;
		reg [31:0] r;	/* the row: eight 4-bit magnitudes, the first four negative */
		reg [3:0] mg;
		begin
			case (ti)
			4'd0: r = 32'hE852F963;
			4'd1: r = 32'hC962DA73;
			4'd2: r = 32'hC741D852;
			4'd3: r = 32'hC531D642;
			4'd4: r = 32'hB752C863;
			4'd5: r = 32'hA862B973;
			4'd6: r = 32'hA763B874;
			4'd7: r = 32'hA742B853;
			4'd8: r = 32'h9751A862;
			4'd9: r = 32'h9741A852;
			4'd10: r = 32'h9731A842;
			4'd11: r = 32'h9641A752;
			4'd12: r = 32'h9632A743;
			4'd13: r = 32'h9210A321;
			4'd14: r = 32'h87539864;
			default: r = 32'h86429753;
			endcase
			mg = r[4 * ix +: 4];
			eacm = ix[2] ? {1'b0, mg} : neg5(mg);
		end
	endfunction

	/* The bit position of texel k's 3-bit index in an EAC block: 45 - 3k. */
	function [5:0] eacp;
		input [3:0] k;
		case (k)
		4'd0: eacp = 6'd45;
		4'd1: eacp = 6'd42;
		4'd2: eacp = 6'd39;
		4'd3: eacp = 6'd36;
		4'd4: eacp = 6'd33;
		4'd5: eacp = 6'd30;
		4'd6: eacp = 6'd27;
		4'd7: eacp = 6'd24;
		4'd8: eacp = 6'd21;
		4'd9: eacp = 6'd18;
		4'd10: eacp = 6'd15;
		4'd11: eacp = 6'd12;
		4'd12: eacp = 6'd9;
		4'd13: eacp = 6'd6;
		4'd14: eacp = 6'd3;
		default: eacp = 6'd0;
		endcase
	endfunction

	/* ---- E0 -> E1 ---- */
	wire [4:0] m = eacm(i_w[51:48], i_w[eacp(i_k) +: 3]);
	wire [13:0] vb = !i_r11 ? {6'd0, i_w[63:56]} : !i_sg ? {3'd0, i_w[63:56], 3'd4} :
		i_w[63:56] == 8'h80 ? -14'sd1016 : {{3{i_w[63]}}, i_w[63:56], 3'd0};

	(* extract_reset = "no", max_fanout = 16 *) reg [4:0] m1;
	(* extract_reset = "no", max_fanout = 16 *) reg [3:0] mu1;
	(* extract_reset = "no", max_fanout = 16 *) reg t0_sh0, t0_sh3;
	(* extract_reset = "no" *) reg [13:0] vb1;
	(* extract_reset = "no", max_fanout = 16 *) reg r11_1, sg1;
	always @(posedge clk) begin
		m1 <= m;
		mu1 <= i_w[55:52];
		t0_sh0 <= (!i_r11 && i_w[52]) || (i_r11 && i_w[55:52] == 4'd0);
		t0_sh3 <= i_r11 && i_w[52];
		vb1 <= vb;
		r11_1 <= i_r11;
		sg1 <= i_sg;
	end

	/* ---- E1 -> E1b: partial products of m times the multiplier ---- */
	wire [13:0] ms = {{9{m1[4]}}, m1};
	wire [13:0] t0 = (t0_sh0 ? ms : 14'd0) | (t0_sh3 ? {ms[10:0], 3'b000} : 14'd0);
	wire [13:0] t1 = !r11_1 ? (mu1[1] ? {ms[12:0], 1'b0} : 14'd0) :
		(mu1[1] ? {ms[9:0], 4'b0000} : 14'd0);
	wire [13:0] t2 = !r11_1 ? (mu1[2] ? {ms[11:0], 2'b00} : 14'd0) :
		(mu1[2] ? {ms[8:0], 5'b00000} : 14'd0);
	wire [13:0] t3 = !r11_1 ? (mu1[3] ? {ms[10:0], 3'b000} : 14'd0) :
		(mu1[3] ? {ms[7:0], 6'b000000} : 14'd0);
	wire [13:0] s01, s23;
	wire [2:0] e_nc;

	am_add #(.W(14)) u_s01 (.a(t0), .b(t1), .ci(1'b0), .s(s01), .co(e_nc[0]));
	am_add #(.W(14)) u_s23 (.a(t2), .b(t3), .ci(1'b0), .s(s23), .co(e_nc[1]));

	(* extract_reset = "no" *) reg [13:0] vb2, s01_2, s23_2;
	(* extract_reset = "no" *) reg r11_2, sg2;
	always @(posedge clk) begin
		vb2 <= vb1;
		s01_2 <= s01;
		s23_2 <= s23;
		r11_2 <= r11_1;
		sg2 <= sg1;
	end

	/* ---- E1b -> E2: 3:2 carry-save + final adder ---- */
	wire [13:0] ev_s = vb2 ^ s01_2 ^ s23_2;
	wire [13:0] ev_c = {(vb2[12:0] & s01_2[12:0]) | (vb2[12:0] & s23_2[12:0]) |
		(s01_2[12:0] & s23_2[12:0]), 1'b0};
	wire [13:0] ev;

	am_add #(.W(14)) u_ev (.a(ev_s), .b(ev_c), .ci(1'b0), .s(ev), .co(e_nc[2]));

	(* extract_reset = "no", max_fanout = 16 *) reg [13:0] ev3;
	(* extract_reset = "no", max_fanout = 16 *) reg r11_3, sg3;
	always @(posedge clk) begin
		ev3 <= ev;
		r11_3 <= r11_2;
		sg3 <= sg2;
	end

	/* ---- E2: the clamp ---- */
	wire signed [13:0] v = ev3;
	assign o_v = !r11_3 ? {3'd0, v < 0 ? 8'd0 : v > 255 ? 8'd255 : v[7:0]} :
		!sg3 ? (v < 0 ? 11'd0 : v > 2047 ? 11'd2047 : v[10:0]) :
		(v < -1023 ? 11'h401 : v > 1023 ? 11'h3FF : v[10:0]);

	wire unused_ok = &{1'b0, e_nc, mu1[0]};
endmodule

`default_nettype wire
