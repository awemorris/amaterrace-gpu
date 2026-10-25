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
 * Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_tcrd (
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
	atg_tu_coord u_nu (.f(cw0), .mode(mu), .c(nu));
	atg_tu_coord u_nv (.f(cw1), .mode(mv), .c(nv));
	atg_tu_coord u_nw (.f(cw4), .mode(mw), .c(nw));
	atg_tu_unnorm u_un0 (.f(cw0), .c(un0));
	atg_tu_unnorm u_un1 (.f(cw1), .c(un1));
	am_mul #(.AW(30), .BW(17), .SIGNED(1)) u_pu (.clk(1'b0), .en(1'b1), .a(nu), .b({1'b0, wl}),
		.p(pu));
	am_mul #(.AW(30), .BW(17), .SIGNED(1)) u_pv (.clk(1'b0), .en(1'b1), .a(nv), .b({1'b0, hl}),
		.p(pv));
	am_mul #(.AW(30), .BW(17), .SIGNED(1)) u_pw (.clk(1'b0), .en(1'b1), .a(nw), .b({1'b0, dl}),
		.p(pw));
	am_mul #(.AW(27), .BW(17), .SIGNED(1)) u_qu (.clk(1'b0), .en(1'b1), .a(fcs), .b({1'b0, wl}),
		.p(qu));
	am_mul #(.AW(27), .BW(17), .SIGNED(1)) u_qv (.clk(1'b0), .en(1'b1), .a(fct), .b({1'b0, wl}),
		.p(qv));
	assign cu = cube ? {{3{qu[43]}}, qu[43:16]} : unn ? {un0[29], un0} : pu[46:16];
	assign cv = cube ? {{3{qv[43]}}, qv[43:16]} : unn ? {un1[29], un1} : pv[46:16];
	assign cw = pw[46:16];

	wire unused_ok = &{1'b0, pu[15:0], pv[15:0], pw[15:0], qu[15:0], qv[15:0]};
endmodule

`default_nettype wire
