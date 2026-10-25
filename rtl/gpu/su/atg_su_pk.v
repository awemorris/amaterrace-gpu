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
 * per-half fp16 arithmetic (include/atg_su_fp16.vh: one rounding under rm,
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
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
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
`include "atg_su_fp.vh"
`include "atg_su_fp16.vh"

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

	/* One half.  The float add/sub/mul/fma share one fused datapath and
	 * the compares one compare (ge is the swapped le), with the operands
	 * of each operation selected in front of it. */
	function [15:0] half;
		input [3:0] o;
		input [15:0] a, b, c;
		input [2:0] r;
		input st;
		reg [15:0] y, fy, fz, ca, cb;
		reg fnoc;
		reg [1:0] cop;
		begin
			fy = 16'h3C00;
			fz = b;
			fnoc = 1'b0;
			case (o)
			ATG_PK_FSUB2[3:0]: fz = {!b[15], b[14:0]};
			ATG_PK_FMUL2[3:0]: begin
				fy = b;
				fz = 16'd0;
				fnoc = 1'b1;
			end
			ATG_PK_FFMA2[3:0]: begin
				fy = b;
				fz = c;
			end
			default: ;
			endcase
			ca = a;
			cb = b;
			case (o)
			ATG_PK_FCMPLT2[3:0]: cop = 2'd1;
			ATG_PK_FCMPGE2[3:0]: begin
				ca = b;
				cb = a;
				cop = 2'd2;
			end
			ATG_PK_FCMPEQ2[3:0]: cop = 2'd0;
			default: cop = 2'd3;
			endcase
			/* (PK_SHARED: the fp16 operations are atg_su_fpu's) */
			case (o)
			ATG_PK_FADD2[3:0], ATG_PK_FSUB2[3:0], ATG_PK_FMUL2[3:0], ATG_PK_FFMA2[3:0]:
				y = SH ? 16'd0 : atg_su_hfma(a, fy, fz, r, fnoc);
			ATG_PK_FMIN2[3:0]: y = SH ? 16'd0 : atg_su_hminmax(a, b, 1'b0);
			ATG_PK_FMAX2[3:0]: y = SH ? 16'd0 : atg_su_hminmax(a, b, 1'b1);
			ATG_PK_IADD2[3:0]: y = a + b;
			ATG_PK_ISUB2[3:0]: y = a - b;
			ATG_PK_IMUL2[3:0]: y = a * b;
			ATG_PK_FCMPLT2[3:0], ATG_PK_FCMPGE2[3:0], ATG_PK_FCMPEQ2[3:0], ATG_PK_FCMPNE2[3:0]:
				y = SH ? 16'd0 : {16{atg_su_hcmp(ca, cb, cop)}};
			default: y = 16'd0;
			endcase
			half = st && o <= ATG_PK_FMAX2[3:0] ? atg_su_hsat(y) : y;
		end
	endfunction

	/* One lane. */
	function [31:0] lane;
		input [3:0] o;
		input [31:0] a, b0, c;
		input [2:0] r;
		input [1:0] hs;
		input sb, st;
		reg [31:0] b;
		reg [15:0] lo, hi;
		begin
			b = hs == 2'd3 ? {b0[15:0], b0[31:16]} : b0;
			if (o == ATG_PK_PACKH[3:0])
				lane = {atg_su_f2h(b0), atg_su_f2h(a)};
			else if (o == ATG_PK_UNPACKH[3:0])
				lane = atg_su_h2f(sb ? a[31:16] : a[15:0]);
			else if (o == ATG_PK_SWAPH[3:0])
				lane = {a[15:0], a[31:16]};
			else if (PACKED != 0) begin
				lo = half(o, a[15:0], b[15:0], c[15:0], r, st);
				hi = half(o, a[31:16], b[31:16], c[31:16], r, st);
				lane = {hs == 2'd1 ? a[31:16] : hi, hs == 2'd2 ? a[15:0] : lo};
			end else
				lane = 32'd0;
		end
	endfunction

	reg [DW-1:0] y;
	integer l;
	always @(*) begin
		y = {DW{1'b0}};
		if (mine)	/* (only for this unit's groups: fast simulation) */
			for (l = 0; l < NPHYS; l = l + 1)
				y[l*32 +: 32] = lane(op, x_a[l*32 +: 32], x_b[l*32 +: 32], x_c[l*32 +: 32], rm,
					hsel, sub, sat);
	end

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
