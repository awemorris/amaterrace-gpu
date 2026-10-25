/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_lds: Shared memory (LDS): lds/sts/atom (the shared form, atom sub[4])
 * per lane, LDS_BYTES of block RAM per SU (4 KiB by default, 16 KiB KC705),
 * word addressed; returns as long beats.
 *
 * One lane group at a time (x_ready is 1 only in IDLE).  The word
 * address of lane l is ((rs1 + imm) >> 2) mod LDS_BYTES/4 (atom: rs1, no
 * immediate).  The lanes go through the RAM's one port one per cycle
 * (lane 0 first; for sts a later lane wins on the same word): lds reads
 * the EXEC lanes (the read data is registered, one more cycle at the
 * end), sts writes the side-effect lanes; atom takes two cycles per
 * side-effect lane, the read and then the write of the new value
 * (docs/ghci.md section 12.5: sub[3:0] the operation, rs2 the operand, rs3
 * cmpxchg's compare value), so each lane's read-modify-write is whole
 * before the next lane's read: lanes on the same word act in lane order,
 * and as the unit takes one group at a time, every atom is indivisible
 * with respect to every other LDS access.  Then one beat: lds l_wr 1 with
 * the EXEC lanes, atom l_wr = the uop's WRD with the side-effect lanes
 * (the old values), sts l_wr 0; l_last = x_last, class m.  A group without
 * lanes returns at once.
 *
 * States: IDLE →(group)→ ACCESS (NPHYS cycles, atom 2 NPHYS) → DRAIN →
 * BEAT →(l_ready)→ IDLE.
*/

`timescale 1ns / 1ps
`default_nettype none

module atg_su_lds #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter LDS_BYTES = 4096	/* Size in bytes */
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
	/* Long result to atg_su_wb (any time; wb may refuse with l_ready = 0) */
	output wire l_valid,
	input wire l_ready,
	output wire [WARP_W-1:0] l_warp,
	output wire [GRP_W-1:0] l_grp,
	output wire [6:0] l_rd,
	output wire [NPHYS*32-1:0] l_data,
	output wire [NPHYS-1:0] l_lanes,
	output wire l_wr,
	output wire l_last,
	output wire [SBE_W:0] l_sbe,
	output wire [2:0] l_cls
);
`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	localparam NW = LDS_BYTES / 4;
	localparam AW = $clog2(NW);
	localparam LW = NPHYS > 1 ? $clog2(NPHYS) : 1;
	localparam [1:0] IDLE = 2'd0, ACCESS = 2'd1, DRAIN = 2'd2, BEAT = 2'd3;

	reg [31:0] ram [0:NW-1];
	reg [1:0] st;
	reg [NPHYS*AW-1:0] radr;
	reg [DW-1:0] rdat, rcmp, res;
	reg [NPHYS-1:0] lanes;
	reg rsts, ratom, rwrd, aph;
	reg [3:0] rsub;
	reg [6:0] rrd;
	reg [WARP_W-1:0] rwarp;
	reg [GRP_W-1:0] rgrp;
	reg rlast;
	reg [SBE_W:0] rsbe;
	reg [LW-1:0] li, pli;
	reg pval;
	reg [31:0] q;

	/* The new value of an atomic's word (the order of docs/ghci.md section 12.5). */
	function [31:0] atom_op;
		input [3:0] op;
		input [31:0] old, a, b;
		case (op)
		4'd0: atom_op = old & a;
		4'd1: atom_op = old | a;
		4'd2: atom_op = old ^ a;
		4'd3: atom_op = a;
		4'd4: atom_op = old + a;
		4'd5: atom_op = old - a;
		4'd6: atom_op = $signed(old) > $signed(a) ? old : a;
		4'd7: atom_op = $signed(old) < $signed(a) ? old : a;
		4'd8: atom_op = old > a ? old : a;
		4'd9: atom_op = old < a ? old : a;
		4'd10: atom_op = old == b ? a : old;
		default: atom_op = old;
		endcase
	endfunction

	wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_LDS;
	wire is_sts = x_uop[ATG_UOP_OP +: 8] == ATG_LDS_STS;
	wire is_atom = x_uop[ATG_UOP_OP +: 8] == ATG_LDS_ATOM;
	wire [NPHYS-1:0] xl = is_sts || is_atom ? x_mask[2*NPHYS-1:NPHYS] : x_mask[NPHYS-1:0];
	wire [31:0] imm = is_atom ? 32'd0 : x_uop[ATG_UOP_IMM +: 32];
	wire [AW-1:0] a = radr[li*AW +: AW];
	wire lane_on = lanes[li];
	/* An atom lane's second cycle: q holds the word read in the first. */
`ifdef MUT_LDS_ATOM_NOCMP
	wire [31:0] anew = atom_op(rsub, q, rdat[li*32 +: 32], rdat[li*32 +: 32]);
