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
 * "sub": with SUBGROUP 1 and NPHYS 8, 16 and 32 (atg_su_lane_sgchk),
 * random shfl (every mode; sources in range, out of range, outside EXEC),
 * vote.any/all and ballot with EXEC full, empty, one lane and random,
 * interleaved with qswap/qbcast, against a model of the rules in the
 * module's header: the results (lanes outside EXEC and source operands of
 * those lanes are X on the bus, so no X may reach a written lane), the
 * lanes written, rd, warp and group, the cycle of each short result
 * (SHORT_LAT after x_end - (G-1) + g), and x_ready (0 for exactly G cycles
 * on the last group, 1 otherwise).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_lane_sgchk #(
	parameter NPHYS = 8,
	parameter SEED = 1
) (
	input wire clk,
	input wire go,
	output reg done,
	output reg [31:0] errs
);
`include "atg_su_uop.vh"
	localparam DW = NPHYS * 32;
	localparam G = 32 / NPHYS;
	localparam GRP_W = G > 1 ? $clog2(G) : 1;
	localparam LAT = 6;
	localparam N = 1500;

	reg rst_n = 1'b0;
	reg x_valid = 0, x_last = 0;
	reg [1:0] x_warp = 0;
	reg [GRP_W-1:0] x_grp = 0;
	reg [ATG_UOP_W-1:0] x_uop = 0;
	reg [DW-1:0] x_a = 0, x_b = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	wire x_ready, s_valid;
	wire [1:0] s_warp;
	wire [GRP_W-1:0] s_grp;
	wire [6:0] s_rd;
	wire [DW-1:0] s_data;
	wire [NPHYS-1:0] s_lanes;

	atg_su_lane #(.NPHYS(NPHYS), .GRP_W(GRP_W), .SHORT_LAT(LAT), .SUBGROUP(1)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.x_last(x_last), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a),
		.x_b(x_b), .x_c({DW{1'b0}}), .x_mask(x_mask), .x_info(32'd0),
		.x_ready(x_ready), .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp), .s_rd(s_rd),
		.s_data(s_data), .s_lanes(s_lanes)
	);

	integer seed = SEED;
	integer t = 0;
	always @(posedge clk)
		t <= t + 1;

	/* The expected short results, by the slot (t at the driving negedge). */
	reg ev [0:63];
	reg [DW-1:0] ed [0:63];
	reg [NPHYS-1:0] el [0:63];
	reg [6:0] erd [0:63];
	reg [1:0] ew [0:63];
	reg [GRP_W-1:0] eg [0:63];

	reg [31:0] a [0:31];
	reg [31:0] b [0:31];
	reg [31:0] r [0:31];
	reg [31:0] ex, wl, bal;
	reg [7:0] op;
	reg [4:0] sub;
	reg [6:0] rd;
	reg [1:0] warp;
	integer i, l, g, sl, k, src, stall, slot, kind;
	reg ok;

	task rnd_inst;
		begin
			kind = $unsigned($random(seed)) % 10;
			op = kind < 5 ? ATG_LANE_SHFL : kind < 7 ? ATG_LANE_VOTE : kind < 8 ?
				ATG_LANE_BALLOT : ATG_LANE_QD;
			sub = op == ATG_LANE_SHFL ? $unsigned($random(seed)) % 5 :
				op == ATG_LANE_VOTE ? $unsigned($random(seed)) % 2 :
				op == ATG_LANE_QD ? 2 + $unsigned($random(seed)) % 4 : 0;
			rd = $unsigned($random(seed)) % 64;
			warp = $random(seed);
			case ($unsigned($random(seed)) % 6)
			0: ex = 32'hFFFFFFFF;
			1: ex = 32'd0;
			2: ex = 32'd1 << ($unsigned($random(seed)) % 32);
			3: ex = ~(32'd1 << ($unsigned($random(seed)) % 32));
			default: ex = $random(seed);
			endcase
			for (l = 0; l < 32; l = l + 1) begin
				a[l] = ($random(seed) & 3) == 0 ? 32'd0 : $random(seed);
				case ($unsigned($random(seed)) % 5)
				0: b[l] = $unsigned($random(seed)) % 32;
				1: b[l] = $unsigned($random(seed)) % 64;
				2: b[l] = $unsigned($random(seed)) % 16;
				3: b[l] = $random(seed);
				default: b[l] = 32 - ($unsigned($random(seed)) % 3);
				endcase
			end
			/* The model. */
			bal = 32'd0;
			for (l = 0; l < 32; l = l + 1)
				if (ex[l] && a[l] != 0)
					bal[l] = 1'b1;
			wl = op == ATG_LANE_SHFL || op == ATG_LANE_QD ? ex : 32'hFFFFFFFF;
			for (l = 0; l < 32; l = l + 1) begin
				r[l] = 32'bx;
				if (op == ATG_LANE_BALLOT)
					r[l] = bal;
				else if (op == ATG_LANE_VOTE)
					r[l] = (sub[0] ? bal == ex : bal != 0) ? 32'hFFFFFFFF : 32'd0;
				else if (op == ATG_LANE_QD) begin
					case (sub)
					2: src = l ^ 1;
					3: src = l ^ 2;
					4: src = l ^ 3;
					default: src = l & ~3;
					endcase
					r[l] = a[src];
				end else if (ex[l]) begin
					case (sub)
					0: ok = b[l] < 32;
					2: ok = b[l] <= l;
					3: ok = b[l] < 32 - l;
					default: ok = b[l] < 32;
					endcase
					case (sub)
					0: src = b[l] % 32;
					2: src = l - b[l] % 32;
					3: src = l + b[l] % 32;
					default: src = l ^ (b[l] % 32);
					endcase
					r[l] = ok && src >= 0 && src < 32 && ex[src % 32] ? a[src % 32] : a[l];
				end
			end
			/* Lanes outside EXEC carry X (qd reads its partners). */
			for (l = 0; l < 32; l = l + 1)
				if (!ex[l]) begin
					if (op != ATG_LANE_QD)
						a[l] = 32'bx;
					b[l] = 32'bx;
				end
		end
	endtask

	/* One group on the bus at this negedge. */
	task drive;
		input integer gg;
		begin
			x_valid = 1'b1;
			x_grp = gg;
			x_last = gg == G - 1;
			x_warp = warp;
			x_uop = 0;
			x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_LANE;
			x_uop[ATG_UOP_OP +: 8] = op;
			x_uop[ATG_UOP_SUB +: 5] = sub;
			x_uop[ATG_UOP_WRD] = 1'b1;
			x_uop[ATG_UOP_RD +: 7] = rd;
			for (l = 0; l < NPHYS; l = l + 1) begin
				x_a[l*32 +: 32] = a[gg * NPHYS + l];
				x_b[l*32 +: 32] = b[gg * NPHYS + l];
				x_mask[l] = ex[gg * NPHYS + l];
				x_mask[NPHYS + l] = ex[gg * NPHYS + l];
			end
		end
	endtask

	task expect_grp;
		input integer at;
		input integer gg;
		begin
			slot = at % 64;
			if (ev[slot]) begin
				$display("FAIL atg_su_lane.sub NPHYS %0d: two results for slot %0d", NPHYS, at);
				errs = errs + 1;
			end
			ev[slot] = 1'b1;
			erd[slot] = rd;
			ew[slot] = warp;
			eg[slot] = gg;
			for (l = 0; l < NPHYS; l = l + 1) begin
				ed[slot][l*32 +: 32] = r[gg * NPHYS + l];
				el[slot][l] = wl[gg * NPHYS + l];
			end
		end
	endtask

	initial begin
		done = 1'b0;
		errs = 0;
		for (k = 0; k < 64; k = k + 1)
			ev[k] = 1'b0;
		@(posedge go);
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		@(negedge clk);
		for (i = 0; i < N; i = i + 1) begin
			rnd_inst;
			for (g = 0; g < G; g = g + 1) begin
				drive(g);
				stall = 0;
				#1;
				while (!x_ready) begin
					if (op == ATG_LANE_QD || !x_last) begin
						$display("FAIL atg_su_lane.sub NPHYS %0d inst %0d: x_ready 0 on group %0d",
							NPHYS, i, g);
						errs = errs + 1;
					end
					@(negedge clk);
					stall = stall + 1;
					#1;
					if (stall > G + 2)
						x_ready_stuck;
				end
				if (op == ATG_LANE_QD)
					expect_grp(t + LAT, g);
				else if (x_last) begin
					if (stall != G) begin
						$display("FAIL atg_su_lane.sub NPHYS %0d inst %0d: last group held %0d cycles, want %0d",
							NPHYS, i, stall, G);
						errs = errs + 1;
					end
					for (k = 0; k < G; k = k + 1)
						expect_grp(t - (G - 1) + k + LAT, k);
				end
				@(negedge clk);
			end
			x_valid = 1'b0;
			x_uop = 0;
			if (($random(seed) & 3) == 0)
				repeat ($unsigned($random(seed)) % 3) @(negedge clk);
		end
		x_valid = 1'b0;
		repeat (LAT + G + 3) @(negedge clk);
		done = 1'b1;
	end

	task x_ready_stuck;
		begin
			$display("FAIL atg_su_lane.sub NPHYS %0d: x_ready stuck at 0", NPHYS);
			errs = errs + 1;
			done = 1'b1;
			$finish;
		end
	endtask

	/* The checker: every slot, the expected result or none. */
	integer cs, cl;
	always @(negedge clk) begin
		if (rst_n && !done) begin
			cs = t % 64;
			if (s_valid !== ev[cs]) begin
				if (errs < 8)
					$display("FAIL atg_su_lane.sub NPHYS %0d slot %0d: s_valid %b want %b",
						NPHYS, t, s_valid, ev[cs]);
				errs = errs + 1;
			end else if (ev[cs]) begin
				if (s_rd !== erd[cs] || s_warp !== ew[cs] || s_grp !== eg[cs] ||
				    s_lanes !== el[cs]) begin
					if (errs < 8)
						$display("FAIL atg_su_lane.sub NPHYS %0d slot %0d: rd %0d warp %0d grp %0d lanes %b want %0d %0d %0d %b",
							NPHYS, t, s_rd, s_warp, s_grp, s_lanes, erd[cs], ew[cs],
							eg[cs], el[cs]);
					errs = errs + 1;
				end
				for (cl = 0; cl < NPHYS; cl = cl + 1)
					if (el[cs][cl] && s_data[cl*32 +: 32] !== ed[cs][cl*32 +: 32]) begin
						if (errs < 8)
							$display("FAIL atg_su_lane.sub NPHYS %0d slot %0d lane %0d: %h want %h",
								NPHYS, t, eg[cs] * NPHYS + cl, s_data[cl*32 +: 32],
								ed[cs][cl*32 +: 32]);
						errs = errs + 1;
					end
			end
			ev[cs] = 1'b0;
		end
	end
endmodule

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

	reg go = 1'b0;
	wire [2:0] sg_done;
	wire [31:0] sg_e8, sg_e16, sg_e32;
	atg_su_lane_sgchk #(.NPHYS(8), .SEED(11)) sg8 (.clk(clk), .go(go), .done(sg_done[0]),
		.errs(sg_e8));
	atg_su_lane_sgchk #(.NPHYS(16), .SEED(12)) sg16 (.clk(clk), .go(go), .done(sg_done[1]),
		.errs(sg_e16));
	atg_su_lane_sgchk #(.NPHYS(32), .SEED(13)) sg32 (.clk(clk), .go(go), .done(sg_done[2]),
		.errs(sg_e32));

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
		go = 1'b1;
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
		if (errors == 0)
			$display("PASS atg_su_lane.qd");
		wait (&sg_done);
		if (sg_e8 + sg_e16 + sg_e32 == 0)
			$display("PASS atg_su_lane.sub");
		if (errors + sg_e8 + sg_e16 + sg_e32 == 0)
			$display("PASS atg_su_lane");
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
