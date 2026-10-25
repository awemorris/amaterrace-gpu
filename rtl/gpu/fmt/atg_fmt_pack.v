/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_pack: four 32-bit components to a pixel of a colour attachment
 * format, for the N formats of FMTS (constants: the module is their bit
 * placements and a choice by fmt): o = {keep[127:0], raw[127:0]}.  The
 * former function atg_fmt_pack of include/atg_fmt_pack.vh;
 * tools/fmtmodel.py pack is the reference; spec/gpu/fmt/atg_fmt_pack.md.
 * c = {c3, c2, c1, c0}, wm the write mask of R, G, B, A.  raw is the pixel
 * as a little-endian integer, keep has a 1 for every bit not written (the
 * masked components and the bits outside the pixel).  The conversions
 * come from the caller, so that a unit that packs one of several formats
 * at a time has one converter a component (docs/style.md, "Arithmetic"):
 * un[16 k +: 16] = atg_fmt_f2unorm(c_k, the component's width; 8 for an
 * sRGB alpha), hf[16 k +: 16] = atg_fmt_f2h(c_k); only the formats that
 * need them read them.  UNORM RNE(clamp01(f) x (2^b - 1)), 16-bit floats
 * to nearest even, 32-bit floats and integer formats the low bits; sRGB
 * formats take R, G and B as 8-bit codes in [7:0] (atg_fmt_srgbenc) and A
 * as UNORM 8.  A format without the colour-attachment feature, and a fmt
 * not in FMTS, write nothing (keep all ones, raw 0).
 *
 * Combinational, no arithmetic: the places come from a table (pent, a
 * function of constants) and every index is a constant once the loops are
 * unrolled (each format's placement is wiring, chosen by fmt); a
 * simulator evaluates only the placement of fmt.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_pack #(
	parameter integer N = 1,	/* the formats */
	parameter [8*N-1:0] FMTS = 8'd37	/* VkFormat i at 8 i */
) (
	input wire [127:0] c,
	input wire [63:0] un,	/* the components as UNORM (atg_fmt_f2unorm) */
	input wire [63:0] hf,	/* as fp16 (atg_fmt_f2h) */
	input wire [7:0] fmt,
	input wire [3:0] wm,
	output reg [255:0] o
);
	`include "atg_fmt_info.vh"

	/* Component k of format i at 48 (4 i + k): [6:0] its lowest bit,
	 * [38:7] its mask (2^w - 1), [40:39] its source (K_*), [41] written (the
	 * format has the colour-attachment feature and the component). */
	localparam [1:0] K_V = 2'd0, K_UN = 2'd1, K_HF = 2'd2, K_SRGB = 2'd3;
	function [192*N-1:0] ptab;
		input integer unused_n;
		integer pi, pk, pb;
		reg [67:0] inf;
		/* verilator lint_off UNUSEDSIGNAL */
		reg [25:0] ft;	/* (COLOR_ATTACHMENT only) */
		/* verilator lint_on UNUSEDSIGNAL */
		reg [1:0] kd;
		reg [5:0] w;
		reg [31:0] m;
		begin
			ptab = {192*N{1'b0}};
			for (pi = 0; pi < N; pi = pi + 1) begin
				inf = atg_fmt_info(FMTS[8 * pi +: 8]);
				ft = atg_fmt_feat(FMTS[8 * pi +: 8], 1'b0);
				for (pk = 0; pk < 4; pk = pk + 1) begin
					w = inf[23 + 13 * pk +: 6];
					for (pb = 0; pb < 32; pb = pb + 1)
						m[pb] = pb < w;
					if (inf[11:9] == ATG_FMT_UNORM || (inf[11:9] == ATG_FMT_SRGB && pk == 3))
						kd = K_UN;
					else if (inf[11:9] == ATG_FMT_SRGB)
						kd = K_SRGB;
					else if (inf[11:9] == ATG_FMT_SFLOAT && w != 6'd32)
						kd = K_HF;
					else
						kd = K_V;
					ptab[48 * (4 * pi + pk) +: 48] = {6'd0, ft[7] && pk < inf[8:6], kd, m,
						inf[16 + 13 * pk +: 7]};
				end
			end
		end
	endfunction
	localparam [192*N-1:0] PTAB = ptab(N);

	/* a component's field: c_k, its UNORM or fp16 conversion, or the 8-bit
	 * sRGB code in c_k[7:0] */
	function [31:0] fsel;
		input [1:0] kd;
		input [31:0] v;
		input [15:0] u, h;
		fsel = kd == K_UN ? {16'd0, u} : kd == K_HF ? {16'd0, h} : kd == K_SRGB ? {24'd0, v[7:0]} : v;
	endfunction

	/* One placement a format (constant places), 0 unless fmt is that format
	 * (so a simulator evaluates only the placement of fmt), then an OR tree
	 * of the NP = 2^LV placements (those from N up are 0). */
	localparam integer LV = N <= 1 ? 0 : N <= 2 ? 1 : N <= 4 ? 2 : N <= 8 ? 3 : N <= 16 ? 4 :
		N <= 32 ? 5 : N <= 64 ? 6 : N <= 128 ? 7 : 8;
	localparam integer NP = 1 << LV;
	wire [256:0] all;	/* {wr, raw, hit} of fmt */
	genvar gi, gl, gj;
	generate
	for (gi = 0; gi < NP; gi = gi + 1) begin : g_f
		wire [256:0] v;	/* {wr, raw, hit} */
		if (gi < N) begin : g_p
			localparam [7:0] F = FMTS[8 * gi +: 8];
			localparam [47:0] E0 = PTAB[48 * (4 * gi) +: 48];
			localparam [47:0] E1 = PTAB[48 * (4 * gi + 1) +: 48];
			localparam [47:0] E2 = PTAB[48 * (4 * gi + 2) +: 48];
			localparam [47:0] E3 = PTAB[48 * (4 * gi + 3) +: 48];
			localparam [6:0] P0 = E0[6:0], P1 = E1[6:0], P2 = E2[6:0], P3 = E3[6:0];
			reg [127:0] raw, wr;
			reg hit;
			always @(*) begin
				raw = 128'd0;
				wr = 128'd0;
				hit = fmt == F;
				if (hit) begin
					if (E0[41] && wm[0]) begin
						raw = raw | ({96'd0, fsel(E0[40:39], c[31:0], un[15:0], hf[15:0]) & E0[38:7]} << P0);
						wr = wr | ({96'd0, E0[38:7]} << P0);
					end
					if (E1[41] && wm[1]) begin
						raw = raw | ({96'd0, fsel(E1[40:39], c[63:32], un[31:16], hf[31:16]) & E1[38:7]} << P1);
						wr = wr | ({96'd0, E1[38:7]} << P1);
					end
					if (E2[41] && wm[2]) begin
						raw = raw | ({96'd0, fsel(E2[40:39], c[95:64], un[47:32], hf[47:32]) & E2[38:7]} << P2);
						wr = wr | ({96'd0, E2[38:7]} << P2);
					end
					if (E3[41] && wm[3]) begin
						raw = raw | ({96'd0, fsel(E3[40:39], c[127:96], un[63:48], hf[63:48]) & E3[38:7]} << P3);
						wr = wr | ({96'd0, E3[38:7]} << P3);
					end
				end
			end
			assign v = {wr, raw, hit};
			wire unused_ok = &{1'b0, E0[47:42], E1[47:42], E2[47:42], E3[47:42]};
		end else begin : g_z
			assign v = 257'd0;
		end
	end
	for (gl = 1; gl <= LV; gl = gl + 1) begin : g_l
		for (gj = 0; gj < (NP >> gl); gj = gj + 1) begin : g_j
			wire [256:0] v;
			if (gl == 1) begin : g_a
				assign v = g_f[2 * gj].v | g_f[2 * gj + 1].v;
			end else begin : g_b
				assign v = g_l[gl - 1].g_j[2 * gj].v | g_l[gl - 1].g_j[2 * gj + 1].v;
			end
		end
	end
	if (LV == 0) begin : g_r0
		assign all = g_f[0].v;
	end else begin : g_r
		assign all = g_l[LV].g_j[0].v;
	end
	endgenerate
	always @(*)
		o = all[0] ? {~all[256:129], all[128:1]} : {{128{1'b1}}, 128'd0};
endmodule

`default_nettype wire
