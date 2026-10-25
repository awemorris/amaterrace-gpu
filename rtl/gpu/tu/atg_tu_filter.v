/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_filter: TU filtering: converts texels (RGBA8/BGRA8 UNORM, D24,
 * D32F) to fp32 RGBA, compares depth texels with the reference of a
 * compare sampler, and blends nearest, bilinear, and over the passes of
 * 3D linear and mip linear filtering, per lane.
 *
 * tools/tumodel.py is the reference; the rules (the bytes and compares,
 * bilinear R, the passes' sums A and A / (255 × 2^32) as fp32, depth
 * without compare, gather, texsz and texqlod, RGB565, R8 and R8G8, D16
 * compare, the swizzle) are in spec/gpu/tu/atg_tu_filter.md section 4.
 *
 * Pipeline (spec section 6): a pass is taken in IDLE or with its
 * predecessor's lane 3 and issues its lanes 0-3 one a cycle into 18
 * stages without stalls: P1 the lane (here), P1-P5 Dref, the compares and
 * the weights (atg_tu_fpre), P5 the channels' bytes, P5-P11 the sums
 * (atg_tu_fsum, the sums A read in P10 and written in P11), P12-P18 the
 * conversion to fp32 (atg_tu_frnd), P18 the lane's words (atg_tu_fword).
 * The quads go out through a FIFO of 4; a pass is taken only while the
 * last passes taken whose quads are not yet returned are fewer than 4.
 * idle: no quad taken and not returned and no pass with more to follow
 * pending (atg_tu hands a pass of the other path only then).
 * See spec/gpu/tu/atg_tu_filter.md.
 *
 * States: IDLE →(tc)→ RUN (lanes 0-3; the next pass is taken with lane 3)
 * → IDLE. */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_filter (
	input wire clk,
	input wire rst_n,
	/* From atg_tu_cache */
	input wire tc_valid,
	output wire tc_ready,
	input wire [511:0] tc_texels,
	input wire [127:0] tc_wts,
	input wire [15:0] tc_tag,
	input wire [3:0] tc_mask,
	input wire [49:0] tc_ctl,
	input wire [127:0] tc_value,
	input wire tc_last,
	output wire idle,
	/* Return to the SU */
	output wire tr_valid,
	input wire tr_ready,
	output wire [15:0] tr_tag,
	output wire [511:0] tr_data,
	output wire tr_last
);
	localparam IDLE = 1'b0, RUN = 1'b1;
	integer i, c, t;

	/* RGB565 as RGBA8 (for the filtered operations). */
	function [31:0] x565;
		input [15:0] w;
		x565 = {8'hFF, w[4:0], w[4:2], w[10:5], w[10:9], w[15:11], w[15:13]};
	endfunction

	/* R8 and R8G8 as RGBA8 (the missing bytes 0, alpha 255). */
	function [31:0] xrg;
		input [31:0] w;
		input [7:0] f;
		xrg = f == 8'd9 ? {8'hFF, 16'd0, w[7:0]} : f == 8'd16 ? {8'hFF, 8'd0, w[15:0]} : w;
	endfunction

	/* The component that swizzle code 3-6 (R, G, B, A) takes, by its bits
	 * 1:0. */
	function [1:0] zsrc;
		input [1:0] s;
		case (s)
		2'd3: zsrc = 2'd0;
		2'd0: zsrc = 2'd1;
		2'd1: zsrc = 2'd2;
		default: zsrc = 2'd3;
		endcase
	endfunction

	/* The texel of word g of a gather: 2, 3, 1, 0. */
	function [1:0] gtx;
		input [1:0] g;
		gtx = g == 2'd0 ? 2'd2 : g == 2'd1 ? 2'd3 : g == 2'd2 ? 2'd1 : 2'd0;
	endfunction

	reg st;
	reg [1:0] k;
	reg [511:0] tx;
	reg [127:0] wts;
	reg [3:0] mask;
	reg [49:0] ctl;
	reg [127:0] val;
	reg [15:0] tag;
	reg last;
	reg mid;	/* a pass with more to follow taken, its last not yet */
	reg [2:0] nq;	/* last passes taken, quads not yet returned */
	reg [639:0] acc;	/* the passes' sums: lane-major, 4 × 40 bits a lane */

	wire fifo_pop = tr_valid && tr_ready;
	wire take = tc_valid && tc_ready;
	wire [2:0] nq_n;
	wire [1:0] k_inc;
	wire nq_nc, k_nc;

	/* tc_ready is a register (replicated: it enables the pass's fields,
	 * about 900 registers): from the next st, k and nq. */
	(* max_fanout = 64 *) reg rdy;
	wire st_n = take ? RUN : st == RUN && k == 2'd3 ? IDLE : st;
	wire [1:0] k_n = take ? 2'd0 : st == RUN ? k_inc : k;

	assign tc_ready = rdy;
	assign idle = st == IDLE && !mid && nq == 3'd0;

	/* nq + (a last pass taken) - (a quad returned) */
	am_add #(.W(3)) u_nq (.a(nq), .b({3{fifo_pop}}), .ci(take && !tc_ctl[4]), .s(nq_n),
		.co(nq_nc));
	am_add #(.W(2)) u_k (.a(k), .b(2'd0), .ci(1'b1), .s(k_inc), .co(k_nc));

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
			mid <= 1'b0;
			nq <= 3'd0;
			rdy <= 1'b1;
		end else begin
			nq <= nq_n;
			rdy <= nq_n != 3'd4 && (st_n == IDLE || k_n == 2'd3);
			if (take) begin
				st <= RUN;
				mid <= tc_ctl[4];
			end else if (st == RUN && k == 2'd3)
				st <= IDLE;
		end
	end
	/* The pass's fields are taken in every cycle of tc_ready (the enables
	 * do not wait for tc_valid; a cycle without one goes to IDLE). */
	always @(posedge clk) begin
		if (tc_ready) begin
			tx <= tc_texels;
			wts <= tc_wts;
			mask <= tc_mask;
			ctl <= tc_ctl;
			val <= tc_value;
			tag <= tc_tag;
			last <= tc_last;
		end
		if (take)
			k <= 2'd0;
		else if (st == RUN)
			k <= k_inc;
	end
	wire issue = st == RUN;

	/* ---- P1: lane k (RGB565, R8 and R8G8 as RGBA8) ---- */
	wire [127:0] lraw = tx[k*128 +: 128];
	wire [7:0] vkf = ctl[34:27];
	wire [127:0] lt0 = ctl[19] ? {x565(lraw[111:96]), x565(lraw[79:64]), x565(lraw[47:32]),
		x565(lraw[15:0])} : {xrg(lraw[127:96], vkf), xrg(lraw[95:64], vkf), xrg(lraw[63:32], vkf),
		xrg(lraw[31:0], vkf)};

	reg v1;
	reg [127:0] lt1;
	reg [15:0] r565_1;
	reg [31:0] wl1, vw1;
	reg [49:0] ctl1;
	reg mk1, fin1, last1;
	reg [1:0] k1;
	reg [15:0] tag1;
	always @(posedge clk) begin
		lt1 <= lt0;
		r565_1 <= lraw[15:0];
		wl1 <= wts[k*32 +: 32];
		vw1 <= val[k*32 +: 32];
		ctl1 <= ctl;
		mk1 <= mask[k];
		fin1 <= !ctl[4];
		last1 <= last;
		k1 <= k;
		tag1 <= tag;
	end

	/* ---- The fields that go along: P1 → P18 ---- */
	/* {lt, r565, vw, ctl, mk, fin, last, k, tag}: 128 + 16 + 32 + 50 + 3 + 2 + 16 */
	localparam DW = 247;
	wire [DW-1:0] d1 = {lt1, r565_1, vw1, ctl1, mk1, fin1, last1, k1, tag1};
	reg [DW-1:0] dl [2:18];
	reg [18:2] vd;
	always @(posedge clk) begin
		dl[2] <= d1;
		for (i = 3; i <= 18; i = i + 1)
			dl[i] <= dl[i - 1];
	end
	always @(posedge clk) begin
		if (!rst_n) begin
			v1 <= 1'b0;
			vd <= 17'd0;
		end else begin
			v1 <= issue;
			vd <= {vd[17:2], v1};
		end
	end
	wire [49:0] ctl3 = dl[3][70:21], ctl4 = dl[4][70:21], ctl11 = dl[11][70:21];
	wire [49:0] ctl14 = dl[14][70:21], ctl18 = dl[18][70:21];
	wire [127:0] lt4 = dl[4][246:119], lt14 = dl[14][246:119], lt18 = dl[18][246:119];
	wire [15:0] r565_14 = dl[14][118:103];
	wire [31:0] vw18 = dl[18][102:71];
	wire [1:0] k10 = dl[10][17:16], k11 = dl[11][17:16];
	wire v11 = vd[11];
	wire mk18 = dl[18][20], fin18 = dl[18][19], last18 = dl[18][18];
	wire [1:0] k18 = dl[18][17:16];
	wire [15:0] tag18 = dl[18][15:0];

	/* ---- P1 → P5: Dref, the compares, the weights (atg_tu_fpre) ---- */
	wire [3:0] ok;	/* P4 */
	wire [67:0] w5;
	wire [16:0] wp5;
	wire [31:0] fa5;

	atg_tu_fpre pre (
		.clk(clk), .i_vw(vw1), .i_lt(lt1), .i_wl(wl1), .i_bil(ctl1[0]), .i_p17(ctl1[17]),
		.i_p18(ctl1[18]), .i_d32(ctl1[1]), .i_d16(ctl1[34:27] == 8'd124), .i_op(ctl1[12:10]),
		.o_ok(ok), .o_w(w5), .o_wp(wp5), .o_fa(fa5)
	);

	/* ---- P4 → P5: the compares; the channels' bytes ---- */
	reg [127:0] by;	/* channel c, texel t: by[(c*4 + t)*8 +: 8] */
	reg [31:0] tw4;
	always @(*) begin
		for (c = 0; c < 4; c = c + 1)
			for (t = 0; t < 4; t = t + 1) begin
				tw4 = lt4[t*32 +: 32];
				if (ctl4[9])
					/* (pass, 0, 0, 1) as bytes */
					by[(c*4 + t)*8 +: 8] = c == 0 ? {8{ok[t]}} : c == 3 ? 8'hFF : 8'd0;
				else
					/* byte of channel c: RGBA8 c, BGRA8 swaps R and B */
					by[(c*4 + t)*8 +: 8] =
						tw4[(ctl4[1] && c != 1 && c != 3 ? 2 - c : c)*8 +: 8];
			end
	end

	reg [127:0] by5;
	reg [3:0] ok5;
	always @(posedge clk) begin
		by5 <= by;
		ok5 <= ok;
	end

	/* ---- P5 → P11: the sums (atg_tu_fsum a channel), written in P11 ---- */
	wire [39:0] rr [0:3];
	/* lane k's sums, read in P10 (the lane's previous pass wrote them 4 or
	 * more cycles before) */
	reg [159:0] al;
	always @(posedge clk)
		al <= k10 == 2'd0 ? acc[159:0] : k10 == 2'd1 ? acc[319:160] :
			k10 == 2'd2 ? acc[479:320] : acc[639:480];
	reg [39:0] rr12 [0:3];
	genvar gc;
	generate
	for (gc = 0; gc < 4; gc = gc + 1) begin : g_acc
		atg_tu_fsum sum (
			.clk(clk), .i_by(by5[gc*32 +: 32]), .i_w(w5), .i_wp(wp5), .i_al(al[gc*40 +: 40]),
			.i_acc(ctl11[5]), .o_rr(rr[gc])
		);
		always @(posedge clk)
			rr12[gc] <= rr[gc];
	end
	endgenerate
	always @(posedge clk)
		if (v11)
			case (k11)
			2'd0: acc[159:0] <= {rr[3], rr[2], rr[1], rr[0]};
			2'd1: acc[319:160] <= {rr[3], rr[2], rr[1], rr[0]};
			2'd2: acc[479:320] <= {rr[3], rr[2], rr[1], rr[0]};
			default: acc[639:480] <= {rr[3], rr[2], rr[1], rr[0]};
			endcase

	reg [31:0] fa6 [6:14];
	reg [3:0] ok6 [6:18];
	always @(posedge clk) begin
		fa6[6] <= fa5;
		ok6[6] <= ok5;
		for (i = 7; i <= 14; i = i + 1)
			fa6[i] <= fa6[i - 1];
		for (i = 7; i <= 18; i = i + 1)
			ok6[i] <= ok6[i - 1];
	end
	wire [31:0] fa14 = fa6[14];
	wire [3:0] ok18 = ok6[18];


	/* ---- P12 → P18, per channel: A × 0x0101010101 = (A × 257) × 65537
	 * + A × 2^32 (P13-P14), or the other conversions' integers (P14 → P15);
	 * then rnd81: p × 2^(n + eb − 127) as fp32 rounded to nearest even, n
	 * the msb position (80 − lz, P16), eb 55, the LOD query 119, RGB565's
	 * G 49, R and B 47 (the codes 0-3); p << lz (P17); the rounding and
	 * the exponent eb + n (+ 1 on a carry) (P18). ---- */
	/* gather's component and byte, from P13's fields into P14 (the
	 * selections are registered: they drive every bit of the four
	 * channels' integers) */
	wire [49:0] ctl13 = dl[13][70:21];
	reg [2:0] gsw13;
	reg [1:0] gsrc13;
	reg [1:0] gsel14;
	always @(*) begin
		case (ctl13[15:14])
		2'd0: gsw13 = ctl13[38:36];
		2'd1: gsw13 = ctl13[41:39];
		2'd2: gsw13 = ctl13[44:42];
		default: gsw13 = ctl13[47:45];
		endcase
		gsrc13 = gsw13 >= 3'd3 && gsw13 <= 3'd6 ? zsrc(gsw13[1:0]) : ctl13[15:14];
	end
	always @(posedge clk)
		gsel14 <= ctl13[1] && !gsrc13[0] ? gsrc13 ^ 2'd2 : gsrc13;
	reg [127:0] rn18;
	generate
	for (gc = 0; gc < 4; gc = gc + 1) begin : g_cv
		wire [31:0] gtw = lt14[gtx(gc)*32 +: 32];
		wire [31:0] rn;

		atg_tu_frnd rnd (
			.clk(clk), .i_rr(rr12[gc]),
			.i_sel(ctl13[2] ? 3'd1 : ctl13[13] ? (ctl13[8] ? 3'd2 : 3'd3) :
				ctl13[8] && !ctl13[9] && gc == 0 ? 3'd4 :
				ctl13[19] && ctl13[3] && gc == 1 ? 3'd5 :
				ctl13[19] && ctl13[3] && gc != 3 ? 3'd6 : 3'd0),
			.i_fx(fa14[(gc % 2)*16 +: 16]), .i_g24(gtw[23:0]), .i_gb(gtw[gsel14*8 +: 8]),
			.i_d24(lt14[23:0]), .i_c6(r565_14[10:5]),
			.i_c5(gc == 0 ? r565_14[15:11] : r565_14[4:0]), .o_rn(rn)
		);
		always @(*)
			rn18[gc*32 +: 32] = rn;
	end
	endgenerate

	/* ---- P18 → out: the lane's words (atg_tu_fword) ---- */
	wire [127:0] res;

	atg_tu_fword word (.i_rn(rn18), .i_lt(lt18), .i_vw(vw18), .i_ok(ok18), .i_ctl(ctl18),
		.i_mk(mk18), .o_res(res));

	/* ---- The quad's words; the FIFO of returned quads ---- */
	reg [383:0] asmb;	/* lanes 0-2 */
	always @(posedge clk)
		if (vd[18] && fin18 && k18 != 2'd3)
			asmb[k18*128 +: 128] <= res;

	wire [528:0] fo;
	wire f_in_ready;
	wire [2:0] f_count;

	am_fifo #(.W(529), .DEPTH_LOG2(2)) outq (
		.clk(clk), .rst_n(rst_n), .in_valid(vd[18] && fin18 && k18 == 2'd3),
		.in_ready(f_in_ready), .in_data({last18, tag18, res, asmb}), .out_valid(tr_valid),
		.out_ready(tr_ready), .out_data(fo), .count(f_count)
	);
	assign tr_data = fo[511:0];
	assign tr_tag = fo[527:512];
	assign tr_last = fo[528];

	wire unused_ok = &{1'b0, ctl3, ctl4, ctl11, ctl13, ctl14, ctl18, nq_nc, k_nc,
		f_in_ready, f_count, last1, vd[17:12], vd[10:2]};
endmodule

`default_nettype wire
