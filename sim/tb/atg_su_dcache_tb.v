/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_dcache_tb: atg_su_dcache (1 KiB, 32-byte lines) in front of
 * amb_mem, driven by random requests over 4 KiB (so lines conflict) and
 * compared with a shadow copy of memory:
 *   hit: reads return the memory's data; a repeated read of a line is a
 *        hit (no MC request) unless a conflicting line came in between;
 *   wt:  writes reach memory (byte enables) and update a present line;
 *   inv: after memory changes behind the cache a present line is stale
 *        until inv, then the read misses and returns the new data.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_dcache_tb;
	localparam LB = 256;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg inv = 1'b0;
	reg u_req_valid = 1'b0, u_req_write = 1'b0;
	reg [26:0] u_req_line = 0;
	reg [31:0] u_req_be = 0;
	reg [LB-1:0] u_req_wdata = 0;
	reg [7:0] u_req_tag = 0;
	wire u_req_ready, u_rsp_valid, u_rsp_write, u_rsp_error;
	wire [7:0] u_rsp_tag;
	wire [LB-1:0] u_rsp_rdata;
	wire m_req_valid, m_req_ready, m_req_write, m_rsp_valid, m_rsp_write, m_rsp_error;
	wire [26:0] m_req_line;
	wire [31:0] m_req_be;
	wire [LB-1:0] m_req_wdata, m_rsp_rdata;
	wire [7:0] m_req_tag, m_rsp_tag;

	atg_su_dcache dut (
		.clk(clk), .rst_n(rst_n), .inv(inv),
		.u_req_valid(u_req_valid), .u_req_ready(u_req_ready), .u_req_write(u_req_write),
		.u_req_line(u_req_line), .u_req_be(u_req_be), .u_req_wdata(u_req_wdata),
		.u_req_tag(u_req_tag), .u_rsp_valid(u_rsp_valid), .u_rsp_write(u_rsp_write),
		.u_rsp_tag(u_rsp_tag), .u_rsp_rdata(u_rsp_rdata), .u_rsp_error(u_rsp_error),
		.m_req_valid(m_req_valid), .m_req_ready(m_req_ready), .m_req_write(m_req_write),
		.m_req_line(m_req_line), .m_req_be(m_req_be), .m_req_wdata(m_req_wdata),
		.m_req_tag(m_req_tag), .m_rsp_valid(m_rsp_valid), .m_rsp_write(m_rsp_write),
		.m_rsp_tag(m_rsp_tag), .m_rsp_rdata(m_rsp_rdata), .m_rsp_error(m_rsp_error)
	);
	amb_mem #(.MEM_WORDS(1024), .ERR_BASE(32'h1000)) mem (
		.clk(clk), .rst_n(rst_n), .req_valid(m_req_valid), .req_ready(m_req_ready),
		.req_write(m_req_write), .req_line(m_req_line), .req_be(m_req_be),
		.req_wdata(m_req_wdata), .req_tag(m_req_tag), .rsp_valid(m_rsp_valid),
		.rsp_write(m_rsp_write), .rsp_tag(m_rsp_tag), .rsp_rdata(m_rsp_rdata),
		.rsp_error(m_rsp_error)
	);

	reg [31:0] shadow [0:1023];
	integer m_reqs;
	always @(posedge clk)
		if (m_req_valid && m_req_ready)
			m_reqs = m_reqs + 1;

	integer seed, i, w, b, err_h, err_w, err_i, n;
	reg [LB-1:0] got;
	reg gerr;

	/* One request; returns the response data in got. */
	task req;
		input wr;
		input [26:0] line;
		input [31:0] be;
		input [LB-1:0] wd;
		begin
			@(negedge clk);
			u_req_valid = 1'b1;
			u_req_write = wr;
			u_req_line = line;
			u_req_be = be;
			u_req_wdata = wd;
			u_req_tag = $random(seed);
			@(posedge clk);
			while (!u_req_ready)
				@(posedge clk);
			@(negedge clk);
			u_req_valid = 1'b0;
			n = 0;
			while (!u_rsp_valid) begin
				@(negedge clk);
				n = n + 1;
				if (n > 100) begin
					$display("FAIL atg_su_dcache: no response");
					$finish;
				end
			end
			got = u_rsp_rdata;
			gerr = u_rsp_error;
			if (u_rsp_tag !== u_req_tag || u_rsp_write !== wr) begin
				$display("FAIL atg_su_dcache: response tag/write");
				err_h = err_h + 1;
			end
			if (wr)
				for (w = 0; w < 8; w = w + 1)
					for (b = 0; b < 4; b = b + 1)
						if (be[w * 4 + b] && line < 128)
							shadow[line * 8 + w][b*8 +: 8] = wd[(w*32 + b*8) +: 8];
		end
	endtask

	task check_read;
		input [26:0] line;
		input integer which;
		begin
			req(1'b0, line, 0, 0);
			for (w = 0; w < 8; w = w + 1)
				if (got[w*32 +: 32] !== shadow[line * 8 + w]) begin
					if (err_h + err_w + err_i < 10)
						$display("FAIL atg_su_dcache: line %0d word %0d %h want %h", line,
							w, got[w*32 +: 32], shadow[line * 8 + w]);
					if (which == 0) err_h = err_h + 1;
					else if (which == 1) err_w = err_w + 1;
					else err_i = err_i + 1;
				end
		end
	endtask

	integer before;
	reg [26:0] ln;
	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		err_h = 0;
		err_w = 0;
		err_i = 0;
		m_reqs = 0;
		for (i = 0; i < 1024; i = i + 1) begin
			shadow[i] = $random(seed);
			mem.poke(4 * i, shadow[i]);
		end
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		/* hit: random reads; a repeat of the same line costs no request. */
		for (i = 0; i < 300; i = i + 1) begin
			ln = $unsigned($random(seed)) % 128;
			check_read(ln, 0);
			before = m_reqs;
			check_read(ln, 0);
			if (m_reqs != before) begin
				$display("FAIL atg_su_dcache: repeated read of line %0d missed", ln);
				err_h = err_h + 1;
			end
		end
		/* An error line answers with rsp_error. */
		req(1'b0, 27'd200, 0, 0);
		if (!gerr) begin
			$display("FAIL atg_su_dcache: no error response");
			err_h = err_h + 1;
		end
		/* wt: random writes and reads. */
		for (i = 0; i < 600; i = i + 1) begin
			ln = $unsigned($random(seed)) % 128;
			if ($random(seed) & 1)
				req(1'b1, ln, $random(seed), {8{$random(seed)}});
			else
				check_read(ln, 1);
		end
		for (i = 0; i < 1024; i = i + 1)
			if (mem.peek(4 * i) !== shadow[i]) begin
				if (err_w < 10)
					$display("FAIL atg_su_dcache: memory word %0d %h want %h", i,
						mem.peek(4 * i), shadow[i]);
				err_w = err_w + 1;
			end
		/* inv: change memory behind the cache. */
		for (i = 0; i < 40; i = i + 1) begin
			ln = $unsigned($random(seed)) % 32;
			check_read(ln, 2);
			shadow[ln * 8] = shadow[ln * 8] ^ 32'h00FF00FF;
			mem.poke(ln * 32, shadow[ln * 8]);
			req(1'b0, ln, 0, 0);
			if (got[31:0] === shadow[ln * 8]) begin
				$display("FAIL atg_su_dcache: line %0d not cached", ln);
				err_i = err_i + 1;
			end
			@(negedge clk);
			inv = 1'b1;
			@(negedge clk);
			inv = 1'b0;
			check_read(ln, 2);
		end
		if (err_h == 0) $display("PASS atg_su_dcache.hit");
		if (err_w == 0) $display("PASS atg_su_dcache.wt");
		if (err_i == 0) $display("PASS atg_su_dcache.inv");
		if (err_h + err_w + err_i == 0) $display("PASS atg_su_dcache");
		$finish;
	end

	initial begin
		#5000000;
		$display("FAIL atg_su_dcache timeout");
		$finish;
	end
endmodule

`default_nettype wire
