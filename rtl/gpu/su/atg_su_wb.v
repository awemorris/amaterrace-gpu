/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_wb: Write-back arbitration: one RF write port shared by the short
 * pipeline (one result per cycle), the long units' beats, and the VF/RX
 * input writes; pushes rq results; releases scoreboard entries.
 *
 * The behaviour, and where it differs from
 * the design: spec/gpu/su/atg_su_wb.md (§10 Status).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_wb #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter NS = 6,	/* Short sources (alu, fpu, pk, lane, lda, exec) */
	parameter NL = 6,	/* Long sources (lsu, lds, cbank, tex, xu, div) */
	parameter SHORT_LAT = 6	/* Cycles from x_valid to the short result (sizes the input FIFOs) */
) (
	input wire clk,
	input wire rst_n,
	/* Short results (packed, source 0 in the low bits; at most one valid per cycle) */
	input wire [NS-1:0] s_valid,
	input wire [NS*WARP_W-1:0] s_warp,
	input wire [NS*GRP_W-1:0] s_grp,
	input wire [NS*7-1:0] s_rd,
	input wire [NS*NPHYS*32-1:0] s_data,
	input wire [NS*NPHYS-1:0] s_lanes,
	/* Long results (packed) */
	input wire [NL-1:0] l_valid,
	output wire [NL-1:0] l_ready,
	input wire [NL*WARP_W-1:0] l_warp,
	input wire [NL*GRP_W-1:0] l_grp,
	input wire [NL*7-1:0] l_rd,
	input wire [NL*NPHYS*32-1:0] l_data,
	input wire [NL*NPHYS-1:0] l_lanes,
	input wire [NL-1:0] l_wr,
	input wire [NL-1:0] l_last,
	input wire [NL*(SBE_W+1)-1:0] l_sbe,
	input wire [NL*3-1:0] l_cls,
	/* Input writes (0 VF, 1 RX: one lane word per cycle) */
	input wire [1:0] in_we,
	input wire [2*WARP_W-1:0] in_warp,
	input wire [11:0] in_reg,
	input wire [9:0] in_lane,
	input wire [63:0] in_data,
	/* Outputs */
	output wire w_en,
	output wire [WARP_W-1:0] w_warp,
	output wire [GRP_W-1:0] w_grp,
	output wire [5:0] w_reg,
	output wire [NPHYS*32-1:0] w_data,
	output wire [NPHYS-1:0] w_lanes,
	output wire rel_valid,
	output wire [WARP_W-1:0] rel_warp,
	output wire [SBE_W:0] rel_sbe,
	output wire [2:0] rel_cls,
	output wire rq_push,
	output wire [NPHYS*32-1:0] rq_data,
	output wire wb_stall
);
`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	localparam G = 32 / NPHYS;
	localparam LP_W = NL > 1 ? $clog2(NL) : 1;
	/* An input FIFO entry: {warp, reg, lane, data}. */
	localparam IW = WARP_W + 6 + 5 + 32;
	/*
	 * The input FIFOs' depth.  A source writes one word a cycle and cannot
	 * wait; a word waits while short results hold the port.  After the first
	 * waiting word raises wb_stall, the short results still to come are at
	 * most those in the units' pipelines (SHORT_LAT), the instruction in
	 * atg_su_opd and the one issued in that cycle (G each; a subgroup
	 * instruction's G more bus cycles carry no result) and the cycles of the
	 * stall's latency (2); source 1 also waits while source 0 has words, so
	 * twice that.  NPHYS 4 (G 8) needs 64; a fixed 16 lost RX writes there.
	 */
	localparam IN_LOG2 = $clog2(2 * (SHORT_LAT + 2 * G + 2));

	/* The short result of this cycle (at most one source is valid). */
	reg sv;
	reg [WARP_W-1:0] sw;
	reg [GRP_W-1:0] sg;
	reg [6:0] srd;
	reg [DW-1:0] sd;
	reg [NPHYS-1:0] sl;
	integer i;
	always @(*) begin
		sv = 1'b0;
		sw = {WARP_W{1'b0}};
		sg = {GRP_W{1'b0}};
		srd = 7'd0;
		sd = {DW{1'b0}};
		sl = {NPHYS{1'b0}};
		for (i = 0; i < NS; i = i + 1) begin
			if (s_valid[i]) begin
				sv = 1'b1;
				sw = sw | s_warp[i*WARP_W +: WARP_W];
				sg = sg | s_grp[i*GRP_W +: GRP_W];
				srd = srd | s_rd[i*7 +: 7];
				sd = sd | s_data[i*DW +: DW];
				sl = sl | s_lanes[i*NPHYS +: NPHYS];
			end
		end
	end

	/* Input writes: one FIFO per source (VF, RX), since they cannot wait. */
	wire [1:0] fi_valid;
	wire [1:0] fi_ready;
	wire [2*IW-1:0] fi_data;
	genvar s;
	generate
		for (s = 0; s < 2; s = s + 1) begin : inq
			wire in_rdy;
			wire [IN_LOG2:0] unused_count;
			am_fifo #(.W(IW), .DEPTH_LOG2(IN_LOG2)) q (
				.clk(clk), .rst_n(rst_n), .in_valid(in_we[s]), .in_ready(in_rdy),
				.in_data({in_warp[s*WARP_W +: WARP_W], in_reg[s*6 +: 6], in_lane[s*5 +: 5],
					in_data[s*32 +: 32]}),
				.out_valid(fi_valid[s]), .out_ready(fi_ready[s]),
				.out_data(fi_data[s*IW +: IW]), .count(unused_count)
			);
`ifndef SYNTHESIS
			always @(posedge clk)
				if (rst_n && in_we[s] && !in_rdy)
					$display("ERROR atg_su_wb: input %0d FIFO full, a write lost", s);
