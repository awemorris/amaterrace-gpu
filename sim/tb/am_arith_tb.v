/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_arith_tb: the common arithmetic modules of rtl/common/ (docs/style.md,
 * "Arithmetic") against the testbench's own arithmetic: am_add, am_sub and
 * am_addsub (8 bits exhaustively with both carries, 32 bits at random),
 * am_shift (8 and 32 bits, every amount, left, logical and arithmetic
 * right), am_mul (17 x 13 unsigned and signed, LAT 0 and 2), am_div (8 bits
 * exhaustively, 32 bits at random, the divisor 0).  Each group prints
 * PASS am_arith.GROUP; the seed is +seed.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_arith_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	integer seed = 1;
	integer errors = 0, before = 0;
	integer i, j, k;

	/* ---- add, sub, addsub */
	reg [7:0] a8, b8;
	reg c8, s8;
	wire [7:0] add8_s, sub8_d, as8_s;
	wire add8_co, sub8_bo, as8_co;
	reg [31:0] a32, b32;
	reg c32, s32;
	wire [31:0] add32_s, sub32_d, as32_s;
	wire add32_co, sub32_bo, as32_co;

	am_add #(.W(8)) add8 (.a(a8), .b(b8), .ci(c8), .s(add8_s), .co(add8_co));
	am_sub #(.W(8)) sub8 (.a(a8), .b(b8), .bi(c8), .d(sub8_d), .bo(sub8_bo));
	am_addsub #(.W(8)) as8 (.a(a8), .b(b8), .sub(s8), .s(as8_s), .co(as8_co));
	am_add #(.W(32)) add32 (.a(a32), .b(b32), .ci(c32), .s(add32_s), .co(add32_co));
	am_sub #(.W(32)) sub32 (.a(a32), .b(b32), .bi(c32), .d(sub32_d), .bo(sub32_bo));
	am_addsub #(.W(32)) as32 (.a(a32), .b(b32), .sub(s32), .s(as32_s), .co(as32_co));

	/* ---- shift */
	reg [7:0] sh8_a;
	reg [2:0] sh8_n;
	reg sh_left, sh_arith;
	wire [7:0] sh8_y;
	reg [31:0] sh32_a;
	reg [4:0] sh32_n;
	wire [31:0] sh32_y;

	am_shift #(.W(8), .SW(3)) sh8 (.a(sh8_a), .amt(sh8_n), .left(sh_left), .arith(sh_arith),
		.y(sh8_y));
	am_shift #(.W(32), .SW(5)) sh32 (.a(sh32_a), .amt(sh32_n), .left(sh_left),
		.arith(sh_arith), .y(sh32_y));

	/* ---- mul */
	reg [16:0] ma;
	reg [12:0] mb;
	reg men = 1'b1;
	wire [29:0] mu0, ms0, mu2, ms2;

	am_mul #(.AW(17), .BW(13), .SIGNED(0), .LAT(0)) mul_u0 (.clk(clk), .en(men), .a(ma), .b(mb),
		.p(mu0));
	am_mul #(.AW(17), .BW(13), .SIGNED(1), .LAT(0)) mul_s0 (.clk(clk), .en(men), .a(ma), .b(mb),
		.p(ms0));
	am_mul #(.AW(17), .BW(13), .SIGNED(0), .LAT(2)) mul_u2 (.clk(clk), .en(men), .a(ma), .b(mb),
		.p(mu2));
	am_mul #(.AW(17), .BW(13), .SIGNED(1), .LAT(2)) mul_s2 (.clk(clk), .en(men), .a(ma), .b(mb),
		.p(ms2));

	/* ---- div */
	reg d8_start = 1'b0, d32_start = 1'b0;
	reg [7:0] d8_a, d8_b;
	reg [31:0] d32_a, d32_b;
	wire d8_busy, d8_done, d32_busy, d32_done;
	wire [7:0] d8_q, d8_r;
	wire [31:0] d32_q, d32_r;

	am_div #(.W(8), .CW(4)) div8 (.clk(clk), .rst_n(rst_n), .start(d8_start), .a(d8_a),
		.b(d8_b), .busy(d8_busy), .done(d8_done), .q(d8_q), .r(d8_r));
	am_div #(.W(32), .CW(6)) div32 (.clk(clk), .rst_n(rst_n), .start(d32_start), .a(d32_a),
		.b(d32_b), .busy(d32_busy), .done(d32_done), .q(d32_q), .r(d32_r));

	task group;
		input [8*8-1:0] name;
		begin
			if (errors == before)
				$display("PASS am_arith.%0s", name);
			else
				$display("FAIL am_arith.%0s: %0d errors", name, errors - before);
			before = errors;
		end
	endtask

	task fail;
		input [8*40-1:0] what;
		begin
			errors = errors + 1;
			if (errors < 20)
				$display("FAIL am_arith: %0s", what);
		end
	endtask

	reg [8:0] r9;
	reg [32:0] r33;
	reg [7:0] e8;
	reg [31:0] e32;
	reg signed [7:0] s8v;
	reg signed [31:0] s32v;
	reg [29:0] eu, es;
	reg [29:0] eu_q [0:1];
	reg [29:0] es_q [0:1];
	integer n;

	task div8_run;
		input [7:0] x, y;
		begin
			@(negedge clk);
			d8_a = x;
			d8_b = y;
			d8_start = 1'b1;
			@(negedge clk);
			d8_start = 1'b0;
			n = 0;
			while (!d8_done && n < 40) begin
				@(negedge clk);
				n = n + 1;
			end
			if (y == 0) begin
				if (d8_q !== 8'hFF || d8_r !== x)
					fail("div8 by 0");
			end else if (d8_q !== x / y || d8_r !== x % y) begin
				fail("div8");
			end
		end
	endtask

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;
		repeat (2) @(posedge clk);
		rst_n = 1'b1;

		/* add */
		for (i = 0; i < 256; i = i + 1)
			for (j = 0; j < 256; j = j + 1)
				for (k = 0; k < 2; k = k + 1) begin
					a8 = i;
					b8 = j;
					c8 = k;
					s8 = k;
					#1;
					r9 = {1'b0, a8} + {1'b0, b8} + k;
					if ({add8_co, add8_s} !== r9)
						fail("add8");
					r9 = {1'b0, a8} - {1'b0, b8} - k;
					if ({sub8_bo, sub8_d} !== r9)
						fail("sub8");
					if (k == 0) begin
						r9 = {1'b0, a8} + {1'b0, b8};
					end else begin
						r9 = {1'b0, a8} + {1'b0, ~b8} + 1;
					end
					if ({as8_co, as8_s} !== r9)
						fail("addsub8");
				end
		for (i = 0; i < 20000; i = i + 1) begin
			a32 = $random(seed);
			b32 = $random(seed);
			c32 = $random(seed);
			s32 = $random(seed);
			#1;
			r33 = {1'b0, a32} + {1'b0, b32} + c32;
			if ({add32_co, add32_s} !== r33)
				fail("add32");
			r33 = {1'b0, a32} - {1'b0, b32} - c32;
			if ({sub32_bo, sub32_d} !== r33)
				fail("sub32");
			e32 = s32 ? a32 - b32 : a32 + b32;
			if (as32_s !== e32)
				fail("addsub32");
		end
		group("add");

		/* shift */
		for (k = 0; k < 3; k = k + 1) begin
			sh_left = k == 0;
			sh_arith = k == 2;
			for (i = 0; i < 256; i = i + 1)
				for (j = 0; j < 8; j = j + 1) begin
					sh8_a = i;
					sh8_n = j;
					#1;
					s8v = sh8_a;
					/* (if, not ?:: an unsigned arm would make >>> logical) */
					if (k == 0)
						e8 = sh8_a << j;
					else if (k == 1)
						e8 = sh8_a >> j;
					else
						e8 = s8v >>> j;
					if (sh8_y !== e8)
						fail("shift8");
				end
			for (i = 0; i < 4000; i = i + 1) begin
				sh32_a = $random(seed);
				sh32_n = $random(seed);
				#1;
				s32v = sh32_a;
				if (k == 0)
					e32 = sh32_a << sh32_n;
				else if (k == 1)
					e32 = sh32_a >> sh32_n;
				else
					e32 = s32v >>> sh32_n;
				if (sh32_y !== e32)
					fail("shift32");
			end
		end
		group("shift");

		/* mul: LAT 0 at once, LAT 2 two clocks later */
		for (i = 0; i < 5000; i = i + 1) begin
			@(negedge clk);
			ma = $random(seed);
			mb = $random(seed);
			#1;
			eu = ma * mb;
			es = $signed(ma) * $signed(mb);
			if (mu0 !== eu)
				fail("mul unsigned");
			if (ms0 !== es)
				fail("mul signed");
			if (i >= 2 && (mu2 !== eu_q[1] || ms2 !== es_q[1]))
				fail("mul LAT 2");
			eu_q[1] = eu_q[0];
			es_q[1] = es_q[0];
			eu_q[0] = eu;
			es_q[0] = es;
		end
		group("mul");

		/* div */
		for (i = 0; i < 256; i = i + 1)
			for (j = 0; j < 256; j = j + 7)
				div8_run(i, j);
		div8_run(8'd200, 8'd255);
		for (i = 0; i < 300; i = i + 1) begin
			@(negedge clk);
			d32_a = $random(seed);
			d32_b = i % 50 == 0 ? 32'd0 : i % 3 == 0 ? $random(seed) & 32'hFF : $random(seed);
			d32_start = 1'b1;
			@(negedge clk);
			d32_start = 1'b0;
			n = 0;
			while (!d32_done && n < 80) begin
				@(negedge clk);
				n = n + 1;
			end
			if (n != 32)
				fail("div32 cycles");
			if (d32_b == 0) begin
				if (d32_q !== 32'hFFFFFFFF || d32_r !== d32_a)
					fail("div32 by 0");
			end else if (d32_q !== d32_a / d32_b || d32_r !== d32_a % d32_b) begin
				fail("div32");
			end
		end
		group("div");

		if (errors == 0)
			$display("PASS am_arith");
		else
			$display("FAIL am_arith: %0d errors", errors);
		$finish;
	end

	initial begin
		#100000000;
		$display("FAIL am_arith: timeout");
		$finish;
	end
endmodule

`default_nettype wire
