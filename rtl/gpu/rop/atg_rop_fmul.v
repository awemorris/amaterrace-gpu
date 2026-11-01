/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_fmul: fp32 multiplier with LAT=4 for ROP fblend pipeline.
 * Fully compliant with ASIC 5nm 1.5 GHz timing, primitive budget (DSP LAT=2,
 * Pre-DSP LUTs = 0, Post-DSP LUTs = 0, <= 3 LUT levels/stage), and fanout limits.
 * RNE, denormals flushed to zero, canonical NaN 0x7FC00000.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_rop_fmul #(
	parameter integer LAT = 4
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	output wire [31:0] o_r
);
	(* keep = "true" *) wire rst_sync = !rst_n;
	wire en_s1_a   = en;
	wire en_s1_b   = en;
	wire en_s1_mul = en;
	wire en_s1b_a = en;
	wire en_s1b_b = en;
	wire en_s2_a  = en;
	wire en_s2_b  = en;
	wire en_s2_c  = en;
	wire en_s2_d  = en;
	wire en_s2_e  = en;
	wire en_s2_f  = en;
	wire en_s3_a  = en;
	wire en_s3_b  = en;
	wire en_s3_c  = en;
	wire en_s3_d  = en;
	wire en_s4_a  = en;
	wire en_s4_b  = en;

	/* =========================================================================
	 * Stage 1: Unpack, exponent ea + eb - 127 (single CARRY4, Pre=1, Post=0),
	 * and launch 2-cycle DSP multiplier (Pre-DSP LUTs = 0).
	 * ========================================================================= */
	wire [7:0] ea = i_a[30:23];
	wire [7:0] eb = i_b[30:23];
	(* keep = "true" *) wire [3:0] a_mnz, b_mnz;
	assign a_mnz[0] = (i_a[5:0]   != 6'd0);
	assign a_mnz[1] = (i_a[11:6]  != 6'd0);
	assign a_mnz[2] = (i_a[17:12] != 6'd0);
	assign a_mnz[3] = (i_a[22:18] != 5'd0);
	assign b_mnz[0] = (i_b[5:0]   != 6'd0);
	assign b_mnz[1] = (i_b[11:6]  != 6'd0);
	assign b_mnz[2] = (i_b[17:12] != 6'd0);
	assign b_mnz[3] = (i_b[22:18] != 5'd0);

	wire ea_zero = (ea[7:4] == 4'd0) && (ea[3:0] == 4'd0);
	wire eb_zero = (eb[7:4] == 4'd0) && (eb[3:0] == 4'd0);
	wire ea_ff   = (&ea[7:4]) && (&ea[3:0]);
	wire eb_ff   = (&eb[7:4]) && (&eb[3:0]);
	wire a_m_nz  = |a_mnz;
	wire b_m_nz  = |b_mnz;
	wire s1_w    = i_a[31] ^ i_b[31];

	/* ea + eb - 127 = {2'b00, ea} + {~eb[7], ~eb[7], ~eb[7], eb[6:0]} + 1'b1 */
	wire [9:0] e_n;
	wire en_co_unused;
	am_add #(.W(10)) u_e_n (
		.a({2'b00, ea}),
		.b({~eb[7], ~eb[7], ~eb[7], eb[6:0]}),
		.ci(1'b1),
		.s(e_n),
		.co(en_co_unused)
	);

	wire [23:0] ma = {1'b1, i_a[22:0]};
	wire [23:0] mb = {1'b1, i_b[22:0]};
	wire [47:0] p2;
	am_mul #(.AW(24), .BW(24), .LAT(2)) u_mul (
		.clk(clk), .en(en_s1_mul), .a(ma), .b(mb), .p(p2)
	);

	reg r1_ea_zero, r1_eb_zero, r1_ea_ff, r1_eb_ff, r1_a_mnz, r1_b_mnz, r1_s;
	reg [9:0] r1_e;

	reg r1b_ea_zero, r1b_eb_zero, r1b_ea_ff, r1b_eb_ff, r1b_a_mnz, r1b_b_mnz, r1b_s;
	reg [9:0] r1b_e;

	/* =========================================================================
	 * Stage 2: Register DSP product p2 directly (Post-DSP LUTs = 0),
	 * and compute pure-LUT r1b_e + 1, r1b_e + 2, and special flags (0 CARRY4s).
	 * ========================================================================= */
	wire nan2_w  = (r1b_ea_ff && r1b_a_mnz) || (r1b_eb_ff && r1b_b_mnz) ||
	               ((r1b_ea_ff || r1b_eb_ff) && (r1b_ea_zero || r1b_eb_zero));
	wire inf2_w  = !nan2_w && (r1b_ea_ff || r1b_eb_ff);
	wire zero2_w = !nan2_w && !inf2_w && (r1b_ea_zero || r1b_eb_zero);
	wire sp2_w   = nan2_w || inf2_w || zero2_w;

	/* Pure-LUT 10-bit +1 (2 LUT levels, 0 CARRY4s) */
	(* keep = "true" *) wire e1_c5 = &r1b_e[4:0];
	wire [9:0] e_p1_w;
	assign e_p1_w[0] = ~r1b_e[0];
	assign e_p1_w[1] = r1b_e[1] ^ r1b_e[0];
	assign e_p1_w[2] = r1b_e[2] ^ (&r1b_e[1:0]);
	assign e_p1_w[3] = r1b_e[3] ^ (&r1b_e[2:0]);
	assign e_p1_w[4] = r1b_e[4] ^ (&r1b_e[3:0]);
	assign e_p1_w[5] = r1b_e[5] ^ e1_c5;
	assign e_p1_w[6] = r1b_e[6] ^ (e1_c5 & r1b_e[5]);
	assign e_p1_w[7] = r1b_e[7] ^ (e1_c5 & (&r1b_e[6:5]));
	assign e_p1_w[8] = r1b_e[8] ^ (e1_c5 & (&r1b_e[7:5]));
	assign e_p1_w[9] = r1b_e[9] ^ (e1_c5 & (&r1b_e[8:5]));

	/* Pure-LUT 10-bit +2 (2 LUT levels, 0 CARRY4s) */
	(* keep = "true" *) wire e2_c5 = &r1b_e[4:1];
	wire [9:0] e_p2_w;
	assign e_p2_w[0] = r1b_e[0];
	assign e_p2_w[1] = ~r1b_e[1];
	assign e_p2_w[2] = r1b_e[2] ^ r1b_e[1];
	assign e_p2_w[3] = r1b_e[3] ^ (&r1b_e[2:1]);
	assign e_p2_w[4] = r1b_e[4] ^ (&r1b_e[3:1]);
	assign e_p2_w[5] = r1b_e[5] ^ e2_c5;
	assign e_p2_w[6] = r1b_e[6] ^ (e2_c5 & r1b_e[5]);
	assign e_p2_w[7] = r1b_e[7] ^ (e2_c5 & (&r1b_e[6:5]));
	assign e_p2_w[8] = r1b_e[8] ^ (e2_c5 & (&r1b_e[7:5]));
	assign e_p2_w[9] = r1b_e[9] ^ (e2_c5 & (&r1b_e[8:5]));

	reg r2_nan, r2_inf, r2_sp, r2_s;
	reg [9:0] r2_e, r2_e_p1, r2_e_p2;
	reg [47:0] r2_p;
	(* equivalent_register_removal = "no", max_fanout = 12 *) reg r2_p47_a, r2_p47_b, r2_p47_c;

	/* =========================================================================
	 * Stage 3: Normalize shift, RNE round bit, mantissa group propagates,
	 * and precomputed exponent overflow/underflow flags (<= 3 LUT levels).
	 * ========================================================================= */
	wire [11:0] m3_lo = r2_p47_a ? r2_p[35:24] : r2_p[34:23];
	wire [10:0] m3_hi = r2_p47_b ? r2_p[46:36] : r2_p[45:35];
	wire [22:0] m3    = {m3_hi, m3_lo};
	wire g3           = r2_p47_c ? r2_p[23] : r2_p[22];

	(* keep = "true" *) wire [3:0] st_chunk;
	assign st_chunk[0] = (r2_p[5:0]   != 6'd0);
	assign st_chunk[1] = (r2_p[11:6]  != 6'd0);
	assign st_chunk[2] = (r2_p[17:12] != 6'd0);
	assign st_chunk[3] = (r2_p[21:18] != 4'd0) || (r2_p47_c && r2_p[22]);
	wire st3           = |st_chunk;
	wire round_ci_w    = g3 && (st3 || m3[0]);

	(* keep = "true" *) wire m3_and0_w = &m3[5:0];
	(* keep = "true" *) wire m3_and1_w = &m3[11:6];
	(* keep = "true" *) wire m3_and2_w = &m3[17:12];
	(* keep = "true" *) wire m3_and3_w = &m3[22:18];
	wire m3_all_ones_w = m3_and0_w & m3_and1_w & m3_and2_w & m3_and3_w;

	wire [7:0] e_base_w = r2_p47_c ? r2_e_p1[7:0] : r2_e[7:0];
	wire [7:0] e_inc_w  = r2_p47_c ? r2_e_p2[7:0] : r2_e_p1[7:0];

	(* keep = "true" *) wire e0_ff = (&r2_e[7:4])    && (&r2_e[3:0]);
	(* keep = "true" *) wire e1_ff = (&r2_e_p1[7:4]) && (&r2_e_p1[3:0]);
	(* keep = "true" *) wire e2_ff = (&r2_e_p2[7:4]) && (&r2_e_p2[3:0]);
	(* keep = "true" *) wire e0_z  = (r2_e[7:4]    == 4'd0) && (r2_e[3:0]    == 4'd0);
	(* keep = "true" *) wire e1_z  = (r2_e_p1[7:4] == 4'd0) && (r2_e_p1[3:0] == 4'd0);
	(* keep = "true" *) wire e2_z  = (r2_e_p2[7:4] == 4'd0) && (r2_e_p2[3:0] == 4'd0);

	wire ovf0 = !r2_e[9]    && (r2_e[8]    || e0_ff);
	wire ovf1 = !r2_e_p1[9] && (r2_e_p1[8] || e1_ff);
	wire ovf2 = !r2_e_p2[9] && (r2_e_p2[8] || e2_ff);
	wire udf0 = r2_e[9]    || (!r2_e[8]    && e0_z);
	wire udf1 = r2_e_p1[9] || (!r2_e_p1[8] && e1_z);
	wire udf2 = r2_e_p2[9] || (!r2_e_p2[8] && e2_z);

	wire base_ovf_w = r2_p47_c ? ovf1 : ovf0;
	wire inc_ovf_w  = r2_p47_c ? ovf2 : ovf1;
	wire base_udf_w = r2_p47_c ? udf1 : udf0;
	wire inc_udf_w  = r2_p47_c ? udf2 : udf1;

	reg r3_nan, r3_inf, r3_sp, r3_s;
	reg r3_m3_and0, r3_m3_and1, r3_m3_and2, r3_m3_all_ones;
	(* equivalent_register_removal = "no", max_fanout = 12 *) reg r3_rci_a, r3_rci_b;
	reg r3_base_ovf, r3_inc_ovf, r3_base_udf, r3_inc_udf;
	reg [7:0] r3_e_base, r3_e_inc;
	reg [22:0] r3_m3;

	/* =========================================================================
	 * Stage 4: Pure-LUT 23-bit mantissa increment + pack + output register
	 * (0 CARRY4s, <= 3 LUT levels).
	 * ========================================================================= */
	(* keep = "true" *) wire c6  = r3_rci_a & r3_m3_and0;
	(* keep = "true" *) wire c12 = r3_rci_a & r3_m3_and0 & r3_m3_and1;
	(* keep = "true" *) wire c18 = r3_rci_b & r3_m3_and0 & r3_m3_and1 & r3_m3_and2;

	wire [22:0] m_inc;
	assign m_inc[0]  = r3_m3[0]  ^ r3_rci_a;
	assign m_inc[1]  = r3_m3[1]  ^ (r3_rci_a & r3_m3[0]);
	assign m_inc[2]  = r3_m3[2]  ^ (r3_rci_a & (&r3_m3[1:0]));
	assign m_inc[3]  = r3_m3[3]  ^ (r3_rci_a & (&r3_m3[2:0]));
	assign m_inc[4]  = r3_m3[4]  ^ (r3_rci_a & (&r3_m3[3:0]));
	assign m_inc[5]  = r3_m3[5]  ^ (r3_rci_a & (&r3_m3[4:0]));

	assign m_inc[6]  = r3_m3[6]  ^ c6;
	assign m_inc[7]  = r3_m3[7]  ^ (c6 & r3_m3[6]);
	assign m_inc[8]  = r3_m3[8]  ^ (c6 & (&r3_m3[7:6]));
	assign m_inc[9]  = r3_m3[9]  ^ (c6 & (&r3_m3[8:6]));
	assign m_inc[10] = r3_m3[10] ^ (c6 & (&r3_m3[9:6]));
	assign m_inc[11] = r3_m3[11] ^ (c6 & (&r3_m3[10:6]));

	assign m_inc[12] = r3_m3[12] ^ c12;
	assign m_inc[13] = r3_m3[13] ^ (c12 & r3_m3[12]);
	assign m_inc[14] = r3_m3[14] ^ (c12 & (&r3_m3[13:12]));
	assign m_inc[15] = r3_m3[15] ^ (c12 & (&r3_m3[14:12]));
	assign m_inc[16] = r3_m3[16] ^ (c12 & (&r3_m3[15:12]));
	assign m_inc[17] = r3_m3[17] ^ (c12 & (&r3_m3[16:12]));

	assign m_inc[18] = r3_m3[18] ^ c18;
	assign m_inc[19] = r3_m3[19] ^ (c18 & r3_m3[18]);
	assign m_inc[20] = r3_m3[20] ^ (c18 & (&r3_m3[19:18]));
	assign m_inc[21] = r3_m3[21] ^ (c18 & (&r3_m3[20:18]));
	assign m_inc[22] = r3_m3[22] ^ (c18 & (&r3_m3[21:18]));

	(* keep = "true" *) wire m_ovf = r3_m3_all_ones && r3_rci_b;
	(* keep = "true" *) wire force_mz_a = r3_sp || (m_ovf ? (r3_inc_ovf || r3_inc_udf) : (r3_base_ovf || r3_base_udf));
	(* keep = "true" *) wire force_mz_b = r3_sp || (m_ovf ? (r3_inc_ovf || r3_inc_udf) : (r3_base_ovf || r3_base_udf));
	(* keep = "true" *) wire force_eff  = r3_nan || r3_inf || (!r3_sp && (m_ovf ? r3_inc_ovf : r3_base_ovf));
	(* keep = "true" *) wire force_ez   = !force_eff && (r3_sp || (m_ovf ? r3_inc_udf : r3_base_udf));

	wire [22:0] m_out;
	assign m_out[11:0]  = force_mz_a ? 12'd0 : m_inc[11:0];
	assign m_out[21:12] = force_mz_b ? 10'd0 : m_inc[21:12];
	assign m_out[22]    = r3_nan || (!force_mz_b && m_inc[22]);

	wire [7:0] e_out = force_eff ? 8'hFF :
	                   force_ez  ? 8'd0  :
	                   (m_ovf ? r3_e_inc : r3_e_base);
	wire s_out = !r3_nan && r3_s;
	wire [31:0] r4_w = {s_out, e_out, m_out};

	(* max_fanout = 16 *) reg [31:0] r4_out;

	always @(posedge clk) begin
		if (rst_sync) begin
			r1_ea_zero  <= 1'b0;
			r1_eb_zero  <= 1'b0;
			r1_ea_ff    <= 1'b0;
			r1_eb_ff    <= 1'b0;
			r1_a_mnz    <= 1'b0;
			r1_b_mnz    <= 1'b0;
			r1_s        <= 1'b0;
			r1b_ea_zero <= 1'b0;
			r1b_eb_zero <= 1'b0;
			r1b_ea_ff   <= 1'b0;
			r1b_eb_ff   <= 1'b0;
			r1b_a_mnz   <= 1'b0;
			r1b_b_mnz   <= 1'b0;
			r1b_s       <= 1'b0;
			r2_nan      <= 1'b0;
			r2_inf      <= 1'b0;
			r2_sp       <= 1'b0;
			r2_s        <= 1'b0;
			r3_nan      <= 1'b0;
			r3_inf      <= 1'b0;
			r3_sp       <= 1'b0;
			r3_s        <= 1'b0;
		end else begin
			if (en_s1_a) begin
				r1_ea_zero <= ea_zero;
				r1_eb_zero <= eb_zero;
				r1_ea_ff   <= ea_ff;
				r1_eb_ff   <= eb_ff;
				r1_a_mnz   <= a_m_nz;
				r1_b_mnz   <= b_m_nz;
				r1_s       <= s1_w;
			end
			if (en_s1b_a) begin
				r1b_ea_zero <= r1_ea_zero;
				r1b_eb_zero <= r1_eb_zero;
				r1b_ea_ff   <= r1_ea_ff;
				r1b_eb_ff   <= r1_eb_ff;
				r1b_a_mnz   <= r1_a_mnz;
				r1b_b_mnz   <= r1_b_mnz;
				r1b_s       <= r1_s;
			end
			if (en_s2_a) begin
				r2_nan <= nan2_w;
				r2_inf <= inf2_w;
				r2_sp  <= sp2_w;
				r2_s   <= r1b_s;
			end
			if (en_s3_a) begin
				r3_nan <= r2_nan;
				r3_inf <= r2_inf;
				r3_sp  <= r2_sp;
				r3_s   <= r2_s;
			end
		end
		if (en_s4_a) r4_out[15:0]  <= r4_w[15:0];
		if (en_s4_b) r4_out[31:16] <= r4_w[31:16];
		if (en_s1_b)
			r1_e <= e_n;
		if (en_s1b_b)
			r1b_e <= r1_e;
		if (en_s2_a) r2_e    <= r1b_e;
		if (en_s2_b) r2_e_p1 <= e_p1_w;
		if (en_s2_b) r2_e_p2 <= e_p2_w;
		if (en_s2_c) r2_p[11:0]  <= p2[11:0];
		if (en_s2_d) r2_p[23:12] <= p2[23:12];
		if (en_s2_e) r2_p[35:24] <= p2[35:24];
		if (en_s2_f) begin
			r2_p[47:36] <= p2[47:36];
			r2_p47_a    <= p2[47];
			r2_p47_b    <= p2[47];
			r2_p47_c    <= p2[47];
		end
		if (en_s3_a) begin
			r3_m3_and0     <= m3_and0_w;
			r3_m3_and1     <= m3_and1_w;
			r3_m3_and2     <= m3_and2_w;
			r3_m3_all_ones <= m3_all_ones_w;
			r3_rci_a       <= round_ci_w;
			r3_rci_b       <= round_ci_w;
			r3_base_ovf    <= base_ovf_w;
			r3_inc_ovf     <= inc_ovf_w;
			r3_base_udf    <= base_udf_w;
			r3_inc_udf     <= inc_udf_w;
		end
		if (en_s3_b) begin
			r3_e_base <= e_base_w;
			r3_e_inc  <= e_inc_w;
		end
		if (en_s3_c) r3_m3[11:0]  <= m3[11:0];
		if (en_s3_d) r3_m3[22:12] <= m3[22:12];
	end

	assign o_r = r4_out;

	wire unused_ok = &{1'b0, en_co_unused, LAT[31:0]};
endmodule

`default_nettype wire
