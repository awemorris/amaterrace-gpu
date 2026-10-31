/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_blend: the blend-over of the blitter's 2D engine (atg_blt_2d):
 * a line of 32-bit pixels, source over destination with premultiplied
 * alpha in bits 31:24, per byte out = src + round(dst x (255 - src.a) /
 * 255), saturated at 255 (docs/ghci.md section 8.2).
 *
 * go (a pulse) starts a line: src and dst are held by the caller until
 * done; three stages, one word a cycle (take the words, the four 8 x 8
 * products, the sums); out holds the blended line from done (a pulse,
 * WPL + 2 cycles after go) until the next go.  round(t / 255) is (t + 128
 * + ((t + 128) >> 8)) >> 8.  See spec/gpu/blt/atg_blt_blend.md.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_blt_blend #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	input wire go,
	input wire [LINE_BYTES*8-1:0] src,
	input wire [LINE_BYTES*8-1:0] dst,
	output reg done,
	output wire [LINE_BYTES*8-1:0] out
);
	localparam WPL = LINE_BYTES / 4;	/* 32-bit words per line */
	localparam WS = LINE_SHIFT - 2;		/* log2(WPL) */

	/* verilator lint_off WIDTHTRUNC */
	localparam [WS:0] WPL_V = WPL;
	/* verilator lint_on WIDTHTRUNC */

	(* max_fanout = 16 *) reg run;
	(* max_fanout = 16 *) reg [WS:0] bi;		/* the next word to take */
	(* max_fanout = 16 *) reg a_v;
	(* max_fanout = 16 *) reg [WS-1:0] a_i;
	(* max_fanout = 16 *) reg [31:0] a_s;
	(* max_fanout = 16 *) reg [31:0] a_d;
	(* max_fanout = 16 *) reg m1_v;
	(* max_fanout = 16 *) reg [WS-1:0] m1_i;
	(* max_fanout = 16 *) reg [31:0] m1_s;
	(* max_fanout = 16 *) reg m2_v;
	(* max_fanout = 16 *) reg [WS-1:0] m2_i;
	(* max_fanout = 16 *) reg [31:0] m2_s;
	(* max_fanout = 16 *) reg r1_v;
	(* max_fanout = 16 *) reg [WS-1:0] r1_i;
	(* max_fanout = 16 *) reg [31:0] r1_s;
	(* max_fanout = 16 *) reg [67:0] r1_t1;
	(* max_fanout = 16 *) reg c_v;
	(* max_fanout = 16 *) reg [WS-1:0] c_i;
	(* max_fanout = 16 *) reg [31:0] c_s;
	(* max_fanout = 16 *) reg [35:0] c_r;
	wire [7:0] inv_a = ~a_s[31:24];	/* 255 - a */

	/*
	 * Per channel: the product d x (255 - a) (am_mul LAT=2),
	 * then round(t / 255) as (t + 128 + ((t + 128) >> 8)) >> 8 registered in c_r (stage 2.5),
	 * then c_s + c_r, saturated (stage 3).
	 */
	wire [63:0] prod;
	(* keep = "true", max_fanout = 16 *) wire [31:0] b_out;
	wire [WS:0] bi_inc;
	wire bi_co_unused;

	am_add #(.W(WS + 1)) a_bi (.a(bi), .b({(WS + 1){1'b0}}), .ci(1'b1), .s(bi_inc), .co(bi_co_unused));

	wire [35:0] stage2_round;
	genvar c;
	generate
	for (c = 0; c < 4; c = c + 1) begin : g_ch
		wire [16:0] t1, t2;
		wire [8:0] sum;
		wire t1_co_unused, t2_co_unused, sum_co_unused;

		am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(2)) m_p (.clk(clk), .en(1'b1), .a(a_d[c*8 +: 8]), .b(inv_a),
			.p(prod[c*16 +: 16]));
		am_add #(.W(17)) a_t1 (.a({1'b0, prod[c*16 +: 16]}), .b(17'd128), .ci(1'b0), .s(t1), .co(t1_co_unused));
		am_add #(.W(17)) a_t2 (.a(r1_t1[c*17 +: 17]), .b({8'd0, r1_t1[c*17 + 8 +: 9]}), .ci(1'b0), .s(t2), .co(t2_co_unused));
		assign stage2_round[c*9 +: 9] = t2[16:8];

		am_add #(.W(9)) a_s (.a({1'b0, c_s[c*8 +: 8]}), .b(c_r[c*9 +: 9]), .ci(1'b0), .s(sum), .co(sum_co_unused));
		assign b_out[c*8 +: 8] = sum[8] ? 8'hFF : sum[7:0];

		wire unused_ok = &{1'b0, t1_co_unused, t2_co_unused, sum_co_unused, t2[7:0]};
	end
	endgenerate

	(* keep = "true", dont_touch = "true" *) wire rst_blend_high = !rst_n;
	(* keep = "true" *) wire take_word = run && (bi != WPL_V);

	/* Sliced output registers for fanout control (<= 16 per enable) */
	genvar oi;
	generate
		for (oi = 0; oi < WPL; oi = oi + 1) begin : g_out
			(* keep = "true" *) wire ce_lo = !go && run && c_v && (c_i == oi[WS-1:0]);
			(* keep = "true" *) wire ce_hi = !go && run && c_v && (c_i == oi[WS-1:0]);
			(* equivalent_register_removal = "no", max_fanout = 16 *) reg [15:0] w_lo;
			(* equivalent_register_removal = "no", max_fanout = 16 *) reg [15:0] w_hi;
			always @(posedge clk) begin
				if (ce_lo)
					w_lo <= b_out[15:0];
				if (ce_hi)
					w_hi <= b_out[31:16];
			end
			assign out[oi*32 +: 16] = w_lo;
			assign out[oi*32 + 16 +: 16] = w_hi;
		end
	endgenerate

	/* Slice input word mux into 4-bit chunks with LUT1 buffers so bi[WS-1:0] has fanout <= 16 */
	wire [31:0] sel_src;
	wire [31:0] sel_dst;
	genvar mxi;
`ifdef SYNTH_KINTEX7
	genvar mbi;
`endif
	generate
		for (mxi = 0; mxi < 8; mxi = mxi + 1) begin : g_in_mux
			wire [WS-1:0] bi_s, bi_d;
`ifdef SYNTH_KINTEX7
			for (mbi = 0; mbi < WS; mbi = mbi + 1) begin : g_bibuf
				LUT1 #(.INIT(2'b10)) u_bs (.I0(bi[mbi]), .O(bi_s[mbi]));
				LUT1 #(.INIT(2'b10)) u_bd (.I0(bi[mbi]), .O(bi_d[mbi]));
			end
`else
			assign bi_s = bi[WS-1:0];
			assign bi_d = bi[WS-1:0];
`endif
			assign sel_src[mxi*4 +: 4] = src[{bi_s, mxi[2:0], 2'b00} +: 4];
			assign sel_dst[mxi*4 +: 4] = dst[{bi_d, mxi[2:0], 2'b00} +: 4];
		end
	endgenerate

	always @(posedge clk) begin
		if (rst_blend_high) begin
			run <= 1'b0;
			done <= 1'b0;
			bi <= {(WS + 1){1'b0}};
			a_v <= 1'b0;
			m1_v <= 1'b0;
			m2_v <= 1'b0;
			r1_v <= 1'b0;
			c_v <= 1'b0;
		end else begin
			done <= 1'b0;
			if (go) begin
				run <= 1'b1;
				bi <= {(WS + 1){1'b0}};
				a_v <= 1'b0;
				m1_v <= 1'b0;
				m2_v <= 1'b0;
				r1_v <= 1'b0;
				c_v <= 1'b0;
			end else if (run) begin
				/* Stage 1: take word bi. */
				a_v <= bi != WPL_V;
				if (take_word) begin
					bi <= bi_inc;
				end
				/* Stage 1.1: am_mul pipeline match */
				m1_v <= a_v;
				/* Stage 1.2: am_mul pipeline match */
				m2_v <= m1_v;
				/* Stage 2.1: register prod + 128 (Post-DSP LUT <= 1) */
				r1_v <= m2_v;
				if (bi == WPL_V && !a_v && !m1_v && !m2_v && !r1_v && !c_v) begin
					run <= 1'b0;
					done <= 1'b1;
				end
			end
			c_v <= !go && run && r1_v;
		end
	end

	/* Free-running datapath registers in separate always block (no rst_blend_high CE!) */
	always @(posedge clk) begin
		a_s <= sel_src;
		a_d <= sel_dst;
		a_i <= bi[WS-1:0];
		m1_s <= a_s;
		m1_i <= a_i;
		m2_s <= m1_s;
		m2_i <= m1_i;
		r1_s <= m2_s;
		r1_i <= m2_i;
		r1_t1 <= {g_ch[3].t1, g_ch[2].t1, g_ch[1].t1, g_ch[0].t1};
		c_s <= r1_s;
		c_i <= r1_i;
		c_r <= stage2_round;
	end

	wire unused_ok = &{1'b0, bi_co_unused};
endmodule

`default_nettype wire
