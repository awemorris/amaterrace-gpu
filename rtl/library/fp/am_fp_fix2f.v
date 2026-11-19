/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fp_fix2f: converts a W-bit fixed-point/integer value v (F fractional bits)
 * to IEEE 754 fp32, exact (when W - SIGNED <= 24). Combinational.
 * Promoted from atg_rx_i2f for library-wide usage.
 * See spec/library/fp/am_fp_fix2f.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_fp_fix2f #(
	parameter W = 17,       /* input bits */
	parameter F = 0,        /* fraction bits */
	parameter SIGNED = 1    /* 1 = signed (two's complement), 0 = unsigned */
) (
	input wire [W-1:0] v,
	output wire [31:0] f
);
	localparam [7:0] E0 = 127 + W - 1 - F;
	localparam [4:0] TOP = W - 1;

	wire sign = SIGNED ? v[W-1] : 1'b0;
	wire [W-1:0] m;
	wire m_co_unused;

	generate
		if (SIGNED) begin : g_signed
			am_addsub #(.W(W)) u_m (.a({W{1'b0}}), .b(v), .sub(sign), .s(m), .co(m_co_unused));
		end else begin : g_unsigned
			assign m = v;
			assign m_co_unused = 1'b0;
		end
	endgenerate

	/* Parallel-prefix OR from MSB down to build 1-hot lead_1h (zero am_msb / am_sub / am_shift chain). */
	wire [31:0] m32 = {{(32-W){1'b0}}, m};
	wire [31:0] p1  = m32 | {1'b0,  m32[31:1]};
	wire [31:0] p2  = p1  | {2'b0,  p1[31:2]};
	wire [31:0] p4  = p2  | {4'b0,  p2[31:4]};
	wire [31:0] p8  = p4  | {8'b0,  p4[31:8]};
	wire [31:0] p16 = p8  | {16'b0, p8[31:16]};
	wire [W-1:0] lead_1h = m & ~p16[W:1];

	/* Direct 1-hot mux for exponent (e = 127 - F + msb_idx) and aligned 24-bit mantissa (bit 23 implicit). */
	wire [8*W-1:0] e_row;
	wire [24*W-1:0] mn_row;
	genvar gb;
	generate
		for (gb = 0; gb < W; gb = gb + 1) begin : g_1h
			localparam [7:0] E_VAL = 127 - F + gb;
			assign e_row[gb*8 +: 8] = lead_1h[gb] ? E_VAL : 8'd0;
			if (gb >= 23) begin : g_rsh
				wire [31:0] tmp = m32 >> (gb - 23);
				assign mn_row[gb*24 +: 24] = lead_1h[gb] ? tmp[23:0] : 24'd0;
			end else begin : g_lsh
				wire [31:0] tmp = m32 << (23 - gb);
				assign mn_row[gb*24 +: 24] = lead_1h[gb] ? tmp[23:0] : 24'd0;
			end
		end
	endgenerate
	reg [7:0] e;
	reg [23:0] mn24;
	integer bi;
	always @(*) begin
		e = 8'd0;
		mn24 = 24'd0;
		for (bi = 0; bi < W; bi = bi + 1) begin
			e = e | e_row[bi*8 +: 8];
			mn24 = mn24 | mn_row[bi*24 +: 24];
		end
	end

	wire [22:0] frac = mn24[22:0];
	assign f = (m == {W{1'b0}}) ? 32'd0 : {sign, e, frac};

	wire unused_ok = &{1'b0, mn24[23], m_co_unused, p16[31:W], TOP, E0};
endmodule

`default_nettype wire
