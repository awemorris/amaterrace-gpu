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
	wire [W-1:0] m, mn;
	wire [7:0] e;
	wire m_co_unused, e_bo_unused;

	generate
		if (SIGNED) begin : g_signed
			am_addsub #(.W(W)) u_m (.a({W{1'b0}}), .b(v), .sub(sign), .s(m), .co(m_co_unused));
		end else begin : g_unsigned
			assign m = v;
			assign m_co_unused = 1'b0;
		end
	endgenerate

	reg [4:0] lz;
	integer b;
	always @(*) begin
		lz = 5'd0;
		for (b = 0; b < W; b = b + 1)
			if (m[b])
				lz = TOP - b[4:0];
	end

	am_shift #(.W(W), .SW(5)) u_mn (.a(m), .amt(lz), .left(1'b1), .arith(1'b0), .y(mn));
	am_sub #(.W(8)) u_e (.a(E0), .b({3'd0, lz}), .bi(1'b0), .d(e), .bo(e_bo_unused));

	localparam PAD = 24 - W;
	wire [22:0] frac;
	generate
		if (PAD == 0) begin : g_frac_exact
			assign frac = mn[22:0];
		end else if (PAD > 0) begin : g_frac_pad
			assign frac = {mn[W-2:0], {PAD{1'b0}}};
		end else begin : g_frac_trunc
			assign frac = mn[W-2:W-24];
		end
	endgenerate
	assign f = (m == {W{1'b0}}) ? 32'd0 : {sign, e, frac};

	wire unused_ok = &{1'b0, mn[W-1], e_bo_unused, m_co_unused};
endmodule

`default_nettype wire
