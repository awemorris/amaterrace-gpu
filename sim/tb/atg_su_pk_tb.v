/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_pk_tb: atg_su_pk (NPHYS 8) with PACKED = 1 and PACKED = 0 against
 * the vectors of tools/gsi1fp.py --pk-vec (sim/tb/su/pk_vec.hex: op, rm,
 * hsel, sub, sat, a, b, c and the exact model's result).  One vector per
 * group in every lane, a random EXEC mask; the result SHORT_LAT cycles
 * later with rd and the mask.
 *   pack:  packh/unpackh/swaph on both units;
 *   arith: the packed arithmetic on the PACKED unit.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_pk_tb;
`include "atg_su_uop.vh"

	localparam NPHYS = 8;
	localparam DW = NPHYS * 32;
	localparam LAT = 6;
	localparam NV = 4000;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg x_valid = 1'b0;
	reg [103:0] x_uop = 0;
	reg [DW-1:0] x_a = 0, x_b = 0, x_c = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	wire r1, r0, v1, v0;
	wire [1:0] w1, w0, g1, g0;
	wire [6:0] rd1, rd0;
	wire [DW-1:0] d1, d0;
	wire [NPHYS-1:0] m1, m0;

	atg_su_pk #(.NPHYS(NPHYS), .SHORT_LAT(LAT), .PACKED(1)) pk1 (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(2'd2), .x_grp(2'd1),
		.x_last(1'b1), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
		.x_c(x_c), .x_mask(x_mask), .x_info(32'd0), .x_ready(r1),
		.s_valid(v1), .s_warp(w1), .s_grp(g1), .s_rd(rd1), .s_data(d1), .s_lanes(m1)
	);
	atg_su_pk #(.NPHYS(NPHYS), .SHORT_LAT(LAT), .PACKED(0)) pk0 (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(2'd2), .x_grp(2'd1),
		.x_last(1'b1), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
		.x_c(x_c), .x_mask(x_mask), .x_info(32'd0), .x_ready(r0),
		.s_valid(v0), .s_warp(w0), .s_grp(g0), .s_rd(rd0), .s_data(d0), .s_lanes(m0)
	);

	reg [147:0] vec [0:NV-1];
	reg [31:0] want [0:NV-1];
	reg [NPHYS-1:0] want_m [0:NV-1];
	reg [3:0] want_op [0:NV-1];
	integer err_p, err_a, seed, i, l, n_out, t;

	always @(posedge clk) begin
		if (rst_n && v1) begin
			if (!v0 || rd1 !== n_out % 63 || m1 !== want_m[n_out] || w1 !== 2'd2 ||
			    g1 !== 2'd1 || rd0 !== rd1 || m0 !== m1) begin
				$display("FAIL atg_su_pk: vector %0d fields", n_out);
				err_p = err_p + 1;
			end
			for (t = 0; t < NPHYS; t = t + 1)
				if (want_m[n_out][t]) begin
					if (d1[t*32 +: 32] !== want[n_out]) begin
						if (err_p + err_a < 10)
							$display("FAIL atg_su_pk: vector %0d op %0d: %h want %h", n_out,
								want_op[n_out], d1[t*32 +: 32], want[n_out]);
						if (want_op[n_out] >= 4'd13)
							err_p = err_p + 1;
						else
							err_a = err_a + 1;
					end
					if (want_op[n_out] >= 4'd13 && d0[t*32 +: 32] !== want[n_out]) begin
						$display("FAIL atg_su_pk: PACKED 0 vector %0d op %0d", n_out,
							want_op[n_out]);
						err_p = err_p + 1;
					end
				end
			n_out = n_out + 1;
		end
	end

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		err_p = 0;
		err_a = 0;
		n_out = 0;
		$readmemh("sim/tb/su/pk_vec.hex", vec);
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		for (i = 0; i < NV; i = i + 1) begin
			@(negedge clk);
			x_valid = 1'b1;
			x_uop = 0;
			x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_PK;
			x_uop[ATG_UOP_WRD] = 1'b1;
			x_uop[ATG_UOP_RD +: 7] = i % 63;
			x_uop[ATG_UOP_OP +: 8] = vec[i][147:144];
			x_uop[ATG_UOP_RM +: 3] = vec[i][142:140];
			x_uop[ATG_UOP_HSEL +: 2] = vec[i][137:136];
			x_uop[ATG_UOP_SUB +: 5] = vec[i][132];
			x_uop[ATG_UOP_MOD + 6] = vec[i][128];
			x_mask = $random(seed);
			for (l = 0; l < NPHYS; l = l + 1) begin
				x_a[l*32 +: 32] = vec[i][127:96];
				x_b[l*32 +: 32] = vec[i][95:64];
				x_c[l*32 +: 32] = vec[i][63:32];
			end
			want[i] = vec[i][31:0];
			want_m[i] = x_mask[NPHYS-1:0];
			want_op[i] = vec[i][147:144];
			if (!r1 || !r0) begin
				$display("FAIL atg_su_pk: x_ready 0");
				err_p = err_p + 1;
			end
		end
		@(negedge clk);
		x_valid = 1'b0;
		repeat (LAT + 3) @(posedge clk);
		if (n_out != NV) begin
			$display("FAIL atg_su_pk: %0d results for %0d groups", n_out, NV);
			err_p = err_p + 1;
		end
		if (err_p == 0) $display("PASS atg_su_pk.pack");
		if (err_a == 0) $display("PASS atg_su_pk.arith");
		if (err_p + err_a == 0) $display("PASS atg_su_pk");
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL atg_su_pk timeout");
		$finish;
	end
endmodule

`default_nettype wire
