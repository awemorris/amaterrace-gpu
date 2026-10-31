/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_srgb_enc: Fast fp32 to sRGB 8-bit unorm encoder.
 * 2-stage hierarchical comparator:
 *   - Stage A: 15 fixed constants comparing b >= TH[k] to determine upper nibble hi[7:4].
 *   - Stage B: 15 candidate thresholds from a 16x15 distributed ROM to determine lower nibble lo[3:0].
 * 100% bit-exact with IEEE 754 float32 sRGB EOTF thresholds in atg_srgb.vh.
 * Uses only ~120 LUTs per lane, 0 large ROMs, and fully compliant with ASIC 5nm 1.5 GHz limits.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_srgb_enc (
	input wire [31:0] b,
	output wire [7:0] srgb
);
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire [30:0] b_hi_a, b_hi_b, b_hi_c, b_hi_d, b_lim;
	genvar g_b_in;
	generate
	for (g_b_in = 0; g_b_in < 31; g_b_in = g_b_in + 1) begin : g_buf_b_in
		LUT1 #(.INIT(2'h2)) u_ba (.I0(b[g_b_in]), .O(b_hi_a[g_b_in]));
		LUT1 #(.INIT(2'h2)) u_bb (.I0(b[g_b_in]), .O(b_hi_b[g_b_in]));
		LUT1 #(.INIT(2'h2)) u_bc (.I0(b[g_b_in]), .O(b_hi_c[g_b_in]));
		LUT1 #(.INIT(2'h2)) u_bd (.I0(b[g_b_in]), .O(b_hi_d[g_b_in]));
		LUT1 #(.INIT(2'h2)) u_bl (.I0(b[g_b_in]), .O(b_lim[g_b_in]));
	end
	endgenerate
