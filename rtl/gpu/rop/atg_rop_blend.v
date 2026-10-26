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

module atg_rop_blend #(
	parameter LAT = 3	/* Pipeline cycles from b_valid to b_rvalid (the RTL has 3) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire b_valid,
	input wire [511:0] b_src,
	input wire [127:0] b_dst,
	input wire [3:0] b_mask,
	input wire [1:0] b_rt,
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

	/* STATE: RT_FORMAT 0x072, BLEND 0x07A, BLEND_CONST 0x07B, WRITE_MASK 0x07C,
	 * RT_FORMATS 0x07D, BLEND1-3 0x084-0x086, BLEND_CONST_R-A 0x087-0x08A,
	 * ROP_CTRL 0x08D. */
	reg [1:0] fmt0;	/* RT_FORMAT */
	reg [31:0] fmts;	/* RT_FORMATS */
	reg [22:0] bls [0:3];
	reg [31:0] kc8, kcf;	/* BLEND_CONST; the fp32 constants as bytes */
	reg kc_sel;	/* ROP_CTRL[1] */
	reg [15:0] wms;
	/* BLEND1-3 and BLEND_CONST_R-A: k = (st_idx - 3) mod 4 = st_idx[1:0] + 1 */
	wire [1:0] s_k;
	wire s_k_co_unused;
	am_add #(.W(2)) u_s_k (.a(st_idx[1:0]), .b(2'd0), .ci(1'b1), .s(s_k), .co(s_k_co_unused));
	wire [7:0] kcf_n;
	atg_rop_f2u8 u_kcf (.f(st_wdata), .u(kcf_n));
	integer i;
	always @(posedge clk)
		if (!rst_n) begin
			fmt0 <= 2'd0;
			fmts <= 32'd0;
			for (i = 0; i < 4; i = i + 1)
				bls[i] <= 23'd0;
			kc8 <= 32'd0;
			kcf <= 32'd0;
			kc_sel <= 1'b0;
			wms <= 16'd0;
		end else if (st_we) begin
			if (st_idx == GHCI_S_RT_FORMAT)
				fmt0 <= st_wdata[1:0];
			if (st_idx == GHCI_S_RT_FORMATS)
				fmts <= st_wdata;
			if (st_idx == GHCI_S_BLEND)
				bls[0] <= st_wdata[22:0];
			if (st_idx >= GHCI_S_BLEND1 && st_idx < GHCI_S_BLEND1 + 9'd3)
				bls[s_k] <= st_wdata[22:0];
			if (st_idx == GHCI_S_BLEND_CONST)
				kc8 <= st_wdata;
			if (st_idx >= GHCI_S_BLEND_CONST_R && st_idx < GHCI_S_BLEND_CONST_R + 9'd4)
				kcf[8 * s_k +: 8] <= kcf_n;
			if (st_idx == GHCI_S_ROP_CTRL)
				kc_sel <= st_wdata[1];
			if (st_idx == GHCI_S_WRITE_MASK)
				wms <= st_wdata[15:0];
		end
	wire [31:0] kc = kc_sel ? kcf : kc8;
	/* the beat's attachment */
	wire [7:0] fvk = fmts[8 * b_rt +: 8];
	wire [2:0] fmt_n = b_rt == 2'd0 && fvk == 8'd0 ? (fmt0 == 2'd0 ? F_BGRA8 :
		fmt0 == 2'd1 ? F_RGBA8 : F_565) : fcode(fvk);
	wire [22:0] bl_n = bls[b_rt];
	wire [3:0] wm_n = wms[4 * b_rt +: 4];

	function [7:0] factor;
		input [3:0] f;
		input [7:0] sc, dc, kcc, sa, da, ka;
		input is_a;
		case (f)
		4'd1: factor = 8'd255;
		4'd2: factor = sc;
		4'd3: factor = ~sc;
		4'd4: factor = dc;
		4'd5: factor = ~dc;
		4'd6: factor = sa;
		4'd7: factor = ~sa;
		4'd8: factor = da;
		4'd9: factor = ~da;
		4'd10: factor = kcc;
		4'd11: factor = ~kcc;
		4'd12: factor = ka;
		4'd13: factor = ~ka;
		4'd14: factor = is_a ? 8'd255 : (sa < ~da ? sa : ~da);
		default: factor = 8'd0;
		endcase
	endfunction

	genvar gl, gc;

	/* Stage 1: RGBA8 per lane, channel c of lane l at [32l + 8c]. */
	wire [127:0] s1_n;
	reg [127:0] d1_n;
	reg [31:0] dp;
	integer l;
	generate
	for (gl = 0; gl < 16; gl = gl + 1) begin : g_f2u8
		atg_rop_f2u8 u_f2u8 (.f(b_src[128 * (gl / 4) + 32 * (gl % 4) +: 32]),
			.u(s1_n[32 * (gl / 4) + 8 * (gl % 4) +: 8]));
	end
	endgenerate
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
	reg [3:0] m1, wm1, wm2;
	reg [2:0] fmt1, fmt2;
	reg [22:0] bl1, bl2;
	reg [31:0] kc1;
	reg [127:0] s1, d1, o1;
	always @(posedge clk) begin
		v1 <= rst_n && b_valid;
		m1 <= b_mask;
		fmt1 <= fmt_n;
		bl1 <= bl_n;
		wm1 <= wm_n;
		kc1 <= kc;
		o1 <= b_dst;
		s1 <= s1_n;
		d1 <= d1_n;
	end

	/* Stage 2: 16 multipliers (1 per channel).
	 * Standard alpha blend (SRC_ALPHA, ONE_MINUS_SRC_ALPHA) is transformed to Lerp:
	 *   D + (S - D) * alpha = D +/- round(|S - D| * alpha / 255)
	 * using only a single multiplication |S - D| * alpha per channel.
	 * For other factor modes (ZERO, ONE, single-factor modulate), u_m computes the required product.
	 */
	wire [255:0] m_n;
	wire [15:0] is_lerp_w, s_ge_d_w, is_one_one_w, fs_one_w, fd_one_w, fs_zero_w, fd_zero_w;
	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_l2
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_c2
			localparam integer IDX = 4 * gl + gc;
			wire [7:0] sc = s1[32 * gl + 8 * gc +: 8];
			wire [7:0] dc = d1[32 * gl + 8 * gc +: 8];
			wire [3:0] f_s_code = gc == 3 ? bl1[15:12] : bl1[4:1];
			wire [3:0] f_d_code = gc == 3 ? bl1[19:16] : bl1[8:5];
			wire [2:0] op_code = gc == 3 ? bl1[22:20] : bl1[11:9];

			wire [7:0] fs = factor(f_s_code, sc, dc, kc1[8 * gc +: 8],
				s1[32 * gl + 24 +: 8], d1[32 * gl + 24 +: 8], kc1[31:24], gc == 3);
			wire [7:0] fd = factor(f_d_code, sc, dc, kc1[8 * gc +: 8],
				s1[32 * gl + 24 +: 8], d1[32 * gl + 24 +: 8], kc1[31:24], gc == 3);

			assign is_lerp_w[IDX] = (op_code == 3'd0) && (
				(f_s_code == 4'd6 && f_d_code == 4'd7) ||
				(f_s_code == 4'd8 && f_d_code == 4'd9) ||
				(f_s_code == 4'd12 && f_d_code == 4'd13)
			);
			wire [7:0] alpha_val = (f_s_code == 4'd6) ? s1[32 * gl + 24 +: 8] :
			                       (f_s_code == 4'd8) ? d1[32 * gl + 24 +: 8] : kc1[31:24];

			assign s_ge_d_w[IDX] = (sc >= dc);
			wire [7:0] s_sub_d, d_sub_s;
			wire s_sub_bo_unused, d_sub_bo_unused;
			am_sub #(.W(8)) u_s_sub_d (.a(sc), .b(dc), .bi(1'b0), .d(s_sub_d), .bo(s_sub_bo_unused));
			am_sub #(.W(8)) u_d_sub_s (.a(dc), .b(sc), .bi(1'b0), .d(d_sub_s), .bo(d_sub_bo_unused));
			wire [7:0] diff = s_ge_d_w[IDX] ? s_sub_d : d_sub_s;

			assign is_one_one_w[IDX] = (f_s_code == 4'd1 && f_d_code == 4'd1);
			assign fs_one_w[IDX] = (f_s_code == 4'd1);
			assign fd_one_w[IDX] = (f_d_code == 4'd1);
			assign fs_zero_w[IDX] = (f_s_code == 4'd0);
			assign fd_zero_w[IDX] = (f_d_code == 4'd0);

			wire use_fd_w = (fs_one_w[IDX] && !fd_one_w[IDX]) || fs_zero_w[IDX];

			wire [7:0] ma = is_lerp_w[IDX] ? diff : (use_fd_w ? dc : sc);
			wire [7:0] mb = is_lerp_w[IDX] ? alpha_val : (use_fd_w ? fd : fs);

			am_mul #(.AW(8), .BW(8)) u_m (.clk(clk), .en(1'b1), .a(ma), .b(mb),
				.p(m_n[16 * IDX +: 16]));

			wire unused_l2 = &{1'b0, s_sub_bo_unused, d_sub_bo_unused};
		end
	end
	endgenerate
	reg v2;
	reg [3:0] m2;
	reg [127:0] s2, d2, o2;
	reg [255:0] m2_reg;
	reg [15:0] is_lerp2, s_ge_d2, is_one_one2, fs_one2, fd_one2, fs_zero2, fd_zero2;
	always @(posedge clk) begin
		v2 <= rst_n && v1;
		m2 <= m1;
		fmt2 <= fmt1;
		bl2 <= bl1;
		wm2 <= wm1;
		s2 <= s1;
		d2 <= d1;
		o2 <= o1;
		m2_reg <= m_n;
		is_lerp2 <= is_lerp_w;
		s_ge_d2 <= s_ge_d_w;
		is_one_one2 <= is_one_one_w;
		fs_one2 <= fs_one_w;
		fd_one2 <= fd_one_w;
		fs_zero2 <= fs_zero_w;
		fd_zero2 <= fd_zero_w;
	end

	/* Stage 3: the operation, the mask, the format. */
	wire [127:0] pix_n;
	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_l3
		wire [31:0] r8;
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_c3
			localparam integer IDX = 4 * gl + gc;
			wire [2:0] op = gc == 3 ? bl2[22:20] : bl2[11:9];
			wire [7:0] sv = s2[32 * gl + 8 * gc +: 8];
			wire [7:0] dv = d2[32 * gl + 8 * gc +: 8];
			wire [15:0] mm = m2_reg[16 * IDX +: 16];

			wire [8:0] dqm;
			atg_rop_div255 u_dqm (.x({2'd0, mm}), .q(dqm));

			wire [8:0] d_add, d_sub, s_add, s_sub, one_one_add, dq_sub_d, dq_sub_s;
			wire d_add_co, d_sub_bo, s_add_co, s_sub_bo, one_one_co, dq_sub_d_bo, dq_sub_s_bo;

			am_add #(.W(9)) u_d_add (.a({1'b0, dv}), .b({1'b0, dqm[7:0]}), .ci(1'b0), .s(d_add), .co(d_add_co));
			am_sub #(.W(9)) u_d_sub (.a({1'b0, dv}), .b({1'b0, dqm[7:0]}), .bi(1'b0), .d(d_sub), .bo(d_sub_bo));
			am_sub #(.W(9)) u_dq_sub_d (.a({1'b0, dqm[7:0]}), .b({1'b0, dv}), .bi(1'b0), .d(dq_sub_d), .bo(dq_sub_d_bo));

			am_add #(.W(9)) u_s_add (.a({1'b0, sv}), .b({1'b0, dqm[7:0]}), .ci(1'b0), .s(s_add), .co(s_add_co));
			am_sub #(.W(9)) u_s_sub (.a({1'b0, sv}), .b({1'b0, dqm[7:0]}), .bi(1'b0), .d(s_sub), .bo(s_sub_bo));
			am_sub #(.W(9)) u_dq_sub_s (.a({1'b0, dqm[7:0]}), .b({1'b0, sv}), .bi(1'b0), .d(dq_sub_s), .bo(dq_sub_s_bo));

			am_add #(.W(9)) u_one_one (.a({1'b0, sv}), .b({1'b0, dv}), .ci(1'b0), .s(one_one_add), .co(one_one_co));

			reg [8:0] v;
			always @(*) begin
				if (op == 3'd3) begin
					v = {1'b0, sv < dv ? sv : dv};
				end else if (op == 3'd4) begin
					v = {1'b0, sv > dv ? sv : dv};
				end else if (is_lerp2[IDX]) begin
					v = s_ge_d2[IDX] ? (d_add[8] ? 9'd255 : d_add) :
					                   (d_sub_bo ? 9'd0 : d_sub);
				end else if (is_one_one2[IDX]) begin
					v = one_one_add[8] ? 9'd255 : one_one_add;
				end else if (fs_one2[IDX] && fd_zero2[IDX]) begin
					v = {1'b0, sv};
				end else if (fs_zero2[IDX] && fd_one2[IDX]) begin
					v = {1'b0, dv};
				end else if (fs_zero2[IDX] && fd_zero2[IDX]) begin
					v = 9'd0;
				end else if (fs_one2[IDX]) begin
					v = (op == 3'd1) ? (s_sub_bo ? 9'd0 : s_sub) :
					    (op == 3'd2) ? (dq_sub_s_bo ? 9'd0 : dq_sub_s) :
					                   (s_add[8] ? 9'd255 : s_add);
				end else if (fd_one2[IDX]) begin
					v = (op == 3'd1) ? (dq_sub_d_bo ? 9'd0 : dq_sub_d) :
					    (op == 3'd2) ? (d_sub_bo ? 9'd0 : d_sub) :
					                   (d_add[8] ? 9'd255 : d_add);
				end else begin
					v = dqm;
				end

				if (!bl2[0])
					v = {1'b0, sv};
				if (v[8])
					v = 9'd255;
			end
			assign r8[8 * gc +: 8] = wm2[gc] ? v[7:0] : dv;

			wire unused_chan = &{1'b0, dqm[8], d_add_co, s_add_co, one_one_co};
		end
		/* 8 bits to 5 and 6: round(v x 31 / 255), round(v x 63 / 255) */
		wire [17:0] x5r, x6g, x5g, x5b;
		wire [8:0] t5r, t6g, t5g, t5b;
		wire [3:0] x_bo_unused;
		am_sub #(.W(18)) u_x5r (.a({5'd0, r8[7:0], 5'd0}), .b({10'd0, r8[7:0]}), .bi(1'b0), .d(x5r),
			.bo(x_bo_unused[0]));
		am_sub #(.W(18)) u_x6g (.a({4'd0, r8[15:8], 6'd0}), .b({10'd0, r8[15:8]}), .bi(1'b0), .d(x6g),
			.bo(x_bo_unused[1]));
		am_sub #(.W(18)) u_x5g (.a({5'd0, r8[15:8], 5'd0}), .b({10'd0, r8[15:8]}), .bi(1'b0), .d(x5g),
			.bo(x_bo_unused[2]));
		am_sub #(.W(18)) u_x5b (.a({5'd0, r8[23:16], 5'd0}), .b({10'd0, r8[23:16]}), .bi(1'b0),
			.d(x5b), .bo(x_bo_unused[3]));
		atg_rop_div255 u_t5r (.x(x5r), .q(t5r));
		atg_rop_div255 u_t6g (.x(x6g), .q(t6g));
		atg_rop_div255 u_t5g (.x(x5g), .q(t5g));
		atg_rop_div255 u_t5b (.x(x5b), .q(t5b));
		wire [15:0] px16 = {t5r[4:0], t6g[5:0], t5b[4:0]};
		wire [15:0] keep = {wm2[0] ? 5'd0 : 5'h1F, wm2[1] ? 6'd0 : 6'h3F, wm2[2] ? 5'd0 : 5'h1F};
		wire [15:0] px15 = {r8[31], t5r[4:0], t5g[4:0], t5b[4:0]};
		wire [15:0] keep15 = {!wm2[3], wm2[0] ? 5'd0 : 5'h1F, wm2[1] ? 5'd0 : 5'h1F,
			wm2[2] ? 5'd0 : 5'h1F};
		reg [31:0] px;
		always @(*)
			case (fmt2)
			F_BGRA8: px = {r8[31:24], r8[7:0], r8[15:8], r8[23:16]};
			F_RGBA8: px = r8;
			F_R8: px = {o2[32 * gl + 8 +: 24], r8[7:0]};
			F_RG8: px = {o2[32 * gl + 16 +: 16], r8[15:0]};
			F_1555: px = {o2[32 * gl + 16 +: 16], (px15 & ~keep15) | (o2[32 * gl +: 16] & keep15)};
			F_565: px = {o2[32 * gl + 16 +: 16], (px16 & ~keep) | (o2[32 * gl +: 16] & keep)};
			default: px = o2[32 * gl +: 32];
			endcase
		assign pix_n[32 * gl +: 32] = m2[gl] ? px : o2[32 * gl +: 32];
		wire unused_t = &{1'b0, t5r[8:5], t6g[8:6], t5g[8:5], t5b[8:5]};
	end
	endgenerate
	always @(posedge clk) begin
		b_rvalid <= rst_n && v2;
		b_pix <= pix_n;
	end

	wire unused_ok = &{LAT != 0, bl2[19:12], bl2[8:1]};
endmodule

`default_nettype wire
