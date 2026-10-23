/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_lane_tb: the quad operations (NPHYS 8): qdx/qdy (fine
 * derivatives, fp32 v[lane|1] - v[lane&~1] and v[lane|2] - v[lane&~2],
 * against real arithmetic on normal inputs whose exponents differ by at
 * most 24, so the double difference is exact and its rounding to single
 * is RNE) and qswap1/2/3, qbcast, SHORT_LAT cycles after x_valid.
 * shfl/vote/ballot (SUBGROUP) are p009: "sub" is not printed yet.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_lane_tb;
`include "atg_su_uop.vh"
	localparam NPHYS = 8;
	localparam DW = NPHYS * 32;
	localparam LAT = 6;
	localparam N = 2000;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg x_valid = 0;
	reg [1:0] x_warp = 0, x_grp = 0;
	reg [ATG_UOP_W-1:0] x_uop = 0;
	reg [DW-1:0] x_a = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	wire x_ready, s_valid;
	wire [1:0] s_warp, s_grp;
	wire [6:0] s_rd;
	wire [DW-1:0] s_data;
	wire [NPHYS-1:0] s_lanes;
	integer seed = 1;
	integer errors = 0, i, l, t = 0, base;
	reg [DW-1:0] want [0:N-1];
	reg [2:0] sub_of [0:N-1];

	always #5 clk = !clk;
	always @(posedge clk)
		t <= t + 1;

	atg_su_lane #(.NPHYS(NPHYS), .SHORT_LAT(LAT)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.x_last(1'b0), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a),
		.x_b({DW{1'b0}}), .x_c({DW{1'b0}}), .x_mask(x_mask), .x_info(32'd0),
		.x_ready(x_ready), .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp), .s_rd(s_rd),
		.s_data(s_data), .s_lanes(s_lanes)
	);

	function [31:0] rf;	/* a normal float, exponent 100-124 */
		input integer dummy;
		reg [31:0] v;
		begin
			v = $random(seed);
			v[30:23] = 8'd100 + ($unsigned($random(seed)) % 25);
			if (($random(seed) & 15) == 0)
				v[22:0] = 0;
			rf = v;
		end
	endfunction

	/* Single <-> double by hand (normal numbers only; iverilog has no shortreal). */
	function real s2d;
		input [31:0] v;
		s2d = $bitstoreal({v[31], {3'd0, v[30:23]} + 11'd896, v[22:0], 29'd0});
	endfunction

	function [31:0] d2s;	/* RNE */
		input real r;
		reg [63:0] b;
		reg [24:0] m;
		reg [10:0] e;
		begin
			b = $realtobits(r);
			if (b[62:0] == 0)
				d2s = {b[63], 31'd0};
			else begin
				m = {2'b01, b[51:29]};
				if (b[28] && (b[27:0] != 0 || b[29]))
					m = m + 25'd1;
				e = b[62:52] - 11'd896;
				if (m[24]) begin
					m = m >> 1;
					e = e + 11'd1;
				end
				d2s = {b[63], e[7:0], m[22:0]};
			end
		end
	endfunction

	function [31:0] fsub;
		input [31:0] p, q;
		fsub = d2s(s2d(p) - s2d(q));
	endfunction

	integer j;
	initial begin
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		@(negedge clk);
		base = t;
		for (i = 0; i < N; i = i + 1) begin
			x_valid = 1'b1;
			x_uop = 0;
			x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_LANE;
			x_uop[ATG_UOP_OP +: 8] = ATG_LANE_QD;
			x_uop[ATG_UOP_WRD] = 1'b1;
			x_uop[ATG_UOP_RD +: 7] = i & 63;
			sub_of[i] = $unsigned($random(seed)) % 6;
			x_uop[ATG_UOP_SUB +: 5] = sub_of[i];
			x_grp = i;
			x_warp = i >> 2;
			x_mask = 16'h00FF;
			for (l = 0; l < NPHYS; l = l + 1) begin
				x_a[l*32 +: 32] = rf(0);
				if (($random(seed) & 7) == 0 && l > 0)
					x_a[l*32 +: 32] = x_a[(l-1)*32 +: 32];
			end
			for (l = 0; l < NPHYS; l = l + 1) begin
				case (sub_of[i])
				0: want[i][l*32 +: 32] = fsub(x_a[(l | 1)*32 +: 32], x_a[(l & ~1)*32 +: 32]);
				1: want[i][l*32 +: 32] = fsub(x_a[(l | 2)*32 +: 32], x_a[(l & ~2)*32 +: 32]);
				2: want[i][l*32 +: 32] = x_a[(l ^ 1)*32 +: 32];
				3: want[i][l*32 +: 32] = x_a[(l ^ 2)*32 +: 32];
				4: want[i][l*32 +: 32] = x_a[(l ^ 3)*32 +: 32];
				default: want[i][l*32 +: 32] = x_a[(l & ~3)*32 +: 32];
				endcase
			end
			@(negedge clk);
		end
		x_valid = 1'b0;
		repeat (LAT + 3) @(negedge clk);
		if (errors == 0) begin
			$display("PASS atg_su_lane.qd");
			$display("PASS atg_su_lane");
		end
		$finish;
	end

	always @(negedge clk) begin
		if (rst_n && t - LAT - base >= 0 && t - LAT - base < N) begin
			j = t - LAT - base;
			if (!s_valid || s_rd !== (j & 63) || s_grp !== (j & 3) || s_data !== want[j]) begin
				if (errors < 5)
					$display("FAIL atg_su_lane.qd %0d sub %0d: %h want %h", j, sub_of[j],
						s_data, want[j]);
				errors = errors + 1;
			end
		end
	end

	initial begin
		#1000000;
		$display("FAIL atg_su_lane timeout");
		$finish;
	end
endmodule

`default_nettype wire
