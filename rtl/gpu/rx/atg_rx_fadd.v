/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_fadd: the RX's fp32 adder, a 4-stage pipeline (one operation per
 * cycle, the result exactly 4 cycles after i_valid).  IEEE single, round
 * to nearest even, denormals flushed to zero on input and output, NaN
 * results the canonical 0x7FC00000 (design §3.1, the SU's rules).
 * i_sub negates b.  See spec/gpu/rx/atg_rx_fadd.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_fadd (
	input wire clk,
	input wire rst_n,
	input wire i_valid,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	input wire i_sub,
	output reg o_valid,
	output reg [31:0] o_r
);
	/* Stage 1: unpack, specials, order by magnitude. */
	wire [31:0] b_in = {i_b[31] ^ i_sub, i_b[30:0]};
	wire [7:0] ea = i_a[30:23];
	wire [7:0] eb = b_in[30:23];
	wire [23:0] ma = ea == 8'd0 ? 24'd0 : {1'b1, i_a[22:0]};
	wire [23:0] mb = eb == 8'd0 ? 24'd0 : {1'b1, b_in[22:0]};
	wire nan_a = ea == 8'hFF && i_a[22:0] != 23'd0;
	wire nan_b = eb == 8'hFF && b_in[22:0] != 23'd0;
	wire inf_a = ea == 8'hFF && i_a[22:0] == 23'd0;
	wire inf_b = eb == 8'hFF && b_in[22:0] == 23'd0;
	wire a_big = {ea, ma} >= {eb, mb};
	/* the exponent difference, larger minus smaller */
	wire [7:0] dab;
	wire dab_bo_unused;
	am_sub #(.W(8)) u_dab (.a(a_big ? ea : eb), .b(a_big ? eb : ea), .bi(1'b0), .d(dab),
		.bo(dab_bo_unused));

	reg v1, sp1, sx1, sub1;
	reg [31:0] spv1;
	reg [7:0] ex1, d1;
	reg [23:0] mx1, my1;

	always @(posedge clk) begin
		v1 <= rst_n && i_valid;
		sp1 <= 1'b1;
		spv1 <= 32'd0;
		if (nan_a || nan_b || (inf_a && inf_b && i_a[31] != b_in[31]))
			spv1 <= 32'h7FC00000;
		else if (inf_a)
			spv1 <= {i_a[31], 8'hFF, 23'd0};
		else if (inf_b)
			spv1 <= {b_in[31], 8'hFF, 23'd0};
		else if (ma == 24'd0 && mb == 24'd0)
			spv1 <= {i_a[31] && b_in[31], 31'd0};
		else
			sp1 <= 1'b0;
		sub1 <= i_a[31] != b_in[31];
		if (a_big) begin
			sx1 <= i_a[31];
			ex1 <= ea;
			mx1 <= ma;
			my1 <= mb;
			d1 <= mb == 24'd0 ? 8'd255 : dab;
		end else begin
			sx1 <= b_in[31];
			ex1 <= eb;
			mx1 <= mb;
			my1 <= ma;
			d1 <= ma == 24'd0 ? 8'd255 : dab;
		end
	end

	/* Stage 2: align the smaller operand (3 extra bits, the last sticky). */
	reg v2, sp2, sx2, sub2;
	reg [31:0] spv2;
	reg [7:0] ex2;
	reg [26:0] px2, py2;
	reg [26:0] sh;
	reg stk;
	integer k;

	wire [26:0] shi = {my1, 3'b000};
	wire [26:0] shr;	/* (d1 < 27 where it is used) */
	am_shift #(.W(27), .SW(5)) u_shr (.a(shi), .amt(d1[4:0]), .left(1'b0), .arith(1'b0),
		.y(shr));
	always @(*) begin
		stk = 1'b0;
		if (d1 >= 8'd27) begin
			stk = my1 != 24'd0;
			sh = 27'd0;
		end else begin
			for (k = 0; k < 27; k = k + 1)
				if (k < d1)
					stk = stk | shi[k];
			sh = shr;
		end
	end

	always @(posedge clk) begin
		v2 <= rst_n && v1;
		sp2 <= sp1;
		spv2 <= spv1;
		sx2 <= sx1;
		sub2 <= sub1;
		ex2 <= ex1;
		px2 <= {mx1, 3'b000};
		py2 <= {sh[26:1], sh[0] | stk};
	end

	/* Stage 3: add or subtract, count the leading zeros. */
	wire [27:0] sum;
	wire sum_co_unused;
	am_addsub #(.W(28)) u_sum (.a({1'b0, px2}), .b({1'b0, py2}), .sub(sub2), .s(sum), .co(sum_co_unused));
	reg [4:0] lz;

	always @(*) begin
		lz = 5'd27;
		for (k = 0; k < 27; k = k + 1)
			if (sum[k])
				lz = 5'd26 - k[4:0];
	end

	reg v3, sp3, sx3;
	reg [31:0] spv3;
	reg [7:0] ex3;
	reg [27:0] sum3;
	reg [4:0] lz3;

	always @(posedge clk) begin
		v3 <= rst_n && v2;
		sp3 <= sp2;
		spv3 <= spv2;
		sx3 <= sx2;
		ex3 <= ex2;
		sum3 <= sum;
		lz3 <= lz;
	end

	/* Stage 4: normalise, round to nearest even, pack. */
	/* ex + 1 (a carry out) or ex - lz; + 1 more when the rounding carries */
	wire [26:0] nl;
	wire [9:0] e0, e;
	wire [24:0] m0;
	wire e0_co_unused, e_co_unused, m_co_unused;
	am_shift #(.W(27), .SW(5)) u_nl (.a(sum3[26:0]), .amt(lz3), .left(1'b1), .arith(1'b0), .y(nl));
	wire [26:0] n = sum3[27] ? {sum3[27:2], sum3[1] | sum3[0]} : nl;
	am_addsub #(.W(10)) u_e0 (.a({2'b00, ex3}), .b(sum3[27] ? 10'd1 : {5'd0, lz3}), .sub(!sum3[27]),
		.s(e0), .co(e0_co_unused));
	wire inc = n[2] && (n[1] || n[0] || n[3]);
	am_add #(.W(25)) u_m0 (.a({1'b0, n[26:3]}), .b(25'd0), .ci(inc), .s(m0), .co(m_co_unused));
	wire [24:0] m = m0[24] ? {1'b0, m0[24:1]} : m0;
	am_add #(.W(10)) u_e (.a(e0), .b(10'd0), .ci(m0[24]), .s(e), .co(e_co_unused));
	wire unused_m = &{1'b0, m[24:23]};

	always @(posedge clk) begin
		o_valid <= rst_n && v3;
		if (sp3)
			o_r <= spv3;
		else if (sum3 == 28'd0)
			o_r <= 32'd0;
		else if (!e[9] && e >= 10'd255)
			o_r <= {sx3, 8'hFF, 23'd0};
		else if (e[9] || e == 10'd0)
			o_r <= {sx3, 31'd0};
		else
			o_r <= {sx3, e[7:0], m[22:0]};
	end
endmodule

`default_nettype wire
