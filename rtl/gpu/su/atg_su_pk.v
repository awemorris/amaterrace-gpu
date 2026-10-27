/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_pk: The 16-bit packed unit:
 * fadd2/fsub2/fmul2/ffma2/fmin2/fmax2/fcmp2, iadd2/isub2/imul2, swaph, and
 * the always-present packh/unpackh. Short pipeline.
 *
 * Takes every group of a uop whose unit is PK (x_ready is 1 but in the
 * busy cycle of PK_SHARED) and
 * presents the result SHORT_LAT cycles later, like atg_su_alu.  packh
 * (two fp32 -> fp16 halves, RNE: rs1 low, rs2 high), unpackh (sub 0 low,
 * 1 high half -> fp32) and swaph are always present; with PACKED the
 * per-half fp16 arithmetic (atg_su_pk_half: one rounding under rm,
 * flushed, canonical NaN 0x7E00), the 16-bit integer add/sub/mul and the
 * Boolean half compares (0xFFFF/0; ge is the swapped le).  hsel 00 both
 * halves, 01 the low half only (the high half from rs1), 10 the high half
 * only (the low half from rs1), 11 rs2's halves swapped, both.  sat clamps
 * the float halves to [0, 1].  With PACKED = 0 atg_su_dec faults the
 * arithmetic, and this unit returns 0 for it.  Reference: tools/gsi1fp.py.
 * PK_SHARED (with PACKED): the fp16 operations (fadd2 to fmax2 and the
 * compares) are atg_su_fpu's, a half a cycle on its fp32 datapath; this
 * unit does not take them, and its x_ready is 0 in the cycle after one is
 * taken (atg_su_fpu's busy cycle; the same rule as atg_su_fpu's).
*/

`timescale 1ns / 1ps
`default_nettype none

