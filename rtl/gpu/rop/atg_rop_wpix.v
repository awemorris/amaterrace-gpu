/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_wpix: the pixels of atg_rop_wb: the attachment's state (CAPS[30]
 * RT_FORMATS, RTk_BASE/STRIDE, WRITE_MASK, BLEND, BLEND1-3, the blend
 * constants), the place of each pixel in the lines, the choice of the
 * blend path and the new pixel bytes.  No state machine; it holds
 * atg_rop_fblend.
 *
 * The beat (i_xy, i_rt, i_smask, i_color) is attachment i_rt of a quad.
 * Its format is RT_FORMATS byte i_rt, or for attachment 0 with that byte 0
 * the earlier RT_FORMAT code (0 B8G8R8A8, 1 R8G8B8A8, 2 and 3 R5G6B5); the
 * pixel is ps = 1, 2, 4, 8 or 16 bytes, sample s of pixel x at (S x + s) ps
 * of the row (S = 4 with MS_CTRL[3:0] = 2, else 1).  A quad's row takes
 * 2 S ps bytes from o_addr (r = 0) on: one line, or (o_multi) o_nl + 1
 * whole lines (only S = 4 with 2 S ps > LINE_BYTES).
 *   One line per row: the quad's 4 lanes of sample g (pass i_g, o_np + 1
 *   passes) are the slots, lane k in entry k >> 1 at byte i_off + (S (k &
 *   1) + g) ps.
 *   Several lines: line i_j of row i_r holds the slots n = E i_j + k, k < E
 *   = LINE_BYTES / ps (lane 2 r + n / 4, sample n mod 4) at byte k ps of
 *   entry r; one pass per line.
 * o_mask: the slots whose sample survived; o_lw: the row (one line) or the
 * line (several) has such a slot.  o_drop: nothing is written (a format
 * without the colour-attachment feature, or no channel of the format in
 * the attachment's write mask).  o_read: the old pixels are needed (blend
 * on, or a write mask without every channel of the format).
 * Paths (o_path): 0 atg_rop_blend (B8G8R8A8, R8G8B8A8, A8B8G8R8, R5G6B5,
 * R8, R8G8, A1R5G5B5 UNORM; 4 slots in 3 cycles, b_pix), 1 atg_rop_fblend
 * (the sRGB formats, A2B10G10R10_UNORM, R16, R16G16, R16G16B16A16_SFLOAT;
 * f_go starts it, f_done the result, f_take takes it), 2 atg_fmt_pack of
 * the source without blending (the integer and 32-bit float formats;
 * Vulkan does not blend them).  o_res: slot k's new pixel at [128 k], ps
 * bytes (the bits the write mask keeps are the old ones).  See
 * spec/gpu/rop/atg_rop_wpix.md.
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

`ifndef CFG_ROP_ENABLE_FBLEND
`define CFG_ROP_ENABLE_FBLEND 1
`endif

`ifndef CFG_ROP_ENABLE_PACK
`define CFG_ROP_ENABLE_PACK 1
`endif

