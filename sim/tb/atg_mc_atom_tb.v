/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_atom_tb: atg_mc_atom with two requesters (NATOM 2) in front of
 * amb_mem (random ready and latency, an error region from 0x1000), with
 * 32-byte and with 64-byte lines.  A shadow copy of memory is the
 * reference: each request is applied to it in the order the unit takes the
 * requests (the unit is serial), and the response must give that old value.
 *   ops:   requester 0 alone: all 11 operations (and 11-15, which store
 *          the old value back) with edge and random operands, cmpxchg equal
 *          and not equal, on words anywhere in a line; requests in the
 *          error region give at_error, at_old 0 and no write; afterwards
 *          memory equals the shadow (only the word was written) and the
 *          number of writes equals the number of successful atomics;
 *   multi: both requesters on 8 shared words in two lines, mostly
 *          offering the next request as soon as one is taken (so both are
 *          often valid together): the responses go to the right requester,
 *          one per request, the old values follow the order of taking, and
 *          when both are valid the unit takes the other one than last time
 *          (round-robin); memory equals the shadow at the end.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_atom_chk #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter SEED = 1
) (
	input wire clk,
	output reg done,
	output reg [31:0] ops_errs,
	output reg [31:0] multi_errs
);
	localparam LA_W = 32 - LINE_SHIFT;
	localparam LB = LINE_BYTES * 8;
	localparam MW = 1024;
	localparam [31:0] ERR_BASE = 32'h1000;
	localparam NOPS = 800;
	localparam NMULTI = 300;

	reg rst_n = 1'b0;
	reg [1:0] at_valid = 2'b00;
	reg [7:0] at_op = 0;
	reg [59:0] at_addr = 0;
	reg [63:0] at_a = 0, at_b = 0;
	wire [1:0] at_ready, at_rsp_valid;
	wire [31:0] at_old;
	wire at_error, busy;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [LA_W-1:0] req_line;
	wire [LINE_BYTES-1:0] req_be;
	wire [LB-1:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;

	atg_mc_atom #(
		.ADDR_W(32), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .NATOM(2), .AW(1)
	) dut (
		.clk(clk), .rst_n(rst_n),
		.at_valid(at_valid), .at_ready(at_ready), .at_op(at_op), .at_addr(at_addr),
		.at_a(at_a), .at_b(at_b), .at_rsp_valid(at_rsp_valid), .at_old(at_old),
		.at_error(at_error), .busy(busy),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);
	amb_mem #(
		.ADDR_W(32), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .MEM_WORDS(MW),
		.ERR_BASE(ERR_BASE), .SEED(SEED + 7)
	) mem (
		.clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready),
		.req_write(req_write), .req_line(req_line), .req_be(req_be),
		.req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid),
		.rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
		.rsp_error(rsp_error)
	);

	/* The reference operations (tools/gsi1model.py's atom). */
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
		4'd10: atom_ref = old == b ? a : old;
		default: atom_ref = old;
		endcase
	endfunction

	reg [31:0] shadow [0:MW-1];
	reg [31:0] exp_old [0:1];
	reg exp_err [0:1];
	reg outst [0:1];
	reg phase;
	integer errs, nok, last_k, both, k;
	reg [29:0] wa;

	task err;
		begin
			if (phase)
				multi_errs = multi_errs + 1;
			else
				ops_errs = ops_errs + 1;
			errs = errs + 1;
		end
	endtask

	/* The reference: applied when the unit takes a request. */
	always @(posedge clk) if (rst_n) begin
		if (at_ready[0] && at_ready[1]) begin
			$display("FAIL atg_mc_atom: both requesters taken (L%0d)", LINE_BYTES);
			err;
		end
		if ((at_ready & ~at_valid) != 2'b00) begin
			$display("FAIL atg_mc_atom: ready without valid (L%0d)", LINE_BYTES);
			err;
		end
		for (k = 0; k < 2; k = k + 1) begin
			if (at_rsp_valid[k]) begin
				if (!outst[k]) begin
					$display("FAIL atg_mc_atom: response to idle requester %0d (L%0d)", k,
						LINE_BYTES);
					err;
				end else if (at_old !== exp_old[k] || at_error !== exp_err[k]) begin
					$display("FAIL atg_mc_atom: requester %0d old %h err %b want %h %b (L%0d)",
						k, at_old, at_error, exp_old[k], exp_err[k], LINE_BYTES);
					err;
				end
				outst[k] = 1'b0;
			end
			if (at_valid[k] && at_ready[k]) begin
				if (outst[k]) begin
					$display("FAIL atg_mc_atom: requester %0d taken twice (L%0d)", k,
						LINE_BYTES);
					err;
				end
				if (at_valid == 2'b11) begin
					both = both + 1;
					if (k == last_k) begin
						$display("FAIL atg_mc_atom: requester %0d taken twice in a row (L%0d)",
							k, LINE_BYTES);
						err;
					end
				end
				last_k = k;
				wa = at_addr[k*30 +: 30];
				if ({wa, 2'b00} >= ERR_BASE) begin
					exp_old[k] = 32'd0;
					exp_err[k] = 1'b1;
				end else begin
					exp_old[k] = shadow[wa];
					exp_err[k] = 1'b0;
					shadow[wa] = atom_ref(at_op[k*4 +: 4], shadow[wa], at_a[k*32 +: 32],
						at_b[k*32 +: 32]);
					nok = nok + 1;
				end
				outst[k] = 1'b1;
			end
		end
	end

	/* One request of requester rq; until its response when wr is set, else
	 * until it is taken (the next request may wait while this one runs). */
	task automatic request;
		input integer rq;
		input [3:0] op;
		input [29:0] adr;
		input [31:0] a, b;
		input wr;
		begin
			@(negedge clk);
			at_op[rq*4 +: 4] = op;
			at_addr[rq*30 +: 30] = adr;
			at_a[rq*32 +: 32] = a;
			at_b[rq*32 +: 32] = b;
			at_valid[rq] = 1'b1;
			@(posedge clk);
			while (!at_ready[rq])
				@(posedge clk);
			@(negedge clk);
			at_valid[rq] = 1'b0;
			at_op[rq*4 +: 4] = $random(seed);
			at_addr[rq*30 +: 30] = $random(seed);
			while (wr && !at_rsp_valid[rq])
				@(posedge clk);
		end
	endtask

	integer seed, i, t, g;
	reg [31:0] va, vb;
	reg [3:0] vop;
	reg [29:0] vadr;

	/* An operand: edge values or random. */
	function [31:0] operand;
		input [31:0] r;
		input [31:0] s;
		case (r[2:0])
		3'd0: operand = 32'd0;
		3'd1: operand = 32'd1;
		3'd2: operand = 32'hFFFFFFFF;
		3'd3: operand = 32'h7FFFFFFF;
		3'd4: operand = 32'h80000000;
		default: operand = s;
		endcase
	endfunction

	task check_mem;
		begin
			for (i = 0; i < MW; i = i + 1)
				if (mem.peek(4 * i) !== shadow[i]) begin
					$display("FAIL atg_mc_atom: word %0d %h want %h (L%0d)", i,
						mem.peek(4 * i), shadow[i], LINE_BYTES);
					err;
				end
			if (mem.writes != nok) begin
				$display("FAIL atg_mc_atom: %0d writes for %0d atomics (L%0d)", mem.writes,
					nok, LINE_BYTES);
				err;
			end
		end
	endtask

	/* Requester 1 of the multi phase. */
	reg go1 = 1'b0, done1 = 1'b0;
	integer seed1, t1, g1;
	initial begin
		wait (go1);
		for (t1 = 0; t1 < NMULTI; t1 = t1 + 1) begin
			for (g1 = 0; g1 < ($unsigned($random(seed1)) % 4 == 0 ? 3 : 0); g1 = g1 + 1)
				@(posedge clk);
			request(1, $unsigned($random(seed1)) % 11, 30'h100 + $unsigned($random(seed1)) % 8 *
				(LINE_BYTES / 16), operand($random(seed1), $random(seed1) % 64),
				$random(seed1) % 4, $unsigned($random(seed1)) % 4 == 0);
		end
		done1 = 1'b1;
	end

	initial begin
		done = 1'b0;
		ops_errs = 0;
		multi_errs = 0;
		errs = 0;
		nok = 0;
		both = 0;
		last_k = -1;
		phase = 1'b0;
		outst[0] = 1'b0;
		outst[1] = 1'b0;
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		seed = seed * 16 + SEED;
		seed1 = seed + 3;
		for (i = 0; i < MW; i = i + 1) begin
			shadow[i] = $random(seed);
			mem.poke(4 * i, shadow[i]);
		end
		repeat (4) @(posedge clk);
		@(negedge clk);
		rst_n = 1'b1;

		/* ops */
		for (t = 0; t < NOPS; t = t + 1) begin
			vop = t % 16 < 11 ? t % 11 : 11 + $unsigned($random(seed)) % 5;
			if ($unsigned($random(seed)) % 16 == 0)
				vadr = (ERR_BASE >> 2) + $unsigned($random(seed)) % 256;
			else
				vadr = $unsigned($random(seed)) % 256;
			if (vadr < 256 && $random(seed) % 4 == 0) begin
				shadow[vadr] = operand($random(seed), $random(seed));
				mem.poke(4 * vadr, shadow[vadr]);
			end
			va = operand($random(seed), $random(seed));
			vb = $random(seed);
			if (vop == 4'd10 && $random(seed) % 2 == 0)
				vb = vadr < 256 ? shadow[vadr] : 32'd0;
			request(0, vop, vadr, va, vb, 1'b1);
			for (g = 0; g < $unsigned($random(seed)) % 3; g = g + 1)
				@(posedge clk);
		end
		repeat (4) @(posedge clk);
		check_mem;
		if (busy) begin
			$display("FAIL atg_mc_atom: busy after ops (L%0d)", LINE_BYTES);
			err;
		end

		/* multi */
		@(negedge clk);
		phase = 1'b1;
		go1 = 1'b1;
		for (t = 0; t < NMULTI; t = t + 1) begin
			for (g = 0; g < ($unsigned($random(seed)) % 4 == 0 ? 3 : 0); g = g + 1)
				@(posedge clk);
			request(0, $unsigned($random(seed)) % 11, 30'h100 + $unsigned($random(seed)) % 8 *
				(LINE_BYTES / 16), operand($random(seed), $random(seed) % 64),
				$random(seed) % 4, $unsigned($random(seed)) % 4 == 0);
		end
		wait (done1);
		repeat (40) @(posedge clk);
		check_mem;
		if (both < NMULTI / 4) begin
			$display("FAIL atg_mc_atom: only %0d contended requests (L%0d)", both, LINE_BYTES);
			err;
		end
		if (busy || outst[0] || outst[1]) begin
			$display("FAIL atg_mc_atom: busy after multi (L%0d)", LINE_BYTES);
			err;
		end
		done = 1'b1;
	end
endmodule

module atg_mc_atom_tb;
	reg clk = 1'b0;
	always #5 clk = !clk;

	wire done32, done64;
	wire [31:0] ops32, ops64, multi32, multi64;
	atg_mc_atom_chk #(.LINE_BYTES(32), .LINE_SHIFT(5), .SEED(1)) l32 (
		.clk(clk), .done(done32), .ops_errs(ops32), .multi_errs(multi32)
	);
	atg_mc_atom_chk #(.LINE_BYTES(64), .LINE_SHIFT(6), .SEED(2)) l64 (
		.clk(clk), .done(done64), .ops_errs(ops64), .multi_errs(multi64)
	);

	initial begin
		wait (done32 && done64);
		if (ops32 + ops64 == 0) $display("PASS atg_mc_atom.ops");
		if (multi32 + multi64 == 0) $display("PASS atg_mc_atom.multi");
		if (ops32 + ops64 + multi32 + multi64 == 0) $display("PASS atg_mc_atom");
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL atg_mc_atom timeout");
		$finish;
	end
endmodule

`default_nettype wire
