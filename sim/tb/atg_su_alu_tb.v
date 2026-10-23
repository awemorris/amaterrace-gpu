/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_alu_tb: random ALU uops (register and immediate forms) on random
 * and corner operands against a behavioural reference; every result must
 * come exactly SHORT_LAT cycles later with its warp, group, rd and lanes.
 * Groups of other units must not produce results.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_alu_tb;
`include "atg_su_uop.vh"
	localparam NPHYS = 8;
	localparam LAT = 6;
	localparam DW = NPHYS * 32;
	localparam N = 3000;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg x_valid = 1'b0;
	reg [1:0] x_warp = 2'd0, x_grp = 2'd0;
	reg [ATG_UOP_W-1:0] x_uop = 0;
	reg [DW-1:0] x_a = 0, x_b = 0, x_c = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	wire x_ready, s_valid;
	wire [1:0] s_warp, s_grp;
	wire [6:0] s_rd;
	wire [DW-1:0] s_data;
	wire [NPHYS-1:0] s_lanes;
	integer seed = 1;
	integer errors = 0, lat_err = 0;
	integer i, j, l, base, n_res;
	/* Expected results by issue cycle. */
	reg [DW-1:0] want_d [0:N+LAT+8];
	reg [6:0] want_rd [0:N+LAT+8];
	reg [1:0] want_w [0:N+LAT+8], want_g [0:N+LAT+8];
	reg [NPHYS-1:0] want_l [0:N+LAT+8];
	reg want_v [0:N+LAT+8];

	always #5 clk = !clk;

	atg_su_alu #(.NPHYS(NPHYS), .SHORT_LAT(LAT)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.x_last(1'b0), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
		.x_c(x_c), .x_mask(x_mask), .x_info(32'd0), .x_ready(x_ready),
		.s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp), .s_rd(s_rd), .s_data(s_data),
		.s_lanes(s_lanes)
	);

	function [31:0] model;
		input [4:0] o;
		input [31:0] a, b, c, imm;
		reg signed [32:0] sa, sb;
		begin
			sa = {a[31], a};
			sb = {b[31], b};
			case (o)
			0: model = a + b;
			1: model = a - b;
			2: model = a << (b % 32);
			3: model = sa < sb ? 32'hFFFFFFFF : 32'd0;
			4: model = {1'b0, a} < {1'b0, b} ? 32'hFFFFFFFF : 32'd0;
			5: model = a ^ b;
			6: model = a >> (b % 32);
			7: model = (sa >>> (b % 32));
			8: model = a | b;
			9: model = a & b;
			10: model = sa < sb ? a : b;
			11: model = sa > sb ? a : b;
			12: model = a < b ? a : b;
			13: model = a > b ? a : b;
			14: model = a & ~b;
			15: model = a | ~b;
			16: model = ~(a ^ b);
			17: model = (a & b) | (~a & c);
			18: model = imm;
			default: model = 0;
			endcase
		end
	endfunction

	function [31:0] rnd;
		input integer dummy;
		integer k;
		begin
			k = $random(seed) & 7;
			case (k)
			0: rnd = 32'd0;
			1: rnd = 32'hFFFFFFFF;
			2: rnd = 32'h80000000;
			3: rnd = 32'h7FFFFFFF;
			4: rnd = $random(seed) & 31;
			default: rnd = $random(seed);
			endcase
		end
	endfunction

	reg [4:0] op;
	reg immb, mine;
	reg [31:0] imm, bb;

	initial begin
		for (i = 0; i < N + LAT + 8; i = i + 1)
			want_v[i] = 1'b0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		@(negedge clk);
		base = t;
		for (i = 0; i < N; i = i + 1) begin
			op = $random(seed) % 19;
			if (op > 18)
				op = 0;
			immb = op != 1 && op != 17 && op != 18 && ($random(seed) & 1);
			imm = rnd(0);
			mine = ($random(seed) & 7) != 0;
			x_valid = ($random(seed) & 3) != 0;
			x_warp = $random(seed);
			x_grp = $random(seed);
			x_uop = 0;
			x_uop[ATG_UOP_UNIT +: 4] = mine ? ATG_UNIT_ALU : ATG_UNIT_FPU;
			x_uop[ATG_UOP_OP +: 8] = {immb, 2'b00, op};
			x_uop[ATG_UOP_RD +: 7] = $random(seed) & 63;
			x_uop[ATG_UOP_IMM +: 32] = imm;
			x_uop[ATG_UOP_WRD] = 1'b1;
			x_mask = $random(seed);
			for (l = 0; l < NPHYS; l = l + 1) begin
				x_a[l*32 +: 32] = rnd(0);
				x_b[l*32 +: 32] = rnd(0);
				x_c[l*32 +: 32] = rnd(0);
				bb = immb ? imm : x_b[l*32 +: 32];
				want_d[i][l*32 +: 32] = model(op, x_a[l*32 +: 32], bb, x_c[l*32 +: 32], imm);
			end
			want_v[i] = x_valid && mine;
			want_w[i] = x_warp;
			want_g[i] = x_grp;
			want_rd[i] = x_uop[ATG_UOP_RD +: 7];
			want_l[i] = x_mask[NPHYS-1:0];
			if (!x_ready) begin
				$display("FAIL atg_su_alu.ops x_ready 0");
				errors = errors + 1;
			end
			@(negedge clk);
		end
		x_valid = 1'b0;
		repeat (LAT + 4) @(negedge clk);
		if (errors == 0)
			$display("PASS atg_su_alu.ops");
		if (lat_err == 0 && n_res > N / 2)
			$display("PASS atg_su_alu.lat");
		else
			$display("FAIL atg_su_alu.lat %0d errors, %0d results", lat_err, n_res);
		if (errors == 0 && lat_err == 0)
			$display("PASS atg_su_alu");
		$finish;
	end

	/* Results: at negedge, the instruction issued LAT cycles ago. */
	integer t = -1;
	initial begin
		n_res = 0;
		base = -1;
	end
	always @(posedge clk)
		if (rst_n)
			t <= t + 1;
	always @(negedge clk) begin
		if (rst_n) begin
			if (base >= 0 && t - LAT - base >= 0 && t - LAT - base < N) begin
				j = t - LAT - base;
				if (s_valid !== want_v[j] || (s_valid && (s_warp !== want_w[j] ||
				    s_grp !== want_g[j] || s_rd !== want_rd[j] || s_lanes !== want_l[j]))) begin
					$display("FAIL atg_su_alu.lat at %0d: v %b want %b", j, s_valid,
						want_v[j]);
					lat_err = lat_err + 1;
				end
				if (s_valid && s_data !== want_d[j]) begin
					$display("FAIL atg_su_alu.ops at %0d: %h want %h", j, s_data,
						want_d[j]);
					errors = errors + 1;
				end
				if (s_valid)
					n_res = n_res + 1;
			end
		end
	end

	initial begin
		#1000000;
		$display("FAIL atg_su_alu timeout");
		$finish;
	end
endmodule

`default_nettype wire
