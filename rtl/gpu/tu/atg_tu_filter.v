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
 * Per channel, with a, b, c, d the 8-bit values of texels 0-3 and fu, fv
 * the lane's weights: bilinear (tc_ctl[0]) R = a (256 − fu)(256 − fv) +
 * b fu (256 − fv) + c (256 − fu) fv + d fu fv (= (a (256 − fu) + b fu)
 * (256 − fv) + (c (256 − fu) + d fu) fv), otherwise R = a × 65536.  The
 * 8-bit values are the texel's bytes (BGRA8, tc_ctl[1]: bytes 0 and 2
 * swapped) or, for a compare (tc_ctl[9]), (255 when Dref passes
 * VkCompareOp tc_ctl[12:10] against the texel's depth, else 0; 0; 0;
 * 255), Dref the lane's tc_value word (D24: Dref to unorm24 and an
 * integer compare; D32F, tc_ctl[1]: an fp32 compare, NaN passing only
 * NOT_EQUAL and ALWAYS; as include/atg_depth.vh, the ROP's depth test).
 * Passes: each adds R × W to the lane's sums A (the first, tc_ctl[5] = 0,
 * starts them), W = (fw or 256 − fw) × (fl or 256 − fl) by the pass's
 * slice and level bits tc_ctl[17], [18] (fl, fw the lane's tc_wts[23:16],
 * [31:24]); a pass with tc_ctl[4] (more follow) returns nothing.  The last
 * returns A / (255 × 2^32) as A × 0x0101010101 / 2^72 rounded to fp32 to
 * nearest even (A = a × 2^32 gives exactly the correctly rounded a / 255).
 * A depth format without compare (tc_ctl[8]) returns texel 0 as (D, 0, 0,
 * 1): D32F the word itself, D24 c / (2^24 − 1) as c × (2^48 + 2^24 + 1) /
 * 2^72 rounded to nearest even (the correctly rounded quotient).
 * Gather (tc_ctl[13]): the lane's words are component tc_ctl[15:14] of
 * texels 2, 3, 1, 0 ((i0, j1), (i1, j1), (i1, j0), (i0, j0)), converted
 * alone: UNORM a / 255, a depth component 0 D (others 0, 3 1.0), a
 * compare 1.0 or 0.0.
 * Lanes outside tc_mask give 0; texsz (tc_ctl[2]) gives word 0 = the
 * lane's tc_value word, the others 0; the LOD query (tc_ctl[2], [16])
 * gives tc_value [15:0] / 256 (the level accessed) and [31:16] / 256
 * (λ'), both signed, as fp32.  texf texels convert like the others.
 * RGB565 (tc_ctl[19], the texel's bits 15:0): texf converts exactly, (R /
 * 31, G / 63, B / 31, 1) rounded to nearest even; the other operations
 * take the texel as RGBA8 ((c << 3) | (c >> 2), (c << 2) | (c >> 4), alpha
 * 255) and filter it like RGBA8.
 * The VkFormat of TEX_FORMAT (tc_ctl[34:27]; 0 for the earlier codes):
 * R8_UNORM (9) and R8G8_UNORM (16) texels are taken as RGBA8 with the
 * missing bytes 0 and alpha 255 (border texels too: Vulkan replaces the
 * format's components only); D16_UNORM (124) compares the texel's bits
 * 15:0 with Dref converted to 16-bit UNORM (as atg_fmt_f2unorm).  The
 * component swizzle (tc_ctl[47:36], VkComponentSwizzle of R, G, B, A:
 * IDENTITY, ZERO, ONE, R, G, B, A) is applied last, after a compare, and
 * gather takes the component that the swizzle puts in its place (ZERO and
 * ONE: 0.0 and 1.0); the queries are not swizzled.
 *
 * Pipeline: a pass is taken in IDLE or in the cycle of its predecessor's
 * lane 3 and issues its lanes 0-3 one a cycle (RUN), each with its four
 * channels, into 18 stages without stalls (the cycle after the issue):
 * P1 the lane's texels, weights and Dref; P2-P4 Dref as unorm24 or
 * unorm16 and its key, the texels' keys, the bilinear weights and W
 * (am_mul); P5 the compares and the channels' bytes; P7 the bytes times
 * the weights; P8-P9 their sum R; P11 R × W, the sums A read and written
 * in that cycle (a lane's next pass comes 4 or more cycles later);
 * P13-P14 A × 0x0101010101; P14 the conversion's integer; P15-P17 its
 * rounding to fp32 (leading zeros, shift, round); P18 the lane's words,
 * written to the quad's place.  The quads go out through a FIFO of 4; a
 * pass is taken only while the last passes taken whose quads are not yet
 * returned are fewer than 4.  idle: no quad taken and not returned and no
 * pass with more to follow pending (atg_tu hands a pass of the other path
 * only then).
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
	`include "atg_depth.vh"
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

	/* The component swizzle of four fp32 components. */
	function [127:0] swz4;
		input [127:0] v;
		input [11:0] z;
		integer j;
		reg [2:0] sc;
		begin
			for (j = 0; j < 4; j = j + 1) begin
				sc = z[3*j +: 3];
				swz4[j*32 +: 32] = sc == 3'd1 ? 32'd0 : sc == 3'd2 ? 32'h3F800000 :
					sc >= 3'd3 && sc <= 3'd6 ? v[{zsrc(sc[1:0]), 5'd0} +: 32] : v[j*32 +: 32];
			end
		end
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

	assign tc_ready = nq != 3'd4 && (st == IDLE || k == 2'd3);
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
		end else begin
			nq <= nq_n;
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
	wire [1:0] k11 = dl[11][17:16];
	wire v11 = vd[11];
	wire mk18 = dl[18][20], fin18 = dl[18][19], last18 = dl[18][18];
	wire [1:0] k18 = dl[18][17:16];
	wire [15:0] tag18 = dl[18][15:0];

	/* ---- P1 → P2: Dref's conversions (as atg_depth_u24, atg_fmt_f2unorm
	 * with 16 bits and atg_depth_key), the texels' keys, the weights ---- */
	wire [7:0] de = vw1[30:23];
	wire dnan = de == 8'hFF && vw1[22:0] != 23'd0;
	wire [47:0] p24, p16;
	wire [4:0] t24;
	wire [5:0] sam1;
	wire [32:0] dneg;
	wire p24_nc, p16_nc, t24_nc, sam1_nc, dneg_nc;

	/* m (2^24 − 1) and m (2^16 − 1), m the significand */
	am_sub #(.W(48)) u_p24 (.a({1'b1, vw1[22:0], 24'd0}), .b({24'd0, 1'b1, vw1[22:0]}),
		.bi(1'b0), .d(p24), .bo(p24_nc));
	am_sub #(.W(48)) u_p16 (.a({8'd0, 1'b1, vw1[22:0], 16'd0}), .b({24'd0, 1'b1, vw1[22:0]}),
		.bi(1'b0), .d(p16), .bo(p16_nc));
	am_sub #(.W(5)) u_t24 (.a(5'd30), .b(vw1[27:23]), .bi(1'b0), .d(t24), .bo(t24_nc));
	am_sub #(.W(6)) u_sam1 (.a(6'd21), .b(vw1[28:23]), .bi(1'b0), .d(sam1), .bo(sam1_nc));
	am_sub #(.W(33)) u_dneg (.a(33'd0), .b({2'b00, vw1[30:0]}), .bi(1'b0), .d(dneg),
		.bo(dneg_nc));

	wire d16_1 = ctl1[34:27] == 8'd124;
	wire [32:0] kneg [0:3];
	wire [3:0] kneg_nc;
	genvar gt;
	generate
	for (gt = 0; gt < 4; gt = gt + 1) begin : g_key
		am_sub #(.W(33)) u_kneg (.a(33'd0), .b({2'b00, lt1[gt*32 +: 31]}), .bi(1'b0),
			.d(kneg[gt]), .bo(kneg_nc[gt]));
	end
	endgenerate

	wire [8:0] ru, rv, rw, rl;
	wire [15:0] fan0, fan1;
	wire [5:0] w_nc;

	am_sub #(.W(9)) u_ru (.a(9'd256), .b({1'b0, wl1[7:0]}), .bi(1'b0), .d(ru), .bo(w_nc[0]));
	am_sub #(.W(9)) u_rv (.a(9'd256), .b({1'b0, wl1[15:8]}), .bi(1'b0), .d(rv), .bo(w_nc[1]));
	am_sub #(.W(9)) u_rl (.a(9'd256), .b({1'b0, wl1[23:16]}), .bi(1'b0), .d(rl), .bo(w_nc[2]));
	am_sub #(.W(9)) u_rw (.a(9'd256), .b({1'b0, wl1[31:24]}), .bi(1'b0), .d(rw), .bo(w_nc[3]));
	/* the LOD query's magnitudes */
	am_sub #(.W(16)) u_fa0 (.a(16'd0), .b(vw1[15:0]), .bi(1'b0), .d(fan0), .bo(w_nc[4]));
	am_sub #(.W(16)) u_fa1 (.a(16'd0), .b(vw1[31:16]), .bi(1'b0), .d(fan1), .bo(w_nc[5]));

	reg [47:0] p24_2, p16_2;
	reg [4:0] t24_2;
	reg [5:0] sam1_2;
	reg [32:0] ka32_2;
	reg u24z2, u24o2, u16z2, u16o2;
	reg [131:0] kb2;
	reg [3:0] kn2;
	reg [8:0] wu2 [0:3];
	reg [8:0] wv2 [0:3];
	reg [8:0] wa2, wb2;
	reg [31:0] fa2;
	/* texel t's key (D32F: the order key; D16, D24: the bits) and NaN */
	wire [131:0] kbw;
	wire [3:0] knw;
	generate
	for (gt = 0; gt < 4; gt = gt + 1) begin : g_kb
		wire [31:0] tw = lt1[gt*32 +: 32];
		assign kbw[gt*33 +: 33] = ctl1[1] ? (tw[30:23] == 8'd0 ? 33'd0 : tw[31] ? kneg[gt] :
			{2'b00, tw[30:0]}) : d16_1 ? {17'd0, tw[15:0]} : {9'd0, tw[23:0]};
		assign knw[gt] = ctl1[1] && (dnan || (tw[30:23] == 8'hFF && tw[22:0] != 23'd0));
	end
	endgenerate
	always @(posedge clk) begin
		p24_2 <= p24;
		p16_2 <= p16;
		t24_2 <= t24;
		sam1_2 <= sam1;
		ka32_2 <= de == 8'd0 ? 33'd0 : vw1[31] ? dneg : {2'b00, vw1[30:0]};
		u24z2 <= de == 8'd0 || vw1[31] || dnan || de < 8'd102;
		u24o2 <= de >= 8'd127;
		u16z2 <= vw1[31] || dnan || de < 8'd103;
		u16o2 <= de >= 8'd127;
		kb2 <= kbw;
		kn2 <= knw;
		for (t = 0; t < 4; t = t + 1) begin
			/* texel t's bilinear factors (without bilinear 256 × 256 for texel 0) */
			wu2[t] <= !ctl1[0] ? (t == 0 ? 9'd256 : 9'd0) : t[0] ? {1'b0, wl1[7:0]} : ru;
			wv2[t] <= !ctl1[0] ? 9'd256 : t[1] ? {1'b0, wl1[15:8]} : rv;
		end
		wa2 <= ctl1[17] ? {1'b0, wl1[31:24]} : rw;
		wb2 <= ctl1[18] ? {1'b0, wl1[23:16]} : rl;
		fa2 <= {vw1[31] ? fan1 : vw1[31:16], vw1[15] ? fan0 : vw1[15:0]};
	end

	/* ---- P2 → P3 ---- */
	wire [71:0] z24;
	wire [47:0] s16;

	am_shift #(.W(72), .SW(5)) u_z24 (.a({p24_2, 24'd0}), .amt(t24_2), .left(1'b0),
		.arith(1'b0), .y(z24));
	am_shift #(.W(48), .SW(6)) u_s16 (.a(p16_2), .amt(sam1_2), .left(1'b0), .arith(1'b0),
		.y(s16));

	reg [47:0] m16;
	always @(*)
		for (i = 0; i < 48; i = i + 1)
			m16[i] = i[5:0] < sam1_2;

	wire [17:0] w3 [0:3];
	wire [17:0] wp3;
	generate
	for (gt = 0; gt < 4; gt = gt + 1) begin : g_w
		am_mul #(.AW(9), .BW(9), .SIGNED(0), .LAT(1)) u_w (
			.clk(clk), .en(1'b1), .a(wu2[gt]), .b(wv2[gt]), .p(w3[gt])
		);
	end
	endgenerate
	am_mul #(.AW(9), .BW(9), .SIGNED(0), .LAT(1)) u_wp (
		.clk(clk), .en(1'b1), .a(wa2), .b(wb2), .p(wp3)
	);

	reg [24:0] z3;	/* bits 71:47 */
	reg st24_3, st16_3;
	reg [16:0] s16_3;	/* bits 16:0 */
	reg [32:0] ka32_3;
	reg u24z3, u24o3, u16z3, u16o3;
	reg [131:0] kb3;
	reg [3:0] kn3;
	reg [31:0] fa3;
	always @(posedge clk) begin
		z3 <= z24[71:47];
		st24_3 <= z24[46:0] != 47'd0;
		s16_3 <= s16[16:0];
		st16_3 <= (p16_2 & m16) != 48'd0;
		{ka32_3, u24z3, u24o3, u16z3, u16o3, kb3, kn3, fa3} <=
			{ka32_2, u24z2, u24o2, u16z2, u16o2, kb2, kn2, fa2};
	end

	/* ---- P3 → P4: the roundings, the reference's key ---- */
	wire [23:0] q24;
	wire [15:0] q16;
	wire q24_nc, q16_nc;

	am_add #(.W(24)) u_q24 (.a(z3[24:1]), .b(24'd0), .ci(z3[0] && (st24_3 || z3[1])), .s(q24),
		.co(q24_nc));
	am_add #(.W(16)) u_q16 (.a(s16_3[16:1]), .b(16'd0), .ci(s16_3[0] && (st16_3 || s16_3[1])),
		.s(q16), .co(q16_nc));

	wire [23:0] dref24 = u24z3 ? 24'd0 : u24o3 ? 24'hFFFFFF : q24;
	wire [15:0] dref16 = u16z3 ? 16'd0 : u16o3 ? 16'hFFFF : q16;

	reg [32:0] ka4;
	reg [131:0] kb4;
	reg [3:0] kn4;
	reg [31:0] fa4;
	reg [17:0] w4 [0:3];
	reg [17:0] wp4;
	always @(posedge clk) begin
		ka4 <= ctl3[1] ? ka32_3 : ctl3[34:27] == 8'd124 ? {17'd0, dref16} : {9'd0, dref24};
		kb4 <= kb3;
		kn4 <= kn3;
		fa4 <= fa3;
		for (t = 0; t < 4; t = t + 1)
			w4[t] <= w3[t];
		wp4 <= wp3;
	end

	/* ---- P4 → P5: the compares; the channels' bytes ---- */
	reg [3:0] ok;
	reg [127:0] by;	/* channel c, texel t: by[(c*4 + t)*8 +: 8] */
	reg [31:0] tw4;
	always @(*) begin
		for (t = 0; t < 4; t = t + 1)
			ok[t] = atg_depth_pass(ctl4[12:10], ka4, kb4[t*33 +: 33], kn4[t]);
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
	reg [17:0] w5 [0:3];
	reg [17:0] wp5;
	reg [3:0] ok5;
	reg [31:0] fa5;
	always @(posedge clk) begin
		by5 <= by;
		for (t = 0; t < 4; t = t + 1)
			w5[t] <= w4[t];
		wp5 <= wp4;
		ok5 <= ok;
		fa5 <= fa4;
	end

	/* ---- P5 → P7: the bytes times the weights ---- */
	wire [24:0] pr7 [0:15];
	genvar gc;
	generate
	for (gc = 0; gc < 16; gc = gc + 1) begin : g_pr
		am_mul #(.AW(8), .BW(17), .SIGNED(0), .LAT(2)) u_pr (
			.clk(clk), .en(1'b1), .a(by5[gc*8 +: 8]), .b(w5[gc % 4][16:0]), .p(pr7[gc])
		);
	end
	endgenerate

	reg [17:0] wp6, wp7;
	always @(posedge clk) begin
		wp6 <= wp5;
		wp7 <= wp6;
	end

	/* ---- P7 → P9: R = the sum of the four (below 2^24) ---- */
	wire [25:0] s01 [0:3];
	wire [25:0] s23 [0:3];
	wire [25:0] rs [0:3];
	wire [11:0] s_nc;
	reg [25:0] s01_8 [0:3];
	reg [25:0] s23_8 [0:3];
	reg [17:0] wp8, wp9;
	reg [23:0] r9 [0:3];
	generate
	for (gc = 0; gc < 4; gc = gc + 1) begin : g_sum
		am_add #(.W(26)) u_s01 (.a({1'b0, pr7[gc*4]}), .b({1'b0, pr7[gc*4 + 1]}), .ci(1'b0),
			.s(s01[gc]), .co(s_nc[gc*3]));
		am_add #(.W(26)) u_s23 (.a({1'b0, pr7[gc*4 + 2]}), .b({1'b0, pr7[gc*4 + 3]}), .ci(1'b0),
			.s(s23[gc]), .co(s_nc[gc*3 + 1]));
		am_add #(.W(26)) u_r (.a(s01_8[gc]), .b(s23_8[gc]), .ci(1'b0), .s(rs[gc]),
			.co(s_nc[gc*3 + 2]));
		always @(posedge clk) begin
			s01_8[gc] <= s01[gc];
			s23_8[gc] <= s23[gc];
			r9[gc] <= rs[gc][23:0];
		end
	end
	endgenerate
	always @(posedge clk) begin
		wp8 <= wp7;
		wp9 <= wp8;
	end

	/* ---- P9 → P11: R × W; P11 → P12: the sums ---- */
	wire [40:0] rw11 [0:3];
	wire [39:0] rr [0:3];
	wire [3:0] rr_nc;
	wire [159:0] al = k11 == 2'd0 ? acc[159:0] : k11 == 2'd1 ? acc[319:160] :
		k11 == 2'd2 ? acc[479:320] : acc[639:480];
	reg [39:0] rr12 [0:3];
	generate
	for (gc = 0; gc < 4; gc = gc + 1) begin : g_acc
		am_mul #(.AW(24), .BW(17), .SIGNED(0), .LAT(2)) u_rw (
			.clk(clk), .en(1'b1), .a(r9[gc]), .b(wp9[16:0]), .p(rw11[gc])
		);
		am_add #(.W(40)) u_rr (.a(ctl11[5] ? al[gc*40 +: 40] : 40'd0), .b(rw11[gc][39:0]),
			.ci(1'b0), .s(rr[gc]), .co(rr_nc[gc]));
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
	wire [11:0] p_nc;
	wire [7:0] e_nc;
	wire [3:0] m_nc;
	reg [127:0] rn18;
	generate
	for (gc = 0; gc < 4; gc = gc + 1) begin : g_cv
		wire [48:0] x;
		wire [64:0] y;
		wire [80:0] p;
		reg [48:0] x13;
		reg [39:0] rr13, rr14;
		reg [64:0] y14;

		am_add #(.W(49)) u_x (.a({9'd0, rr12[gc]}), .b({1'b0, rr12[gc], 8'd0}), .ci(1'b0),
			.s(x), .co(p_nc[gc*3]));
		am_add #(.W(65)) u_y (.a({16'd0, x13}), .b({x13, 16'd0}), .ci(1'b0), .s(y),
			.co(p_nc[gc*3 + 1]));
		am_add #(.W(81)) u_p (.a({16'd0, y14}), .b({9'd0, rr14, 32'd0}), .ci(1'b0), .s(p),
			.co(p_nc[gc*3 + 2]));

		always @(posedge clk) begin
			x13 <= x;
			rr13 <= rr12[gc];
			y14 <= y;
			rr14 <= rr13;
		end

		/* the integer of channel gc (P14) */
		wire [31:0] gtw = lt14[gtx(gc)*32 +: 32];
		wire [7:0] gbt = gtw[gsel14*8 +: 8];
		wire [15:0] fx = fa14[(gc % 2)*16 +: 16];
		wire [4:0] c5 = gc == 0 ? r565_14[15:11] : r565_14[4:0];
		/* the source (from P13's fields): 0 the sum, 1 the LOD query, 2
		 * gather of depth, 3 gather of a colour, 4 a depth texel, 5 RGB565's
		 * G, 6 its R or B */
		reg [2:0] sel;
		always @(posedge clk)
			sel <= ctl13[2] ? 3'd1 : ctl13[13] ? (ctl13[8] ? 3'd2 : 3'd3) :
				ctl13[8] && !ctl13[9] && gc == 0 ? 3'd4 :
				ctl13[19] && ctl13[3] && gc == 1 ? 3'd5 :
				ctl13[19] && ctl13[3] && gc != 3 ? 3'd6 : 3'd0;
		reg [80:0] np;
		reg [1:0] ncode;
		always @(*) begin
			ncode = sel == 3'd1 ? 2'd1 : sel == 3'd5 ? 2'd2 : sel == 3'd6 ? 2'd3 : 2'd0;
			case (sel)
			3'd1: np = {65'd0, fx};
			3'd2: np = {9'd0, gtw[23:0], gtw[23:0], gtw[23:0]};
			3'd3: np = {9'd0, {5{gbt}}, 32'd0};
			3'd4: np = {9'd0, lt14[23:0], lt14[23:0], lt14[23:0]};
			/* c / 63: c × sum(2^6i, i < 13) */
			3'd5: np = {3'd0, {13{r565_14[10:5]}}};
			/* c / 31: c × sum(2^5i, i < 16) */
			3'd6: np = {1'd0, {16{c5}}};
			default: np = p;
			endcase
		end

		reg [80:0] np15, np16;
		reg [1:0] nc15, nc16;
		reg [6:0] lz16;
		reg z16, z17;
		reg [6:0] lz;
		always @(*) begin
			lz = 7'd0;
			for (i = 0; i < 81; i = i + 1)
				if (np15[i])
					lz = 7'd80 - i[6:0];
		end
		always @(posedge clk) begin
			np15 <= np;
			nc15 <= ncode;
			np16 <= np15;
			nc16 <= nc15;
			lz16 <= lz;
			z16 <= np15 == 81'd0;
		end

		/* eb + 80 and eb + 81 of the code */
		wire [7:0] eb80 = nc16 == 2'd1 ? 8'd199 : nc16 == 2'd2 ? 8'd129 : nc16 == 2'd3 ? 8'd127 :
			8'd135;
		wire [7:0] eb81 = nc16 == 2'd1 ? 8'd200 : nc16 == 2'd2 ? 8'd130 : nc16 == 2'd3 ? 8'd128 :
			8'd136;
		wire [80:0] ny;
		wire [7:0] ne0, ne1;

		am_shift #(.W(81), .SW(7)) u_ny (.a(np16), .amt(lz16), .left(1'b1), .arith(1'b0),
			.y(ny));
		am_sub #(.W(8)) u_ne0 (.a(eb80), .b({1'b0, lz16}), .bi(1'b0), .d(ne0), .bo(e_nc[gc*2]));
		am_sub #(.W(8)) u_ne1 (.a(eb81), .b({1'b0, lz16}), .bi(1'b0), .d(ne1),
			.bo(e_nc[gc*2 + 1]));

		reg [24:0] ny17;	/* bits 80:56 */
		reg nst17;
		reg [7:0] ne0_17, ne1_17;
		always @(posedge clk) begin
			ny17 <= ny[80:56];
			nst17 <= ny[55:0] != 56'd0;
			z17 <= z16;
			ne0_17 <= ne0;
			ne1_17 <= ne1;
		end

		wire [24:0] m;

		am_add #(.W(25)) u_m (.a({1'b0, ny17[24:1]}), .b(25'd0),
			.ci(ny17[0] && (nst17 || ny17[1])), .s(m), .co(m_nc[gc]));

		always @(posedge clk)
			rn18[gc*32 +: 32] <= z17 ? 32'd0 : {1'b0, m[24] ? ne1_17 : ne0_17,
				m[24] ? m[23:1] : m[22:0]};
		wire unused_cv = &{1'b0, ny[55:0] & 56'd0};
	end
	endgenerate

	/* ---- P18 → out: the lane's words ---- */
	reg [127:0] res;
	reg [31:0] gw;
	reg [2:0] gsw18;
	reg [1:0] gsrc18;
	always @(*) begin
		case (ctl18[15:14])
		2'd0: gsw18 = ctl18[38:36];
		2'd1: gsw18 = ctl18[41:39];
		2'd2: gsw18 = ctl18[44:42];
		default: gsw18 = ctl18[47:45];
		endcase
		gsrc18 = gsw18 >= 3'd3 && gsw18 <= 3'd6 ? zsrc(gsw18[1:0]) : ctl18[15:14];
		res = rn18;
		if (ctl18[19] && ctl18[3])	/* texf of RGB565: exact */
			res[127:96] = 32'h3F800000;
		if (ctl18[8] && !ctl18[9])
			res = {32'h3F800000, 64'd0, ctl18[1] ? lt18[31:0] : rn18[31:0]};
		if (ctl18[13]) begin
			/* gather: word g is texel 2, 3, 1, 0 */
			for (c = 0; c < 4; c = c + 1) begin
				gw = lt18[gtx(c[1:0])*32 +: 32];
				if (ctl18[9])
					res[c*32 +: 32] = ok18[gtx(c[1:0])] ? 32'h3F800000 : 32'd0;
				else if (gsw18 == 3'd1 || gsw18 == 3'd2)
					res[c*32 +: 32] = gsw18 == 3'd2 ? 32'h3F800000 : 32'd0;
				else if (ctl18[8])
					res[c*32 +: 32] = gsrc18 == 2'd0 ? (ctl18[1] ? gw : rn18[c*32 +: 32]) :
						gsrc18 == 2'd3 ? 32'h3F800000 : 32'd0;
				else
					res[c*32 +: 32] = rn18[c*32 +: 32];
			end
		end else
			res = swz4(res, ctl18[47:36]);
		if (ctl18[2])
			res = ctl18[16] ? {64'd0, vw18[31], rn18[62:32], vw18[15], rn18[30:0]} :
				{96'd0, vw18};
		if (!mk18)
			res = 128'd0;
	end

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

	wire unused_ok = &{1'b0, ctl3, ctl4, ctl11, ctl13, ctl14, ctl18, nq_nc, k_nc, p24_nc, p16_nc,
		t24_nc, sam1_nc, dneg_nc, kneg_nc,
		w_nc, s_nc, rr_nc, p_nc, e_nc, m_nc, q24_nc, q16_nc, f_in_ready, f_count, wp3[17],
		wp9[17], s16[47:17], z24[46:0], last1, vd[17:12], vd[10:2]};
endmodule

`default_nettype wire
