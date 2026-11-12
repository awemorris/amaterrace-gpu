/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_blend: ROP blend: converts fp32 colour to the render-target
 * format, blends with the destination pixels (BLEND factors and ops,
 * BLEND_CONST), applies WRITE_MASK; a fixed pipeline used by atg_rop_wb.
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

`ifndef CFG_ROP_MRT_COUNT
`define CFG_ROP_MRT_COUNT 1
`endif

/* verilator lint_off BLKSEQ */
(* keep_hierarchy = "yes" *)
module atg_rop_blend #(
	parameter LAT = 11,	/* Pipeline cycles from b_valid to b_rvalid (11 for high-freq ASIC, 3 for legacy) */
	parameter MRT_COUNT = `CFG_ROP_MRT_COUNT
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire b_valid,
	input wire [511:0] b_src,
	input wire [511:0] b_src1,
	input wire b_has_src1,
	input wire [127:0] b_dst,
	input wire [3:0] b_mask,
	input wire [2:0] b_rt,
	output reg b_rvalid,
	output reg [127:0] b_pix
);
	`include "ghci_regs.vh"
	(* keep = "true", dont_touch = "true" *) wire rst_sync = !rst_n;

	/* Internal format codes (F_* in the 3-bit lane format). */
	localparam [2:0] F_BGRA8 = 3'd0, F_RGBA8 = 3'd1, F_565 = 3'd2, F_R8 = 3'd3, F_RG8 = 3'd4,
		F_1555 = 3'd5, F_NONE = 3'd7;
	function [2:0] fcode;
		input [7:0] vk;
		case (vk)
		8'd44: fcode = F_BGRA8;
		8'd37, 8'd51: fcode = F_RGBA8;
		8'd4: fcode = F_565;
		8'd9: fcode = F_R8;
		8'd16: fcode = F_RG8;
		8'd8: fcode = F_1555;
		default: fcode = F_NONE;
		endcase
	endfunction

	/* Distributed ROM tables for round(v * 31 / 255) and round(v * 63 / 255). */
	(* rom_style = "distributed" *) reg [4:0] rom_u5 [0:255];
	(* rom_style = "distributed" *) reg [5:0] rom_u6 [0:255];
	integer ir;
	reg [31:0] u5_init, u6_init;
	initial begin
		for (ir = 0; ir < 256; ir = ir + 1) begin
			u5_init = (ir * 31 + 128 + ((ir * 31 + 128) >> 8)) >> 8;
			u6_init = (ir * 63 + 128 + ((ir * 63 + 128) >> 8)) >> 8;
			rom_u5[ir] = u5_init[4:0];
			rom_u6[ir] = u6_init[5:0];
		end
	end

	reg [1:0] fmt0;	/* RT_FORMAT */
	reg [63:0] fmts;	/* RT_FORMATS (0..7) */
	reg [26:0] bls [0:7];
	reg [31:0] kc8, kcf;	/* BLEND_CONST; the fp32 constants as bytes */
	reg kc_sel;	/* ROP_CTRL[1] */
`ifdef CFG_ROP_DUAL_SOURCE
	reg dual_src_en;	/* ROP_CTRL[7] */
`else
	wire dual_src_en = 1'b0;
`endif
	reg [31:0] wms;
