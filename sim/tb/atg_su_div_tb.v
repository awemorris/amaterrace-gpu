/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_div_tb: atg_su_div (NPHYS 8) on random and corner operands of
 * div/divu/rem/remu against a behavioural RISC-V reference, with random
 * EXEC masks (also empty), random l_ready, and the beat fields (rd, warp,
 * group, lanes, l_last = x_last, l_sbe, class x).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_div_tb;
`include "atg_su_uop.vh"

	localparam NPHYS = 8;
	localparam DW = NPHYS * 32;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg x_valid = 1'b0, x_last = 1'b0;
	reg [1:0] x_warp = 0, x_grp = 0;
	reg [2:0] x_sbe = 0;
	reg [103:0] x_uop = 0;
	reg [DW-1:0] x_a = 0, x_b = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	reg l_ready = 1'b0;
	wire x_ready, l_valid, l_wr, l_last;
	wire [1:0] l_warp, l_grp;
	wire [6:0] l_rd;
	wire [DW-1:0] l_data;
	wire [NPHYS-1:0] l_lanes;
	wire [2:0] l_sbe, l_cls;

	atg_su_div #(.NPHYS(NPHYS)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.x_last(x_last), .x_sbe(x_sbe), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
		.x_c({DW{1'b0}}), .x_mask(x_mask), .x_info(32'd0), .x_ready(x_ready),
		.l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp), .l_grp(l_grp), .l_rd(l_rd),
		.l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last), .l_sbe(l_sbe),
		.l_cls(l_cls)
	);

	function [31:0] ref;
		input [1:0] op;
		input [31:0] a, b;
		begin
			if (b == 0)
				ref = op[1] ? a : 32'hFFFFFFFF;
			else if (!op[0] && a == 32'h80000000 && b == 32'hFFFFFFFF)
				ref = op[1] ? 32'd0 : 32'h80000000;
			else
				case (op)
				2'd0: ref = $signed(a) / $signed(b);
				2'd1: ref = a / b;
				2'd2: ref = $signed(a) % $signed(b);
				default: ref = a % b;
				endcase
		end
	endfunction

	function [31:0] pick;
		input integer s;
		input [31:0] r;
		case (s % 8)
		0: pick = 32'd0;
		1: pick = 32'hFFFFFFFF;
		2: pick = 32'h80000000;
		3: pick = 32'h7FFFFFFF;
		4: pick = r % 17;
		5: pick = 32'd0 - (r % 9);
		default: pick = r;
		endcase
	endfunction

	integer seed, i, l, err, n, got;
	reg [DW-1:0] want;
	reg [1:0] op;
	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		err = 0;
		got = 0;
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		for (i = 0; i < 400; i = i + 1) begin
			@(negedge clk);
			op = $random(seed);
			x_uop = 0;
			x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_DIV;
			x_uop[ATG_UOP_OP +: 8] = {6'd0, op};
			x_uop[ATG_UOP_RD +: 7] = i % 60;
			x_uop[ATG_UOP_CLS +: 3] = ATG_CLS_X;
			x_uop[ATG_UOP_WRD] = 1'b1;
			x_warp = $random(seed);
			x_grp = $random(seed);
			x_last = $random(seed);
			x_sbe = $random(seed);
			x_mask = $random(seed);
			if (i % 13 == 0)
				x_mask[NPHYS-1:0] = 0;
			for (l = 0; l < NPHYS; l = l + 1) begin
				x_a[l*32 +: 32] = pick($random(seed) & 255, $random(seed));
				x_b[l*32 +: 32] = pick($random(seed) & 255, $random(seed));
				want[l*32 +: 32] = ref(op, x_a[l*32 +: 32], x_b[l*32 +: 32]);
			end
			x_valid = 1'b1;
			@(posedge clk);
			while (!x_ready)
				@(posedge clk);
			@(negedge clk);
			x_valid = 1'b0;
			x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_ALU;	/* the bus moves on */
			x_a = $random(seed);
			/* Wait for the beat, with random back-pressure. */
			n = 0;
			l_ready = ($random(seed) & 3) != 0;
			#1;
			while (!(l_valid && l_ready)) begin
				@(negedge clk);
				l_ready = ($random(seed) & 3) != 0;
				#1;
				n = n + 1;
				if (n > 1000) begin
					$display("FAIL atg_su_div: no beat");
					$finish;
				end
			end
			if (l_rd !== i % 60 || l_lanes !== x_mask[NPHYS-1:0] || !l_wr || l_last !== x_last ||
			    l_sbe !== x_sbe || l_cls !== ATG_CLS_X || l_warp !== x_warp ||
			    l_grp !== x_grp) begin
				$display("FAIL atg_su_div: group %0d beat fields", i);
				err = err + 1;
			end
			for (l = 0; l < NPHYS; l = l + 1)
				if (x_mask[l] && l_data[l*32 +: 32] !== want[l*32 +: 32]) begin
					if (err < 10)
						$display("FAIL atg_su_div: op %0d %h / %h = %h want %h", op,
							dut.ra[l*32 +: 32], dut.rb[l*32 +: 32],
							l_data[l*32 +: 32], want[l*32 +: 32]);
					err = err + 1;
				end
			got = got + 1;
			@(negedge clk);
			l_ready = 1'b0;
		end
		if (err == 0 && got == 400) begin
			$display("PASS atg_su_div.ops");
			$display("PASS atg_su_div");
		end
		$finish;
	end

	initial begin
		#5000000;
		$display("FAIL atg_su_div timeout");
		$finish;
	end
endmodule

`default_nettype wire
