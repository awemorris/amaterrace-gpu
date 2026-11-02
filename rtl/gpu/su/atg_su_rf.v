/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_rf: The SU register file (design §3.5): two copies of
 * NWARPS × NREGS × 32 lanes × 32 bits in True Dual-Port Block RAM
 * so that two sources are read concurrently every cycle alongside
 * one writeback port, one bank per physical lane (NPHYS banks, each holding
 * 32/NPHYS architectural lanes).
 *
 * Write: w_en writes register w_reg of lane group w_grp of warp w_warp in
 * the lanes of w_lanes, in every copy.  Read: r_en reads r_reg1 and r_reg2 of
 * one lane group; r_data1 and r_data2 are valid the cycle after r_en and hold
 * until the next r_en.  A read of a register written in the same cycle
 * returns the old value (no bypass).  Address = {warp, reg, grp}.  The
 * contents are not reset.  scrub (session protection) writes 0 to every
 * address of every copy, one address per cycle through the write port,
 * while scrub_busy (the unit is idle then; it has priority over w_en).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_rf #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter NREGS = 32,	/* GPRs per thread: 32 or 64 (r0..r62 at most; 63 is rq) */
	parameter REG_IO = 0	/* 1: register write port and read output (Rule 4 BRAM compliance) */
) (
	input wire clk,
	input wire rst_n,
	/* Write (from atg_su_wb) */
	input wire w_en,
	input wire [WARP_W-1:0] w_warp,
	input wire [GRP_W-1:0] w_grp,
	input wire [5:0] w_reg,
	input wire [NPHYS*32-1:0] w_data,
	input wire [NPHYS-1:0] w_lanes,
	/* Read (from atg_su_opd) */
	input wire r_en,
	input wire [WARP_W-1:0] r_warp,
	input wire [GRP_W-1:0] r_grp,
	input wire [5:0] r_reg1,
	input wire [5:0] r_reg2,
	output wire [NPHYS*32-1:0] r_data1,
	output wire [NPHYS*32-1:0] r_data2,
	/* Session protection: clear the contents */
	input wire scrub,
	output wire scrub_busy
);
	localparam G = 32 / NPHYS;	/* lane groups per warp */
	localparam DEPTH = NWARPS * NREGS * G;
	localparam A_W = $clog2(DEPTH);

	localparam NR_W = $clog2(NREGS);	/* NREGS and G are powers of two: the fields are disjoint */
	localparam G_W = $clog2(G);

	/* (w NREGS + r mod NREGS) G + g mod G, as its bit fields. */
	function [31:0] addr;
		input [WARP_W-1:0] w;
		input [5:0] r;
		input [GRP_W-1:0] g;
		addr = ({{(32-WARP_W){1'b0}}, w} << (NR_W + G_W)) | (({26'd0, r} % NREGS) << G_W) |
			({{(32-GRP_W){1'b0}}, g} % G);
	endfunction

	wire [31:0] wa32 = addr(w_warp, w_reg, w_grp);
	wire [31:0] ra1_32 = addr(r_warp, r_reg1, r_grp);
	wire [31:0] ra2_32 = addr(r_warp, r_reg2, r_grp);
	wire [A_W-1:0] wa = wa32[A_W-1:0];
	wire [A_W-1:0] ra1 = ra1_32[A_W-1:0];
	wire [A_W-1:0] ra2 = ra2_32[A_W-1:0];

	wire sc_on;
	wire [A_W-1:0] sc_a;

	atg_su_scrub #(.DEPTH(DEPTH), .AW(A_W)) sc (
		.clk(clk), .rst_n(rst_n), .start(scrub), .on(sc_on), .a(sc_a)
	);

	wire [A_W-1:0] sc_a_next;
	wire sc_co_unused;
	am_add #(.W(A_W)) u_sc_next (
		.a(sc_a), .b({A_W{1'b0}}), .ci(1'b1), .s(sc_a_next), .co(sc_co_unused)
	);

	assign scrub_busy = sc_on;
	/* The write port: the scrub's zeros or the write-back's data. */
	(* dont_touch = "true" *) wire rst_p = !rst_n;
	(* dont_touch = "true" *) wire wd_zero_all = rst_p || scrub || sc_on;
	wire [A_W-1:0] wam = sc_on ? sc_a : wa;

	(* max_fanout = 12 *) reg [NPHYS-1:0] we_r;
	(* dont_touch = "true" *) reg [A_W-1:0] wa_r1;
	(* dont_touch = "true" *) reg [A_W-1:0] wa_r2;
	wire [NPHYS*32-1:0] wd_r;

	always @(posedge clk) begin
		if (rst_p) begin
			we_r  <= {NPHYS{1'b0}};
			wa_r1 <= {A_W{1'b0}};
			wa_r2 <= {A_W{1'b0}};
		end else if (scrub) begin
			we_r  <= {NPHYS{1'b1}};
			wa_r1 <= {A_W{1'b0}};
			wa_r2 <= {A_W{1'b0}};
		end else if (sc_on) begin
			if ({{(32-A_W){1'b0}}, sc_a} == DEPTH - 1) begin
				we_r <= {NPHYS{1'b0}};
			end else begin
				we_r  <= {NPHYS{1'b1}};
				wa_r1 <= sc_a_next;
				wa_r2 <= sc_a_next;
			end
		end else begin
			we_r  <= w_en ? w_lanes : {NPHYS{1'b0}};
			wa_r1 <= wa;
			wa_r2 <= wa;
		end
	end

	/* Two copies per lane: m1 for read port 1, m2 for read port 2. Both written on write-back. */
	genvar l, glh;
	generate
		for (l = 0; l < NPHYS; l = l + 1) begin : lane
			for (glh = 0; glh < 2; glh = glh + 1) begin : g_wd_half
				(* shreg_extract = "no" *) reg [15:0] wd_h;
				(* dont_touch = "true" *) wire wd_zero_h = wd_zero_all || rst_p;
				always @(posedge clk) begin
					if (wd_zero_h)
						wd_h <= 16'd0;
					else
						wd_h <= w_data[l*32 + glh*16 +: 16];
				end
				assign wd_r[l*32 + glh*16 +: 16] = wd_h;
			end
			(* ram_style = "block" *) reg [31:0] m1 [0:DEPTH-1];
			(* ram_style = "block" *) reg [31:0] m2 [0:DEPTH-1];
			reg [31:0] q1, q2;
			(* dont_touch = "true" *) reg [31:0] q1_pipe, q2_pipe;

			wire [31:0] din = REG_IO ? wd_r[l*32 +: 32] : (sc_on ? 32'd0 : w_data[l*32 +: 32]);
			wire [A_W-1:0] waddr1 = REG_IO ? wa_r1 : wam;
			wire [A_W-1:0] waddr2 = REG_IO ? wa_r2 : wam;
			wire [A_W-1:0] ra1_l = ra1;
			wire [A_W-1:0] ra2_l = ra2;
			wire r_en_l = r_en;
			wire wea = REG_IO ? we_r[l] : (sc_on || (w_en && w_lanes[l]));

			always @(posedge clk) begin
				if (wea) begin
					m1[waddr1] <= din;
					m2[waddr2] <= din;
				end
				if (r_en_l) begin
					q1 <= m1[ra1_l];
					q2 <= m2[ra2_l];
				end
				q1_pipe <= q1;
				q2_pipe <= q2;
			end

			assign r_data1[l*32 +: 32] = REG_IO ? q1_pipe : q1;
			assign r_data2[l*32 +: 32] = REG_IO ? q2_pipe : q2;
		end
	endgenerate

	wire unused_ok = &{1'b0, wa32, ra1_32, ra2_32, sc_co_unused};
endmodule

`default_nettype wire
