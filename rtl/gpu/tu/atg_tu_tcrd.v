/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_tcrd: a lane's texel coordinates with 8 fraction bits for
 * atg_tu_addr's stage A: (the normalized coordinate's atg_tu_coord) ×
 * size >> 16, a cube's face coordinate × the face size >> 16, or an
 * unnormalized coordinate's floor(x × 256) (atg_tu_unnorm).
 *
 * Latency:
 * - LAT = 0: combinational
 * - LAT = 1: 1 cycle pipeline register in input + 1 cycle in multiplier (total 2 cycles)
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_tcrd #(
	parameter LAT = 1
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [31:0] cw0,	/* the lane's u, v and w (r) words */
	input wire [31:0] cw1,
	input wire [31:0] cw4,
	input wire [1:0] mu,
	input wire [1:0] mv,
	input wire [1:0] mw,
	input wire [15:0] wl,
	input wire [15:0] hl,
	input wire [15:0] dl,
	input wire signed [26:0] fcs,	/* a cube's face coordinates */
	input wire signed [26:0] fct,
	input wire cube,
	input wire unn,
	output wire signed [30:0] cu,
	output wire signed [30:0] cv,
	output wire signed [30:0] cw
);
	wire signed [29:0] nu, nv, nw, un0, un1;
	wire signed [46:0] pu, pv, pw;
	wire signed [43:0] qu, qv;
	atg_tu_coord #(.LAT(LAT)) u_nu (.clk(clk), .rst_n(rst_n), .en(en), .f(cw0), .mode(mu), .c(nu));
	atg_tu_coord #(.LAT(LAT)) u_nv (.clk(clk), .rst_n(rst_n), .en(en), .f(cw1), .mode(mv), .c(nv));
	atg_tu_coord #(.LAT(LAT)) u_nw (.clk(clk), .rst_n(rst_n), .en(en), .f(cw4), .mode(mw), .c(nw));
	atg_tu_unnorm #(.LAT(LAT)) u_un0 (.clk(clk), .rst_n(rst_n), .en(en), .f(cw0), .c(un0));
	atg_tu_unnorm #(.LAT(LAT)) u_un1 (.clk(clk), .rst_n(rst_n), .en(en), .f(cw1), .c(un1));

	/* LAT >= 1 pipeline registers */
	reg signed [29:0] r_nu, r_nv, r_nw;
	reg signed [29:0] r_un0, r_un1;
	reg signed [26:0] r_fcs, r_fct;
	reg r_cube, r_unn;
	reg r_cube_d, r_unn_d;

	always @(posedge clk) begin
		if (!rst_n) begin
			r_nu    <= 30'sd0;
			r_nv    <= 30'sd0;
			r_nw    <= 30'sd0;
			r_un0   <= 30'sd0;
			r_un1   <= 30'sd0;
			r_fcs   <= 27'sd0;
			r_fct   <= 27'sd0;
			r_cube  <= 1'b0;
			r_unn   <= 1'b0;
			r_cube_d <= 1'b0;
			r_unn_d  <= 1'b0;
		end else if (en) begin
			r_nu    <= nu;
			r_nv    <= nv;
			r_nw    <= nw;
			r_un0   <= un0;
			r_un1   <= un1;
			r_fcs   <= fcs;
			r_fct   <= fct;
			r_cube  <= cube;
			r_unn   <= unn;
			r_cube_d <= r_cube;
			r_unn_d  <= r_unn;
		end
	end

	wire signed [29:0] in_nu  = (LAT >= 1) ? r_nu : nu;
	wire signed [29:0] in_nv  = (LAT >= 1) ? r_nv : nv;
	wire signed [29:0] in_nw  = (LAT >= 1) ? r_nw : nw;
	wire signed [26:0] in_fcs = (LAT >= 1) ? r_fcs : fcs;
	wire signed [26:0] in_fct = (LAT >= 1) ? r_fct : fct;
	wire signed [29:0] un0_val = (LAT >= 1) ? r_un0 : un0;
	wire signed [29:0] un1_val = (LAT >= 1) ? r_un1 : un1;
	wire final_cube            = (LAT >= 1) ? r_cube_d : cube;
	wire final_unn             = (LAT >= 1) ? r_unn_d  : unn;

	wire mclk = (LAT >= 1) ? clk : 1'b0;
	localparam MLAT = (LAT >= 1) ? 1 : 0;

	am_mul #(.AW(30), .BW(17), .SIGNED(1), .LAT(MLAT)) u_pu (.clk(mclk), .en(en), .a(in_nu), .b({1'b0, wl}),
		.p(pu));
	am_mul #(.AW(30), .BW(17), .SIGNED(1), .LAT(MLAT)) u_pv (.clk(mclk), .en(en), .a(in_nv), .b({1'b0, hl}),
		.p(pv));
	am_mul #(.AW(30), .BW(17), .SIGNED(1), .LAT(MLAT)) u_pw (.clk(mclk), .en(en), .a(in_nw), .b({1'b0, dl}),
		.p(pw));
	am_mul #(.AW(27), .BW(17), .SIGNED(1), .LAT(MLAT)) u_qu (.clk(mclk), .en(en), .a(in_fcs), .b({1'b0, wl}),
		.p(qu));
	am_mul #(.AW(27), .BW(17), .SIGNED(1), .LAT(MLAT)) u_qv (.clk(mclk), .en(en), .a(in_fct), .b({1'b0, wl}),
		.p(qv));
	assign cu = final_cube ? {{3{qu[43]}}, qu[43:16]} : final_unn ? {un0_val[29], un0_val} : pu[46:16];
	assign cv = final_cube ? {{3{qv[43]}}, qv[43:16]} : final_unn ? {un1_val[29], un1_val} : pv[46:16];
	assign cw = pw[46:16];

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, rst_n, en} : 1'b0;
	wire unused_ok = &{1'b0, pu[15:0], pv[15:0], pw[15:0], qu[15:0], qv[15:0], unused_lat0};
endmodule

`default_nettype wire
