/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fpu_tb: atg_su_fpu (NPHYS 8) against the vectors of
 * tools/gsi1fp.py --fpu-vec (sim/tb/su/fpu_vec.hex: op, rm, sat, a, b, c and
 * the reference result of the exact soft-float model).  One vector per
 * group, lane l gets the vector rotated by l (so every lane sees every
 * vector), a random EXEC mask; the result must come exactly SHORT_LAT
 * cycles later with the uop's rd and the mask.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_fpu_tb;
`include "atg_su_uop.vh"

	localparam NPHYS = 8;
	localparam DW = NPHYS * 32;
	localparam LAT = 6;
	localparam NV = 6000;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg x_valid = 1'b0;
	reg [UOP_W-1:0] x_uop = 0;
	reg [DW-1:0] x_a = 0, x_b = 0, x_c = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	wire x_ready, s_valid;
	wire [1:0] s_warp, s_grp;
	wire [6:0] s_rd;
	wire [DW-1:0] s_data;
	wire [NPHYS-1:0] s_lanes;
	localparam UOP_W = 104;

	atg_su_fpu #(.NPHYS(NPHYS), .SHORT_LAT(LAT)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(2'd1), .x_grp(2'd2),
		.x_last(1'b1), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
		.x_c(x_c), .x_mask(x_mask), .x_info(32'd0), .x_ready(x_ready),
		.s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp), .s_rd(s_rd), .s_data(s_data),
		.s_lanes(s_lanes)
	);

	reg [143:0] vec [0:NV-1];
	/* Expected outputs, by the cycle they were sent. */
	reg [DW-1:0] want [0:NV+LAT];
	reg [NPHYS-1:0] want_m [0:NV+LAT];
	reg [6:0] want_rd [0:NV+LAT];
	reg [4:0] want_op [0:NV+LAT];
	integer err [0:3];	/* arith, cvt, cmp, mul */
	integer seed, i, l, v, n_out;

	function integer cat;
		input [4:0] op;
		begin
			if (op <= 5'd9 || op == 5'd18 || op == 5'd19)
				cat = op >= 5'd7 && op <= 5'd9 ? 2 : (op == 5'd18 ? 1 : 0);
			else if (op <= 5'd13)
				cat = 1;
			else if (op <= 5'd17)
				cat = 2;
			else
				cat = 3;
		end
	endfunction

	/* Check on the output side. */
	integer t;
	always @(posedge clk) begin
		if (rst_n && s_valid) begin
			if (s_rd !== want_rd[n_out] || s_lanes !== want_m[n_out] || s_warp !== 2'd1 ||
			    s_grp !== 2'd2) begin
				$display("FAIL atg_su_fpu: vector %0d: rd/lanes/warp/grp", n_out);
				err[0] = err[0] + 1;
			end
			for (t = 0; t < NPHYS; t = t + 1)
				if (want_m[n_out][t] && s_data[t*32 +: 32] !== want[n_out][t*32 +: 32]) begin
					if (err[cat(want_op[n_out])] < 10)
						$display("FAIL atg_su_fpu: vector %0d lane %0d op %0d: %h want %h",
							n_out, t, want_op[n_out], s_data[t*32 +: 32],
							want[n_out][t*32 +: 32]);
					err[cat(want_op[n_out])] = err[cat(want_op[n_out])] + 1;
				end
			n_out = n_out + 1;
		end
	end

	reg [143:0] w;
	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		for (i = 0; i < 4; i = i + 1)
			err[i] = 0;
		n_out = 0;
		$readmemh("sim/tb/su/fpu_vec.hex", vec);
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		for (i = 0; i < NV; i = i + 1) begin
			@(negedge clk);
			x_valid = 1'b1;
			x_uop = 0;
			x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_FPU;
			x_uop[ATG_UOP_WRD] = 1'b1;
			x_uop[ATG_UOP_RD +: 7] = i % 63;
			x_uop[ATG_UOP_OP +: 8] = vec[i][143:136];
			x_uop[ATG_UOP_RM +: 3] = vec[i][134:132];
			x_uop[ATG_UOP_MOD + 6] = vec[i][128];
			x_mask = $random(seed);
			if (i % 7 == 0)
				x_mask[NPHYS-1:0] = {NPHYS{1'b1}};
			for (l = 0; l < NPHYS; l = l + 1) begin
				/* Lane l: a vector of the same op, rm and sat (searched
				 * forward, the group's own vector when none). */
				w = vec[i];
				for (v = 1; v < 40; v = v + 1)
					if (l != 0 && i + l * v < NV && vec[i + l * v][143:128] == vec[i][143:128] &&
					    w == vec[i])
						w = vec[i + l * v];
				x_a[l*32 +: 32] = w[127:96];
				x_b[l*32 +: 32] = w[95:64];
				x_c[l*32 +: 32] = w[63:32];
				want[i][l*32 +: 32] = w[31:0];
			end
			want_m[i] = x_mask[NPHYS-1:0];
			want_rd[i] = i % 63;
			want_op[i] = vec[i][140:136];
			if (x_ready !== 1'b1) begin
				$display("FAIL atg_su_fpu: x_ready 0");
				err[0] = err[0] + 1;
			end
		end
		@(negedge clk);
		x_valid = 1'b0;
		repeat (LAT + 3) @(posedge clk);
		if (n_out != NV) begin
			$display("FAIL atg_su_fpu: %0d results for %0d groups", n_out, NV);
			err[0] = err[0] + 1;
		end
		if (err[0] == 0) $display("PASS atg_su_fpu.arith");
		if (err[1] == 0) $display("PASS atg_su_fpu.cvt");
		if (err[2] == 0) $display("PASS atg_su_fpu.cmp");
		if (err[3] == 0) $display("PASS atg_su_fpu.mul");
		if (err[0] + err[1] + err[2] + err[3] == 0)
			$display("PASS atg_su_fpu");
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL atg_su_fpu timeout");
		$finish;
	end
endmodule

`default_nettype wire
