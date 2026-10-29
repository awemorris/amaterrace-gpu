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

	/* The short result of this cycle: structured balanced 2-level MUX tree (at most one valid per cycle) */
	wire v_01 = s_valid[0] || s_valid[1];
	wire v_23 = s_valid[2] || s_valid[3];

	wire [DW-1:0] sd_01 = s_valid[0] ? s_data[0*DW +: DW] : s_data[1*DW +: DW];
	wire [DW-1:0] sd_23 = s_valid[2] ? s_data[2*DW +: DW] : s_data[3*DW +: DW];
	wire [DW-1:0] sd_45 = s_valid[4] ? s_data[4*DW +: DW] : s_data[5*DW +: DW];
	wire [DW-1:0] sd = v_01 ? sd_01 : (v_23 ? sd_23 : sd_45);

	wire [6:0] srd_01 = s_valid[0] ? s_rd[0*7 +: 7] : s_rd[1*7 +: 7];
	wire [6:0] srd_23 = s_valid[2] ? s_rd[2*7 +: 7] : s_rd[3*7 +: 7];
	wire [6:0] srd_45 = s_valid[4] ? s_rd[4*7 +: 7] : s_rd[5*7 +: 7];
	wire [6:0] srd = v_01 ? srd_01 : (v_23 ? srd_23 : srd_45);

	wire [WARP_W-1:0] sw_01 = s_valid[0] ? s_warp[0*WARP_W +: WARP_W] : s_warp[1*WARP_W +: WARP_W];
	wire [WARP_W-1:0] sw_23 = s_valid[2] ? s_warp[2*WARP_W +: WARP_W] : s_warp[3*WARP_W +: WARP_W];
	wire [WARP_W-1:0] sw_45 = s_valid[4] ? s_warp[4*WARP_W +: WARP_W] : s_warp[5*WARP_W +: WARP_W];
	wire [WARP_W-1:0] sw = v_01 ? sw_01 : (v_23 ? sw_23 : sw_45);

	wire [GRP_W-1:0] sg_01 = s_valid[0] ? s_grp[0*GRP_W +: GRP_W] : s_grp[1*GRP_W +: GRP_W];
	wire [GRP_W-1:0] sg_23 = s_valid[2] ? s_grp[2*GRP_W +: GRP_W] : s_grp[3*GRP_W +: GRP_W];
	wire [GRP_W-1:0] sg_45 = s_valid[4] ? s_grp[4*GRP_W +: GRP_W] : s_grp[5*GRP_W +: GRP_W];
	wire [GRP_W-1:0] sg = v_01 ? sg_01 : (v_23 ? sg_23 : sg_45);

	wire [NPHYS-1:0] sl_01 = s_valid[0] ? s_lanes[0*NPHYS +: NPHYS] : s_lanes[1*NPHYS +: NPHYS];
	wire [NPHYS-1:0] sl_23 = s_valid[2] ? s_lanes[2*NPHYS +: NPHYS] : s_lanes[3*NPHYS +: NPHYS];
	wire [NPHYS-1:0] sl_45 = s_valid[4] ? s_lanes[4*NPHYS +: NPHYS] : s_lanes[5*NPHYS +: NPHYS];
	wire [NPHYS-1:0] sl = v_01 ? sl_01 : (v_23 ? sl_23 : sl_45);

	wire sv = |s_valid;

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
	(* keep = "true", max_fanout = 16 *) wire sv_arb = sv;
	wire port_free = !sv_arb && !(|fi_valid);
	reg [LP_W-1:0] rr;

	/* Precomputed parallel round-robin arbiters:
	 * arb_free: assumes port_free == 1 (all l_valid are eligible)
	 * arb_busy: assumes port_free == 0 (only l_valid && !l_wr are eligible)
	 * This cuts the long path from sv/fi_valid into the 8-source priority tree.
	 */
	reg lsel_free_v, lsel_free_hv;
	reg [LP_W-1:0] lsel_free, lsel_free_lo;
	reg lsel_busy_v, lsel_busy_hv;
	reg [LP_W-1:0] lsel_busy, lsel_busy_lo;
	integer k;
	always @(*) begin
		lsel_free_v = 1'b0;
		lsel_free_hv = 1'b0;
		lsel_free = {LP_W{1'b0}};
		lsel_free_lo = {LP_W{1'b0}};

		lsel_busy_v = 1'b0;
		lsel_busy_hv = 1'b0;
		lsel_busy = {LP_W{1'b0}};
		lsel_busy_lo = {LP_W{1'b0}};

		for (k = NL - 1; k >= 0; k = k - 1) begin
			/* Free arbiter */
			if (l_valid[k]) begin
				lsel_free_v = 1'b1;
				lsel_free_lo = k[LP_W-1:0];
				if (k[LP_W-1:0] >= rr) begin
					lsel_free_hv = 1'b1;
					lsel_free = k[LP_W-1:0];
				end
			end
			/* Busy arbiter (only non-writing beats can proceed) */
			if (l_valid[k] && !l_wr[k]) begin
				lsel_busy_v = 1'b1;
				lsel_busy_lo = k[LP_W-1:0];
				if (k[LP_W-1:0] >= rr) begin
					lsel_busy_hv = 1'b1;
					lsel_busy = k[LP_W-1:0];
				end
			end
		end
		if (!lsel_free_hv)
			lsel_free = lsel_free_lo;
		if (!lsel_busy_hv)
			lsel_busy = lsel_busy_lo;
	end

	wire lsel_v = port_free ? lsel_free_v : lsel_busy_v;
	wire [LP_W-1:0] lsel = port_free ? lsel_free : lsel_busy;

	/* The selected source's fields for release and ready (a selection by lsel). */
	reg [WARP_W-1:0] l_s_warp;
	reg [SBE_W:0] l_s_sbe;
	reg [2:0] l_s_cls;
	reg [NL-1:0] l_s_one;
	integer m;
	always @(*) begin
		l_s_warp = l_warp[WARP_W-1:0];
		l_s_sbe = l_sbe[SBE_W:0];
		l_s_cls = l_cls[2:0];
		for (m = 0; m < NL; m = m + 1) begin
			l_s_one[m] = lsel == m[LP_W-1:0];
			if (m > 0 && l_s_one[m]) begin
				l_s_warp = l_warp[m*WARP_W +: WARP_W];
				l_s_sbe = l_sbe[m*(SBE_W+1) +: SBE_W+1];
				l_s_cls = l_cls[m*3 +: 3];
			end
		end
	end
	assign l_ready = lsel_v ? l_s_one : {NL{1'b0}};

	/* Long result fields for the free arbiter (independent of sv) for writeback */
	reg [6:0] lrd_free;
	reg [WARP_W-1:0] l_s_warp_free;
	reg [GRP_W-1:0]  l_s_grp_free;
	reg [DW-1:0]     l_s_data_free;
	reg [NPHYS-1:0]  l_s_lanes_free;
	integer mf;
	always @(*) begin
		lrd_free = l_rd[6:0];
		l_s_warp_free = l_warp[WARP_W-1:0];
		l_s_grp_free = l_grp[GRP_W-1:0];
		l_s_data_free = l_data[DW-1:0];
		l_s_lanes_free = l_lanes[NPHYS-1:0];
		for (mf = 1; mf < NL; mf = mf + 1) begin
			if (lsel_free == mf[LP_W-1:0]) begin
				lrd_free = l_rd[mf*7 +: 7];
				l_s_warp_free = l_warp[mf*WARP_W +: WARP_W];
				l_s_grp_free = l_grp[mf*GRP_W +: GRP_W];
				l_s_data_free = l_data[mf*DW +: DW];
				l_s_lanes_free = l_lanes[mf*NPHYS +: NPHYS];
			end
		end
	end

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

	wire fi_has = |fi_valid;
	wire lw_free = lsel_free_v && l_wr[lsel_free];
	wire s_rq = sv && (srd == 7'd63);
	wire l_rq_free = lw_free && (lrd_free == 7'd63);

	(* keep = "true" *) wire s_we = (srd != 7'd63);
	(* keep = "true" *) wire non_s_we = fi_has ? 1'b1 : (lw_free && (lrd_free != 7'd63));
	assign w_en = sv ? s_we : non_s_we;

	assign w_warp  = sv ? sw       : (fi_has ? fe[IW-1 -: WARP_W] : l_s_warp_free);
	assign w_grp   = sv ? sg       : (fi_has ? fe_grp[GRP_W-1:0]  : l_s_grp_free);
	assign w_reg   = sv ? srd[5:0] : (fi_has ? fe[42:37]          : lrd_free[5:0]);
	assign w_data  = sv ? sd       : (fi_has ? fe_data            : l_s_data_free);
	assign w_lanes = sv ? sl       : (fi_has ? fe_lanes           : l_s_lanes_free);
	assign rq_push = sv ? s_rq     : (!fi_has && l_rq_free);
	assign rq_data = sv ? sd       : l_s_data_free;

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
