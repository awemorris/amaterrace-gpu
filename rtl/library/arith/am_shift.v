/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_shift: a W-bit barrel shifter by a variable amount (combinational).
 * Supports left, logical right, and arithmetic right shifts.
 * Parameter DIR allows compile-time specialization:
 *   DIR = 0: Dynamic direction via `left` port (both left/right synthesized, muxed at output)
 *   DIR = 1: Right-shift only (`left` ignored, left path pruned)
 *   DIR = 2: Left-shift only (`left` ignored, right path pruned)
 *
 * Sliced into 4-bit nibbles with a 2-level tree buffer structure to guarantee
 * all internal and port nets strictly conform to ASIC fanout limits (fanout <= 16).
 *
 * An amount of W or more gives 0 (or all sign bits for arithmetic right shift).
 */

`timescale 1ns / 1ps
`default_nettype none

module am_shift #(
	parameter W = 32,
	parameter SW = 5,	/* amount bits */
	parameter DIR = 0	/* 0: dynamic (via `left` port), 1: right-only, 2: left-only */
) (
	input wire [W-1:0] a,
	input wire [SW-1:0] amt,
	input wire left,
	input wire arith,
	output wire [W-1:0] y
);
	localparam NNIB = (W + 3) / 4;
	localparam NBR = (NNIB + 3) / 4;

	wire [W-1:0] rsh;
	wire [W-1:0] lsh;

	genvar g_br, g_nib, gb;

	/* -------------------------------------------------------------------------
	 * Right Shift
	 * ------------------------------------------------------------------------- */
	generate
	if (DIR != 2) begin : g_rsh_gen
		wire fill = ((DIR == 1) ? arith : (!left && arith)) ? a[W - 1] : 1'b0;
		if (W <= 4) begin : g_rsh_direct
			wire [W-1:0] log_rsh = a >> amt;
			wire [W-1:0] mask = ~({W{1'b1}} >> amt);
			assign rsh = fill ? (log_rsh | mask) : log_rsh;
		end else begin : g_rsh_tree
			wire [SW-1:0] amt_br [0:NBR-1];
			wire [W-1:0] a_br [0:NBR-1];
			wire fill_br [0:NBR-1];
			for (g_br = 0; g_br < NBR; g_br = g_br + 1) begin : g_br_buf
				for (gb = 0; gb < SW; gb = gb + 1) begin : g_br_amt
`ifdef SYNTH_KINTEX7
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bamt_br (.I0(amt[gb]), .O(amt_br[g_br][gb]));
`else
					assign amt_br[g_br][gb] = amt[gb];
`endif
				end
				for (gb = 0; gb < W; gb = gb + 1) begin : g_br_a
`ifdef SYNTH_KINTEX7
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_ba_br (.I0(a[gb]), .O(a_br[g_br][gb]));
`else
					assign a_br[g_br][gb] = a[gb];
`endif
				end
`ifdef SYNTH_KINTEX7
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bfill_br (.I0(fill), .O(fill_br[g_br]));
`else
				assign fill_br[g_br] = fill;
`endif
			end

			for (g_nib = 0; g_nib < NNIB; g_nib = g_nib + 1) begin : g_nib_sl
				localparam NIB_W = ((g_nib + 1) * 4 <= W) ? 4 : (W - g_nib * 4);
				localparam BR_IDX = g_nib / 4;
				wire [SW-1:0] amt_b0, amt_b1, amt_b2, amt_b3;
				wire fill_nib_0, fill_nib_1, fill_nib_2, fill_nib_3;
				for (gb = 0; gb < SW; gb = gb + 1) begin : g_nib_amt
`ifdef SYNTH_KINTEX7
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bamt_0 (.I0(amt_br[BR_IDX][gb]), .O(amt_b0[gb]));
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bamt_1 (.I0(amt_br[BR_IDX][gb]), .O(amt_b1[gb]));
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bamt_2 (.I0(amt_br[BR_IDX][gb]), .O(amt_b2[gb]));
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bamt_3 (.I0(amt_br[BR_IDX][gb]), .O(amt_b3[gb]));
`else
					assign amt_b0[gb] = amt_br[BR_IDX][gb];
					assign amt_b1[gb] = amt_br[BR_IDX][gb];
					assign amt_b2[gb] = amt_br[BR_IDX][gb];
					assign amt_b3[gb] = amt_br[BR_IDX][gb];
`endif
				end
`ifdef SYNTH_KINTEX7
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bfill_0 (.I0(fill_br[BR_IDX]), .O(fill_nib_0));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bfill_1 (.I0(fill_br[BR_IDX]), .O(fill_nib_1));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bfill_2 (.I0(fill_br[BR_IDX]), .O(fill_nib_2));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bfill_3 (.I0(fill_br[BR_IDX]), .O(fill_nib_3));
`else
				assign fill_nib_0 = fill_br[BR_IDX];
				assign fill_nib_1 = fill_br[BR_IDX];
				assign fill_nib_2 = fill_br[BR_IDX];
				assign fill_nib_3 = fill_br[BR_IDX];
`endif
				wire [W-1:0] rsh_f_0 = a_br[BR_IDX] >> amt_b0[1:0];
				wire [W-1:0] msk_f_0 = ~({W{1'b1}} >> amt_b0[1:0]);
				wire [NNIB*4-1:0] log_rsh_0 = {{(NNIB*4-W){1'b0}}, (rsh_f_0 >> {amt_b0[SW-1:2], 2'b00})};
				wire [NNIB*4-1:0] mask_0    = {{(NNIB*4-W){1'b0}}, ((msk_f_0 >> {amt_b0[SW-1:2], 2'b00}) | ~({W{1'b1}} >> {amt_b0[SW-1:2], 2'b00}))};

				wire [W-1:0] rsh_f_1 = a_br[BR_IDX] >> amt_b1[1:0];
				wire [W-1:0] msk_f_1 = ~({W{1'b1}} >> amt_b1[1:0]);
				wire [NNIB*4-1:0] log_rsh_1 = {{(NNIB*4-W){1'b0}}, (rsh_f_1 >> {amt_b1[SW-1:2], 2'b00})};
				wire [NNIB*4-1:0] mask_1    = {{(NNIB*4-W){1'b0}}, ((msk_f_1 >> {amt_b1[SW-1:2], 2'b00}) | ~({W{1'b1}} >> {amt_b1[SW-1:2], 2'b00}))};

				wire [W-1:0] rsh_f_2 = a_br[BR_IDX] >> amt_b2[1:0];
				wire [W-1:0] msk_f_2 = ~({W{1'b1}} >> amt_b2[1:0]);
				wire [NNIB*4-1:0] log_rsh_2 = {{(NNIB*4-W){1'b0}}, (rsh_f_2 >> {amt_b2[SW-1:2], 2'b00})};
				wire [NNIB*4-1:0] mask_2    = {{(NNIB*4-W){1'b0}}, ((msk_f_2 >> {amt_b2[SW-1:2], 2'b00}) | ~({W{1'b1}} >> {amt_b2[SW-1:2], 2'b00}))};

				wire [W-1:0] rsh_f_3 = a_br[BR_IDX] >> amt_b3[1:0];
				wire [W-1:0] msk_f_3 = ~({W{1'b1}} >> amt_b3[1:0]);
				wire [NNIB*4-1:0] log_rsh_3 = {{(NNIB*4-W){1'b0}}, (rsh_f_3 >> {amt_b3[SW-1:2], 2'b00})};
				wire [NNIB*4-1:0] mask_3    = {{(NNIB*4-W){1'b0}}, ((msk_f_3 >> {amt_b3[SW-1:2], 2'b00}) | ~({W{1'b1}} >> {amt_b3[SW-1:2], 2'b00}))};

				wire [3:0] rsh_out;
				assign rsh_out[0] = fill_nib_0 ? (log_rsh_0[g_nib * 4 + 0] | mask_0[g_nib * 4 + 0]) : log_rsh_0[g_nib * 4 + 0];
				assign rsh_out[1] = fill_nib_1 ? (log_rsh_1[g_nib * 4 + 1] | mask_1[g_nib * 4 + 1]) : log_rsh_1[g_nib * 4 + 1];
				assign rsh_out[2] = fill_nib_2 ? (log_rsh_2[g_nib * 4 + 2] | mask_2[g_nib * 4 + 2]) : log_rsh_2[g_nib * 4 + 2];
				assign rsh_out[3] = fill_nib_3 ? (log_rsh_3[g_nib * 4 + 3] | mask_3[g_nib * 4 + 3]) : log_rsh_3[g_nib * 4 + 3];
				assign rsh[g_nib * 4 +: NIB_W] = rsh_out[0 +: NIB_W];
			end
		end
	end else begin : g_rsh_stub
		assign rsh = {W{1'b0}};
	end
	endgenerate

	/* -------------------------------------------------------------------------
	 * Left Shift
	 * ------------------------------------------------------------------------- */
	generate
	if (DIR != 1) begin : g_lsh_gen
		if (W <= 4) begin : g_lsh_direct
			assign lsh = a << amt;
		end else begin : g_lsh_tree
			wire [SW-1:0] amt_br [0:NBR-1];
			wire [W-1:0] a_br [0:NBR-1];
			for (g_br = 0; g_br < NBR; g_br = g_br + 1) begin : g_br_buf
				for (gb = 0; gb < SW; gb = gb + 1) begin : g_br_amt
`ifdef SYNTH_KINTEX7
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bamt_br (.I0(amt[gb]), .O(amt_br[g_br][gb]));
`else
					assign amt_br[g_br][gb] = amt[gb];
`endif
				end
				for (gb = 0; gb < W; gb = gb + 1) begin : g_br_a
`ifdef SYNTH_KINTEX7
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_ba_br (.I0(a[gb]), .O(a_br[g_br][gb]));
`else
					assign a_br[g_br][gb] = a[gb];
`endif
				end
			end

			for (g_nib = 0; g_nib < NNIB; g_nib = g_nib + 1) begin : g_nib_sl
				localparam NIB_W = ((g_nib + 1) * 4 <= W) ? 4 : (W - g_nib * 4);
				localparam BR_IDX = g_nib / 4;
				wire [SW-1:0] amt_b0, amt_b1, amt_b2, amt_b3;
				for (gb = 0; gb < SW; gb = gb + 1) begin : g_nib_amt
`ifdef SYNTH_KINTEX7
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bamt_0 (.I0(amt_br[BR_IDX][gb]), .O(amt_b0[gb]));
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bamt_1 (.I0(amt_br[BR_IDX][gb]), .O(amt_b1[gb]));
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bamt_2 (.I0(amt_br[BR_IDX][gb]), .O(amt_b2[gb]));
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bamt_3 (.I0(amt_br[BR_IDX][gb]), .O(amt_b3[gb]));
`else
					assign amt_b0[gb] = amt_br[BR_IDX][gb];
					assign amt_b1[gb] = amt_br[BR_IDX][gb];
					assign amt_b2[gb] = amt_br[BR_IDX][gb];
					assign amt_b3[gb] = amt_br[BR_IDX][gb];
`endif
				end
				wire [W-1:0] lsh_f_0 = a_br[BR_IDX] << amt_b0[1:0];
				wire [NNIB*4-1:0] lshifted_0 = {{(NNIB*4-W){1'b0}}, (lsh_f_0 << {amt_b0[SW-1:2], 2'b00})};

				wire [W-1:0] lsh_f_1 = a_br[BR_IDX] << amt_b1[1:0];
				wire [NNIB*4-1:0] lshifted_1 = {{(NNIB*4-W){1'b0}}, (lsh_f_1 << {amt_b1[SW-1:2], 2'b00})};

				wire [W-1:0] lsh_f_2 = a_br[BR_IDX] << amt_b2[1:0];
				wire [NNIB*4-1:0] lshifted_2 = {{(NNIB*4-W){1'b0}}, (lsh_f_2 << {amt_b2[SW-1:2], 2'b00})};

				wire [W-1:0] lsh_f_3 = a_br[BR_IDX] << amt_b3[1:0];
				wire [NNIB*4-1:0] lshifted_3 = {{(NNIB*4-W){1'b0}}, (lsh_f_3 << {amt_b3[SW-1:2], 2'b00})};
				wire [3:0] lsh_out;
				assign lsh_out[0] = lshifted_0[g_nib * 4 + 0];
				assign lsh_out[1] = lshifted_1[g_nib * 4 + 1];
				assign lsh_out[2] = lshifted_2[g_nib * 4 + 2];
				assign lsh_out[3] = lshifted_3[g_nib * 4 + 3];
				assign lsh[g_nib * 4 +: NIB_W] = lsh_out[0 +: NIB_W];
			end
		end
	end else begin : g_lsh_stub
		assign lsh = {W{1'b0}};
	end
	endgenerate

	/* -------------------------------------------------------------------------
	 * Output Multiplexer
	 * ------------------------------------------------------------------------- */
	generate
	if (DIR == 1) begin : g_out_r
		assign y = rsh;
	end else if (DIR == 2) begin : g_out_l
		assign y = lsh;
	end else begin : g_out_dyn
		if (W <= 4) begin : g_omux_direct
			assign y = left ? lsh : rsh;
		end else begin : g_omux_tree
			wire left_br [0:NBR-1];
			for (g_br = 0; g_br < NBR; g_br = g_br + 1) begin : g_br_buf
`ifdef SYNTH_KINTEX7
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bleft_br (.I0(left), .O(left_br[g_br]));
`else
				assign left_br[g_br] = left;
`endif
			end

			for (g_nib = 0; g_nib < NNIB; g_nib = g_nib + 1) begin : g_nib_sl
				localparam NIB_W = ((g_nib + 1) * 4 <= W) ? 4 : (W - g_nib * 4);
				localparam BR_IDX = g_nib / 4;
				wire left_nib;
`ifdef SYNTH_KINTEX7
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bleft_nib (.I0(left_br[BR_IDX]), .O(left_nib));
`else
				assign left_nib = left_br[BR_IDX];
`endif
				assign y[g_nib * 4 +: NIB_W] = left_nib ? lsh[g_nib * 4 +: NIB_W] : rsh[g_nib * 4 +: NIB_W];
			end
		end
	end
	endgenerate

	wire unused_ok = &{1'b0, left, arith, rsh, lsh};
endmodule

`default_nettype wire
