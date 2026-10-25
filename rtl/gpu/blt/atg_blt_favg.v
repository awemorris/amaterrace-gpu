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

	/* The pixel's bytes, 2^psl in 5 bits (0 from 32 bytes), by table. */
	reg [4:0] ps;

	always @(*)
		case (m_psl)
		3'd0: ps = 5'd1;
		3'd1: ps = 5'd2;
		3'd2: ps = 5'd4;
		3'd3: ps = 5'd8;
		3'd4: ps = 5'd16;
		default: ps = 5'd0;
		endcase

	/* Channels of a pixel: sRGB 3, fp16 ps / 2, fp32 ps / 4. */
	wire [2:0] cpp = m_fmt == 3'd3 ? 3'd3 : m_fmt == 3'd4 ? ps[3:1] : ps[4:2];

	/*
	 * The bit places of sample sn of channel j of pixel p in the samples:
	 * sRGB at byte 4 (4 p + sn) + j, fp16 and fp32 at byte ps (4 p + sn)
	 * plus 2 j or 4 j.  ps (4 p + sn) is (4 p + sn) << psl, or 0 for a ps of
	 * 0 (the 5-bit 2^psl wrapped).
	 */
	function [31:0] at_ps;	/* t x ps, by a shift */
		input [31:0] shifted;
		input [4:0] pz;
		at_ps = pz == 5'd0 ? 32'd0 : shifted;
	endfunction

	/* Steps 0 and 1 add two samples each: (s0 + s1), then (s2 + s3); only
	 * those two samples are decoded. */
`ifdef MUT_FAVG_PAIR
	wire [1:0] sn_a = step == 2'd1 ? 2'd2 : 2'd0;
	wire [1:0] sn_c = step == 2'd1 ? 2'd1 : 2'd2;
`else
	wire [1:0] sn_a = step == 2'd1 ? 2'd2 : 2'd0;
	wire [1:0] sn_c = step == 2'd1 ? 2'd3 : 2'd1;
