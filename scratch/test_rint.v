`timescale 1ns / 1ps
`default_nettype none

module am_fp_rint_orig (
	input wire [31:0] x,
	input wire [2:0] rm,
	output wire [24:0] n
);
	wire [23:0] m = {x[30:23] != 8'd0, x[22:0]};
	wire [7:0] f;
	wire [4:0] fm1;
	wire [23:0] q0;
	wire [2:0] carry_unused;
	am_sub #(.W(8)) u_f (.a(8'd150), .b(x[30:23]), .bi(1'b0), .d(f), .bo(carry_unused[0]));
	am_sub #(.W(5)) u_fm1 (.a(f[4:0]), .b(5'd1), .bi(1'b0), .d(fm1), .bo(carry_unused[1]));
	am_shift #(.W(24), .SW(5)) u_q (.a(m), .amt(f[4:0]), .left(1'b0), .arith(1'b0), .y(q0));
	wire [23:0] q = f >= 8'd24 ? 24'd0 : q0;
	wire g = f > 8'd24 ? 1'b0 : m[fm1];
	wire [23:0] smk;
	am_shift #(.W(24), .SW(5)) u_smk (.a(24'hFFFFFF), .amt(fm1), .left(1'b1), .arith(1'b0), .y(smk));
	wire st = f > 8'd24 ? |m : f != 8'd0 && |(m & ~smk);
	reg up;
	always @(*)
		case (rm)
		3'd1: up = 1'b0;
		3'd2: up = x[31] && (g || st);
		3'd3: up = !x[31] && (g || st);
		3'd4: up = g;
		default: up = g && (st || q[0]);
		endcase
	am_add #(.W(25)) u_n (.a({1'b0, q}), .b(25'd0), .ci(up), .s(n), .co(carry_unused[2]));
	wire unused_ok = &{1'b0, carry_unused};
endmodule

module am_fp_rint_fast (
	input wire [31:0] x,
	input wire [2:0] rm,
	output wire [24:0] n
);
	wire [23:0] m = {x[30:23] != 8'd0, x[22:0]};
	wire [7:0] f;
	wire [7:0] fm1_w;
	wire [23:0] q0;
	wire [2:0] carry_unused;
	am_sub #(.W(8)) u_f (.a(8'd150), .b(x[30:23]), .bi(1'b0), .d(f), .bo(carry_unused[0]));
	am_sub #(.W(8)) u_fm1 (.a(8'd149), .b(x[30:23]), .bi(1'b0), .d(fm1_w), .bo(carry_unused[1]));
	wire [4:0] fm1 = fm1_w[4:0];
	am_shift #(.W(24), .SW(5)) u_q (.a(m), .amt(f[4:0]), .left(1'b0), .arith(1'b0), .y(q0));
	wire [23:0] q = f >= 8'd24 ? 24'd0 : q0;
	wire g = f > 8'd24 ? 1'b0 : m[fm1];

	wire [23:0] m_or;
	assign m_or[0] = m[0];
	genvar gi;
	generate
		for (gi = 1; gi < 24; gi = gi + 1) begin : g_or
			assign m_or[gi] = m_or[gi-1] | m[gi];
		end
	endgenerate

	wire st = f > 8'd24 ? m_or[23] : (fm1 == 5'd0 || f == 8'd0) ? 1'b0 : m_or[fm1 - 1];

	reg up;
	always @(*)
		case (rm)
		3'd1: up = 1'b0;
		3'd2: up = x[31] && (g || st);
		3'd3: up = !x[31] && (g || st);
		3'd4: up = g;
		default: up = g && (st || q[0]);
		endcase
	am_add #(.W(25)) u_n (.a({1'b0, q}), .b(25'd0), .ci(up), .s(n), .co(carry_unused[2]));
	wire unused_ok = &{1'b0, carry_unused, fm1_w[7:5]};
endmodule

module test_rint;
	reg [31:0] x;
	reg [2:0] rm;
	wire [24:0] n_orig, n_fast;
	am_fp_rint_orig u_orig (.x(x), .rm(rm), .n(n_orig));
	am_fp_rint_fast u_fast (.x(x), .rm(rm), .n(n_fast));

	integer i, errors = 0;
	initial begin
		for (i = 0; i < 500000; i = i + 1) begin
			x = $random;
			rm = $random;
			#1;
			if (n_orig !== n_fast) begin
				$display("MISMATCH at %0d: x=%h rm=%0d orig=%h fast=%h", i, x, rm, n_orig, n_fast);
				errors = errors + 1;
				if (errors > 10) $finish;
			end
		end
		if (errors == 0)
			$display("PASS: 500,000 vectors matched perfectly!");
		$finish;
	end
endmodule
