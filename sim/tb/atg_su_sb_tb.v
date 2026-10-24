/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_sb_tb: the scoreboard issue stage (NPHYS 8, NWARPS 4, 4 entries).
 * A model of atg_su_opd takes every issue and pulses x_end G cycles
 * later.  raw: a read of a pending lw rd replays until its release (wake);
 * waw: a write into a pending texl rd..rd+3 replays, so does a texl.3.c
 * whose rs1+3 is in it; full: four pending
 * loads fill a warp's entries, a fifth replays, another warp issues;
 * wait: wait/fence/end against the counters; fault: ILL pulses fault with
 * the pc and feedback 1; short: a reader of a short writer's rd is held
 * until the result is in the RF (SHORT_LAT + 1 - G cycles after x_end).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_sb_tb;
`include "atg_su_uop.vh"
	localparam LAT = 6;
	localparam G = 4;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg u_valid = 1'b0;
	reg [1:0] u_warp = 0;
	reg [15:0] u_pc = 0;
	reg [ATG_UOP_W-1:0] u_uop = 0;
	wire u_ready, i_valid, fb_valid, busy, fault;
	reg i_ready = 1'b1;
	wire [1:0] i_warp, fb_warp;
	wire [15:0] i_pc, fault_pc;
	wire [ATG_UOP_W-1:0] i_uop;
	wire [2:0] i_sbe;
	reg x_end = 1'b0;
	wire [1:0] fb_kind;
	wire [3:0] wake;
	reg rel_valid = 1'b0;
	reg [1:0] rel_warp = 0;
	reg [2:0] rel_sbe = 0, rel_cls = 0;
	reg wb_stall = 1'b0;
	integer errors = 0;
	integer cyc = 0;
	integer last_issue_cyc, last_xend_cyc;

	always #5 clk = !clk;

	atg_su_sb #(.NPHYS(8), .SHORT_LAT(LAT)) dut (
		.clk(clk), .rst_n(rst_n), .u_valid(u_valid), .u_ready(u_ready), .u_warp(u_warp),
		.u_pc(u_pc), .u_uop(u_uop), .i_valid(i_valid), .i_ready(i_ready), .i_warp(i_warp),
		.i_pc(i_pc), .i_uop(i_uop), .i_sbe(i_sbe), .x_end(x_end), .fb_valid(fb_valid),
		.fb_warp(fb_warp), .fb_kind(fb_kind), .wake(wake), .rel_valid(rel_valid),
		.rel_warp(rel_warp), .rel_sbe(rel_sbe), .rel_cls(rel_cls), .wb_stall(wb_stall),
		.rq_empty(1'b1), .rq_full(1'b1), .busy(busy), .fault(fault), .fault_pc(fault_pc)
	);

	/* The opd model: x_end G + 1 cycles after each issue, in order. */
	reg [31:0] xq [0:63];
	integer xh = 0, xt = 0;
	always @(posedge clk) begin
		cyc <= cyc + 1;
		if (i_valid && i_ready) begin
			xq[xt % 64] <= cyc + G + 1;
			xt <= xt + 1;
			last_issue_cyc <= cyc;
		end
	end
	always @(negedge clk) begin
		x_end = xh != xt && xq[xh % 64] <= cyc;
		if (x_end) begin
			xh = xh + 1;
			last_xend_cyc = cyc;
		end
	end

	function [ATG_UOP_W-1:0] mk;
		input [3:0] unit;
		input [7:0] op;
		input [2:0] cls;
		input [6:0] rd, rs1, rs2;
		input wrd, u1, u2;
		input [2:0] ndst;
		reg [ATG_UOP_W-1:0] u;
		begin
			u = 0;
			u[ATG_UOP_UNIT +: 4] = unit;
			u[ATG_UOP_OP +: 8] = op;
			u[ATG_UOP_CLS +: 3] = cls;
			u[ATG_UOP_RD +: 7] = rd;
			u[ATG_UOP_RS1 +: 7] = rs1;
			u[ATG_UOP_RS2 +: 7] = rs2;
			u[ATG_UOP_WRD] = wrd;
			u[ATG_UOP_USE1] = u1;
			u[ATG_UOP_USE2] = u2;
			u[ATG_UOP_NDST +: 3] = ndst;
			mk = u;
		end
	endfunction

	function [ATG_UOP_W-1:0] alu;	/* add rd, rs1, rs2 */
		input [6:0] rd, rs1, rs2;
		alu = mk(ATG_UNIT_ALU, 0, ATG_CLS_A, rd, rs1, rs2, 1, 1, 1, 1);
	endfunction
	function [ATG_UOP_W-1:0] lw;	/* lw rd, 0(rs1) */
		input [6:0] rd, rs1;
		lw = mk(ATG_UNIT_LSU, ATG_LSU_LW, ATG_CLS_M, rd, rs1, 0, 1, 1, 0, 1);
	endfunction
	function [ATG_UOP_W-1:0] sw;	/* sw rs2, 0(rs1) */
		input [6:0] rs1, rs2;
		sw = mk(ATG_UNIT_LSU, ATG_LSU_SW, ATG_CLS_M, 0, rs1, rs2, 0, 1, 1, 0);
	endfunction
	function [ATG_UOP_W-1:0] ctl;	/* wait / end */
		input [3:0] unit;
		input [7:0] op;
		input [11:0] imm;
		reg [ATG_UOP_W-1:0] u;
		begin
			u = mk(unit, op, ATG_CLS_A, 0, 0, 0, 0, 0, 0, 0);
			u[ATG_UOP_IMM +: 32] = {20'd0, imm};
			ctl = u;
		end
	endfunction

	/* Present one instruction; returns 0 issued, 1 issued/wc, 2 replay,
	 * 3 consumed without issue; sbe is the entry. */
	integer res;
	reg [2:0] sbe;
	reg was_issue;
	task send;
		input [1:0] w;
		input [15:0] pc;
		input [ATG_UOP_W-1:0] u;
		begin
			@(negedge clk);
			u_valid = 1'b1;
			u_warp = w;
			u_pc = pc;
			u_uop = u;
			#1;
			while (!u_ready) begin
				@(negedge clk);
				#1;
			end
			was_issue = i_valid;
			sbe = i_sbe;
			if (!fb_valid || fb_warp !== w)
				res = -1;
			else if (fb_kind == 2'd2)
				res = 2;
			else if (!i_valid)
				res = 3;
			else
				res = fb_kind;
			@(negedge clk);
			u_valid = 1'b0;
		end
	endtask

	task do_rel;
		input [1:0] w;
		input [2:0] e;
		input [2:0] c;
		begin
			@(negedge clk);
			rel_valid = 1'b1;
			rel_warp = w;
			rel_sbe = e;
			rel_cls = c;
			#1;
			if (wake !== (4'd1 << w)) begin
				$display("FAIL atg_su_sb wake %b", wake);
				errors = errors + 1;
			end
			@(negedge clk);
			rel_valid = 1'b0;
		end
	endtask

	task chk;
		input integer want;
		input [8*24-1:0] what;
		begin
			if (res != want) begin
				$display("FAIL atg_su_sb.%0s: result %0d want %0d", what, res, want);
				errors = errors + 1;
			end
		end
	endtask

	reg [2:0] e_lw, e_tex;
	reg [2:0] ents [0:3];
	integer k, ec;
	initial begin
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		/* raw */
		ec = errors;
		send(0, 1, lw(5, 1));
		chk(0, "raw lw");
		e_lw = sbe;
		send(0, 2, alu(6, 5, 1));
		chk(2, "raw replay rs1");
		send(0, 2, alu(6, 1, 5));
		chk(2, "raw replay rs2");
		send(0, 2, alu(5, 1, 2));
		chk(2, "raw replay waw rd");
		send(1, 2, alu(6, 5, 1));
		chk(0, "raw other warp");
		do_rel(0, e_lw, ATG_CLS_M);
		send(0, 2, alu(6, 5, 1));
		chk(0, "raw after release");
		if (errors == ec)
			$display("PASS atg_su_sb.raw");
		/* waw: texl r8 (rd..rd+3) */
		ec = errors;
		u_uop = mk(ATG_UNIT_TEX, ATG_TEX_TEXL, ATG_CLS_T, 8, 0, 1, 1, 1, 1, 4);
		u_uop[ATG_UOP_PAIR] = 1'b1;
		send(2, 10, u_uop);
		chk(0, "waw texl");
		e_tex = sbe;
		send(2, 11, alu(11, 1, 2));
		chk(2, "waw r11");
		send(2, 11, alu(8, 1, 2));
		chk(2, "waw r8");
		send(2, 11, alu(12, 1, 2));
		chk(0, "waw r12");
		send(2, 12, alu(13, 10, 2));
		chk(2, "waw read r10");
		/* texl.3.c r20, r5: reads r5-r8 (rs1+3 = rs3 + 1 = r8): replays;
		 * texl.c r20, r5 reads r5-r7 only: issues. */
		u_uop = mk(ATG_UNIT_TEX, ATG_TEX_TEXL | 8'd4, ATG_CLS_T, 20, 5, 1, 1, 1, 1, 4);
		u_uop[ATG_UOP_PAIR] = 1'b1;
		u_uop[ATG_UOP_USE3] = 1'b1;
		u_uop[ATG_UOP_RS3 +: 7] = 7'd7;
		u_uop[ATG_UOP_SUB + 4] = 1'b1;
		send(2, 12, u_uop);
		chk(2, "waw texl.3.c reads rs1+3");
		u_uop[ATG_UOP_SUB + 4] = 1'b0;
		send(2, 12, u_uop);
		chk(0, "waw texl.c");
		do_rel(2, sbe, ATG_CLS_T);
		/* A texture over r6..r9 overlaps too. */
		u_uop = mk(ATG_UNIT_TEX, ATG_TEX_TEXL, ATG_CLS_T, 6, 0, 1, 1, 1, 1, 4);
		send(2, 13, u_uop);
		chk(2, "waw texl over texl");
		do_rel(2, e_tex, ATG_CLS_T);
		send(2, 11, alu(11, 1, 2));
		chk(0, "waw after release");
		if (errors == ec)
			$display("PASS atg_su_sb.waw");
		/* full */
		ec = errors;
		for (k = 0; k < 4; k = k + 1) begin
			send(1, 20 + k, lw(20 + k, 1));
			chk(0, "full lw");
			ents[k] = sbe;
		end
		if (ents[0] == ents[1] || ents[1] == ents[2] || ents[2] == ents[3] || ents[0] == ents[3])
			begin
			$display("FAIL atg_su_sb.full entries %0d %0d %0d %0d", ents[0], ents[1], ents[2],
				ents[3]);
			errors = errors + 1;
		end
		send(1, 24, lw(30, 1));
		chk(2, "full fifth");
		send(1, 24, sw(1, 2));
		chk(0, "full store without entry");
		if (sbe !== 3'b111) begin
			$display("FAIL atg_su_sb.full store took an entry");
			errors = errors + 1;
		end
		send(3, 24, lw(30, 1));
		chk(0, "full other warp");
		do_rel(3, sbe, ATG_CLS_M);
		do_rel(1, ents[2], ATG_CLS_M);
		send(1, 24, lw(30, 1));
		chk(0, "full after release");
		if (sbe !== ents[2]) begin
			$display("FAIL atg_su_sb.full reused entry %0d want %0d", sbe, ents[2]);
			errors = errors + 1;
		end
		for (k = 0; k < 4; k = k + 1)
			do_rel(1, k, ATG_CLS_M);
		do_rel(1, 3'b111, ATG_CLS_M);	/* the store */
		if (errors == ec)
			$display("PASS atg_su_sb.full");
		/* wait / fence / end on warp 3: two stores outstanding (cm = 2). */
		ec = errors;
		send(3, 30, sw(1, 2));
		send(3, 31, sw(1, 2));
		send(3, 32, ctl(ATG_UNIT_CTL, ATG_CTL_WAIT, 12'hFF1));
		chk(2, "wait cm 1");
		send(3, 32, ctl(ATG_UNIT_CTL, ATG_CTL_WAIT, 12'hFF2));
		chk(3, "wait cm 2 satisfied");
		send(3, 33, ctl(ATG_UNIT_LSU, ATG_LSU_FENCE, 12'h001));
		chk(2, "fence");
		send(3, 33, ctl(ATG_UNIT_EXEC, ATG_EXEC_END, 12'h000));
		chk(2, "end");
		do_rel(3, 3'b111, ATG_CLS_M);
		send(3, 32, ctl(ATG_UNIT_CTL, ATG_CTL_WAIT, 12'hFF1));
		chk(3, "wait after release");
		send(3, 33, ctl(ATG_UNIT_EXEC, ATG_EXEC_END, 12'h000));
		chk(2, "end cm 1");
		do_rel(3, 3'b111, ATG_CLS_M);
		send(3, 33, ctl(ATG_UNIT_LSU, ATG_LSU_FENCE, 12'h001));
		chk(0, "fence after");
		send(3, 34, ctl(ATG_UNIT_EXEC, ATG_EXEC_END, 12'h000));
		chk(1, "end issues, wait for wc");
		if (errors == ec)
			$display("PASS atg_su_sb.wait");
		/* fault */
		ec = errors;
		@(negedge clk);
		u_valid = 1'b1;
		u_warp = 2;
		u_pc = 16'h1234;
		u_uop = 104'd1 << ATG_UOP_ILL;
		#1;
		if (!u_ready || !fault || fault_pc !== 16'h1234 || i_valid || fb_kind !== 2'd1) begin
			$display("FAIL atg_su_sb.fault");
			errors = errors + 1;
		end
		@(negedge clk);
		u_valid = 1'b0;
		#1;
		if (fault) begin
			$display("FAIL atg_su_sb.fault pulse");
			errors = errors + 1;
		end
		if (errors == ec)
			$display("PASS atg_su_sb.fault");
		/* short interlock: add r20; add r21, r20 waits until r20 is written. */
		ec = errors;
		repeat (10) @(negedge clk);
		send(0, 40, alu(20, 1, 2));
		k = last_issue_cyc;
		send(0, 41, alu(21, 20, 2));
		chk(0, "short reader");
		/* Reader issue cycle must be >= writer x_end + LAT + 1 - G. */
		if (last_issue_cyc < k + G + 1 + LAT + 1 - G) begin
			$display("FAIL atg_su_sb.short: writer %0d reader %0d", k, last_issue_cyc);
			errors = errors + 1;
		end
		send(0, 42, alu(22, 1, 2));
		k = last_issue_cyc;
		send(0, 43, alu(23, 3, 4));
		if (last_issue_cyc != k + 2) begin
			$display("FAIL atg_su_sb.short: independent waited %0d", last_issue_cyc - k);
			errors = errors + 1;
		end
		if (errors == ec)
			$display("PASS atg_su_sb.short");
		repeat (20) @(negedge clk);
		if (busy) begin
			$display("FAIL atg_su_sb busy at the end");
			errors = errors + 1;
		end
		if (errors == 0)
			$display("PASS atg_su_sb");
		$finish;
	end

	initial begin
		#1000000;
		$display("FAIL atg_su_sb timeout");
		$finish;
	end
endmodule

`default_nettype wire