`else
	wire [31:0] anew = atom_op(rsub, q, rdat[li*32 +: 32], rcmp[li*32 +: 32]);
`endif
`ifdef MUT_LDS_ATOM_RAW
	wire aread = 1'b0;
`else
	wire aread = ratom && lane_on && !aph;
`endif
	assign x_ready = st == IDLE;

	/* The word addresses of the group on x_*. */
	reg [NPHYS*AW-1:0] xadr;
	reg [31:0] ba;
	integer l;
	always @(*)
		for (l = 0; l < NPHYS; l = l + 1) begin
			ba = x_a[l*32 +: 32] + imm;
			xadr[l*AW +: AW] = ba[AW+1:2];
		end

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
			li <= {LW{1'b0}};
			pval <= 1'b0;
			aph <= 1'b0;
		end else begin
			pval <= 1'b0;
			case (st)
			IDLE: if (mine) begin
				radr <= xadr;
				rdat <= x_b;
				rcmp <= x_c;
				lanes <= xl;
				rsts <= is_sts;
				ratom <= is_atom;
				rwrd <= x_uop[ATG_UOP_WRD];
				rsub <= x_uop[ATG_UOP_SUB +: 4];
				res <= {DW{1'b0}};
				rrd <= x_uop[ATG_UOP_RD +: 7];
				rwarp <= x_warp;
				rgrp <= x_grp;
				rlast <= x_last;
				rsbe <= x_sbe;
				li <= {LW{1'b0}};
				aph <= 1'b0;
				st <= xl == {NPHYS{1'b0}} ? BEAT : ACCESS;
			end
			ACCESS: if (aread) begin
				/* The read of an atom lane; the write is the next cycle. */
				aph <= 1'b1;
			end else begin
				if (lane_on && rsts)
					ram[a] <= rdat[li*32 +: 32];
				if (lane_on && ratom) begin
					ram[a] <= anew;
					res[li*32 +: 32] <= q;
				end
				aph <= 1'b0;
				pval <= lane_on && !rsts && !ratom;
				pli <= li;
				li <= li + 1'b1;
				if ({{(32-LW){1'b0}}, li} == NPHYS - 1)
					st <= DRAIN;
			end
			DRAIN: st <= BEAT;
			default: if (l_ready)
				st <= IDLE;
			endcase
			if (pval)
				res[pli*32 +: 32] <= q;
		end
	end

	/* The RAM's registered read. */
	always @(posedge clk)
		q <= ram[a];

	assign l_valid = st == BEAT;
	assign l_warp = rwarp;
	assign l_grp = rgrp;
	assign l_rd = rrd;
	assign l_data = res;
	assign l_lanes = lanes;
	assign l_wr = ratom ? rwrd : !rsts;
	assign l_last = rlast;
	assign l_sbe = rsbe;
	assign l_cls = ATG_CLS_M;

	wire unused_ok = &{1'b0, x_pc, x_info, x_uop, imm, ba, (NWARPS != 0)};
endmodule

`default_nettype wire
