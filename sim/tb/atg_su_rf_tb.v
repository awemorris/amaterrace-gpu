/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_rf_tb: NPHYS 8, 16 and 32 register files (NWARPS 4, NREGS 32;
 * NPHYS 16 also with NREGS 64, NWARPS 8) against a model: random
 * lane-masked writes and three-port reads in the same cycles, then a
 * read and a write of one register in one cycle (old value).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_rf_chk #(
	parameter NPHYS = 8,
	parameter NWARPS = 4,
	parameter WARP_W = 2,
	parameter NREGS = 32,
	parameter SEED = 1
) (
	input wire clk,
	input wire go,
	output reg done,
	output reg [31:0] errs
);
	localparam G = 32 / NPHYS;
	localparam GRP_W = G > 1 ? $clog2(G) : 1;
	localparam DW = NPHYS * 32;
	reg w_en = 1'b0, r_en = 1'b0;
	reg [WARP_W-1:0] w_warp = 0, r_warp = 0;
	reg [GRP_W-1:0] w_grp = 0, r_grp = 0;
	reg [5:0] w_reg = 0, r1 = 0, r2 = 0, r3 = 0;
	reg [DW-1:0] w_data = 0;
	reg [NPHYS-1:0] w_lanes = 0;
	wire [DW-1:0] d1, d2, d3;
	reg [31:0] model [0:NWARPS*NREGS*32-1];
	reg [DW-1:0] e1, e2, e3;
	integer seed = SEED;
	integer i, l, k, phase;
	reg chk;

	atg_su_rf #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS)) dut (
		.clk(clk), .rst_n(1'b1), .w_en(w_en), .w_warp(w_warp), .w_grp(w_grp), .w_reg(w_reg),
		.w_data(w_data), .w_lanes(w_lanes), .r_en(r_en), .r_warp(r_warp), .r_grp(r_grp),
		.r_reg1(r1), .r_reg2(r2), .r_reg3(r3), .r_data1(d1), .r_data2(d2), .r_data3(d3)
	);

	function integer idx;
		input integer w, r, g, lane;
		idx = (w * NREGS + r) * 32 + g * NPHYS + lane;
	endfunction

	task expect;
		begin
			for (l = 0; l < NPHYS; l = l + 1) begin
				e1[l*32 +: 32] = model[idx(r_warp, r1, r_grp, l)];
				e2[l*32 +: 32] = model[idx(r_warp, r2, r_grp, l)];
				e3[l*32 +: 32] = model[idx(r_warp, r3, r_grp, l)];
			end
		end
	endtask

	initial begin
		done = 1'b0;
		errs = 0;
		chk = 1'b0;
		@(posedge go);
		/* Fill every register of every lane. */
		for (k = 0; k < NWARPS * NREGS * G; k = k + 1) begin
			@(negedge clk);
			w_en = 1'b1;
			w_warp = k / (NREGS * G);
			w_reg = (k / G) % NREGS;
			w_grp = k % G;
			w_lanes = {NPHYS{1'b1}};
			for (l = 0; l < NPHYS; l = l + 1) begin
				w_data[l*32 +: 32] = $random(seed);
				model[idx(w_warp, w_reg, w_grp, l)] = w_data[l*32 +: 32];
			end
		end
		@(negedge clk);
		w_en = 1'b0;
		for (phase = 0; phase < 2; phase = phase + 1) begin
			for (i = 0; i < 4000; i = i + 1) begin
				@(negedge clk);
				/* Check last cycle's read. */
				if (chk && (d1 !== e1 || d2 !== e2 || d3 !== e3)) begin
					$display("FAIL atg_su_rf.%s NPHYS %0d at %0d",
						phase ? "same" : "rw", NPHYS, i);
					errs = errs + 1;
				end
				r_en = $random(seed) & 1;
				r_warp = $unsigned($random(seed)) % NWARPS;
				r_grp = $unsigned($random(seed)) % G;
				r1 = $unsigned($random(seed)) % NREGS;
				r2 = $unsigned($random(seed)) % NREGS;
				r3 = $unsigned($random(seed)) % NREGS;
				if (r_en) begin
					expect;
					chk = 1'b1;
				end
				w_en = $random(seed) & 1;
				w_warp = phase ? r_warp : $unsigned($random(seed)) % NWARPS;
				w_grp = phase ? r_grp : $unsigned($random(seed)) % G;
				w_reg = phase ? r2 : $unsigned($random(seed)) % NREGS;
				w_lanes = $random(seed);
				for (l = 0; l < NPHYS; l = l + 1)
					w_data[l*32 +: 32] = $random(seed);
				/* The model takes the write after the read (old value). */
				if (w_en)
					for (l = 0; l < NPHYS; l = l + 1)
						if (w_lanes[l])
							model[idx(w_warp, w_reg, w_grp, l)] = w_data[l*32 +: 32];
			end
		end
		@(negedge clk);
		done = 1'b1;
	end
endmodule

module atg_su_rf_tb;
	reg clk = 1'b0;
	reg go = 1'b0;
	wire [3:0] done;
	wire [31:0] e0, e1, e2, e3;

	always #5 clk = !clk;

	atg_su_rf_chk #(.NPHYS(8), .SEED(1)) c0 (.clk(clk), .go(go), .done(done[0]), .errs(e0));
	atg_su_rf_chk #(.NPHYS(16), .SEED(2)) c1 (.clk(clk), .go(go), .done(done[1]), .errs(e1));
	atg_su_rf_chk #(.NPHYS(32), .SEED(3)) c2 (.clk(clk), .go(go), .done(done[2]), .errs(e2));
	atg_su_rf_chk #(.NPHYS(16), .NWARPS(8), .WARP_W(3), .NREGS(64), .SEED(4)) c3 (
		.clk(clk), .go(go), .done(done[3]), .errs(e3));

	initial begin
		#20 go = 1'b1;
		wait (&done);
		/* The checkers run "rw" then "same"; errors print with their name. */
		if (e0 == 0 && e1 == 0 && e2 == 0 && e3 == 0) begin
			$display("PASS atg_su_rf.rw");
			$display("PASS atg_su_rf.same");
			$display("PASS atg_su_rf");
		end
		$finish;
	end

	initial begin
		#5000000;
		$display("FAIL atg_su_rf timeout");
		$finish;
	end
endmodule

`default_nettype wire