`endif
	wire [31:0] ta_sh, tc_sh, ta_ps, tc_ps, ia_s, ic_s, ia_h, ic_h, ia_f, ic_f;
	wire [5:0] idx_co_unused;

	am_shift #(.W(32), .SW(3)) h_ta (.a({28'd0, p, sn_a}), .amt(m_psl), .left(1'b1), .arith(1'b0), .y(ta_sh));
	am_shift #(.W(32), .SW(3)) h_tc (.a({28'd0, p, sn_c}), .amt(m_psl), .left(1'b1), .arith(1'b0), .y(tc_sh));
	assign ta_ps = at_ps(ta_sh, ps);
	assign tc_ps = at_ps(tc_sh, ps);
	am_add #(.W(32)) a_ias (.a({26'd0, p, sn_a, 2'b00}), .b({29'd0, j}), .ci(1'b0), .s(ia_s), .co(idx_co_unused[0]));
	am_add #(.W(32)) a_ics (.a({26'd0, p, sn_c, 2'b00}), .b({29'd0, j}), .ci(1'b0), .s(ic_s), .co(idx_co_unused[1]));
	am_add #(.W(32)) a_iah (.a({ta_ps[28:0], 3'b000}), .b({25'd0, j, 4'b0000}), .ci(1'b0), .s(ia_h), .co(idx_co_unused[2]));
	am_add #(.W(32)) a_ich (.a({tc_ps[28:0], 3'b000}), .b({25'd0, j, 4'b0000}), .ci(1'b0), .s(ic_h), .co(idx_co_unused[3]));
	am_add #(.W(32)) a_iaf (.a({ta_ps[28:0], 3'b000}), .b({24'd0, j, 5'b00000}), .ci(1'b0), .s(ia_f), .co(idx_co_unused[4]));
	am_add #(.W(32)) a_icf (.a({tc_ps[28:0], 3'b000}), .b({24'd0, j, 5'b00000}), .ci(1'b0), .s(ic_f), .co(idx_co_unused[5]));

	/* Sample sn of channel j of pixel p, as fp32 (the places are 32-bit, as the former expressions were). */
	/* verilator lint_off UNUSEDSIGNAL */
	function [31:0] xs;	/* (everything it reads is an argument) */
		input [511:0] si;
		input [2:0] fm;
		input [31:0] i_s;
		input [31:0] i_h;
		input [31:0] i_f;
		begin
			if (fm == 3'd3)
				xs = atg_srgb_dec(si[{i_s[28:0], 3'b000} +: 8]);
			else if (fm == 3'd4)
				xs = atg_fmt_h2f(si[i_h +: 16]);
			else
				xs = si[i_f +: 32];
		end
	endfunction
	/* verilator lint_on UNUSEDSIGNAL */
	wire [31:0] xa = xs(s_in, m_fmt, ia_s, ia_h, ia_f);
	wire [31:0] xc = xs(s_in, m_fmt, ic_s, ic_h, ic_f);
	wire [31:0] fa = step[1] ? (step[0] ? sm : r01) : xa;
	wire [31:0] fb = step == 2'd3 ? QUARTER : ONE;
	wire [31:0] fc = step[1] ? (step[0] ? 32'h80000000 : r23) : xc;
	wire [31:0] fr = atg_su_ffma(fa, fb, fc, 3'd0, 1'b0);
	wire [15:0] fh = atg_fmt_f2h(fr);
	wire [2:0] cpp_last, n_last;
	wire [1:0] last_co_unused;

	am_sub #(.W(3)) s_cpp (.a(cpp), .b(3'd1), .bi(1'b0), .d(cpp_last), .bo(last_co_unused[0]));
	am_sub #(.W(3)) s_n (.a(m_n), .b(3'd1), .bi(1'b0), .d(n_last), .bo(last_co_unused[1]));
	wire lastj = j == cpp_last;
	wire lastp = {1'b0, p} == n_last;

	/* The sRGB encoder. */
	wire e_ready, e_valid;
	wire [7:0] e_code;
	atg_fmt_srgbenc enc (
		.clk(clk), .rst_n(rst_n), .i_valid(st == RUN && step == 2'd3 && m_fmt == 3'd3),
		.i_ready(e_ready), .i_x(fr), .o_valid(e_valid), .o_ready(st == ENC), .o_code(e_code)
	);

	/* sRGB alpha: byte 3, the UNORM8 average of the four samples, ties to even. */
	wire [31:0] aq;	/* pixel q's at bits 8 q */

	genvar q;
	generate
		for (q = 0; q < 4; q = q + 1) begin : g_alpha
			wire [9:0] a01, a23, asum;
			wire [3:0] a_co_unused;

			am_add #(.W(10)) a_01 (.a({2'd0, s_in[8 * (4 * (4 * q) + 3) +: 8]}), .b({2'd0, s_in[8 * (4 * (4 * q + 1) + 3) +: 8]}),
				.ci(1'b0), .s(a01), .co(a_co_unused[0]));
			am_add #(.W(10)) a_23 (.a({2'd0, s_in[8 * (4 * (4 * q + 2) + 3) +: 8]}), .b({2'd0, s_in[8 * (4 * (4 * q + 3) + 3) +: 8]}),
				.ci(1'b0), .s(a23), .co(a_co_unused[1]));
			am_add #(.W(10)) a_s (.a(a01), .b(a23), .ci(1'b0), .s(asum), .co(a_co_unused[2]));
			am_add #(.W(8)) a_q (.a(asum[9:2]), .b(8'd0), .ci(asum[1] && (asum[0] || asum[2])), .s(aq[8 * q +: 8]),
				.co(a_co_unused[3]));

			wire unused_ok = &{1'b0, a_co_unused};
		end
	endgenerate

	assign i_ready = st == IDLE;
	assign o_valid = st == OUT;

	/* The channel's result goes in, at its place in the output (as the samples' places, sample 0). */
	wire take = (st == RUN && step == 2'd3 && m_fmt != 3'd3) || (st == ENC && e_valid);
	wire [31:0] tp_sh, tp_ps, op_s, op_h, op_f;
	wire [2:0] j_inc;
	wire [1:0] p_inc, step_inc;
	wire [5:0] out_co_unused;
	integer k;

	am_shift #(.W(32), .SW(3)) h_tp (.a({30'd0, p}), .amt(m_psl), .left(1'b1), .arith(1'b0), .y(tp_sh));
	assign tp_ps = at_ps(tp_sh, ps);
	am_add #(.W(32)) a_ops (.a({28'd0, p, 2'b00}), .b({29'd0, j}), .ci(1'b0), .s(op_s), .co(out_co_unused[0]));
	am_add #(.W(32)) a_oph (.a({tp_ps[28:0], 3'b000}), .b({25'd0, j, 4'b0000}), .ci(1'b0), .s(op_h), .co(out_co_unused[1]));
	am_add #(.W(32)) a_opf (.a({tp_ps[28:0], 3'b000}), .b({24'd0, j, 5'b00000}), .ci(1'b0), .s(op_f), .co(out_co_unused[2]));
	am_add #(.W(3)) a_j (.a(j), .b(3'd0), .ci(1'b1), .s(j_inc), .co(out_co_unused[3]));
	am_add #(.W(2)) a_p (.a(p), .b(2'd0), .ci(1'b1), .s(p_inc), .co(out_co_unused[4]));
	am_add #(.W(2)) a_step (.a(step), .b(2'd0), .ci(1'b1), .s(step_inc), .co(out_co_unused[5]));

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
				step <= step_inc;
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
					out_p[{op_s[28:0], 3'b000} +: 8] <= e_code;
				else if (m_fmt == 3'd4)
					out_p[op_h +: 16] <= fh;
				else
					out_p[op_f +: 32] <= fr;
				j <= lastj ? 3'd0 : j_inc;
				if (lastj)
					p <= p_inc;
				step <= 2'd0;
				if (lastj && lastp) begin
					st <= OUT;
					if (m_fmt == 3'd3)
						for (k = 0; k < 4; k = k + 1)
							if (k < m_n)
								out_p[8 * (4 * k + 3) +: 8] <= aq[8 * k +: 8];
				end else
					st <= RUN;
			end
		end
	end

	wire unused_ok = &{1'b0, e_ready, idx_co_unused, last_co_unused, out_co_unused, ta_ps[31:29], tc_ps[31:29],
		tp_ps[31:29], op_s[31:29], op_h[31:7], op_f[31:7]};
endmodule

`default_nettype wire
