/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_align: byte-aligned window selector (combinational).
 * Extracts a LINE_BYTES window from a 2*LINE_BYTES double line
 * starting at byte offset off (0..LINE_BYTES-1).
 *
 * Implemented with 3 stages of 4-to-1 byte multiplexers:
 *   Stage 0: shifts by 0, 1, 2, or 3 bytes (off[1:0])
 *   Stage 1: shifts by 0, 4, 8, or 12 bytes (off[3:2])
 *   Stage 2: shifts by 0, 16, 32, or 48 bytes (off[5:4])
 * Strictly <= 3 LUT6 logic levels from input to output.
 * Fully buffered select trees guaranteeing fanout <= 16 on all nets.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_align #(
	parameter LINE_BYTES = 64,
	parameter LINE_SHIFT = 6
) (
	input wire [2 * LINE_BYTES * 8 - 1:0] in_data,
	input wire [LINE_SHIFT - 1:0] off,
	output wire [LINE_BYTES * 8 - 1:0] out_data
);
	localparam US = LINE_SHIFT;

	/* Number of intermediate bytes needed per stage */
	localparam S2_OUT_BYTES = LINE_BYTES;
	localparam S1_OUT_BYTES = (LINE_BYTES >= 64) ? (LINE_BYTES + 48) : (LINE_BYTES + 16);
	localparam S0_OUT_BYTES = S1_OUT_BYTES + 12;

	/* Unpack in_data into byte array */
	wire [7:0] in_b [0:2*LINE_BYTES-1];
	genvar ui;
	generate
		for (ui = 0; ui < 2 * LINE_BYTES; ui = ui + 1) begin : g_in_unpack
			assign in_b[ui] = in_data[ui*8 +: 8];
		end
	endgenerate

	/*
	 * =========================================================================
	 * Buffer Trees for Select Bits (Target fanout <= 16 per net)
	 * =========================================================================
	 */
	/* Stage 0 Select: off[1:0] */
	/* Each leaf buffer drives 2 bytes (16 LUT6s) */
	localparam S0_LEAF_CNT = (S0_OUT_BYTES + 1) / 2;
	localparam S0_MID_CNT  = (S0_LEAF_CNT + 7) / 8;
	wire [1:0] s0_sel [0:S0_LEAF_CNT-1];

`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) wire [1:0] s0_mid [0:S0_MID_CNT-1];
	genvar sm0, sl0, b0;
	generate
		for (b0 = 0; b0 < 2; b0 = b0 + 1) begin : g_s0_bit
			for (sm0 = 0; sm0 < S0_MID_CNT; sm0 = sm0 + 1) begin : g_s0_mid
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_m0 (.I0(off[b0]), .O(s0_mid[sm0][b0]));
			end
			for (sl0 = 0; sl0 < S0_LEAF_CNT; sl0 = sl0 + 1) begin : g_s0_leaf
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_l0 (.I0(s0_mid[sl0 / 8][b0]), .O(s0_sel[sl0][b0]));
			end
		end
	endgenerate
`else
	genvar sl0_gen;
	generate
		for (sl0_gen = 0; sl0_gen < S0_LEAF_CNT; sl0_gen = sl0_gen + 1) begin : g_s0_leaf_sim
			assign s0_sel[sl0_gen] = off[1:0];
		end
	endgenerate
`endif

	/* Stage 1 Select: off[3:2] */
	localparam S1_LEAF_CNT = (S1_OUT_BYTES + 1) / 2;
	localparam S1_MID_CNT  = (S1_LEAF_CNT + 7) / 8;
	wire [1:0] s1_sel [0:S1_LEAF_CNT-1];

`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) wire [1:0] s1_mid [0:S1_MID_CNT-1];
	genvar sm1, sl1, b1;
	generate
		for (b1 = 0; b1 < 2; b1 = b1 + 1) begin : g_s1_bit
			for (sm1 = 0; sm1 < S1_MID_CNT; sm1 = sm1 + 1) begin : g_s1_mid
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_m1 (.I0(off[2 + b1]), .O(s1_mid[sm1][b1]));
			end
			for (sl1 = 0; sl1 < S1_LEAF_CNT; sl1 = sl1 + 1) begin : g_s1_leaf
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_l1 (.I0(s1_mid[sl1 / 8][b1]), .O(s1_sel[sl1][b1]));
			end
		end
	endgenerate
`else
	genvar sl1_gen;
	generate
		for (sl1_gen = 0; sl1_gen < S1_LEAF_CNT; sl1_gen = sl1_gen + 1) begin : g_s1_leaf_sim
			assign s1_sel[sl1_gen] = off[3:2];
		end
	endgenerate
`endif

	/* Stage 2 Select: off[5:4] (or {1'b0, off[4]} for 32B) */
	localparam S2_LEAF_CNT = (S2_OUT_BYTES + 1) / 2;
	localparam S2_MID_CNT  = (S2_LEAF_CNT + 7) / 8;
	wire [1:0] s2_sel [0:S2_LEAF_CNT-1];