`else
			wire unused_rdy = &{1'b0, in_rdy};
`endif
		end
	endgenerate

	/* Long beats: round-robin from the pointer.  A beat that writes (the RF or
	 * rq) needs the port; one without (a store's completion) does not. */
	wire port_free = !sv && !(|fi_valid);
	/* (The first eligible source at or after rr, else the first one.) */
	reg [LP_W-1:0] rr;
	reg lsel_v;
	reg [LP_W-1:0] lsel;
	reg [LP_W-1:0] lsel_lo;
	reg lsel_hv;
	reg [NL-1:0] l_elig;
	integer k;
	always @(*) begin
		lsel_v = 1'b0;
		lsel_hv = 1'b0;
		lsel = {LP_W{1'b0}};
		lsel_lo = {LP_W{1'b0}};
		for (k = NL - 1; k >= 0; k = k - 1) begin
			l_elig[k] = l_valid[k] && (port_free || !l_wr[k]);
			if (l_elig[k]) begin
				lsel_v = 1'b1;
				lsel_lo = k[LP_W-1:0];
				if (k[LP_W-1:0] >= rr) begin
					lsel_hv = 1'b1;
					lsel = k[LP_W-1:0];
				end
			end
		end
		if (!lsel_hv)
			lsel = lsel_lo;
	end

	/* The selected source's fields (a selection by lsel). */
	reg [6:0] lrd;
	reg [WARP_W-1:0] l_s_warp;
	reg [GRP_W-1:0] l_s_grp;
	reg [DW-1:0] l_s_data;
	reg [NPHYS-1:0] l_s_lanes;
	reg [SBE_W:0] l_s_sbe;
	reg [2:0] l_s_cls;
	reg [NL-1:0] l_s_one;
	integer m;
	always @(*) begin
		lrd = l_rd[6:0];
		l_s_warp = l_warp[WARP_W-1:0];
		l_s_grp = l_grp[GRP_W-1:0];
		l_s_data = l_data[DW-1:0];
		l_s_lanes = l_lanes[NPHYS-1:0];
		l_s_sbe = l_sbe[SBE_W:0];
		l_s_cls = l_cls[2:0];
		for (m = 0; m < NL; m = m + 1) begin
			l_s_one[m] = lsel == m[LP_W-1:0];
			if (m > 0 && l_s_one[m]) begin
				lrd = l_rd[m*7 +: 7];
				l_s_warp = l_warp[m*WARP_W +: WARP_W];
				l_s_grp = l_grp[m*GRP_W +: GRP_W];
				l_s_data = l_data[m*DW +: DW];
				l_s_lanes = l_lanes[m*NPHYS +: NPHYS];
				l_s_sbe = l_sbe[m*(SBE_W+1) +: SBE_W+1];
				l_s_cls = l_cls[m*3 +: 3];
			end
		end
	end
	wire lw = lsel_v && l_wr[lsel];
	assign l_ready = lsel_v ? l_s_one : {NL{1'b0}};

	/* Inputs take cycles without a short result, source 0 first. */
	wire in_go = !sv && (|fi_valid);
	wire in_src = !fi_valid[0];
	wire [IW-1:0] fe = fi_data[in_src*IW +: IW];
	assign fi_ready = in_go ? (in_src ? 2'b10 : 2'b01) : 2'b00;
	wire [4:0] fe_lane = fe[36:32];

	reg [DW-1:0] fe_data;
	reg [NPHYS-1:0] fe_lanes;
	integer l;
	always @(*) begin
		for (l = 0; l < NPHYS; l = l + 1) begin
			fe_data[l*32 +: 32] = fe[31:0];
			fe_lanes[l] = {27'd0, fe_lane} % NPHYS == l;
		end
	end
	wire [31:0] fe_grp = {27'd0, fe_lane} / NPHYS;

	wire s_rq = sv && srd == 7'd63;
	wire l_rq = !sv && !in_go && lw && lrd == 7'd63;
	assign w_en = (sv && !s_rq) || in_go || (lw && !l_rq && !sv && !in_go);
	assign w_warp = sv ? sw : in_go ? fe[IW-1 -: WARP_W] : l_s_warp;
	assign w_grp = sv ? sg : in_go ? fe_grp[GRP_W-1:0] : l_s_grp;
	assign w_reg = sv ? srd[5:0] : in_go ? fe[42:37] : lrd[5:0];
	assign w_data = sv ? sd : in_go ? fe_data : l_s_data;
	assign w_lanes = sv ? sl : in_go ? fe_lanes : l_s_lanes;
	assign rq_push = s_rq || l_rq;
	assign rq_data = sv ? sd : l_s_data;

	/* A long beat that has waited more than 4 cycles, or a pending input,
	 * stops the issue so that a free write cycle comes. */
	reg [2:0] wait_n;
	wire [LP_W-1:0] lsel_next;
	wire [2:0] wait_next;
	wire ls_co_unused, wn_co_unused;
	am_add #(.W(LP_W)) u_lsel (.a(lsel), .b({LP_W{1'b0}}), .ci(1'b1), .s(lsel_next), .co(ls_co_unused));
	am_add #(.W(3)) u_wait (.a(wait_n), .b(3'd0), .ci(1'b1), .s(wait_next), .co(wn_co_unused));
	always @(posedge clk) begin
		if (!rst_n) begin
			rr <= {LP_W{1'b0}};
			wait_n <= 3'd0;
		end else begin
			if (lsel_v)
				rr <= {{(32-LP_W){1'b0}}, lsel} == NL - 1 ? {LP_W{1'b0}} : lsel_next;
			if ((|(l_valid & ~l_ready)) && wait_n != 3'd7)
				wait_n <= wait_next;
			else if (!(|(l_valid & ~l_ready)))
				wait_n <= 3'd0;
		end
	end

	/* Register release and stall outputs to break long combinational path to SB and Sched */
	reg r_rel_valid;
	reg [WARP_W-1:0] r_rel_warp;
	reg [SBE_W:0] r_rel_sbe;
	reg [2:0] r_rel_cls;
	reg r_wb_stall;

	always @(posedge clk) begin
		if (!rst_n) begin
			r_rel_valid <= 1'b0;
			r_rel_warp  <= {WARP_W{1'b0}};
			r_rel_sbe   <= {(SBE_W+1){1'b0}};
			r_rel_cls   <= 3'd0;
			r_wb_stall  <= 1'b0;
		end else begin
			r_rel_valid <= lsel_v && l_last[lsel];
			r_rel_warp  <= l_s_warp;
			r_rel_sbe   <= l_s_sbe;
			r_rel_cls   <= l_s_cls;
			r_wb_stall  <= wait_n > 3'd4 || (|fi_valid);
		end
	end

	assign rel_valid = r_rel_valid;
	assign rel_warp = r_rel_warp;
	assign rel_sbe = r_rel_sbe;
	assign rel_cls = r_rel_cls;
	assign wb_stall = r_wb_stall;

`ifndef SYNTHESIS
	/* Two short results in one cycle cannot happen (fixed latency, one issue). */
	reg s_any, s_two;
	integer si;
	always @(*) begin
		s_any = 1'b0;
		s_two = 1'b0;
		for (si = 0; si < NS; si = si + 1)
			if (s_valid[si]) begin
				s_two = s_two || s_any;
				s_any = 1'b1;
			end
	end
	always @(posedge clk)
		if (rst_n && s_two)
			$display("ERROR atg_su_wb: two short results in one cycle (%b)", s_valid);
`endif

	wire unused_ok = &{1'b0, fe_grp, (G != 0)};
endmodule

`default_nettype wire
