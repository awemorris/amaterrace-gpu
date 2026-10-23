/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_xu_tb: atg_su_xu (NPHYS 8) on the vectors of tools/gsi1fp.py
 * --xu-vec (sim/tb/su/xu_vec.hex: op, x and the model's result; one op per
 * block of 8 = one lane group).
 *   funcs: every result equals the model bit for bit, and lies within the
 *          error bounds against the real functions ($sqrt, $pow, $ln, $sin,
 *          $cos): rcp, rsq, fsqrt 1 ulp; exp2 2 ulp; log2 2 ulp or 2^-21
 *          absolute in [0.5, 2]; sin, cos 2^-20 absolute for |x| <= pi;
 *   beats: one beat per group with the group's fields, l_last = x_last,
 *          EXEC lanes only (also an empty mask), random l_ready.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_xu_tb;
`include "atg_su_uop.vh"

	localparam NPHYS = 8;
	localparam DW = NPHYS * 32;
	localparam NV = 3000;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg x_valid = 1'b0, x_last = 1'b0;
	reg [1:0] x_warp = 0, x_grp = 0;
	reg [2:0] x_sbe = 0;
	reg [103:0] x_uop = 0;
	reg [DW-1:0] x_a = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	reg l_ready = 1'b0;
	wire x_ready, l_valid, l_wr, l_last;
	wire [1:0] l_warp, l_grp;
	wire [6:0] l_rd;
	wire [DW-1:0] l_data;
	wire [NPHYS-1:0] l_lanes;
	wire [2:0] l_sbe, l_cls;

	atg_su_xu #(.NPHYS(NPHYS)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.x_last(x_last), .x_sbe(x_sbe), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a),
		.x_b({DW{1'b0}}), .x_c({DW{1'b0}}), .x_mask(x_mask), .x_info(32'd0),
		.x_ready(x_ready), .l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp),
		.l_grp(l_grp), .l_rd(l_rd), .l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr),
		.l_last(l_last), .l_sbe(l_sbe), .l_cls(l_cls)
	);

	reg [67:0] vec [0:NV-1];

	function real fval;
		input [31:0] b;
		begin
			if (b[30:23] == 8'd0)
				fval = 0.0;
			else
				fval = (8388608.0 + b[22:0]) * $pow(2.0, $itor(b[30:23]) - 150.0);
			if (b[31])
				fval = -fval;
		end
	endfunction

	/* One ulp at |v| (fp32, normal range). */
	function real ulp;
		input real v;
		real a;
		integer e;
		begin
			a = v < 0.0 ? -v : v;
			e = 0;
			if (a < 1.1754943e-38)
				ulp = 1.0e-45;
			else begin
				while (a >= 2.0) begin
					a = a / 2.0;
					e = e + 1;
				end
				while (a < 1.0) begin
					a = a * 2.0;
					e = e - 1;
				end
				ulp = $pow(2.0, $itor(e - 23));
			end
		end
	endfunction

	integer err_f, err_b, nbound;
	task bound;
		input [2:0] op;
		input [31:0] xb, yb;
		real x, y, r, d;
		reg chk;
		begin
			x = fval(xb);
			y = fval(yb);
			chk = 1'b0;
			r = 0.0;
			if (xb[30:23] != 8'hFF && xb[30:23] > 8'd2 && yb[30:23] != 8'hFF &&
			    yb[30:23] > 8'd2) begin
				chk = 1'b1;
				case (op)
				3'd0: r = 1.0 / x;
				3'd1: r = 1.0 / $sqrt(x);
				3'd2: r = $pow(2.0, x);
				3'd3: r = $ln(x) / $ln(2.0);
				3'd4: r = $sin(x);
				3'd5: r = $cos(x);
				default: r = $sqrt(x);
				endcase
			end
			if (chk && op >= 3'd4 && (x > 3.1416 || x < -3.1416))
				chk = 1'b0;
			if (chk) begin
				d = y - r;
				if (d < 0.0)
					d = -d;
				nbound = nbound + 1;
				if ((op == 3'd0 || op == 3'd1 || op == 3'd6) && d > ulp(r))
					chk = 1'b0;
				else if (op == 3'd2 && d > 2.0 * ulp(r))
					chk = 1'b0;
				else if (op == 3'd3 && d > 2.0 * ulp(r) &&
				    !(x >= 0.5 && x <= 2.0 && d <= $pow(2.0, -21.0)))
					chk = 1'b0;
				else if (op >= 3'd4 && op <= 3'd5 && d > $pow(2.0, -20.0))
					chk = 1'b0;
				if (!chk) begin
					if (err_f < 10)
						$display("FAIL atg_su_xu: bound op %0d x %h y %h (%g, want %g)",
							op, xb, yb, y, r);
					err_f = err_f + 1;
				end
			end
		end
	endtask

	integer seed, i, l, n, g;
	reg [2:0] op;
	reg [DW-1:0] want;
	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		err_f = 0;
		err_b = 0;
		nbound = 0;
		$readmemh("sim/tb/su/xu_vec.hex", vec);
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		for (g = 0; g < NV / NPHYS; g = g + 1) begin
			@(negedge clk);
			op = vec[g * NPHYS][66:64];
			x_uop = 0;
			x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_XU;
			x_uop[ATG_UOP_OP +: 8] = {5'd0, op};
			x_uop[ATG_UOP_RD +: 7] = g % 60;
			x_uop[ATG_UOP_CLS +: 3] = ATG_CLS_X;
			x_uop[ATG_UOP_WRD] = 1'b1;
			x_warp = $random(seed);
			x_grp = $random(seed);
			x_last = $random(seed);
			x_sbe = $random(seed);
			x_mask = $random(seed);
			if (g % 3 == 0)
				x_mask[NPHYS-1:0] = {NPHYS{1'b1}};
			if (g % 41 == 5)
				x_mask[NPHYS-1:0] = 0;
			for (l = 0; l < NPHYS; l = l + 1) begin
				x_a[l*32 +: 32] = vec[g * NPHYS + l][63:32];
				want[l*32 +: 32] = vec[g * NPHYS + l][31:0];
			end
			x_valid = 1'b1;
			@(posedge clk);
			while (!x_ready)
				@(posedge clk);
			@(negedge clk);
			x_valid = 1'b0;
			x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_ALU;
			n = 0;
			l_ready = ($random(seed) & 3) != 0;
			#1;
			while (!(l_valid && l_ready)) begin
				@(negedge clk);
				l_ready = ($random(seed) & 3) != 0;
				#1;
				n = n + 1;
				if (n > 20000) begin
					$display("FAIL atg_su_xu: no beat");
					$finish;
				end
			end
			if (l_rd !== g % 60 || l_lanes !== x_mask[NPHYS-1:0] || !l_wr ||
			    l_last !== x_last || l_sbe !== x_sbe || l_cls !== ATG_CLS_X ||
			    l_warp !== x_warp || l_grp !== x_grp) begin
				$display("FAIL atg_su_xu: group %0d beat fields", g);
				err_b = err_b + 1;
			end
			for (l = 0; l < NPHYS; l = l + 1)
				if (x_mask[l]) begin
					if (l_data[l*32 +: 32] !== want[l*32 +: 32]) begin
						if (err_f < 10)
							$display("FAIL atg_su_xu: op %0d x %h: %h want %h (model)", op,
								x_a[l*32 +: 32], l_data[l*32 +: 32], want[l*32 +: 32]);
						err_f = err_f + 1;
					end
					bound(op, x_a[l*32 +: 32], l_data[l*32 +: 32]);
				end
			@(negedge clk);
			l_ready = 1'b0;
		end
		if (nbound < 1000) begin
			$display("FAIL atg_su_xu: only %0d bound checks", nbound);
			err_f = err_f + 1;
		end
		if (err_f == 0) $display("PASS atg_su_xu.funcs");
		if (err_b == 0) $display("PASS atg_su_xu.beats");
		if (err_f + err_b == 0) $display("PASS atg_su_xu");
		$finish;
	end

	initial begin
		#50000000;
		$display("FAIL atg_su_xu timeout");
		$finish;
	end
endmodule

`default_nettype wire
