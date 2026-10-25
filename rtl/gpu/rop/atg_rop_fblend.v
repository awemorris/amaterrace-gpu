/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_fblend: the fp32 blend path of the render output: blending, the
 * write mask and the packing of one beat (four pixels of one attachment)
 * for the colour formats that the 8-bit path does not take: the sRGB
 * formats (VkFormat 43, 50, 57), A2B10G10R10_UNORM (64) and R16, R16G16,
 * R16G16B16A16_SFLOAT (76, 83, 97).
 *
 * For each lane of i_lanes: d = the stored pixel unpacked (atg_fmt_comp; sRGB
 * decoded to linear, a missing alpha 1); for the fixed-point targets the
 * source and the constant are clamped to [0, 1] (NaN and negative to +0).
 * With i_blend[0], per channel: the ops 0 ADD s Fs + d Fd, 1 SUBTRACT,
 * 2 REVERSE_SUBTRACT (5-7 as ADD) with the factors of VkBlendFactor 0-14
 * (15 as ZERO; "one minus x" is 1 - x on the fadd; SRC_ALPHA_SATURATE
 * min(A_s, 1 - A_d), 1 for alpha), 3 MIN and 4 MAX (fp32 order, NaN gives
 * 0x7FC00000); without it the source.  The arithmetic is one atg_rx_fmul
 * and one atg_rx_fadd, one operation at a time.  sRGB R, G, B go through
 * one atg_fmt_srgbenc, then atg_fmt_pack (the write mask) gives o_raw and
 * o_keep (all ones for lanes outside i_lanes and for other formats).  See
 * spec/gpu/rop/atg_rop_fblend.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_fblend (
	input wire clk,
	input wire rst_n,
	input wire i_valid,
	output wire i_ready,
	input wire [3:0] i_lanes,
	input wire [511:0] i_src,
	input wire [255:0] i_dst,
	input wire [7:0] i_fmt,
	input wire [22:0] i_blend,
	input wire [127:0] i_const,
	input wire [3:0] i_wm,
	output wire o_valid,
	input wire o_ready,
	output reg [255:0] o_raw,
	output reg [255:0] o_keep
);
	`include "atg_fmt_info.vh"
	localparam [31:0] ONE = 32'h3F800000;

	localparam [3:0] S_IDLE = 4'd0, S_CH = 4'd1, S_FS = 4'd2, S_FD = 4'd3, S_P = 4'd4,
		S_Q = 4'd5, S_R = 4'd6, S_W = 4'd7, S_ENC = 4'd8, S_EW = 4'd9, S_PACK = 4'd10,
		S_OUT = 4'd11;
	reg [3:0] st;

	reg [3:0] lanes, wm;
	reg [511:0] src;
	reg [255:0] dst;
	reg [7:0] fmt;
	reg [22:0] bl;
	reg [127:0] kc;
	reg [1:0] l, c;	/* lane, channel */
	reg [127:0] rr [0:3];	/* the results */
	reg [31:0] fs_v, fd_v, p_v, q_v;
	reg [2:0] dsel;	/* S_W: 0 Fs, 1 Fd, 2 p, 3 q, 4 the result */

	wire is_srgb = fmt == 8'd43 || fmt == 8'd50 || fmt == 8'd57;
	wire fixed = is_srgb || fmt == 8'd64;
	wire known = fixed || fmt == 8'd76 || fmt == 8'd83 || fmt == 8'd97;

	/* clamp to [0, 1]: NaN and negative (-0 included) to +0 */
	function [31:0] c01;
		input [31:0] x;
		c01 = (x[30:23] == 8'hFF && x[22:0] != 23'd0) || x[31] ? 32'd0 :
			x > ONE ? ONE : x;
	endfunction
	function fle;	/* a <= b, -0 = +0; 0 with a NaN */
		input [31:0] a, b;
		reg [32:0] ka, kb;
		begin
			/* the signed keys ka <= kb, from the signs and the magnitudes */
			ka = {2'd0, a[30:0]};
			kb = {2'd0, b[30:0]};
			fle = !(a[30:23] == 8'hFF && a[22:0] != 23'd0) &&
				!(b[30:23] == 8'hFF && b[22:0] != 23'd0) &&
				(a[31] ? (b[31] ? ka >= kb : 1'b1) : (b[31] ? ka == 0 && kb == 0 : ka <= kb));
		end
	endfunction
	function isnan;
		input [30:0] a;
		isnan = a[30:23] == 8'hFF && a[22:0] != 23'd0;
	endfunction
	function [31:0] fmin;
		input [31:0] a, b;
		fmin = isnan(a[30:0]) || isnan(b[30:0]) ? 32'h7FC00000 : fle(a, b) ? a : b;
	endfunction
	function [31:0] fmax;
		input [31:0] a, b;
		fmax = isnan(a[30:0]) || isnan(b[30:0]) ? 32'h7FC00000 : fle(b, a) ? a : b;
	endfunction

	/* The lane's values: source, destination, constant (clamped for fixed). */
	wire [127:0] s_raw = src[128 * l +: 128];
	/* The formats of this path (the destination is unpacked and the result
	 * packed for these only; the value for other formats is not used: their
	 * lanes are skipped and give o_raw 0, o_keep all ones); the format's
	 * info word. */
	localparam [55:0] PFF = {8'd97, 8'd83, 8'd76, 8'd64, 8'd57, 8'd50, 8'd43};
	wire [67:0] pinf = atg_fmt_info(fmt);
	genvar gf;
	/* The places of component k of format i of PFF, at 7 (4 i + k). */
	function [7*28-1:0] ppos;
		input integer unused_n;
		integer pi, pk;
		reg [67:0] fi;
		begin
			ppos = {7*28{1'b0}};
			for (pi = 0; pi < 7; pi = pi + 1) begin
				fi = atg_fmt_info(PFF[8 * pi +: 8]);
				for (pk = 0; pk < 4; pk = pk + 1)
					ppos[7 * (4 * pi + pk) +: 7] = fi[16 + 13 * pk +: 7];
			end
		end
	endfunction
	localparam [7*28-1:0] PPOS = ppos(0);
	/* The destination unpacked: components c and A (the two that a step
	 * reads), each by one atg_fmt_comp from its field moved to bit 0 (a
	 * constant place for each format and component) with the format's info
	 * word, its places 0. */
	wire [127:0] d_raw = {64'd0, dst[64 * l +: 64]};
	wire [67:0] uinf = pinf & ~{6'd0, 7'h7F, 6'd0, 7'h7F, 6'd0, 7'h7F, 6'd0, 7'h7F, 16'd0};
	reg [31:0] craw, araw;
	reg [6:0] up;
	reg d_known;
	integer uf, uk;
	always @(*) begin
		craw = 32'd0;
		araw = 32'd0;
		up = 7'd0;
		d_known = 1'b0;
		for (uf = 0; uf < 7; uf = uf + 1)
			if (fmt == PFF[8 * uf +: 8]) begin
				d_known = 1'b1;
				for (uk = 0; uk < 4; uk = uk + 1) begin
					up = PPOS[7 * (4 * uf + uk) +: 7];
					if (c == uk[1:0])
						craw = d_raw[up +: 32];
					if (uk == 3)
						araw = d_raw[up +: 32];
				end
			end
	end
	wire [31:0] d_cv, d_av;
	atg_fmt_comp u_dc (.raw({96'd0, craw}), .inf(uinf), .k(c), .sten(1'b0), .v(d_cv));
	atg_fmt_comp u_da (.raw({96'd0, araw}), .inf(uinf), .k(2'd3), .sten(1'b0), .v(d_av));
	wire [31:0] s_c = fixed ? c01(s_raw[32 * c +: 32]) : s_raw[32 * c +: 32];
	wire [31:0] s_a = fixed ? c01(s_raw[127:96]) : s_raw[127:96];
	wire [31:0] d_c = d_known ? d_cv : 32'd0;
	wire [31:0] d_a = d_known ? d_av : 32'd0;
	wire [31:0] k_c = fixed ? c01(kc[32 * c +: 32]) : kc[32 * c +: 32];
	wire [31:0] k_a = fixed ? c01(kc[127:96]) : kc[127:96];
	wire [3:0] f_s = c == 2'd3 ? bl[15:12] : bl[4:1];
	wire [3:0] f_d = c == 2'd3 ? bl[19:16] : bl[8:5];
	wire [2:0] op = c == 2'd3 ? bl[22:20] : bl[11:9];

	/* A factor's value x (the "one minus" ones are 1 - x); sat: SATURATE. */
	function [31:0] fval;
		input [3:0] f;
		input alpha;
		input [31:0] sc, dc, sa, da, kcc, ka;
		case (f)
		4'd1: fval = ONE;
		4'd2, 4'd3: fval = sc;
		4'd4, 4'd5: fval = dc;
		4'd6, 4'd7: fval = sa;
		4'd8, 4'd9, 4'd14: fval = alpha && f == 4'd14 ? ONE : da;
		4'd10, 4'd11: fval = kcc;
		4'd12, 4'd13: fval = ka;
		default: fval = 32'd0;
		endcase
	endfunction
	function needs_sub;	/* the factor is 1 - x */
		input [3:0] f;
		input alpha;
		needs_sub = (f[0] && f >= 4'd3 && f <= 4'd13) || (f == 4'd14 && !alpha);
	endfunction
	wire alpha = c == 2'd3;
	wire [31:0] xs = fval(f_s, alpha, s_c, d_c, s_a, d_a, k_c, k_a);
	wire [31:0] xd = fval(f_d, alpha, s_c, d_c, s_a, d_a, k_c, k_a);

	/* The fp units, one operation at a time. */
	reg fa_v, fm_v, fa_sub;
	reg [31:0] opa, opb;
	wire fa_o, fm_o;
	wire [31:0] fa_r, fm_r;
	atg_rx_fadd fadd (.clk(clk), .rst_n(rst_n), .i_valid(fa_v), .i_a(opa), .i_b(opb),
		.i_sub(fa_sub), .o_valid(fa_o), .o_r(fa_r));
	atg_rx_fmul fmul (.clk(clk), .rst_n(rst_n), .i_valid(fm_v), .i_a(opa), .i_b(opb),
		.o_valid(fm_o), .o_r(fm_r));
	wire [31:0] res = fa_o ? fa_r : fm_r;

	/* The sRGB encoder. */
	reg e_v;
	wire e_ready, e_ov;
	wire [7:0] e_code;
	wire [127:0] rr_l = rr[l];
	atg_fmt_srgbenc enc (.clk(clk), .rst_n(rst_n), .i_valid(e_v), .i_ready(e_ready),
		.i_x(rr_l[32 * c +: 32]), .o_valid(e_ov), .o_ready(1'b1), .o_code(e_code));

	/* The pack of lane l. */
	/* one converter a component for the format of the moment: UNORM of the
	 * component's width (8 for an sRGB alpha), fp16 */
	wire [63:0] p_un, p_hf;
	generate
	for (gf = 0; gf < 4; gf = gf + 1) begin : g_cv
		atg_fmt_f2unorm u_un (.f(rr_l[32 * gf +: 32]), .w(pinf[11:9] == ATG_FMT_SRGB ? 6'd8 :
			pinf[23 + 13 * gf +: 6]), .u(p_un[16 * gf +: 16]));
		atg_fmt_f2h u_hf (.f(rr_l[32 * gf +: 32]), .h(p_hf[16 * gf +: 16]));
	end
	endgenerate
	wire [255:0] pk;
	atg_fmt_pack #(.N(7), .FMTS(PFF)) u_pk (.c(rr_l), .un(p_un), .hf(p_hf), .fmt(fmt), .wm(wm), .o(pk));

	assign i_ready = st == S_IDLE;
	assign o_valid = st == S_OUT;
	wire last_ch = c == 2'd3;

	/* the next channel and lane numbers */
	wire [1:0] c1, l1;
	wire c1_co_unused, l1_co_unused;
	am_add #(.W(2)) u_c1 (.a(c), .b(2'd0), .ci(1'b1), .s(c1), .co(c1_co_unused));
	am_add #(.W(2)) u_l1 (.a(l), .b(2'd0), .ci(1'b1), .s(l1), .co(l1_co_unused));

	/* next channel, lane, or the end of the arithmetic */
	task next;
		begin
			c <= c1;
			st <= S_CH;
			if (last_ch) begin
				l <= l1;
				if (l == 2'd3) begin
					l <= 2'd0;
					c <= 2'd0;
					st <= is_srgb ? S_ENC : S_PACK;
				end
			end
		end
	endtask

	always @(posedge clk) begin
		fa_v <= 1'b0;
		fm_v <= 1'b0;
		e_v <= 1'b0;
		if (!rst_n) begin
			st <= S_IDLE;
		end else case (st)
		S_IDLE:
			if (i_valid) begin
				lanes <= i_lanes;
				src <= i_src;
				dst <= i_dst;
				fmt <= i_fmt;
				bl <= i_blend;
				kc <= i_const;
				wm <= i_wm;
				l <= 2'd0;
				c <= 2'd0;
				st <= S_CH;
			end
		S_CH:
			if (!lanes[l] || !known) begin
				/* skip the lane */
				c <= 2'd0;
				l <= l1;
				if (l == 2'd3)
					st <= is_srgb ? S_ENC : S_PACK;
			end else if (!bl[0]) begin
				rr[l][32 * c +: 32] <= s_c;
				next;
			end else if (op == 3'd3) begin
				rr[l][32 * c +: 32] <= fmin(s_c, d_c);
				next;
			end else if (op == 3'd4) begin
				rr[l][32 * c +: 32] <= fmax(s_c, d_c);
				next;
			end else
				st <= S_FS;
		S_FS:
			if (needs_sub(f_s, alpha)) begin
				fa_v <= 1'b1;
				fa_sub <= 1'b1;
				opa <= ONE;
				opb <= xs;
				dsel <= 3'd0;
				st <= S_W;
			end else begin
				fs_v <= xs;
				st <= S_FD;
			end
		S_FD:
			if (needs_sub(f_d, alpha)) begin
				fa_v <= 1'b1;
				fa_sub <= 1'b1;
				opa <= ONE;
				opb <= xd;
				dsel <= 3'd1;
				st <= S_W;
			end else begin
				fd_v <= xd;
				st <= S_P;
			end
		S_P: begin
			fm_v <= 1'b1;
			opa <= s_c;
			opb <= fs_v;
			dsel <= 3'd2;
			st <= S_W;
		end
		S_Q: begin
			fm_v <= 1'b1;
			opa <= d_c;
			opb <= fd_v;
			dsel <= 3'd3;
			st <= S_W;
		end
		S_R: begin
			fa_v <= 1'b1;
			fa_sub <= op == 3'd1 || op == 3'd2;
			opa <= op == 3'd2 ? q_v : p_v;
			opb <= op == 3'd2 ? p_v : q_v;
			dsel <= 3'd4;
			st <= S_W;
		end
		S_W:
			if (fa_o || fm_o)
				case (dsel)
				3'd0: begin
					fs_v <= f_s == 4'd14 ? fmin(s_a, res) : res;
					st <= S_FD;
				end
				3'd1: begin
					fd_v <= f_d == 4'd14 ? fmin(s_a, res) : res;
					st <= S_P;
				end
				3'd2: begin
					p_v <= res;
					st <= S_Q;
				end
				3'd3: begin
					q_v <= res;
					st <= S_R;
				end
				default: begin
					rr[l][32 * c +: 32] <= res;
					next;
				end
				endcase
		S_ENC:
			/* R, G, B of each lane through the encoder */
			if (!lanes[l] || c == 2'd3) begin
				c <= 2'd0;
				l <= l1;
				if (l == 2'd3) begin
					l <= 2'd0;
					st <= S_PACK;
				end
			end else if (e_ready) begin
				e_v <= 1'b1;
				st <= S_EW;
			end
		S_EW:
			if (e_ov) begin
				rr[l][32 * c +: 32] <= {24'd0, e_code};
				c <= c1;
				st <= S_ENC;
			end
		S_PACK: begin
			o_raw[64 * l +: 64] <= known && lanes[l] ? pk[63:0] : 64'd0;
			o_keep[64 * l +: 64] <= known && lanes[l] ? pk[191:128] : {64{1'b1}};
			l <= l1;
			if (l == 2'd3)
				st <= S_OUT;
		end
		default:	/* S_OUT */
			if (o_ready)
				st <= S_IDLE;
		endcase
	end

	wire unused_ok = &{1'b0, pk[127:64], pk[255:192]};
endmodule

`default_nettype wire
