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
 *                   (am_fp_f2h)
 *   fmt 5 SFLOAT32  every 32 bits of 32-, 64- and 128-bit pixels, averaged
 *
 * The average of a channel is ((s0 + s1) + (s2 + s3)) x 0.25 in fp32, each
 * step one fused multiply-add (am_fp_fma_p; round to nearest
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
	localparam [3:0] IDLE = 4'd0, RUN = 4'd1, ENC_START = 4'd2, ENC = 4'd3,
		FH0 = 4'd4, FH1 = 4'd5, FH2 = 4'd6, FH3 = 4'd7, COMMIT = 4'd8, OUT = 4'd9;
	localparam [31:0] ONE = 32'h3F800000, QUARTER = 32'h3E800000;

	reg [3:0] st;
	reg [511:0] s_in;
	reg [2:0] m_fmt, m_psl, m_n;
	reg [1:0] p;		/* the pixel */
	reg [2:0] j;		/* its channel */
	reg [2:0] step_d;
	reg [1:0] step;
	reg [3:0] fma_wait;
	reg [31:0] r01, r23, sm, r_final;
	reg [31:0] r_fa, r_fb, r_fc;
	reg [31:0] r_xa, r_xc;
	reg [31:0] ia_s_r, ic_s_r, ia_h_r, ic_h_r, ia_f_r, ic_f_r;

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

	/* Sample sn of channel j of pixel p: Stage A extracts raw slice from s_in; Stage B decodes (u_ha/atg_srgb_dec). */
	wire [31:0] raw_xa = (m_fmt == 3'd3) ? {24'd0, s_in[{ia_s_r[5:0], 3'b000} +: 8]} :
	                     (m_fmt == 3'd4) ? {16'd0, s_in[{ia_h_r[8:4], 4'b0000} +: 16]} :
	                                       s_in[{ia_f_r[8:5], 5'b00000} +: 32];
	wire [31:0] raw_xc = (m_fmt == 3'd3) ? {24'd0, s_in[{ic_s_r[5:0], 3'b000} +: 8]} :
	                     (m_fmt == 3'd4) ? {16'd0, s_in[{ic_h_r[8:4], 4'b0000} +: 16]} :
	                                       s_in[{ic_f_r[8:5], 5'b00000} +: 32];
	wire [31:0] ha, hc;	/* the two fp16 samples as fp32, from registered 16-bit slice */
	am_fp_h2f #(.DENORM(1), .LAT(0)) u_ha (.h(r_xa[15:0]), .f(ha));
	am_fp_h2f #(.DENORM(1), .LAT(0)) u_hc (.h(r_xc[15:0]), .f(hc));
	wire [31:0] xa = (m_fmt == 3'd3) ? atg_srgb_dec(r_xa[7:0]) : (m_fmt == 3'd4) ? ha : r_xa;
	wire [31:0] xc = (m_fmt == 3'd3) ? atg_srgb_dec(r_xc[7:0]) : (m_fmt == 3'd4) ? hc : r_xc;
	/* The fma: fb is 1.0 or 0.25 (a significand of 2^23), so the product of
	 * the significands is fa's shifted (no multiplier). */
	wire [31:0] fr;
	am_fp_fma_p #(.LAT(6)) u_fma (.clk(clk), .rst_n(rst_n), .en(1'b1), .a0(r_fa), .b0(r_fb), .c0(r_fc), .rm(3'd0), .noc(1'b0),
		.p({1'b0, r_fa[30:23] != 8'd0 ? {1'b1, r_fa[22:0]} : 24'd0, 23'd0}), .r(fr));

	/*
	 * 4-cycle pipelined fp32 -> fp16 conversion (exact match to am_fp_f2h)
	 * so every stage stays <= 12 cmos3 levels instead of 63 cmos3.
	 */
	wire [23:0] fh_m = {1'b1, r_final[22:0]};
	wire [11:0] fh_q_w;
	wire [4:0] fh_sh_w, fh_sh1_w;
	wire [5:0] fh_co_unused;
	am_add #(.W(12)) u_fh_q (.a({1'b0, fh_m[23:13]}), .b(12'd0),
		.ci(r_final[12] && (r_final[11:0] != 12'd0 || r_final[13])), .s(fh_q_w), .co(fh_co_unused[0]));
	am_sub #(.W(5)) u_fh_sh (.a(5'd30), .b(r_final[27:23]), .bi(1'b0), .d(fh_sh_w), .bo(fh_co_unused[1]));
	am_sub #(.W(5)) u_fh_sh1 (.a(5'd29), .b(r_final[27:23]), .bi(1'b0), .d(fh_sh1_w), .bo(fh_co_unused[2]));

	reg        fh0_sign_r, fh0_ef_r, fh0_mnz_r, fh0_ge113_r, fh0_gt142_r, fh0_le101_r;
	reg [11:0] fh0_q_r;
	reg [4:0]  fh0_sh_r, fh0_sh1_r;
	wire [7:0] fh_ex_w;
	wire [23:0] fh_ds_w, fh_hi_w;
	am_sub #(.W(8)) u_fh_ex (.a(r_final[30:23]), .b(fh0_q_r[11] ? 8'd111 : 8'd112), .bi(1'b0),
		.d(fh_ex_w), .bo(fh_co_unused[3]));
	am_shift #(.W(24), .SW(5), .DIR(1)) u_fh_ds (.a(fh_m), .amt(fh0_sh_r), .left(1'b0), .arith(1'b0), .y(fh_ds_w));
	am_shift #(.W(24), .SW(5), .DIR(2)) u_fh_hi (.a({24{1'b1}}), .amt(fh0_sh1_r), .left(1'b1), .arith(1'b0), .y(fh_hi_w));

	reg [7:0]  fh1_ex_r;
	reg [14:0] fh1_ds_r;
	reg [23:0] fh1_hi_r;
	reg        fh1_g_r;
	wire fh2_st_w = (fh_m & ~fh1_hi_r) != 24'd0;
	wire fh2_rnd_w = fh1_g_r && (fh2_st_w || fh1_ds_r[0]);

	reg [14:0] fh2_ds_r;
	reg        fh2_rnd_r, fh2_ovf_r;
	wire [14:0] fh3_dr_w;
	am_add #(.W(15)) u_fh_dr (.a(fh2_ds_r), .b(15'd0), .ci(fh2_rnd_r), .s(fh3_dr_w), .co(fh_co_unused[4]));
	assign fh_co_unused[5] = 1'b0;

	reg [15:0] fh_r;
	wire [15:0] fh_mux_w = fh0_ef_r ? (fh0_mnz_r ? 16'h7E00 : {fh0_sign_r, 15'h7C00}) :
		fh0_ge113_r ? (fh2_ovf_r ? {fh0_sign_r, 15'h7C00} :
			{fh0_sign_r, fh1_ex_r[4:0], fh0_q_r[11:10] != 2'b01 ? 10'd0 : fh0_q_r[9:0]}) :
		fh0_le101_r ? {fh0_sign_r, 15'd0} : {fh0_sign_r, fh3_dr_w};
	wire [15:0] fh = fh_r;
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
		.clk(clk), .rst_n(rst_n), .i_valid(st == ENC_START),
		.i_ready(e_ready), .i_x(r_final), .o_valid(e_valid), .o_ready(st == ENC), .o_code(e_code)
	);

	/* sRGB alpha: byte 3, the UNORM8 average of the four samples, ties to even. */
	wire [31:0] aq;	/* pixel q's at bits 8 q */

	genvar q;
	generate
		for (q = 0; q < 4; q = q + 1) begin : g_alpha
			wire [9:0] aw0 = {2'd0, s_in[8 * (4 * (4 * q) + 3) +: 8]};
			wire [9:0] aw1 = {2'd0, s_in[8 * (4 * (4 * q + 1) + 3) +: 8]};
			wire [9:0] aw2 = {2'd0, s_in[8 * (4 * (4 * q + 2) + 3) +: 8]};
			wire [9:0] aw3 = {2'd0, s_in[8 * (4 * (4 * q + 3) + 3) +: 8]};
			wire [9:0] ac1_s = aw0 ^ aw1 ^ aw2;
			wire [9:0] ac1_c = {((aw0[8:0] & aw1[8:0]) | (aw1[8:0] & aw2[8:0]) | (aw0[8:0] & aw2[8:0])), 1'b0};
			wire [9:0] ac2_s = ac1_s ^ ac1_c ^ aw3;
			wire [9:0] ac2_c = {((ac1_s[8:0] & ac1_c[8:0]) | (ac1_c[8:0] & aw3[8:0]) | (ac1_s[8:0] & aw3[8:0])), 1'b0};
			wire [9:0] asum, asum_p4;
			wire [1:0] a_co_unused;
			am_add #(.W(10)) a_s (.a(ac2_s), .b(ac2_c), .ci(1'b0), .s(asum), .co(a_co_unused[0]));
			wire [7:0] ap4_s = ac2_s[9:2] ^ ac2_c[9:2] ^ 8'd1;
			wire [7:0] ap4_c = {((ac2_s[8:2] & ac2_c[8:2]) | (ac2_s[8:2] & 7'd1) | (ac2_c[8:2] & 7'd1)), 1'b0};
			am_add #(.W(10)) a_sp4 (.a({ap4_s, ac2_s[1:0]}), .b({ap4_c, ac2_c[1:0]}), .ci(1'b0), .s(asum_p4), .co(a_co_unused[1]));
			assign aq[8 * q +: 8] = (asum[1] && (asum[0] || asum[2])) ? asum_p4[9:2] : asum[9:2];

			wire unused_ok = &{1'b0, a_co_unused, asum_p4[1:0]};
		end
	endgenerate

	assign i_ready = st == IDLE;
	assign o_valid = st == OUT;

	/* The channel's result goes in, at its place in the output (as the samples' places, sample 0). */
	wire take = (st == COMMIT) || (st == ENC && e_valid);
	wire [2:0] j_inc;
	wire [1:0] p_inc, step_inc;
	wire [2:0] out_co_unused;
	integer k;

	am_add #(.W(3)) a_j (.a(j), .b(3'd0), .ci(1'b1), .s(j_inc), .co(out_co_unused[0]));
	am_add #(.W(2)) a_p (.a(p), .b(2'd0), .ci(1'b1), .s(p_inc), .co(out_co_unused[1]));
	am_add #(.W(2)) a_step (.a(step), .b(2'd0), .ci(1'b1), .s(step_inc), .co(out_co_unused[2]));

	wire [2:0] h_idx = (m_psl == 3'd1) ? {1'b0, p} :
	                   (m_psl == 3'd2) ? {p, j[0]} :
	                   {p[0], j[1:0]};
	wire [1:0] w_idx = (m_psl == 3'd2) ? p :
	                   (m_psl == 3'd3) ? {p[0], j[0]} :
	                   j[1:0];

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			st <= IDLE;
			m_fmt <= 3'd0;
			m_psl <= 3'd0;
			m_n <= 3'd0;
			p <= 2'd0;
			j <= 3'd0;
			step <= 2'd0;
			fma_wait <= 4'd0;
			r01 <= 32'd0;
			r23 <= 32'd0;
			sm <= 32'd0;
			r_final <= 32'd0;
			r_fa <= 32'd0;
			r_fb <= 32'd0;
			r_fc <= 32'd0;
			r_xa <= 32'd0;
			r_xc <= 32'd0;
			ia_s_r <= 32'd0;
			ic_s_r <= 32'd0;
			ia_h_r <= 32'd0;
			ic_h_r <= 32'd0;
			ia_f_r <= 32'd0;
			ic_f_r <= 32'd0;
			fh0_sign_r <= 1'b0;
			fh0_ef_r <= 1'b0;
			fh0_mnz_r <= 1'b0;
			fh0_ge113_r <= 1'b0;
			fh0_gt142_r <= 1'b0;
			fh0_le101_r <= 1'b0;
			fh0_q_r <= 12'd0;
			fh0_sh_r <= 5'd0;
			fh0_sh1_r <= 5'd0;
			fh1_ex_r <= 8'd0;
			fh1_ds_r <= 15'd0;
			fh1_hi_r <= 24'd0;
			fh1_g_r <= 1'b0;
			fh2_ds_r <= 15'd0;
			fh2_rnd_r <= 1'b0;
			fh2_ovf_r <= 1'b0;
			fh_r <= 16'd0;
			out_p <= 128'd0;
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
				fma_wait <= 4'd0;
				st <= RUN;
			end
			RUN: begin
				case (fma_wait)
				4'd0: begin
					ia_s_r <= ia_s;
					ic_s_r <= ic_s;
					ia_h_r <= ia_h;
					ic_h_r <= ic_h;
					ia_f_r <= ia_f;
					ic_f_r <= ic_f;
					fma_wait <= 4'd1;
				end
				4'd1: begin
					r_xa <= raw_xa;
					r_xc <= raw_xc;
					fma_wait <= 4'd2;
				end
				4'd2: begin
					r_fa <= step[1] ? (step[0] ? sm : r01) : xa;
					r_fb <= step == 2'd3 ? QUARTER : ONE;
					r_fc <= step[1] ? (step[0] ? 32'h80000000 : r23) : xc;
					fma_wait <= 4'd3;
				end
				4'd3: fma_wait <= 4'd4;
				4'd4: fma_wait <= 4'd5;
				4'd5: fma_wait <= 4'd6;
				4'd6: fma_wait <= 4'd7;
				4'd7: fma_wait <= 4'd8;
				4'd8: fma_wait <= 4'd9;
				4'd9: begin
					fma_wait <= 4'd0;
					if (step == 2'd0) begin
						r01 <= fr;
						step <= step_inc;
					end else if (step == 2'd1) begin
						r23 <= fr;
						step <= step_inc;
					end else if (step == 2'd2) begin
						sm <= fr;
						step <= step_inc;
					end else begin
						r_final <= fr;
						step <= 2'd0;
						if (m_fmt == 3'd3)
							st <= ENC_START;
						else if (m_fmt == 3'd4)
							st <= FH0;
						else
							st <= COMMIT;
					end
				end
				default: fma_wait <= 4'd0;
				endcase
			end
			FH0: begin
				fh0_sign_r  <= r_final[31];
				fh0_ef_r    <= (r_final[30:23] == 8'hFF);
				fh0_mnz_r   <= (r_final[22:0] != 23'd0);
				fh0_ge113_r <= (r_final[30:23] >= 8'd113);
				fh0_gt142_r <= (r_final[30:23] > 8'd142);
				fh0_le101_r <= (r_final[30:23] <= 8'd101);
				fh0_q_r     <= fh_q_w;
				fh0_sh_r    <= fh_sh_w;
				fh0_sh1_r   <= fh_sh1_w;
				st <= FH1;
			end
			FH1: begin
				fh1_ex_r <= fh_ex_w;
				fh1_ds_r <= fh_ds_w[14:0];
				fh1_hi_r <= fh_hi_w;
				fh1_g_r  <= fh_m[fh0_sh1_r];
				st <= FH2;
			end
			FH2: begin
				fh2_ds_r  <= fh1_ds_r;
				fh2_rnd_r <= fh2_rnd_w;
				fh2_ovf_r <= (fh1_ex_r >= 8'd31) || fh0_gt142_r;
				st <= FH3;
			end
			FH3: begin
				fh_r <= fh_mux_w;
				st <= COMMIT;
			end
			ENC_START: begin
				st <= ENC;
			end
			ENC: ;
			COMMIT: ;
			default: if (o_ready) begin
				st <= IDLE;
				out_p <= 128'd0;
			end
			endcase
			if (take) begin
				fma_wait <= 4'd0;
				if (m_fmt == 3'd3)
					out_p[8 * {p, j[1:0]} +: 8] <= e_code;
				else if (m_fmt == 3'd4)
					out_p[16 * h_idx +: 16] <= fh;
				else
					out_p[32 * w_idx +: 32] <= r_final;
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

	wire unused_ok = &{1'b0, e_ready, idx_co_unused, last_co_unused, out_co_unused, fh_co_unused,
		fh_ds_w[23:15], ta_ps[31:29], tc_ps[31:29],
		ia_s_r[31:6], ic_s_r[31:6], ia_h_r[31:9], ic_h_r[31:9], ia_h_r[3:0], ic_h_r[3:0],
		ia_f_r[31:9], ic_f_r[31:9], ia_f_r[4:0], ic_f_r[4:0],
		ia_h[31:9], ic_h[31:9], ps};
endmodule

`default_nettype wire
