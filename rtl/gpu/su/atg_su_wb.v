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
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/su/atg_su_wb.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_wb #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter NS = 6,	/* Short sources (alu, fpu, pk, lane, lda, exec) */
	parameter NL = 6	/* Long sources (lsu, lds, cbank, tex, xu, div) */
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
			wire unused_in_ready;
			wire [4:0] unused_count;
			am_fifo #(.W(IW), .DEPTH_LOG2(4)) q (
				.clk(clk), .rst_n(rst_n), .in_valid(in_we[s]), .in_ready(unused_in_ready),
				.in_data({in_warp[s*WARP_W +: WARP_W], in_reg[s*6 +: 6], in_lane[s*5 +: 5],
					in_data[s*32 +: 32]}),
				.out_valid(fi_valid[s]), .out_ready(fi_ready[s]),
				.out_data(fi_data[s*IW +: IW]), .count(unused_count)
			);
		end
	endgenerate

	/* Long beats: round-robin from the pointer.  A beat that writes (the RF or
	 * rq) needs the port; one without (a store's completion) does not. */
	wire port_free = !sv && !(|fi_valid);
	reg [LP_W-1:0] rr;
	reg lsel_v;
	reg [LP_W-1:0] lsel;
	integer k, c;
	always @(*) begin
		lsel_v = 1'b0;
		lsel = {LP_W{1'b0}};
		for (k = NL - 1; k >= 0; k = k - 1) begin
			c = ({{(32-LP_W){1'b0}}, rr} + k) % NL;
			if (l_valid[c] && (port_free || !l_wr[c])) begin
				lsel_v = 1'b1;
				lsel = c[LP_W-1:0];
			end
		end
	end
	wire lw = lsel_v && l_wr[lsel];
	wire [6:0] lrd = l_rd[lsel*7 +: 7];
	assign l_ready = lsel_v ? ({{(NL-1){1'b0}}, 1'b1} << lsel) : {NL{1'b0}};

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
	assign w_warp = sv ? sw : in_go ? fe[IW-1 -: WARP_W] : l_warp[lsel*WARP_W +: WARP_W];
	assign w_grp = sv ? sg : in_go ? fe_grp[GRP_W-1:0] : l_grp[lsel*GRP_W +: GRP_W];
	assign w_reg = sv ? srd[5:0] : in_go ? fe[42:37] : lrd[5:0];
	assign w_data = sv ? sd : in_go ? fe_data : l_data[lsel*DW +: DW];
	assign w_lanes = sv ? sl : in_go ? fe_lanes : l_lanes[lsel*NPHYS +: NPHYS];
	assign rq_push = s_rq || l_rq;
	assign rq_data = sv ? sd : l_data[lsel*DW +: DW];

	assign rel_valid = lsel_v && l_last[lsel];
	assign rel_warp = l_warp[lsel*WARP_W +: WARP_W];
	assign rel_sbe = l_sbe[lsel*(SBE_W+1) +: SBE_W+1];
	assign rel_cls = l_cls[lsel*3 +: 3];

	/* A long beat that has waited more than 4 cycles, or a pending input,
	 * stops the issue so that a free write cycle comes. */
	reg [2:0] wait_n;
	always @(posedge clk) begin
		if (!rst_n) begin
			rr <= {LP_W{1'b0}};
			wait_n <= 3'd0;
		end else begin
			if (lsel_v)
				rr <= lsel + 1'b1 == NL ? {LP_W{1'b0}} : lsel + 1'b1;
			if ((|(l_valid & ~l_ready)) && wait_n != 3'd7)
				wait_n <= wait_n + 3'd1;
			else if (!(|(l_valid & ~l_ready)))
				wait_n <= 3'd0;
		end
	end
	assign wb_stall = wait_n > 3'd4 || (|fi_valid);

`ifndef SYNTHESIS
	/* Two short results in one cycle cannot happen (fixed latency, one issue). */
	always @(posedge clk)
		if (rst_n && (s_valid & (s_valid - 1'b1)) != {NS{1'b0}})
			$display("ERROR atg_su_wb: two short results in one cycle (%b)", s_valid);
`endif

	wire unused_ok = &{1'b0, fe_grp, c, (G != 0)};
endmodule

`default_nettype wire
