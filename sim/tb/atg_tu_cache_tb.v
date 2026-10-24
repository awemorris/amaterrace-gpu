/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_cache_tb: atg_tu_cache with 32-byte (ZYBO) and 64-byte (KC705)
 * lines against a memory model on its AMB port (random request accept,
 * random response latency, one error region: 0x00E00000-0x00EFFFFF).
 * Each quad's texels must be the memory's words at its addresses (only
 * the ta_mask lanes, only texel 0 without bilinear, nothing for texsz, 0
 * after an error), the other fields passed through, in order.
 *   hit   a quad repeated: no request after its first pass
 *   miss  random quads over 64 KiB (conflicts), every ctl, errors (an error
 *         line is not kept: it is requested again)
 *   inv   cached lines keep their old data after memory changes, inv drops
 *         them; inv while a miss is outstanding
 *   border border texels (address bit 0) are the border colour's raw texel
 *         for every format and colour class, mixed with fetched texels; a
 *         quad of border texels only makes no request
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_cache_run #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	output reg done,
	output reg [31:0] e_hit,
	output reg [31:0] e_miss,
	output reg [31:0] e_inv,
	output reg [31:0] e_border
);
	localparam LB = LINE_BYTES * 8;

	reg inv = 1'b0;
	reg ta_valid = 1'b0;
	reg [511:0] ta_addr = 0;
	reg [127:0] ta_wts = 0;
	reg [15:0] ta_tag = 0;
	reg [3:0] ta_mask = 0;
	reg [23:0] ta_ctl = 0;
	reg [127:0] ta_value = 0;
	reg ta_last = 1'b0;
	reg tc_ready = 1'b0;
	wire ta_ready, tc_valid, tc_last;
	wire [511:0] tc_texels;
	wire [127:0] tc_wts;
	wire [15:0] tc_tag;
	wire [3:0] tc_mask;
	wire [23:0] tc_ctl;
	wire [127:0] tc_value;
	wire req_valid, req_write;
	reg req_ready = 1'b0;
	wire [31-LINE_SHIFT:0] req_line;
	wire [LINE_BYTES-1:0] req_be;
	wire [LB-1:0] req_wdata;
	wire [7:0] req_tag;
	reg rsp_valid = 1'b0;
	reg rsp_error = 1'b0;
	reg [LB-1:0] rsp_rdata = 0;

	atg_tu_cache #(.ADDR_W(32), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) dut (
		.clk(clk), .rst_n(rst_n), .inv(inv),
		.ta_valid(ta_valid), .ta_ready(ta_ready), .ta_addr(ta_addr), .ta_wts(ta_wts),
		.ta_tag(ta_tag), .ta_mask(ta_mask), .ta_ctl(ta_ctl), .ta_value(ta_value),
		.ta_last(ta_last), .tc_valid(tc_valid), .tc_ready(tc_ready), .tc_texels(tc_texels),
		.tc_wts(tc_wts), .tc_tag(tc_tag), .tc_mask(tc_mask), .tc_ctl(tc_ctl),
		.tc_value(tc_value), .tc_last(tc_last),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(1'b0), .rsp_tag(8'd0), .rsp_rdata(rsp_rdata),
		.rsp_error(rsp_error)
	);

	integer seed = SEED;
	integer nreq = 0;
	reg [31:0] gen = 0;	/* memory generation of the region below 0x1000 */

	function [31:0] memword;
		input [31:0] a;
		input [31:0] g;
		memword = (a[31:2] * 32'h9E3779B1) ^ (a < 32'h1000 ? g * 32'h01000193 : 32'd0);
	endfunction

	/* The memory: one request at a time (the cache has one outstanding). */
	reg [31:0] la;
	reg [LB-1:0] line;
	integer d, w;
	always @(posedge clk) begin
		req_ready <= ($random(seed) & 1) == 0;
		rsp_valid <= 1'b0;
		if (req_valid && req_ready) begin
			nreq = nreq + 1;
			la = {req_line, {LINE_SHIFT{1'b0}}};
			if (req_write)
				$display("FAIL atg_tu_cache: a write request");
			/* the data as memory holds it when the request is taken */
			for (w = 0; w < LINE_BYTES / 4; w = w + 1)
				line[w*32 +: 32] = memword(la + w * 4, gen);
			d = $random(seed) & 15;
			repeat (d) @(posedge clk);
			rsp_rdata <= line;
			rsp_error <= la[31:20] == 12'h00E;
			rsp_valid <= 1'b1;
		end
	end

	reg [31:0] gen_seen;	/* the generation the expected texels use */

	/* The border texel by format ({ctl[8], ctl[1]}) and class (ctl[7:6]). */
	function [31:0] braw;
		input [23:0] ctl;
		case ({ctl[8], ctl[1], ctl[7:6]})
		4'b0001, 4'b0101: braw = 32'hFF000000;
		4'b0010, 4'b0110: braw = 32'hFFFFFFFF;
		4'b1010: braw = 32'h00FFFFFF;
		4'b1110: braw = 32'h3F800000;
		default: braw = 32'd0;
		endcase
	endfunction

	task quad;
		input [511:0] addr;
		input [3:0] mask;
		input [23:0] ctl;
		output integer errs;
		reg [511:0] want;
		reg [127:0] wts;
		reg [15:0] tag;
		reg [127:0] val;
		reg last;
		integer l, t, n;
		begin
			errs = 0;
			wts = {$random(seed), $random(seed), $random(seed), $random(seed)};
			tag = $random(seed);
			val = {4{$random(seed)}};
			last = $random(seed);
			want = 512'd0;
			for (l = 0; l < 4; l = l + 1)
				for (t = 0; t < 4; t = t + 1)
					if (mask[l] && !ctl[2] && (t == 0 || ctl[0]) && addr[(l*4+t)*32])
						want[(l*4+t)*32 +: 32] = braw(ctl);
					else if (mask[l] && !ctl[2] && (t == 0 || ctl[0]) &&
					    addr[(l*4+t)*32 + 20 +: 12] != 12'h00E)
						want[(l*4+t)*32 +: 32] = memword(addr[(l*4+t)*32 +: 32] & ~32'd3, gen_seen);
			while (($random(seed) & 3) == 0)
				@(posedge clk);
			ta_valid <= 1'b1;
			ta_addr <= addr;
			ta_wts <= wts;
			ta_tag <= tag;
			ta_mask <= mask;
			ta_ctl <= ctl;
			ta_value <= val;
			ta_last <= last;
			@(posedge clk);
			while (!ta_ready)
				@(posedge clk);
			ta_valid <= 1'b0;
			ta_addr <= {16{$random(seed)}};
			n = 0;
			while (!tc_valid && n < 5000) begin
				@(posedge clk);
				n = n + 1;
			end
			while (($random(seed) & 3) == 0)
				@(posedge clk);
			if (!tc_valid || tc_texels !== want || tc_wts !== wts || tc_tag !== tag ||
			    tc_mask !== mask || tc_ctl !== ctl || tc_value !== val || tc_last !== last) begin
				errs = 1;
				$display("FAIL atg_tu_cache(%0d): valid %b texels %h, want %h", LINE_BYTES,
					tc_valid, tc_texels, want);
			end
			tc_ready <= 1'b1;
			@(posedge clk);
			tc_ready <= 1'b0;
		end
	endtask

	function [511:0] raddr;
		input [31:0] span;
		input [31:0] r0;
		integer i;
		reg [31:0] base;
		begin
			base = r0 % span;
			for (i = 0; i < 16; i = i + 1)
				raddr[i*32 +: 32] = ((base + ($random(seed) & 32'hFF)) % span) & ~32'd3;
		end
	endfunction

	integer i, k, e, n0;
	reg [511:0] a;
	reg [23:0] ctl;
	initial begin
		done = 1'b0;
		e_hit = 0;
		e_miss = 0;
		e_inv = 0;
		e_border = 0;
		gen_seen = 0;
		@(posedge rst_n);
		repeat (2) @(posedge clk);
		/* hit */
		for (k = 0; k < 20; k = k + 1) begin
			a = raddr(32'h4000, $random(seed));
			ctl = k[0] ? 24'h000001 : 24'h000002;
			quad(a, 4'hF, ctl, e);
			e_hit = e_hit + e;
			n0 = nreq;
			for (i = 0; i < 3; i = i + 1) begin
				quad(a, $random(seed), ctl, e);
				e_hit = e_hit + e;
			end
			if (nreq != n0) begin
				e_hit = e_hit + 1;
				$display("FAIL atg_tu_cache(%0d): %0d requests for a cached quad", LINE_BYTES,
					nreq - n0);
			end
		end
		/* miss */
		for (k = 0; k < 400; k = k + 1) begin
			a = raddr(32'h10000, $random(seed));
			if (k % 7 == 3)
				for (i = 0; i < 16; i = i + 1)
					if ($random(seed) & 1)
						a[i*32 +: 32] = 32'h00E00000 | (a[i*32 +: 32] & 32'hFFFF);
			ctl = $random(seed) & 24'h000007;
			quad(a, $random(seed), ctl, e);
			e_miss = e_miss + e;
		end
		/* An error line is not kept. */
		a = {16{32'h00E00040}};
		quad(a, 4'h1, 24'h000000, e);
		e_miss = e_miss + e;
		n0 = nreq;
		quad(a, 4'h1, 24'h000000, e);
		e_miss = e_miss + e;
		if (nreq != n0 + 1) begin
			e_miss = e_miss + 1;
			$display("FAIL atg_tu_cache(%0d): error line kept", LINE_BYTES);
		end
		/* inv */
		for (k = 0; k < 10; k = k + 1) begin
			a = raddr(32'h1000, $random(seed));
			quad(a, 4'hF, 24'h000001, e);
			e_inv = e_inv + e;
			gen = gen + 1;
			quad(a, 4'hF, 24'h000001, e);	/* still the cached (old) data */
			e_inv = e_inv + e;
			gen_seen = gen;
			inv <= 1'b1;
			@(posedge clk);
			inv <= 1'b0;
			quad(a, 4'hF, 24'h000001, e);
			e_inv = e_inv + e;
		end
		/* inv while a miss is outstanding (and memory changed): the line
		 * is not kept but fetched again. */
		inv <= 1'b1;
		@(posedge clk);
		inv <= 1'b0;
		for (k = 0; k < 10; k = k + 1) begin
			a = {16{32'h00000800 + k * 32'h40}};
			gen_seen = gen + 1;
			fork
				quad(a, 4'h1, 24'h000000, e);
				begin
					while (!(req_valid && req_ready))
						@(posedge clk);
					gen = gen + 1;
					inv <= 1'b1;
					@(posedge clk);
					inv <= 1'b0;
				end
			join
			e_inv = e_inv + e;
			n0 = nreq;
			quad(a, 4'h1, 24'h000000, e);
			e_inv = e_inv + e;
			if (nreq != n0) begin
				e_inv = e_inv + 1;
				$display("FAIL atg_tu_cache(%0d): refetched line not kept", LINE_BYTES);
			end
		end
		/* border: random border texels among fetched ones, every format
		 * and class; then quads of border texels only. */
		for (k = 0; k < 200; k = k + 1) begin
			a = raddr(32'h4000, $random(seed));
			for (i = 0; i < 16; i = i + 1)
				if ($random(seed) & 1)
					a[i*32] = 1'b1;
			ctl = ($random(seed) & 24'h0001C3) | 24'h000001;
			quad(a, $random(seed), ctl, e);
			e_border = e_border + e;
		end
		for (k = 0; k < 20; k = k + 1) begin
			a = raddr(32'h10000, $random(seed)) | {16{32'h00000001}};
			ctl = ($random(seed) & 24'h0001C3);
			n0 = nreq;
			quad(a, 4'hF, ctl, e);
			e_border = e_border + e;
			if (nreq != n0) begin
				e_border = e_border + 1;
				$display("FAIL atg_tu_cache(%0d): a request for border texels", LINE_BYTES);
			end
		end
		done = 1'b1;
	end
endmodule

module atg_tu_cache_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	wire d32, d64;
	wire [31:0] h32, m32, i32, b32, h64, m64, i64, b64;
	atg_tu_cache_run #(.LINE_BYTES(32), .LINE_SHIFT(5), .SEED(11)) r32 (
		.clk(clk), .rst_n(rst_n), .done(d32), .e_hit(h32), .e_miss(m32), .e_inv(i32),
		.e_border(b32));
	atg_tu_cache_run #(.LINE_BYTES(64), .LINE_SHIFT(6), .SEED(12)) r64 (
		.clk(clk), .rst_n(rst_n), .done(d64), .e_hit(h64), .e_miss(m64), .e_inv(i64),
		.e_border(b64));

	initial begin
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		wait (d32 && d64);
		if (h32 == 0 && h64 == 0)
			$display("PASS atg_tu_cache.hit");
		if (m32 == 0 && m64 == 0)
			$display("PASS atg_tu_cache.miss");
		if (i32 == 0 && i64 == 0)
			$display("PASS atg_tu_cache.inv");
		if (b32 == 0 && b64 == 0)
			$display("PASS atg_tu_cache.border");
		if (h32 + h64 + m32 + m64 + i32 + i64 + b32 + b64 == 0)
			$display("PASS atg_tu_cache");
		else
			$display("FAIL atg_tu_cache: %0d %0d %0d %0d / %0d %0d %0d %0d", h32, m32, i32, b32,
				h64, m64, i64, b64);
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL atg_tu_cache: timeout");
		$finish;
	end
endmodule

`default_nettype wire
