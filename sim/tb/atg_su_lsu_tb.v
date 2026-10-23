/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_lsu_tb: atg_su_lsu (NPHYS 8, 32-byte lines) with amb_mem on its
 * D$ port (no cache: every request reaches the model) and a behavioural
 * atomic unit on at_* that applies the operation to the same memory.
 *   coalesce: random lane addresses in a few lines: one request per
 *             distinct line, every lane gets its word;
 *   store:    byte enables of the side-effect lanes reach memory, the
 *             beat (l_wr 0) comes after the last write response;
 *   atom:     every op of the 11 against a model, old values returned;
 *   empty:    an empty lane mask gives a beat without any request.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_lsu_tb;
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
	wire dc_req_valid, dc_req_ready, dc_req_write, dc_rsp_valid, dc_rsp_write, dc_rsp_error;
	wire [26:0] dc_req_line;
	wire [31:0] dc_req_be;
	wire [255:0] dc_req_wdata, dc_rsp_rdata;
	wire [7:0] dc_req_tag, dc_rsp_tag;
	wire at_valid, dc_inv;
	reg at_ready = 1'b0, at_rsp_valid = 1'b0, at_error = 1'b0;
	wire [3:0] at_op;
	wire [29:0] at_addr;
	wire [31:0] at_a, at_b;
	reg [31:0] at_old = 0;

	atg_su_lsu #(.NPHYS(NPHYS)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.x_last(x_last), .x_sbe(x_sbe), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
		.x_c(x_c), .x_mask(x_mask), .x_info(32'd0), .x_ready(x_ready),
		.l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp), .l_grp(l_grp), .l_rd(l_rd),
		.l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last), .l_sbe(l_sbe),
		.l_cls(l_cls),
		.dc_req_valid(dc_req_valid), .dc_req_ready(dc_req_ready), .dc_req_write(dc_req_write),
		.dc_req_line(dc_req_line), .dc_req_be(dc_req_be), .dc_req_wdata(dc_req_wdata),
		.dc_req_tag(dc_req_tag), .dc_rsp_valid(dc_rsp_valid), .dc_rsp_write(dc_rsp_write),
		.dc_rsp_tag(dc_rsp_tag), .dc_rsp_rdata(dc_rsp_rdata), .dc_rsp_error(dc_rsp_error),
		.at_valid(at_valid), .at_ready(at_ready), .at_op(at_op), .at_addr(at_addr),
		.at_a(at_a), .at_b(at_b), .at_rsp_valid(at_rsp_valid), .at_old(at_old),
		.at_error(at_error), .dc_inv(dc_inv)
	);
	amb_mem #(.MEM_WORDS(1024)) mem (
		.clk(clk), .rst_n(rst_n), .req_valid(dc_req_valid), .req_ready(dc_req_ready),
		.req_write(dc_req_write), .req_line(dc_req_line), .req_be(dc_req_be),
		.req_wdata(dc_req_wdata), .req_tag(dc_req_tag), .rsp_valid(dc_rsp_valid),
		.rsp_write(dc_rsp_write), .rsp_tag(dc_rsp_tag), .rsp_rdata(dc_rsp_rdata),
		.rsp_error(dc_rsp_error)
	);

	integer reqs, wrsp, invs;
	always @(posedge clk) begin
		if (dc_req_valid && dc_req_ready)
			reqs = reqs + 1;
		if (dc_rsp_valid && dc_rsp_write)
			wrsp = wrsp + 1;
		if (dc_inv)
			invs = invs + 1;
	end

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

	/* The atomic unit: random ready, the old value 2-5 cycles later. */
	integer seed, d;
	reg [31:0] old;
	always @(posedge clk) begin
		if (at_valid && at_ready) begin
			old = mem.peek({at_addr, 2'b00});
			mem.poke({at_addr, 2'b00}, atom_ref(at_op, old, at_a, at_b));
			at_ready <= 1'b0;
			for (d = 0; d < 2 + ($unsigned($random(seed)) % 4); d = d + 1)
				@(posedge clk);
			at_old <= old;
			at_rsp_valid <= 1'b1;
			@(posedge clk);
			at_rsp_valid <= 1'b0;
		end else
			at_ready <= ($random(seed) & 1) != 0;
	end

	reg [31:0] shadow [0:1023];
	integer i, l, n, err_c, err_s, err_a, err_e, lines, k;
	reg [DW-1:0] want;
	reg [26:0] seen [0:NPHYS-1];
	reg dup;

	task send;
		input [7:0] op;
		input [31:0] imm;
		begin
			@(negedge clk);
			x_uop = 0;
			x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_LSU;
			x_uop[ATG_UOP_OP +: 8] = op;
			x_uop[ATG_UOP_IMM +: 32] = imm;
			x_uop[ATG_UOP_CLS +: 3] = ATG_CLS_M;
			x_uop[ATG_UOP_RD +: 7] = i % 60;
			x_uop[ATG_UOP_WRD] = op != ATG_LSU_SW;
			x_uop[ATG_UOP_SUB +: 5] = $unsigned($random(seed)) % 11;
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
		end
	endtask

	task beat;
		output integer e;
		begin
			e = 0;
			n = 0;
			l_ready = ($random(seed) & 3) != 0;
			#1;
			while (!(l_valid && l_ready)) begin
				@(negedge clk);
				l_ready = ($random(seed) & 3) != 0;
				#1;
				n = n + 1;
				if (n > 2000) begin
					$display("FAIL atg_su_lsu: no beat");
					$finish;
				end
			end
			if (l_rd !== i % 60 || l_last !== x_last || l_sbe !== x_sbe ||
			    l_cls !== ATG_CLS_M || l_warp !== x_warp || l_grp !== x_grp)
				e = 1;
			@(negedge clk);
			l_ready = 1'b0;
		end
	endtask

	integer e;
	reg [3:0] aop;
	reg [31:0] imm;
	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		err_c = 0;
		err_s = 0;
		err_a = 0;
		err_e = 0;
		reqs = 0;
		wrsp = 0;
		invs = 0;
		for (i = 0; i < 1024; i = i + 1) begin
			shadow[i] = $random(seed);
			mem.poke(4 * i, shadow[i]);
		end
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		/* coalesce */
		for (i = 0; i < 300; i = i + 1) begin
			imm = ($unsigned($random(seed)) % 16) * 4 - 32;
			x_mask = $random(seed);
			lines = 0;
			for (l = 0; l < NPHYS; l = l + 1) begin
				x_a[l*32 +: 32] = 32'h100 + ($unsigned($random(seed)) % (i % 4 == 0 ? 8 : 96)) * 4 + {$random(seed)} % 4 * 0;
				if (x_mask[l]) begin
					want[l*32 +: 32] = shadow[(x_a[l*32 +: 32] + imm) / 4];
					dup = 1'b0;
					for (k = 0; k < lines; k = k + 1)
						if (seen[k] == (x_a[l*32 +: 32] + imm) >> 5)
							dup = 1'b1;
					if (!dup) begin
						seen[lines] = (x_a[l*32 +: 32] + imm) >> 5;
						lines = lines + 1;
					end
				end
			end
			reqs = 0;
			send(ATG_LSU_LW, imm);
			beat(e);
			err_c = err_c + e;
			if (reqs != lines || l_lanes !== x_mask[NPHYS-1:0] || l_wr !== 1'b1) begin
				$display("FAIL atg_su_lsu: lw %0d: %0d requests for %0d lines", i, reqs, lines);
				err_c = err_c + 1;
			end
			for (l = 0; l < NPHYS; l = l + 1)
				if (x_mask[l] && l_data[l*32 +: 32] !== want[l*32 +: 32]) begin
					$display("FAIL atg_su_lsu: lw %0d lane %0d %h want %h", i, l,
						l_data[l*32 +: 32], want[l*32 +: 32]);
					err_c = err_c + 1;
				end
		end
		/* store */
		for (i = 0; i < 300; i = i + 1) begin
			imm = 0;
			x_mask = $random(seed);
			for (l = 0; l < NPHYS; l = l + 1) begin
				x_a[l*32 +: 32] = 32'h200 + ($unsigned($random(seed)) % 64) * 4;
				x_b[l*32 +: 32] = $random(seed);
			end
			for (l = 0; l < NPHYS; l = l + 1)
				if (x_mask[NPHYS + l])
					shadow[x_a[l*32 +: 32] / 4] = x_b[l*32 +: 32];
			reqs = 0;
			wrsp = 0;
			send(ATG_LSU_SW, imm);
			beat(e);
			err_s = err_s + e;
			if (l_wr !== 1'b0 || l_lanes !== x_mask[2*NPHYS-1:NPHYS] || wrsp != reqs) begin
				$display("FAIL atg_su_lsu: sw %0d: beat before the write responses", i);
				err_s = err_s + 1;
			end
		end
		for (i = 0; i < 1024; i = i + 1)
			if (mem.peek(4 * i) !== shadow[i]) begin
				if (err_s < 10)
					$display("FAIL atg_su_lsu: word %0d %h want %h", i, mem.peek(4 * i),
						shadow[i]);
				err_s = err_s + 1;
			end
		/* atom */
		for (i = 0; i < 200; i = i + 1) begin
			x_mask = $random(seed);
			for (l = 0; l < NPHYS; l = l + 1) begin
				x_a[l*32 +: 32] = 32'h300 + ($unsigned($random(seed)) % 8) * 4;
				x_b[l*32 +: 32] = $random(seed) % 100;
				x_c[l*32 +: 32] = $random(seed) % 4 == 0 ? shadow[x_a[l*32 +: 32] / 4] :
					$random(seed);
			end
			invs = 0;
			send(ATG_LSU_ATOM, 0);
			aop = x_uop[ATG_UOP_SUB +: 4];
			for (l = 0; l < NPHYS; l = l + 1)
				if (x_mask[NPHYS + l]) begin
					want[l*32 +: 32] = shadow[x_a[l*32 +: 32] / 4];
					shadow[x_a[l*32 +: 32] / 4] = atom_ref(aop, shadow[x_a[l*32 +: 32] / 4],
						x_b[l*32 +: 32], x_c[l*32 +: 32]);
				end
			beat(e);
			err_a = err_a + e;
			if (l_lanes !== x_mask[2*NPHYS-1:NPHYS] || l_wr !== 1'b1 ||
			    (x_mask[2*NPHYS-1:NPHYS] != 0 && invs != 1)) begin
				$display("FAIL atg_su_lsu: atom %0d beat/inv", i);
				err_a = err_a + 1;
			end
			for (l = 0; l < NPHYS; l = l + 1)
				if (x_mask[NPHYS + l] && l_data[l*32 +: 32] !== want[l*32 +: 32]) begin
					$display("FAIL atg_su_lsu: atom %0d op %0d lane %0d old %h want %h", i,
						aop, l, l_data[l*32 +: 32], want[l*32 +: 32]);
					err_a = err_a + 1;
				end
		end
		for (i = 0; i < 1024; i = i + 1)
			if (mem.peek(4 * i) !== shadow[i]) begin
				if (err_a < 10)
					$display("FAIL atg_su_lsu: atom word %0d %h want %h", i,
						mem.peek(4 * i), shadow[i]);
				err_a = err_a + 1;
			end
		/* empty, and fence */
		for (i = 0; i < 30; i = i + 1) begin
			x_mask = 0;
			reqs = 0;
			send(i % 3 == 0 ? ATG_LSU_LW : i % 3 == 1 ? ATG_LSU_SW : ATG_LSU_ATOM, 0);
			beat(e);
			err_e = err_e + e;
			if (reqs != 0) begin
				$display("FAIL atg_su_lsu: empty group made requests");
				err_e = err_e + 1;
			end
		end
		invs = 0;
		send(ATG_LSU_FENCE, 32'd4);
		send(ATG_LSU_FENCE, 32'd1);
		repeat (3) @(posedge clk);
		if (invs != 1 || l_valid) begin
			$display("FAIL atg_su_lsu: fence");
			err_e = err_e + 1;
		end
		if (err_c == 0) $display("PASS atg_su_lsu.coalesce");
		if (err_s == 0) $display("PASS atg_su_lsu.store");
		if (err_a == 0) $display("PASS atg_su_lsu.atom");
		if (err_e == 0) $display("PASS atg_su_lsu.empty");
		if (err_c + err_s + err_a + err_e == 0) $display("PASS atg_su_lsu");
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL atg_su_lsu timeout");
		$finish;
	end
endmodule

`default_nettype wire
