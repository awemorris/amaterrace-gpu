/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_cache_tb: atg_tu_cache with 32-byte and 64-byte (KC705)
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
 *   border border texels (ta_bord) are the border colour's raw texel
 *         for every format and colour class, mixed with fetched texels; a
 *         quad of border texels only makes no request; tc_bord is ta_bord
 *   h16   RGB565 (ctl[19]): the half word that address bit 1 selects, its
 *         border texels (0, 0, 0xFFFF)
 *   parts the slots of 8- and 16-byte texels without bilinear (ctl[26:25]),
 *         the half words and bytes of 2- and 1-byte texels (ctl[24:23])
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
	output reg [31:0] e_border,
	output reg [31:0] e_h16,
	output reg [31:0] e_parts,
	output reg [31:0] e_assoc,
	output reg [31:0] e_bank
);
	localparam LB = LINE_BYTES * 8;

	reg inv = 1'b0;
	reg ta_valid = 1'b0;
	reg [511:0] ta_addr = 0;
	reg [15:0] ta_bord = 0;
	reg [127:0] ta_wts = 0;
	reg [15:0] ta_tag = 0;
	reg [3:0] ta_mask = 0;
	reg [49:0] ta_ctl = 0;
	reg [127:0] ta_value = 0;
	reg ta_last = 1'b0;
	reg tc_ready = 1'b0;
	wire ta_ready, tc_valid, tc_last;
	wire [511:0] tc_texels;
	wire [15:0] tc_bord;
	wire [31:0] tc_lo;
	wire [127:0] tc_wts;
	wire [15:0] tc_tag;
	wire [3:0] tc_mask;
	wire [49:0] tc_ctl;
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
		.ta_valid(ta_valid), .ta_ready(ta_ready), .ta_addr(ta_addr), .ta_bord(ta_bord),
		.ta_wts(ta_wts), .ta_tag(ta_tag), .ta_mask(ta_mask), .ta_ctl(ta_ctl), .ta_value(ta_value),
		.ta_last(ta_last), .tc_valid(tc_valid), .tc_ready(tc_ready), .tc_texels(tc_texels),
		.tc_bord(tc_bord), .tc_lo(tc_lo), .tc_wts(tc_wts), .tc_tag(tc_tag), .tc_mask(tc_mask), .tc_ctl(tc_ctl),
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
		input [47:0] ctl;
		if (ctl[19])
			braw = ctl[7:6] == 2'd2 ? 32'h0000FFFF : 32'd0;
		else case ({ctl[8], ctl[1], ctl[7:6]})
		4'b0001, 4'b0101: braw = 32'hFF000000;
		4'b0010, 4'b0110: braw = 32'hFFFFFFFF;
		4'b1010: braw = 32'h00FFFFFF;
		4'b1110: braw = 32'h3F800000;
		default: braw = 32'd0;
		endcase
	endfunction

	/* The texel at address a: the word, or RGB565's half word. */
	function [31:0] texel;
		input [31:0] a;
		input [47:0] ctl;
		input [31:0] g;
		reg [31:0] wd;
		begin
			wd = memword(a & ~32'd3, g);
			texel = ctl[24:23] == 2'd2 ? {24'd0, wd[a[1:0]*8 +: 8]} :
				ctl[19] || ctl[24:23] == 2'd1 ? {16'd0, a[1] ? wd[31:16] : wd[15:0]} : wd;
		end
	endfunction

	task quad;
		input [511:0] addr;
		input [15:0] bord;
		input [3:0] mask;
		input [47:0] ctl;
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
					if (mask[l] && !ctl[2] && (t == 0 || ctl[0] || (t == 1 && ctl[26:25] != 2'd0) ||
					    ctl[26:25] == 2'd2) && bord[l*4+t])
						want[(l*4+t)*32 +: 32] = braw(ctl);
					else if (mask[l] && !ctl[2] && (t == 0 || ctl[0] ||
					    (t == 1 && ctl[26:25] != 2'd0) || ctl[26:25] == 2'd2) &&
					    addr[(l*4+t)*32 + 20 +: 12] != 12'h00E)
						want[(l*4+t)*32 +: 32] = texel(addr[(l*4+t)*32 +: 32], ctl, gen_seen);
			while (($random(seed) & 3) == 0)
				@(posedge clk);
			ta_valid <= 1'b1;
			ta_addr <= addr;
			ta_bord <= bord;
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
			for (l = 0; l < 16; l = l + 1)
				if (tc_lo[2*l +: 2] !== addr[32*l +: 2])
					errs = 1;
			if (!tc_valid || tc_texels !== want || tc_bord !== bord || tc_wts !== wts || tc_tag !== tag ||
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
	reg [15:0] b;
	reg [47:0] ctl;
	initial begin
		done = 1'b0;
		e_hit = 0;
		e_miss = 0;
		e_inv = 0;
		e_border = 0;
		e_h16 = 0;
		e_parts = 0;
		e_assoc = 0;
		e_bank = 0;
		gen_seen = 0;
		@(posedge rst_n);
		repeat (2) @(posedge clk);
		/* hit */
		for (k = 0; k < 20; k = k + 1) begin
			a = raddr(32'h4000, $random(seed));
			ctl = k[0] ? 48'h000001 : 48'h000002;
			quad(a, 16'd0, 4'hF, ctl, e);
			e_hit = e_hit + e;
			n0 = nreq;
			for (i = 0; i < 3; i = i + 1) begin
				quad(a, 16'd0, $random(seed), ctl, e);
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
			ctl = $random(seed) & 48'h000007;
			quad(a, 16'd0, $random(seed), ctl, e);
			e_miss = e_miss + e;
		end
		/* An error line is not kept. */
		a = {16{32'h00E00040}};
		quad(a, 16'd0, 4'h1, 48'h000000, e);
		e_miss = e_miss + e;
		n0 = nreq;
		quad(a, 16'd0, 4'h1, 48'h000000, e);
		e_miss = e_miss + e;
		if (nreq != n0 + 1) begin
			e_miss = e_miss + 1;
			$display("FAIL atg_tu_cache(%0d): error line kept", LINE_BYTES);
		end
		/* inv */
		for (k = 0; k < 10; k = k + 1) begin
			a = raddr(32'h1000, $random(seed));
			quad(a, 16'd0, 4'hF, 48'h000001, e);
			e_inv = e_inv + e;
			gen = gen + 1;
			quad(a, 16'd0, 4'hF, 48'h000001, e);	/* still the cached (old) data */
			e_inv = e_inv + e;
			gen_seen = gen;
			inv <= 1'b1;
			@(posedge clk);
			inv <= 1'b0;
			quad(a, 16'd0, 4'hF, 48'h000001, e);
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
				quad(a, 16'd0, 4'h1, 48'h000000, e);
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
			quad(a, 16'd0, 4'h1, 48'h000000, e);
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
			b = $random(seed);
			ctl = ($random(seed) & 48'h0001C3) | 48'h000001;
			quad(a, b, $random(seed), ctl, e);
			e_border = e_border + e;
		end
		for (k = 0; k < 20; k = k + 1) begin
			a = raddr(32'h10000, $random(seed));
			ctl = ($random(seed) & 48'h0001C3);
			n0 = nreq;
			quad(a, 16'hFFFF, 4'hF, ctl, e);
			e_border = e_border + e;
			if (nreq != n0) begin
				e_border = e_border + 1;
				$display("FAIL atg_tu_cache(%0d): a request for border texels", LINE_BYTES);
			end
		end
		/* h16: RGB565, half words and border texels. */
		for (k = 0; k < 200; k = k + 1) begin
			a = raddr(32'h4000, $random(seed));
			b = 16'd0;
			for (i = 0; i < 16; i = i + 1) begin
				a[i*32 + 1] = $random(seed);
				if (($random(seed) & 3) == 0)
					b[i] = 1'b1;
			end
			ctl = ($random(seed) & 48'h0000C1) | 48'h080000;
			quad(a, b, $random(seed), ctl, e);
			e_h16 = e_h16 + e;
		end
		/* parts: 8- and 16-byte texels' slots, 2- and 1-byte texels. */
		for (k = 0; k < 300; k = k + 1) begin
			a = raddr(32'h4000, $random(seed));
			b = 16'd0;
			for (i = 0; i < 16; i = i + 1) begin
				a[i*32 +: 2] = $random(seed);
				if (($random(seed) & 7) == 0)
					b[i] = 1'b1;
			end
			ctl = ($random(seed) & 48'h0000C1);
			case (k % 4)
			0: ctl = ctl | 48'h2000000 | 48'h800000;	/* 2 slots, a word */
			1: ctl = ctl | 48'h4000000;	/* 4 slots */
			2: ctl = ctl | 48'h800000;	/* 2-byte texels */
			default: ctl = ctl | 48'h1000000;	/* 1-byte texels */
			endcase
			if (k % 4 < 2)
				ctl = ctl & ~48'h800000;
			quad(a, b, $random(seed), ctl, e);
			e_parts = e_parts + e;
		end
		/* assoc: 4-way set-associativity and Tree-PLRU eviction */
		begin : b_assoc
			reg [31:0] set_stride;
			reg [31:0] l0, l1, l2, l3, l4;
			set_stride = 32'd2048;
			l0 = 32'h00002000;
			l1 = 32'h00002000 + set_stride;
			l2 = 32'h00002000 + 2 * set_stride;
			l3 = 32'h00002000 + 3 * set_stride;
			l4 = 32'h00002000 + 4 * set_stride;

			// Fill 4 lines of the same set
			a = {16{l0}}; quad(a, 16'd0, 4'h1, 48'h0, e); e_assoc = e_assoc + e;
			a = {16{l1}}; quad(a, 16'd0, 4'h1, 48'h0, e); e_assoc = e_assoc + e;
			a = {16{l2}}; quad(a, 16'd0, 4'h1, 48'h0, e); e_assoc = e_assoc + e;
			a = {16{l3}}; quad(a, 16'd0, 4'h1, 48'h0, e); e_assoc = e_assoc + e;

			// All 4 lines must hit
			n0 = nreq;
			a = {16{l0}}; quad(a, 16'd0, 4'h1, 48'h0, e); e_assoc = e_assoc + e;
			a = {16{l1}}; quad(a, 16'd0, 4'h1, 48'h0, e); e_assoc = e_assoc + e;
			a = {16{l2}}; quad(a, 16'd0, 4'h1, 48'h0, e); e_assoc = e_assoc + e;
			a = {16{l3}}; quad(a, 16'd0, 4'h1, 48'h0, e); e_assoc = e_assoc + e;
			if (nreq != n0) begin
				e_assoc = e_assoc + 1;
				$display("FAIL atg_tu_cache(%0d): 4-way lines not all cached", LINE_BYTES);
			end

			// Access l0, l1, l2 so l3 is least recently used
			a = {16{l0}}; quad(a, 16'd0, 4'h1, 48'h0, e);
			a = {16{l1}}; quad(a, 16'd0, 4'h1, 48'h0, e);
			a = {16{l2}}; quad(a, 16'd0, 4'h1, 48'h0, e);

			// Now bring in 5th line l4 (must evict l3 via PLRU)
			n0 = nreq;
			a = {16{l4}}; quad(a, 16'd0, 4'h1, 48'h0, e); e_assoc = e_assoc + e;
			if (nreq != n0 + 1) begin
				e_assoc = e_assoc + 1;
				$display("FAIL atg_tu_cache(%0d): 5th line did not miss as expected", LINE_BYTES);
			end

			// l0, l1, l2, l4 must all HIT
			n0 = nreq;
			a = {16{l0}}; quad(a, 16'd0, 4'h1, 48'h0, e); e_assoc = e_assoc + e;
			a = {16{l1}}; quad(a, 16'd0, 4'h1, 48'h0, e); e_assoc = e_assoc + e;
			a = {16{l2}}; quad(a, 16'd0, 4'h1, 48'h0, e); e_assoc = e_assoc + e;
			a = {16{l4}}; quad(a, 16'd0, 4'h1, 48'h0, e); e_assoc = e_assoc + e;
			if (nreq != n0) begin
				e_assoc = e_assoc + 1;
				$display("FAIL atg_tu_cache(%0d): PLRU survivors did not hit", LINE_BYTES);
			end

			// l3 was evicted, so accessing l3 MUST MISS
			n0 = nreq;
			a = {16{l3}}; quad(a, 16'd0, 4'h1, 48'h0, e); e_assoc = e_assoc + e;
			if (nreq != n0 + 1) begin
				e_assoc = e_assoc + 1;
				$display("FAIL atg_tu_cache(%0d): evicted line l3 did not miss", LINE_BYTES);
			end
		end
		/* bank: 4-bank concurrent read verification */
		begin : b_bank
			integer cyc;
			// Preload a 2x2 bilinear quad in lane 0 (slots 0..3)
			a = 512'd0;
			a[0*32 +: 32] = 32'h00003000;
			a[1*32 +: 32] = 32'h00003004;
			a[2*32 +: 32] = 32'h00003020;
			a[3*32 +: 32] = 32'h00003024;
			ctl = 48'h000001; // bilinear enabled
			quad(a, 16'd0, 4'h1, ctl, e); // warmup lines
			e_bank = e_bank + e;

			// Now measure cycle count on cached hit: 1 active lane with 4 slots
			ta_valid <= 1'b1;
			ta_addr <= a;
			ta_bord <= 16'd0;
			ta_mask <= 4'h1; // lane 0 only
			ta_ctl <= ctl;
			@(posedge clk);
			while (!ta_ready) @(posedge clk);
			ta_valid <= 1'b0;
			cyc = 0;
			while (!tc_valid && cyc < 100) begin
				@(posedge clk);
				cyc = cyc + 1;
			end
			tc_ready <= 1'b1;
			@(posedge clk);
			tc_ready <= 1'b0;
			// With 4 banks reading in parallel, 1 lane finishes in <= 6 cycles (not 16+ cycles!)
			if (cyc > 6) begin
				e_bank = e_bank + 1;
				$display("FAIL atg_tu_cache(%0d): 4-bank parallel read took %0d cycles (expected <= 6)",
					LINE_BYTES, cyc);
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
	wire [31:0] h32, m32, i32, b32, h64, m64, i64, b64, s32, s64, p32, p64, a32, a64, k32, k64;
	atg_tu_cache_run #(.LINE_BYTES(32), .LINE_SHIFT(5), .SEED(11)) r32 (
		.clk(clk), .rst_n(rst_n), .done(d32), .e_hit(h32), .e_miss(m32), .e_inv(i32),
		.e_border(b32), .e_h16(s32), .e_parts(p32), .e_assoc(a32), .e_bank(k32));
	atg_tu_cache_run #(.LINE_BYTES(64), .LINE_SHIFT(6), .SEED(12)) r64 (
		.clk(clk), .rst_n(rst_n), .done(d64), .e_hit(h64), .e_miss(m64), .e_inv(i64),
		.e_border(b64), .e_h16(s64), .e_parts(p64), .e_assoc(a64), .e_bank(k64));

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
		if (s32 == 0 && s64 == 0)
			$display("PASS atg_tu_cache.h16");
		if (p32 == 0 && p64 == 0)
			$display("PASS atg_tu_cache.parts");
		if (a32 == 0 && a64 == 0)
			$display("PASS atg_tu_cache.assoc");
		if (k32 == 0 && k64 == 0)
			$display("PASS atg_tu_cache.bank");
		if (h32 + h64 + m32 + m64 + i32 + i64 + b32 + b64 + s32 + s64 + p32 + p64 + a32 + a64 + k32 + k64 == 0)
			$display("PASS atg_tu_cache");
		else
			$display("FAIL atg_tu_cache: %0d %0d %0d %0d / %0d %0d %0d %0d / %0d %0d", h32, m32, i32, b32,
				h64, m64, i64, b64, a32 + a64, k32 + k64);
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL atg_tu_cache: timeout");
		$finish;
	end
endmodule

`default_nettype wire
