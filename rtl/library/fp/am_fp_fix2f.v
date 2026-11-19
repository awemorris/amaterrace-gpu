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

	/* Nibble-grouped leading-one detector + tree OR (replaces 5-stage prefix OR + serial OR loop). */
	localparam integer N_NIB = (W + 3) / 4;
	wire [31:0] m32 = {{(32-W){1'b0}}, m};
	wire [4*N_NIB-1:0] m_pad = {{(4*N_NIB-W){1'b0}}, m};
	wire [N_NIB-1:0] nib_nz, nib_1h;
	wire [4*N_NIB-1:0] nib_l1h;
	genvar gn, gb;
	generate
		for (gn = 0; gn < N_NIB; gn = gn + 1) begin : g_nib
			wire [3:0] nv = m_pad[4*gn +: 4];
			assign nib_nz[gn] = |nv;
			assign nib_l1h[4*gn + 3] =  nv[3];
			assign nib_l1h[4*gn + 2] = !nv[3] &&  nv[2];
			assign nib_l1h[4*gn + 1] = !nv[3] && !nv[2] &&  nv[1];
			assign nib_l1h[4*gn + 0] = !nv[3] && !nv[2] && !nv[1] && nv[0];
			if (gn == N_NIB - 1) begin : g_top_nib
				assign nib_1h[gn] = nib_nz[gn];
			end else begin : g_lo_nib
				assign nib_1h[gn] = nib_nz[gn] && !(|nib_nz[N_NIB-1:gn+1]);
			end
		end
	endgenerate

	wire [W-1:0] lead_1h;
	wire [8*4*N_NIB-1:0] e_row;
	wire [24*4*N_NIB-1:0] mn_row;
	generate
		for (gb = 0; gb < 4 * N_NIB; gb = gb + 1) begin : g_1h
			if (gb < W) begin : g_active
				localparam [7:0] E_VAL = 127 - F + gb;
				assign lead_1h[gb] = nib_1h[gb / 4] && nib_l1h[gb];
				assign e_row[gb*8 +: 8] = lead_1h[gb] ? E_VAL : 8'd0;
				if (gb >= 23) begin : g_rsh
					wire [31:0] tmp = m32 >> (gb - 23);
					assign mn_row[gb*24 +: 24] = lead_1h[gb] ? tmp[23:0] : 24'd0;
				end else begin : g_lsh
					wire [31:0] tmp = m32 << (23 - gb);
					assign mn_row[gb*24 +: 24] = lead_1h[gb] ? tmp[23:0] : 24'd0;
				end
			end else begin : g_pad
				assign e_row[gb*8 +: 8] = 8'd0;
				assign mn_row[gb*24 +: 24] = 24'd0;
			end
		end
	endgenerate

	wire [8*N_NIB-1:0] e_nib;
	wire [24*N_NIB-1:0] mn_nib;
	generate
		for (gn = 0; gn < N_NIB; gn = gn + 1) begin : g_nib_or
			assign e_nib[gn*8 +: 8] =
				e_row[(gn*4+0)*8 +: 8] | e_row[(gn*4+1)*8 +: 8] |
				e_row[(gn*4+2)*8 +: 8] | e_row[(gn*4+3)*8 +: 8];
			assign mn_nib[gn*24 +: 24] =
				mn_row[(gn*4+0)*24 +: 24] | mn_row[(gn*4+1)*24 +: 24] |
				mn_row[(gn*4+2)*24 +: 24] | mn_row[(gn*4+3)*24 +: 24];
		end
	endgenerate

	reg [7:0] e;
	reg [23:0] mn24;
	integer bi;
	always @(*) begin
		e = 8'd0;
		mn24 = 24'd0;
		for (bi = 0; bi < N_NIB; bi = bi + 1) begin
			e = e | e_nib[bi*8 +: 8];
			mn24 = mn24 | mn_nib[bi*24 +: 24];
		end
	end

	wire [22:0] frac = mn24[22:0];
	assign f = (m == {W{1'b0}}) ? 32'd0 : {sign, e, frac};

	wire unused_ok = &{1'b0, mn24[23], m_co_unused, nib_l1h, TOP, E0};
endmodule

`default_nettype wire