module atg_rop_wpix #(
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* The beat (atg_rop_wb's copy) and the place in it */
	input wire [31:0] i_xy,
	input wire [2:0] i_rt,
	input wire [15:0] i_smask,	/* bit 4 l + s: sample s of lane l */
	input wire [511:0] i_color,
	input wire i_r,	/* row */
	input wire [1:0] i_j,	/* line of the row (several lines) */
	input wire [1:0] i_g,	/* pass: the sample (one line) */
	/* The two line entries and the quad's first byte in each */
	input wire [LINE_BYTES*8-1:0] i_line0,
	input wire [LINE_BYTES*8-1:0] i_line1,
	input wire [LINE_SHIFT-1:0] i_off0,
	input wire [LINE_SHIFT-1:0] i_off1,
	input wire [LINE_SHIFT-1:0] i_off0_p1,
	input wire [LINE_SHIFT-1:0] i_off1_p1,
	input wire [LINE_SHIFT-1:0] i_reg_off0,
	input wire [LINE_SHIFT-1:0] i_reg_off1,
	/* Registered inputs for fblend to eliminate combinational ripple from ds */
	input wire [2:0] i_reg_rt,
	input wire [511:0] i_reg_color,
	input wire [15:0] i_reg_mask,
	/* The paths' results */
	input wire [127:0] b_pix,
	input wire f_go,
	output wire f_done,
	input wire f_take,
	/* To atg_rop_wb */
	output wire [31:0] o_addr,
	output wire [31:0] o_addr1,
	output wire [1:0] o_nl,
	output wire [1:0] o_np,
	output wire o_multi,
	output wire o_drop,
	output wire o_read,
	output wire [1:0] o_path,
	output wire o_lw,
	output wire [3:0] o_mask,
	output wire [511:0] o_bsrc,
	output wire [127:0] o_bdst,
	output wire [511:0] o_res,
	output wire [3:0] o_ent,
	output wire [4*LINE_SHIFT-1:0] o_soff,
	output wire [4:0] o_ps,
	output wire [31:0] o_row_base0,
	output wire [31:0] o_row_base1,
	output wire [31:0] o_xoff,
	output wire [2:0] o_xsh,
	output wire [31:0] o_stride,
	output wire [31:0] o_xoff_j
);
	`include "ghci_regs.vh"
	`include "atg_rop_unorm8.vh"
	`include "atg_fmt_info.vh"

	/* Distributed ROM for unorm8 conversion to avoid BRAM inference */
	(* rom_style = "distributed" *) reg [31:0] rom_unorm8 [0:255];
	integer r_u8_i;
	initial begin
		for (r_u8_i = 0; r_u8_i < 256; r_u8_i = r_u8_i + 1)
			rom_unorm8[r_u8_i] = atg_rop_unorm8(r_u8_i[7:0]);
	end

	/* STATE: RT_BASE 0x070, RT_STRIDE 0x071, RT_FORMAT 0x072, BLEND 0x07A,
	 * BLEND_CONST 0x07B, WRITE_MASK 0x07C, RT_FORMATS 0x07D, RT1-3_BASE and
	 * _STRIDE 0x07E-0x083, BLEND1-3 0x084-0x086, BLEND_CONST_R-A
	 * 0x087-0x08A, ROP_CTRL 0x08D, MS_CTRL 0x05E; RT_EXT 0x1B0-0x1BD (Phase 003: MRT 8). */
	reg [31:0] base [0:7];
	reg [31:0] stride [0:7];
	reg [22:0] bls [0:7];
	reg [31:0] kcf [0:3];
	reg [1:0] fmt0;
	reg [63:0] fmts;
	reg [31:0] kc8;
	reg [31:0] wms;
	reg kc_sel;
	(* max_fanout = 8 *) reg ms4;

`ifdef SYNTH_KINTEX7
	wire st_we_base, st_we_cfg;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_we_b (.I0(st_we), .O(st_we_base));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_we_c (.I0(st_we), .O(st_we_cfg));

	wire [8:0] st_idx_base, st_idx_cfg;
	wire [31:0] st_wdata_base, st_wdata_cfg;
	genvar g_wps;
	generate
	for (g_wps = 0; g_wps < 9; g_wps = g_wps + 1) begin : g_wp_idx
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ib (.I0(st_idx[g_wps]), .O(st_idx_base[g_wps]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ic (.I0(st_idx[g_wps]), .O(st_idx_cfg[g_wps]));
	end
	for (g_wps = 0; g_wps < 32; g_wps = g_wps + 1) begin : g_wp_wdata
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wb (.I0(st_wdata[g_wps]), .O(st_wdata_base[g_wps]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wc (.I0(st_wdata[g_wps]), .O(st_wdata_cfg[g_wps]));
	end
	endgenerate
`else
	wire st_we_base = st_we;
	wire st_we_cfg = st_we;
	wire [8:0] st_idx_base = st_idx;
	wire [8:0] st_idx_cfg = st_idx;
	wire [31:0] st_wdata_base = st_wdata;
	wire [31:0] st_wdata_cfg = st_wdata;
`endif

	/* The index within RT1-3_BASE/_STRIDE (2 (k - 1) + stride), BLEND1-3 or
	 * BLEND_CONST_R-A: the three ranges follow each other, one subtracter. */
	wire [8:0] s_off;
	wire s_off_bo_unused;
	am_sub #(.W(9)) u_s_off (.a(st_idx_base), .b(st_idx_base >= GHCI_S_BLEND_CONST_R ? GHCI_S_BLEND_CONST_R :
		st_idx_base >= GHCI_S_BLEND1 ? GHCI_S_BLEND1 : GHCI_S_RT1_BASE), .bi(1'b0), .d(s_off),
		.bo(s_off_bo_unused));
	wire [8:0] s_rt = s_off;
	wire [8:0] s_bl = s_off;
	wire [8:0] s_kc = s_off;

	/* Extended ROP space for RT4-7 (0x1B0-0x1BF, CAPS[30]) */
	wire [8:0] s_ext;
	wire s_ext_bo_unused;
	am_sub #(.W(9)) u_s_ext (.a(st_idx_base), .b(GHCI_S_RT_EXT), .bi(1'b0), .d(s_ext),
		.bo(s_ext_bo_unused));

	integer i;
	always @(posedge clk)
		if (!rst_n) begin
			for (i = 0; i < 8; i = i + 1) begin
				base[i] <= 32'd0;
				stride[i] <= 32'd0;
				bls[i] <= 23'd0;
			end
			for (i = 0; i < 4; i = i + 1)
				kcf[i] <= 32'd0;
			fmt0 <= 2'd0;
			fmts <= 64'd0;
			kc8 <= 32'd0;
			wms <= 32'd0;
			kc_sel <= 1'b0;
			ms4 <= 1'b0;
		end else begin
			if (st_we_base) begin
				if (st_idx_base == GHCI_S_RT_BASE)
					base[0] <= st_wdata_base;
				if (st_idx_base == GHCI_S_RT_STRIDE)
					stride[0] <= st_wdata_base;
				if (st_idx_base >= GHCI_S_RT1_BASE && st_idx_base < GHCI_S_RT1_BASE + 9'd6)
					for (i = 0; i < 4; i = i + 1)	/* attachment s_rt[2:1] + 1 */
						if (s_rt[2:1] == i[1:0]) begin
							if (s_rt[0])
								stride[(i + 1) % 4] <= st_wdata_base;
							else
								base[(i + 1) % 4] <= st_wdata_base;
						end
				if (st_idx_base >= GHCI_S_RT_EXT && st_idx_base < GHCI_S_RT_EXT + 9'd8)
					for (i = 0; i < 4; i = i + 1)
						if (s_ext[2:1] == i[1:0]) begin
							if (s_ext[0])
								stride[{1'b1, i[1:0]}] <= st_wdata_base;
							else
								base[{1'b1, i[1:0]}] <= st_wdata_base;
						end
			end
			if (st_we_cfg) begin
				if (st_idx_cfg == GHCI_S_RT_FORMAT)
					fmt0 <= st_wdata_cfg[1:0];
				if (st_idx_cfg == GHCI_S_RT_FORMATS)
					fmts[31:0] <= st_wdata_cfg;
				if (st_idx_cfg == GHCI_S_RT_FORMATS1 || st_idx_cfg == 9'h08E)
					fmts[63:32] <= st_wdata_cfg;
				if (st_idx_cfg == GHCI_S_BLEND)
					bls[0] <= st_wdata_cfg[22:0];
				if (st_idx_cfg >= GHCI_S_BLEND1 && st_idx_cfg < GHCI_S_BLEND1 + 9'd3)
					for (i = 0; i < 4; i = i + 1)	/* BLEND s_bl + 1 */
						if (s_bl[1:0] == i[1:0])
							bls[(i + 1) % 4] <= st_wdata_cfg[22:0];
				if (st_idx_cfg >= GHCI_S_BLEND4 && st_idx_cfg < GHCI_S_BLEND4 + 9'd4)
					for (i = 0; i < 4; i = i + 1)
						if (s_ext[1:0] == i[1:0])
							bls[{1'b1, i[1:0]}] <= st_wdata_cfg[22:0];
				if (st_idx_cfg == GHCI_S_BLEND_CONST)
					kc8 <= st_wdata_cfg;
				if (st_idx_cfg >= GHCI_S_BLEND_CONST_R && st_idx_cfg < GHCI_S_BLEND_CONST_R + 9'd4)
					kcf[s_kc[1:0]] <= st_wdata_cfg;
				if (st_idx_cfg == GHCI_S_ROP_CTRL)
					kc_sel <= st_wdata_cfg[1];
				if (st_idx_cfg == GHCI_S_WRITE_MASK) begin
					wms[15:0] <= st_wdata_cfg[15:0];
					if (st_wdata_cfg[31:16] != 16'd0)
						wms[31:16] <= st_wdata_cfg[31:16];
				end
				if (st_idx_cfg == GHCI_S_WRITE_MASK1)
					wms[31:16] <= st_wdata_cfg[15:0];
				if (st_idx_cfg == GHCI_S_MS_CTRL)
					ms4 <= st_wdata_cfg[3:0] == 4'd2;
			end
		end

	/* Registered RT format properties to eliminate combinational format decode in ROP paths */
	genvar grt;
	generate
	for (grt = 0; grt < 8; grt = grt + 1) begin : g_cfg
		wire [7:0] fsel_k = fmts[8 * grt +: 8];
		wire [7:0] vk_k = (grt == 0 && fsel_k == 8'd0) ?
			(fmt0 == 2'd0 ? 8'd44 : fmt0 == 2'd1 ? 8'd37 : 8'd4) : fsel_k;
		wire [67:0] inf_k = atg_fmt_info(vk_k);
		wire [25:0] feat_k = atg_fmt_feat(vk_k, 1'b0);
		wire [4:0] ps_k = inf_k[5:1];
		wire [2:0] psl_k = ps_k[4] ? 3'd4 : ps_k[3] ? 3'd3 : ps_k[2] ? 3'd2 : ps_k[1] ? 3'd1 : 3'd0;
		wire [3:0] cmask_k = inf_k[8:6] >= 3'd4 ? 4'hF : inf_k[8:6] == 3'd3 ? 4'h7 :
			inf_k[8:6] == 3'd2 ? 4'h3 : 4'h1;
		wire [3:0] wm_k = wms[4 * grt +: 4];
		wire [22:0] bl_k = bls[grt];
		wire p_u8_k = vk_k == 8'd44 || vk_k == 8'd37 || vk_k == 8'd51 || vk_k == 8'd4 || vk_k == 8'd9 ||
			vk_k == 8'd16 || vk_k == 8'd8;
		wire p_f32_k = (`CFG_ROP_ENABLE_FBLEND != 0) &&
			(vk_k == 8'd43 || vk_k == 8'd50 || vk_k == 8'd57 || vk_k == 8'd64 || vk_k == 8'd76 ||
			vk_k == 8'd83 || vk_k == 8'd97);
		wire [1:0] path_k = p_u8_k ? 2'd0 : p_f32_k ? 2'd1 : 2'd2;
		wire drop_k = !feat_k[7] || (wm_k & cmask_k) == 4'd0;
		wire read_k = (bl_k[0] && (p_u8_k || p_f32_k)) || (wm_k & cmask_k) != cmask_k;
		wire [3:0] segl_k = ms4 ?
			(psl_k == 3'd4 ? 4'd7 : psl_k == 3'd3 ? 4'd6 : psl_k == 3'd2 ? 4'd5 : psl_k == 3'd1 ? 4'd4 : 4'd3) :
			(psl_k == 3'd4 ? 4'd5 : psl_k == 3'd3 ? 4'd4 : psl_k == 3'd2 ? 4'd3 : psl_k == 3'd1 ? 4'd2 : 4'd1);
		localparam [31:0] LS32 = LINE_SHIFT;
		wire multi_k = segl_k > LS32[3:0];
		wire [3:0] nll_k = (LINE_SHIFT == 5) ?
			(segl_k == 4'd7 ? 4'd2 : segl_k == 4'd6 ? 4'd1 : 4'd0) :
			(segl_k == 4'd7 ? 4'd1 : 4'd0);
		wire [2:0] xsh_k = ms4 ?
			(psl_k == 3'd4 ? 3'd6 : psl_k == 3'd3 ? 3'd5 : psl_k == 3'd2 ? 3'd4 : psl_k == 3'd1 ? 3'd3 : 3'd2) :
			psl_k;
		wire [2:0] el_k = (LINE_SHIFT == 5) ?
			(psl_k == 3'd4 ? 3'd1 : psl_k == 3'd3 ? 3'd2 : psl_k == 3'd2 ? 3'd3 : psl_k == 3'd1 ? 3'd4 : 3'd5) :
			(psl_k == 3'd4 ? 3'd2 : psl_k == 3'd3 ? 3'd3 : psl_k == 3'd2 ? 3'd4 : psl_k == 3'd1 ? 3'd5 : 3'd6);

		reg [7:0] r_vk;
		reg [4:0] r_ps;
		reg [2:0] r_psl;
		reg [1:0] r_path;
		reg r_drop, r_read, r_multi;
		reg [3:0] r_nll;
		reg [2:0] r_xsh, r_el;
		reg [3:0] r_wm;
		reg [22:0] r_bl;

		always @(posedge clk) begin
			if (!rst_n) begin
				r_vk <= 8'd44;
				r_ps <= 5'd4;
				r_psl <= 3'd2;
				r_path <= 2'd0;
				r_drop <= 1'b0;
				r_read <= 1'b0;
				r_multi <= 1'b0;
				r_nll <= 4'd0;
				r_xsh <= 3'd2;
				r_el <= 3'd3;
				r_wm <= 4'hF;
				r_bl <= 23'd0;
			end else begin
				r_vk <= vk_k;
				r_ps <= ps_k;
				r_psl <= psl_k;
				r_path <= path_k;
				r_drop <= drop_k;
				r_read <= read_k;
				r_multi <= multi_k;
				r_nll <= nll_k;
				r_xsh <= xsh_k;
				r_el <= el_k;
				r_wm <= wm_k;
				r_bl <= bl_k;
			end
		end
	end
	endgenerate

	reg [7:0] vk;
	reg [4:0] ps;
	(* max_fanout = 8 *) reg [2:0] psl;
	reg [1:0] path;
	reg drop, read, multi;
	reg [3:0] nll;
	(* max_fanout = 8 *) reg [2:0] xsh, el;
	reg [3:0] wm;
	reg [22:0] bl;

`ifdef SYNTH_KINTEX7
	wire [2:0] i_rt_cfg0, i_rt_cfg1, i_rt_cfg2, i_rt_addr;
	genvar g_rtb;
	generate
	for (g_rtb = 0; g_rtb < 3; g_rtb = g_rtb + 1) begin : g_rt_buf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rt0 (.I0(i_rt[g_rtb]), .O(i_rt_cfg0[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rt1 (.I0(i_rt[g_rtb]), .O(i_rt_cfg1[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rt2 (.I0(i_rt[g_rtb]), .O(i_rt_cfg2[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rta (.I0(i_rt[g_rtb]), .O(i_rt_addr[g_rtb]));
	end
	endgenerate
`else
	wire [2:0] i_rt_cfg0 = i_rt;
	wire [2:0] i_rt_cfg1 = i_rt;
	wire [2:0] i_rt_cfg2 = i_rt;
	wire [2:0] i_rt_addr = i_rt;
`endif

	always @(*) begin
		case (i_rt_cfg0)
		3'd0: begin vk = g_cfg[0].r_vk; ps = g_cfg[0].r_ps; psl = g_cfg[0].r_psl; path = g_cfg[0].r_path; end
		3'd1: begin vk = g_cfg[1].r_vk; ps = g_cfg[1].r_ps; psl = g_cfg[1].r_psl; path = g_cfg[1].r_path; end
		3'd2: begin vk = g_cfg[2].r_vk; ps = g_cfg[2].r_ps; psl = g_cfg[2].r_psl; path = g_cfg[2].r_path; end
		3'd3: begin vk = g_cfg[3].r_vk; ps = g_cfg[3].r_ps; psl = g_cfg[3].r_psl; path = g_cfg[3].r_path; end
		3'd4: begin vk = g_cfg[4].r_vk; ps = g_cfg[4].r_ps; psl = g_cfg[4].r_psl; path = g_cfg[4].r_path; end
		3'd5: begin vk = g_cfg[5].r_vk; ps = g_cfg[5].r_ps; psl = g_cfg[5].r_psl; path = g_cfg[5].r_path; end
		3'd6: begin vk = g_cfg[6].r_vk; ps = g_cfg[6].r_ps; psl = g_cfg[6].r_psl; path = g_cfg[6].r_path; end
		default: begin vk = g_cfg[7].r_vk; ps = g_cfg[7].r_ps; psl = g_cfg[7].r_psl; path = g_cfg[7].r_path; end
		endcase
	end

	always @(*) begin
		case (i_rt_cfg1)
		3'd0: begin drop = g_cfg[0].r_drop; read = g_cfg[0].r_read; multi = g_cfg[0].r_multi; nll = g_cfg[0].r_nll; end
		3'd1: begin drop = g_cfg[1].r_drop; read = g_cfg[1].r_read; multi = g_cfg[1].r_multi; nll = g_cfg[1].r_nll; end
		3'd2: begin drop = g_cfg[2].r_drop; read = g_cfg[2].r_read; multi = g_cfg[2].r_multi; nll = g_cfg[2].r_nll; end
		3'd3: begin drop = g_cfg[3].r_drop; read = g_cfg[3].r_read; multi = g_cfg[3].r_multi; nll = g_cfg[3].r_nll; end
		3'd4: begin drop = g_cfg[4].r_drop; read = g_cfg[4].r_read; multi = g_cfg[4].r_multi; nll = g_cfg[4].r_nll; end
		3'd5: begin drop = g_cfg[5].r_drop; read = g_cfg[5].r_read; multi = g_cfg[5].r_multi; nll = g_cfg[5].r_nll; end
		3'd6: begin drop = g_cfg[6].r_drop; read = g_cfg[6].r_read; multi = g_cfg[6].r_multi; nll = g_cfg[6].r_nll; end
		default: begin drop = g_cfg[7].r_drop; read = g_cfg[7].r_read; multi = g_cfg[7].r_multi; nll = g_cfg[7].r_nll; end
		endcase
	end

	always @(*) begin
		case (i_rt_cfg2)
		3'd0: begin xsh = g_cfg[0].r_xsh; el = g_cfg[0].r_el; wm = g_cfg[0].r_wm; bl = g_cfg[0].r_bl; end
		3'd1: begin xsh = g_cfg[1].r_xsh; el = g_cfg[1].r_el; wm = g_cfg[1].r_wm; bl = g_cfg[1].r_bl; end
		3'd2: begin xsh = g_cfg[2].r_xsh; el = g_cfg[2].r_el; wm = g_cfg[2].r_wm; bl = g_cfg[2].r_bl; end
		3'd3: begin xsh = g_cfg[3].r_xsh; el = g_cfg[3].r_el; wm = g_cfg[3].r_wm; bl = g_cfg[3].r_bl; end
		3'd4: begin xsh = g_cfg[4].r_xsh; el = g_cfg[4].r_el; wm = g_cfg[4].r_wm; bl = g_cfg[4].r_bl; end
		3'd5: begin xsh = g_cfg[5].r_xsh; el = g_cfg[5].r_el; wm = g_cfg[5].r_wm; bl = g_cfg[5].r_bl; end
		3'd6: begin xsh = g_cfg[6].r_xsh; el = g_cfg[6].r_el; wm = g_cfg[6].r_wm; bl = g_cfg[6].r_bl; end
		default: begin xsh = g_cfg[7].r_xsh; el = g_cfg[7].r_el; wm = g_cfg[7].r_wm; bl = g_cfg[7].r_bl; end
		endcase
	end

	assign o_path = path;
	assign o_drop = drop;
	assign o_read = read;
	assign o_ps = ps;
	wire p_u8 = path == 2'd0;
	wire p_f32 = path == 2'd1;
	wire [16:0] yr;
	wire [48:0] yrs;
	wire [31:0] xoff, a1;
	wire yr_co_unused, a1_co_unused, a3_co_unused;
	/* base + (y + r) stride + x S ps + (several lines) the line j */
	am_shift #(.W(32), .SW(3)) u_xoff (.a({16'd0, i_xy[15:0]}), .amt(xsh), .left(1'b1), .arith(1'b0),
		.y(xoff));
	assign o_xoff = xoff;
	assign o_xsh = xsh;
	am_add #(.W(17)) u_yr (.a({1'b0, i_xy[31:16]}), .b(17'd0), .ci(1'b0), .s(yr), .co(yr_co_unused));
	am_mul #(.AW(17), .BW(32), .LAT(2)) u_yrs (.clk(clk), .en(1'b1), .a(yr), .b(stride[i_rt_addr]), .p(yrs));
	am_add #(.W(32)) u_a1 (.a(base[i_rt_addr]), .b(yrs[31:0]), .ci(1'b0), .s(a1), .co(a1_co_unused));
	assign o_row_base0 = a1;
	assign o_stride = stride[i_rt_addr];

	wire rb1_co_unused;
	am_add #(.W(32)) u_rb1 (.a(a1), .b(stride[i_rt_addr]), .ci(1'b0), .s(o_row_base1), .co(rb1_co_unused));

	assign o_multi = multi;
	assign o_nl = multi ? (nll == 4'd1 ? 2'd1 : 2'd3) : 2'd0;
	assign o_np = !multi && ms4 ? 2'd3 : 2'd0;

	wire [31:0] xoff_j;
	wire xj_co_unused;
	am_add #(.W(32)) u_xj (.a(xoff),
`ifdef MUT_WPIX_LINE
		.b(32'd0),
`else
		.b(multi ? {{(30-LINE_SHIFT){1'b0}}, i_j, {LINE_SHIFT{1'b0}}} : 32'd0),
`endif
		.ci(1'b0), .s(xoff_j), .co(xj_co_unused));
	assign o_xoff_j = xoff_j;

	am_add #(.W(32)) u_a3 (.a(a1), .b(xoff_j), .ci(1'b0), .s(o_addr), .co(a3_co_unused));
	wire a3_1_co_unused;
	am_add #(.W(32)) u_a3_1 (.a(o_row_base1), .b(xoff_j), .ci(1'b0), .s(o_addr1), .co(a3_1_co_unused));

	/* The slots. */
	wire [127:0] kcv = kc_sel ? {kcf[3], kcf[2], kcf[1], kcf[0]} :
		{rom_unorm8[kc8[31:24]], rom_unorm8[kc8[23:16]], rom_unorm8[kc8[15:8]],
		rom_unorm8[kc8[7:0]]};
	wire [255:0] f_dst, f_raw, f_keep;
	wire f_idle;	/* the wb starts it only after taking its result */
	wire [3:0] mk, en;
	wire [4*LINE_SHIFT-1:0] so;
	wire [511:0] src, dst;
	genvar k;
	function [LINE_SHIFT-1:0] shift_left_psl;
		input [2:0] val;
		input [2:0] sh;
		case (sh)
		3'd0: shift_left_psl = {{(LINE_SHIFT-3){1'b0}}, val};
		3'd1: shift_left_psl = {{(LINE_SHIFT-4){1'b0}}, val, 1'b0};
		3'd2: shift_left_psl = {{(LINE_SHIFT-5){1'b0}}, val, 2'b00};
		3'd3: shift_left_psl = {val[LINE_SHIFT-4:0], 3'b000};
		default: shift_left_psl = {val[LINE_SHIFT-5:0], 4'b0000};
		endcase
	endfunction

	function [3:0] shift_left_el;
		input [1:0] val;
		input [2:0] sh;
		case (sh)
		3'd0: shift_left_el = {2'b00, val};
		3'd1: shift_left_el = {1'b0, val, 1'b0};
		default: shift_left_el = {val, 2'b00};
		endcase
	endfunction

	/* Slot configuration: derived from selected RT (i_rt) */
`ifdef SYNTH_KINTEX7
	wire [2:0] psl_k [0:3];
	genvar g_pk, g_bit;
	generate
	for (g_pk = 0; g_pk < 4; g_pk = g_pk + 1) begin : g_psl_k
		for (g_bit = 0; g_bit < 3; g_bit = g_bit + 1) begin : g_pb
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pk (.I0(psl[g_bit]), .O(psl_k[g_pk][g_bit]));
		end
	end
	endgenerate
`else
	wire [2:0] psl_k [0:3];
	genvar g_pk;
	generate
	for (g_pk = 0; g_pk < 4; g_pk = g_pk + 1) begin : g_psl_k
		assign psl_k[g_pk] = psl;
	end
	endgenerate
`endif

	wire [2:0] el_slot = el;
	wire multi_slot = multi;
	wire ms4_slot = ms4;

	generate
	for (k = 0; k < 4; k = k + 1) begin : g_slot
		/* one line: lane k, sample i_g; several: n = E i_j + k */
		wire [3:0] nj = shift_left_el(i_j, el_slot);
		wire [3:0] n;
		wire [LINE_SHIFT-1:0] om;
		wire n_co_unused;
		localparam [3:0] K4 = k;
		am_add #(.W(4)) u_n (.a(nj), .b(K4), .ci(1'b0), .s(n), .co(n_co_unused));
		wire [1:0] ln = multi_slot ? {i_r, n[2]} : k;
		wire [LINE_SHIFT-1:0] o1s = shift_left_psl(ms4_slot ? {k[0], i_g} : {2'b00, k[0]}, psl_k[k]);
		wire [LINE_SHIFT-1:0] o1;
		if (k == 0 || k == 2) begin : g_k02
			wire has_o1s = ms4_slot && (i_g != 2'd0);
			wire [LINE_SHIFT-1:0] off_base = (k >= 2) ? i_off1 : i_off0;
			wire [LINE_SHIFT-1:0] o1_add;
			wire o1_co_unused;
			am_add #(.W(LINE_SHIFT)) u_o1 (.a(off_base), .b(o1s), .ci(1'b0), .s(o1_add),
				.co(o1_co_unused));
			assign o1 = has_o1s ? o1_add : off_base;
		end else begin : g_k13
			wire [LINE_SHIFT-1:0] off_base = (k >= 2) ? i_off1 : i_off0;
			wire o1_co_unused;
			am_add #(.W(LINE_SHIFT)) u_o1 (.a(off_base), .b(o1s), .ci(1'b0), .s(o1),
				.co(o1_co_unused));
		end
		assign om = shift_left_psl({1'b0, k[1:0]}, psl_k[k]);
		(* max_fanout = 16 *) wire [LINE_SHIFT-1:0] o = multi_slot ? om : o1;
		assign so[LINE_SHIFT * k +: LINE_SHIFT] = o;
		assign en[k] = multi_slot ? i_r : k >= 2;
		assign mk[k] = multi_slot ? (el_slot == 3'd2 || k < 2) && i_smask[{ln, n[1:0]}] : i_smask[{ln, i_g}];
		/* the old pixel: its 16-byte block, then its ps bytes there (the
		 * offset is a multiple of ps, as in atg_rop_wb; the bytes above ps
		 * are 0) */
		wire [127:0] blk = en[k] ? i_line1[128 * o[LINE_SHIFT-1:4] +: 128] :
			i_line0[128 * o[LINE_SHIFT-1:4] +: 128];
`ifdef SYNTH_KINTEX7
		wire [2:0] psl_s [0:7];
		genvar g_ps, g_sb;
		for (g_ps = 0; g_ps < 8; g_ps = g_ps + 1) begin : g_ps_buf
			for (g_sb = 0; g_sb < 3; g_sb = g_sb + 1) begin : g_psb
				(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ps (.I0(psl_k[k][g_sb]), .O(psl_s[g_ps][g_sb]));
			end
		end
		wire [127:0] dst_k;
		assign dst_k[15:0] = psl_s[0][2] ? blk[15:0] : psl_s[0] == 3'd3 ? blk[64 * o[3] +: 16] :
			psl_s[0] == 3'd2 ? blk[32 * o[3:2] +: 16] :
			psl_s[0] == 3'd1 ? blk[16 * o[3:1] +: 16] : {8'd0, blk[8 * o[3:0] +: 8]};
		assign dst_k[31:16] = psl_s[1][2] ? blk[31:16] : psl_s[1] == 3'd3 ? blk[64 * o[3] + 16 +: 16] :
			psl_s[1] == 3'd2 ? blk[32 * o[3:2] + 16 +: 16] : 16'd0;
		assign dst_k[47:32] = psl_s[2][2] ? blk[47:32] : psl_s[2] == 3'd3 ? blk[64 * o[3] + 32 +: 16] : 16'd0;
		assign dst_k[63:48] = psl_s[3][2] ? blk[63:48] : psl_s[3] == 3'd3 ? blk[64 * o[3] + 48 +: 16] : 16'd0;
		assign dst_k[79:64] = psl_s[4][2] ? blk[79:64] : 16'd0;
		assign dst_k[95:80] = psl_s[5][2] ? blk[95:80] : 16'd0;
		assign dst_k[111:96] = psl_s[6][2] ? blk[111:96] : 16'd0;
		assign dst_k[127:112] = psl_s[7][2] ? blk[127:112] : 16'd0;
		assign dst[128 * k +: 128] = dst_k;
`else
		assign dst[128 * k +: 128] = psl_k[k][2] ? blk : psl_k[k] == 3'd3 ? {64'd0, blk[64 * o[3] +: 64]} :
			psl_k[k] == 3'd2 ? {96'd0, blk[32 * o[3:2] +: 32]} :
			psl_k[k] == 3'd1 ? {112'd0, blk[16 * o[3:1] +: 16]} : {120'd0, blk[8 * o[3:0] +: 8]};
`endif
		wire [31:0] bdst_k = (psl_k[k] == 3'd0) ? {24'd0, blk[8 * o[3:0] +: 8]} :
		                     (psl_k[k] == 3'd1) ? {16'd0, blk[16 * o[3:1] +: 16]} :
		                     blk[32 * o[3:2] +: 32];
		assign src[128 * k +: 128] = i_color[128 * ln +: 128];
		wire unused_n = &{1'b0, n[3]};
	end
	endgenerate
	assign o_mask = mk;
	assign o_lw = multi ? mk != 4'd0 : i_smask[8 * i_r +: 8] != 8'd0;
	assign o_ent = en;
	assign o_soff = so;
	assign o_bsrc = src;
	assign o_bdst = {g_slot[3].bdst_k, g_slot[2].bdst_k, g_slot[1].bdst_k, g_slot[0].bdst_k};

	/* Registered RT configuration for fblend and o_res to eliminate cross-module combinational path from ds/FSM */
	reg [7:0] f_vk;
	reg [22:0] f_bl;
	reg [3:0] f_wm;
	reg [2:0] f_psl, f_el;
	reg [1:0] f_path;
	reg f_multi;
	always @(*) begin
		case (i_reg_rt)
		3'd0: begin f_vk = g_cfg[0].r_vk; f_bl = g_cfg[0].r_bl; f_wm = g_cfg[0].r_wm; f_psl = g_cfg[0].r_psl; f_el = g_cfg[0].r_el; f_multi = g_cfg[0].r_multi; f_path = g_cfg[0].r_path; end
		3'd1: begin f_vk = g_cfg[1].r_vk; f_bl = g_cfg[1].r_bl; f_wm = g_cfg[1].r_wm; f_psl = g_cfg[1].r_psl; f_el = g_cfg[1].r_el; f_multi = g_cfg[1].r_multi; f_path = g_cfg[1].r_path; end
		3'd2: begin f_vk = g_cfg[2].r_vk; f_bl = g_cfg[2].r_bl; f_wm = g_cfg[2].r_wm; f_psl = g_cfg[2].r_psl; f_el = g_cfg[2].r_el; f_multi = g_cfg[2].r_multi; f_path = g_cfg[2].r_path; end
		3'd3: begin f_vk = g_cfg[3].r_vk; f_bl = g_cfg[3].r_bl; f_wm = g_cfg[3].r_wm; f_psl = g_cfg[3].r_psl; f_el = g_cfg[3].r_el; f_multi = g_cfg[3].r_multi; f_path = g_cfg[3].r_path; end
		3'd4: begin f_vk = g_cfg[4].r_vk; f_bl = g_cfg[4].r_bl; f_wm = g_cfg[4].r_wm; f_psl = g_cfg[4].r_psl; f_el = g_cfg[4].r_el; f_multi = g_cfg[4].r_multi; f_path = g_cfg[4].r_path; end
		3'd5: begin f_vk = g_cfg[5].r_vk; f_bl = g_cfg[5].r_bl; f_wm = g_cfg[5].r_wm; f_psl = g_cfg[5].r_psl; f_el = g_cfg[5].r_el; f_multi = g_cfg[5].r_multi; f_path = g_cfg[5].r_path; end
		3'd6: begin f_vk = g_cfg[6].r_vk; f_bl = g_cfg[6].r_bl; f_wm = g_cfg[6].r_wm; f_psl = g_cfg[6].r_psl; f_el = g_cfg[6].r_el; f_multi = g_cfg[6].r_multi; f_path = g_cfg[6].r_path; end
		default: begin f_vk = g_cfg[7].r_vk; f_bl = g_cfg[7].r_bl; f_wm = g_cfg[7].r_wm; f_psl = g_cfg[7].r_psl; f_el = g_cfg[7].r_el; f_multi = g_cfg[7].r_multi; f_path = g_cfg[7].r_path; end
		endcase
	end
	wire f_p_u8 = (f_path == 2'd0);
	wire f_p_f32 = (f_path == 2'd1);
	wire [127:0] f_kcv = kcv;

	wire [511:0] f_src;
	wire [3:0] f_mk;
	genvar g_fk;
	generate
	for (g_fk = 0; g_fk < 4; g_fk = g_fk + 1) begin : g_f_slot
		wire [3:0] f_nj = shift_left_el(i_j, f_el);
		wire [3:0] f_n;
		wire f_n_co_unused;
		localparam [3:0] FK4 = g_fk;
		am_add #(.W(4)) u_fn (.a(f_nj), .b(FK4), .ci(1'b0), .s(f_n), .co(f_n_co_unused));
		wire [1:0] f_ln = f_multi ? {i_r, f_n[2]} : g_fk[1:0];
		wire [LINE_SHIFT-1:0] f_o1s = shift_left_psl(ms4 ? {g_fk[0], i_g} : {2'b00, g_fk[0]}, f_psl);
		wire [LINE_SHIFT-1:0] f_off_base = (g_fk >= 2) ? i_reg_off1 : i_reg_off0;
		wire [LINE_SHIFT-1:0] f_o1;
		wire f_o1_co_unused;
		am_add #(.W(LINE_SHIFT)) u_fo1 (.a(f_off_base), .b(f_o1s), .ci(1'b0), .s(f_o1), .co(f_o1_co_unused));
		wire [LINE_SHIFT-1:0] f_om = shift_left_psl({1'b0, g_fk[1:0]}, f_psl);
		wire [LINE_SHIFT-1:0] f_o = f_multi ? f_om : f_o1;
		wire f_en = f_multi ? i_r : (g_fk >= 2);
		wire [127:0] f_blk = f_en ? i_line1[128 * f_o[LINE_SHIFT-1:4] +: 128] :
			i_line0[128 * f_o[LINE_SHIFT-1:4] +: 128];
		wire [63:0] f_dst_k = f_psl[2] ? f_blk[63:0] :
			f_psl == 3'd3 ? f_blk[64 * f_o[3] +: 64] :
			f_psl == 3'd2 ? {32'd0, f_blk[32 * f_o[3:2] +: 32]} :
			f_psl == 3'd1 ? {48'd0, f_blk[16 * f_o[3:1] +: 16]} :
			{56'd0, f_blk[8 * f_o[3:0] +: 8]};
		wire [127:0] f_dst128_k = f_psl[2] ? f_blk :
			f_psl == 3'd3 ? {64'd0, f_blk[64 * f_o[3] +: 64]} :
			f_psl == 3'd2 ? {96'd0, f_blk[32 * f_o[3:2] +: 32]} :
			f_psl == 3'd1 ? {112'd0, f_blk[16 * f_o[3:1] +: 16]} :
			{120'd0, f_blk[8 * f_o[3:0] +: 8]};
		assign f_dst[64 * g_fk +: 64] = f_dst_k;
		assign f_src[128 * g_fk +: 128] = i_reg_color[128 * f_ln +: 128];
		assign f_mk[g_fk] = f_multi ? (f_el == 3'd2 || g_fk < 2) && i_reg_mask[{f_ln, f_n[1:0]}] :
			i_reg_mask[{f_ln, i_g}];
		wire unused_fn = &{1'b0, f_n[3], f_n_co_unused, f_o1_co_unused};
	end
	endgenerate

	generate
	if (`CFG_ROP_ENABLE_FBLEND != 0) begin : g_fblend
		atg_rop_fblend fblend (.clk(clk), .rst_n(rst_n), .i_valid(f_go), .i_ready(f_idle),
			.i_lanes(f_mk), .i_src(f_src), .i_dst(f_dst), .i_fmt(f_vk), .i_blend(f_bl), .i_const(f_kcv),
			.i_wm(f_wm), .o_valid(f_done), .o_ready(f_take), .o_raw(f_raw), .o_keep(f_keep));
	end else begin : g_no_fblend
		assign f_idle = 1'b1;
		assign f_done = f_go;
		assign f_raw = 256'd0;
		assign f_keep = 256'd0;
	end
	endgenerate

	/* atg_fmt_pack for the formats of path 2 (the colour-attachment formats
	 * that are neither path 0 nor 1: integer and 32-bit float formats, no
	 * conversion), one a lane, each format its own bit placement; a format
	 * without the colour-attachment feature writes nothing, as in
	 * atg_fmt_pack.  For the formats of paths 0 and 1 the value is not used. */
	localparam [191:0] P2F = {8'd109, 8'd108, 8'd107, 8'd103, 8'd102, 8'd101, 8'd100, 8'd99, 8'd98,
		8'd96, 8'd95, 8'd82, 8'd81, 8'd75, 8'd74, 8'd68, 8'd56, 8'd55, 8'd42, 8'd41, 8'd21, 8'd20,
		8'd14, 8'd13};

	/* The new pixels. */
	generate
	for (k = 0; k < 4; k = k + 1) begin : g_res
		wire [255:0] pk;
		if (`CFG_ROP_ENABLE_PACK != 0) begin : g_pk
			atg_fmt_pack #(.N(24), .FMTS(P2F), .LAT(0)) u_pk (
				.clk(clk), .rst_n(rst_n), .en(1'b1),
				.c(f_src[128 * k +: 128]), .un(64'd0), .hf(64'd0),
				.fmt(f_vk), .wm(f_wm), .o(pk)
			);
		end else begin : g_no_pk
			assign pk = 256'd0;
		end
		wire [63:0] fr = (f_raw[64 * k +: 64] & ~f_keep[64 * k +: 64]) |
			(f_dst[64 * k +: 64] & f_keep[64 * k +: 64]);
		wire [127:0] reg_dst_k = g_f_slot[k].f_dst128_k;
		assign o_res[128 * k +: 128] = f_p_u8 ? {96'd0, b_pix[32 * k +: 32]} :
`ifdef MUT_WPIX_KEEP
			f_p_f32 ? {64'd0, fr} : pk[127:0];
`else
			f_p_f32 ? {64'd0, fr} : (`CFG_ROP_ENABLE_PACK != 0 ?
				((pk[127:0] & ~pk[255:128]) | (reg_dst_k & pk[255:128])) :
				{96'd0, b_pix[32 * k +: 32]});
`endif
	end
	endgenerate

	localparam [31:0] LS32 = LINE_SHIFT;
	wire unused_ok = &{1'b0, f_idle, yrs[48:32], LS32[31:4], s_rt[8:3], s_bl[8:2],
		s_kc[8:2], nll[3:2], s_ext[8:3], s_ext_bo_unused, kcv, f_dst, bl[22:1], f_take,
		xj_co_unused, a3_1_co_unused};
endmodule

`default_nettype wire
