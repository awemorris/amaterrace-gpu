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
 * BEAT →(l_ready)→ IDLE.  scrub (session protection, the unit idle) writes
 * 0 to every word through the RAM's write port, one per cycle, while
 * scrub_busy.
*/

`timescale 1ns / 1ps
`default_nettype none

module atg_su_lds #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
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
	output wire [2:0] l_cls,
	/* Session protection: clear the contents */
	input wire scrub,
	output wire scrub_busy,
	/* Port B: Mesh Read Port */
	input wire mesh_rd_en,
	input wire [$clog2(LDS_BYTES/4)-1:0] mesh_rd_addr,
	output wire [31:0] mesh_rd_data
);
`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	localparam NW = LDS_BYTES / 4;
	localparam AW = $clog2(NW);
	localparam LW = NPHYS > 1 ? $clog2(NPHYS) : 1;
	localparam [2:0] IDLE = 3'd0, ACCESS = 3'd1, DRAIN1 = 3'd2, DRAIN2 = 3'd3,
		DRAIN3 = 3'd4, BEAT = 3'd5;

`ifdef SYNTH_KINTEX7
	(* ram_style = "block" *)
	/* synthesis syn_ramstyle = "block" */
`else
	(* ram_style = "block" *)
`endif
	reg [31:0] ram [0:NW-1];
	integer init_i;
	initial begin
		for (init_i = 0; init_i < NW; init_i = init_i + 1)
			ram[init_i] = 32'd0;
	end
	(* keep = "true" *) wire rst_p = !rst_n;
	(* max_fanout = 12 *) reg [2:0] st;
	wire [NPHYS*AW-1:0] radr;
	wire [DW-1:0] rdat, rcmp, res;
	(* max_fanout = 12 *) reg [NPHYS-1:0] lanes;
	(* max_fanout = 12 *) reg [31:0] atom_b, atom_c;
	(* max_fanout = 12 *) reg rsts, ratom, rwrd;
	(* max_fanout = 12 *) reg [2:0] aph;
	(* max_fanout = 12 *) reg [3:0] rsub;
	reg [6:0] rrd;
	reg [WARP_W-1:0] rwarp;
	reg [GRP_W-1:0] rgrp;
	reg rlast;
	reg [SBE_W:0] rsbe;
	(* shreg_extract = "no", max_fanout = 12 *) reg [LW-1:0] li, pli_1, pli_2, pli_3;
	(* shreg_extract = "no", max_fanout = 12 *) reg pval_1, pval_2, pval_3;
	reg [AW-1:0] ram_addr_r;
	(* max_fanout = 12 *) reg ram_we_r;
	reg [31:0] ram_wd_r;
	reg [31:0] q;
	(* dont_touch = "true" *) reg [31:0] q_pipe;

	/* The new value of an atomic's word (the order of docs/ghci.md section 12.5). */
	function [31:0] atom_op;
		input [3:0] op;
		input [31:0] old, a, b;
		case (op)
		4'd0: atom_op = old & a;
		4'd1: atom_op = old | a;
		4'd2: atom_op = old ^ a;
		4'd3: atom_op = a;
		4'd4, 4'd5: atom_op = old; /* Direct-pathed via asum */
		4'd6: atom_op = $signed(old) > $signed(a) ? old : a;
		4'd7: atom_op = $signed(old) < $signed(a) ? old : a;
		4'd8: atom_op = old > a ? old : a;
		4'd9: atom_op = old < a ? old : a;
		4'd10: atom_op = old == b ? a : old;
		default: atom_op = old;
		endcase
	endfunction

	(* max_fanout = 12 *) wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_LDS;
	(* max_fanout = 12 *) wire is_sts = x_uop[ATG_UOP_OP +: 8] == ATG_LDS_STS;
	(* max_fanout = 12 *) wire is_atom = x_uop[ATG_UOP_OP +: 8] == ATG_LDS_ATOM;
	wire [NPHYS-1:0] xl = is_sts || is_atom ? x_mask[2*NPHYS-1:NPHYS] : x_mask[NPHYS-1:0];
	(* max_fanout = 12 *) wire [31:0] imm = is_atom ? 32'd0 : x_uop[ATG_UOP_IMM +: 32];
	/* Lane li's word address (a selection: AW bits a lane). */
	(* max_fanout = 12 *) reg [AW-1:0] a;
	integer al;
	always @(*) begin
		a = radr[AW-1:0];
		for (al = 1; al < NPHYS; al = al + 1)
			if (li == al[LW-1:0])
				a = radr[al*AW +: AW];
	end
	(* max_fanout = 12 *) wire lane_on = lanes[li];
	/* An atom lane's read-modify-write uses q_pipe (dedicated fabric register after BRAM q). */
	wire [31:0] cur_rdat = rdat[li*32 +: 32];
	wire [31:0] asum;
	wire as_co_unused;
	am_addsub #(.W(32)) u_asum (.a(q_pipe), .b(atom_b), .sub(rsub == 4'd5), .s(asum),
		.co(as_co_unused));

	wire [31:0] anew_other;
