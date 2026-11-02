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
 * Writes (pw_*): varying word pw_addr[5:0] of vertex pw_addr[7:6] of
 * primitive pw_addr[10:8] of warp pw_warp; pw_addr 0xFFF instead writes
 * the warp's primitive map (bits 3q+2..3q: the primitive of quad q; RX
 * writes it for every warp, 0 in v1 where a warp holds one triangle).
 * lda rd, imm: every lane reads PT word imm[8:2] (4 + w: varying word w)
 * of vertex imm[1:0] of its quad's primitive (0 for PT words 0-3, beyond
 * 4 + VARY_WORDS or for vertex 3); the result is on s_* SHORT_LAT cycles
 * after the group was taken, for the EXEC lanes.  The table has
 * NC = min(NPHYS/4, 2) copies in block RAM (design §3.5), read
 * synchronously: copy c reads quad p * NC + c in read cycle p, so a lane
 * group takes NR = NPHYS/4/NC cycles and x_ready is 0 in its later ones.
 * scrub (session protection, the unit idle) writes 0 to every word of
 * every copy through the table's write port, one word per cycle, while
 * scrub_busy.
 * See spec/gpu/su/atg_su_lda.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_lda #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter PRIMS = 8,	/* Primitives per warp slot */
	parameter VARY_WORDS = 32,	/* Varying words per vertex, at most 64 (KC705 64) */
	parameter SHORT_LAT = 6	/* Cycles from the group's take to the short result (one fixed pipeline for classes a and f, design §3.1.1); at least 1 + NR */
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
	input wire [31:0] pw_data,
	/* Session protection: clear the table */
	input wire scrub,
	output wire scrub_busy
);
`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	localparam NQ = NPHYS < 8 ? 1 : NPHYS / 4;	/* quads per lane group */
	localparam NC = NQ < 2 ? NQ : 2;	/* table copies (read ports) */
	localparam NR = NQ / NC;	/* read cycles per group */
	localparam PW = NR > 1 ? $clog2(NR) : 1;
	localparam LD = SHORT_LAT - NR - 2;	/* data stages after raddr_r (1) + BRAM rq (1) + rq_pipe (1) */
	localparam DEPTH = NWARPS * PRIMS * 3 * VARY_WORDS;
	localparam AW = $clog2(DEPTH);
	localparam EW = 1 + WARP_W + GRP_W + 7 + NPHYS;
	localparam PL = $clog2(PRIMS);	/* PRIMS, VARY_WORDS, NQ and NC are powers of two */
	localparam VL = $clog2(VARY_WORDS);

	/*
	 * A table word's address ((warp PRIMS + prim) 3 + vertex) VARY_WORDS +
	 * word, modulo 2^AW, for prim < PRIMS and word < VARY_WORDS: the 3 x by
	 * two adders, the rest disjoint bits.
	 */
	function [AW-1:0] tab_x;	/* warp PRIMS + prim */
		input [WARP_W-1:0] w;
		input [2:0] pr;
		/* verilator lint_off WIDTHTRUNC */
		tab_x = ({{(32-WARP_W){1'b0}}, w} << PL) | {29'd0, pr};
		/* verilator lint_on WIDTHTRUNC */
	endfunction

	/* The primitive maps. */
	wire rst_p = !rst_n;
	(* dont_touch = "true" *) wire scrub_i = scrub;
	wire [NWARPS*24-1:0] pmap;
	wire map_we = pw_we && pw_addr == 12'hFFF;
	genvar gpm;
	generate
		for (gpm = 0; gpm < NWARPS; gpm = gpm + 1) begin : g_pmap_w
			(* dont_touch = "true" *) wire pm_we_s  = map_we && (pw_warp == gpm[WARP_W-1:0]);
			reg [23:0] pmap_w_r;
			always @(posedge clk) begin
				if (rst_p)
					pmap_w_r <= 24'd0;
				else if (pm_we_s)
					pmap_w_r <= pw_data[23:0];
			end
			assign pmap[gpm*24 +: 24] = pmap_w_r;
		end
	endgenerate

	/* Table writes. */
	wire [31:0] wprim = {29'd0, pw_addr[10:8]};
	wire [31:0] wvtx = {30'd0, pw_addr[7:6]};
	wire [31:0] wword = {26'd0, pw_addr[5:0]};
	wire tab_we = pw_we && !pw_addr[11] && wvtx < 3 && wword < VARY_WORDS && wprim < PRIMS;
	wire [AW-1:0] wx = tab_x(pw_warp, wprim[2:0]);
	wire [AW-1:0] wy;
	wire wy_co_unused;
	am_add #(.W(AW)) u_wy (
		.a({wx[AW-2:0], wvtx[0] | wvtx[1]}),
		.b(wx),
		.ci(wvtx[1]),
		.s(wy),
		.co(wy_co_unused)
	);
	/* verilator lint_off WIDTHTRUNC */
	wire [AW-1:0] waddr_a = (wy << VL) | wword[AW-1:0];
	/* verilator lint_on WIDTHTRUNC */
	wire [31:0] waddr = {{(32-AW){1'b0}}, waddr_a};

	/* The write port: the RX's writes or the scrub's zeros (registered for 0-LUT BRAM ADDR, Rule 4). */
	wire sc_on;
	wire [AW-1:0] sc_a;

	atg_su_scrub #(.DEPTH(DEPTH), .AW(AW)) sc (
		.clk(clk), .rst_n(rst_n), .start(scrub_i), .on(sc_on), .a(sc_a)
	);

	wire [AW-1:0] sc_a_next;
	wire sc_a_co_unused;
	am_add #(.W(AW)) u_sc_a_next (.a(sc_a), .b({AW{1'b0}}), .ci(1'b1), .s(sc_a_next), .co(sc_a_co_unused));

	assign scrub_busy = sc_on;
	(* max_fanout = 12 *) reg t_we_r;
	(* max_fanout = 12 *) reg [AW-1:0] t_wa_r;
	(* shreg_extract = "no", max_fanout = 12 *) reg [15:0] t_wd_lo_r, t_wd_hi_r;
	wire [31:0] t_wd_r = {t_wd_hi_r, t_wd_lo_r};
	(* dont_touch = "true" *) wire wd_zero_lo = rst_p || scrub_i || sc_on;
	(* dont_touch = "true" *) wire wd_zero_hi = rst_p || scrub_i || sc_on;
	always @(posedge clk) begin
		if (rst_p) begin
			t_we_r <= 1'b0;
			t_wa_r <= {AW{1'b0}};
		end else if (scrub_i) begin
			t_we_r <= 1'b1;
			t_wa_r <= {AW{1'b0}};
		end else if (sc_on) begin
			if ({{(32-AW){1'b0}}, sc_a} == DEPTH - 1)
				t_we_r <= 1'b0;
			else begin
				t_we_r <= 1'b1;
				t_wa_r <= sc_a_next;
			end
		end else begin
			t_we_r <= tab_we;
			t_wa_r <= waddr[AW-1:0];
		end
		if (wd_zero_lo)
			t_wd_lo_r <= 16'd0;
		else
			t_wd_lo_r <= pw_data[15:0];
		if (wd_zero_hi)
			t_wd_hi_r <= 16'd0;
		else
			t_wd_hi_r <= pw_data[31:16];
	end

	/* The read cycle of the group being read: 0 takes a group from x_*. */
	(* max_fanout = 12 *) reg [PW-1:0] ph;
	wire [PW-1:0] ph_next;
	wire ph_co_unused;
	am_add #(.W(PW)) u_ph (.a(ph), .b({PW{1'b0}}), .ci(1'b1), .s(ph_next), .co(ph_co_unused));
	(* max_fanout = 12 *) wire x_ready_w = ph == {PW{1'b0}};
	assign x_ready = x_ready_w;
	wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_LDA && x_uop[ATG_UOP_WRD];
	(* max_fanout = 12 *) wire take = mine && x_ready_w;

	/* The group's warp, quads' primitives and immediate: from x_* in read cycle 0, then latched. */
	(* max_fanout = 12 *) reg [WARP_W-1:0] l_warp;
	(* max_fanout = 12 *) reg [GRP_W-1:0] l_grp;
	(* max_fanout = 12 *) reg [23:0] l_map;
	(* max_fanout = 12 *) reg [8:0] l_imm;
	wire [WARP_W-1:0] x_warp_map, x_warp_ctl;
`ifdef SYNTH_KINTEX7
	genvar glw;
	generate
		for (glw = 0; glw < WARP_W; glw = glw + 1) begin : g_buf_xwl
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_xwm (.I0(x_warp[glw]), .O(x_warp_map[glw]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_xwc (.I0(x_warp[glw]), .O(x_warp_ctl[glw]));
		end
	endgenerate
`else
	assign x_warp_map = x_warp;
	assign x_warp_ctl = x_warp;
`endif
	(* max_fanout = 12 *) wire [WARP_W-1:0] c_warp = x_ready_w ? x_warp_ctl : l_warp;
	(* max_fanout = 12 *) wire [GRP_W-1:0] c_grp = x_ready_w ? x_grp : l_grp;
	reg [23:0] x_map;
	integer mi;
	always @(*) begin
		x_map = pmap[23:0];
		for (mi = 1; mi < NWARPS; mi = mi + 1)
			if (x_warp_map == mi[WARP_W-1:0])
				x_map = pmap[mi*24 +: 24];
	end
	(* max_fanout = 12 *) wire [23:0] c_map = x_ready_w ? x_map : l_map;
	(* max_fanout = 12 *) wire [8:0] c_imm = x_ready_w ? x_uop[ATG_UOP_IMM +: 9] : l_imm;
	always @(posedge clk) begin
		if (rst_p) begin
			ph <= {PW{1'b0}};
			l_warp <= {WARP_W{1'b0}};
			l_grp <= {GRP_W{1'b0}};
			l_imm <= 9'd0;
			l_map <= 24'd0;
		end else begin
			if (take) begin
				l_warp <= x_warp_ctl;
				l_grp <= x_grp;
				l_imm <= x_uop[ATG_UOP_IMM +: 9];
				l_map <= x_map;
			end
			if (NR > 1 && (take || !x_ready_w))
				ph <= ph_next;
		end
	end

	(* max_fanout = 12 *) wire [31:0] rvtx = {30'd0, c_imm[1:0]};
	(* max_fanout = 12 *) wire [31:0] rword = {25'd0, c_imm[8:2]};
	(* max_fanout = 12 *) wire rok = rvtx < 3 && rword >= 4 && rword < 4 + VARY_WORDS;
	wire [6:0] rvary_sub;
	wire rv_bo_unused;
	am_sub #(.W(7)) u_rvary (.a(rword[6:0]), .b(7'd4), .bi(1'b0), .d(rvary_sub), .bo(rv_bo_unused));
	(* max_fanout = 12 *) wire [6:0] rvary = (rword[6:0] >= 7'd4) ? rvary_sub : 7'd0;
	/* the quad copy 0 reads: group NQ + ph NC (disjoint bits) */
	wire [31:0] qbase = ({{(32-GRP_W){1'b0}}, c_grp} * NQ) | ({{(32-PW){1'b0}}, ph} * NC);

	/* The copies: registered read address raddr_r + synchronous BRAM read rq + fabric rq_pipe (Rule 4). */
	reg [NC*32-1:0] rq;
	(* dont_touch = "true" *) reg [NC*32-1:0] rq_pipe;
	(* shreg_extract = "no", max_fanout = 12 *) reg [NC-1:0] rq_ok, rq_ok_pipe;
	genvar q;
	generate
	for (q = 0; q < NC; q = q + 1) begin : g_copy
		reg [31:0] m [0:DEPTH-1];
		reg [AW-1:0] raddr_r;
		reg rok_r;
		wire [31:0] qi = qbase | q;
`ifdef MUT_LDA_PHASE
		wire [31:0] qm = ({{(32-GRP_W){1'b0}}, c_grp} * NQ) | q;
		wire [2:0] pqi = qm[2:0];
`else
		wire [2:0] pqi = qi[2:0];
`endif
		/* The quad's primitive (a selection: 3 bits a quad). */
		reg [2:0] prim;
		integer pq;
		always @(*) begin
			prim = c_map[2:0];
			for (pq = 1; pq < 8; pq = pq + 1)
				if (pqi == pq[2:0])
					prim = c_map[3 * pq +: 3];
		end
		wire [AW-1:0] rx = tab_x(c_warp, prim);
		wire [AW-1:0] ry;
		wire ry_co_unused;
		am_add #(.W(AW)) u_ry (
			.a({rx[AW-2:0], rvtx[0] | rvtx[1]}),
			.b(rx),
			.ci(rvtx[1]),
			.s(ry),
			.co(ry_co_unused)
		);
		/* verilator lint_off WIDTHTRUNC */
		wire [AW-1:0] raddr_a = (ry << VL) | {{(AW > 7 ? AW - 7 : 0){1'b0}}, rvary};
		/* verilator lint_on WIDTHTRUNC */
		wire [31:0] raddr = {{(32-AW){1'b0}}, raddr_a};
		always @(posedge clk) begin
			if (rst_p) begin
				raddr_r <= {AW{1'b0}};
				rok_r <= 1'b0;
				rq_ok[q] <= 1'b0;
			end else begin
				raddr_r <= raddr[AW-1:0];
				rok_r <= rok && {29'd0, prim} < PRIMS;
				rq_ok[q] <= rok_r;
			end
			if (t_we_r)
				m[t_wa_r] <= t_wd_r;
			rq[32 * q +: 32] <= m[raddr_r];
		end
		wire unused_q = &{1'b0, qi, raddr};
	end
	endgenerate

	always @(posedge clk) begin
		rq_pipe <= rq;
		if (rst_p)
			rq_ok_pipe <= {NC{1'b0}};
		else
			rq_ok_pipe <= rq_ok;
	end

	/* The reads of a group gathered: read cycle p's data is in rq_pipe 3 cycles after ph. */
	(* shreg_extract = "no", max_fanout = 12 *) reg [PW-1:0] rph_d1, rph_d2, rph;
	always @(posedge clk)
		if (rst_p) begin
			rph_d1 <= {PW{1'b0}};
			rph_d2 <= {PW{1'b0}};
			rph    <= {PW{1'b0}};
		end else begin
			rph_d1 <= ph;
			rph_d2 <= rph_d1;
			rph    <= rph_d2;
		end
	wire [DW-1:0] y;	/* the group's data in the cycle of its last read's */
	genvar c, gs;
	generate
	for (c = 0; c < NC; c = c + 1) begin : g_last
		(* dont_touch = "true" *) wire [7:0] rq_ok_sl;
		wire [127:0] rq_rep = {4{rq_pipe[32 * c +: 32]}};
		for (gs = 0; gs < 8; gs = gs + 1) begin : g_last_sl
			assign rq_ok_sl[gs] = rq_ok_pipe[c];
			assign y[128 * ((NR - 1) * NC + c) + gs * 16 +: 16] = rq_ok_sl[gs] ? rq_rep[gs * 16 +: 16] : 16'd0;
		end
	end
	if (NR > 1) begin : g_buf
		/* the earlier read cycles' data, held until the last */
		wire [128*NC*(NR-1)-1:0] ybuf;
		genvar p;
		for (p = 0; p < NR - 1; p = p + 1) begin : g_ph
			localparam [PW-1:0] PV = p;
			for (c = 0; c < NC; c = c + 1) begin : g_c
				wire [127:0] rq_rep_b = {4{rq_pipe[32 * c +: 32]}};
				for (gs = 0; gs < 8; gs = gs + 1) begin : g_ybuf_sl
					(* dont_touch = "true" *) wire ybuf_we_s = (rph == PV);
					(* dont_touch = "true" *) wire ybuf_ok_s = rq_ok_pipe[c];
					(* shreg_extract = "no" *) reg [15:0] ybuf_sl_r;
					always @(posedge clk)
						if (ybuf_we_s)
							ybuf_sl_r <= ybuf_ok_s ? rq_rep_b[gs * 16 +: 16] : 16'd0;
					assign ybuf[128 * (p * NC + c) + gs * 16 +: 16] = ybuf_sl_r;
				end
			end
		end
		assign y[128*NC*(NR-1)-1:0] = ybuf;
	end else begin : g_nobuf
		wire unused_rph = &{1'b0, rph_d1, rph_d2, rph};
	end
	endgenerate

	/* SHORT_LAT stages of the group's control; stage 0 is registered from x_*. */
	(* shreg_extract = "no", max_fanout = 12 *) reg [EW-1:0] pipe [0:SHORT_LAT-1];
	integer k;
	always @(posedge clk) begin
		if (rst_p) begin
			for (k = 0; k < SHORT_LAT; k = k + 1)
				pipe[k][EW-1] <= 1'b0;
		end else begin
			pipe[0][EW-1] <= take;
			for (k = 1; k < SHORT_LAT; k = k + 1)
				pipe[k][EW-1] <= pipe[k-1][EW-1];
		end
		pipe[0][EW-2:0] <= {x_warp_ctl, x_grp, x_uop[ATG_UOP_RD +: 7], x_mask[NPHYS-1:0]};
		for (k = 1; k < SHORT_LAT; k = k + 1)
			pipe[k][EW-2:0] <= pipe[k-1][EW-2:0];
	end

	/* The data, NR+2 cycles after the take, through LD stages. */
	wire [DW-1:0] y_final;
	generate
	if (LD > 0) begin : g_dp
		(* shreg_extract = "no" *) reg [DW-1:0] dp [0:LD-1];
		integer kd;
		always @(posedge clk) begin
			dp[0] <= y;
			for (kd = 1; kd < LD; kd = kd + 1)
				dp[kd] <= dp[kd-1];
		end
		assign y_final = dp[LD-1];
	end else begin : g_nodp
		assign y_final = y;
	end
	endgenerate

	wire [EW-1:0] o = pipe[SHORT_LAT-1];
	assign s_valid = o[EW-1];
	assign s_warp = o[EW-2 -: WARP_W];
	assign s_grp = o[EW-2-WARP_W -: GRP_W];
	assign s_rd = o[EW-2-WARP_W-GRP_W -: 7];
	assign s_lanes = o[NPHYS-1:0];
	(* dont_touch = "true" *) wire [NPHYS*2-1:0] s_val_sl;
	generate
	for (gs = 0; gs < NPHYS*2; gs = gs + 1) begin : g_sd_sl
		assign s_val_sl[gs] = o[EW-1];
		assign s_data[gs*16 +: 16] = s_val_sl[gs] ? y_final[gs*16 +: 16] : 16'd0;
	end
	endgenerate

	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_a, x_b, x_c, x_mask[2*NPHYS-1:NPHYS],
		x_info, x_uop, waddr, qbase, rvary, sc_a_co_unused};
endmodule

`default_nettype wire
