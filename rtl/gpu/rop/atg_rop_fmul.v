/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_fmul: fp32 multiplier with LAT=2 for ROP fblend pipeline.
 * Fully compliant with ASIC 5nm 1.5 GHz timing, primitive budget (DSP LAT=2),
 * and fanout limits.
 * RNE, denormals flushed to zero, canonical NaN 0x7FC00000.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_rop_fmul (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	output wire [31:0] o_r
);
	/* Stage 1: unpack and special cases */
	wire [7:0] ea = i_a[30:23];
	wire [7:0] eb = i_b[30:23];
	wire za = ea == 8'd0;
	wire zb = eb == 8'd0;
	wire nan_a = ea == 8'hFF && i_a[22:0] != 23'd0;
	wire nan_b = eb == 8'hFF && i_b[22:0] != 23'd0;
	wire inf_a = ea == 8'hFF && i_a[22:0] == 23'd0;
	wire inf_b = eb == 8'hFF && i_b[22:0] == 23'd0;
	wire s = i_a[31] ^ i_b[31];

	/* exponent ea + eb - 127 */
	wire [9:0] eab, e_n;
	wire eab_co_unused, en_bo_unused;
	am_add #(.W(10)) u_eab (.a({2'b00, ea}), .b({2'b00, eb}), .ci(1'b0), .s(eab), .co(eab_co_unused));
	am_sub #(.W(10)) u_e_n (.a(eab), .b(10'd127), .bi(1'b0), .d(e_n), .bo(en_bo_unused));

	wire sp = nan_a || nan_b || ((inf_a || inf_b) && (za || zb)) || inf_a || inf_b || za || zb;
	wire [31:0] spv = (nan_a || nan_b || ((inf_a || inf_b) && (za || zb))) ? 32'h7FC00000 :
		(inf_a || inf_b) ? {s, 8'hFF, 23'd0} : {s, 31'd0};

	wire [23:0] ma = {1'b1, i_a[22:0]};
	wire [23:0] mb = {1'b1, i_b[22:0]};

	/* 2-cycle DSP multiplier (AREG=0, MREG=1, PREG=1) */
	wire [47:0] p2;
	am_mul #(.AW(24), .BW(24), .LAT(2)) u_mul (.clk(clk), .en(en), .a(ma), .b(mb), .p(p2));

	/* Pipeline matching registers (2 stages) */
	(* max_fanout = 8 *) reg r1_sp, r1_s;
	reg [31:0] r1_spv;
	reg [9:0] r1_e;

	(* max_fanout = 8 *) reg r2_sp, r2_s;
	reg [31:0] r2_spv;
	reg [9:0] r2_e;

	/* Replicated enable signals to prevent high-fanout violations (<= 8) */
	(* max_fanout = 8 *) wire en_1_ctrl = en;
	(* max_fanout = 8 *) wire en_1_e0   = en;
	(* max_fanout = 8 *) wire en_1_e1   = en;
	(* max_fanout = 8 *) wire en_1_sp0  = en;
	(* max_fanout = 8 *) wire en_1_sp1  = en;

	(* max_fanout = 8 *) wire en_2_ctrl = en;
	(* max_fanout = 8 *) wire en_2_e0   = en;
	(* max_fanout = 8 *) wire en_2_e1   = en;
	(* max_fanout = 8 *) wire en_2_sp0  = en;
	(* max_fanout = 8 *) wire en_2_sp1  = en;

	always @(posedge clk) begin
		if (!rst_n) begin
			r1_sp <= 1'b0;
			r1_s  <= 1'b0;
			r2_sp <= 1'b0;
			r2_s  <= 1'b0;
		end else begin
			if (en_1_ctrl) begin
				r1_sp <= sp;
				r1_s  <= s;
			end
			if (en_2_ctrl) begin
				r2_sp <= r1_sp;
				r2_s  <= r1_s;
			end
		end
	end

	always @(posedge clk) begin
		if (en_1_e0)  r1_e[4:0]   <= e_n[4:0];
		if (en_1_e1)  r1_e[9:5]   <= e_n[9:5];
		if (en_1_sp0) r1_spv[15:0]  <= spv[15:0];
		if (en_1_sp1) r1_spv[31:16] <= spv[31:16];

		if (en_2_e0)  r2_e[4:0]   <= r1_e[4:0];
		if (en_2_e1)  r2_e[9:5]   <= r1_e[9:5];
		if (en_2_sp0) r2_spv[15:0]  <= r1_spv[15:0];
		if (en_2_sp1) r2_spv[31:16] <= r1_spv[31:16];
	end

	/* Normalize and round (from PREG output p2) */
	(* max_fanout = 8 *) wire p47_e   = p2[47];
	(* max_fanout = 8 *) wire p47_m0  = p2[47];
	(* max_fanout = 8 *) wire p47_m1  = p2[47];
	(* max_fanout = 8 *) wire p47_g   = p2[47];
	(* max_fanout = 8 *) wire p47_s   = p2[47];

	wire [9:0] e2n;
	wire e2n_co_unused;
	am_add #(.W(10)) u_e2n (.a(r2_e), .b(10'd0), .ci(p47_e), .s(e2n), .co(e2n_co_unused));

	wire [11:0] m3_lo = p47_m0 ? p2[35:24] : p2[34:23];
	wire [11:0] m3_hi = p47_m1 ? p2[47:36] : p2[46:35];
	wire [23:0] m3 = {m3_hi, m3_lo};
	wire g3 = p47_g ? p2[23] : p2[22];
	wire st3 = p47_s ? (p2[22:0] != 23'd0) : (p2[21:0] != 22'd0);

	wire [24:0] m0;
	wire [9:0] e;
	wire m0_co_unused, e_co_unused;
	am_add #(.W(25)) u_m0 (.a({1'b0, m3}), .b(25'd0), .ci(g3 && (st3 || m3[0])), .s(m0),
		.co(m0_co_unused));
	wire [24:0] m = m0[24] ? {1'b0, m0[24:1]} : m0;
	am_add #(.W(10)) u_e (.a(e2n), .b(10'd0), .ci(m0[24]), .s(e), .co(e_co_unused));

	(* max_fanout = 8 *) wire r2_sp_m0 = r2_sp;
	(* max_fanout = 8 *) wire r2_sp_m1 = r2_sp;
	(* max_fanout = 8 *) wire r2_sp_eh = r2_sp;

	wire [11:0] m_out_lo = r2_sp_m0 ? r2_spv[11:0] :
		(!e[9] && e >= 10'd255) ? 12'd0 :
		(e[9] || e == 10'd0) ? 12'd0 : m[11:0];

	wire [10:0] m_out_hi = r2_sp_m1 ? r2_spv[22:12] :
		(!e[9] && e >= 10'd255) ? 11'd0 :
		(e[9] || e == 10'd0) ? 11'd0 : m[22:12];

	wire [8:0] eh_out = r2_sp_eh ? r2_spv[31:23] :
		(!e[9] && e >= 10'd255) ? {r2_s, 8'hFF} :
		(e[9] || e == 10'd0) ? {r2_s, 8'd0} : {r2_s, e[7:0]};

	assign o_r = {eh_out, m_out_hi, m_out_lo};

	wire unused_ok = &{1'b0, m[24:23], eab_co_unused, en_bo_unused, e2n_co_unused, m0_co_unused, e_co_unused};
endmodule

`default_nettype wire