`ifdef MUT_LDS_ATOM_NOCMP
	assign anew_other = atom_op(rsub, q_pipe, atom_b, atom_b);
`else
	assign anew_other = atom_op(rsub, q_pipe, atom_b, atom_c);
`endif

	wire is_addsub = (rsub == 4'd4 || rsub == 4'd5);
	(* keep = "true" *) wire [31:0] w_asum = asum;
	(* keep = "true" *) wire [31:0] w_other = anew_other;
	wire [31:0] w_atom = is_addsub ? w_asum : w_other;
`ifdef MUT_LDS_ATOM_RAW
	wire atom_active = 1'b0;
`else
	wire atom_active = ratom && lane_on;
`endif
	assign x_ready = st == IDLE && !ram_we_r;

	/* The word addresses of the group on x_*: (rs1 + imm) / 4, its low AW bits. */
	(* keep = "true", max_fanout = 12 *) wire lds_take_base = !scrub && !sc_on && (st == IDLE) && mine && !ram_we_r;
	(* keep = "true", max_fanout = 12 *) wire lds_atom_base = !scrub && !sc_on && (st == ACCESS) && ratom && (aph == 3'd3);
	wire [NPHYS*AW-1:0] xadr;
	genvar l, glh;
	generate
		for (l = 0; l < NPHYS; l = l + 1) begin : g_adr
			wire [AW+1:0] ba;
			wire co_unused;
			am_add #(.W(AW + 2)) u_ba (.a(x_a[l*32 +: AW + 2]), .b(imm[AW+1:0]), .ci(1'b0), .s(ba),
				.co(co_unused));
			assign xadr[l*AW +: AW] = ba[AW+1:2];
			wire unused_b = &{1'b0, ba[1:0]};

			(* keep = "true" *) wire lds_take_l = lds_take_base;
			(* shreg_extract = "no" *) reg [AW-1:0] radr_l_r;
			always @(posedge clk)
				if (lds_take_l)
					radr_l_r <= xadr[l*AW +: AW];
			assign radr[l*AW +: AW] = radr_l_r;

			for (glh = 0; glh < 2; glh = glh + 1) begin : g_lds_half
				(* keep = "true" *) wire lds_take_h = lds_take_base;
				wire lds_atom_we_h = lds_atom_base && lanes[l] && (li == l[LW-1:0]);
				wire lds_rd_we_h   = pval_3 && (pli_3 == l[LW-1:0]);
				(* keep = "true" *) wire lds_q_we_h = lds_rd_we_h || lds_atom_we_h;
				(* shreg_extract = "no" *) reg [15:0] rdat_h_r, rcmp_h_r, res_h_r;
				always @(posedge clk) begin
					if (lds_take_h) begin
						rdat_h_r <= x_b[l*32 + glh*16 +: 16];
						rcmp_h_r <= x_c[l*32 + glh*16 +: 16];
					end
					if (lds_q_we_h)
						res_h_r <= q_pipe[glh*16 +: 16];
					else if (lds_take_h)
						res_h_r <= 16'd0;
				end
				assign rdat[l*32 + glh*16 +: 16] = rdat_h_r;
				assign rcmp[l*32 + glh*16 +: 16] = rcmp_h_r;
				assign res[l*32 + glh*16 +: 16]  = res_h_r;
			end
		end
	endgenerate

	/* The next lane. */
	wire [LW-1:0] li_next;
	wire li_co_unused;
	am_add #(.W(LW)) u_li (.a(li), .b({LW{1'b0}}), .ci(1'b1), .s(li_next), .co(li_co_unused));

	/* Session protection scrub counter. */
	wire sc_on;
	wire [AW-1:0] sc_a;

	atg_su_scrub #(.DEPTH(NW), .AW(AW)) sc (
		.clk(clk), .rst_n(rst_n), .start(scrub), .on(sc_on), .a(sc_a)
	);

	wire [AW-1:0] sc_a_next;
	wire sc_a_co_unused;
	am_add #(.W(AW)) u_sc_a_next (.a(sc_a), .b({AW{1'b0}}), .ci(1'b1), .s(sc_a_next), .co(sc_a_co_unused));

	assign scrub_busy = sc_on;

	always @(posedge clk) begin
		if (rst_p) begin
			st <= IDLE;
			li <= {LW{1'b0}};
			pli_1 <= {LW{1'b0}};
			pli_2 <= {LW{1'b0}};
			pli_3 <= {LW{1'b0}};
			pval_1 <= 1'b0;
			pval_2 <= 1'b0;
			pval_3 <= 1'b0;
			aph <= 3'd0;
			atom_b <= 32'd0;
			atom_c <= 32'd0;
			ram_addr_r <= {AW{1'b0}};
			ram_we_r <= 1'b0;
			ram_wd_r <= 32'd0;
		end else begin
			pval_1 <= 1'b0;
			pval_2 <= pval_1;
			pval_3 <= pval_2;
			pli_2 <= pli_1;
			pli_3 <= pli_2;
			ram_we_r <= 1'b0;

			if (scrub) begin
				ram_we_r <= 1'b1;
				ram_addr_r <= {AW{1'b0}};
				ram_wd_r <= 32'd0;
			end else if (sc_on) begin
				if ({{(32-AW){1'b0}}, sc_a} != NW - 1) begin
					ram_we_r <= 1'b1;
					ram_addr_r <= sc_a_next;
					ram_wd_r <= 32'd0;
				end
			end else begin
				case (st)
				IDLE: if (mine && !ram_we_r) begin
					lanes <= xl;
					rsts <= is_sts;
					ratom <= is_atom;
					rwrd <= x_uop[ATG_UOP_WRD];
					rsub <= x_uop[ATG_UOP_SUB +: 4];
					rrd <= x_uop[ATG_UOP_RD +: 7];
					rwarp <= x_warp;
					rgrp <= x_grp;
					rlast <= x_last;
					rsbe <= x_sbe;
					li <= {LW{1'b0}};
					aph <= 3'd0;
					st <= xl == {NPHYS{1'b0}} ? BEAT : ACCESS;
				end
				ACCESS: if (atom_active) begin
					case (aph)
					3'd0: begin
						ram_addr_r <= a;
						atom_b <= cur_rdat;
						atom_c <= rcmp[li*32 +: 32];
						aph <= 3'd1;
					end
					3'd1: aph <= 3'd2;
					3'd2: aph <= 3'd3;
					3'd3: begin
						ram_we_r <= 1'b1;
						ram_addr_r <= a;
						ram_wd_r <= w_atom;
						aph <= 3'd4;
					end
					default: begin
						aph <= 3'd0;
						li <= li_next;
						if ({{(32-LW){1'b0}}, li} == NPHYS - 1)
							st <= DRAIN1;
					end
					endcase
				end else begin
					if (!ratom) begin
						ram_addr_r <= a;
						if (rsts && lane_on) begin
							ram_we_r <= 1'b1;
							ram_wd_r <= cur_rdat;
						end
					end
					aph <= 3'd0;
					pval_1 <= lane_on && !rsts && !ratom;
					pli_1 <= li;
					li <= li_next;
					if ({{(32-LW){1'b0}}, li} == NPHYS - 1)
						st <= DRAIN1;
				end
				DRAIN1: st <= DRAIN2;
				DRAIN2: st <= DRAIN3;
				DRAIN3: st <= BEAT;
				default: if (l_ready)
					st <= IDLE;
				endcase
			end
		end
	end

	/* Port A: Registered address + dedicated fabric output register q_pipe (Rule 4). */
	always @(posedge clk) begin
		if (ram_we_r)
			ram[ram_addr_r] <= ram_wd_r;
		q <= ram[ram_addr_r];
		q_pipe <= q;
	end

	/* Port B: Registered read + dedicated fabric output register mesh_rd_data_r (Rule 4). */
	reg [31:0] mesh_rd_q;
	(* dont_touch = "true" *) reg [31:0] mesh_rd_data_r;
	always @(posedge clk) begin
		if (mesh_rd_en)
			mesh_rd_q <= ram[mesh_rd_addr];
		mesh_rd_data_r <= mesh_rd_q;
	end
	assign mesh_rd_data = mesh_rd_data_r;

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

	wire unused_ok = &{1'b0, x_pc, x_info, x_uop, imm, x_a, sc_a_co_unused, (NWARPS != 0)};
endmodule

`default_nettype wire
