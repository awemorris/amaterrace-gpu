`timescale 1ns / 1ps
`default_nettype none

module tb_sub1;
	reg [31:0] i_x;
	wire [31:0] r_sub1, r_fadd;
	wire fadd_ov;

	atg_rop_sub1 u_sub1 (.i_x(i_x), .o_r(r_sub1));

	atg_rop_fadd #(.LAT(0)) u_fadd (
		.clk(1'b0), .rst_n(1'b1), .i_valid(1'b1),
		.i_a(32'h3F800000), .i_b(i_x), .i_sub(1'b1),
		.o_valid(fadd_ov), .o_r(r_fadd)
	);

	integer i, errors;
	reg [31:0] test_vals [0:23];

	initial begin
		errors = 0;
		test_vals[0]  = 32'h00000000;
		test_vals[1]  = 32'h80000000;
		test_vals[2]  = 32'h3F800000;
		test_vals[3]  = 32'hBF800000;
		test_vals[4]  = 32'h3F800001;
		test_vals[5]  = 32'h3F7FFFFF;
		test_vals[6]  = 32'h3F7FFFFE;
		test_vals[7]  = 32'h7F800000;
		test_vals[8]  = 32'hFF800000;
		test_vals[9]  = 32'h7FC00000;
		test_vals[10] = 32'h7FA00000;
		test_vals[11] = 32'h00000001;
		test_vals[12] = 32'h007FFFFF;
		test_vals[13] = 32'h40000000;
		test_vals[14] = 32'hC0000000;
		test_vals[15] = 32'h41000000;
		test_vals[16] = 32'h7F7FFFFF;
		test_vals[17] = 32'hFF7FFFFF;
		test_vals[18] = 32'h3E800000;
		test_vals[19] = 32'h3F000000;
		test_vals[20] = 32'h3F400000;
		test_vals[21] = 32'h3FC00000;
		test_vals[22] = 32'hBFC00000;
		test_vals[23] = 32'hC1200000;

		for (i = 0; i < 24; i = i + 1) begin
			i_x = test_vals[i];
			#1;
			if (r_sub1 !== r_fadd) begin
				$display("MISMATCH on 0x%08x: sub1=0x%08x, fadd=0x%08x", i_x, r_sub1, r_fadd);
				errors = errors + 1;
			end
		end

		for (i = 0; i < 50000; i = i + 1) begin
			i_x = $random;
			#1;
			if (r_sub1 !== r_fadd) begin
				if (errors < 10)
					$display("MISMATCH on 0x%08x: sub1=0x%08x, fadd=0x%08x", i_x, r_sub1, r_fadd);
				errors = errors + 1;
			end
		end

		if (errors == 0)
			$display("ALL 50024 TESTS PASSED! sub1 is bit-exact with fadd!");
		else
			$display("FAILED with %0d errors", errors);
		$finish;
	end
endmodule

`default_nettype wire
