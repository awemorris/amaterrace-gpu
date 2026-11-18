/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_index_tb: atg_vf_index against amb_mem and a reference walk
 * computed here from the memory: non-indexed draws (no memory access),
 * u16 and u32 index buffers with odd FIRST and counts that cross lines,
 * primitive restart (0xFFFF only for u16, 0xFFFFFFFF only for u32, nothing
 * without PRIM_RESTART), and instances (also COUNT 0 / INSTANCE_COUNT 0,
 * which send nothing).  iv_ready is random (seeded).  Each item is checked
 * in order: index, instance, restart, last.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_index_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg kick = 1'b0;
	reg iv_ready = 1'b0;
	wire busy, iv_valid, iv_restart, iv_last;
	wire [31:0] iv_index, iv_inst;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;

	atg_vf_index dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .kick(kick), .busy(busy), .iv_valid(iv_valid),
		.iv_ready(iv_ready), .iv_index(iv_index), .iv_inst(iv_inst),
		.iv_restart(iv_restart), .iv_last(iv_last),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));
	amb_mem #(.MEM_WORDS(4096), .SEED(5)) mem (.clk(clk), .rst_n(rst_n),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));

	localparam [31:0] IBASE = 32'h0000_0400;
	localparam MAXN = 2048;
	integer seed, i, n, got, errs, sect_errs, nreq, tmo;
	reg [31:0] x_idx [0:MAXN-1];
	reg [31:0] x_inst [0:MAXN-1];
	reg x_rst [0:MAXN-1];

	task st_put;
		input [8:0] i_;
		input [31:0] val;
		begin
			st_we <= 1'b1;
			st_idx <= i_;
			st_wdata <= val;
			@(posedge clk);
			st_we <= 1'b0;
		end
	endtask

	/* The index at position p of the buffer (fmt 1 u16, 2 u32). */
	function [31:0] ival;
		input [1:0] fmt;
		input [31:0] p;
		reg [31:0] w;
		begin
			if (fmt == 2'd1) begin
				w = mem.peek(IBASE + 2 * p - (p & 1) * 2);
				ival = (p & 1) ? {16'd0, w[31:16]} : {16'd0, w[15:0]};
			end else
				ival = mem.peek(IBASE + 4 * p);
		end
	endfunction

	/* The checker: every handshake against x_*[got]. */
	always @(posedge clk) begin
		if (req_valid && req_ready)
			nreq = nreq + 1;
		if (iv_valid && iv_ready) begin
			if (got >= n) begin
				$display("FAIL atg_vf_index: item %0d beyond %0d", got, n);
				errs = errs + 1;
			end else if (iv_inst !== x_inst[got] || iv_restart !== x_rst[got] ||
				(!x_rst[got] && iv_index !== x_idx[got]) || iv_last !== (got == n - 1)) begin
				$display("FAIL atg_vf_index: item %0d index %h inst %h rst %b last %b, want %h %h %b %b",
					got, iv_index, iv_inst, iv_restart, iv_last, x_idx[got], x_inst[got],
					x_rst[got], got == n - 1);
				errs = errs + 1;
			end
			got = got + 1;
		end
		iv_ready <= ($random(seed) & 3) != 0;
	end

	task draw;
		input [1:0] fmt;
		input [31:0] first, count;
		input rst;
		input [31:0] icount, finst;
		integer j, k;
		reg [31:0] v;
		begin
			st_put(9'h021, IBASE);
			st_put(9'h022, {30'd0, fmt});
			st_put(9'h023, first);
			st_put(9'h024, count);
			st_put(9'h025, {31'd0, rst});
			st_put(9'h026, icount);
			st_put(9'h027, finst);
			n = 0;
			for (k = 0; k < icount; k = k + 1)
				for (j = 0; j < count; j = j + 1) begin
					v = fmt == 2'd0 ? first + j : ival(fmt, first + j);
					x_idx[n] = v;
					x_inst[n] = finst + k;
					x_rst[n] = fmt != 2'd0 && rst &&
						(fmt == 2'd1 ? v[15:0] == 16'hFFFF : v == 32'hFFFFFFFF);
					n = n + 1;
				end
			got = 0;
			nreq = 0;
			kick <= 1'b1;
			@(posedge clk);
			kick <= 1'b0;
			@(posedge clk);
			tmo = 0;
			while ((busy || got < n) && tmo < 100000) begin
				@(posedge clk);
				tmo = tmo + 1;
			end
			if (tmo >= 100000 || got != n) begin
				$display("FAIL atg_vf_index: draw fmt %0d first %0d count %0d: %0d of %0d items",
					fmt, first, count, got, n);
				errs = errs + 1;
			end
			if (fmt == 2'd0 && nreq != 0) begin
				$display("FAIL atg_vf_index: non-indexed draw made %0d requests", nreq);
				errs = errs + 1;
			end
			repeat (3) @(posedge clk);
		end
	endtask

	task section;
		input [8*8-1:0] name;
		begin
			if (errs == sect_errs)
				$display("PASS atg_vf_index.%0s", name);
			sect_errs = errs;
		end
	endtask

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		errs = 0;
		sect_errs = 0;
		got = 0;
		n = 0;
		nreq = 0;
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		/* random indices, with some all-ones halves and words */
		for (i = 0; i < 512; i = i + 1)
			mem.poke(IBASE + 4 * i, ($random(seed) & 7) == 0 ? 32'hFFFFFFFF :
				($random(seed) & 7) == 0 ? {$random(seed) & 32'hFFFF, 16'hFFFF} : $random(seed));

		/* direct */
		draw(2'd0, 0, 1, 1'b0, 1, 0);
		draw(2'd0, 7, 3, 1'b1, 1, 0);
		for (i = 0; i < 6; i = i + 1)
			draw(2'd0, $random(seed), 1 + ($unsigned($random(seed)) % 70), 1'b0, 1,
				$random(seed));
		section("direct");

		/* u16 and u32, odd FIRST, counts over several lines */
		for (i = 0; i < 8; i = i + 1) begin
			draw(2'd1, $unsigned($random(seed)) % 200, 1 + ($unsigned($random(seed)) % 90),
				1'b0, 1, 0);
			draw(2'd2, $unsigned($random(seed)) % 200, 1 + ($unsigned($random(seed)) % 50),
				1'b0, 1, 0);
		end
		draw(2'd1, 15, 1, 1'b0, 1, 0);
		draw(2'd1, 16, 16, 1'b0, 1, 0);
		draw(2'd2, 7, 2, 1'b0, 1, 0);
		draw(2'd2, 8, 8, 1'b0, 1, 0);
		section("u16u32");

		/* restart */
		for (i = 0; i < 8; i = i + 1) begin
			draw(2'd1, $unsigned($random(seed)) % 200, 1 + ($unsigned($random(seed)) % 90),
				1'b1, 1, 0);
			draw(2'd2, $unsigned($random(seed)) % 200, 1 + ($unsigned($random(seed)) % 50),
				1'b1, 1, 0);
		end
		section("restart");

		/* instances */
		draw(2'd0, 3, 5, 1'b0, 3, 10);
		draw(2'd1, 33, 21, 1'b1, 4, 2);
		draw(2'd2, 5, 13, 1'b1, 3, 32'hFFFFFFFE);
		draw(2'd0, 3, 0, 1'b0, 3, 0);
		draw(2'd1, 3, 5, 1'b0, 0, 0);
		for (i = 0; i < 4; i = i + 1)
			draw($unsigned($random(seed)) % 3, $unsigned($random(seed)) % 100,
				1 + ($unsigned($random(seed)) % 20), $random(seed), 1 + ($unsigned($random(seed)) % 4),
				$random(seed));
		section("inst");

		if (errs == 0)
			$display("PASS atg_vf_index");
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL atg_vf_index: timeout");
		$finish;
	end
endmodule

`default_nettype wire
