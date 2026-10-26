/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_lds_tb: atg_su_lds (NPHYS 8, 4 KiB) against a shadow array.
 *   rw:   random sts then lds over the whole RAM (addresses wrap at
 *         LDS_BYTES; duplicate addresses in a group: the higher lane wins);
 *   mask: sts writes only the side-effect lanes, lds returns the EXEC lanes;
 *         empty masks give an immediate beat; beat fields and l_wr;
 *   atom: atoms (every operation, cmpxchg with equal and unequal compare
 *         values) of the side-effect lanes in lane order on few words (many
 *         lanes on one word), the old values returned (l_wr = WRD), the RAM
 *         afterwards, mixed with sts and lds.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_lds_tb;
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
	reg [DW-1:0] x_a = 0, x_b = 0, x_c = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	reg l_ready = 1'b0;
	wire x_ready, l_valid, l_wr, l_last;
	wire [1:0] l_warp, l_grp;
	wire [6:0] l_rd;
	wire [DW-1:0] l_data;
	wire [NPHYS-1:0] l_lanes;
	wire [2:0] l_sbe, l_cls;

	atg_su_lds #(.NPHYS(NPHYS)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.scrub(1'b0), .scrub_busy(),
		.x_last(x_last), .x_sbe(x_sbe), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
		.x_c(x_c), .x_mask(x_mask), .x_info(32'd0), .x_ready(x_ready),
		.l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp), .l_grp(l_grp), .l_rd(l_rd),
		.l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last), .l_sbe(l_sbe),
		.l_cls(l_cls),
		.mesh_rd_en(1'b0), .mesh_rd_addr(10'd0), .mesh_rd_data()
	);

	reg [31:0] shadow [0:1023];
	reg [1023:0] known;
	integer seed, i, l, n, err_rw, err_m, err_a;
	reg [31:0] imm;
	reg [DW-1:0] want;

	/* kind 0 lds, 1 sts, 2 atom (operation aop, rd written when awrd). */
	reg [1:0] kind;
	reg [3:0] aop;
	reg awrd;
	task go;
		input [1:0] k;
		begin
			kind = k;
			@(negedge clk);
			x_uop = 0;
			x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_LDS;
			x_uop[ATG_UOP_OP +: 8] = k == 2'd2 ? ATG_LDS_ATOM : k == 2'd1 ? ATG_LDS_STS :
				ATG_LDS_LDS;
			/* atom has no immediate: a stray value in the field must not move it. */
			x_uop[ATG_UOP_IMM +: 32] = k == 2'd2 ? 32'h40 : imm;
			x_uop[ATG_UOP_SUB +: 5] = {k == 2'd2, aop};
			x_uop[ATG_UOP_RD +: 7] = i % 60;
			x_uop[ATG_UOP_WRD] = k == 2'd2 ? awrd : k == 2'd0;
			x_warp = $random(seed);
			x_grp = $random(seed);
			x_last = $random(seed);
			x_sbe = $random(seed);
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
				if (n > 1000) begin
					$display("FAIL atg_su_lds: no beat");
					$finish;
				end
			end
			if (l_rd !== i % 60 || l_last !== x_last || l_sbe !== x_sbe ||
			    l_cls !== ATG_CLS_M || l_warp !== x_warp || l_grp !== x_grp ||
			    l_wr !== (kind == 2'd2 ? awrd : kind == 2'd0) ||
			    l_lanes !== (kind != 2'd0 ? x_mask[2*NPHYS-1:NPHYS] : x_mask[NPHYS-1:0])) begin
				$display("FAIL atg_su_lds: group %0d beat fields", i);
				err_m = err_m + 1;
			end
			@(negedge clk);
			l_ready = 1'b0;
		end
	endtask

	/* The reference of an atomic's new value (docs/ghci.md section 12.5). */
	function [31:0] atom_ref;
		input [3:0] op;
		input [31:0] old, a, b;
		case (op)
		4'd0: atom_ref = old & a;
		4'd1: atom_ref = old | a;
		4'd2: atom_ref = old ^ a;
		4'd3: atom_ref = a;
		4'd4: atom_ref = old + a;
		4'd5: atom_ref = old - a;
		4'd6: atom_ref = $signed(old) > $signed(a) ? old : a;
		4'd7: atom_ref = $signed(old) < $signed(a) ? old : a;
		4'd8: atom_ref = old > a ? old : a;
		4'd9: atom_ref = old < a ? old : a;
		default: atom_ref = old == b ? a : old;
		endcase
	endfunction

	reg [31:0] ad;
	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		err_rw = 0;
		err_m = 0;
		err_a = 0;
		known = 0;
		aop = 0;
		awrd = 0;
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		for (i = 0; i < 1200; i = i + 1) begin
			imm = ($random(seed) % 64) * 4;
			x_mask = $random(seed);
			if (i % 50 == 0)
				x_mask = 0;
			for (l = 0; l < NPHYS; l = l + 1) begin
				x_a[l*32 +: 32] = i % 5 == 0 ? $random(seed) & 32'hFFFFFFFC :
					($unsigned($random(seed)) % (i % 3 == 0 ? 16 : 1100)) * 4;
				x_b[l*32 +: 32] = $random(seed);
			end
			if (i < 600 || $random(seed) & 1) begin
				for (l = 0; l < NPHYS; l = l + 1)
					if (x_mask[NPHYS + l]) begin
						ad = ((x_a[l*32 +: 32] + imm) >> 2) % 1024;
						shadow[ad] = x_b[l*32 +: 32];
						known[ad] = 1'b1;
					end
				go(2'd1);
			end else begin
				go(2'd0);
				for (l = 0; l < NPHYS; l = l + 1) begin
					ad = ((x_a[l*32 +: 32] + imm) >> 2) % 1024;
					if (x_mask[l] && known[ad] && l_data[l*32 +: 32] !== shadow[ad]) begin
						if (err_rw < 10)
							$display("FAIL atg_su_lds: lds %0d lane %0d word %0d %h want %h", i,
								l, ad, l_data[l*32 +: 32], shadow[ad]);
						err_rw = err_rw + 1;
					end
				end
			end
		end
		/* Every word written so far reads back. */
		for (i = 0; i < 1024; i = i + 1)
			if (known[i] && dut.ram[i] !== shadow[i]) begin
				if (err_m < 10)
					$display("FAIL atg_su_lds: word %0d %h want %h", i, dut.ram[i], shadow[i]);
				err_m = err_m + 1;
			end
		/* atom: first every word known (sts of whole groups), then atomics on
		 * eight words (or the whole RAM), with sts and lds between. */
		x_mask = {2*NPHYS{1'b1}};
		imm = 0;
		for (i = 0; i < 1024 / NPHYS; i = i + 1) begin
			for (l = 0; l < NPHYS; l = l + 1) begin
				x_a[l*32 +: 32] = (i * NPHYS + l) * 4;
				x_b[l*32 +: 32] = $random(seed);
				shadow[i * NPHYS + l] = x_b[l*32 +: 32];
			end
			go(2'd1);
		end
		for (i = 0; i < 1500; i = i + 1) begin
			x_mask = $random(seed);
			if (i % 40 == 0)
				x_mask = 0;
			aop = $unsigned($random(seed)) % 11;
			awrd = ($random(seed) & 7) != 0;
			imm = ($random(seed) % 8) * 4;
			for (l = 0; l < NPHYS; l = l + 1) begin
				/* Small values and few words: the operations and the order matter. */
				x_a[l*32 +: 32] = i % 7 == 0 ? $random(seed) & 32'hFFFFFFFC :
					(($unsigned($random(seed)) % 8) * 4) | (i % 3 == 0 ? 32'h1000 : 0);
				x_b[l*32 +: 32] = i % 2 ? $random(seed) : $random(seed) % 5;
				x_c[l*32 +: 32] = $random(seed) % 5;
			end
			n = $unsigned($random(seed)) % 4;
			if (n == 0) begin
				for (l = 0; l < NPHYS; l = l + 1)
					if (x_mask[NPHYS + l]) begin
						ad = ((x_a[l*32 +: 32] + imm) >> 2) % 1024;
						shadow[ad] = x_b[l*32 +: 32];
					end
				go(2'd1);
			end else if (n == 1) begin
				go(2'd0);
				for (l = 0; l < NPHYS; l = l + 1) begin
					ad = ((x_a[l*32 +: 32] + imm) >> 2) % 1024;
					if (x_mask[l] && l_data[l*32 +: 32] !== shadow[ad]) begin
						if (err_a < 10)
							$display("FAIL atg_su_lds: lds %0d lane %0d word %0d %h want %h",
								i, l, ad, l_data[l*32 +: 32], shadow[ad]);
						err_a = err_a + 1;
					end
				end
			end else begin
				for (l = 0; l < NPHYS; l = l + 1)
					if (x_mask[NPHYS + l]) begin
						ad = (x_a[l*32 +: 32] >> 2) % 1024;
						want[l*32 +: 32] = shadow[ad];
						shadow[ad] = atom_ref(aop, shadow[ad], x_b[l*32 +: 32],
							x_c[l*32 +: 32]);
					end
				go(2'd2);
				for (l = 0; l < NPHYS; l = l + 1)
					if (awrd && x_mask[NPHYS + l] &&
					    l_data[l*32 +: 32] !== want[l*32 +: 32]) begin
						if (err_a < 10)
							$display("FAIL atg_su_lds: atom %0d op %0d lane %0d %h want %h",
								i, aop, l, l_data[l*32 +: 32], want[l*32 +: 32]);
						err_a = err_a + 1;
					end
			end
		end
		for (i = 0; i < 1024; i = i + 1)
			if (dut.ram[i] !== shadow[i]) begin
				if (err_a < 10)
					$display("FAIL atg_su_lds: atom: word %0d %h want %h", i, dut.ram[i],
						shadow[i]);
				err_a = err_a + 1;
			end
		if (err_rw == 0) $display("PASS atg_su_lds.rw");
		if (err_m == 0) $display("PASS atg_su_lds.mask");
		if (err_a == 0) $display("PASS atg_su_lds.atom");
		if (err_rw + err_m + err_a == 0) $display("PASS atg_su_lds");
		$finish;
	end

	initial begin
		#10000000;
		$display("FAIL atg_su_lds timeout");
		$finish;
	end
endmodule

`default_nettype wire