`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) wire [1:0] s2_mid [0:S2_MID_CNT-1];
	genvar sm2, sl2, b2;
	generate
		for (b2 = 0; b2 < 2; b2 = b2 + 1) begin : g_s2_bit
			wire in_s2_bit;
			if (LINE_BYTES >= 64) begin : g_s2_in_64
				assign in_s2_bit = (b2 == 1) ? off[5] : off[4];
			end else begin : g_s2_in_32
				assign in_s2_bit = (b2 == 1) ? 1'b0 : off[4];
			end
			for (sm2 = 0; sm2 < S2_MID_CNT; sm2 = sm2 + 1) begin : g_s2_mid
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_m2 (.I0(in_s2_bit), .O(s2_mid[sm2][b2]));
			end
			for (sl2 = 0; sl2 < S2_LEAF_CNT; sl2 = sl2 + 1) begin : g_s2_leaf
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_l2 (.I0(s2_mid[sl2 / 8][b2]), .O(s2_sel[sl2][b2]));
			end
		end
	endgenerate
`else
	genvar sl2_gen;
	generate
		if (LINE_BYTES >= 64) begin : g_s2_sel_64
			for (sl2_gen = 0; sl2_gen < S2_LEAF_CNT; sl2_gen = sl2_gen + 1) begin : g_s2_leaf_sim
				assign s2_sel[sl2_gen] = off[5:4];
			end
		end else begin : g_s2_sel_32
			for (sl2_gen = 0; sl2_gen < S2_LEAF_CNT; sl2_gen = sl2_gen + 1) begin : g_s2_leaf_sim
				assign s2_sel[sl2_gen] = {1'b0, off[4]};
			end
		end
	endgenerate
`endif

	/*
	 * =========================================================================
	 * Stage 0: 4-to-1 Multiplexers (Shift by 0, 1, 2, or 3 bytes)
	 * =========================================================================
	 */
	wire [7:0] st0_b [0:S0_OUT_BYTES-1];
	genvar i0;
	generate
		for (i0 = 0; i0 < S0_OUT_BYTES; i0 = i0 + 1) begin : g_stage0
			wire [1:0] sel0 = s0_sel[i0 / 2];
			assign st0_b[i0] = (sel0 == 2'd3) ? in_b[i0 + 3] :
			                   (sel0 == 2'd2) ? in_b[i0 + 2] :
			                   (sel0 == 2'd1) ? in_b[i0 + 1] : in_b[i0];
		end
	endgenerate

	/*
	 * =========================================================================
	 * Stage 1: 4-to-1 Multiplexers (Shift by 0, 4, 8, or 12 bytes)
	 * =========================================================================
	 */
	wire [7:0] st1_b [0:S1_OUT_BYTES-1];
	genvar i1;
	generate
		for (i1 = 0; i1 < S1_OUT_BYTES; i1 = i1 + 1) begin : g_stage1
			wire [1:0] sel1 = s1_sel[i1 / 2];
			assign st1_b[i1] = (sel1 == 2'd3) ? st0_b[i1 + 12] :
			                   (sel1 == 2'd2) ? st0_b[i1 + 8]  :
			                   (sel1 == 2'd1) ? st0_b[i1 + 4]  : st0_b[i1];
		end
	endgenerate

	/*
	 * =========================================================================
	 * Stage 2: 4-to-1 Multiplexers (Shift by 0, 16, 32, or 48 bytes)
	 * =========================================================================
	 */
	wire [7:0] st2_b [0:S2_OUT_BYTES-1];
	genvar i2;
	generate
		for (i2 = 0; i2 < S2_OUT_BYTES; i2 = i2 + 1) begin : g_stage2
			wire [1:0] sel2 = s2_sel[i2 / 2];
			if (LINE_BYTES >= 64) begin : g_s2_64
				assign st2_b[i2] = (sel2 == 2'd3) ? st1_b[i2 + 48] :
				                   (sel2 == 2'd2) ? st1_b[i2 + 32] :
				                   (sel2 == 2'd1) ? st1_b[i2 + 16] : st1_b[i2];
			end else begin : g_s2_32
				assign st2_b[i2] = sel2[0] ? st1_b[i2 + 16] : st1_b[i2];
			end
		end
	endgenerate

	/* Pack stage 2 outputs into out_data */
	genvar pk;
	generate
		for (pk = 0; pk < LINE_BYTES; pk = pk + 1) begin : g_out_pack
			assign out_data[pk*8 +: 8] = st2_b[pk];
		end
	endgenerate

endmodule
`default_nettype wire