module atg_su_pk #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter PACKED = 0,	/* Packed arithmetic present (0: only packh/unpackh/swaph) */
	parameter SHORT_LAT = 6,	/* Cycles from x_valid to the short result (one fixed pipeline for classes a and f, design §3.1.1) */
	parameter PK_SHARED = 0	/* With PACKED: the fp16 operations on atg_su_fpu (above) */
) (
	input wire clk,
	input wire rst_n,
	/* Issued instruction, one lane group per cycle (from atg_su_opd, shared by all units) */
	input wire x_valid,
	input wire [WARP_W-1:0] x_warp,
	input wire [GRP_W-1:0] x_grp,
	input wire x_last,
	input wire [SBE_W:0] x_sbe,
	input wire [15:0] x_pc,
	input wire [UOP_W-1:0] x_uop,
	input wire [NPHYS*32-1:0] x_a,
	input wire [NPHYS*32-1:0] x_b,
	input wire [NPHYS*32-1:0] x_c,
	input wire [2*NPHYS-1:0] x_mask,
	input wire [31:0] x_info,
	output wire x_ready,
	/* Short result to atg_su_wb (exactly SHORT_LAT cycles after x_valid) */
	output wire s_valid,
	output wire [WARP_W-1:0] s_warp,
	output wire [GRP_W-1:0] s_grp,
	output wire [6:0] s_rd,
	output wire [NPHYS*32-1:0] s_data,
	output wire [NPHYS-1:0] s_lanes
);
`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	localparam EW = 1 + WARP_W + GRP_W + 7 + NPHYS + DW;

	localparam SH = PK_SHARED != 0 && PACKED != 0;

	wire [3:0] op = x_uop[ATG_UOP_OP +: 4];
	/* PK_SHARED: an fp16 operation goes to atg_su_fpu; busy is the cycle
	 * after it is taken (as atg_su_fpu's). */
	wire pk_fp = op <= ATG_PK_FMAX2[3:0] || (op >= ATG_PK_FCMPLT2[3:0] && op <= ATG_PK_FCMPNE2[3:0]);
	reg busy;
	wire grp = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_PK && x_uop[ATG_UOP_WRD] && !busy;
	wire mine = grp && !(SH && pk_fp);
	always @(posedge clk)
		if (!rst_n)
			busy <= 1'b0;
		else
			busy <= SH && grp && pk_fp;
	wire [2:0] rm = x_uop[ATG_UOP_RM +: 3];
	wire [1:0] hsel = x_uop[ATG_UOP_HSEL +: 2];
	wire sub = x_uop[ATG_UOP_SUB];
	wire sat = x_uop[ATG_UOP_MOD + 6];

	/*
	 * One lane: two atg_su_pk_half (each with its fused fp16 datapath,
	 * compares and 16-bit integer arithmetic, and packh's fp32 -> fp16 of
	 * one source: rs1 low, rs2 high) and unpackh's fp16 -> fp32
	 * (am_fp_h2f).  y is 0 but for this unit's groups.
	 */
	wire [DW-1:0] y;
	genvar l;
	generate
	for (l = 0; l < NPHYS; l = l + 1) begin : g_lane
		wire [31:0] la = x_a[l*32 +: 32];
		wire [31:0] lb0 = x_b[l*32 +: 32];
		wire [31:0] lc = x_c[l*32 +: 32];
		wire [31:0] lb = hsel == 2'd3 ? {lb0[15:0], lb0[31:16]} : lb0;
		wire [15:0] lo, hi;
		wire [31:0] un;
		atg_su_pk_half #(.ARITH(PACKED), .FP(!SH)) u_lo (
			.o(op), .ha(la[15:0]), .hb(lb[15:0]), .hc(lc[15:0]), .r(rm), .sat(sat), .xw(la),
			.y(lo)
		);
		atg_su_pk_half #(.ARITH(PACKED), .FP(!SH)) u_hi (
			.o(op), .ha(la[31:16]), .hb(lb[31:16]), .hc(lc[31:16]), .r(rm), .sat(sat), .xw(lb0),
			.y(hi)
		);
		am_fp_h2f #(.DENORM(0), .LAT(0)) u_un (.h(sub ? la[31:16] : la[15:0]), .f(un));
		wire [31:0] v = op == ATG_PK_PACKH[3:0] ? {hi, lo} : op == ATG_PK_UNPACKH[3:0] ? un :
			op == ATG_PK_SWAPH[3:0] ? {la[15:0], la[31:16]} :
			PACKED != 0 ? {hsel == 2'd1 ? la[31:16] : hi, hsel == 2'd2 ? la[15:0] : lo} :
			32'd0;
		assign y[l*32 +: 32] = mine ? v : 32'd0;
	end
	endgenerate

	/* SHORT_LAT stages; stage 0 is registered from x_*. */
	reg [EW-1:0] pipe [0:SHORT_LAT-1];
	integer k;
	always @(posedge clk) begin
		if (!rst_n) begin
			for (k = 0; k < SHORT_LAT; k = k + 1)
				pipe[k] <= {EW{1'b0}};
		end else begin
			pipe[0] <= {mine, x_warp, x_grp, x_uop[ATG_UOP_RD +: 7], x_mask[NPHYS-1:0], y};
			for (k = 1; k < SHORT_LAT; k = k + 1)
				pipe[k] <= pipe[k-1];
		end
	end

	wire [EW-1:0] o = pipe[SHORT_LAT-1];
	assign s_valid = o[EW-1];
	assign s_warp = o[EW-2 -: WARP_W];
	assign s_grp = o[EW-2-WARP_W -: GRP_W];
	assign s_rd = o[EW-2-WARP_W-GRP_W -: 7];
	assign s_lanes = o[DW +: NPHYS];
	assign s_data = o[DW-1:0];
	assign x_ready = !busy;

	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_mask[2*NPHYS-1:NPHYS], x_info, x_uop,
		(NWARPS != 0)};
endmodule

`default_nettype wire
