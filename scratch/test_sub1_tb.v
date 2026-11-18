`timescale 1ns / 1ps
`default_nettype none

module test_sub1_tb;
	reg [31:0] x;
	wire [31:0] r_dut, r_ref;
	wire ref_ov_unused;

	atg_fp_sub1 dut (.x(x), .r(r_dut));

	am_fp_add #(.LAT(0)) ref_add (
		.clk(1'b0), .rst_n(1'b1), .i_valid(1'b1),
		.i_a(32'h3F800000), .i_b(x), .i_sub(1'b1),
		.o_valid(ref_ov_unused), .o_r(r_ref)
	);

	integer i, errors;
	reg [31:0] test_val;

	initial begin
		errors = 0;

		/* Corner cases */
		x = 32'h00000000; #10; check();
		x = 32'h80000000; #10; check();
		x = 32'h3F800000; #10; check(); /* 1.0 */
		x = 32'h3F000000; #10; check(); /* 0.5 */
		x = 32'h3E800000; #10; check(); /* 0.25 */
		x = 32'h3F400000; #10; check(); /* 0.75 */
		x = 32'h3E000000; #10; check(); /* 0.125 */
		x = 32'h3F7FFFFF; #10; check(); /* largest < 1.0 */
		x = 32'h00800000; #10; check(); /* smallest normal */
		x = 32'h7FC00000; #10; check(); /* NaN */
		x = 32'h7F800000; #10; check(); /* +Inf */

		/* 20,000 random values in [0.0, 1.0] */
		for (i = 0; i < 50000; i = i + 1) begin
			/* Exponent in 0..127 */
			test_val[31] = 1'b0;
			test_val[30:23] = $random % 128;
			test_val[22:0] = $random;
			if (test_val > 32'h3F800000)
				test_val = 32'h3F800000;
			x = test_val;
			#10;
			check();
		end

		if (errors == 0)
			$display("PASS: All 50000+ tests matched am_fp_add perfectly!");
		else
			$display("FAIL: %0d mismatches found", errors);
		$finish;
	end

	task check;
		begin
			if (r_dut !== r_ref) begin
				errors = errors + 1;
				if (errors <= 10)
					$display("MISMATCH for x=%h: dut=%h, ref=%h", x, r_dut, r_ref);
			end
		end
	endtask
endmodule
