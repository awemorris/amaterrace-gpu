/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fpu: The fp32 unit of the SU, NPHYS lanes: fadd/fsub/fmul/fmadd
 * family (FMA on DSPs), fmin/fmax, fsgnj, fround, fcvt, feq/flt/fle/fne
 * (Boolean), fract, sat; also the integer mul* (DSP). Short pipeline.
 *
 * Takes every group of a uop whose unit is FPU (x_ready is always 1) and
 * presents its result on s_* exactly SHORT_LAT cycles after x_valid, in
 * order, like atg_su_alu.  IEEE binary32 with the rules of design §3.1:
 * one rounding under the uop's rm (0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM,
 * 7 = RNE), denormals flushed on input and output, canonical NaN
 * 0x7FC00000.  fadd/fsub/fmul and the fmadd family share one fused
 * datapath (atg_su_ffma of include/atg_su_fp.vh); fract = x - floor(x)
 * through the same datapath (RNE); compares write Boolean (all ones/0);
 * the sat bit clamps float results to [0, 1].  mul* are the integer
 * multiplies of RISC-V M.  The reference is tools/gsi1fp.py.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_fpu #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter SHORT_LAT = 6	/* Cycles from x_valid to the short result (one fixed pipeline for classes a and f, design §3.1.1) */
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

	localparam DW = NPHYS * 32;
	localparam EW = 1 + WARP_W + GRP_W + 7 + NPHYS + DW;

	wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_FPU && x_uop[ATG_UOP_WRD];
	wire [4:0] op = x_uop[ATG_UOP_OP +: 5];
	wire [2:0] rm = x_uop[ATG_UOP_RM +: 3];
	wire sat = x_uop[ATG_UOP_MOD + 6];

	/* One lane. */
	function [31:0] fpu;
		input [4:0] o;
		input [31:0] a, b, c;
		input [2:0] r;
		input st;
		reg [31:0] x, y, z, fl, res;
		reg [2:0] rr;
		reg noc, fma, flt;
		reg [63:0] pr;
		begin
			/* The fused datapath's operands. */
			x = a;
			y = 32'h3F800000;
			z = b;
			noc = 1'b0;
			rr = r;
			fl = atg_su_fround(a, o == ATG_FPU_FRACT[4:0] ? 3'd2 : r);
			case (o)
			ATG_FPU_FSUB[4:0]: z = {!b[31], b[30:0]};
			ATG_FPU_FMUL[4:0]: begin
				y = b;
				noc = 1'b1;
			end
			ATG_FPU_FMADD[4:0]: begin
				y = b;
				z = c;
			end
			ATG_FPU_FMSUB[4:0]: begin
				y = b;
				z = {!c[31], c[30:0]};
			end
			ATG_FPU_FNMSUB[4:0]: begin
				x = {!a[31], a[30:0]};
				y = b;
				z = c;
			end
			ATG_FPU_FNMADD[4:0]: begin
				x = {!a[31], a[30:0]};
				y = b;
				z = {!c[31], c[30:0]};
			end
			ATG_FPU_FRACT[4:0]: begin
				z = {!fl[31], fl[30:0]};
				rr = 3'd0;
			end
			default: ;
			endcase
			fma = o <= ATG_FPU_FNMADD[4:0] || o == ATG_FPU_FRACT[4:0];
			flt = 1'b1;
			res = 32'd0;
			pr = 64'd0;
			if (fma)
				res = atg_su_ffma(x, y, z, rr, noc);
			else begin
				case (o)
				ATG_FPU_FSGNJ[4:0]: res = {b[31], a[30:0]};
				ATG_FPU_FMIN[4:0]: res = atg_su_fminmax(a, b, 1'b0);
				ATG_FPU_FMAX[4:0]: res = atg_su_fminmax(a, b, 1'b1);
				ATG_FPU_FCVTWS[4:0]: res = atg_su_f2i(a, r, 1'b0);
				ATG_FPU_FCVTWUS[4:0]: res = atg_su_f2i(a, r, 1'b1);
				ATG_FPU_FCVTSW[4:0]: res = atg_su_i2f(a[31], a[31] ? 32'd0 - a : a, r);
				ATG_FPU_FCVTSWU[4:0]: res = atg_su_i2f(1'b0, a, r);
				ATG_FPU_FEQ[4:0]: res = {32{atg_su_fcmp(a, b, 2'd0)}};
				ATG_FPU_FLT[4:0]: res = {32{atg_su_fcmp(a, b, 2'd1)}};
				ATG_FPU_FLE[4:0]: res = {32{atg_su_fcmp(a, b, 2'd2)}};
				ATG_FPU_FNE[4:0]: res = {32{atg_su_fcmp(a, b, 2'd3)}};
				ATG_FPU_FROUND[4:0]: res = fl;
				ATG_FPU_MUL[4:0]: begin
					pr = {{32{a[31]}}, a} * {{32{b[31]}}, b};
					res = pr[31:0];
				end
				ATG_FPU_MULH[4:0]: begin
					pr = {{32{a[31]}}, a} * {{32{b[31]}}, b};
					res = pr[63:32];
				end
				ATG_FPU_MULHSU[4:0]: begin
					pr = {{32{a[31]}}, a} * {32'd0, b};
					res = pr[63:32];
				end
				ATG_FPU_MULHU[4:0]: begin
					pr = {32'd0, a} * {32'd0, b};
					res = pr[63:32];
				end
				default: ;
				endcase
			end
			case (o)
			ATG_FPU_FCVTWS[4:0], ATG_FPU_FCVTWUS[4:0], ATG_FPU_FEQ[4:0], ATG_FPU_FLT[4:0],
			ATG_FPU_FLE[4:0], ATG_FPU_FNE[4:0], ATG_FPU_MUL[4:0], ATG_FPU_MULH[4:0],
			ATG_FPU_MULHSU[4:0], ATG_FPU_MULHU[4:0]: flt = 1'b0;
			default: ;
			endcase
			fpu = st && flt ? atg_su_sat(res) : res;
		end
	endfunction

	reg [DW-1:0] y;
	integer l;
	always @(*) begin
		for (l = 0; l < NPHYS; l = l + 1)
			y[l*32 +: 32] = fpu(op, x_a[l*32 +: 32], x_b[l*32 +: 32], x_c[l*32 +: 32], rm, sat);
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
	assign x_ready = 1'b1;

	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_mask[2*NPHYS-1:NPHYS], x_info, x_uop,
		(NWARPS != 0)};
endmodule

`default_nettype wire
