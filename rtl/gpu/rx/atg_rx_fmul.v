/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_fmul: the RX's fp32 multiplier, a 4-stage pipeline (one
 * operation per cycle, the result exactly 4 cycles after i_valid), with
 * the rules of atg_rx_fadd (RNE, denormals flushed, canonical NaN).
 * See spec/gpu/rx/atg_rx_fmul.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_fmul (
	input wire clk,
	input wire rst_n,
	input wire i_valid,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	output reg o_valid,
	output reg [31:0] o_r
);
	/* Stage 1: unpack and the special cases. */
	wire [7:0] ea = i_a[30:23];
	wire [7:0] eb = i_b[30:23];
	wire za = ea == 8'd0;
	wire zb = eb == 8'd0;
	wire nan_a = ea == 8'hFF && i_a[22:0] != 23'd0;
	wire nan_b = eb == 8'hFF && i_b[22:0] != 23'd0;
	wire inf_a = ea == 8'hFF && i_a[22:0] == 23'd0;
	wire inf_b = eb == 8'hFF && i_b[22:0] == 23'd0;
	wire s = i_a[31] ^ i_b[31];
	/* the exponent ea + eb - 127 */
	wire [9:0] eab, e_n;
	wire eab_co_unused, en_bo_unused;
	am_add #(.W(10)) u_eab (.a({2'b00, ea}), .b({2'b00, eb}), .ci(1'b0), .s(eab), .co(eab_co_unused));
	am_sub #(.W(10)) u_e_n (.a(eab), .b(10'd127), .bi(1'b0), .d(e_n), .bo(en_bo_unused));

	reg v1, sp1, s1;
	reg [31:0] spv1;
	reg [9:0] e1;
	reg [23:0] ma1, mb1;

	always @(posedge clk) begin
		v1 <= rst_n && i_valid;
		s1 <= s;
		sp1 <= 1'b1;
		spv1 <= {s, 31'd0};
		if (nan_a || nan_b || ((inf_a || inf_b) && (za || zb)))
			spv1 <= 32'h7FC00000;
		else if (inf_a || inf_b)
			spv1 <= {s, 8'hFF, 23'd0};
		else if (!za && !zb)
			sp1 <= 1'b0;
		e1 <= e_n;
		ma1 <= {1'b1, i_a[22:0]};
		mb1 <= {1'b1, i_b[22:0]};
	end

	/* Stage 2: the product (DSPs). */
	reg v2, sp2, s2;
	reg [31:0] spv2;
	reg [9:0] e2;
	reg [47:0] p2;
	wire [47:0] p1;
	am_mul #(.AW(24), .BW(24)) u_p1 (.clk(clk), .en(1'b1), .a(ma1), .b(mb1), .p(p1));
	/* stage 3's exponent: + 1 for a product in [2, 4) */
	wire [9:0] e2n;
	wire e2n_co_unused;
	am_add #(.W(10)) u_e2n (.a(e2), .b(10'd0), .ci(p2[47]), .s(e2n), .co(e2n_co_unused));

	always @(posedge clk) begin
		v2 <= rst_n && v1;
		sp2 <= sp1;
		spv2 <= spv1;
		s2 <= s1;
		e2 <= e1;
		p2 <= p1;
	end

	/* Stage 3: normalise (the product is in [1, 4)). */
	reg v3, sp3, s3, g3, st3;
	reg [31:0] spv3;
	reg [9:0] e3;
	reg [23:0] m3;

	always @(posedge clk) begin
		v3 <= rst_n && v2;
		sp3 <= sp2;
		spv3 <= spv2;
		s3 <= s2;
		if (p2[47]) begin
			m3 <= p2[47:24];
			g3 <= p2[23];
			st3 <= p2[22:0] != 23'd0;
			e3 <= e2n;
		end else begin
			m3 <= p2[46:23];
			g3 <= p2[22];
			st3 <= p2[21:0] != 22'd0;
			e3 <= e2n;
		end
	end

	/* Stage 4: round to nearest even, pack. */
	wire [24:0] m0;
	wire [9:0] e;
	wire m0_co_unused, e_co_unused;
	am_add #(.W(25)) u_m0 (.a({1'b0, m3}), .b(25'd0), .ci(g3 && (st3 || m3[0])), .s(m0),
		.co(m0_co_unused));
	wire [24:0] m = m0[24] ? {1'b0, m0[24:1]} : m0;
	am_add #(.W(10)) u_e (.a(e3), .b(10'd0), .ci(m0[24]), .s(e), .co(e_co_unused));
	wire unused_m = &{1'b0, m[24:23]};

	always @(posedge clk) begin
		o_valid <= rst_n && v3;
		if (sp3)
			o_r <= spv3;
		else if (!e[9] && e >= 10'd255)
			o_r <= {s3, 8'hFF, 23'd0};
		else if (e[9] || e == 10'd0)
			o_r <= {s3, 31'd0};
		else
			o_r <= {s3, e[7:0], m[22:0]};
	end
endmodule

`default_nettype wire
