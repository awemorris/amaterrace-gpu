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
 *
 * Three stages, 4 pixels per cycle: (1) the source to unorm8 (RNE), the
 * destination unpacked to RGBA8; (2) the factor products; (3) the
 * operation, round(x / 255), WRITE_MASK and packing.  The blend runs on
 * 8-bit unorm channels.  With CAPS[30] b_rt chooses the attachment's
 * BLEND word (0x07A, BLEND1-3), write mask (WRITE_MASK[4 rt +: 4]) and
 * format (RT_FORMATS byte rt, or attachment 0's RT_FORMAT code when that
 * byte is 0): VkFormat 44 B8G8R8A8, 37 and 51 R8G8B8A8, 4 R5G6B5, 9 R8,
 * 16 R8G8, 8 A1R5G5B5 (the pixel in the low bytes of its 32-bit lane;
 * formats without alpha read a destination alpha of 255, missing colours 0
 * and are not written); any other format writes nothing.  The constant is
 * BLEND_CONST's bytes, or with ROP_CTRL[1] the fp32 BLEND_CONST_R-A
 * clamped and rounded to 8 bits when written.  See
 * spec/gpu/rop/atg_rop_blend.md.
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

`ifndef CFG_ROP_MRT_COUNT
`define CFG_ROP_MRT_COUNT 1
`endif

module atg_rop_blend #(
	parameter LAT = 3,	/* Pipeline cycles from b_valid to b_rvalid (the RTL has 3) */
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

	/* Distributed ROM tables for round(v * 31 / 255) and round(v * 63 / 255).
	 * Maps to Xilinx SLICEM distributed ROM using fast MUXF7/MUXF8 structures. */
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

	/* STATE: RT_FORMAT 0x072, BLEND 0x07A, BLEND_CONST 0x07B, WRITE_MASK 0x07C,
	 * RT_FORMATS 0x07D, BLEND1-3 0x084-0x086, BLEND_CONST_R-A 0x087-0x08A,
	 * ROP_CTRL 0x08D, LOGIC_OP 0x08E; RT_EXT 0x1B0-0x1BD (Phase 003: MRT 8). */
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
	wire [1:0] s_k;
	wire s_k_co_unused;
	am_add #(.W(2)) u_s_k (.a(st_idx[1:0]), .b(2'd0), .ci(1'b1), .s(s_k), .co(s_k_co_unused));

	/* Extended ROP space for RT4-7 (0x1B0-0x1BF, CAPS[30]) */
	/* verilator lint_off UNUSEDSIGNAL */
	wire [8:0] s_ext;
	/* verilator lint_on UNUSEDSIGNAL */
	wire s_ext_bo_unused;
	am_sub #(.W(9)) u_s_ext (.a(st_idx), .b(GHCI_S_RT_EXT), .bi(1'b0), .d(s_ext),
		.bo(s_ext_bo_unused));

	wire [7:0] kcf_n;
	atg_rop_f2u8 u_kcf (.f(st_wdata), .u(kcf_n));
	integer i;
	always @(posedge clk)
		if (!rst_n) begin
			fmt0 <= 2'd0;
			fmts <= 64'd0;
			for (i = 0; i < 8; i = i + 1) begin
				bls[i] <= 27'd0;
`ifdef CFG_ROP_ENABLE_LOGICOP
				lop_en[i] <= 1'b0;
				lop_op[i] <= 4'd0;
`endif
			end
			kc8 <= 32'd0;
			kcf <= 32'd0;
			kc_sel <= 1'b0;
`ifdef CFG_ROP_DUAL_SOURCE
			dual_src_en <= 1'b0;
