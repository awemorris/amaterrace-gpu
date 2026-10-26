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
 * 5-stage stream pipeline (throughput: 1 beat per cycle, latency: 5 cycles):
 *   Stage 1 (DEC): Unpack destination (atg_fmt_comp) and clamp inputs to [0, 1]
 *   Stage 2 (FAC): Factor generation (fval, 1.0 - x via am_fp_add)
 *   Stage 3A (MUL): Parallel fp32 multiplications P = s * Fs, Q = d * Fd
 *   Stage 3B (ALU): Parallel fp32 combine (P +/- Q, fmin, fmax)
 *   Stage 4 (ENC): sRGB encode (unrolled decision tree) & pack (atg_fmt_pack)
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
	output reg o_valid,
	input wire o_ready,
	output reg [255:0] o_raw,
	output reg [255:0] o_keep
);
	`include "atg_fmt_info.vh"
	`include "atg_srgb.vh"

	localparam [31:0] ONE = 32'h3F800000;
	localparam [55:0] PFF = {8'd97, 8'd83, 8'd76, 8'd64, 8'd57, 8'd50, 8'd43};

	/* Pipeline control: stall when output valid and downstream not ready */
	wire pipe_stall = o_valid && !o_ready;
	wire pipe_en = !pipe_stall;
	assign i_ready = pipe_en;

	/* Functions for fp32 classification and clamping */
	function [31:0] c01;
		input [31:0] x;
		c01 = (x[30:23] == 8'hFF && x[22:0] != 23'd0) || x[31] ? 32'd0 :
			x > ONE ? ONE : x;
	endfunction

	function fle;	/* a <= b, -0 = +0; 0 with a NaN */
		input [31:0] a, b;
		reg [32:0] ka, kb;
		begin
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

	function needs_sub;
		input [3:0] f;
		input alpha;
		needs_sub = (f[0] && f >= 4'd3 && f <= 4'd13) || (f == 4'd14 && !alpha);
	endfunction

	function [7:0] srgb_encode_comb;
		input [31:0] b;
		reg [7:0] lo;
		begin
			if ((b[30:23] == 8'hFF && b[22:0] != 23'd0) || b[31]) begin
				srgb_encode_comb = 8'd0;
			end else begin
				lo = 8'd0;
				if (b >= atg_srgb_thr(8'd127)) lo = lo | 8'd128;
				if (b >= atg_srgb_thr(lo | 8'd63)) lo = lo | 8'd64;
				if (b >= atg_srgb_thr(lo | 8'd31)) lo = lo | 8'd32;
				if (b >= atg_srgb_thr(lo | 8'd15)) lo = lo | 8'd16;
				if (b >= atg_srgb_thr(lo | 8'd7)) lo = lo | 8'd8;
				if (b >= atg_srgb_thr(lo | 8'd3)) lo = lo | 8'd4;
				if (b >= atg_srgb_thr(lo | 8'd1)) lo = lo | 8'd2;
				if (b >= atg_srgb_thr(lo)) lo = lo | 8'd1;
				srgb_encode_comb = lo;
			end
		end
	endfunction

	/* =========================================================================
	 * STAGE 1: Unpack Destination & Clamp Inputs (Latency: 1 cycle)
	 * ========================================================================= */
	wire is_srgb0 = i_fmt == 8'd43 || i_fmt == 8'd50 || i_fmt == 8'd57;
	wire fixed0 = is_srgb0 || i_fmt == 8'd64;
	wire [67:0] pinf0 = atg_fmt_info(i_fmt);
	wire [67:0] uinf0 = pinf0 & ~{6'd0, 7'h7F, 6'd0, 7'h7F, 6'd0, 7'h7F, 6'd0, 7'h7F, 16'd0};

	wire [127:0] d_unpacked0 [0:3];
	reg d_known0;
	genvar gl, gc;

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_dec_l
		wire [127:0] d_raw_l = {64'd0, i_dst[64 * gl +: 64]};
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_dec_c
			reg [31:0] craw_lc;
			reg [6:0] up_lc;
			integer uf_i;
			always @(*) begin
				craw_lc = 32'd0;
				up_lc = 7'd0;
				for (uf_i = 0; uf_i < 7; uf_i = uf_i + 1)
					if (i_fmt == PFF[8 * uf_i +: 8]) begin
						up_lc = PPOS[7 * (4 * uf_i + gc) +: 7];
						craw_lc = d_raw_l[up_lc +: 32];
					end
			end
			wire [31:0] comp_v;
			atg_fmt_comp u_comp (.raw({96'd0, craw_lc}), .inf(uinf0), .k(gc[1:0]), .sten(1'b0), .v(comp_v));
			assign d_unpacked0[gl][32 * gc +: 32] = comp_v;
		end
	end
	endgenerate

	integer uf_k;
	always @(*) begin
		d_known0 = 1'b0;
		for (uf_k = 0; uf_k < 7; uf_k = uf_k + 1)
			if (i_fmt == PFF[8 * uf_k +: 8])
				d_known0 = 1'b1;
	end

	reg [127:0] s1 [0:3];
	reg [127:0] d1 [0:3];
	reg [127:0] kc1;
	reg [22:0] bl1;
	reg [7:0] fmt1;
	reg [3:0] wm1, lanes1;
	reg v1, known1;

	integer i_l, i_c;
	always @(posedge clk) begin
		if (!rst_n) begin
			v1 <= 1'b0;
			known1 <= 1'b0;
			bl1 <= 23'd0;
			fmt1 <= 8'd0;
			wm1 <= 4'd0;
			lanes1 <= 4'd0;
			kc1 <= 128'd0;
			for (i_l = 0; i_l < 4; i_l = i_l + 1) begin
				s1[i_l] <= 128'd0;
				d1[i_l] <= 128'd0;
			end
		end else if (pipe_en) begin
			v1 <= i_valid;
			known1 <= d_known0;
			bl1 <= i_blend;
			fmt1 <= i_fmt;
			wm1 <= i_wm;
			lanes1 <= i_lanes;
			for (i_c = 0; i_c < 4; i_c = i_c + 1)
				kc1[32 * i_c +: 32] <= fixed0 ? c01(i_const[32 * i_c +: 32]) : i_const[32 * i_c +: 32];
			for (i_l = 0; i_l < 4; i_l = i_l + 1) begin
				for (i_c = 0; i_c < 4; i_c = i_c + 1) begin
					s1[i_l][32 * i_c +: 32] <= fixed0 ? c01(i_src[128 * i_l + 32 * i_c +: 32]) :
					                                    i_src[128 * i_l + 32 * i_c +: 32];
					d1[i_l][32 * i_c +: 32] <= d_known0 ? d_unpacked0[i_l][32 * i_c +: 32] : 32'd0;
				end
			end
		end
	end

	/* =========================================================================
	 * STAGE 2: Factor Generation (Latency: 1 cycle)
	 * ========================================================================= */
	wire [127:0] fs_w [0:3];
	wire [127:0] fd_w [0:3];
	wire [11:0] op2_w = {bl1[22:20], bl1[11:9], bl1[11:9], bl1[11:9]};

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_fac_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_fac_c
			wire is_alpha = (gc == 3);
			wire [3:0] f_s = is_alpha ? bl1[15:12] : bl1[4:1];
			wire [3:0] f_d = is_alpha ? bl1[19:16] : bl1[8:5];

			wire [31:0] sc = s1[gl][32 * gc +: 32];
			wire [31:0] dc = d1[gl][32 * gc +: 32];
			wire [31:0] sa = s1[gl][127:96];
			wire [31:0] da = d1[gl][127:96];
			wire [31:0] kcc = kc1[32 * gc +: 32];
			wire [31:0] ka = kc1[127:96];

			wire [31:0] xs = fval(f_s, is_alpha, sc, dc, sa, da, kcc, ka);
			wire [31:0] xd = fval(f_d, is_alpha, sc, dc, sa, da, kcc, ka);

			wire [31:0] sub_s_res, sub_d_res;
			wire sub_s_ov_unused, sub_d_ov_unused;
			am_fp_add #(.LAT(0)) u_sub_s (.clk(clk), .rst_n(rst_n), .i_valid(1'b1), .i_a(ONE), .i_b(xs),
				.i_sub(1'b1), .o_valid(sub_s_ov_unused), .o_r(sub_s_res));
			am_fp_add #(.LAT(0)) u_sub_d (.clk(clk), .rst_n(rst_n), .i_valid(1'b1), .i_a(ONE), .i_b(xd),
				.i_sub(1'b1), .o_valid(sub_d_ov_unused), .o_r(sub_d_res));

			assign fs_w[gl][32 * gc +: 32] = needs_sub(f_s, is_alpha) ?
				(f_s == 4'd14 ? fmin(sa, sub_s_res) : sub_s_res) : xs;
			assign fd_w[gl][32 * gc +: 32] = needs_sub(f_d, is_alpha) ?
				(f_d == 4'd14 ? fmin(sa, sub_d_res) : sub_d_res) : xd;
		end
	end
	endgenerate

	reg [127:0] s2 [0:3];
	reg [127:0] d2 [0:3];
	reg [127:0] fs2 [0:3];
	reg [127:0] fd2 [0:3];
	reg [11:0] op2;
	reg blen2;
	reg [7:0] fmt2;
	reg [3:0] wm2, lanes2;
	reg v2, known2;

	always @(posedge clk) begin
		if (!rst_n) begin
			v2 <= 1'b0;
			known2 <= 1'b0;
			blen2 <= 1'b0;
			fmt2 <= 8'd0;
			wm2 <= 4'd0;
			lanes2 <= 4'd0;
			op2 <= 12'd0;
			for (i_l = 0; i_l < 4; i_l = i_l + 1) begin
				s2[i_l] <= 128'd0;
				d2[i_l] <= 128'd0;
				fs2[i_l] <= 128'd0;
				fd2[i_l] <= 128'd0;
			end
		end else if (pipe_en) begin
			v2 <= v1;
			known2 <= known1;
			blen2 <= bl1[0];
			fmt2 <= fmt1;
			wm2 <= wm1;
			lanes2 <= lanes1;
			op2 <= op2_w;
			for (i_l = 0; i_l < 4; i_l = i_l + 1) begin
				s2[i_l] <= s1[i_l];
				d2[i_l] <= d1[i_l];
				fs2[i_l] <= fs_w[i_l];
				fd2[i_l] <= fd_w[i_l];
			end
		end
	end

	/* =========================================================================
	 * STAGE 3A: fp32 Multiplications P = s * Fs, Q = d * Fd (Latency: 1 cycle)
	 * ========================================================================= */
	wire [127:0] p_w [0:3];
	wire [127:0] q_w [0:3];

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_mul_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_mul_c
			wire [31:0] p_res, q_res;
			wire mul_p_ov_unused, mul_q_ov_unused;
			am_fp_mul #(.LAT(0)) u_mul_p (.clk(clk), .rst_n(rst_n), .i_valid(1'b1),
				.i_a(s2[gl][32 * gc +: 32]), .i_b(fs2[gl][32 * gc +: 32]),
				.o_valid(mul_p_ov_unused), .o_r(p_res));
			am_fp_mul #(.LAT(0)) u_mul_q (.clk(clk), .rst_n(rst_n), .i_valid(1'b1),
				.i_a(d2[gl][32 * gc +: 32]), .i_b(fd2[gl][32 * gc +: 32]),
				.o_valid(mul_q_ov_unused), .o_r(q_res));
			assign p_w[gl][32 * gc +: 32] = p_res;
			assign q_w[gl][32 * gc +: 32] = q_res;
		end
	end
	endgenerate

	reg [127:0] p3 [0:3];
	reg [127:0] q3 [0:3];
	reg [127:0] s3 [0:3];
	reg [127:0] d3 [0:3];
	reg [11:0] op3;
	reg blen3;
	reg [7:0] fmt3;
	reg [3:0] wm3, lanes3;
	reg v3, known3;

	always @(posedge clk) begin
		if (!rst_n) begin
			v3 <= 1'b0;
			known3 <= 1'b0;
			blen3 <= 1'b0;
			fmt3 <= 8'd0;
			wm3 <= 4'd0;
			lanes3 <= 4'd0;
			op3 <= 12'd0;
			for (i_l = 0; i_l < 4; i_l = i_l + 1) begin
				p3[i_l] <= 128'd0;
				q3[i_l] <= 128'd0;
				s3[i_l] <= 128'd0;
				d3[i_l] <= 128'd0;
			end
		end else if (pipe_en) begin
			v3 <= v2;
			known3 <= known2;
			blen3 <= blen2;
			fmt3 <= fmt2;
			wm3 <= wm2;
			lanes3 <= lanes2;
			op3 <= op2;
			for (i_l = 0; i_l < 4; i_l = i_l + 1) begin
				p3[i_l] <= p_w[i_l];
				q3[i_l] <= q_w[i_l];
				s3[i_l] <= s2[i_l];
				d3[i_l] <= d2[i_l];
			end
		end
	end

	/* =========================================================================
	 * STAGE 3B: fp32 Combine P +/- Q, Min/Max (Latency: 1 cycle)
	 * ========================================================================= */
	wire [127:0] res_w [0:3];

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_alu_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_alu_c
			wire [2:0] op = op3[3 * gc +: 3];
			wire [31:0] pv = p3[gl][32 * gc +: 32];
			wire [31:0] qv = q3[gl][32 * gc +: 32];
			wire [31:0] sv = s3[gl][32 * gc +: 32];
			wire [31:0] dv = d3[gl][32 * gc +: 32];

			wire sub_sel = (op == 3'd1 || op == 3'd2);
			wire [31:0] add_a = (op == 3'd2) ? qv : pv;
			wire [31:0] add_b = (op == 3'd2) ? pv : qv;
			wire [31:0] pq_res;
			wire add_ov_unused;
			am_fp_add #(.LAT(0)) u_add_pq (.clk(clk), .rst_n(rst_n), .i_valid(1'b1),
				.i_a(add_a), .i_b(add_b), .i_sub(sub_sel),
				.o_valid(add_ov_unused), .o_r(pq_res));

			assign res_w[gl][32 * gc +: 32] = (!blen3) ? sv :
				(op == 3'd3) ? fmin(sv, dv) :
				(op == 3'd4) ? fmax(sv, dv) : pq_res;
		end
	end
	endgenerate

	reg [127:0] res4 [0:3];
	reg [7:0] fmt4;
	reg [3:0] wm4, lanes4;
	reg v4, known4;

	always @(posedge clk) begin
		if (!rst_n) begin
			v4 <= 1'b0;
			known4 <= 1'b0;
			fmt4 <= 8'd0;
			wm4 <= 4'd0;
			lanes4 <= 4'd0;
			for (i_l = 0; i_l < 4; i_l = i_l + 1)
				res4[i_l] <= 128'd0;
		end else if (pipe_en) begin
			v4 <= v3;
			known4 <= known3;
			fmt4 <= fmt3;
			wm4 <= wm3;
			lanes4 <= lanes3;
			for (i_l = 0; i_l < 4; i_l = i_l + 1)
				res4[i_l] <= res_w[i_l];
		end
	end

	/* =========================================================================
	 * STAGE 4: sRGB Encode & Pack (Latency: 1 cycle)
	 * ========================================================================= */
	wire is_srgb4 = (fmt4 == 8'd43 || fmt4 == 8'd50 || fmt4 == 8'd57);
	wire [67:0] pinf4 = atg_fmt_info(fmt4);
	wire [255:0] raw_out_w, keep_out_w;

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_pack_l
		wire [31:0] cv0 = is_srgb4 ? {24'd0, srgb_encode_comb(res4[gl][31:0])} : res4[gl][31:0];
		wire [31:0] cv1 = is_srgb4 ? {24'd0, srgb_encode_comb(res4[gl][63:32])} : res4[gl][63:32];
		wire [31:0] cv2 = is_srgb4 ? {24'd0, srgb_encode_comb(res4[gl][95:64])} : res4[gl][95:64];
		wire [31:0] cv3 = res4[gl][127:96];
		wire [127:0] comp_vec = {cv3, cv2, cv1, cv0};

		wire [63:0] p_un, p_hf;
		genvar g_c;
		for (g_c = 0; g_c < 4; g_c = g_c + 1) begin : g_pack_c
			wire [31:0] cv_f = comp_vec[32 * g_c +: 32];
			atg_fmt_f2unorm u_un (.f(cv_f), .w(pinf4[11:9] == ATG_FMT_SRGB ? 6'd8 :
				pinf4[23 + 13 * g_c +: 6]), .u(p_un[16 * g_c +: 16]));
			am_fp_f2h #(.LAT(0)) u_hf (.f(cv_f), .h(p_hf[16 * g_c +: 16]));
		end

		wire [255:0] pk;
		atg_fmt_pack #(.N(7), .FMTS(PFF)) u_pk (.c(comp_vec), .un(p_un), .hf(p_hf),
			.fmt(fmt4), .wm(wm4), .o(pk));

		assign raw_out_w[64 * gl +: 64] = (known4 && lanes4[gl]) ? pk[63:0] : 64'd0;
		assign keep_out_w[64 * gl +: 64] = (known4 && lanes4[gl]) ? pk[191:128] : {64{1'b1}};

		wire unused_pk_l = &{1'b0, pk[127:64], pk[255:192], pinf4};
	end
	endgenerate

	always @(posedge clk) begin
		if (!rst_n) begin
			o_valid <= 1'b0;
			o_raw <= 256'd0;
			o_keep <= {256{1'b1}};
		end else if (pipe_en) begin
			o_valid <= v4;
			o_raw <= raw_out_w;
			o_keep <= keep_out_w;
		end
	end

endmodule

`default_nettype wire
