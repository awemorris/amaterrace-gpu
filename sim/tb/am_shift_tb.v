/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_shift_tb: comprehensive equivalence unit testbench for am_shift.
 * Tests multiple bit widths (W=1, 2, 3, 4, 5, 8, 12, 16, 20, 24, 32, 48, 64) across all shift amounts
 * (0 <= amt < 2^SW), DIR configurations (DIR=0: dynamic, 1: right-only, 2: left-only),
 * and all shift modes (left, logical right, arithmetic right) against reference behavior.
 * Validates equivalence for both Generic behavioral simulation and SYNTH_ASIC (2-level tree buffers).
 */

`timescale 1ns / 1ps
`default_nettype none

module am_shift_tb;
	integer errors = 0;
	integer total_vectors = 0;
	integer i, j, k, amt_i;
	integer seed = 12345;
	reg [63:0] exp64;

	/* -------------------------------------------------------------
	 * Golden Reference Shift Function (supports W <= 64, DIR 0/1/2)
	 * ------------------------------------------------------------- */
	function [63:0] ref_shift;
		input [6:0] w;
		input [63:0] in;
		input [6:0] amt;
		input l;
		input ar;
		input [1:0] dir;
		reg eff_left;
		reg eff_arith;
		reg [63:0] mask;
		reg [63:0] sign_mask;
		reg msb;
		begin
			if (dir == 2'd1) begin
				eff_left = 1'b0;
				eff_arith = ar;
			end else if (dir == 2'd2) begin
				eff_left = 1'b1;
				eff_arith = 1'b0;
			end else begin
				eff_left = l;
				eff_arith = ar;
			end

			msb = in[w - 1];
			mask = (w == 64) ? ~64'd0 : ((64'd1 << w) - 64'd1);

			if (eff_left) begin
				if (amt >= w)
					ref_shift = 64'd0;
				else
					ref_shift = (in << amt) & mask;
			end else begin
				if (amt >= w) begin
					if (eff_arith && msb)
						ref_shift = mask;
					else
						ref_shift = 64'd0;
				end else begin
					if (eff_arith && msb) begin
						sign_mask = (w == 64) ? ~64'd0 : ((64'd1 << w) - 64'd1);
						ref_shift = ((in >> amt) | ~(sign_mask >> amt)) & mask;
					end else begin
						ref_shift = (in >> amt) & mask;
					end
				end
			end
		end
	endfunction

	/* -------------------------------------------------------------
	 * DUT Instances
	 * ------------------------------------------------------------- */
	/* W=1, SW=1, DIR=0 */
	reg a1; reg amt1; reg left1, arith1; wire y1;
	am_shift #(.W(1), .SW(1), .DIR(0)) dut1 (.a(a1), .amt(amt1), .left(left1), .arith(arith1), .y(y1));

	/* W=2, SW=2, DIR=0 */
	reg [1:0] a2; reg [1:0] amt2; reg left2, arith2; wire [1:0] y2;
	am_shift #(.W(2), .SW(2), .DIR(0)) dut2 (.a(a2), .amt(amt2), .left(left2), .arith(arith2), .y(y2));

	/* W=3, SW=2, DIR=0 */
	reg [2:0] a3; reg [1:0] amt3; reg left3, arith3; wire [2:0] y3;
	am_shift #(.W(3), .SW(2), .DIR(0)) dut3 (.a(a3), .amt(amt3), .left(left3), .arith(arith3), .y(y3));

	/* W=4, SW=3, DIR=0, 1, 2 */
	reg [3:0] a4; reg [2:0] amt4; reg left4, arith4;
	wire [3:0] y4_d0, y4_d1, y4_d2;
	am_shift #(.W(4), .SW(3), .DIR(0)) dut4_d0 (.a(a4), .amt(amt4), .left(left4), .arith(arith4), .y(y4_d0));
	am_shift #(.W(4), .SW(3), .DIR(1)) dut4_d1 (.a(a4), .amt(amt4), .left(left4), .arith(arith4), .y(y4_d1));
	am_shift #(.W(4), .SW(3), .DIR(2)) dut4_d2 (.a(a4), .amt(amt4), .left(left4), .arith(arith4), .y(y4_d2));

	/* W=5, SW=3, DIR=0 */
	reg [4:0] a5; reg [2:0] amt5; reg left5, arith5; wire [4:0] y5;
	am_shift #(.W(5), .SW(3), .DIR(0)) dut5 (.a(a5), .amt(amt5), .left(left5), .arith(arith5), .y(y5));

	/* W=8, SW=4, DIR=0, 1, 2 */
	reg [7:0] a8; reg [3:0] amt8; reg left8, arith8;
	wire [7:0] y8_d0, y8_d1, y8_d2;
	am_shift #(.W(8), .SW(4), .DIR(0)) dut8_d0 (.a(a8), .amt(amt8), .left(left8), .arith(arith8), .y(y8_d0));
	am_shift #(.W(8), .SW(4), .DIR(1)) dut8_d1 (.a(a8), .amt(amt8), .left(left8), .arith(arith8), .y(y8_d1));
	am_shift #(.W(8), .SW(4), .DIR(2)) dut8_d2 (.a(a8), .amt(amt8), .left(left8), .arith(arith8), .y(y8_d2));

	/* W=12, SW=4, DIR=0 */
	reg [11:0] a12; reg [3:0] amt12; reg left12, arith12; wire [11:0] y12;
	am_shift #(.W(12), .SW(4), .DIR(0)) dut12 (.a(a12), .amt(amt12), .left(left12), .arith(arith12), .y(y12));

	/* W=16, SW=5, DIR=0, 1, 2 */
	reg [15:0] a16; reg [4:0] amt16; reg left16, arith16;
	wire [15:0] y16_d0, y16_d1, y16_d2;
	am_shift #(.W(16), .SW(5), .DIR(0)) dut16_d0 (.a(a16), .amt(amt16), .left(left16), .arith(arith16), .y(y16_d0));
	am_shift #(.W(16), .SW(5), .DIR(1)) dut16_d1 (.a(a16), .amt(amt16), .left(left16), .arith(arith16), .y(y16_d1));
	am_shift #(.W(16), .SW(5), .DIR(2)) dut16_d2 (.a(a16), .amt(amt16), .left(left16), .arith(arith16), .y(y16_d2));

	/* W=20, SW=5, DIR=0 */
	reg [19:0] a20; reg [4:0] amt20; reg left20, arith20; wire [19:0] y20;
	am_shift #(.W(20), .SW(5), .DIR(0)) dut20 (.a(a20), .amt(amt20), .left(left20), .arith(arith20), .y(y20));

	/* W=24, SW=6, DIR=0 */
	reg [23:0] a24; reg [5:0] amt24; reg left24, arith24; wire [23:0] y24;
	am_shift #(.W(24), .SW(6), .DIR(0)) dut24 (.a(a24), .amt(amt24), .left(left24), .arith(arith24), .y(y24));

	/* W=32, SW=6, DIR=0, 1, 2 */
	reg [31:0] a32; reg [5:0] amt32; reg left32, arith32;
	wire [31:0] y32_d0, y32_d1, y32_d2;
	am_shift #(.W(32), .SW(6), .DIR(0)) dut32_d0 (.a(a32), .amt(amt32), .left(left32), .arith(arith32), .y(y32_d0));
	am_shift #(.W(32), .SW(6), .DIR(1)) dut32_d1 (.a(a32), .amt(amt32), .left(left32), .arith(arith32), .y(y32_d1));
	am_shift #(.W(32), .SW(6), .DIR(2)) dut32_d2 (.a(a32), .amt(amt32), .left(left32), .arith(arith32), .y(y32_d2));

	/* W=48, SW=7, DIR=0 */
	reg [47:0] a48; reg [6:0] amt48; reg left48, arith48; wire [47:0] y48;
	am_shift #(.W(48), .SW(7), .DIR(0)) dut48 (.a(a48), .amt(amt48), .left(left48), .arith(arith48), .y(y48));

	/* W=64, SW=7, DIR=0, 1, 2 */
	reg [63:0] a64; reg [6:0] amt64; reg left64, arith64;
	wire [63:0] y64_d0, y64_d1, y64_d2;
	am_shift #(.W(64), .SW(7), .DIR(0)) dut64_d0 (.a(a64), .amt(amt64), .left(left64), .arith(arith64), .y(y64_d0));
	am_shift #(.W(64), .SW(7), .DIR(1)) dut64_d1 (.a(a64), .amt(amt64), .left(left64), .arith(arith64), .y(y64_d1));
	am_shift #(.W(64), .SW(7), .DIR(2)) dut64_d2 (.a(a64), .amt(amt64), .left(left64), .arith(arith64), .y(y64_d2));

	/* -------------------------------------------------------------
	 * Test Execution
	 * ------------------------------------------------------------- */
	initial begin
		/* 1. W=1 (exhaustive: 2 values * 2 amounts * 4 modes = 16 vectors) */
		for (i = 0; i < 2; i = i + 1) begin
			a1 = i[0];
			for (amt_i = 0; amt_i < 2; amt_i = amt_i + 1) begin
				amt1 = amt_i[0];
				for (k = 0; k < 4; k = k + 1) begin
					left1 = k[0]; arith1 = k[1]; #1;
					exp64 = ref_shift(7'd1, {63'd0, a1}, {6'd0, amt1}, left1, arith1, 2'd0);
					if (y1 !== exp64[0]) begin
						$display("FAIL W=1: a=%b amt=%b l=%b ar=%b got=%b exp=%b", a1, amt1, left1, arith1, y1, exp64[0]);
						errors = errors + 1;
					end
					total_vectors = total_vectors + 1;
				end
			end
		end

		/* 2. W=2 (exhaustive: 4 values * 4 amounts * 4 modes = 64 vectors) */
		for (i = 0; i < 4; i = i + 1) begin
			a2 = i[1:0];
			for (amt_i = 0; amt_i < 4; amt_i = amt_i + 1) begin
				amt2 = amt_i[1:0];
				for (k = 0; k < 4; k = k + 1) begin
					left2 = k[0]; arith2 = k[1]; #1;
					exp64 = ref_shift(7'd2, {62'd0, a2}, {5'd0, amt2}, left2, arith2, 2'd0);
					if (y2 !== exp64[1:0]) begin
						$display("FAIL W=2: a=%b amt=%d l=%b ar=%b got=%b exp=%b", a2, amt2, left2, arith2, y2, exp64[1:0]);
						errors = errors + 1;
					end
					total_vectors = total_vectors + 1;
				end
			end
		end

		/* 3. W=3 (exhaustive: 8 values * 4 amounts * 4 modes = 128 vectors) */
		for (i = 0; i < 8; i = i + 1) begin
			a3 = i[2:0];
			for (amt_i = 0; amt_i < 4; amt_i = amt_i + 1) begin
				amt3 = amt_i[1:0];
				for (k = 0; k < 4; k = k + 1) begin
					left3 = k[0]; arith3 = k[1]; #1;
					exp64 = ref_shift(7'd3, {61'd0, a3}, {5'd0, amt3}, left3, arith3, 2'd0);
					if (y3 !== exp64[2:0]) begin
						$display("FAIL W=3: a=%b amt=%d l=%b ar=%b got=%b exp=%b", a3, amt3, left3, arith3, y3, exp64[2:0]);
						errors = errors + 1;
					end
					total_vectors = total_vectors + 1;
				end
			end
		end

		/* 4. W=4 (exhaustive for DIR=0, 1, 2: 16 values * 8 amounts * 4 modes * 3 = 1,536 vectors) */
		for (i = 0; i < 16; i = i + 1) begin
			a4 = i[3:0];
			for (amt_i = 0; amt_i < 8; amt_i = amt_i + 1) begin
				amt4 = amt_i[2:0];
				for (k = 0; k < 4; k = k + 1) begin
					left4 = k[0]; arith4 = k[1]; #1;
					/* DIR 0 */
					exp64 = ref_shift(7'd4, {60'd0, a4}, {4'd0, amt4}, left4, arith4, 2'd0);
					if (y4_d0 !== exp64[3:0]) begin
						$display("FAIL W=4 DIR=0: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a4, amt4, left4, arith4, y4_d0, exp64[3:0]);
						errors = errors + 1;
					end
					/* DIR 1 */
					exp64 = ref_shift(7'd4, {60'd0, a4}, {4'd0, amt4}, left4, arith4, 2'd1);
					if (y4_d1 !== exp64[3:0]) begin
						$display("FAIL W=4 DIR=1: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a4, amt4, left4, arith4, y4_d1, exp64[3:0]);
						errors = errors + 1;
					end
					/* DIR 2 */
					exp64 = ref_shift(7'd4, {60'd0, a4}, {4'd0, amt4}, left4, arith4, 2'd2);
					if (y4_d2 !== exp64[3:0]) begin
						$display("FAIL W=4 DIR=2: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a4, amt4, left4, arith4, y4_d2, exp64[3:0]);
						errors = errors + 1;
					end
					total_vectors = total_vectors + 3;
				end
			end
		end

		/* 5. W=5 (exhaustive: 32 values * 8 amounts * 4 modes = 1,024 vectors) */
		for (i = 0; i < 32; i = i + 1) begin
			a5 = i[4:0];
			for (amt_i = 0; amt_i < 8; amt_i = amt_i + 1) begin
				amt5 = amt_i[2:0];
				for (k = 0; k < 4; k = k + 1) begin
					left5 = k[0]; arith5 = k[1]; #1;
					exp64 = ref_shift(7'd5, {59'd0, a5}, {4'd0, amt5}, left5, arith5, 2'd0);
					if (y5 !== exp64[4:0]) begin
						$display("FAIL W=5: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a5, amt5, left5, arith5, y5, exp64[4:0]);
						errors = errors + 1;
					end
					total_vectors = total_vectors + 1;
				end
			end
		end

		/* 6. W=8 (exhaustive for DIR=0, 1, 2: 256 values * 16 amounts * 4 modes * 3 = 49,152 vectors) */
		for (i = 0; i < 256; i = i + 1) begin
			a8 = i[7:0];
			for (amt_i = 0; amt_i < 16; amt_i = amt_i + 1) begin
				amt8 = amt_i[3:0];
				for (k = 0; k < 4; k = k + 1) begin
					left8 = k[0]; arith8 = k[1]; #1;
					exp64 = ref_shift(7'd8, {56'd0, a8}, {3'd0, amt8}, left8, arith8, 2'd0);
					if (y8_d0 !== exp64[7:0]) begin
						$display("FAIL W=8 DIR=0: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a8, amt8, left8, arith8, y8_d0, exp64[7:0]);
						errors = errors + 1;
					end
					exp64 = ref_shift(7'd8, {56'd0, a8}, {3'd0, amt8}, left8, arith8, 2'd1);
					if (y8_d1 !== exp64[7:0]) begin
						$display("FAIL W=8 DIR=1: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a8, amt8, left8, arith8, y8_d1, exp64[7:0]);
						errors = errors + 1;
					end
					exp64 = ref_shift(7'd8, {56'd0, a8}, {3'd0, amt8}, left8, arith8, 2'd2);
					if (y8_d2 !== exp64[7:0]) begin
						$display("FAIL W=8 DIR=2: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a8, amt8, left8, arith8, y8_d2, exp64[7:0]);
						errors = errors + 1;
					end
					total_vectors = total_vectors + 3;
				end
			end
		end

		/* 7. W=12 (all 16 amounts: corners + random = 16 * 100 * 4 = 6,400 vectors) */
		for (amt_i = 0; amt_i < 16; amt_i = amt_i + 1) begin
			amt12 = amt_i[3:0];
			for (j = 0; j < 100; j = j + 1) begin
				case (j)
					0: a12 = 12'h000;
					1: a12 = 12'hFFF;
					2: a12 = 12'hAAA;
					3: a12 = 12'h555;
					4: a12 = 12'h800;
					5: a12 = 12'h001;
					default: a12 = $random(seed);
				endcase
				for (k = 0; k < 4; k = k + 1) begin
					left12 = k[0]; arith12 = k[1]; #1;
					exp64 = ref_shift(7'd12, {52'd0, a12}, {3'd0, amt12}, left12, arith12, 2'd0);
					if (y12 !== exp64[11:0]) begin
						$display("FAIL W=12: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a12, amt12, left12, arith12, y12, exp64[11:0]);
						errors = errors + 1;
					end
					total_vectors = total_vectors + 1;
				end
			end
		end

		/* 8. W=16 (all 32 amounts * DIR 0, 1, 2: corners + random = 32 * 100 * 4 * 3 = 38,400 vectors) */
		for (amt_i = 0; amt_i < 32; amt_i = amt_i + 1) begin
			amt16 = amt_i[4:0];
			for (j = 0; j < 100; j = j + 1) begin
				case (j)
					0: a16 = 16'h0000;
					1: a16 = 16'hFFFF;
					2: a16 = 16'hAAAA;
					3: a16 = 16'h5555;
					4: a16 = 16'h8000;
					5: a16 = 16'h7FFF;
					6: a16 = 16'h0001;
					default: a16 = $random(seed);
				endcase
				for (k = 0; k < 4; k = k + 1) begin
					left16 = k[0]; arith16 = k[1]; #1;
					exp64 = ref_shift(7'd16, {48'd0, a16}, {2'd0, amt16}, left16, arith16, 2'd0);
					if (y16_d0 !== exp64[15:0]) begin
						$display("FAIL W=16 DIR=0: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a16, amt16, left16, arith16, y16_d0, exp64[15:0]);
						errors = errors + 1;
					end
					exp64 = ref_shift(7'd16, {48'd0, a16}, {2'd0, amt16}, left16, arith16, 2'd1);
					if (y16_d1 !== exp64[15:0]) begin
						$display("FAIL W=16 DIR=1: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a16, amt16, left16, arith16, y16_d1, exp64[15:0]);
						errors = errors + 1;
					end
					exp64 = ref_shift(7'd16, {48'd0, a16}, {2'd0, amt16}, left16, arith16, 2'd2);
					if (y16_d2 !== exp64[15:0]) begin
						$display("FAIL W=16 DIR=2: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a16, amt16, left16, arith16, y16_d2, exp64[15:0]);
						errors = errors + 1;
					end
					total_vectors = total_vectors + 3;
				end
			end
		end

		/* 9. W=20 (all 32 amounts: corners + random = 32 * 50 * 4 = 6,400 vectors) */
		for (amt_i = 0; amt_i < 32; amt_i = amt_i + 1) begin
			amt20 = amt_i[4:0];
			for (j = 0; j < 50; j = j + 1) begin
				case (j)
					0: a20 = 20'h00000;
					1: a20 = 20'hFFFFF;
					2: a20 = 20'hAAAAA;
					3: a20 = 20'h55555;
					4: a20 = 20'h80000;
					5: a20 = 20'h00001;
					default: a20 = {$random(seed), $random(seed)};
				endcase
				for (k = 0; k < 4; k = k + 1) begin
					left20 = k[0]; arith20 = k[1]; #1;
					exp64 = ref_shift(7'd20, {44'd0, a20}, {2'd0, amt20}, left20, arith20, 2'd0);
					if (y20 !== exp64[19:0]) begin
						$display("FAIL W=20: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a20, amt20, left20, arith20, y20, exp64[19:0]);
						errors = errors + 1;
					end
					total_vectors = total_vectors + 1;
				end
			end
		end

		/* 10. W=24 (all 64 amounts: corners + random = 64 * 50 * 4 = 12,800 vectors) */
		for (amt_i = 0; amt_i < 64; amt_i = amt_i + 1) begin
			amt24 = amt_i[5:0];
			for (j = 0; j < 50; j = j + 1) begin
				case (j)
					0: a24 = 24'h000000;
					1: a24 = 24'hFFFFFF;
					2: a24 = 24'hAAAAAA;
					3: a24 = 24'h555555;
					4: a24 = 24'h800000;
					5: a24 = 24'h7FFFFF;
					6: a24 = 24'h000001;
					default: a24 = {$random(seed), $random(seed)};
				endcase
				for (k = 0; k < 4; k = k + 1) begin
					left24 = k[0]; arith24 = k[1]; #1;
					exp64 = ref_shift(7'd24, {40'd0, a24}, {1'b0, amt24}, left24, arith24, 2'd0);
					if (y24 !== exp64[23:0]) begin
						$display("FAIL W=24: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a24, amt24, left24, arith24, y24, exp64[23:0]);
						errors = errors + 1;
					end
					total_vectors = total_vectors + 1;
				end
			end
		end

		/* 11. W=32 (all 64 amounts * DIR 0, 1, 2: corners + random = 64 * 100 * 4 * 3 = 76,800 vectors) */
		for (amt_i = 0; amt_i < 64; amt_i = amt_i + 1) begin
			amt32 = amt_i[5:0];
			for (j = 0; j < 100; j = j + 1) begin
				case (j)
					0: a32 = 32'h00000000;
					1: a32 = 32'hFFFFFFFF;
					2: a32 = 32'hAAAAAAAA;
					3: a32 = 32'h55555555;
					4: a32 = 32'h80000000;
					5: a32 = 32'h7FFFFFFF;
					6: a32 = 32'h00000001;
					default: a32 = $random(seed);
				endcase
				for (k = 0; k < 4; k = k + 1) begin
					left32 = k[0]; arith32 = k[1]; #1;
					exp64 = ref_shift(7'd32, {32'd0, a32}, {1'b0, amt32}, left32, arith32, 2'd0);
					if (y32_d0 !== exp64[31:0]) begin
						$display("FAIL W=32 DIR=0: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a32, amt32, left32, arith32, y32_d0, exp64[31:0]);
						errors = errors + 1;
					end
					exp64 = ref_shift(7'd32, {32'd0, a32}, {1'b0, amt32}, left32, arith32, 2'd1);
					if (y32_d1 !== exp64[31:0]) begin
						$display("FAIL W=32 DIR=1: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a32, amt32, left32, arith32, y32_d1, exp64[31:0]);
						errors = errors + 1;
					end
					exp64 = ref_shift(7'd32, {32'd0, a32}, {1'b0, amt32}, left32, arith32, 2'd2);
					if (y32_d2 !== exp64[31:0]) begin
						$display("FAIL W=32 DIR=2: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a32, amt32, left32, arith32, y32_d2, exp64[31:0]);
						errors = errors + 1;
					end
					total_vectors = total_vectors + 3;
				end
			end
		end

		/* 12. W=48 (all 128 amounts: corners + random = 128 * 40 * 4 = 20,480 vectors) */
		for (amt_i = 0; amt_i < 128; amt_i = amt_i + 1) begin
			amt48 = amt_i[6:0];
			for (j = 0; j < 40; j = j + 1) begin
				case (j)
					0: a48 = 48'h000000000000;
					1: a48 = 48'hFFFFFFFFFFFF;
					2: a48 = 48'hAAAAAAAAAAAA;
					3: a48 = 48'h555555555555;
					4: a48 = 48'h800000000000;
					5: a48 = 48'h7FFFFFFFFFFF;
					6: a48 = 48'h000000000001;
					default: a48 = {$random(seed), $random(seed)};
				endcase
				for (k = 0; k < 4; k = k + 1) begin
					left48 = k[0]; arith48 = k[1]; #1;
					exp64 = ref_shift(7'd48, {16'd0, a48}, amt48, left48, arith48, 2'd0);
					if (y48 !== exp64[47:0]) begin
						$display("FAIL W=48: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a48, amt48, left48, arith48, y48, exp64[47:0]);
						errors = errors + 1;
					end
					total_vectors = total_vectors + 1;
				end
			end
		end

		/* 13. W=64 (all 128 amounts * DIR 0, 1, 2: corners + random = 128 * 50 * 4 * 3 = 76,800 vectors) */
		for (amt_i = 0; amt_i < 128; amt_i = amt_i + 1) begin
			amt64 = amt_i[6:0];
			for (j = 0; j < 50; j = j + 1) begin
				case (j)
					0: a64 = 64'h0000000000000000;
					1: a64 = 64'hFFFFFFFFFFFFFFFF;
					2: a64 = 64'hAAAAAAAAAAAAAAAA;
					3: a64 = 64'h5555555555555555;
					4: a64 = 64'h8000000000000000;
					5: a64 = 64'h7FFFFFFFFFFFFFFF;
					6: a64 = 64'h0000000000000001;
					default: a64 = {$random(seed), $random(seed)};
				endcase
				for (k = 0; k < 4; k = k + 1) begin
					left64 = k[0]; arith64 = k[1]; #1;
					exp64 = ref_shift(7'd64, a64, amt64, left64, arith64, 2'd0);
					if (y64_d0 !== exp64) begin
						$display("FAIL W=64 DIR=0: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a64, amt64, left64, arith64, y64_d0, exp64);
						errors = errors + 1;
					end
					exp64 = ref_shift(7'd64, a64, amt64, left64, arith64, 2'd1);
					if (y64_d1 !== exp64) begin
						$display("FAIL W=64 DIR=1: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a64, amt64, left64, arith64, y64_d1, exp64);
						errors = errors + 1;
					end
					exp64 = ref_shift(7'd64, a64, amt64, left64, arith64, 2'd2);
					if (y64_d2 !== exp64) begin
						$display("FAIL W=64 DIR=2: a=%h amt=%d l=%b ar=%b got=%h exp=%h", a64, amt64, left64, arith64, y64_d2, exp64);
						errors = errors + 1;
					end
					total_vectors = total_vectors + 3;
				end
			end
		end

		/* Final result */
		if (errors == 0) begin
			$display("PASS am_shift");
			$display("am_shift verified: %0d vectors (all widths 1..64, DIR 0/1/2, shift amounts, left/logical-right/arith-right bit-exact)", total_vectors);
		end else begin
			$display("FAIL am_shift: %0d errors", errors);
		end

		$finish;
	end
endmodule

`default_nettype wire