`endif
			wms <= 32'd0;
		end else if (st_we) begin
			if (st_idx == GHCI_S_RT_FORMAT)
				fmt0 <= st_wdata[1:0];
			if (st_idx == GHCI_S_RT_FORMATS)
				fmts[31:0] <= st_wdata;
			if (st_idx == GHCI_S_RT_FORMATS1)
				fmts[63:32] <= st_wdata;
			if (st_idx == GHCI_S_BLEND)
				bls[0] <= st_wdata[26:0];
			if (st_idx >= GHCI_S_BLEND1 && st_idx < GHCI_S_BLEND1 + 9'd3)
				bls[{1'b0, s_k}] <= st_wdata[26:0];
			if (st_idx >= GHCI_S_BLEND4 && st_idx < GHCI_S_BLEND4 + 9'd4)
				for (i = 0; i < 4; i = i + 1)
					if (s_ext[1:0] == i[1:0])
						bls[{1'b1, i[1:0]}] <= st_wdata[26:0];
			if (st_idx == GHCI_S_BLEND_CONST)
				kc8 <= st_wdata;
			if (st_idx >= GHCI_S_BLEND_CONST_R && st_idx < GHCI_S_BLEND_CONST_R + 9'd4)
				kcf[8 * s_k +: 8] <= kcf_n;
			if (st_idx == GHCI_S_ROP_CTRL) begin
				kc_sel <= st_wdata[1];
`ifdef CFG_ROP_DUAL_SOURCE
				dual_src_en <= st_wdata[7];
`endif
`ifdef CFG_ROP_ENABLE_LOGICOP
				for (i = 0; i < 8; i = i + 1) begin
					lop_en[i] <= st_wdata[2];
					lop_op[i] <= st_wdata[6:3];
				end