`else
	wire [30:0] b_hi_a = b[30:0];
	wire [30:0] b_hi_b = b[30:0];
	wire [30:0] b_hi_c = b[30:0];
	wire [30:0] b_hi_d = b[30:0];
	wire [30:0] b_lim  = b[30:0];
`endif

	wire is_nan = (b_lim[30:23] == 8'hFF) && (b_lim[22:0] != 23'd0);
	wire is_neg = b[31];
	wire is_zero = is_nan || is_neg || (b_lim[30:0] < 31'h391F22B4); /* < thr[0] */
	wire is_max  = (!is_neg) && (b_lim[30:0] >= 31'h3F7EDC0E);      /* >= thr[254] */

	wire [30:0] b_lo_wire [0:14];
	genvar g_b;
	generate
	for (g_b = 0; g_b < 15; g_b = g_b + 1) begin : g_b_rep
		(* keep = "true" *) wire [30:0] b_k = b[30:0];
		assign b_lo_wire[g_b] = b_k;
	end
	endgenerate

	/* Stage A: Compare against 15 constant thresholds to get upper nibble hi */
	wire [14:0] cmp_hi_a;
	wire [14:0] cmp_hi_b;

	assign cmp_hi_a[0] = (b_hi_a >= 31'h3BA314BD);
	assign cmp_hi_a[1] = (b_hi_a >= 31'h3C668654);
	assign cmp_hi_a[2] = (b_hi_a >= 31'h3CED78B5);
	assign cmp_hi_a[3] = (b_hi_a >= 31'h3D4EC8D2);
	assign cmp_hi_a[4] = (b_hi_b >= 31'h3DA23384);
	assign cmp_hi_a[5] = (b_hi_b >= 31'h3DECF395);
	assign cmp_hi_a[6] = (b_hi_b >= 31'h3E2457B6);
	assign cmp_hi_a[7] = (b_hi_b >= 31'h3E5B2D9A);
	assign cmp_hi_a[8] = (b_hi_c >= 31'h3E8DB641);
	assign cmp_hi_a[9] = (b_hi_c >= 31'h3EB2BF00);
	assign cmp_hi_a[10] = (b_hi_c >= 31'h3EDCE2B2);
	assign cmp_hi_a[11] = (b_hi_c >= 31'h3F062827);
	assign cmp_hi_a[12] = (b_hi_d >= 31'h3F209A3C);
	assign cmp_hi_a[13] = (b_hi_d >= 31'h3F3DDCE5);
	assign cmp_hi_a[14] = (b_hi_d >= 31'h3F5E0486);

	assign cmp_hi_b = cmp_hi_a;

	/* 15-bit thermometer decode function */
	function [3:0] decode_hi;
		input [14:0] c;
		decode_hi =
			c[14] ? 4'd15 :
			c[13] ? 4'd14 :
			c[12] ? 4'd13 :
			c[11] ? 4'd12 :
			c[10] ? 4'd11 :
			c[9]  ? 4'd10 :
			c[8]  ? 4'd9 :
			c[7]  ? 4'd8 :
			c[6]  ? 4'd7 :
			c[5]  ? 4'd6 :
			c[4]  ? 4'd5 :
			c[3]  ? 4'd4 :
			c[2]  ? 4'd3 :
			c[1]  ? 4'd2 :
			c[0]  ? 4'd1 : 4'd0;
	endfunction

	wire [3:0] hi_root_lo = decode_hi(cmp_hi_a);
	wire [3:0] hi_root_hi = decode_hi(cmp_hi_b);
	wire [3:0] hi = hi_root_lo;

	/* Replicated copies of decoded hi for lower and upper threshold bits */
	wire [3:0] hi_k_lo [0:14];
	wire [3:0] hi_k_hi [0:14];
`ifdef SYNTH_KINTEX7
	wire [3:0] hi_half_a_lo, hi_half_b_lo;
	wire [3:0] hi_half_a_hi, hi_half_b_hi;
	genvar g_h, g_bit;
	generate
	for (g_bit = 0; g_bit < 4; g_bit = g_bit + 1) begin : g_hi_split
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_salo (.I0(hi_root_lo[g_bit]), .O(hi_half_a_lo[g_bit]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sblo (.I0(hi_root_lo[g_bit]), .O(hi_half_b_lo[g_bit]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sahi (.I0(hi_root_hi[g_bit]), .O(hi_half_a_hi[g_bit]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sbhi (.I0(hi_root_hi[g_bit]), .O(hi_half_b_hi[g_bit]));
	end
	for (g_h = 0; g_h < 15; g_h = g_h + 1) begin : g_hi_tree
		wire [3:0] src_lo = (g_h < 8) ? hi_half_a_lo : hi_half_b_lo;
		wire [3:0] src_hi = (g_h < 8) ? hi_half_a_hi : hi_half_b_hi;
		for (g_bit = 0; g_bit < 4; g_bit = g_bit + 1) begin : g_hi_bits
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_blo (
				.I0(src_lo[g_bit]), .O(hi_k_lo[g_h][g_bit])
			);
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_bhi (
				.I0(src_hi[g_bit]), .O(hi_k_hi[g_h][g_bit])
			);
		end
	end
	endgenerate
`else
	genvar g_h;
	generate
	for (g_h = 0; g_h < 15; g_h = g_h + 1) begin : g_hi_rep
		assign hi_k_lo[g_h] = hi_root_lo;
		assign hi_k_hi[g_h] = hi_root_hi;
	end
	endgenerate
`endif

	/* Stage B: 15 candidate thresholds for selected hi */

	function [30:0] get_tl_0;
		input [3:0] h;
		case (h)
		4'd0: get_tl_0 = 31'h391F22B4;
		4'd1: get_tl_0 = 31'h3BB0A731;
		4'd2: get_tl_0 = 31'h3C72DD71;
		4'd3: get_tl_0 = 31'h3CF6D72E;
		4'd4: get_tl_0 = 31'h3D553E73;
		4'd5: get_tl_0 = 31'h3DA66510;
		4'd6: get_tl_0 = 31'h3DF22D50;
		4'd7: get_tl_0 = 31'h3E278099;
		4'd8: get_tl_0 = 31'h3E5EE9D4;
		4'd9: get_tl_0 = 31'h3E8FE170;
		4'd10: get_tl_0 = 31'h3EB53A71;
		4'd11: get_tl_0 = 31'h3EDFB168;
		4'd12: get_tl_0 = 31'h3F07BA92;
		4'd13: get_tl_0 = 31'h3F225913;
		4'd14: get_tl_0 = 31'h3F3FC975;
		4'd15: get_tl_0 = 31'h3F60200E;
		endcase
	endfunction
	wire [30:0] tl_0_l = get_tl_0(hi_k_lo[0]);
	wire [30:0] tl_0_h = get_tl_0(hi_k_hi[0]);
	wire [30:0] tl_0 = {tl_0_h[30:16], tl_0_l[15:0]};
	function [30:0] get_tl_1;
		input [3:0] h;
		case (h)
		4'd0: get_tl_1 = 31'h39EEB40E;
		4'd1: get_tl_1 = 31'h3BBEDCB7;
		4'd2: get_tl_1 = 31'h3C7F950F;
		4'd3: get_tl_1 = 31'h3D0035FC;
		4'd4: get_tl_1 = 31'h3D5BD1D3;
		4'd5: get_tl_1 = 31'h3DAAA6A0;
		4'd6: get_tl_1 = 31'h3DF77817;
		4'd7: get_tl_1 = 31'h3E2AB27D;
		4'd8: get_tl_1 = 31'h3E62AF7E;
		4'd9: get_tl_1 = 31'h3E92118B;
		4'd10: get_tl_1 = 31'h3EB7BB00;
		4'd11: get_tl_1 = 31'h3EE2856A;
		4'd12: get_tl_1 = 31'h3F094FB9;
		4'd13: get_tl_1 = 31'h3F241ABC;
		4'd14: get_tl_1 = 31'h3F41B8EB;
		4'd15: get_tl_1 = 31'h3F623E90;
		endcase
	endfunction
	wire [30:0] tl_1_l = get_tl_1(hi_k_lo[1]);
	wire [30:0] tl_1_h = get_tl_1(hi_k_hi[1]);
	wire [30:0] tl_1 = {tl_1_h[30:16], tl_1_l[15:0]};
	function [30:0] get_tl_2;
		input [3:0] h;
		case (h)
		4'd0: get_tl_2 = 31'h3A46EB61;
		4'd1: get_tl_2 = 31'h3BCDB76D;
		4'd2: get_tl_2 = 31'h3C865702;
		4'd3: get_tl_2 = 31'h3D051BB4;
		4'd4: get_tl_2 = 31'h3D628318;
		4'd5: get_tl_2 = 31'h3DAEF847;
		4'd6: get_tl_2 = 31'h3DFCD3FC;
		4'd7: get_tl_2 = 31'h3E2DED68;
		4'd8: get_tl_2 = 31'h3E667E9F;
		4'd9: get_tl_2 = 31'h3E944696;
		4'd10: get_tl_2 = 31'h3EBA40B1;
		4'd11: get_tl_2 = 31'h3EE55EBD;
		4'd12: get_tl_2 = 31'h3F0AE79F;
		4'd13: get_tl_2 = 31'h3F25DF38;
		4'd14: get_tl_2 = 31'h3F43AB48;
		4'd15: get_tl_2 = 31'h3F64600C;
		endcase
	endfunction
	wire [30:0] tl_2_l = get_tl_2(hi_k_lo[2]);
	wire [30:0] tl_2_h = get_tl_2(hi_k_hi[2]);
	wire [30:0] tl_2 = {tl_2_h[30:16], tl_2_l[15:0]};
	function [30:0] get_tl_3;
		input [3:0] h;
		case (h)
		4'd0: get_tl_3 = 31'h3A8B3E5E;
		4'd1: get_tl_3 = 31'h3BDD3967;
		4'd2: get_tl_3 = 31'h3C8D148F;
		4'd3: get_tl_3 = 31'h3D0A1CEC;
		4'd4: get_tl_3 = 31'h3D69526A;
		4'd5: get_tl_3 = 31'h3DB35A15;
		4'd6: get_tl_3 = 31'h3E012087;
		4'd7: get_tl_3 = 31'h3E313161;
		4'd8: get_tl_3 = 31'h3E6A573E;
		4'd9: get_tl_3 = 31'h3E968095;
		4'd10: get_tl_3 = 31'h3EBCCB85;
		4'd11: get_tl_3 = 31'h3EE83D63;
		4'd12: get_tl_3 = 31'h3F0C8244;
		4'd13: get_tl_3 = 31'h3F27A689;
		4'd14: get_tl_3 = 31'h3F45A08F;
		4'd15: get_tl_3 = 31'h3F668485;
		endcase
	endfunction
	wire [30:0] tl_3_l = get_tl_3(hi_k_lo[3]);
	wire [30:0] tl_3_h = get_tl_3(hi_k_hi[3]);
	wire [30:0] tl_3 = {tl_3_h[30:16], tl_3_l[15:0]};
	function [30:0] get_tl_4;
		input [3:0] h;
		case (h)
		4'd0: get_tl_4 = 31'h3AB3070B;
		4'd1: get_tl_4 = 31'h3BED64AF;
		4'd2: get_tl_4 = 31'h3C940396;
		4'd3: get_tl_4 = 31'h3D0F39D0;
		4'd4: get_tl_4 = 31'h3D703FEE;
		4'd5: get_tl_4 = 31'h3DB7CC1B;
		4'd6: get_tl_4 = 31'h3E03DFAE;
		4'd7: get_tl_4 = 31'h3E347E70;
		4'd8: get_tl_4 = 31'h3E6E3962;
		4'd9: get_tl_4 = 31'h3E98BF89;
		4'd10: get_tl_4 = 31'h3EBF5B81;
		4'd11: get_tl_4 = 31'h3EEB215D;
		4'd12: get_tl_4 = 31'h3F0E1FAA;
		4'd13: get_tl_4 = 31'h3F2970AF;
		4'd14: get_tl_4 = 31'h3F4798BF;
		4'd15: get_tl_4 = 31'h3F68ABFB;
		endcase
	endfunction
	wire [30:0] tl_4_l = get_tl_4(hi_k_lo[4]);
	wire [30:0] tl_4_h = get_tl_4(hi_k_hi[4]);
	wire [30:0] tl_4 = {tl_4_h[30:16], tl_4_l[15:0]};
	function [30:0] get_tl_5;
		input [3:0] h;
		case (h)
		4'd0: get_tl_5 = 31'h3ADACFB8;
		4'd1: get_tl_5 = 31'h3BFE3B46;
		4'd2: get_tl_5 = 31'h3C9B247C;
		4'd3: get_tl_5 = 31'h3D14728A;
		4'd4: get_tl_5 = 31'h3D774BCA;
		4'd5: get_tl_5 = 31'h3DBC4E6B;
		4'd6: get_tl_5 = 31'h3E06A77B;
		4'd7: get_tl_5 = 31'h3E37D49C;
		4'd8: get_tl_5 = 31'h3E722511;
		4'd9: get_tl_5 = 31'h3E9B0377;
		4'd10: get_tl_5 = 31'h3EC1F0A7;
		4'd11: get_tl_5 = 31'h3EEE0AB1;
		4'd12: get_tl_5 = 31'h3F0FBFD2;
		4'd13: get_tl_5 = 31'h3F2B3DAD;
		4'd14: get_tl_5 = 31'h3F4993DB;
		4'd15: get_tl_5 = 31'h3F6AD670;
		endcase
	endfunction
	wire [30:0] tl_5_l = get_tl_5(hi_k_lo[5]);
	wire [30:0] tl_5_h = get_tl_5(hi_k_hi[5]);
	wire [30:0] tl_5 = {tl_5_h[30:16], tl_5_l[15:0]};
	function [30:0] get_tl_6;
		input [3:0] h;
		case (h)
		4'd0: get_tl_6 = 31'h3B014C33;
		4'd1: get_tl_6 = 31'h3C07DF91;
		4'd2: get_tl_6 = 31'h3CA277A6;
		4'd3: get_tl_6 = 31'h3D19C745;
		4'd4: get_tl_6 = 31'h3D7E7624;
		4'd5: get_tl_6 = 31'h3DC0E114;
		4'd6: get_tl_6 = 31'h3E0977F6;
		4'd7: get_tl_6 = 31'h3E3B33EC;
		4'd8: get_tl_6 = 31'h3E761A52;
		4'd9: get_tl_6 = 31'h3E9D4C62;
		4'd10: get_tl_6 = 31'h3EC48AF9;
		4'd11: get_tl_6 = 31'h3EF0F95F;
		4'd12: get_tl_6 = 31'h3F1162BE;
		4'd13: get_tl_6 = 31'h3F2D0D83;
		4'd14: get_tl_6 = 31'h3F4B91E3;
		4'd15: get_tl_6 = 31'h3F6D03E5;
		endcase
	endfunction
	wire [30:0] tl_6_l = get_tl_6(hi_k_lo[6]);
	wire [30:0] tl_6_h = get_tl_6(hi_k_hi[6]);
	wire [30:0] tl_6 = {tl_6_h[30:16], tl_6_l[15:0]};
	function [30:0] get_tl_7;
		input [3:0] h;
		case (h)
		4'd0: get_tl_7 = 31'h3B153089;
		4'd1: get_tl_7 = 31'h3C10F91B;
		4'd2: get_tl_7 = 31'h3CA9FD78;
		4'd3: get_tl_7 = 31'h3D1F382C;
		4'd4: get_tl_7 = 31'h3D82DF90;
		4'd5: get_tl_7 = 31'h3DC58429;
		4'd6: get_tl_7 = 31'h3E0C5126;
		4'd7: get_tl_7 = 31'h3E3E9C67;
		4'd8: get_tl_7 = 31'h3E7A192C;
		4'd9: get_tl_7 = 31'h3E9F9A4C;
		4'd10: get_tl_7 = 31'h3EC72A7C;
		4'd11: get_tl_7 = 31'h3EF3ED6B;
		4'd12: get_tl_7 = 31'h3F13086E;
		4'd13: get_tl_7 = 31'h3F2EE032;
		4'd14: get_tl_7 = 31'h3F4D92D8;
		4'd15: get_tl_7 = 31'h3F6F345A;
		endcase
	endfunction
	wire [30:0] tl_7_l = get_tl_7(hi_k_lo[7]);
	wire [30:0] tl_7_h = get_tl_7(hi_k_hi[7]);
	wire [30:0] tl_7 = {tl_7_h[30:16], tl_7_l[15:0]};
	function [30:0] get_tl_8;
		input [3:0] h;
		case (h)
		4'd0: get_tl_8 = 31'h3B2914DF;
		4'd1: get_tl_8 = 31'h3C1A6B32;
		4'd2: get_tl_8 = 31'h3CB1B653;
		4'd3: get_tl_8 = 31'h3D24C567;
		4'd4: get_tl_8 = 31'h3D869372;
		4'd5: get_tl_8 = 31'h3DCA37B9;
		4'd6: get_tl_8 = 31'h3E0F3314;
		4'd7: get_tl_8 = 31'h3E420E15;
		4'd8: get_tl_8 = 31'h3E7E21A5;
		4'd9: get_tl_8 = 31'h3EA1ED38;
		4'd10: get_tl_8 = 31'h3EC9CF32;
		4'd11: get_tl_8 = 31'h3EF6E6D8;
		4'd12: get_tl_8 = 31'h3F14B0E4;
		4'd13: get_tl_8 = 31'h3F30B5BD;
		4'd14: get_tl_8 = 31'h3F4F96BD;
		4'd15: get_tl_8 = 31'h3F7167D2;
		endcase
	endfunction
	wire [30:0] tl_8_l = get_tl_8(hi_k_lo[8]);
	wire [30:0] tl_8_h = get_tl_8(hi_k_hi[8]);
	wire [30:0] tl_8 = {tl_8_h[30:16], tl_8_l[15:0]};
	function [30:0] get_tl_9;
		input [3:0] h;
		case (h)
		4'd0: get_tl_9 = 31'h3B3CF936;
		4'd1: get_tl_9 = 31'h3C2436C8;
		4'd2: get_tl_9 = 31'h3CB9A298;
		4'd3: get_tl_9 = 31'h3D2A6F22;
		4'd4: get_tl_9 = 31'h3D8A56CB;
		4'd5: get_tl_9 = 31'h3DCEFBD6;
		4'd6: get_tl_9 = 31'h3E121DC5;
		4'd7: get_tl_9 = 31'h3E4588FB;
		4'd8: get_tl_9 = 31'h3E8119E2;
		4'd9: get_tl_9 = 31'h3EA4452B;
		4'd10: get_tl_9 = 31'h3ECC791E;
		4'd11: get_tl_9 = 31'h3EF9E5A8;
		4'd12: get_tl_9 = 31'h3F165C22;
		4'd13: get_tl_9 = 31'h3F328E24;
		4'd14: get_tl_9 = 31'h3F519D92;
		4'd15: get_tl_9 = 31'h3F739E4D;
		endcase
	endfunction
	wire [30:0] tl_9_l = get_tl_9(hi_k_lo[9]);
	wire [30:0] tl_9_h = get_tl_9(hi_k_hi[9]);
	wire [30:0] tl_9 = {tl_9_h[30:16], tl_9_l[15:0]};
	function [30:0] get_tl_10;
		input [3:0] h;
		case (h)
		4'd0: get_tl_10 = 31'h3B50F2D1;
		4'd1: get_tl_10 = 31'h3C2E5CC7;
		4'd2: get_tl_10 = 31'h3CC1C2A9;
		4'd3: get_tl_10 = 31'h3D303584;
		4'd4: get_tl_10 = 31'h3D8E29AB;
		4'd5: get_tl_10 = 31'h3DD3D08F;
		4'd6: get_tl_10 = 31'h3E151143;
		4'd7: get_tl_10 = 31'h3E490D22;
		4'd8: get_tl_10 = 31'h3E8327C7;
		4'd9: get_tl_10 = 31'h3EA6A226;
		4'd10: get_tl_10 = 31'h3ECF2842;
		4'd11: get_tl_10 = 31'h3EFCE9DE;
		4'd12: get_tl_10 = 31'h3F180A29;
		4'd13: get_tl_10 = 31'h3F346968;
		4'd14: get_tl_10 = 31'h3F53A758;
		4'd15: get_tl_10 = 31'h3F75D7CC;
		endcase
	endfunction
	wire [30:0] tl_10_l = get_tl_10(hi_k_lo[10]);
	wire [30:0] tl_10_h = get_tl_10(hi_k_hi[10]);
	wire [30:0] tl_10 = {tl_10_h[30:16], tl_10_l[15:0]};
	function [30:0] get_tl_11;
		input [3:0] h;
		case (h)
		4'd0: get_tl_11 = 31'h3B65FB9B;
		4'd1: get_tl_11 = 31'h3C38DE1A;
		4'd2: get_tl_11 = 31'h3CCA16E3;
		4'd3: get_tl_11 = 31'h3D3618B7;
		4'd4: get_tl_11 = 31'h3D920C27;
		4'd5: get_tl_11 = 31'h3DD8B5F5;
		4'd6: get_tl_11 = 31'h3E180D95;
		4'd7: get_tl_11 = 31'h3E4C9A90;
		4'd8: get_tl_11 = 31'h3E853A86;
		4'd9: get_tl_11 = 31'h3EA9042E;
		4'd10: get_tl_11 = 31'h3ED1DCA2;
		4'd11: get_tl_11 = 31'h3EFFF37E;
		4'd12: get_tl_11 = 31'h3F19BAFA;
		4'd13: get_tl_11 = 31'h3F36478B;
		4'd14: get_tl_11 = 31'h3F55B411;
		4'd15: get_tl_11 = 31'h3F781451;
		endcase
	endfunction
	wire [30:0] tl_11_l = get_tl_11(hi_k_lo[11]);
	wire [30:0] tl_11_h = get_tl_11(hi_k_hi[11]);
	wire [30:0] tl_11 = {tl_11_h[30:16], tl_11_l[15:0]};
	function [30:0] get_tl_12;
		input [3:0] h;
		case (h)
		4'd0: get_tl_12 = 31'h3B7C3403;
		4'd1: get_tl_12 = 31'h3C43BBA4;
		4'd2: get_tl_12 = 31'h3CD29FA4;
		4'd3: get_tl_12 = 31'h3D3C18E4;
		4'd4: get_tl_12 = 31'h3D95FE4F;
		4'd5: get_tl_12 = 31'h3DDDAC19;
		4'd6: get_tl_12 = 31'h3E1B12C2;
		4'd7: get_tl_12 = 31'h3E50314C;
		4'd8: get_tl_12 = 31'h3E875222;
		4'd9: get_tl_12 = 31'h3EAB6B44;
		4'd10: get_tl_12 = 31'h3ED49641;
		4'd11: get_tl_12 = 31'h3F018145;
		4'd12: get_tl_12 = 31'h3F1B6E96;
		4'd13: get_tl_12 = 31'h3F38288F;
		4'd14: get_tl_12 = 31'h3F57C3BE;
		4'd15: get_tl_12 = 31'h3F7A53DD;
		endcase
	endfunction
	wire [30:0] tl_12_l = get_tl_12(hi_k_lo[12]);
	wire [30:0] tl_12_h = get_tl_12(hi_k_hi[12]);
	wire [30:0] tl_12 = {tl_12_h[30:16], tl_12_l[15:0]};
	function [30:0] get_tl_13;
		input [3:0] h;
		case (h)
		4'd0: get_tl_13 = 31'h3B89D060;
		4'd1: get_tl_13 = 31'h3C4EF648;
		4'd2: get_tl_13 = 31'h3CDB5D4B;
		4'd3: get_tl_13 = 31'h3D423632;
		4'd4: get_tl_13 = 31'h3D9A0035;
		4'd5: get_tl_13 = 31'h3DE2B30A;
		4'd6: get_tl_13 = 31'h3E1E20D1;
		4'd7: get_tl_13 = 31'h3E53D15D;
		4'd8: get_tl_13 = 31'h3E896E9D;
		4'd9: get_tl_13 = 31'h3EADD76D;
		4'd10: get_tl_13 = 31'h3ED75521;
		4'd11: get_tl_13 = 31'h3F030B82;
		4'd12: get_tl_13 = 31'h3F1D24FF;
		4'd13: get_tl_13 = 31'h3F3A0C73;
		4'd14: get_tl_13 = 31'h3F59D65F;
		4'd15: get_tl_13 = 31'h3F7C9671;
		endcase
	endfunction
	wire [30:0] tl_13_l = get_tl_13(hi_k_lo[13]);
	wire [30:0] tl_13_h = get_tl_13(hi_k_hi[13]);
	wire [30:0] tl_13 = {tl_13_h[30:16], tl_13_l[15:0]};
	function [30:0] get_tl_14;
		input [3:0] h;
		case (h)
		4'd0: get_tl_14 = 31'h3B962333;
		4'd1: get_tl_14 = 31'h3C5A8EE4;
		4'd2: get_tl_14 = 31'h3CE45032;
		4'd3: get_tl_14 = 31'h3D4870CA;
		4'd4: get_tl_14 = 31'h3D9E11EC;
		4'd5: get_tl_14 = 31'h3DE7CAD9;
		4'd6: get_tl_14 = 31'h3E2137CB;
		4'd7: get_tl_14 = 31'h3E577ACA;
		4'd8: get_tl_14 = 31'h3E8B8FFC;
		4'd9: get_tl_14 = 31'h3EB048AA;
		4'd10: get_tl_14 = 31'h3EDA1946;
		4'd11: get_tl_14 = 31'h3F049877;
		4'd12: get_tl_14 = 31'h3F1EDE36;
		4'd13: get_tl_14 = 31'h3F3BF33A;
		4'd14: get_tl_14 = 31'h3F5BEBF7;
		4'd15: get_tl_14 = 31'h3F7EDC0E;
		endcase
	endfunction
	wire [30:0] tl_14_l = get_tl_14(hi_k_lo[14]);
	wire [30:0] tl_14_h = get_tl_14(hi_k_hi[14]);
	wire [30:0] tl_14 = {tl_14_h[30:24], tl_14_l[23:16], tl_14_h[15:8], tl_14_l[7:0]};

	wire [14:0] cmp_lo;

	assign cmp_lo[0] = (b_lo_wire[0] >= tl_0);
	assign cmp_lo[1] = (b_lo_wire[1] >= tl_1);
	assign cmp_lo[2] = (b_lo_wire[2] >= tl_2);
	assign cmp_lo[3] = (b_lo_wire[3] >= tl_3);
	assign cmp_lo[4] = (b_lo_wire[4] >= tl_4);
	assign cmp_lo[5] = (b_lo_wire[5] >= tl_5);
	assign cmp_lo[6] = (b_lo_wire[6] >= tl_6);
	assign cmp_lo[7] = (b_lo_wire[7] >= tl_7);
	assign cmp_lo[8] = (b_lo_wire[8] >= tl_8);
	assign cmp_lo[9] = (b_lo_wire[9] >= tl_9);
	assign cmp_lo[10] = (b_lo_wire[10] >= tl_10);
	assign cmp_lo[11] = (b_lo_wire[11] >= tl_11);
	assign cmp_lo[12] = (b_lo_wire[12] >= tl_12);
	assign cmp_lo[13] = (b_lo_wire[13] >= tl_13);
	assign cmp_lo[14] = (b_lo_wire[14] >= tl_14);

	/* 15-bit thermometer decode to 4-bit binary */
	wire [3:0] lo =
		cmp_lo[14] ? 4'd15 :
		cmp_lo[13] ? 4'd14 :
		cmp_lo[12] ? 4'd13 :
		cmp_lo[11] ? 4'd12 :
		cmp_lo[10] ? 4'd11 :
		cmp_lo[9]  ? 4'd10 :
		cmp_lo[8]  ? 4'd9 :
		cmp_lo[7]  ? 4'd8 :
		cmp_lo[6]  ? 4'd7 :
		cmp_lo[5]  ? 4'd6 :
		cmp_lo[4]  ? 4'd5 :
		cmp_lo[3]  ? 4'd4 :
		cmp_lo[2]  ? 4'd3 :
		cmp_lo[1]  ? 4'd2 :
		cmp_lo[0]  ? 4'd1 : 4'd0;

`ifdef SYNTH_KINTEX7
	wire is_zero_hi, is_zero_lo;
	wire is_max_hi, is_max_lo;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_z_hi (.I0(is_zero), .O(is_zero_hi));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_z_lo (.I0(is_zero), .O(is_zero_lo));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_m_hi (.I0(is_max), .O(is_max_hi));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_m_lo (.I0(is_max), .O(is_max_lo));
	assign srgb[7:4] = is_zero_hi ? 4'd0 : is_max_hi ? 4'd15 : hi;
	assign srgb[3:0] = is_zero_lo ? 4'd0 : is_max_lo ? 4'd15 : lo;
`else
	assign srgb = is_zero ? 8'd0 : is_max ? 8'd255 : {hi, lo};
`endif
endmodule

`default_nettype wire
