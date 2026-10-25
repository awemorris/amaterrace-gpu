/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_i2f: a W-bit signed integer v over 2^F (|v| < 2^(W-1)) to fp32,
 * exact (W <= 23).  The former functions i2f8 of atg_rx_bary (W 21,
 * F 3) and i2f of atg_rx_scan and atg_rx_frag (W 17, F 0).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_i2f #(
	parameter W = 17,	/* input bits, sign included */
	parameter F = 0	/* fraction bits of the input */
) (
	input wire [W-1:0] v,
	output wire [31:0] f
);
	localparam [7:0] E0 = 127 + W - 1 - F;	/* the exponent of a value at bit W - 1 */
	localparam [4:0] TOP = W - 1;
	/* |v|, normalised to bit W - 1; the exponent E0 - lz */
	wire [W-1:0] m, mn;
	wire [7:0] e;
	wire m_co_unused, e_bo_unused;
	am_addsub #(.W(W)) u_m (.a({W{1'b0}}), .b(v), .sub(v[W-1]), .s(m), .co(m_co_unused));
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

	wire [22:0] frac = {mn[W-2:0], {(24 - W){1'b0}}};
	assign f = m == {W{1'b0}} ? 32'd0 : {v[W-1], e, frac};

	wire unused_ok = &{1'b0, mn[W-1]};
endmodule

`default_nettype wire
