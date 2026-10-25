/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fadd: r = a + b in fp32 (design §3.1 precision: round to nearest
 * even, denormals flushed on input and output, NaN results 0x7FC00000).
 * The former function atg_su_fadd of include/atg_su_fp.vh.
 * Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_fadd (
	input wire [31:0] a,
	input wire [31:0] b,
	output wire [31:0] r
);
	wire [7:0] ea = a[30:23];
	wire [7:0] eb = b[30:23];
	wire [23:0] ma = ea == 8'd0 ? 24'd0 : {1'b1, a[22:0]};
	wire [23:0] mb = eb == 8'd0 ? 24'd0 : {1'b1, b[22:0]};
	wire nan_a = ea == 8'hFF && a[22:0] != 0;
	wire nan_b = eb == 8'hFF && b[22:0] != 0;
	wire inf_a = ea == 8'hFF && a[22:0] == 0;
	wire inf_b = eb == 8'hFF && b[22:0] == 0;
	wire [5:0] carry_unused;

	/* x is the larger magnitude; y is aligned to it (d = ex - ey) with the
	 * bits shifted out as a sticky bit */
	wire xa = {ea, ma} >= {eb, mb};
	wire sx = xa ? a[31] : b[31];
	wire sy = xa ? b[31] : a[31];
	wire [7:0] ex = xa ? ea : eb;
	wire [23:0] mx = xa ? ma : mb;
	wire [23:0] my = xa ? mb : ma;
	wire [7:0] ey = my == 24'd0 ? ex : xa ? eb : ea;
	wire [7:0] d;
	am_sub #(.W(8)) u_d (.a(ex), .b(ey), .bi(1'b0), .d(d), .bo(carry_unused[0]));
	wire [26:0] sh = {my, 3'b000};
	wire [26:0] shr;
	am_shift #(.W(27), .SW(5)) u_al (.a(sh), .amt(d[4:0]), .left(1'b0), .arith(1'b0), .y(shr));
	reg sst;
	integer i;
	always @(*) begin
		sst = 1'b0;
		for (i = 0; i < 27; i = i + 1)
			if (i < d && sh[i])
				sst = 1'b1;
	end
	/* {carry, 24 bits, guard, round, sticky} */
	wire [27:0] px = {1'b0, mx, 3'b000};
	wire [27:0] py = d >= 8'd27 ? {27'd0, my != 24'd0} : {1'b0, shr[26:1], shr[0] | sst};

	/* the sum or the difference, normalised: right by 1 on a carry, left
	 * by 26 - msb after a cancellation */
	wire same = sx == sy;
	wire [27:0] r0;
	am_addsub #(.W(28)) u_r (.a(px), .b(py), .sub(!same), .s(r0), .co(carry_unused[1]));
	reg [4:0] msb;
	always @(*) begin
		msb = 5'd0;
		for (i = 0; i < 27; i = i + 1)
			if (r0[i])
				msb = i[4:0];
	end
	wire [4:0] nsh;
	wire [27:0] rl;
	am_sub #(.W(5)) u_nsh (.a(5'd26), .b(msb), .bi(1'b0), .d(nsh), .bo(carry_unused[2]));
	am_shift #(.W(28), .SW(5)) u_nrm (.a(r0), .amt(nsh), .left(1'b1), .arith(1'b0), .y(rl));
	wire nz = r0[26:0] != 27'd0;
	wire [27:0] rn = same ? (r0[27] ? {1'b0, r0[27:2], r0[1] | r0[0]} : r0) : nz ? rl : r0;
	/* the exponent: ex + carry or ex - (26 - msb) */
	wire [9:0] er1;
	am_addsub #(.W(10)) u_er1 (.a({2'b00, ex}), .b(same ? {9'd0, r0[27]} : {5'd0, nsh}), .sub(!same), .s(er1),
		.co(carry_unused[3]));

	/* rn[26:3] the mantissa, [2] guard, [1] round, [0] sticky */
	wire up = rn[2] && (rn[1] || rn[0] || rn[3]);
	wire [24:0] mr0;
	wire [9:0] er;
	am_add #(.W(25)) u_mr (.a({1'b0, rn[26:3]}), .b(25'd0), .ci(up), .s(mr0), .co(carry_unused[4]));
	am_add #(.W(10)) u_er (.a(er1), .b(10'd0), .ci(mr0[24]), .s(er), .co(carry_unused[5]));
	wire [22:0] mr = mr0[24] ? mr0[23:1] : mr0[22:0];

	assign r = nan_a || nan_b || (inf_a && inf_b && a[31] != b[31]) ? 32'h7FC00000 :
		inf_a ? {a[31], 8'hFF, 23'd0} :
		inf_b ? {b[31], 8'hFF, 23'd0} :
		ma == 24'd0 && mb == 24'd0 ? {a[31] && b[31], 31'd0} :	/* (-0) + (-0) = -0, else +0 */
		rn[26:0] == 27'd0 ? 32'd0 :
		er[9] || er == 10'd0 ? {sx, 31'd0} :	/* underflow: flushed */
		er >= 10'd255 ? {sx, 8'hFF, 23'd0} : {sx, er[7:0], mr};

	wire unused_ok = &{1'b0, carry_unused, rn[27]};
endmodule

`default_nettype wire
