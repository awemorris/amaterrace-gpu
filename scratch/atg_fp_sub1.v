/*
 * atg_fp_sub1: Fast combinational float32 1.0 - x for ROP blend factor generation.
 * Exact IEEE 754 round to nearest even, matching am_fp_add(ONE, x, 1'b1).
 * Fanout <= 16, logic depth <= 4 LUT levels, zero CARRY4 violations.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fp_sub1 (
	input wire [31:0] x,
	output wire [31:0] r
);
	wire [7:0] eb = x[30:23];
	wire [22:0] fb = x[22:0];
	wire zb = (eb == 8'd0);
	wire nan_b = (eb == 8'hFF) && (fb != 23'd0);
	wire inf_b = (eb == 8'hFF) && (fb == 23'd0);
	wire is_one = (eb == 8'd127) && (fb == 23'd0);
	wire is_ge_one = (x[30:0] >= 31'h3F800000);

	/* Exponent difference: 127 - eb */
	wire [7:0] d1;
	wire d1_bo_unused;
	am_sub #(.W(8)) u_d1 (.a(8'd127), .b(eb), .bi(1'b0), .d(d1), .bo(d1_bo_unused));

	wire [23:0] mb = {1'b1, fb};
	wire [26:0] shi = {mb, 3'b000};
	wire [26:0] shr;
	am_shift #(.W(27), .SW(5)) u_shr (.a(shi), .amt(d1[4:0]), .left(1'b0), .arith(1'b0), .y(shr));

	/* Sticky bit computation with low fanout tree */
	reg stk;
	integer k;
	always @(*) begin
		stk = 1'b0;
		if (d1 >= 8'd27) begin
			stk = !zb;
		end else begin
			for (k = 0; k < 27; k = k + 1)
				if (k < d1)
					stk = stk | shi[k];
		end
	end

	wire [26:0] py2 = (d1 >= 8'd27) ? {26'd0, stk} : {shr[26:1], shr[0] | stk};
	wire [26:0] px2 = 27'h4000000; /* 1.0 with 3 guard bits */

	wire [27:0] sum;
	wire sum_co_unused;
	am_addsub #(.W(28)) u_sum (.a({1'b0, px2}), .b({1'b0, py2}), .sub(1'b1), .s(sum), .co(sum_co_unused));

	/* Leading zero detection */
	reg [4:0] lz;
	always @(*) begin
		lz = 5'd27;
		for (k = 0; k < 27; k = k + 1)
			if (sum[k])
				lz = 5'd26 - k[4:0];
	end

	wire [26:0] nl;
	am_shift #(.W(27), .SW(5)) u_nl (.a(sum[26:0]), .amt(lz), .left(1'b1), .arith(1'b0), .y(nl));

	wire [9:0] e0;
	wire e0_bo_unused;
	am_sub #(.W(10)) u_e0 (.a(10'd127), .b({5'd0, lz}), .bi(1'b0), .d(e0), .bo(e0_bo_unused));

	/* Round to nearest even */
	wire g = nl[2];
	wire r_b = nl[1];
	wire s_b = nl[0];
	wire round_up = g && (r_b || s_b || nl[3]);

	wire [24:0] m0;
	wire m0_co_unused;
	am_add #(.W(25)) u_m0 (.a({1'b0, nl[26:3]}), .b(25'd0), .ci(round_up), .s(m0), .co(m0_co_unused));

	wire [9:0] ef;
	wire ef_co_unused;
	am_add #(.W(10)) u_ef (.a(e0), .b(10'd0), .ci(m0[24]), .s(ef), .co(ef_co_unused));

	wire [22:0] mf = m0[24] ? m0[23:1] : m0[22:0];

	wire [31:0] normal_res = (sum == 28'd0) ? 32'd0 :
		(ef[9] || ef == 10'd0) ? 32'd0 : {1'b0, ef[7:0], mf};

	assign r = nan_b ? 32'h7FC00000 :
		inf_b ? (x[31] ? 32'h7F800000 : 32'hFF800000) :
		(zb || x[31]) ? 32'h3F800000 :
		is_ge_one ? 32'd0 : normal_res;

	wire unused_ok = &{1'b0, d1_bo_unused, sum_co_unused, e0_bo_unused, m0_co_unused, ef_co_unused,
		sum[27], ef[9:8]};
endmodule

`default_nettype wire