`endif
			end
`ifdef CFG_ROP_ENABLE_LOGICOP
			if (st_idx == GHCI_S_LOGIC_OP) begin
				if (st_wdata[31:8] == 24'd0) begin
					for (i = 0; i < 8; i = i + 1) begin
						lop_en[i] <= st_wdata[0];
						lop_op[i] <= st_wdata[4:1];
					end
				end else begin
					lop_en[0] <= st_wdata[0];
					lop_op[0] <= st_wdata[4:1];
					lop_en[1] <= st_wdata[8];
					lop_op[1] <= st_wdata[12:9];
					lop_en[2] <= st_wdata[16];
					lop_op[2] <= st_wdata[20:17];
					lop_en[3] <= st_wdata[24];
					lop_op[3] <= st_wdata[28:25];
				end
			end
`endif
			if (st_idx == GHCI_S_WRITE_MASK) begin
				wms[15:0] <= st_wdata[15:0];
				if (st_wdata[31:16] != 16'd0)
					wms[31:16] <= st_wdata[31:16];
			end
			if (st_idx == GHCI_S_WRITE_MASK1)
				wms[31:16] <= st_wdata[15:0];
		end
	wire [31:0] kc = kc_sel ? kcf : kc8;
	/* the beat's attachment */
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

	genvar gl, gc;

	/* Stage 1: RGBA8 per lane, channel c of lane l at [32l + 8c]. */
	wire [127:0] s1_n;
	integer l;
	generate
	for (gl = 0; gl < 16; gl = gl + 1) begin : g_f2u8
		atg_rop_f2u8 u_f2u8 (.f(b_src[128 * (gl / 4) + 32 * (gl % 4) +: 32]),
			.u(s1_n[32 * (gl / 4) + 8 * (gl % 4) +: 8]));
	end
	endgenerate

`ifdef CFG_ROP_DUAL_SOURCE
	wire [127:0] s1_1_n;
	generate
	for (gl = 0; gl < 16; gl = gl + 1) begin : g_f2u8_1
		atg_rop_f2u8 u_f2u8_1 (.f(b_src1[128 * (gl / 4) + 32 * (gl % 4) +: 32]),
			.u(s1_1_n[32 * (gl / 4) + 8 * (gl % 4) +: 8]));
	end
	endgenerate
`else
	wire [127:0] s1_1_n = 128'd0;
	wire unused_src1 = &{1'b0, b_src1, b_has_src1};
`endif

	reg [127:0] d1_n;
	reg [31:0] dp;
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

	reg v1;
	reg [3:0] m1, wm1;
	reg [2:0] fmt1;
	reg [26:0] bl1;
	reg [11:0] op1_vec;
	reg [3:0] bl_en1_vec;
`ifdef CFG_ROP_ENABLE_LOGICOP
	reg lop_en1;
	reg [3:0] lop_op1;
`endif
	reg [31:0] kc1;
	reg [127:0] s1, o1;
	(* extract_reset = "no", extract_enable = "no", use_sync_set = "no", use_sync_reset = "no" *) reg [127:0] d1;
`ifdef CFG_ROP_DUAL_SOURCE
	reg [127:0] s1_1;
	reg dual_src_en1;
`endif
	always @(posedge clk) begin
		v1 <= rst_n && b_valid;
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
		dual_src_en1 <= rst_n && dual_src_en;
`endif
		d1 <= d1_n;
	end

	/* Stage 2: p = s x Fs, q = d x Fd, registered in DSP PREG (LAT=1). */
	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_l2
		wire [7:0] sa_cur = s1[32 * gl + 24 +: 8];
		wire [7:0] da_cur = d1[32 * gl + 24 +: 8];
		(* max_fanout = 8 *) wire sat_cond = (sa_cur < ~da_cur);
		wire [7:0] sat_a = sat_cond ? sa_cur : ~da_cur;
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
			wire [7:0] sa = sa_cur;
			wire [7:0] da = da_cur;
			wire [4:0] f_s = gc == 3 ? {bl1[25], bl1[15:12]} : {bl1[23], bl1[4:1]};
			wire [4:0] f_d = gc == 3 ? {bl1[26], bl1[19:16]} : {bl1[24], bl1[8:5]};
			wire [7:0] fs_base = factor_nosat(f_s, sc, dc, kc1[8 * gc +: 8], sa, da, kc1[31:24], s1c, s1a);
			wire [7:0] fd_base = factor_nosat(f_d, sc, dc, kc1[8 * gc +: 8], sa, da, kc1[31:24], s1c, s1a);
			wire is_sat_s = (gc < 3) && (f_s == 5'd14);
			wire is_sat_d = (gc < 3) && (f_d == 5'd14);
			wire [7:0] fs = is_sat_s ? sat_a : fs_base;
			wire [7:0] fd = is_sat_d ? sat_a : fd_base;
			wire [15:0] pp2, qq2;
			am_mul #(.AW(8), .BW(8), .LAT(1)) u_p (.clk(clk), .en(1'b1), .a(sc), .b(fs),
				.p(pp2));
			am_mul #(.AW(8), .BW(8), .LAT(1)) u_q (.clk(clk), .en(1'b1), .a(dc), .b(fd),
				.p(qq2));
		end
	end
	endgenerate

	reg v2;
	reg [127:0] s2, d2, o2;
	(* EQUIVALENT_REGISTER_REMOVAL = "NO" *) reg [2:0] op2 [0:3][0:3];
	(* EQUIVALENT_REGISTER_REMOVAL = "NO" *) reg op_sub2 [0:3][0:3];
	(* EQUIVALENT_REGISTER_REMOVAL = "NO" *) reg op_rsub2_a [0:3][0:3];
	(* EQUIVALENT_REGISTER_REMOVAL = "NO" *) reg op_rsub2_b [0:3][0:3];
	(* EQUIVALENT_REGISTER_REMOVAL = "NO" *) reg op_dq2 [0:3][0:3];
	(* EQUIVALENT_REGISTER_REMOVAL = "NO" *) reg bl_en2 [0:3][0:3];
	reg [3:0] wm2_arr [0:3];
	reg [2:0] fmt2_arr [0:3];
	reg [3:0] m2_arr [0:3];
`ifdef CFG_ROP_ENABLE_LOGICOP
	reg lop_en2;
	reg [3:0] lop_op2;
`endif
`ifdef CFG_ROP_DUAL_SOURCE
	reg dual_src_en2;
`endif
	integer il, ic;
	always @(posedge clk) begin
		v2 <= rst_n && v1;
		s2 <= s1;
		d2 <= d1;
		o2 <= o1;
		for (il = 0; il < 4; il = il + 1) begin
			wm2_arr[il] <= wm1;
			fmt2_arr[il] <= fmt1;
			m2_arr[il] <= m1;
			for (ic = 0; ic < 4; ic = ic + 1) begin
				op2[il][ic] <= op1_vec[3 * ic +: 3];
				op_sub2[il][ic] <= (op1_vec[3 * ic +: 3] == 3'd1) || (op1_vec[3 * ic +: 3] == 3'd2);
				op_rsub2_a[il][ic] <= (op1_vec[3 * ic +: 3] == 3'd2);
				op_rsub2_b[il][ic] <= (op1_vec[3 * ic +: 3] == 3'd2);
				op_dq2[il][ic] <= (op1_vec[3 * ic +: 3] != 3'd1) && (op1_vec[3 * ic +: 3] != 3'd2)
				               && (op1_vec[3 * ic +: 3] != 3'd3) && (op1_vec[3 * ic +: 3] != 3'd4);
				bl_en2[il][ic] <= bl_en1_vec[ic];
			end
		end
`ifdef CFG_ROP_ENABLE_LOGICOP
		lop_en2 <= lop_en1;
		lop_op2 <= lop_op1;
`endif
`ifdef CFG_ROP_DUAL_SOURCE
		dual_src_en2 <= rst_n && dual_src_en1;
`endif
	end

	/* Stage 3: the operation, the mask, the format. */
	wire [127:0] pix_n;
	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_l3
		wire [31:0] r8;
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
				3'd3: r8_bp = (sv < dv) ? sv : dv;
				3'd4: r8_bp = (sv > dv) ? sv : dv;
				default: r8_bp = 8'd0;
				endcase
			end

`ifdef CFG_ROP_ENABLE_LOGICOP
			wire use_dq = wm2[gc] && bl_en && !lop_en2 && (op_sub ? pq_co : op_dq);
`else
			wire use_dq = wm2[gc] && bl_en && (op_sub ? pq_co : op_dq);
`endif
			wire [7:0] dq_sat = {8{dq[8]}} | dq[7:0];

			wire [4:0] t5_rom = rom_u5[dq[7:0]];
			wire [5:0] t6_rom = rom_u6[dq[7:0]];
			wire [4:0] t5_dq = {5{dq[8]}} | t5_rom;
			wire [5:0] t6_dq = {6{dq[8]}} | t6_rom;

			wire [4:0] t5_bp = rom_u5[r8_bp];
			wire [5:0] t6_bp = rom_u6[r8_bp];
		end
		wire [3:0] use_dq_ch = {g_c3[3].use_dq, g_c3[2].use_dq, g_c3[1].use_dq, g_c3[0].use_dq};
		wire [31:0] o2_lane = o2[32 * gl +: 32];

		/* Per-channel blended results (8-bit) */
		wire [7:0] ch0 = use_dq_ch[0] ? g_c3[0].dq_sat : g_c3[0].r8_bp;
		wire [7:0] ch1 = use_dq_ch[1] ? g_c3[1].dq_sat : g_c3[1].r8_bp;
		wire [7:0] ch2 = use_dq_ch[2] ? g_c3[2].dq_sat : g_c3[2].r8_bp;
		wire [7:0] ch3 = use_dq_ch[3] ? g_c3[3].dq_sat : g_c3[3].r8_bp;

		/* 16-bit format converted components */
		wire [4:0] r5 = use_dq_ch[0] ? g_c3[0].t5_dq : g_c3[0].t5_bp;
		wire [5:0] g6 = use_dq_ch[1] ? g_c3[1].t6_dq : g_c3[1].t6_bp;
		wire [4:0] g5 = use_dq_ch[1] ? g_c3[1].t5_dq : g_c3[1].t5_bp;
		wire [4:0] b5 = use_dq_ch[2] ? g_c3[2].t5_dq : g_c3[2].t5_bp;
		wire a1 = use_dq_ch[3] ? g_c3[3].dq_sat[7] : g_c3[3].r8_bp[7];

		reg [31:0] px_out;
		always @(*) begin
			case (fmt2)
			F_BGRA8: px_out = {ch3, ch0, ch1, ch2};
			F_RGBA8: px_out = {ch3, ch2, ch1, ch0};
			F_R8:    px_out = {o2_lane[31:8], ch0};
			F_RG8:   px_out = {o2_lane[31:16], ch1, ch0};
			F_565:   px_out = {o2_lane[31:16], r5, g6, b5};
			F_1555:  px_out = {o2_lane[31:16], a1, r5, g5, b5};
			default: px_out = o2_lane;
			endcase
		end

		assign pix_n[32 * gl +: 32] = m2 ? px_out : o2_lane;
	end
	endgenerate
	always @(posedge clk) begin
		b_rvalid <= rst_n && v2;
		b_pix <= pix_n;
	end

`ifdef CFG_ROP_DUAL_SOURCE
	wire unused_ok = &{LAT != 0, (MRT_COUNT != 0), bl1[26:0], b_has_src1, dual_src_en, dual_src_en2};
`else
	wire unused_ok = &{LAT != 0, (MRT_COUNT != 0), bl1[26:0], dual_src_en, lop_en_n, lop_op_n, s1_1_n};
`endif
endmodule

`default_nettype wire