`ifdef CFG_ROP_ENABLE_LOGICOP
	reg lop_en [0:7];
	reg [3:0] lop_op [0:7];
`endif
	/* BLEND1-3 and BLEND_CONST_R-A: k = (st_idx - 3) mod 4 = st_idx[1:0] + 1 */
	(* keep = "true" *) wire [1:0] s_k = {st_idx[1] ^ st_idx[0], ~st_idx[0]};

	/* Extended ROP space for RT4-7 (0x1B0-0x1BF, CAPS[30]): s_ext[1:0] = st_idx[1:0] since 0x1B0 is multiple of 16 */
	wire [1:0] s_ext_lo = st_idx[1:0];
	wire is_blend1_3 = (st_idx == 9'h084) || (st_idx == 9'h085) || (st_idx == 9'h086);
	wire is_blend4_7 = (st_idx[8:2] == 7'b0110111); /* 0x1B8..0x1BB */
	wire is_kcf_we   = (st_idx == 9'h087) || (st_idx == 9'h088) || (st_idx == 9'h089) || (st_idx == 9'h08A);

`ifdef SYNTH_KINTEX7
	wire [31:0] st_wdata_bl, st_wdata_bl2;
	genvar g_wd;
	generate
	for (g_wd = 0; g_wd < 32; g_wd = g_wd + 1) begin : g_wdata_buf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wdbl  (.I0(st_wdata[g_wd]), .O(st_wdata_bl[g_wd]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wdbl2 (.I0(st_wdata[g_wd]), .O(st_wdata_bl2[g_wd]));
	end
	endgenerate
`else
	wire [31:0] st_wdata_bl  = st_wdata;
	wire [31:0] st_wdata_bl2 = st_wdata;
`endif

	/* 3-stage pipelined f2u8 for kcf (used when LAT != 3) and combinational u_kcf (for LAT == 3) */
	wire [7:0] kcf_pipe_u;
	reg kcf_v0a, kcf_v0b, kcf_v0c;
	reg [1:0] kcf_k0a, kcf_k0b, kcf_k0c;
	atg_rop_blend_f2u8_pipe u_kcf_pipe (
		.clk(clk), .rst_sync(rst_sync), .f(st_wdata_bl2), .u(kcf_pipe_u)
	);
	always @(posedge clk) begin
		if (rst_sync) begin
			kcf_v0a <= 1'b0;
			kcf_v0b <= 1'b0;
			kcf_v0c <= 1'b0;
			kcf_k0a <= 2'd0;
			kcf_k0b <= 2'd0;
			kcf_k0c <= 2'd0;
		end else begin
			kcf_v0a <= st_we && is_kcf_we;
			kcf_k0a <= s_k;
			kcf_v0b <= kcf_v0a;
			kcf_k0b <= kcf_k0a;
			kcf_v0c <= kcf_v0b;
			kcf_k0c <= kcf_k0b;
		end
	end

	wire [7:0] kcf_comb_n;
	generate
	if (LAT == 3) begin : g_kcf_comb
		atg_rop_f2u8 u_kcf (.f(st_wdata), .u(kcf_comb_n));
	end else begin : g_kcf_nocomb
		assign kcf_comb_n = 8'd0;
	end
	endgenerate

`ifdef SYNTH_KINTEX7
	/* Split bls[0..7], fmts[31:0], fmts[63:32], kc8[31:0] write enables so fanout <= 16 */
	wire fmts_lo_we_raw = st_we && (st_idx == GHCI_S_RT_FORMATS);
	wire fmts_hi_we_raw = st_we && (st_idx == GHCI_S_RT_FORMATS1);
	wire kc8_we_raw     = st_we && (st_idx == GHCI_S_BLEND_CONST);
	wire fmts_lo_we0, fmts_lo_we1, fmts_hi_we0, fmts_hi_we1, kc8_we0, kc8_we1;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_fmts_lo0 (.I0(fmts_lo_we_raw), .O(fmts_lo_we0));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_fmts_lo1 (.I0(fmts_lo_we_raw), .O(fmts_lo_we1));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_fmts_hi0 (.I0(fmts_hi_we_raw), .O(fmts_hi_we0));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_fmts_hi1 (.I0(fmts_hi_we_raw), .O(fmts_hi_we1));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_kc8_we0  (.I0(kc8_we_raw),     .O(kc8_we0));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_kc8_we1  (.I0(kc8_we_raw),     .O(kc8_we1));
	always @(posedge clk) begin
		if (rst_sync) begin
			fmts <= 64'd0;
			kc8 <= 32'd0;
		end else begin
			if (fmts_lo_we0) fmts[15:0]  <= st_wdata_bl[15:0];
			if (fmts_lo_we1) fmts[31:16] <= st_wdata_bl[31:16];
			if (fmts_hi_we0) fmts[47:32] <= st_wdata_bl[15:0];
			if (fmts_hi_we1) fmts[63:48] <= st_wdata_bl[31:16];
			if (kc8_we0)     kc8[15:0]   <= st_wdata_bl[15:0];
			if (kc8_we1)     kc8[31:16]  <= st_wdata_bl[31:16];
		end
	end

	genvar g_bls;
	generate
	for (g_bls = 0; g_bls < 8; g_bls = g_bls + 1) begin : g_bls_reg
		wire bls_we_raw = st_we && (
			(g_bls == 0) ? (st_idx == GHCI_S_BLEND) :
			(g_bls < 4)  ? (is_blend1_3 && (s_k == g_bls[1:0])) :
			               (is_blend4_7 && (s_ext_lo == g_bls[1:0]))
		);
		wire bls_we_lo, bls_we_hi;
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_bwe_lo (.I0(bls_we_raw), .O(bls_we_lo));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_bwe_hi (.I0(bls_we_raw), .O(bls_we_hi));
		always @(posedge clk) begin
			if (rst_sync) begin
				bls[g_bls][13:0]  <= 14'd0;
				bls[g_bls][26:14] <= 13'd0;
			end else begin
				if (bls_we_lo)
					bls[g_bls][13:0]  <= st_wdata_bl[13:0];
				if (bls_we_hi)
					bls[g_bls][26:14] <= st_wdata_bl[26:14];
			end
		end
`ifdef CFG_ROP_ENABLE_LOGICOP
		wire lop_bcast = (st_wdata_bl2[31:8] == 24'd0);
		wire lop_we_raw = st_we && ((st_idx == GHCI_S_ROP_CTRL) ||
			((st_idx == GHCI_S_LOGIC_OP) && ((g_bls < 4) || lop_bcast)));
		wire lop_we_buf;
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lop_we (.I0(lop_we_raw), .O(lop_we_buf));
		wire lop_en_nxt = (st_idx == GHCI_S_ROP_CTRL) ? st_wdata_bl2[2] :
			(lop_bcast || (g_bls >= 4)) ? st_wdata_bl2[0] : st_wdata_bl2[8 * (g_bls % 4)];
		wire [3:0] lop_op_nxt = (st_idx == GHCI_S_ROP_CTRL) ? st_wdata_bl2[6:3] :
			(lop_bcast || (g_bls >= 4)) ? st_wdata_bl2[4:1] : st_wdata_bl2[8 * (g_bls % 4) + 1 +: 4];
		always @(posedge clk) begin
			if (rst_sync) begin
				lop_en[g_bls] <= 1'b0;
				lop_op[g_bls] <= 4'd0;
			end else if (lop_we_buf) begin
				lop_en[g_bls] <= lop_en_nxt;
				lop_op[g_bls] <= lop_op_nxt;
			end
		end
`endif
	end
	endgenerate
`endif

	integer i;
	always @(posedge clk)
		if (rst_sync) begin
			fmt0 <= 2'd0;
`ifndef SYNTH_KINTEX7
			fmts <= 64'd0;
			kc8 <= 32'd0;
			for (i = 0; i < 8; i = i + 1) begin
				bls[i] <= 27'd0;
`ifdef CFG_ROP_ENABLE_LOGICOP
				lop_en[i] <= 1'b0;
				lop_op[i] <= 4'd0;
`endif
			end
`endif
			kcf <= 32'd0;
			kc_sel <= 1'b0;
`ifdef CFG_ROP_DUAL_SOURCE
			dual_src_en <= 1'b0;
`endif
			wms <= 32'd0;
		end else begin
			if (LAT != 3 && kcf_v0c)
				kcf[8 * kcf_k0c +: 8] <= kcf_pipe_u;
			if (st_we) begin
				if (st_idx == GHCI_S_RT_FORMAT)
					fmt0 <= st_wdata_bl2[1:0];
`ifndef SYNTH_KINTEX7
				if (st_idx == GHCI_S_RT_FORMATS)
					fmts[31:0] <= st_wdata_bl;
				if (st_idx == GHCI_S_RT_FORMATS1)
					fmts[63:32] <= st_wdata_bl;
				if (st_idx == GHCI_S_BLEND)
					bls[0] <= st_wdata_bl[26:0];
				if (is_blend1_3)
					bls[{1'b0, s_k}] <= st_wdata_bl[26:0];
				if (is_blend4_7)
					for (i = 0; i < 4; i = i + 1)
						if (s_ext_lo == i[1:0])
							bls[{1'b1, i[1:0]}] <= st_wdata_bl[26:0];
				if (st_idx == GHCI_S_BLEND_CONST)
					kc8 <= st_wdata_bl;
`endif
				if (LAT == 3 && is_kcf_we)
					kcf[8 * s_k +: 8] <= kcf_comb_n;
				if (st_idx == GHCI_S_ROP_CTRL) begin
					kc_sel <= st_wdata_bl2[1];
`ifdef CFG_ROP_DUAL_SOURCE
					dual_src_en <= st_wdata_bl2[7];
`endif
`ifndef SYNTH_KINTEX7
`ifdef CFG_ROP_ENABLE_LOGICOP
					for (i = 0; i < 8; i = i + 1) begin
						lop_en[i] <= st_wdata_bl2[2];
						lop_op[i] <= st_wdata_bl2[6:3];
					end
`endif
`endif
				end
`ifndef SYNTH_KINTEX7
`ifdef CFG_ROP_ENABLE_LOGICOP
				if (st_idx == GHCI_S_LOGIC_OP) begin
					if (st_wdata_bl2[31:8] == 24'd0) begin
						for (i = 0; i < 8; i = i + 1) begin
							lop_en[i] <= st_wdata_bl2[0];
							lop_op[i] <= st_wdata_bl2[4:1];
						end
					end else begin
						lop_en[0] <= st_wdata_bl2[0];
						lop_op[0] <= st_wdata_bl2[4:1];
						lop_en[1] <= st_wdata_bl2[8];
						lop_op[1] <= st_wdata_bl2[12:9];
						lop_en[2] <= st_wdata_bl2[16];
						lop_op[2] <= st_wdata_bl2[20:17];
						lop_en[3] <= st_wdata_bl2[24];
						lop_op[3] <= st_wdata_bl2[28:25];
					end
				end
`endif
`endif
				if (st_idx == GHCI_S_WRITE_MASK) begin
					wms[15:0] <= st_wdata_bl2[15:0];
					if (st_wdata_bl2[31:16] != 16'd0)
						wms[31:16] <= st_wdata_bl2[31:16];
				end
				if (st_idx == GHCI_S_WRITE_MASK1)
					wms[31:16] <= st_wdata_bl2[15:0];
			end
		end
`ifdef SYNTH_KINTEX7
	wire kc_sel_lo, kc_sel_hi;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_kcsel_lo (.I0(kc_sel), .O(kc_sel_lo));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_kcsel_hi (.I0(kc_sel), .O(kc_sel_hi));
	wire [31:0] kc = {kc_sel_hi ? kcf[31:16] : kc8[31:16], kc_sel_lo ? kcf[15:0] : kc8[15:0]};
`else
	wire [31:0] kc = kc_sel ? kcf : kc8;
`endif

	function [7:0] factor_nosat;
		input [4:0] f;
		input [7:0] sc, dc, kcc, sa, da, ka, s1c, s1a;
		case (f)
		5'd1: factor_nosat = 8'd255;
		5'd2: factor_nosat = sc;
		5'd3: factor_nosat = ~sc;
		5'd4: factor_nosat = dc;
		5'd5: factor_nosat = ~dc;
		5'd6: factor_nosat = sa;
		5'd7: factor_nosat = ~sa;
		5'd8: factor_nosat = da;
		5'd9: factor_nosat = ~da;
		5'd10: factor_nosat = kcc;
		5'd11: factor_nosat = ~kcc;
		5'd12: factor_nosat = ka;
		5'd13: factor_nosat = ~ka;
		5'd14: factor_nosat = 8'd255;
`ifdef CFG_ROP_DUAL_SOURCE
		5'd15: factor_nosat = s1c;
		5'd16: factor_nosat = ~s1c;
		5'd17: factor_nosat = s1a;
		5'd18: factor_nosat = ~s1a;
`else
		5'd15, 5'd16, 5'd17, 5'd18: factor_nosat = (s1c ^ s1a) & 8'd0;
`endif
		default: factor_nosat = 8'd0;
		endcase
	endfunction

`ifdef CFG_ROP_ENABLE_LOGICOP
	function [7:0] calc_logic_op;
		input [3:0] op;
		input [7:0] s;
		input [7:0] d;
		case (op)
		4'd0:  calc_logic_op = 8'h00;
		4'd1:  calc_logic_op = s & d;
		4'd2:  calc_logic_op = s & ~d;
		4'd3:  calc_logic_op = s;
		4'd4:  calc_logic_op = ~s & d;
		4'd5:  calc_logic_op = d;
		4'd6:  calc_logic_op = s ^ d;
		4'd7:  calc_logic_op = s | d;
		4'd8:  calc_logic_op = ~(s | d);
		4'd9:  calc_logic_op = ~(s ^ d);
		4'd10: calc_logic_op = ~d;
		4'd11: calc_logic_op = s | ~d;
		4'd12: calc_logic_op = ~s;
		4'd13: calc_logic_op = ~s | d;
		4'd14: calc_logic_op = ~(s & d);
		4'd15: calc_logic_op = 8'hFF;
		endcase
	endfunction
`endif

	/* Pure-LUT 8-bit unsigned < comparator (0 CARRY4s, 2 LUTs) */
	function u8_lt;
		input [7:0] a;
		input [7:0] b;
		reg hi_lt, hi_eq, lo_lt;
		begin
			hi_lt = (~a[7] & b[7]) | ((a[7] ~^ b[7]) & (~a[6] & b[6])) |
				((a[7] ~^ b[7]) & (a[6] ~^ b[6]) & ((~a[5] & b[5]) | ((a[5] ~^ b[5]) & (~a[4] & b[4]))));
			hi_eq = (a[7:4] == b[7:4]);
			lo_lt = (~a[3] & b[3]) | ((a[3] ~^ b[3]) & (~a[2] & b[2])) |
				((a[3] ~^ b[3]) & (a[2] ~^ b[2]) & ((~a[1] & b[1]) | ((a[1] ~^ b[1]) & (~a[0] & b[0]))));
			u8_lt = hi_lt | (hi_eq & lo_lt);
		end
	endfunction

	genvar gl, gc;
	generate
	if (LAT == 3) begin : g_lat3
		wire [7:0] fvk = fmts[8 * b_rt +: 8];
		wire [2:0] fmt_n = b_rt == 3'd0 && fvk == 8'd0 ? (fmt0 == 2'd0 ? F_BGRA8 :
			fmt0 == 2'd1 ? F_RGBA8 : F_565) : fcode(fvk);
		wire [26:0] bl_n = bls[b_rt];
		wire [3:0] wm_n = wms[4 * b_rt +: 4];
`ifdef CFG_ROP_ENABLE_LOGICOP
		wire lop_en_n = lop_en[b_rt];
		wire [3:0] lop_op_n = lop_op[b_rt];
`else
		wire lop_en_n = 1'b0;
		wire [3:0] lop_op_n = 4'd0;
`endif
		wire [127:0] s1_n;
		for (gl = 0; gl < 16; gl = gl + 1) begin : g_f2u8
			atg_rop_f2u8 u_f2u8 (.f(b_src[128 * (gl / 4) + 32 * (gl % 4) +: 32]),
				.u(s1_n[32 * (gl / 4) + 8 * (gl % 4) +: 8]));
		end
`ifdef CFG_ROP_DUAL_SOURCE
		wire [127:0] s1_1_n;
		for (gl = 0; gl < 16; gl = gl + 1) begin : g_f2u8_1
			atg_rop_f2u8 u_f2u8_1 (.f(b_src1[128 * (gl / 4) + 32 * (gl % 4) +: 32]),
				.u(s1_1_n[32 * (gl / 4) + 8 * (gl % 4) +: 8]));
		end
`else
		wire [127:0] s1_1_n = 128'd0;
`endif
		reg [127:0] d1_n;
		reg [31:0] dp;
		integer l;
		always @(*) begin
			for (l = 0; l < 4; l = l + 1) begin
				dp = b_dst[32 * l +: 32];
				case (fmt_n)
				F_BGRA8: d1_n[32 * l +: 32] = {dp[31:24], dp[7:0], dp[15:8], dp[23:16]};
				F_RGBA8: d1_n[32 * l +: 32] = dp;
				F_R8: d1_n[32 * l +: 32] = {8'd255, 16'd0, dp[7:0]};
				F_RG8: d1_n[32 * l +: 32] = {8'd255, 8'd0, dp[15:0]};
				F_1555: d1_n[32 * l +: 32] = {{8{dp[15]}}, dp[4:0], dp[4:2], dp[9:5], dp[9:7],
					dp[14:10], dp[14:12]};
				default: d1_n[32 * l +: 32] = {8'd255, dp[4:0], dp[4:2], dp[10:5], dp[10:9],
					dp[15:11], dp[15:13]};
				endcase
			end
		end

		reg v1, v1_m, v2;
		reg [3:0] m1, wm1, m1_m, wm1_m;
		reg [2:0] fmt1, fmt1_m;
		reg [26:0] bl1;
		reg [11:0] op1_vec, op1_vec_m;
		reg [3:0] bl_en1_vec, bl_en1_vec_m;
`ifdef CFG_ROP_ENABLE_LOGICOP
		reg lop_en1, lop_en1_m, lop_en2;
		reg [3:0] lop_op1, lop_op1_m, lop_op2;
`endif
		reg [31:0] kc1;
		reg [127:0] s1, o1, d1, s1_m, d1_m, o1_m, s2, d2, o2;
`ifdef CFG_ROP_DUAL_SOURCE
		reg [127:0] s1_1;
`endif
		reg [2:0] op2 [0:3][0:3];
		reg op_sub2 [0:3][0:3];
		reg op_rsub2_a [0:3][0:3];
		reg op_rsub2_b [0:3][0:3];
		reg op_dq2 [0:3][0:3];
		reg bl_en2 [0:3][0:3];
		reg [3:0] wm2_arr [0:3];
		reg [2:0] fmt2_arr [0:3];
		reg [3:0] m2_arr [0:3];
		integer il, ic;

		always @(posedge clk) begin
			v1 <= !rst_sync && b_valid;
			m1 <= b_mask;
			fmt1 <= fmt_n;
			bl1 <= bl_n;
			wm1 <= wm_n;
			op1_vec <= {bl_n[22:20], bl_n[11:9], bl_n[11:9], bl_n[11:9]};
			bl_en1_vec <= {4{bl_n[0]}};
`ifdef CFG_ROP_ENABLE_LOGICOP
			lop_en1 <= lop_en_n;
			lop_op1 <= lop_op_n;
`endif
			kc1 <= kc;
			o1 <= b_dst;
			s1 <= s1_n;
`ifdef CFG_ROP_DUAL_SOURCE
			s1_1 <= s1_1_n;
`endif
			d1 <= d1_n;

			v1_m <= !rst_sync && v1;
			s1_m <= s1;
			d1_m <= d1;
			o1_m <= o1;
			wm1_m <= wm1;
			fmt1_m <= fmt1;
			m1_m <= m1;
			op1_vec_m <= op1_vec;
			bl_en1_vec_m <= bl_en1_vec;
`ifdef CFG_ROP_ENABLE_LOGICOP
			lop_en1_m <= lop_en1;
			lop_op1_m <= lop_op1;
`endif
			v2 <= !rst_sync && v1_m;
			s2 <= s1_m;
			d2 <= d1_m;
			o2 <= o1_m;
			for (il = 0; il < 4; il = il + 1) begin
				wm2_arr[il] <= wm1_m;
				fmt2_arr[il] <= fmt1_m;
				m2_arr[il] <= m1_m;
				for (ic = 0; ic < 4; ic = ic + 1) begin
					op2[il][ic] <= op1_vec_m[3 * ic +: 3];
					op_sub2[il][ic] <= (op1_vec_m[3 * ic +: 3] == 3'd1) || (op1_vec_m[3 * ic +: 3] == 3'd2);
					op_rsub2_a[il][ic] <= (op1_vec_m[3 * ic +: 3] == 3'd2);
					op_rsub2_b[il][ic] <= (op1_vec_m[3 * ic +: 3] == 3'd2);
					op_dq2[il][ic] <= (op1_vec_m[3 * ic +: 3] != 3'd1) && (op1_vec_m[3 * ic +: 3] != 3'd2)
					               && (op1_vec_m[3 * ic +: 3] != 3'd3) && (op1_vec_m[3 * ic +: 3] != 3'd4);
					bl_en2[il][ic] <= bl_en1_vec_m[ic];
				end
			end
`ifdef CFG_ROP_ENABLE_LOGICOP
			lop_en2 <= lop_en1_m;
			lop_op2 <= lop_op1_m;
`endif
			b_rvalid <= !rst_sync && v1_m;
		end

		for (gl = 0; gl < 4; gl = gl + 1) begin : g_l2
			wire [7:0] sa_cur = s1[32 * gl + 24 +: 8];
			wire [7:0] da_cur = d1[32 * gl + 24 +: 8];
			wire [7:0] da_inv = ~da_cur;
			wire sat_cond = u8_lt(sa_cur, da_inv);
			wire [7:0] sat_a = sat_cond ? sa_cur : da_inv;
			for (gc = 0; gc < 4; gc = gc + 1) begin : g_c2
				wire [7:0] sc = s1[32 * gl + 8 * gc +: 8];
				wire [7:0] dc = d1[32 * gl + 8 * gc +: 8];
`ifdef CFG_ROP_DUAL_SOURCE
				wire [7:0] s1c = s1_1[32 * gl + 8 * gc +: 8];
				wire [7:0] s1a = s1_1[32 * gl + 24 +: 8];
`else
				wire [7:0] s1c = 8'd0;
				wire [7:0] s1a = 8'd0;
`endif
				wire [4:0] f_s = gc == 3 ? {bl1[25], bl1[15:12]} : {bl1[23], bl1[4:1]};
				wire [4:0] f_d = gc == 3 ? {bl1[26], bl1[19:16]} : {bl1[24], bl1[8:5]};
				wire [7:0] fs_base = factor_nosat(f_s, sc, dc, kc1[8 * gc +: 8], sa_cur, da_cur, kc1[31:24], s1c, s1a);
				wire [7:0] fd_base = factor_nosat(f_d, sc, dc, kc1[8 * gc +: 8], sa_cur, da_cur, kc1[31:24], s1c, s1a);
				wire is_sat_s = (gc < 3) && (f_s == 5'd14);
				wire is_sat_d = (gc < 3) && (f_d == 5'd14);
				wire [7:0] fs = is_sat_s ? sat_a : fs_base;
				wire [7:0] fd = is_sat_d ? sat_a : fd_base;
				wire [15:0] pp2, qq2;
				am_mul #(.AW(8), .BW(8), .LAT(2)) u_p (.clk(clk), .en(1'b1), .a(sc), .b(fs), .p(pp2));
				am_mul #(.AW(8), .BW(8), .LAT(2)) u_q (.clk(clk), .en(1'b1), .a(dc), .b(fd), .p(qq2));
			end
		end

		wire [127:0] pix_n;
		for (gl = 0; gl < 4; gl = gl + 1) begin : g_l3
			wire [3:0] wm2 = wm2_arr[gl];
			wire [2:0] fmt2 = fmt2_arr[gl];
			wire m2 = m2_arr[gl][gl];
			for (gc = 0; gc < 4; gc = gc + 1) begin : g_c3
				wire [2:0] op = op2[gl][gc];
				wire bl_en = bl_en2[gl][gc];
				wire [7:0] sv = s2[32 * gl + 8 * gc +: 8];
				wire [7:0] dv = d2[32 * gl + 8 * gc +: 8];
				wire [15:0] pp = g_l2[gl].g_c2[gc].pp2;
				wire [15:0] qq = g_l2[gl].g_c2[gc].qq2;
				wire op_sub = op_sub2[gl][gc];
				wire is_rsub_a = op_rsub2_a[gl][gc];
				wire is_rsub_b = op_rsub2_b[gl][gc];
				wire op_dq = op_dq2[gl][gc];
				wire [15:0] op_a = is_rsub_a ? qq : pp;
				wire [15:0] op_b = is_rsub_b ? pp : qq;
				wire [15:0] pq;
				wire pq_co;
				am_addsub #(.W(16)) u_pq (.a(op_a), .b(op_b), .sub(op_sub), .s(pq), .co(pq_co));
				wire [8:0] dq;
				wire [17:0] x_dq = {1'b0, (op_sub ? 1'b0 : pq_co), pq};
				atg_rop_div255 u_dq (.x(x_dq), .q(dq));
				reg [7:0] r8_bp;
				always @(*) begin
					if (!wm2[gc])
						r8_bp = dv;
`ifdef CFG_ROP_ENABLE_LOGICOP
					else if (lop_en2)
						r8_bp = calc_logic_op(lop_op2, sv, dv);
`endif
					else if (!bl_en)
						r8_bp = sv;
					else case (op)
					3'd3: r8_bp = u8_lt(sv, dv) ? sv : dv;
					3'd4: r8_bp = u8_lt(dv, sv) ? sv : dv;
					default: r8_bp = 8'd0;
					endcase
				end
`ifdef CFG_ROP_ENABLE_LOGICOP
				wire use_dq = wm2[gc] && bl_en && !lop_en2 && (op_sub ? pq_co : op_dq);
`else
				wire use_dq = wm2[gc] && bl_en && (op_sub ? pq_co : op_dq);
`endif
				wire [7:0] dq_sat = {8{dq[8]}} | dq[7:0];
				wire [7:0] ch_out = use_dq ? dq_sat : r8_bp;
			end
			wire [31:0] o2_lane = o2[32 * gl +: 32];
			wire [7:0] ch0 = g_c3[0].ch_out;
			wire [7:0] ch1 = g_c3[1].ch_out;
			wire [7:0] ch2 = g_c3[2].ch_out;
			wire [7:0] ch3 = g_c3[3].ch_out;
			wire [4:0] r5 = rom_u5[ch0];
			wire [5:0] g6 = rom_u6[ch1];
			wire [4:0] g5 = rom_u5[ch1];
			wire [4:0] b5 = rom_u5[ch2];
			wire a1 = ch3[7];
			reg [15:0] px_out_lo, px_out_hi;
			always @(*) begin
				case (fmt2)
				F_BGRA8: px_out_lo = {ch1, ch2};
				F_RGBA8: px_out_lo = {ch1, ch0};
				F_R8:    px_out_lo = {o2_lane[15:8], ch0};
				F_RG8:   px_out_lo = {ch1, ch0};
				F_565:   px_out_lo = {r5, g6, b5};
				F_1555:  px_out_lo = {a1, r5, g5, b5};
				default: px_out_lo = o2_lane[15:0];
				endcase
				case (fmt2)
				F_BGRA8: px_out_hi = {ch3, ch0};
				F_RGBA8: px_out_hi = {ch3, ch2};
				default: px_out_hi = o2_lane[31:16];
				endcase
			end
			assign pix_n[32 * gl +: 16]      = m2 ? px_out_lo : o2_lane[15:0];
			assign pix_n[32 * gl + 16 +: 16] = m2 ? px_out_hi : o2_lane[31:16];
		end
		always @(*) b_pix = pix_n;
		wire unused_lat3 = &{1'b0, v2};
	end else begin : g_pipe11
		/* =====================================================================
		 * High-Frequency 11-Stage Pipeline (LAT = 11)
		 * ===================================================================== */
		/* Stage 0A (cycle 0 -> 1): Boundary Input Registration */
		reg v0a, v0b, v0c, v1, v1_m, v2, v_s4, v_s5, v_s6, v_s7;
`ifdef SYNTH_KINTEX7
		wire b_clk = clk;
`else
		reg b_icg_en;
		always @(negedge clk) begin
			if (rst_sync)
				b_icg_en <= 1'b1;
			else
				b_icg_en <= b_valid || v0a || v0b || v0c || v1 || v1_m || v2 || v_s4 || v_s5 || v_s6 || v_s7 || b_rvalid;
		end
		wire b_clk = clk & b_icg_en;
`endif
		reg [511:0] src0a;
`ifdef CFG_ROP_DUAL_SOURCE
		reg [511:0] src1_0a;
`endif
		reg [127:0] dst0a;
		reg [3:0] mask0a;
		(* keep = "true", dont_touch = "true" *) reg [2:0] rt0a_rep [0:5];
		integer i0a;
		always @(posedge b_clk) begin
			v0a <= !rst_sync && b_valid;
			src0a <= b_src;
`ifdef CFG_ROP_DUAL_SOURCE
			src1_0a <= b_src1;
`endif
			dst0a <= b_dst;
			mask0a <= b_mask;
			for (i0a = 0; i0a < 6; i0a = i0a + 1)
				rt0a_rep[i0a] <= b_rt;
		end

		/* Attachment state lookup in Stage 0A -> 0B (replicated rt0a_rep keeps fanout <= 12) */
		wire [7:0] fvk_0a = fmts[8 * rt0a_rep[0] +: 8];
		wire [2:0] fmt_0a = (rt0a_rep[0] == 3'd0 && fvk_0a == 8'd0) ?
			(fmt0 == 2'd0 ? F_BGRA8 : fmt0 == 2'd1 ? F_RGBA8 : F_565) : fcode(fvk_0a);
		wire [8:0] bl_0a_s0, bl_0a_s1, bl_0a_s2;
		for (gl = 0; gl < 9; gl = gl + 1) begin : g_bl0a_slice
			assign bl_0a_s0[gl] = bls[rt0a_rep[1]][gl];
			assign bl_0a_s1[gl] = bls[rt0a_rep[2]][9 + gl];
			assign bl_0a_s2[gl] = bls[rt0a_rep[3]][18 + gl];
		end
		wire [26:0] bl_0a = {bl_0a_s2, bl_0a_s1, bl_0a_s0};
		wire [3:0] wm_0a = wms[4 * rt0a_rep[4] +: 4];
`ifdef CFG_ROP_ENABLE_LOGICOP
		wire lop_en_0a = lop_en[rt0a_rep[5]];
		wire [3:0] lop_op_0a = lop_op[rt0a_rep[5]];
`else
		wire lop_en_0a = 1'b0;
		wire [3:0] lop_op_0a = 4'd0;
`endif

		/* Stages 0B, 0C, 1 (cycles 1 -> 2 -> 3 -> 4): 3-stage f2u8 + destination unpack */
		wire [127:0] s1;
		for (gl = 0; gl < 16; gl = gl + 1) begin : g_f2u8_p
			atg_rop_blend_f2u8_pipe u_f2u8 (
				.clk(b_clk), .rst_sync(rst_sync),
				.f(src0a[128 * (gl / 4) + 32 * (gl % 4) +: 32]),
				.u(s1[32 * (gl / 4) + 8 * (gl % 4) +: 8])
			);
		end
`ifdef CFG_ROP_DUAL_SOURCE
		wire [127:0] s1_1;
		for (gl = 0; gl < 16; gl = gl + 1) begin : g_f2u8_1_p
			atg_rop_blend_f2u8_pipe u_f2u8_1 (
				.clk(b_clk), .rst_sync(rst_sync),
				.f(src1_0a[128 * (gl / 4) + 32 * (gl % 4) +: 32]),
				.u(s1_1[32 * (gl / 4) + 8 * (gl % 4) +: 8])
			);
		end
`else
		wire [127:0] s1_1 = 128'd0;
`endif

		reg [3:0] m0b, m0c, m1;
		reg [3:0] wm0b, wm0c, wm1;
		(* keep = "true", dont_touch = "true" *) reg [2:0] fmt0b_l_lo [0:3];
		(* keep = "true", dont_touch = "true" *) reg [2:0] fmt0b_l_hi [0:3];
		reg [2:0] fmt0b, fmt0c, fmt1;
		reg [26:0] bl0b;
		(* keep = "true", dont_touch = "true" *) reg [26:0] bl0c_lo;
		(* keep = "true", dont_touch = "true" *) reg [26:0] bl0c_hi;
		(* keep = "true", dont_touch = "true" *) reg [26:0] bl1_c_lo [0:3][0:3];
		(* keep = "true", dont_touch = "true" *) reg [26:0] bl1_c_hi [0:3][0:3];
		reg [11:0] op1_vec;
		reg [3:0] bl_en1_vec;
`ifdef CFG_ROP_ENABLE_LOGICOP
		reg lop_en0b, lop_en0c, lop_en1;
		reg [3:0] lop_op0b, lop_op0c, lop_op1;
`endif
		(* keep = "true", dont_touch = "true" *) reg [31:0] kc1_l [0:3];
		reg [127:0] dst0b, o0c, d0c, o1, d1;

		wire [127:0] d0c_n;
		for (gl = 0; gl < 4; gl = gl + 1) begin : g_d0c_unpack
			wire [31:0] dp0b = dst0b[32 * gl +: 32];
			wire [2:0] fmt0b_lo = fmt0b_l_lo[gl];
			wire [2:0] fmt0b_hi = fmt0b_l_hi[gl];
			reg [15:0] d0c_lane_lo, d0c_lane_hi;
			always @(*) begin
				case (fmt0b_lo)
				F_BGRA8: d0c_lane_lo = {dp0b[15:8], dp0b[23:16]};
				F_RGBA8: d0c_lane_lo = dp0b[15:0];
				F_R8:    d0c_lane_lo = {8'd0, dp0b[7:0]};
				F_RG8:   d0c_lane_lo = dp0b[15:0];
				F_1555:  d0c_lane_lo = {dp0b[9:5], dp0b[9:7], dp0b[14:10], dp0b[14:12]};
				default: d0c_lane_lo = {dp0b[10:5], dp0b[10:9], dp0b[15:11], dp0b[15:13]};
				endcase
				case (fmt0b_hi)
				F_BGRA8: d0c_lane_hi = {dp0b[31:24], dp0b[7:0]};
				F_RGBA8: d0c_lane_hi = dp0b[31:16];
				F_R8:    d0c_lane_hi = {8'd255, 8'd0};
				F_RG8:   d0c_lane_hi = {8'd255, 8'd0};
				F_1555:  d0c_lane_hi = {{8{dp0b[15]}}, dp0b[4:0], dp0b[4:2]};
				default: d0c_lane_hi = {8'd255, dp0b[4:0], dp0b[4:2]};
				endcase
			end
			assign d0c_n[32 * gl +: 32] = {d0c_lane_hi, d0c_lane_lo};
		end
		integer l0b, c0b;

		always @(posedge b_clk) begin
			/* S0B (cycle 1 -> 2) */
			v0b <= !rst_sync && v0a;
			m0b <= mask0a;
			wm0b <= wm_0a;
			fmt0b <= fmt_0a;
			for (l0b = 0; l0b < 4; l0b = l0b + 1) begin
				fmt0b_l_lo[l0b] <= fmt_0a;
				fmt0b_l_hi[l0b] <= fmt_0a;
			end
			bl0b <= bl_0a;
`ifdef CFG_ROP_ENABLE_LOGICOP
			lop_en0b <= lop_en_0a;
			lop_op0b <= lop_op_0a;
`endif
			dst0b <= dst0a;

			/* S0C (cycle 2 -> 3) */
			v0c <= !rst_sync && v0b;
			m0c <= m0b;
			wm0c <= wm0b;
			fmt0c <= fmt0b;
			bl0c_lo <= bl0b;
			bl0c_hi <= bl0b;
`ifdef CFG_ROP_ENABLE_LOGICOP
			lop_en0c <= lop_en0b;
			lop_op0c <= lop_op0b;
`endif
			o0c <= dst0b;
			d0c <= d0c_n;

			/* S1 (cycle 3 -> 4) */
			v1 <= !rst_sync && v0c;
			m1 <= m0c;
			wm1 <= wm0c;
			fmt1 <= fmt0c;
			for (l0b = 0; l0b < 4; l0b = l0b + 1) begin
				for (c0b = 0; c0b < 4; c0b = c0b + 1) begin
					bl1_c_lo[l0b][c0b] <= bl0c_lo;
					bl1_c_hi[l0b][c0b] <= bl0c_hi;
				end
				kc1_l[l0b] <= kc;
			end
			op1_vec <= {bl0c_hi[22:20], bl0c_hi[11:9], bl0c_hi[11:9], bl0c_hi[11:9]};
			bl_en1_vec <= {4{bl0c_hi[0]}};
`ifdef CFG_ROP_ENABLE_LOGICOP
			lop_en1 <= lop_en0c;
			lop_op1 <= lop_op0c;
`endif
			o1 <= o0c;
			d1 <= d0c;
		end

		/* Stages 2 & 3 (cycles 4 -> 5 -> 6): Factor selection & 2-stage DSP multiply */
		for (gl = 0; gl < 4; gl = gl + 1) begin : g_l2
			wire [7:0] sa_cur = s1[32 * gl + 24 +: 8];
			wire [7:0] da_cur = d1[32 * gl + 24 +: 8];
			wire [7:0] sa_cur_01, sa_cur_23;
			wire [7:0] da_cur_01, da_cur_23;
`ifdef SYNTH_KINTEX7
			genvar gb;
			for (gb = 0; gb < 8; gb = gb + 1) begin : g_sada_buf
				(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sa01 (.I0(sa_cur[gb]), .O(sa_cur_01[gb]));
				(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sa23 (.I0(sa_cur[gb]), .O(sa_cur_23[gb]));
				(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_da01 (.I0(da_cur[gb]), .O(da_cur_01[gb]));
				(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_da23 (.I0(da_cur[gb]), .O(da_cur_23[gb]));
			end
`else
			assign sa_cur_01 = sa_cur;
			assign sa_cur_23 = sa_cur;
			assign da_cur_01 = da_cur;
			assign da_cur_23 = da_cur;
`endif
			wire [7:0] da_inv = ~da_cur;
			(* keep = "true" *) wire sat_cond = u8_lt(sa_cur, da_inv);
			(* keep = "true" *) wire [7:0] sat_a = sat_cond ? sa_cur : da_inv;
			wire [31:0] kc1_lane = kc1_l[gl];
			for (gc = 0; gc < 4; gc = gc + 1) begin : g_c2
				wire [26:0] bl1_lo = bl1_c_lo[gl][gc];
				wire [26:0] bl1_hi = bl1_c_hi[gl][gc];
				wire [7:0] sc = s1[32 * gl + 8 * gc +: 8];
				wire [7:0] dc = d1[32 * gl + 8 * gc +: 8];
				wire [7:0] sa_f = (gc < 2) ? sa_cur_01 : sa_cur_23;
				wire [7:0] da_f = (gc < 2) ? da_cur_01 : da_cur_23;
`ifdef CFG_ROP_DUAL_SOURCE
				wire [7:0] s1c = s1_1[32 * gl + 8 * gc +: 8];
				wire [7:0] s1a = s1_1[32 * gl + 24 +: 8];
`else
				wire [7:0] s1c = 8'd0;
				wire [7:0] s1a = 8'd0;
`endif
				wire [4:0] f_s_lo = gc == 3 ? {bl1_lo[25], bl1_lo[15:12]} : {bl1_lo[23], bl1_lo[4:1]};
				wire [4:0] f_d_lo = gc == 3 ? {bl1_lo[26], bl1_lo[19:16]} : {bl1_lo[24], bl1_lo[8:5]};
				wire [4:0] f_s_hi = gc == 3 ? {bl1_hi[25], bl1_hi[15:12]} : {bl1_hi[23], bl1_hi[4:1]};
				wire [4:0] f_d_hi = gc == 3 ? {bl1_hi[26], bl1_hi[19:16]} : {bl1_hi[24], bl1_hi[8:5]};
				wire [7:0] fs_base_lo = factor_nosat(f_s_lo, sc, dc, kc1_lane[8 * gc +: 8], sa_f, da_f, kc1_lane[31:24], s1c, s1a);
				wire [7:0] fd_base_lo = factor_nosat(f_d_lo, sc, dc, kc1_lane[8 * gc +: 8], sa_f, da_f, kc1_lane[31:24], s1c, s1a);
				wire [7:0] fs_base_hi = factor_nosat(f_s_hi, sc, dc, kc1_lane[8 * gc +: 8], sa_f, da_f, kc1_lane[31:24], s1c, s1a);
				wire [7:0] fd_base_hi = factor_nosat(f_d_hi, sc, dc, kc1_lane[8 * gc +: 8], sa_f, da_f, kc1_lane[31:24], s1c, s1a);
				wire [7:0] fs_base = {fs_base_hi[7:4], fs_base_lo[3:0]};
				wire [7:0] fd_base = {fd_base_hi[7:4], fd_base_lo[3:0]};
				wire is_sat_s = (gc < 3) && (f_s_hi == 5'd14);
				wire is_sat_d = (gc < 3) && (f_d_hi == 5'd14);
`ifdef SYNTH_KINTEX7
				(* keep = "true", dont_touch = "true" *) wire is_sat_s_lo, is_sat_s_hi;
				(* keep = "true", dont_touch = "true" *) wire is_sat_d_lo, is_sat_d_hi;
				LUT1 #(.INIT(2'h2)) u_sat_s_lo (.I0(is_sat_s), .O(is_sat_s_lo));
				LUT1 #(.INIT(2'h2)) u_sat_s_hi (.I0(is_sat_s), .O(is_sat_s_hi));
				LUT1 #(.INIT(2'h2)) u_sat_d_lo (.I0(is_sat_d), .O(is_sat_d_lo));
				LUT1 #(.INIT(2'h2)) u_sat_d_hi (.I0(is_sat_d), .O(is_sat_d_hi));
				wire [7:0] fs = {is_sat_s_hi ? sat_a[7:4] : fs_base[7:4], is_sat_s_lo ? sat_a[3:0] : fs_base[3:0]};
				wire [7:0] fd = {is_sat_d_hi ? sat_a[7:4] : fd_base[7:4], is_sat_d_lo ? sat_a[3:0] : fd_base[3:0]};
`else
				wire [7:0] fs = is_sat_s ? sat_a : fs_base;
				wire [7:0] fd = is_sat_d ? sat_a : fd_base;
`endif
				wire [15:0] pp2, qq2;
				am_mul #(.AW(8), .BW(8), .LAT(2)) u_p (.clk(b_clk), .en(1'b1), .a(sc), .b(fs), .p(pp2));
				am_mul #(.AW(8), .BW(8), .LAT(2)) u_q (.clk(b_clk), .en(1'b1), .a(dc), .b(fd), .p(qq2));
				wire unused_bl1_ch = &{1'b0, fs_base_lo[7:4], fd_base_lo[7:4], fs_base_hi[3:0], fd_base_hi[3:0],
					bl1_lo[22:20], bl1_lo[11:9], bl1_lo[0], bl1_hi[22:20], bl1_hi[11:9], bl1_hi[0],
					(gc == 3 ? {bl1_lo[24:23], bl1_lo[8:1], bl1_hi[24:23], bl1_hi[8:1]} :
					           {bl1_lo[26:25], bl1_lo[19:12], bl1_hi[26:25], bl1_hi[19:12]})};
			end
		end

		/* Matching pipeline registers for S2 (v1_m) and S3 (v2) */
		reg [127:0] s1_m, d1_m, o1_m, o2;
		(* keep = "true", dont_touch = "true" *) reg [3:0] wm1_m [0:3];
		reg [3:0] m1_m;
		reg [2:0] fmt1_m;
		(* keep = "true", dont_touch = "true" *) reg [11:0] op1_vec_m [0:3];
		(* keep = "true", dont_touch = "true" *) reg [3:0] bl_en1_vec_m [0:3];
`ifdef CFG_ROP_ENABLE_LOGICOP
		(* keep = "true", dont_touch = "true" *) reg lop_en1_m [0:3][0:3];
		(* keep = "true", dont_touch = "true" *) reg [3:0] lop_op1_m [0:3][0:3];
`endif
		reg sv_lt_dv_m [0:3][0:3];
		reg sv_gt_dv_m [0:3][0:3];

		(* keep = "true", dont_touch = "true" *) reg op_inv_p2 [0:3][0:3];
		(* keep = "true", dont_touch = "true" *) reg op_inv_q2 [0:3][0:3];
		(* keep = "true", dont_touch = "true" *) reg op_sub2 [0:3][0:3];
		(* keep = "true", dont_touch = "true" *) reg op_dq2 [0:3][0:3];
		(* keep = "true", dont_touch = "true" *) reg use_dq_en2 [0:3][0:3];
		(* keep = "true", dont_touch = "true" *) reg [7:0] r8_bp2 [0:3][0:3];
		reg [2:0] fmt2_arr [0:3];
		reg [3:0] m2_arr [0:3];

		wire [7:0] r8_bp2_n [0:3][0:3];
		for (gl = 0; gl < 4; gl = gl + 1) begin : g_bp2_l
			for (gc = 0; gc < 4; gc = gc + 1) begin : g_bp2_c
				wire [2:0] op_c = op1_vec_m[gl][3 * gc +: 3];
				wire [7:0] sv_c = s1_m[32 * gl + 8 * gc +: 8];
				wire [7:0] dv_c = d1_m[32 * gl + 8 * gc +: 8];
				wire wm_c = wm1_m[gl][gc];
				wire bl_en_c = bl_en1_vec_m[gl][gc];
				wire lt_c = sv_lt_dv_m[gl][gc];
				wire gt_c = sv_gt_dv_m[gl][gc];
`ifdef CFG_ROP_ENABLE_LOGICOP
				wire lop_en_c = lop_en1_m[gl][gc];
				wire [3:0] lop_op_c = lop_op1_m[gl][gc];
`endif
				reg [7:0] bp_mux;
				always @(*) begin
					if (!wm_c)
						bp_mux = dv_c;
`ifdef CFG_ROP_ENABLE_LOGICOP
					else if (lop_en_c)
						bp_mux = calc_logic_op(lop_op_c, sv_c, dv_c);
`endif
					else if (!bl_en_c)
						bp_mux = sv_c;
					else if (op_c == 3'd3)
						bp_mux = lt_c ? sv_c : dv_c;
					else if (op_c == 3'd4)
						bp_mux = gt_c ? sv_c : dv_c;
					else
						bp_mux = 8'd0;
				end
`ifdef SYNTH_KINTEX7
				genvar gb;
				for (gb = 0; gb < 8; gb = gb + 1) begin : g_bp_buf
					(* keep = "true", dont_touch = "true" *)
					LUT1 #(.INIT(2'h2)) u_bp (.I0(bp_mux[gb]), .O(r8_bp2_n[gl][gc][gb]));
				end
`else
				assign r8_bp2_n[gl][gc] = bp_mux;
`endif
			end
		end

		integer il, ic;
		reg [2:0] op_cur;
		always @(posedge b_clk) begin
			/* S2 (cycle 4 -> 5) */
			v1_m <= !rst_sync && v1;
			s1_m <= s1;
			d1_m <= d1;
			o1_m <= o1;
			fmt1_m <= fmt1;
			m1_m <= m1;
			for (il = 0; il < 4; il = il + 1) begin
				wm1_m[il] <= wm1;
				op1_vec_m[il] <= op1_vec;
				bl_en1_vec_m[il] <= bl_en1_vec;
				for (ic = 0; ic < 4; ic = ic + 1) begin
`ifdef CFG_ROP_ENABLE_LOGICOP
					lop_en1_m[il][ic] <= lop_en1;
					lop_op1_m[il][ic] <= lop_op1;
`endif
					sv_lt_dv_m[il][ic] <= u8_lt(s1[32 * il + 8 * ic +: 8], d1[32 * il + 8 * ic +: 8]);
					sv_gt_dv_m[il][ic] <= u8_lt(d1[32 * il + 8 * ic +: 8], s1[32 * il + 8 * ic +: 8]);
				end
			end

			/* S3 (cycle 5 -> 6) */
			v2 <= !rst_sync && v1_m;
			o2 <= o1_m;
			for (il = 0; il < 4; il = il + 1) begin
				fmt2_arr[il] <= fmt1_m;
				m2_arr[il] <= m1_m;
				for (ic = 0; ic < 4; ic = ic + 1) begin
					op_cur = op1_vec_m[il][3 * ic +: 3];
					op_inv_p2[il][ic] <= (op_cur == 3'd2);
					op_inv_q2[il][ic] <= (op_cur == 3'd1);
					op_sub2[il][ic]   <= (op_cur == 3'd1) || (op_cur == 3'd2);
					op_dq2[il][ic]    <= (op_cur != 3'd1) && (op_cur != 3'd2) && (op_cur != 3'd3) && (op_cur != 3'd4);
`ifdef CFG_ROP_ENABLE_LOGICOP
					use_dq_en2[il][ic] <= wm1_m[il][ic] && bl_en1_vec_m[il][ic] && !lop_en1_m[il][ic];
`else
					use_dq_en2[il][ic] <= wm1_m[il][ic] && bl_en1_vec_m[il][ic];
`endif
					r8_bp2[il][ic] <= r8_bp2_n[il][ic];
				end
			end
		end

		/* Stages 4, 5, 6, 7, 8 (cycles 6 -> 7 -> 8 -> 9 -> 10 -> 11) */
		reg [127:0] o_s4, o_s5, o_s6, o_s7;
		reg [2:0] fmt_s4 [0:3], fmt_s5 [0:3], fmt_s6 [0:3];
		(* keep = "true", dont_touch = "true" *) reg [2:0] fmt_s7_lo [0:3];
		(* keep = "true", dont_touch = "true" *) reg [2:0] fmt_s7_hi [0:3];
		reg [3:0] m_s4 [0:3], m_s5 [0:3], m_s6 [0:3];
		(* keep = "true", dont_touch = "true" *) reg m_s7_lo [0:3];
		(* keep = "true", dont_touch = "true" *) reg m_s7_hi [0:3];

		always @(posedge b_clk) begin
			v_s4 <= !rst_sync && v2;
			v_s5 <= !rst_sync && v_s4;
			v_s6 <= !rst_sync && v_s5;
			v_s7 <= !rst_sync && v_s6;
			b_rvalid <= !rst_sync && v_s7;

			o_s4 <= o2;
			o_s5 <= o_s4;
			o_s6 <= o_s5;
			o_s7 <= o_s6;

			for (il = 0; il < 4; il = il + 1) begin
				fmt_s4[il] <= fmt2_arr[il];
				fmt_s5[il] <= fmt_s4[il];
				fmt_s6[il] <= fmt_s5[il];
				fmt_s7_lo[il] <= fmt_s6[il];
				fmt_s7_hi[il] <= fmt_s6[il];

				m_s4[il] <= m2_arr[il];
				m_s5[il] <= m_s4[il];
				m_s6[il] <= m_s5[il];
				m_s7_lo[il] <= m_s6[il][il];
				m_s7_hi[il] <= m_s6[il][il];
			end
		end

		wire [127:0] pix_s8;
		for (gl = 0; gl < 4; gl = gl + 1) begin : g_l3
			for (gc = 0; gc < 4; gc = gc + 1) begin : g_c3
				wire [15:0] pp = g_l2[gl].g_c2[gc].pp2;
				wire [15:0] qq = g_l2[gl].g_c2[gc].qq2;

				/* S4 (cycle 6 -> 7): Post-DSP register (1 LUT after DSP PREG) */
				reg [15:0] p_s4, q_s4;
				reg op_sub_s4, op_dq_s4, use_dq_en_s4;
				reg [7:0] r8_bp_s4;
				always @(posedge b_clk) begin
					p_s4 <= op_inv_p2[gl][gc] ? ~pp : pp;
					q_s4 <= op_inv_q2[gl][gc] ? ~qq : qq;
					op_sub_s4 <= op_sub2[gl][gc];
					op_dq_s4 <= op_dq2[gl][gc];
					use_dq_en_s4 <= use_dq_en2[gl][gc];
					r8_bp_s4 <= r8_bp2[gl][gc];
				end

				/* S5 (cycle 7 -> 8): 16-bit add/sub (Pre-LUTs = 0, Post-LUTs = 1) */
				wire [15:0] pq_w;
				wire pq_co_w;
				am_add #(.W(16)) u_pq (
					.a(p_s4), .b(q_s4), .ci(op_sub_s4), .s(pq_w), .co(pq_co_w)
				);
				reg [15:0] pq_s5;
				reg x16_s5, use_dq_s5;
				reg [7:0] r8_bp_s5;
				always @(posedge b_clk) begin
					pq_s5 <= pq_w;
					x16_s5 <= !op_sub_s4 && pq_co_w;
					use_dq_s5 <= use_dq_en_s4 && (op_sub_s4 ? pq_co_w : op_dq_s4);
					r8_bp_s5 <= r8_bp_s4;
				end

				/* S6 (cycle 8 -> 9): div255 3:2 compressor (pure LUT, 0 CARRY4s) */
				wire [16:0] x_s5 = {x16_s5, pq_s5};
				wire [16:0] u_w, v_w;
				assign u_w[0] = x_s5[0] ^ x_s5[8] ^ x_s5[7];
				assign v_w[0] = 1'b0;
				assign u_w[1] = x_s5[1] ^ x_s5[9];
				assign v_w[1] = (x_s5[0] & x_s5[8]) | (x_s5[8] & x_s5[7]) | (x_s5[0] & x_s5[7]);
				assign u_w[2] = x_s5[2] ^ x_s5[10];
				assign v_w[2] = x_s5[1] & x_s5[9];
				assign u_w[3] = x_s5[3] ^ x_s5[11];
				assign v_w[3] = x_s5[2] & x_s5[10];
				assign u_w[4] = x_s5[4] ^ x_s5[12];
				assign v_w[4] = x_s5[3] & x_s5[11];
				assign u_w[5] = x_s5[5] ^ x_s5[13];
				assign v_w[5] = x_s5[4] & x_s5[12];
				assign u_w[6] = x_s5[6] ^ x_s5[14];
				assign v_w[6] = x_s5[5] & x_s5[13];
				assign u_w[7] = ~(x_s5[7] ^ x_s5[15]);
				assign v_w[7] = x_s5[6] & x_s5[14];
				assign u_w[8] = x_s5[8] ^ x_s5[16];
				assign v_w[8] = x_s5[7] | x_s5[15];
				assign u_w[9] = x_s5[9];
				assign v_w[9] = x_s5[8] & x_s5[16];
				assign u_w[16:10] = x_s5[16:10];
				assign v_w[16:10] = 7'd0;
				wire y16_w = x_s5[16] | (&x_s5[15:7]);

				reg [16:0] u_s6, v_s6;
				reg y16_s6, use_dq_s6;
				reg [7:0] r8_bp_s6;
				always @(posedge b_clk) begin
					u_s6 <= u_w;
					v_s6 <= v_w;
					y16_s6 <= y16_w;
					use_dq_s6 <= use_dq_s5;
					r8_bp_s6 <= r8_bp_s5;
				end

				/* S7 (cycle 9 -> 10): div255 17-bit add + clamp/bypass mux (Pre=0, Post=1) */
				wire [16:0] div_s_w;
				wire div_co_unused;
				am_add #(.W(17)) u_div_add (
					.a(u_s6), .b(v_s6), .ci(y16_s6), .s(div_s_w), .co(div_co_unused)
				);
				wire [7:0] ch_s7_w = use_dq_s6 ? ({8{div_s_w[16]}} | div_s_w[15:8]) : r8_bp_s6;
				(* keep = "true", dont_touch = "true" *) reg [7:0] ch_raw_s7;
				(* keep = "true", dont_touch = "true" *) reg [7:0] ch_rom_u5_s7;
				(* keep = "true", dont_touch = "true" *) reg [7:0] ch_rom_u6_s7;
				always @(posedge b_clk) begin
					ch_raw_s7 <= ch_s7_w;
					ch_rom_u5_s7 <= ch_s7_w;
					ch_rom_u6_s7 <= ch_s7_w;
				end
				wire unused_div = &{1'b0, div_co_unused, div_s_w[7:0]};
			end

			/* S8 (cycle 10 -> 11): ROM lookup + format pack -> registered b_pix */
			wire [31:0] o_lane = o_s7[32 * gl +: 32];
			wire [7:0] ch0 = g_c3[0].ch_raw_s7;
			wire [7:0] ch1 = g_c3[1].ch_raw_s7;
			wire [7:0] ch2 = g_c3[2].ch_raw_s7;
			wire [7:0] ch3 = g_c3[3].ch_raw_s7;

			wire [4:0] r5 = rom_u5[g_c3[0].ch_rom_u5_s7];
			wire [5:0] g6 = rom_u6[g_c3[1].ch_rom_u6_s7];
			wire [4:0] g5 = rom_u5[g_c3[1].ch_rom_u5_s7];
			wire [4:0] b5 = rom_u5[g_c3[2].ch_rom_u5_s7];
			wire a1 = ch3[7];

			wire [2:0] fmt_lo_cur = fmt_s7_lo[gl];
			wire [2:0] fmt_hi_cur = fmt_s7_hi[gl];
			reg [15:0] px_out_lo, px_out_hi;
			always @(*) begin
				case (fmt_lo_cur)
				F_BGRA8: px_out_lo = {ch1, ch2};
				F_RGBA8: px_out_lo = {ch1, ch0};
				F_R8:    px_out_lo = {o_lane[15:8], ch0};
				F_RG8:   px_out_lo = {ch1, ch0};
				F_565:   px_out_lo = {r5, g6, b5};
				F_1555:  px_out_lo = {a1, r5, g5, b5};
				default: px_out_lo = o_lane[15:0];
				endcase
				case (fmt_hi_cur)
				F_BGRA8: px_out_hi = {ch3, ch0};
				F_RGBA8: px_out_hi = {ch3, ch2};
				default: px_out_hi = o_lane[31:16];
				endcase
			end
			assign pix_s8[32 * gl +: 16]      = m_s7_lo[gl] ? px_out_lo : o_lane[15:0];
			assign pix_s8[32 * gl + 16 +: 16] = m_s7_hi[gl] ? px_out_hi : o_lane[31:16];
			wire unused_rom3 = &{1'b0, g_c3[0].ch_rom_u6_s7, g_c3[2].ch_rom_u6_s7, g_c3[3].ch_rom_u5_s7, g_c3[3].ch_rom_u6_s7};
		end

		always @(posedge b_clk) begin
			b_pix <= pix_s8;
		end
	end
	endgenerate

	wire unused_ok = &{1'b0, (LAT != 0), (MRT_COUNT != 0), b_has_src1, dual_src_en, st_idx[8:2]};
endmodule

/*
 * 3-stage pipelined fp32-to-unorm8 converter (Pre-CARRY4 LUTs = 0, Post-CARRY4 LUTs <= 1)
 */
(* keep_hierarchy = "yes" *)
module atg_rop_blend_f2u8_pipe (
	input wire clk,
	input wire rst_sync,
	input wire [31:0] f,
	(* keep = "true", dont_touch = "true" *) output reg [7:0] u
);
	/* Stage 1: p = (m << 8) - m, pure-LUT shift amount t = 14 - e[3:0], sticky bit, range/sat flags */
	wire [31:0] p_w;
	wire p_bo_unused;
	am_sub #(.W(32)) u_p (
		.a({1'b1, f[22:0], 8'd0}),
		.b({8'd0, 1'b1, f[22:0]}),
		.bi(1'b0),
		.d(p_w),
		.bo(p_bo_unused)
	);

	wire [3:0] e_lo = f[26:23];
	(* keep = "true" *) wire [3:0] t_w = {
		~(e_lo[3] ^ (e_lo[2] & e_lo[1] & e_lo[0])),
		~(e_lo[2] ^ (e_lo[1] & e_lo[0])),
		~(e_lo[1] ^ e_lo[0]),
		e_lo[0]
	};

	(* keep = "true" *) wire [3:0] m_nz;
	assign m_nz[0] = (f[5:0]   != 6'd0);
	assign m_nz[1] = (f[11:6]  != 6'd0);
	assign m_nz[2] = (f[17:12] != 6'd0);
	assign m_nz[3] = (f[22:18] != 5'd0);
	wire mant_nz = |m_nz;
	wire st_w = mant_nz || (e_lo != 4'd14);

	wire [7:0] e = f[30:23];
	wire is_nan = (e == 8'hFF) && mant_nz;
	wire in_range_w = !f[31] && (e[7:4] == 4'b0111) && (e_lo != 4'b1111) &&
		(e_lo[3] || (e_lo[2] && (e_lo[1] || e_lo[0])));
	wire sat_w = !f[31] && (e[7] || (&e[6:0])) && !is_nan;

	reg [17:0] p_s1;
	reg [3:0] t_s1;
	reg st_s1, in_range_s1, sat_s1;
	always @(posedge clk) begin
		p_s1 <= p_w[31:14];
		t_s1 <= t_w;
		st_s1 <= st_w;
		in_range_s1 <= in_range_w;
		sat_s1 <= sat_w;
	end

	/* Stage 2: 18-bit right shift by t_s1 (0..9) + RNE carry-in */
	wire [17:0] sh_w;
	am_shift #(.W(18), .SW(4)) u_sh (
		.a(p_s1), .amt(t_s1), .left(1'b0), .arith(1'b0), .y(sh_w)
	);
	reg [7:0] hi_s2;
	reg ci_s2, in_range_s2, sat_s2;
	always @(posedge clk) begin
		hi_s2 <= sh_w[17:10];
		ci_s2 <= sh_w[9] && (st_s1 || sh_w[10]);
		in_range_s2 <= in_range_s1;
		sat_s2 <= sat_s1;
	end

	/* Stage 3: 8-bit RNE rounding add + clamp mux -> registered u */
	wire [7:0] r_w;
	wire r_co_unused;
	am_add #(.W(8)) u_r (
		.a(hi_s2), .b(8'd0), .ci(ci_s2), .s(r_w), .co(r_co_unused)
	);
	always @(posedge clk) begin
		u <= sat_s2 ? 8'hFF : (in_range_s2 ? r_w : 8'h00);
	end

	wire unused_f2u8 = &{1'b0, rst_sync, p_bo_unused, p_w[13:0], sh_w[8:0], r_co_unused};
endmodule

`default_nettype wire
