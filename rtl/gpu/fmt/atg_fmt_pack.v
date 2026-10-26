/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_pack: four 32-bit components to a pixel of a colour attachment
 * format, for the N formats of FMTS: o = {keep[127:0], raw[127:0]}.
 *
 * Pipelined into 2 stages (LAT = 2) to eliminate 200 MHz critical path,
 * or combinational (LAT = 0) for backward compatibility.
 *   Stage 1: component selection (fsel), masking, shifting, and lower OR tree.
 *   Stage 2: upper OR tree reduction, format selection, write-mask, output assembly.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_pack #(
	parameter integer N = 1,		/* the formats */
	parameter [8*N-1:0] FMTS = 8'd37,	/* VkFormat i at 8 i */
	parameter integer LAT = 2		/* 0: combinational, 2: 2-stage pipeline */
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [127:0] c,
	input wire [63:0] un,	/* the components as UNORM (atg_fmt_f2unorm) */
	input wire [63:0] hf,	/* as fp16 (am_fp_f2h) */
	input wire [7:0] fmt,
	input wire [3:0] wm,
	output wire [255:0] o
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

	localparam integer LV = N <= 1 ? 0 : N <= 2 ? 1 : N <= 4 ? 2 : N <= 8 ? 3 : N <= 16 ? 4 :
		N <= 32 ? 5 : N <= 64 ? 6 : N <= 128 ? 7 : 8;
	localparam integer NP = 1 << LV;
	localparam integer L_SPLIT = (LV >= 2) ? (LV / 2) : 1;
	localparam integer N_MID = (LV == 0) ? 1 : (NP >> L_SPLIT);
	localparam integer REM = (LV == 0) ? 0 : (LV - L_SPLIT);

	wire [256:0] v_leaf [0:NP-1];
	genvar gi, gl, gj;
	generate
	for (gi = 0; gi < NP; gi = gi + 1) begin : g_f
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
				hit = (fmt == F);
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
			assign v_leaf[gi] = {wr, raw, hit};
			wire unused_ok = &{1'b0, E0[47:42], E1[47:42], E2[47:42], E3[47:42]};
		end else begin : g_z
			assign v_leaf[gi] = 257'd0;
		end
	end

	/* Stage 1 Tree: levels 1 to L_SPLIT */
	if (LV > 0) begin : g_tree1
		for (gl = 1; gl <= L_SPLIT; gl = gl + 1) begin : g_l1
			for (gj = 0; gj < (NP >> gl); gj = gj + 1) begin : g_j1
				wire [256:0] v;
				if (gl == 1) begin : g_a1
					assign v = v_leaf[2 * gj] | v_leaf[2 * gj + 1];
				end else begin : g_b1
					assign v = g_l1[gl - 1].g_j1[2 * gj].v | g_l1[gl - 1].g_j1[2 * gj + 1].v;
				end
			end
		end
	end
	endgenerate

	/* Stage 1 Pipeline Register / Stage 2 Tree inputs */
	wire [256:0] in_s2 [0:N_MID-1];
	genvar gk;
	generate
	if (LV == 0) begin : g_stage1_lv0
		for (gk = 0; gk < N_MID; gk = gk + 1) begin : g_in2
			wire [256:0] s1_val = v_leaf[0];
			if (LAT == 2) begin : g_lat2
				reg [256:0] reg_s1;
				always @(posedge clk) begin
					if (!rst_n)
						reg_s1 <= 257'd0;
					else if (en)
						reg_s1 <= s1_val;
				end
				assign in_s2[gk] = reg_s1;
			end else begin : g_lat0
				assign in_s2[gk] = s1_val;
			end
		end
	end else begin : g_stage1_lvn
		for (gk = 0; gk < N_MID; gk = gk + 1) begin : g_in2
			wire [256:0] s1_val = g_tree1.g_l1[L_SPLIT].g_j1[gk].v;
			if (LAT == 2) begin : g_lat2
				reg [256:0] reg_s1;
				always @(posedge clk) begin
					if (!rst_n)
						reg_s1 <= 257'd0;
					else if (en)
						reg_s1 <= s1_val;
				end
				assign in_s2[gk] = reg_s1;
			end else begin : g_lat0
				assign in_s2[gk] = s1_val;
			end
		end
	end

	/* Stage 2 Tree: levels 1 to REM */
	if (REM > 0) begin : g_tree2
		for (gl = 1; gl <= REM; gl = gl + 1) begin : g_l2
			for (gj = 0; gj < (N_MID >> gl); gj = gj + 1) begin : g_j2
				wire [256:0] v;
				if (gl == 1) begin : g_a2
					assign v = in_s2[2 * gj] | in_s2[2 * gj + 1];
				end else begin : g_b2
					assign v = g_l2[gl - 1].g_j2[2 * gj].v | g_l2[gl - 1].g_j2[2 * gj + 1].v;
				end
			end
		end
	end

	wire [256:0] all_s2;
	if (REM == 0) begin : g_all_rem0
		assign all_s2 = in_s2[0];
	end else begin : g_all_rem
		assign all_s2 = g_tree2.g_l2[REM].g_j2[0].v;
	end
	endgenerate

	wire [255:0] o_next = all_s2[0] ? {~all_s2[256:129], all_s2[128:1]} : {{128{1'b1}}, 128'd0};

	/* Stage 2 Pipeline Register */
	generate
	if (LAT == 2) begin : g_s2_reg
		reg [255:0] reg_s2;
		always @(posedge clk) begin
			if (!rst_n)
				reg_s2 <= {{128{1'b1}}, 128'd0};
			else if (en)
				reg_s2 <= o_next;
		end
		assign o = reg_s2;
	end else begin : g_s2_comb
		assign o = o_next;
	end
	endgenerate

	wire unused_ok = &{1'b0, clk, rst_n, en};
endmodule

`default_nettype wire
