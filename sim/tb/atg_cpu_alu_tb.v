/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_alu_tb: every ALU op on corner and random operands against a
 * behavioural reference, then eq/lt/ltu on signed/unsigned corners.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_alu_tb;
	reg [3:0] op;
	reg [31:0] a, b;
	wire [31:0] y;
	wire eq, lt, ltu;
	integer seed = 1;
	integer errors = 0;
	integer i, k, j;
	reg [31:0] corner [0:7];

	atg_cpu_alu dut (.op(op), .a(a), .b(b), .y(y), .eq(eq), .lt(lt), .ltu(ltu));

	function [31:0] ref_y;
		input [3:0] o;
		input [31:0] x, z;
		begin
			case (o)
			4'd0: ref_y = x + z;
			4'd1: ref_y = x - z;
			4'd2: ref_y = x << z[4:0];
			4'd3: ref_y = ($signed(x) < $signed(z)) ? 32'd1 : 32'd0;
			4'd4: ref_y = (x < z) ? 32'd1 : 32'd0;
			4'd5: ref_y = x ^ z;
			4'd6: ref_y = x >> z[4:0];
			4'd7: ref_y = $signed(x) >>> z[4:0];
			4'd8: ref_y = x | z;
			4'd9: ref_y = x & z;
			4'd10: ref_y = z;
			default: ref_y = 32'd0;
			endcase
		end
	endfunction

	task check_ops;
		begin
			for (k = 0; k < 16; k = k + 1) begin
				op = k;
				#1;
				if (y !== ref_y(op, a, b)) begin
					$display("FAIL ops op=%0d a=%h b=%h y=%h want %h", op, a, b, y,
						ref_y(op, a, b));
					errors = errors + 1;
				end
			end
		end
	endtask

	task check_cmp;
		begin
			#1;
			if (eq !== (a == b) || lt !== ($signed(a) < $signed(b)) || ltu !== (a < b)) begin
				$display("FAIL cmp a=%h b=%h eq=%b lt=%b ltu=%b", a, b, eq, lt, ltu);
				errors = errors + 1;
			end
		end
	endtask

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;
		corner[0] = 32'h0000_0000;
		corner[1] = 32'h0000_0001;
		corner[2] = 32'hFFFF_FFFF;
		corner[3] = 32'h8000_0000;
		corner[4] = 32'h7FFF_FFFF;
		corner[5] = 32'h0000_001F;
		corner[6] = 32'h0000_0020;
		corner[7] = 32'h8000_0001;
		for (i = 0; i < 8; i = i + 1)
			for (j = 0; j < 8; j = j + 1) begin
				a = corner[i];
				b = corner[j];
				check_ops;
			end
		for (i = 0; i < 2000; i = i + 1) begin
			a = $random(seed);
			b = $random(seed);
			check_ops;
		end
		if (errors == 0)
			$display("PASS atg_cpu_alu.ops");
		k = errors;
		for (i = 0; i < 8; i = i + 1)
			for (j = 0; j < 8; j = j + 1) begin
				a = corner[i];
				b = corner[j];
				check_cmp;
			end
		for (i = 0; i < 2000; i = i + 1) begin
			a = $random(seed);
			b = (i % 3 == 0) ? a : $random(seed);
			check_cmp;
		end
		if (errors == k)
			$display("PASS atg_cpu_alu.cmp");
		if (errors == 0)
			$display("PASS atg_cpu_alu");
		$finish;
	end
endmodule

`default_nettype wire
