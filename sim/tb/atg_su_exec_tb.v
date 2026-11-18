/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_exec_tb: EXEC, KILLED and warp control (NPHYS 8, 4 groups).  The
 * TB drives the groups of each instruction as atg_su_opd does (x_mask
 * from q_exec).  branch: the six branches on random Booleans and random
 * EXEC (also EXEC = 0) against a reference, target pc + offset or pc + 1;
 * exec: exec.set/and/or and kill update the masks, exec.save writes each
 * lane's EXEC bit as a Boolean to all lanes SHORT_LAT cycles later;
 * endbar: end and bar give wc_op 1 and 2.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_exec_tb;
`include "atg_su_uop.vh"
	localparam NPHYS = 8;
	localparam G = 4;
	localparam DW = NPHYS * 32;
	localparam LAT = 6;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg x_valid = 0, x_last = 0;
	reg [1:0] x_warp = 0, x_grp = 0;
	reg [15:0] x_pc = 0;
	reg [ATG_UOP_W-1:0] x_uop = 0;
	reg [DW-1:0] x_a = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	wire x_ready, s_valid, wc_valid;
	wire [1:0] s_warp, s_grp, wc_warp, wc_op;
	wire [6:0] s_rd;
	wire [DW-1:0] s_data;
	wire [NPHYS-1:0] s_lanes;
	wire [15:0] wc_pc;
	reg [1:0] q_warp = 0;
	wire [31:0] q_exec, q_killed;
	reg init_valid = 0;
	reg [1:0] init_warp = 0;
	reg [31:0] init_mask = 0;
	integer seed = 1;
	integer errors = 0, ec, i, g, l;

	always #5 clk = !clk;

	atg_su_exec #(.NPHYS(NPHYS), .SHORT_LAT(LAT)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.x_last(x_last), .x_sbe(3'd7), .x_pc(x_pc), .x_uop(x_uop), .x_a(x_a),
		.x_b({DW{1'b0}}), .x_c({DW{1'b0}}), .x_mask(x_mask), .x_info(32'd0),
		.x_ready(x_ready), .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp), .s_rd(s_rd),
		.s_data(s_data), .s_lanes(s_lanes), .wc_valid(wc_valid), .wc_warp(wc_warp),
		.wc_op(wc_op), .wc_pc(wc_pc), .q_warp(q_warp), .q_exec(q_exec),
		.q_killed(q_killed), .init_valid(init_valid), .init_warp(init_warp),
		.init_mask(init_mask)
	);

	task fail;
		input [8*40-1:0] what;
		begin
			$display("FAIL atg_su_exec.%0s", what);
			errors = errors + 1;
		end
	endtask

	task init;
		input [1:0] w;
		input [31:0] m;
		begin
			@(negedge clk);
			init_valid = 1'b1;
			init_warp = w;
			init_mask = m;
			@(negedge clk);
			init_valid = 1'b0;
		end
	endtask

	/* Run one instruction of warp w with rs1 = the Booleans in b (per lane). */
	task run;
		input [1:0] w;
		input [7:0] op;
		input [31:0] b;
		input [15:0] pc;
		input [31:0] imm;
		begin
			q_warp = w;
			for (g = 0; g < G; g = g + 1) begin
				@(negedge clk);
				x_valid = 1'b1;
				x_warp = w;
				x_grp = g;
				x_last = g == G - 1;
				x_pc = pc;
				x_uop = 0;
				x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_EXEC;
				x_uop[ATG_UOP_OP +: 8] = op;
				x_uop[ATG_UOP_IMM +: 32] = imm;
				x_uop[ATG_UOP_RD +: 7] = 7'd9;
				x_uop[ATG_UOP_WRD] = op == ATG_EXEC_SAVE;
				#1;
				x_mask = {NPHYS{1'b0}} | (q_exec >> (g * NPHYS));
				for (l = 0; l < NPHYS; l = l + 1)
					x_a[l*32 +: 32] = b[g * NPHYS + l] ? $random(seed) | 1 : 32'd0;
			end
			@(negedge clk);
			x_valid = 1'b0;
		end
	endtask

	reg [31:0] e, b;
	reg [7:0] op;
	reg tk;
	reg [15:0] want_pc;
	initial begin
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		/* branch */
		ec = errors;
		for (i = 0; i < 300; i = i + 1) begin
			e = ($random(seed) & 7) == 0 ? 32'd0 : $random(seed);
			b = ($random(seed) & 3) == 0 ? e : ($random(seed) & 3) == 0 ? 32'd0 : $random(seed);
			op = $unsigned($random(seed)) % 6;
			init(i % 4, e);
			case (op)
			ATG_EXEC_BANY: tk = (b & e) != 0;
			ATG_EXEC_BNONE: tk = (b & e) == 0;
			ATG_EXEC_BALL: tk = (~b & e) == 0;
			ATG_EXEC_J: tk = 1;
			ATG_EXEC_BEXNZ: tk = e != 0;
			default: tk = e == 0;
			endcase
			want_pc = tk ? 16'd100 - 16'd7 : 16'd101;
			run(i % 4, op, b, 16'd100, -32'sd7);
			#1;
			if (!wc_valid || wc_warp !== i % 4 || wc_op !== 2'd0 || wc_pc !== want_pc)
				fail("branch");
			@(negedge clk);
			#1;
			if (wc_valid)
				fail("branch pulse");
		end
		if (errors == ec)
			$display("PASS atg_su_exec.branch");
		/* exec */
		ec = errors;
		init(1, 32'hFFFF0000);
		run(1, ATG_EXEC_AND, 32'h0F0F0F0F, 0, 0);
		q_warp = 1;
		#1;
		if (q_exec !== 32'h0F0F0000)
			fail("exec.and");
		run(1, ATG_EXEC_OR, 32'h000000F0, 0, 0);
		#1;
		if (q_exec !== 32'h0F0F00F0)
			fail("exec.or");
		run(1, ATG_EXEC_KILL, 32'hFFFF00FF, 0, 0);
		#1;
		if (q_killed !== 32'h0F0F00F0)
			fail("kill");
		run(1, ATG_EXEC_KILL, 32'h00000100, 0, 0);
		#1;
		if (q_killed !== 32'h0F0F00F0)
			fail("kill outside EXEC");
		/* exec.save: groups come back SHORT_LAT cycles after each x_valid. */
		fork
			run(1, ATG_EXEC_SAVE, 0, 0, 0);
			begin
				repeat (LAT + 1) @(negedge clk);
				for (g = 0; g < G; g = g + 1) begin
					#1;
					if (!s_valid || s_grp !== g || s_rd !== 7'd9 || s_lanes !== 8'hFF)
						fail("exec.save result");
					for (l = 0; l < NPHYS; l = l + 1)
						if (s_data[l*32 +: 32] !== (q_exec[g * NPHYS + l] ? 32'hFFFFFFFF : 0))
							fail("exec.save data");
					@(negedge clk);
				end
			end
		join
		run(1, ATG_EXEC_SET, 32'h12345678, 0, 0);
		#1;
		if (q_exec !== 32'h12345678 || q_killed !== 32'h0F0F00F0)
			fail("exec.set");
		init(1, 32'hFFFFFFFF);
		#1;
		if (q_killed !== 0)
			fail("init clears KILLED");
		if (errors == ec)
			$display("PASS atg_su_exec.exec");
		/* endbar */
		ec = errors;
		run(2, ATG_EXEC_BAR, 0, 16'd40, 0);
		#1;
		if (!wc_valid || wc_op !== 2'd2 || wc_pc !== 16'd41 || wc_warp !== 2'd2)
			fail("bar");
		run(3, ATG_EXEC_END, 0, 16'd50, 0);
		#1;
		if (!wc_valid || wc_op !== 2'd1 || wc_warp !== 2'd3)
			fail("end");
		if (errors == ec)
			$display("PASS atg_su_exec.endbar");
		if (errors == 0)
			$display("PASS atg_su_exec");
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL atg_su_exec timeout");
		$finish;
	end
endmodule

`default_nettype wire
