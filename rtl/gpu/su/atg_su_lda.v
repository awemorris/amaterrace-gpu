/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_lda: The primitive table: the three vertices' varyings of each
 * fragment warp's primitives, written by RX before the warp starts and
 * read by lda (short results).
 *
 * Writes (pw_*): word pw_addr[5:0] of vertex pw_addr[7:6] of primitive
 * pw_addr[10:8] of warp pw_warp; pw_addr 0xFFF instead writes the warp's
 * primitive map (bits 3q+2..3q: the primitive of quad q; RX writes it for
 * every warp, 0 in v1 where a warp holds one triangle).  lda rd, imm:
 * every lane reads word imm[7:2] of vertex imm[1:0] of its quad's
 * primitive (0 beyond VARY_WORDS or for vertex 3); the result is on s_*
 * SHORT_LAT cycles after x_valid, for the EXEC lanes.  The table has one
 * copy per quad of a lane group (NPHYS/4 read ports, design §3.5), read
 * asynchronously.  See spec/gpu/su/atg_su_lda.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_lda #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter PRIMS = 8,	/* Primitives per warp slot */
	parameter VARY_WORDS = 36,	/* Words per vertex (4 + 32 varyings) */
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
	output wire [NPHYS-1:0] s_lanes,
	/* Primitive table writes (from atg_rx through the atg_su ports fl_pw_*) */
	input wire pw_we,
	input wire [WARP_W-1:0] pw_warp,
	input wire [11:0] pw_addr,
	input wire [31:0] pw_data
);
`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	localparam NQ = NPHYS / 4;	/* quads per lane group = table copies */
	localparam DEPTH = NWARPS * PRIMS * 3 * VARY_WORDS;
	localparam AW = $clog2(DEPTH);
	localparam EW = 1 + WARP_W + GRP_W + 7 + NPHYS + DW;

	/* The primitive maps. */
	reg [NWARPS*24-1:0] pmap;
	wire map_we = pw_we && pw_addr == 12'hFFF;
	always @(posedge clk)
		if (!rst_n)
			pmap <= {(NWARPS*24){1'b0}};
		else if (map_we)
			pmap[pw_warp*24 +: 24] <= pw_data[23:0];

	/* Table writes. */
	wire [31:0] wprim = {29'd0, pw_addr[10:8]};
	wire [31:0] wvtx = {30'd0, pw_addr[7:6]};
	wire [31:0] wword = {26'd0, pw_addr[5:0]};
	wire tab_we = pw_we && !pw_addr[11] && wvtx < 3 && wword < VARY_WORDS && wprim < PRIMS;
	wire [31:0] waddr = ((({{(32-WARP_W){1'b0}}, pw_warp} * PRIMS + wprim) * 3 + wvtx) *
		VARY_WORDS) + wword;

	/* lda: the word and vertex of the immediate. */
	wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_LDA && x_uop[ATG_UOP_WRD];
	wire [31:0] imm = x_uop[ATG_UOP_IMM +: 32];
	wire [31:0] rvtx = {30'd0, imm[1:0]};
	wire [31:0] rword = {26'd0, imm[7:2]};
	wire rok = rvtx < 3 && rword < VARY_WORDS;
	wire [23:0] wmap = pmap[x_warp*24 +: 24];
	wire [31:0] qbase = {{(32-GRP_W){1'b0}}, x_grp} * NQ;	/* the group's first quad */

	reg [DW-1:0] y;
	genvar q;
	generate
	for (q = 0; q < NQ; q = q + 1) begin : g_copy
		reg [31:0] m [0:DEPTH-1];
		wire [31:0] qi = qbase + q;
		wire [2:0] prim = wmap[3 * qi[2:0] +: 3];
		wire [31:0] raddr = ((({{(32-WARP_W){1'b0}}, x_warp} * PRIMS + {29'd0, prim}) * 3 +
			rvtx) * VARY_WORDS) + rword;
		wire [31:0] r = m[raddr[AW-1:0]];
		always @(posedge clk)
			if (tab_we)
				m[waddr[AW-1:0]] <= pw_data;
		always @(*)
			y[128 * q +: 128] = rok && {29'd0, prim} < PRIMS ? {4{r}} : 128'd0;
		wire unused_q = &{1'b0, qi, raddr};
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
	assign x_ready = 1'b1;

	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_a, x_b, x_c, x_mask[2*NPHYS-1:NPHYS],
		x_info, x_uop, imm, waddr, wmap, qbase};
endmodule

`default_nettype wire
