/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_h2f: fp16 to fp32, exactly (half denormals normalised,
 * infinities kept, NaN 0x7FC00000); the former function atg_fmt_h2f of
 * include/atg_fmt_unpack.vh (tools/fmtmodel.py).  atg_fmt_comp has the
 * same normalisation for every small float of a texel.  Combinational.
 * See spec/gpu/fmt/atg_fmt_h2f.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_h2f (
	input wire [15:0] h,
	output wire [31:0] f
);
	/* lz: the leading zeros of the fraction (0 for 0) */
	reg [3:0] lz;
	reg found;
	always @(*) begin
		found = 1'b1;
		casez (h[9:0])
		10'b1?????????: lz = 4'd0;
		10'b01????????: lz = 4'd1;
		10'b001???????: lz = 4'd2;
		10'b0001??????: lz = 4'd3;
		10'b00001?????: lz = 4'd4;
		10'b000001????: lz = 4'd5;
		10'b0000001???: lz = 4'd6;
		10'b00000001??: lz = 4'd7;
		10'b000000001?: lz = 4'd8;
		10'b0000000001: lz = 4'd9;
		default: begin
			lz = 4'd0;
			found = 1'b0;
		end
		endcase
	end
	/* a denormal: the bits below the leading one, exponent 112 - lz; a
	 * normal number: exponent e + 112 */
	wire [3:0] lz1;
	wire [9:0] fr;
	wire [7:0] ed, en;
	wire [2:0] carry_unused;
	am_add #(.W(4)) u_lz1 (.a(lz), .b(4'd0), .ci(1'b1), .s(lz1), .co(carry_unused[0]));
	am_shift #(.W(10), .SW(4)) u_fr (.a(h[9:0]), .amt(lz1), .left(1'b1), .arith(1'b0), .y(fr));
	am_sub #(.W(8)) u_ed (.a(8'd112), .b({4'd0, lz}), .bi(1'b0), .d(ed), .bo(carry_unused[1]));
	am_add #(.W(8)) u_en (.a({3'd0, h[14:10]}), .b(8'd112), .ci(1'b0), .s(en), .co(carry_unused[2]));
	assign f = h[14:10] == 5'd31 ? (h[9:0] != 10'd0 ? 32'h7FC00000 : {h[15], 31'h7F800000}) :
		h[14:10] == 5'd0 ? (h[9:0] == 10'd0 ? {h[15], 31'd0} : {h[15], ed, fr, 13'd0}) :
		{h[15], en, h[9:0], 13'd0};

	wire unused_ok = &{1'b0, carry_unused, found};
endmodule

`default_nettype wire
