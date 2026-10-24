/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_dec_tb: the decode vectors of tools/gsi1asm.py --dec-table
 * (sim/tb/su/dec_table.hex: instruction, uop with NREGS 32 / PACKED 0 /
 * SUBGROUP 0 / HAS_SA 0, uop with NREGS 64 / PACKED 1 / SUBGROUP 1 /
 * HAS_SA 1 / MS4 1) through two decoders, plus the valid/ready register;
 * texszs: texsz.s (immediate 3) faults without MS4 and is TEXSZ 0x4B with it.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_dec_tb;
`include "atg_su_uop.vh"
	localparam NV = 5480;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg d_valid = 1'b0;
	reg [1:0] d_warp = 2'd0;
	reg [15:0] d_pc = 16'd0;
	reg [63:0] d_instr = 64'd0;
	reg u_ready = 1'b1;
	wire d_ready_a, d_ready_b, u_valid_a, u_valid_b;
	wire [1:0] u_warp_a, u_warp_b;
	wire [15:0] u_pc_a, u_pc_b;
	wire [ATG_UOP_W-1:0] u_uop_a, u_uop_b;
	reg [271:0] vec [0:NV-1];
	integer errors = 0, e0 = 0;
	integer i, n_op, n_fault, n_legal;
	integer seed = 1;

	always #5 clk = !clk;

	atg_su_dec dut_a (
		.clk(clk), .rst_n(rst_n), .d_valid(d_valid), .d_ready(d_ready_a), .d_warp(d_warp),
		.d_pc(d_pc), .d_instr(d_instr), .u_valid(u_valid_a), .u_ready(u_ready),
		.u_warp(u_warp_a), .u_pc(u_pc_a), .u_uop(u_uop_a)
	);
	atg_su_dec #(.NREGS(64), .PACKED(1), .SUBGROUP(1), .HAS_SA(1), .MS4(1)) dut_b (
		.clk(clk), .rst_n(rst_n), .d_valid(d_valid), .d_ready(d_ready_b), .d_warp(d_warp),
		.d_pc(d_pc), .d_instr(d_instr), .u_valid(u_valid_b), .u_ready(u_ready),
		.u_warp(u_warp_b), .u_pc(u_pc_b), .u_uop(u_uop_b)
	);

	/* One instruction through both decoders; compare the uops. */
	task one;
		input [63:0] w;
		input [ATG_UOP_W-1:0] want_a, want_b;
		input integer kind;
		begin
			@(negedge clk);
			d_valid = 1'b1;
			d_instr = w;
			d_pc = $random(seed);
			d_warp = $random(seed);
			@(negedge clk);
			d_valid = 1'b0;
			if (!u_valid_a || !u_valid_b || u_pc_a !== d_pc || u_warp_a !== d_warp) begin
				$display("FAIL atg_su_dec.handshake w=%h", w);
				errors = errors + 1;
			end
			if (u_uop_a !== want_a || u_uop_b !== want_b) begin
				$display("FAIL atg_su_dec.%s w=%h a=%h want %h b=%h want %h",
					kind == 0 ? "table" : "operands", w, u_uop_a, want_a, u_uop_b,
					want_b);
				errors = errors + 1;
			end
		end
	endtask

	initial begin
		$readmemh("sim/tb/su/dec_table.hex", vec);
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		n_fault = 0;
		n_legal = 0;
		/* The table: every entry of gsi1asm.py's table with random fields. */
		n_op = 0;
		for (i = 0; i < NV - 2000; i = i + 1) begin
			one(vec[i][271:208], vec[i][207:104], vec[i][103:0], 0);
			n_op = n_op + 1;
			if (vec[i][104 + ATG_UOP_ILL])
				n_fault = n_fault + 1;
			else
				n_legal = n_legal + 1;
		end
		if (errors == 0)
			$display("PASS atg_su_dec.table");
		/* Random 64-bit words (7-bit operands, immediates, word1 fields). */
		for (i = NV - 2000; i < NV; i = i + 1)
			one(vec[i][271:208], vec[i][207:104], vec[i][103:0], 1);
		if (errors == 0)
			$display("PASS atg_su_dec.operands");
		/* Faults: compressed forms, registers >= NREGS, the optional sets. */
		one({32'd0, 32'h00000010}, 104'd1 << ATG_UOP_ILL, 104'd1 << ATG_UOP_ILL, 2);
		/* add r1, r40, r2: rs1 = 40 is beyond NREGS 32 only. */
		if (1) begin
			@(negedge clk);
			d_valid = 1'b1;
			d_instr = {32'h00000004, 32'h002400b3};
			@(negedge clk);
			d_valid = 1'b0;
			if (!u_uop_a[ATG_UOP_ILL] || u_uop_b[ATG_UOP_ILL]) begin
				$display("FAIL atg_su_dec.fault nregs a=%h b=%h", u_uop_a, u_uop_b);
				errors = errors + 1;
			end
		end
		/* fadd2 r1, r2, r3 (PACKED), vote.any r1, r2 (SUBGROUP), sactl r1 (HAS_SA). */
		for (i = 0; i < 3; i = i + 1) begin
			@(negedge clk);
			d_valid = 1'b1;
			d_instr = i == 0 ? {32'd0, 32'h003100db} : i == 1 ? {32'd0, 32'h000140fb} :
				{32'd0, 32'h0000e07b};
			@(negedge clk);
			d_valid = 1'b0;
			if (!u_uop_a[ATG_UOP_ILL] || u_uop_b[ATG_UOP_ILL]) begin
				$display("FAIL atg_su_dec.fault option %0d a=%h b=%h", i, u_uop_a,
					u_uop_b);
				errors = errors + 1;
			end
		end
		/* Back-pressure: u_ready 0 holds the register and d_ready falls. */
		@(negedge clk);
		u_ready = 1'b0;
		d_valid = 1'b1;
		d_instr = {32'd0, 32'h00000013};
		@(negedge clk);
		d_instr = {32'd0, 32'h00100093};
		@(negedge clk);
		if (d_ready_a || u_uop_a[ATG_UOP_IMM +: 32] !== 32'd0) begin
			$display("FAIL atg_su_dec.fault back-pressure");
			errors = errors + 1;
		end
		u_ready = 1'b1;
		@(negedge clk);
		d_valid = 1'b0;
		if (u_uop_a[ATG_UOP_IMM +: 32] !== 32'd1) begin
			$display("FAIL atg_su_dec.fault back-pressure release");
			errors = errors + 1;
		end
		if (errors == 0)
			$display("PASS atg_su_dec.fault");
		/* texsz.s r5, 3: an ISA fault without MS4, op 0x4B (no rs1) with it. */
		e0 = errors;
		@(negedge clk);
		d_valid = 1'b1;
		d_instr = {32'h00060000, 32'h003032ab};
		@(negedge clk);
		d_valid = 1'b0;
		if (!u_uop_a[ATG_UOP_ILL] || u_uop_b[ATG_UOP_ILL] || u_uop_b[ATG_UOP_OP +: 8] !== 8'h4B ||
		    u_uop_b[ATG_UOP_UNIT +: 4] !== ATG_UNIT_TEX || u_uop_b[ATG_UOP_USE1]) begin
			$display("FAIL atg_su_dec.texszs a=%h b=%h", u_uop_a, u_uop_b);
			errors = errors + 1;
		end
		if (errors == e0)
			$display("PASS atg_su_dec.texszs");
		$display("atg_su_dec: %0d table vectors (%0d legal, %0d faults)", n_op, n_legal,
			n_fault);
		if (errors == 0)
			$display("PASS atg_su_dec");
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL atg_su_dec timeout");
		$finish;
	end
endmodule

`default_nettype wire
