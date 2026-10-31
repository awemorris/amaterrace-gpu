`timescale 1ns / 1ps
`default_nettype none

module tb_srgb_enc;
	`include "atg_srgb.vh"

	reg [31:0] b;
	wire [7:0] srgb;

	atg_srgb_enc dut (.b(b), .srgb(srgb));

	function [7:0] ref_enc;
		input [31:0] val;
		integer k;
		reg [7:0] cnt;
		begin
			if ((val[30:23] == 8'hFF && val[22:0] != 23'd0) || val[31])
				ref_enc = 8'd0;
			else if (val >= 32'h3F7EDC0E)
				ref_enc = 8'd255;
			else begin
				cnt = 8'd0;
				for (k = 0; k < 255; k = k + 1)
					if (val >= atg_srgb_thr(k[7:0]))
						cnt = cnt + 8'd1;
				ref_enc = cnt;
			end
		end
	endfunction

	integer i, delta, err;
	reg [31:0] test_val;

	initial begin
		err = 0;
		/* Test around all 255 thresholds */
		for (i = 0; i < 255; i = i + 1) begin
			for (delta = -4; delta <= 4; delta = delta + 1) begin
				test_val = atg_srgb_thr(i[7:0]) + delta;
				b = test_val;
				#1;
				if (srgb !== ref_enc(test_val)) begin
					$display("FAIL at threshold %0d + %0d: b=%h, got %d, want %d",
						i, delta, test_val, srgb, ref_enc(test_val));
					err = err + 1;
				end
			end
		end

		/* Test zero, negative, NaNs, inf */
		b = 32'h00000000; #1; if (srgb !== 0) err = err + 1;
		b = 32'h80000000; #1; if (srgb !== 0) err = err + 1;
		b = 32'hBF800000; #1; if (srgb !== 0) err = err + 1;
		b = 32'h7FC00000; #1; if (srgb !== 0) err = err + 1;
		b = 32'h7F800000; #1; if (srgb !== 255) err = err + 1;
		b = 32'h3F800000; #1; if (srgb !== 255) err = err + 1;

		if (err == 0)
			$display("ALL TESTS PASSED! Bit-exact with atg_srgb.vh!");
		else
			$display("FAILED with %0d errors", err);
		$finish;
	end
endmodule
