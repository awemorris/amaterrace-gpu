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
 * When W > 16, shift amount `amt` and select `left` are buffered per 16-bit slice
 * to guarantee all internal nets strictly conform to ASIC fanout limits (fanout <= 16).
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
	wire [W-1:0] rsh;
	wire [W-1:0] lsh;

	genvar g_chunk;
	generate
	if (DIR != 2) begin : g_rsh_gen
		wire fill = ((DIR == 1) ? arith : (!left && arith)) ? a[W - 1] : 1'b0;
		wire signed [W:0] ext_data = {fill, a};
		if (W <= 16) begin : g_rsh_direct
			wire signed [W:0] ext_shift = ext_data >>> amt;
			assign rsh = ext_shift[W-1:0];
		end else begin : g_rsh_sliced
			for (g_chunk = 0; g_chunk < (W + 15) / 16; g_chunk = g_chunk + 1) begin : g_sl
				localparam CHK_W = ((g_chunk + 1) * 16 <= W) ? 16 : (W - g_chunk * 16);
				wire [SW-1:0] amt_b;
				genvar gb;
				for (gb = 0; gb < SW; gb = gb + 1) begin : g_amt_buf
`ifdef SYNTH_KINTEX7
					(* keep = "true" *) LUT1 #(.INIT(2'b10)) u_bamt (.I0(amt[gb]), .O(amt_b[gb]));
`else
					assign amt_b[gb] = amt[gb];
`endif
				end
				wire signed [W:0] ext_chunk = ext_data;
				wire signed [W:0] shifted_chunk = ext_chunk >>> amt_b;
				assign rsh[g_chunk * 16 +: CHK_W] = shifted_chunk[g_chunk * 16 +: CHK_W];
			end
		end
	end else begin : g_rsh_stub
		assign rsh = {W{1'b0}};
	end
	endgenerate

	generate
	if (DIR != 1) begin : g_lsh_gen
		if (W <= 16) begin : g_lsh_direct
			assign lsh = a << amt;
		end else begin : g_lsh_sliced
			for (g_chunk = 0; g_chunk < (W + 15) / 16; g_chunk = g_chunk + 1) begin : g_sl
				localparam CHK_W = ((g_chunk + 1) * 16 <= W) ? 16 : (W - g_chunk * 16);
				wire [SW-1:0] amt_b;
				genvar gb;
				for (gb = 0; gb < SW; gb = gb + 1) begin : g_amt_buf
`ifdef SYNTH_KINTEX7
					(* keep = "true" *) LUT1 #(.INIT(2'b10)) u_bamt (.I0(amt[gb]), .O(amt_b[gb]));
`else
					assign amt_b[gb] = amt[gb];
`endif
				end
				wire [W-1:0] lshifted_chunk = a << amt_b;
				assign lsh[g_chunk * 16 +: CHK_W] = lshifted_chunk[g_chunk * 16 +: CHK_W];
			end
		end
	end else begin : g_lsh_stub
		assign lsh = {W{1'b0}};
	end
	endgenerate

	generate
	if (DIR == 1) begin : g_out_r
		assign y = rsh;
	end else if (DIR == 2) begin : g_out_l
		assign y = lsh;
	end else begin : g_out_dyn
		if (W <= 16) begin : g_omux_direct
			assign y = left ? lsh : rsh;
		end else begin : g_omux_sliced
			genvar g_om;
			for (g_om = 0; g_om < (W + 15) / 16; g_om = g_om + 1) begin : g_sl
				localparam CHK_W = ((g_om + 1) * 16 <= W) ? 16 : (W - g_om * 16);
				wire left_b;
`ifdef SYNTH_KINTEX7
				(* keep = "true" *) LUT1 #(.INIT(2'b10)) u_bl (.I0(left), .O(left_b));
`else
				assign left_b = left;
`endif
				assign y[g_om * 16 +: CHK_W] = left_b ? lsh[g_om * 16 +: CHK_W] : rsh[g_om * 16 +: CHK_W];
			end
		end
	end
	endgenerate

	wire unused_ok = &{1'b0, left, arith, rsh, lsh};
endmodule

`default_nettype wire
