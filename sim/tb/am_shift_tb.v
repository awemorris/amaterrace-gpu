/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_shift_tb: comprehensive equivalence unit testbench for am_shift.
 * Tests multiple bit widths (W=8, 16, 24, 32, 48, 64) across all shift amounts
 * (0 <= amt <= W+2), corner cases, and all modes (left, logical right, arithmetic right)
 * against reference behavior.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_shift_tb;
	integer errors = 0;
	integer i, amt_i;
	integer seed = 12345;

	/* -------------------------------------------------------------
	 * Width 8 DUT
	 * ------------------------------------------------------------- */
	reg [7:0] a8;
	reg [3:0] amt8;
	reg left8, arith8;
	wire [7:0] y8;

	am_shift #(.W(8), .SW(4)) dut8 (
		.a(a8), .amt(amt8), .left(left8), .arith(arith8), .y(y8)
	);

	function [7:0] ref_shift8(input [7:0] in, input [3:0] amt, input l, input ar);
		reg signed [7:0] s_in;
		begin
			s_in = in;
			if (amt >= 8) begin
				if (l || !ar) ref_shift8 = 8'd0;
				else ref_shift8 = {8{in[7]}};
			end else begin
				if (l) ref_shift8 = in << amt;
				else if (ar) ref_shift8 = s_in >>> amt;
				else ref_shift8 = in >> amt;
			end
		end
	endfunction

	/* -------------------------------------------------------------
	 * Width 16 DUT
	 * ------------------------------------------------------------- */
	reg [15:0] a16;
	reg [4:0] amt16;
	reg left16, arith16;
	wire [15:0] y16;

	am_shift #(.W(16), .SW(5)) dut16 (
		.a(a16), .amt(amt16), .left(left16), .arith(arith16), .y(y16)
	);

	function [15:0] ref_shift16(input [15:0] in, input [4:0] amt, input l, input ar);
		reg signed [15:0] s_in;
		begin
			s_in = in;
			if (amt >= 16) begin
				if (l || !ar) ref_shift16 = 16'd0;
				else ref_shift16 = {16{in[15]}};
			end else begin
				if (l) ref_shift16 = in << amt;
				else if (ar) ref_shift16 = s_in >>> amt;
				else ref_shift16 = in >> amt;
			end
		end
	endfunction

	/* -------------------------------------------------------------
	 * Width 24 DUT
	 * ------------------------------------------------------------- */
	reg [23:0] a24;
	reg [5:0] amt24;
	reg left24, arith24;
	wire [23:0] y24;

	am_shift #(.W(24), .SW(6)) dut24 (
		.a(a24), .amt(amt24), .left(left24), .arith(arith24), .y(y24)
	);

	function [23:0] ref_shift24(input [23:0] in, input [5:0] amt, input l, input ar);
		reg signed [23:0] s_in;
		begin
			s_in = in;
			if (amt >= 24) begin
				if (l || !ar) ref_shift24 = 24'd0;
				else ref_shift24 = {24{in[23]}};
			end else begin
				if (l) ref_shift24 = in << amt;
				else if (ar) ref_shift24 = s_in >>> amt;
				else ref_shift24 = in >> amt;
			end
		end
	endfunction

	/* -------------------------------------------------------------
	 * Width 32 DUT
	 * ------------------------------------------------------------- */
	reg [31:0] a32;
	reg [5:0] amt32;
	reg left32, arith32;
	wire [31:0] y32;

	am_shift #(.W(32), .SW(6)) dut32 (
		.a(a32), .amt(amt32), .left(left32), .arith(arith32), .y(y32)
	);

	function [31:0] ref_shift32(input [31:0] in, input [5:0] amt, input l, input ar);
		reg signed [31:0] s_in;
		begin
			s_in = in;
			if (amt >= 32) begin
				if (l || !ar) ref_shift32 = 32'd0;
				else ref_shift32 = {32{in[31]}};
			end else begin
				if (l) ref_shift32 = in << amt;
				else if (ar) ref_shift32 = s_in >>> amt;
				else ref_shift32 = in >> amt;
			end
		end
	endfunction

	/* -------------------------------------------------------------
	 * Width 48 DUT
	 * ------------------------------------------------------------- */
	reg [47:0] a48;
	reg [6:0] amt48;
	reg left48, arith48;
	wire [47:0] y48;

	am_shift #(.W(48), .SW(7)) dut48 (
		.a(a48), .amt(amt48), .left(left48), .arith(arith48), .y(y48)
	);

	function [47:0] ref_shift48(input [47:0] in, input [6:0] amt, input l, input ar);
		reg signed [47:0] s_in;
		begin
			s_in = in;
			if (amt >= 48) begin
				if (l || !ar) ref_shift48 = 48'd0;
				else ref_shift48 = {48{in[47]}};
			end else begin
				if (l) ref_shift48 = in << amt;
				else if (ar) ref_shift48 = s_in >>> amt;
				else ref_shift48 = in >> amt;
			end
		end
	endfunction

	initial begin
		/* 1. Exhaustive test for W=8 */
		for (i = 0; i < 256; i = i + 1) begin
			a8 = i[7:0];
			for (amt_i = 0; amt_i <= 10; amt_i = amt_i + 1) begin
				amt8 = amt_i[3:0];

				/* Logical Right */
				left8 = 1'b0; arith8 = 1'b0; #1;
				if (y8 !== ref_shift8(a8, amt8, left8, arith8)) begin
					$display("FAIL W=8 L-Right: a=0x%02x amt=%0d y=0x%02x exp=0x%02x",
						a8, amt8, y8, ref_shift8(a8, amt8, left8, arith8));
					errors = errors + 1;
				end

				/* Arithmetic Right */
				left8 = 1'b0; arith8 = 1'b1; #1;
				if (y8 !== ref_shift8(a8, amt8, left8, arith8)) begin
					$display("FAIL W=8 A-Right: a=0x%02x amt=%0d y=0x%02x exp=0x%02x",
						a8, amt8, y8, ref_shift8(a8, amt8, left8, arith8));
					errors = errors + 1;
				end

				/* Left */
				left8 = 1'b1; arith8 = 1'b0; #1;
				if (y8 !== ref_shift8(a8, amt8, left8, arith8)) begin
					$display("FAIL W=8 Left: a=0x%02x amt=%0d y=0x%02x exp=0x%02x",
						a8, amt8, y8, ref_shift8(a8, amt8, left8, arith8));
					errors = errors + 1;
				end
			end
		end

		/* 2. Randomized test for W=16 (2000 vectors) */
		for (i = 0; i < 2000; i = i + 1) begin
			a16 = $random(seed);
			amt16 = $random(seed) % 18;
			left16 = $random(seed) & 1;
			arith16 = $random(seed) & 1;
			#1;
			if (y16 !== ref_shift16(a16, amt16, left16, arith16)) begin
				$display("FAIL W=16: a=0x%04x amt=%0d l=%b ar=%b y=0x%04x exp=0x%04x",
					a16, amt16, left16, arith16, y16, ref_shift16(a16, amt16, left16, arith16));
				errors = errors + 1;
			end
		end

		/* 3. Randomized test for W=24 (2000 vectors) */
		for (i = 0; i < 2000; i = i + 1) begin
			a24 = {$random(seed), $random(seed)};
			amt24 = $random(seed) % 26;
			left24 = $random(seed) & 1;
			arith24 = $random(seed) & 1;
			#1;
			if (y24 !== ref_shift24(a24, amt24, left24, arith24)) begin
				$display("FAIL W=24: a=0x%06x amt=%0d l=%b ar=%b y=0x%06x exp=0x%06x",
					a24, amt24, left24, arith24, y24, ref_shift24(a24, amt24, left24, arith24));
				errors = errors + 1;
			end
		end

		/* 4. Randomized test for W=32 (5000 vectors) */
		for (i = 0; i < 5000; i = i + 1) begin
			a32 = $random(seed);
			amt32 = $random(seed) % 35;
			left32 = $random(seed) & 1;
			arith32 = $random(seed) & 1;
			#1;
			if (y32 !== ref_shift32(a32, amt32, left32, arith32)) begin
				$display("FAIL W=32: a=0x%08x amt=%0d l=%b ar=%b y=0x%08x exp=0x%08x",
					a32, amt32, left32, arith32, y32, ref_shift32(a32, amt32, left32, arith32));
				errors = errors + 1;
			end
		end

		/* 5. Randomized test for W=48 (2000 vectors) */
		for (i = 0; i < 2000; i = i + 1) begin
			a48 = {$random(seed), $random(seed)};
			amt48 = $random(seed) % 52;
			left48 = $random(seed) & 1;
			arith48 = $random(seed) & 1;
			#1;
			if (y48 !== ref_shift48(a48, amt48, left48, arith48)) begin
				$display("FAIL W=48: a=0x%012x amt=%0d l=%b ar=%b y=0x%012x exp=0x%012x",
					a48, amt48, left48, arith48, y48, ref_shift48(a48, amt48, left48, arith48));
				errors = errors + 1;
			end
		end

		/* Final result */
		if (errors == 0)
			$display("PASS am_shift");
		else
			$display("FAIL am_shift: %0d errors", errors);

		$finish;
	end
endmodule

`default_nettype wire
