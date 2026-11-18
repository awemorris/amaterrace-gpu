`timescale 1ns / 1ps
`default_nettype none

module test_fp_add_lat5;
	reg clk = 0;
	always #2.5 clk = !clk;
	reg rst_n = 0;

	reg [31:0] a = 0, b = 0;
	reg sub = 0;
	wire [31:0] r0, r5;
	wire v0, v5;

	am_fp_add #(.LAT(0)) u0 (
		.clk(clk), .rst_n(rst_n), .i_valid(1'b1),
		.i_a(a), .i_b(b), .i_sub(sub),
		.o_valid(v0), .o_r(r0)
	);

	am_fp_add #(.LAT(5)) u5 (
		.clk(clk), .rst_n(rst_n), .i_valid(1'b1),
		.i_a(a), .i_b(b), .i_sub(sub),
		.o_valid(v5), .o_r(r5)
	);

	reg [31:0] pipe [0:4];
	integer i, errors = 0;

	always @(posedge clk) begin
		pipe[0] <= r0;
		pipe[1] <= pipe[0];
		pipe[2] <= pipe[1];
		pipe[3] <= pipe[2];
		pipe[4] <= pipe[3];
	end

	initial begin
		#10 rst_n = 1;
		@(posedge clk);
		for (i = 0; i < 50000; i = i + 1) begin
			@(negedge clk);
			a = $random;
			b = $random;
			sub = $random;
			@(posedge clk);
			#1;
			if (i >= 10) begin
				if (r5 !== pipe[4]) begin
					$display("MISMATCH at %0d: r5=%h expected=%h (a=%h b=%h sub=%b)", i, r5, pipe[4], a, b, sub);
					errors = errors + 1;
					if (errors > 10) $finish;
				end
			end
		end
		if (errors == 0)
			$display("PASS: All 50000 tests matched LAT=0 and LAT=5 perfectly!");
		$finish;
	end
endmodule
