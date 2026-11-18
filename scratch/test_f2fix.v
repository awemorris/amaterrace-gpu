`timescale 1ns / 1ps
`default_nettype none

module test_f2fix;
	reg [31:0] f;
	wire [23:0] q_gold;

	am_fp_f2fix #(.W(24), .F(8), .SIGNED(1), .ROUND(1), .SATURATE(1), .SAT_BITS(22)) u_gold (
		.f(f), .q(q_gold)
	);

	localparam [7:0] E_BASE = 8'd142;
	localparam [7:0] E_MIN  = 8'd118;

	wire sign = f[31];
	wire [7:0] exp = f[30:23];
	wire [22:0] mant = f[22:0];

	wire is_nan = (exp == 8'hFF) && (mant != 23'd0);
	wire is_zero = (exp == 8'd0);

	wire [7:0] sh_w;
	wire bo_s_unused, bo_udf_w, bo_lt_ebase_w;
	am_sub #(.W(8)) u_s  (.a(E_BASE), .b(exp), .bi(1'b0), .d(sh_w), .bo(bo_s_unused));
	am_sub #(.W(8)) u_uf (.a(exp), .b(E_MIN), .bi(1'b0), .d(), .bo(bo_udf_w));
	am_sub #(.W(8)) u_ov (.a(exp), .b(E_BASE), .bi(1'b0), .d(), .bo(bo_lt_ebase_w));

	wire [4:0] sh_b0 = sh_w[4:0];
	wire [4:0] sh_b1 = sh_w[4:0];
	wire [4:0] sh_b2 = sh_w[4:0];

	wire [47:0] in_data = {1'b1, mant, 24'd0};

	wire [47:0] s_coarse;
	assign s_coarse[15:0]  = (sh_w[7:5] != 3'd0) ? 16'd0 :
	                         (sh_b0[4:3] == 2'd0) ? in_data[15:0] :
	                         (sh_b0[4:3] == 2'd1) ? in_data[23:8] :
	                         (sh_b0[4:3] == 2'd2) ? in_data[31:16] : in_data[39:24];

	assign s_coarse[31:16] = (sh_w[7:5] != 3'd0) ? 16'd0 :
	                         (sh_b1[4:3] == 2'd0) ? in_data[31:16] :
	                         (sh_b1[4:3] == 2'd1) ? in_data[39:24] :
	                         (sh_b1[4:3] == 2'd2) ? in_data[47:32] : {8'd0, in_data[47:40]};

	assign s_coarse[47:32] = (sh_w[7:5] != 3'd0) ? 16'd0 :
	                         (sh_b2[4:3] == 2'd0) ? in_data[47:32] :
	                         (sh_b2[4:3] == 2'd1) ? {8'd0, in_data[47:40]} : 16'd0;

	wire [54:0] c_pad = {7'd0, s_coarse};
	wire [47:0] shifted;

	wire [15:0] f0_lo = sh_b0[1] ?
		(sh_b0[0] ? c_pad[3 +: 16] : c_pad[2 +: 16]) :
		(sh_b0[0] ? c_pad[1 +: 16] : c_pad[0 +: 16]);
	wire [15:0] f0_hi = sh_b0[1] ?
		(sh_b0[0] ? c_pad[7 +: 16] : c_pad[6 +: 16]) :
		(sh_b0[0] ? c_pad[5 +: 16] : c_pad[4 +: 16]);
	assign shifted[15:0] = sh_b0[2] ? f0_hi : f0_lo;

	wire [15:0] f1_lo = sh_b1[1] ?
		(sh_b1[0] ? c_pad[16 + 3 +: 16] : c_pad[16 + 2 +: 16]) :
		(sh_b1[0] ? c_pad[16 + 1 +: 16] : c_pad[16 + 0 +: 16]);
	wire [15:0] f1_hi = sh_b1[1] ?
		(sh_b1[0] ? c_pad[16 + 7 +: 16] : c_pad[16 + 6 +: 16]) :
		(sh_b1[0] ? c_pad[16 + 5 +: 16] : c_pad[16 + 4 +: 16]);
	assign shifted[31:16] = sh_b1[2] ? f1_hi : f1_lo;

	wire [15:0] f2_lo = sh_b2[1] ?
		(sh_b2[0] ? c_pad[32 + 3 +: 16] : c_pad[32 + 2 +: 16]) :
		(sh_b2[0] ? c_pad[32 + 1 +: 16] : c_pad[32 + 0 +: 16]);
	wire [15:0] f2_hi = sh_b2[1] ?
		(sh_b2[0] ? c_pad[32 + 7 +: 16] : c_pad[32 + 6 +: 16]) :
		(sh_b2[0] ? c_pad[32 + 5 +: 16] : c_pad[32 + 4 +: 16]);
	assign shifted[47:32] = sh_b2[2] ? f2_hi : f2_lo;

	wire [23:0] unrounded = shifted[47:24];
	wire guard = shifted[23];
	wire sticky = |shifted[22:0];
	wire round_up = guard && (sticky || unrounded[0]);

	wire [23:0] rounded_mag;
	wire rnd_carry;
	am_add #(.W(24)) u_rnd (.a(unrounded), .b(24'd0), .ci(round_up), .s(rounded_mag), .co(rnd_carry));

	wire underflow = bo_udf_w || is_zero;
	wire overflow  = is_nan || (!bo_lt_ebase_w) || rnd_carry || (rounded_mag[23:22] != 2'd0);

	wire [23:0] pos_val = overflow ? 24'h3FFFFF : (underflow ? 24'd0 : rounded_mag);
	wire [23:0] neg_val;
	am_sub #(.W(24)) u_neg (.a(24'd0), .b(pos_val), .bi(1'b0), .d(neg_val), .bo());

	wire [23:0] q_test = is_nan ? 24'd0 : (sign ? neg_val : pos_val);

	integer i;
	initial begin
		for (i = 0; i < 100000; i = i + 1) begin
			f = {$random, $random};
			#1;
			if (q_test !== q_gold) begin
				$display("MISMATCH at i=%0d: f=%h, q_test=%h, q_gold=%h", i, f, q_test, q_gold);
				$finish;
			end
		end
		$display("EXPLICIT MUX SHIFT MATCHED ALL 100,000 VECTORS!");
		$finish;
	end
endmodule
