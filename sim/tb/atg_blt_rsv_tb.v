/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_rsv_tb: the blitter's RESOLVE (atg_blt with MS4, so through the
 * wrapper and atg_blt_rsv, atg_blt_rsv_px, atg_blt_avg) against a reference
 * model written here from docs/ghci.md section 8.2, in the two line sizes
 * at once (atg_blt_rsv_tbc LINE_BYTES 32 and 64), and the wrapper without
 * MS4.  Each instance has its own memory behind the AMB port (in order,
 * random latency and ready, error responses at and above 0x8000; a stream
 * mode with latency 1 and ready always 1), filled with random bytes; after
 * each case the whole memory is compared with the model's.  Prints, when
 * both line sizes pass:
 *
 *   PASS atg_blt_rsv.unorm8    UNORM8, 32-bit pixels, aligned
 *   PASS atg_blt_rsv.rgb565    UNORM565, 16-bit pixels
 *   PASS atg_blt_rsv.sample0   SAMPLE0, both pixel sizes
 *   PASS atg_blt_rsv.offset    source and destination x of other
 *                              alignments, strides not of whole lines
 *   PASS atg_blt_rsv.tiled     4x4 tiled destination, both pixel sizes
 *   PASS atg_blt_rsv.clip      the clip rectangle
 *   PASS atg_blt_rsv.rowshare  rows sharing source and destination lines
 *   PASS atg_blt_rsv.random    random cases (+seed)
 *   PASS atg_blt_rsv.stream    latency 1, ready 1: at most 7 cycles per
 *                              destination line (4x, 32-bit, aligned); and
 *                              latency 40 with the port blocked half the
 *                              time: the source line FIFO never overflows
 *   PASS atg_blt_rsv.fault     every refused combination: kind 2, busy 0,
 *                              no request; an error response: kind 5 after
 *                              the drain, then a normal resolve is right
 *   PASS atg_blt_rsv.2d        FILL, RESOLVE, COPY, RESOLVE in turn through
 *                              the wrapper
 *   PASS atg_blt_rsv.halt      ready held at 0 for 300 cycles in the middle
 *   PASS atg_blt_rsv.nms4      without MS4: RESOLVE is kind 2, FILL works
 *   PASS atg_blt_rsv
 *
 * Mutations (iverilog -D): MUT_RSV_RNE (unorm8, rgb565, random fail),
 * MUT_RSV_SPLIT (offset, random), MUT_RSV_ROWEND (rowshare, random),
 * MUT_RSV_CREDIT (no read credit: a FIFO overflow in stream), MUT_RSV_RSP (2d).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_rsv_tbc #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter MS4 = 1,
	parameter SEED0 = 1
) (
	input wire clk,
	input wire rst_n,
	input wire start,
	output reg fin
);
	`include "ghci_regs.vh"

	localparam LB = LINE_BYTES;
	localparam LBITS = LINE_BYTES * 8;
	localparam LA_W = 32 - LINE_SHIFT;
	localparam MEMB = 32768;
	localparam NT = 13;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 9'd0;
	reg [31:0] st_wdata = 32'd0;
	reg kick = 1'b0;
	wire busy, done, error;
	wire [3:0] error_kind;
	wire req_valid, req_write;
	reg req_ready = 1'b0;
	wire [LA_W-1:0] req_line;
	wire [LB-1:0] req_be;
	wire [LBITS-1:0] req_wdata;
	wire [7:0] req_tag;
	reg rsp_valid = 1'b0, rsp_write = 1'b0, rsp_error = 1'b0;
	reg [7:0] rsp_tag = 8'd0;
	reg [LBITS-1:0] rsp_rdata = {LBITS{1'b0}};

	atg_blt #(.ADDR_W(32), .LINE_BYTES(LB), .LINE_SHIFT(LINE_SHIFT), .MS4(MS4)) dut (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.kick(kick), .busy(busy), .done(done), .error(error), .error_kind(error_kind),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));

	/* ------------------------------------------------ the memory */
	reg [7:0] mem [0:MEMB-1];
	reg [7:0] rmem [0:MEMB-1];
	reg stream = 1'b0;
	reg hold = 1'b0;
	integer seed;
	integer cyc = 0;
	integer nreq = 0;
	reg pq_w [0:63];
	reg [7:0] pq_tag [0:63];
	reg [LA_W-1:0] pq_line [0:63];
	reg [LB-1:0] pq_be [0:63];
	reg [LBITS-1:0] pq_wd [0:63];
	integer pq_due [0:63];
	integer pq_h = 0, pq_t = 0;
	integer burst = 0;
	integer lat_fix = 0;
	reg pulse_hold = 1'b0;
	integer i, b, a;

	always @(posedge clk) begin
		cyc <= cyc + 1;
		rsp_valid <= 1'b0;
		if (req_valid && req_ready) begin
			pq_w[pq_t % 64] = req_write;
			pq_tag[pq_t % 64] = req_tag;
			pq_line[pq_t % 64] = req_line;
			pq_be[pq_t % 64] = req_be;
			pq_wd[pq_t % 64] = req_wdata;
			pq_due[pq_t % 64] = cyc + (lat_fix ? lat_fix : stream ? 1 : 1 + ($random(seed) & 15));
			pq_t = pq_t + 1;
			nreq = nreq + 1;
		end
		if (pq_h != pq_t && cyc >= pq_due[pq_h % 64]) begin
			a = pq_line[pq_h % 64] * LB;
			rsp_valid <= 1'b1;
			rsp_write <= pq_w[pq_h % 64];
			rsp_tag <= pq_tag[pq_h % 64];
			rsp_error <= a >= MEMB;
			for (b = 0; b < LB; b = b + 1) begin
				if (a < MEMB && pq_w[pq_h % 64] && pq_be[pq_h % 64][b])
					mem[a + b] = pq_wd[pq_h % 64][8 * b +: 8];
				rsp_rdata[8 * b +: 8] <= a < MEMB ? mem[a + b] : 8'hxx;
			end
			pq_h = pq_h + 1;
		end
		/* ready: random, with bursts of 10-73 cycles at 0 (not in stream) */
		if (burst > 0)
			burst = burst - 1;
		else if (!stream && ($random(seed) & 127) == 0)
			burst = 10 + ($random(seed) & 63);
		req_ready <= !hold && burst == 0 && !(pulse_hold && cyc % 96 >= 48) &&
			(stream || ($random(seed) & 3) != 0);
	end

	/* The source line FIFO never overflows (the read credit). */
	generate
		if (MS4 != 0) begin : g_mon
			always @(posedge clk)
				if (dut.g_rsv.rsv.px.ln_push && !dut.g_rsv.rsv.px.lq_ready) begin
					errs[tn] = errs[tn] + 1;
					$display("FAIL atg_blt_rsv LB %0d test %0d: a line pushed into a full FIFO",
						LB, tn);
				end
		end
	endgenerate

	/* ------------------------------------------------ helpers */
	task st;
		input [8:0] idx;
		input [31:0] v;
		begin
			@(posedge clk);
			st_we <= 1'b1;
			st_idx <= idx;
			st_wdata <= v;
			@(posedge clk);
			st_we <= 1'b0;
		end
	endtask

	/* Kick and wait: ok = done (1) or error (0, its kind in ekind). */
	reg ok;
	reg [3:0] ekind;
	integer t0, tcy;
	task run;
		integer n;
		begin
			@(posedge clk);
			kick <= 1'b1;
			@(posedge clk);
			kick <= 1'b0;
			t0 = cyc;
			n = 0;
			ok = 1'bx;
			while (ok === 1'bx && n < 60000) begin
				@(posedge clk);
				if (done)
					ok = 1'b1;
				if (error) begin
					ok = 1'b0;
					ekind = error_kind;
				end
				n = n + 1;
			end
			tcy = cyc - t0;
			if (ok === 1'bx) begin
				$display("FAIL atg_blt_rsv LB %0d: timeout", LB);
				ok = 1'b0;
				ekind = 4'hF;
			end
		end
	endtask

	integer errs [0:NT-1];
	integer tn;

	task fail_msg;
		input [8*40-1:0] what;
		begin
			errs[tn] = errs[tn] + 1;
			if (errs[tn] < 4)
				$display("FAIL atg_blt_rsv LB %0d test %0d: %0s", LB, tn, what);
		end
	endtask

	task compare;
		integer k, nd;
		begin
			nd = 0;
			for (k = 0; k < MEMB; k = k + 1)
				if (mem[k] !== rmem[k]) begin
					if (nd < 3)
						$display("FAIL atg_blt_rsv LB %0d test %0d: byte %h is %h, want %h",
							LB, tn, k, mem[k], rmem[k]);
					nd = nd + 1;
				end
			if (nd) begin
				errs[tn] = errs[tn] + 1;
				for (k = 0; k < MEMB; k = k + 1)
					rmem[k] = mem[k];
			end
		end
	endtask

	task fill_random;
		integer k;
		begin
			for (k = 0; k < MEMB; k = k + 1) begin
				mem[k] = $random(seed);
				rmem[k] = mem[k];
			end
		end
	endtask

	/* The reference RESOLVE on ref (which equals mem at the start). */
	function [7:0] rne4;
		input integer sum;
		integer q, r;
		begin
			q = sum / 4;
			r = sum % 4;
			rne4 = q + ((r > 2 || (r == 2 && q % 2 == 1)) ? 1 : 0);
		end
	endfunction

	reg [31:0] c_dbase, c_dstride, c_sbase, c_sstride;
	integer c_dx, c_dy, c_sx, c_sy, c_w, c_h, c_ps, c_fmt, c_tiled;
	integer c_cx0, c_cy0, c_cx1, c_cy1;

	task ref_resolve;
		integer x, y, s, k, sum, x0, y0, x1, y1, sxx, syy, da, sa, v, f;
		reg [15:0] hv;
		reg [15:0] px;
		begin
			x0 = c_dx; y0 = c_dy; x1 = c_dx + c_w; y1 = c_dy + c_h;
			if (c_cx1 != 0 || c_cy1 != 0) begin
				if (c_cx0 > x0) x0 = c_cx0;
				if (c_cy0 > y0) y0 = c_cy0;
				if (c_cx1 < x1) x1 = c_cx1;
				if (c_cy1 < y1) y1 = c_cy1;
			end
			for (y = y0; y < y1; y = y + 1)
				for (x = x0; x < x1; x = x + 1) begin
					sxx = c_sx + (x - c_dx);
					syy = c_sy + (y - c_dy);
					sa = c_sbase + syy * c_sstride + sxx * 4 * c_ps;
					if (c_tiled)
						da = c_dbase + (y / 4) * c_dstride + (x / 4) * 16 * c_ps +
							((y % 4) * 4 + x % 4) * c_ps;
					else
						da = c_dbase + y * c_dstride + x * c_ps;
					if (c_fmt == 2) begin
						for (k = 0; k < c_ps; k = k + 1)
							rmem[da + k] = rmem[sa + k];
					end else if (c_fmt == 1) begin
						px = 16'd0;
						for (f = 0; f < 3; f = f + 1) begin
							sum = 0;
							for (s = 0; s < 4; s = s + 1) begin
								hv = {rmem[sa + 2 * s + 1], rmem[sa + 2 * s]};
								v = f == 0 ? hv[4:0] : f == 1 ? hv[10:5] : hv[15:11];
								sum = sum + v;
							end
							v = rne4(sum);
							if (f == 0) px[4:0] = v;
							else if (f == 1) px[10:5] = v;
							else px[15:11] = v;
						end
						rmem[da] = px[7:0];
						rmem[da + 1] = px[15:8];
					end else begin
						for (k = 0; k < c_ps; k = k + 1) begin
							sum = 0;
							for (s = 0; s < 4; s = s + 1)
								sum = sum + rmem[sa + s * c_ps + k];
							rmem[da + k] = rne4(sum);
						end
					end
				end
		end
	endtask

	/* Write the BLT state of the case and run it. */
	task do_case;
		input check;
		begin
			st(GHCI_S_BLT_OP, {19'd0, 3'd0, (c_ps == 2) ? 2'd1 : 2'd0, 5'd0, 3'd4});
			st(GHCI_S_BLT_DST_BASE, c_dbase);
			st(GHCI_S_BLT_DST_STRIDE, c_dstride);
			st(GHCI_S_BLT_SRC_BASE, c_sbase);
			st(GHCI_S_BLT_SRC_STRIDE, c_sstride);
			st(GHCI_S_BLT_DST_XY, {c_dy[15:0], c_dx[15:0]});
			st(GHCI_S_BLT_SRC_XY, {c_sy[15:0], c_sx[15:0]});
			st(GHCI_S_BLT_SIZE, {c_h[15:0], c_w[15:0]});
			st(GHCI_S_BLT_CLIP_MIN, {c_cy0[15:0], c_cx0[15:0]});
			st(GHCI_S_BLT_CLIP_MAX, {c_cy1[15:0], c_cx1[15:0]});
			st(GHCI_S_BLT_RESOLVE, {23'd0, c_tiled[0], c_fmt[3:0], 4'd2});
			run;
			if (check) begin
				if (ok !== 1'b1)
					fail_msg("no done");
				ref_resolve;
				compare;
			end
		end
	endtask

	/* A case with the given shape; the strides and bases are derived. */
	task mk;
		input integer ps, fmt, tiled, sx, sy, dx, dy, w, h, sxtra, dxtra;
		integer wp;
		begin
			c_ps = ps; c_fmt = fmt; c_tiled = tiled;
			c_sx = sx; c_sy = sy; c_dx = dx; c_dy = dy; c_w = w; c_h = h;
			c_cx0 = 0; c_cy0 = 0; c_cx1 = 0; c_cy1 = 0;
			wp = sx + w;
			wp = wp + (wp % 2);
			c_sbase = 32'h0400 + 64 * ($random(seed) & 7);
			c_sstride = (wp + 2 * sxtra) * 4 * ps;
			if (tiled) begin
				c_dbase = 32'h5000 + 16 * ps * ($random(seed) & 7);
				c_dstride = (((dx + w + 3) / 4) + dxtra) * 16 * ps;
			end else begin
				c_dbase = 32'h5000 + ps * ($random(seed) & 31);
				c_dstride = (dx + w + dxtra) * ps;
			end
		end
	endtask

	integer k, n, lines;

	initial begin
		fin = 1'b0;
		seed = SEED0;
		for (k = 0; k < NT; k = k + 1)
			errs[k] = 0;
		@(posedge start);
		repeat (4) @(posedge clk);
		fill_random;

		if (MS4 != 0) begin
		/* 0 unorm8 */
		tn = 0;
		mk(4, 0, 0, 0, 0, 0, 0, 16, 4, 0, 0);
		c_dbase = 32'h5000;
		do_case(1);
		mk(4, 0, 0, 0, 0, 0, 0, 13, 5, 0, 3);
		do_case(1);
		/* 1 rgb565 */
		tn = 1;
		mk(2, 1, 0, 0, 0, 0, 0, 32, 3, 0, 0);
		do_case(1);
		mk(2, 1, 0, 3, 1, 5, 2, 21, 4, 1, 2);
		do_case(1);
		/* 2 sample0 */
		tn = 2;
		mk(4, 2, 0, 1, 0, 2, 1, 11, 3, 0, 1);
		do_case(1);
		mk(2, 2, 0, 0, 2, 7, 0, 19, 3, 1, 0);
		do_case(1);
		mk(2, 0, 0, 2, 0, 1, 0, 17, 2, 0, 0);	/* UNORM8 of 16-bit pixels */
		do_case(1);
		/* 3 offset */
		tn = 3;
		for (k = 0; k < 8; k = k + 1) begin
			mk(k % 2 ? 2 : 4, k % 2 ? 1 : 0, 0, k, k % 3, 7 - k, 1, 9 + k, 3, k % 2, k);
			do_case(1);
		end
		/* 4 tiled */
		tn = 4;
		for (k = 0; k < 6; k = k + 1) begin
			mk(k % 2 ? 2 : 4, k % 3 == 2 ? 2 : (k % 2), 1, k, k % 2, k + 1, k, 7 + 2 * k, 6, 0,
				k % 2);
			do_case(1);
		end
		/* 5 clip */
		tn = 5;
		for (k = 0; k < 4; k = k + 1) begin
			mk(4, 0, k % 2, 2, 1, 3, 2, 18, 6, 0, 1);
			c_cx0 = 4 + k; c_cy0 = 3; c_cx1 = 15 - k; c_cy1 = 7;
			do_case(1);
		end
		mk(4, 0, 0, 0, 0, 3, 2, 10, 4, 0, 0);
		c_cx0 = 20; c_cy0 = 0; c_cx1 = 30; c_cy1 = 20;	/* clipped away */
		n = nreq;
		do_case(1);
		if (nreq != n)
			fail_msg("empty clip made requests");
		/* 6 rowshare: strides below a line */
		tn = 6;
		mk(4, 0, 0, 0, 0, 0, 0, 2, 6, 0, 0);	/* P = 32 */
		do_case(1);
		mk(2, 1, 0, 1, 0, 0, 0, 1, 7, 0, 1);	/* P = 16, dst stride 4 */
		do_case(1);
		mk(4, 2, 0, 1, 1, 3, 1, 3, 5, 0, 0);
		do_case(1);
		/* 7 random */
		tn = 7;
		for (k = 0; k < 60; k = k + 1) begin
			n = $random(seed) & 1;
			mk(n ? 2 : 4, n ? ($random(seed) & 1) + (($random(seed) & 3) == 0) : 2 * ($random(seed) & 1),
				$random(seed) & 1, $random(seed) & 7, $random(seed) & 3, $random(seed) & 15,
				$random(seed) & 7, 1 + ($random(seed) & 15), 1 + ($random(seed) & 3),
				$random(seed) & 1, $random(seed) & 7);
			if (($random(seed) & 3) == 0) begin
				c_cx0 = $random(seed) & 15; c_cy0 = $random(seed) & 7;
				c_cx1 = c_cx0 + 1 + ($random(seed) & 15); c_cy1 = c_cy0 + 1 + ($random(seed) & 7);
			end
			do_case(1);
		end
		/* 8 stream */
		tn = 8;
		stream = 1'b1;
		mk(4, 0, 0, 0, 0, 0, 0, 64, 16, 0, 0);
		c_sbase = 32'h0400;
		c_dbase = 32'h5000;
		do_case(1);
		lines = 64 * 16 * 4 / LB;
		if (tcy > 7 * lines)
			fail_msg("slower than 7 cycles per line");
		$display("atg_blt_rsv LB %0d: stream %0d cycles for %0d destination lines", LB, tcy,
			lines);
		$display("PASS atg_blt_rsv(%0d).quad_resolve: 256 quads (1024 pixels) in %0d cycles",
			LB, tcy);
		/* the credit: long latency (the reads in flight reach the
		 * credit) and the port blocked half of the time (atg_blt_rsv_px
		 * stalls on its write with its window full) */
		lat_fix = 40;
		pulse_hold = 1'b1;
		mk(4, 0, 0, 0, 0, 0, 0, 64, 12, 0, 0);
		do_case(1);
		mk(2, 1, 0, 0, 0, 0, 0, 64, 12, 0, 0);
		do_case(1);
		lat_fix = 0;
		pulse_hold = 1'b0;
		stream = 1'b0;
		/* 9 fault */
		tn = 9;
		mk(4, 0, 0, 0, 0, 0, 0, 4, 2, 0, 0);
		for (k = 0; k < 7; k = k + 1) begin
			n = nreq;
			st(GHCI_S_BLT_OP, k == 0 ? 32'h5 : k == 1 ? 32'h14 : k == 2 ? 32'h1004 :
				k == 3 ? 32'h204 : 32'h4);
			st(GHCI_S_BLT_RESOLVE, k == 4 ? 32'h1 : k == 5 ? 32'h82 : k == 6 ? 32'h12 : 32'h2);
			run;
			if (ok !== 1'b0 || ekind != GHCI_FAULT_OPCODE || nreq != n)
				fail_msg("refused combination");
		end
		mk(4, 0, 0, 0, 0, 0, 0, 16, 2, 0, 0);
		c_sbase = 32'h7F00;	/* runs past the end: error responses */
		do_case(0);
		if (ok !== 1'b0 || ekind != GHCI_FAULT_AXI)
			fail_msg("no AXI error");
		for (k = 0; k < MEMB; k = k + 1)
			rmem[k] = mem[k];
		mk(4, 0, 0, 1, 0, 2, 0, 9, 3, 0, 0);
		do_case(1);
		end

		/* 10 2d (and nms4 without MS4): FILL, RESOLVE, COPY, RESOLVE */
		tn = MS4 ? 10 : 12;
		st(GHCI_S_BLT_OP, 32'h0);
		st(GHCI_S_BLT_DST_BASE, 32'h6000);
		st(GHCI_S_BLT_DST_STRIDE, 32'd64);
		st(GHCI_S_BLT_DST_XY, 32'h0);
		st(GHCI_S_BLT_SIZE, {16'd3, 16'd10});
		st(GHCI_S_BLT_COLOR, 32'hA5C3_1E77);
		st(GHCI_S_BLT_CLIP_MAX, 32'h0);
		run;
		if (ok !== 1'b1)
			fail_msg("FILL");
		for (k = 0; k < 3; k = k + 1)
			for (n = 0; n < 40; n = n + 1)
				rmem[32'h6000 + 64 * k + n] = 32'hA5C31E77 >> (8 * (n % 4));
		compare;
		if (MS4 != 0) begin
			mk(4, 0, 0, 0, 0, 1, 1, 6, 2, 0, 0);
			do_case(1);
		end else begin
			n = nreq;
			st(GHCI_S_BLT_OP, 32'h4);
			run;
			if (ok !== 1'b0 || ekind != GHCI_FAULT_OPCODE || nreq != n || busy)
				fail_msg("RESOLVE without MS4");
		end
		st(GHCI_S_BLT_OP, 32'h1);
		st(GHCI_S_BLT_SRC_BASE, 32'h6000);
		st(GHCI_S_BLT_SRC_STRIDE, 32'd64);
		st(GHCI_S_BLT_SRC_XY, 32'h0);
		st(GHCI_S_BLT_DST_BASE, 32'h6800);
		st(GHCI_S_BLT_DST_STRIDE, 32'd64);
		st(GHCI_S_BLT_DST_XY, 32'h0);
		st(GHCI_S_BLT_SIZE, {16'd3, 16'd10});
		run;
		if (ok !== 1'b1)
			fail_msg("COPY");
		for (k = 0; k < 3; k = k + 1)
			for (n = 0; n < 40; n = n + 1)
				rmem[32'h6800 + 64 * k + n] = rmem[32'h6000 + 64 * k + n];
		compare;
		if (MS4 != 0) begin
			mk(2, 1, 1, 0, 0, 0, 0, 8, 4, 0, 0);
			do_case(1);
		end

		if (MS4 != 0) begin
		/* 11 halt */
		tn = 11;
		mk(4, 0, 0, 0, 0, 0, 0, 30, 8, 0, 0);
		fork
			do_case(1);
			begin
				repeat (150) @(posedge clk);
				hold = 1'b1;
				repeat (300) @(posedge clk);
				hold = 1'b0;
			end
		join
		end
		fin = 1'b1;
	end
endmodule

module atg_blt_rsv_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg start = 1'b0;
	always #5 clk = !clk;
	wire f32, f64, fn;
	integer seed, k, bad;

	atg_blt_rsv_tbc #(.LINE_BYTES(32), .LINE_SHIFT(5), .MS4(1), .SEED0(11)) c32 (
		.clk(clk), .rst_n(rst_n), .start(start), .fin(f32));
	atg_blt_rsv_tbc #(.LINE_BYTES(64), .LINE_SHIFT(6), .MS4(1), .SEED0(23)) c64 (
		.clk(clk), .rst_n(rst_n), .start(start), .fin(f64));
	atg_blt_rsv_tbc #(.LINE_BYTES(32), .LINE_SHIFT(5), .MS4(0), .SEED0(37)) cn (
		.clk(clk), .rst_n(rst_n), .start(start), .fin(fn));

	task report;
		input integer t;
		input [8*12-1:0] name;
		begin
			if (c32.errs[t] == 0 && c64.errs[t] == 0 && cn.errs[t] == 0)
				$display("PASS atg_blt_rsv.%0s", name);
			else begin
				$display("FAIL atg_blt_rsv.%0s", name);
				bad = bad + 1;
			end
		end
	endtask

	initial begin
		#200000000;
		$display("FAIL atg_blt_rsv: timeout");
		$finish;
	end

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		c32.seed = c32.seed + seed;
		bad = 0;
		repeat (4) @(posedge clk);
		rst_n = 1'b1;
		start = 1'b1;
		wait (f32 && f64 && fn);
		report(0, "unorm8");
		report(1, "rgb565");
		report(2, "sample0");
		report(3, "offset");
		report(4, "tiled");
		report(5, "clip");
		report(6, "rowshare");
		report(7, "random");
		report(8, "stream");
		report(9, "fault");
		report(10, "2d");
		report(11, "halt");
		report(12, "nms4");
		if (bad == 0)
			$display("PASS atg_blt_rsv");
		$finish;
	end
endmodule

`default_nettype wire
