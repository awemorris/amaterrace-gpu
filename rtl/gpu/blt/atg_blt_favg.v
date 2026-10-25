/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_favg: the floating-point and sRGB averages of the blitter's
 * RESOLVE (docs/ghci.md sections 8.2 and 8.5), one group of up to four
 * pixels at a time (atg_blt_rsv_px stalls while it works).  The input and
 * output layouts are atg_blt_avg's (sample s of pixel p at slot 4 p + s of
 * 2^psl bytes; pixel p at bits 8 ps p).
 *
 *   fmt 3 SRGB8_A8  32-bit pixels: bytes 0-2 decoded to linear fp32
 *                   (atg_srgb_dec), averaged, encoded to the nearest code
 *                   (atg_fmt_srgbenc); byte 3 as UNORM8 (atg_blt_avg's rule)
 *   fmt 4 SFLOAT16  every 16 bits of 16-, 32- and 64-bit pixels: to fp32
 *                   exactly, averaged, to binary16 to nearest even
 *                   (atg_fmt_f2h)
 *   fmt 5 SFLOAT32  every 32 bits of 32-, 64- and 128-bit pixels, averaged
 *
 * The average of a channel is ((s0 + s1) + (s2 + s3)) x 0.25 in fp32, each
 * step one fused multiply-add of include/atg_su_fp.vh (round to nearest
 * even, denormals flushed, NaN 0x7FC00000), four steps a channel (and the
 * encoder's nine cycles for sRGB).  i_valid/i_ready: a group, taken in
 * IDLE (npx pixels); o_valid/o_ready: its averages, held until taken.
 * See spec/gpu/blt/atg_blt_favg.md.
 *
 * States: IDLE →(i_valid)→ RUN (channel by channel: steps 0-3, sRGB: ENC)
 * → OUT →(o_ready)→ IDLE.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_favg (
	input wire clk,
	input wire rst_n,
	input wire i_valid,
	output wire i_ready,
	input wire [2:0] fmt,
	input wire [2:0] psl,
	input wire [2:0] npx,	/* pixels */
	input wire [511:0] in_s,
	output wire o_valid,
	input wire o_ready,
	output reg [127:0] out_p
);
	`include "atg_srgb.vh"
	`include "atg_fmt_info.vh"
	`include "atg_fmt_unpack.vh"
	`include "atg_fmt_pack.vh"
	`include "atg_su_fp.vh"
	localparam [1:0] IDLE = 2'd0, RUN = 2'd1, ENC = 2'd2, OUT = 2'd3;
	localparam [31:0] ONE = 32'h3F800000, QUARTER = 32'h3E800000;

	reg [1:0] st;
	reg [511:0] s_in;
	reg [2:0] m_fmt, m_psl, m_n;
	reg [1:0] p;		/* the pixel */
	reg [2:0] j;		/* its channel */
	reg [1:0] step;
	reg [31:0] r01, r23, sm;

	/* Channels of a pixel: sRGB 3, fp16 ps / 2, fp32 ps / 4. */
	wire [4:0] ps = 5'd1 << m_psl;
	wire [2:0] cpp = m_fmt == 3'd3 ? 3'd3 : m_fmt == 3'd4 ? ps[3:1] : ps[4:2];

	/* Sample s of channel j of pixel p, as fp32. */
	function [31:0] xs;	/* (everything it reads is an argument) */
		input [511:0] si;
		input [2:0] fm;
		input [4:0] pz;
		input [1:0] pp;
		input [2:0] jj;
		input [1:0] sn;
		begin
			if (fm == 3'd3)
				xs = atg_srgb_dec(si[8 * (4 * (4 * pp + {30'd0, sn}) + {29'd0, jj}) +: 8]);
			else if (fm == 3'd4)
				xs = atg_fmt_h2f(si[8 * pz * (4 * pp + {30'd0, sn}) + 16 * {29'd0, jj} +: 16]);
			else
				xs = si[8 * pz * (4 * pp + {30'd0, sn}) + 32 * {29'd0, jj} +: 32];
		end
	endfunction
	/* Steps 0 and 1 add two samples each: (s0 + s1), then (s2 + s3); only
	 * those two samples are decoded. */
`ifdef MUT_FAVG_PAIR
	wire [31:0] xa = xs(s_in, m_fmt, ps, p, j, step == 2'd1 ? 2'd2 : 2'd0);
	wire [31:0] xc = xs(s_in, m_fmt, ps, p, j, step == 2'd1 ? 2'd1 : 2'd2);
`else
	wire [31:0] xa = xs(s_in, m_fmt, ps, p, j, step == 2'd1 ? 2'd2 : 2'd0);
	wire [31:0] xc = xs(s_in, m_fmt, ps, p, j, step == 2'd1 ? 2'd3 : 2'd1);
`endif
	wire [31:0] fa = step[1] ? (step[0] ? sm : r01) : xa;
	wire [31:0] fb = step == 2'd3 ? QUARTER : ONE;
	wire [31:0] fc = step[1] ? (step[0] ? 32'h80000000 : r23) : xc;
	wire [31:0] fr = atg_su_ffma(fa, fb, fc, 3'd0, 1'b0);
	wire [15:0] fh = atg_fmt_f2h(fr);
	wire lastj = j == cpp - 3'd1;
	wire lastp = {1'b0, p} == m_n - 3'd1;

	/* The sRGB encoder. */
	wire e_ready, e_valid;
	wire [7:0] e_code;
	atg_fmt_srgbenc enc (
		.clk(clk), .rst_n(rst_n), .i_valid(st == RUN && step == 2'd3 && m_fmt == 3'd3),
		.i_ready(e_ready), .i_x(fr), .o_valid(e_valid), .o_ready(st == ENC), .o_code(e_code)
	);

	/* sRGB alpha: byte 3, the UNORM8 average. */
	reg [9:0] asum;
	reg [7:0] aq [0:3];
	integer q, t;
	always @(*)
		for (q = 0; q < 4; q = q + 1) begin
			asum = 10'd0;
			for (t = 0; t < 4; t = t + 1)
				asum = asum + {2'd0, s_in[8 * (4 * (4 * q + t) + 3) +: 8]};
			aq[q] = asum[9:2] + {7'd0, asum[1] && (asum[0] || asum[2])};
		end

	assign i_ready = st == IDLE;
	assign o_valid = st == OUT;

	/* The channel's result goes in. */
	wire take = (st == RUN && step == 2'd3 && m_fmt != 3'd3) || (st == ENC && e_valid);
	integer k;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
		end else begin
			case (st)
			IDLE: if (i_valid) begin
				s_in <= in_s;
				m_fmt <= fmt;
				m_psl <= psl;
				m_n <= npx;
				p <= 2'd0;
				j <= 3'd0;
				step <= 2'd0;
				out_p <= 128'd0;
				st <= RUN;
			end
			RUN: begin
				step <= step + 2'd1;
				if (step == 2'd0)
					r01 <= fr;
				if (step == 2'd1)
					r23 <= fr;
				if (step == 2'd2)
					sm <= fr;
				if (step == 2'd3 && m_fmt == 3'd3)
					st <= ENC;
			end
			ENC: ;
			default: if (o_ready)
				st <= IDLE;
			endcase
			if (take) begin
				if (m_fmt == 3'd3)
					out_p[8 * (4 * p + j) +: 8] <= e_code;
				else if (m_fmt == 3'd4)
					out_p[8 * ps * p + 16 * {29'd0, j} +: 16] <= fh;
				else
					out_p[8 * ps * p + 32 * {29'd0, j} +: 32] <= fr;
				j <= lastj ? 3'd0 : j + 3'd1;
				if (lastj)
					p <= p + 2'd1;
				step <= 2'd0;
				if (lastj && lastp) begin
					st <= OUT;
					if (m_fmt == 3'd3)
						for (k = 0; k < 4; k = k + 1)
							if (k < m_n)
								out_p[8 * (4 * k + 3) +: 8] <= aq[k];
				end else
					st <= RUN;
			end
		end
	end

	wire unused_ok = &{1'b0, e_ready};
endmodule

`default_nettype wire
