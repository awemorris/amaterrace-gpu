/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_fmul: fp32 multiplier with configurable latency (LAT = 0 or 4) for RX.
 * RNE, denormals flushed, canonical NaN 0x7FC00000.
 * Compliant with ASIC 5nm 1.5 GHz timing, primitive budget (<= 1 Post-DSP LUT,
 * <= 1 Post-CARRY4 LUT, <= 3 random LUT levels), and fanout (<= 16) limits.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_rx_fmul #(
	parameter LAT = 4
) (
	input wire clk,
	input wire rst_n,
	input wire i_valid,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	output wire o_valid,
	output wire [31:0] o_r
);
	/* Stage 1: unpack, special cases, and ea + eb (0 Pre-LUTs, 0 Post-LUTs). */
	wire [7:0] ea = i_a[30:23];
	wire [7:0] eb = i_b[30:23];
	wire za = ea == 8'd0;
	wire zb = eb == 8'd0;
	wire nan_a = ea == 8'hFF && i_a[22:0] != 23'd0;
	wire nan_b = eb == 8'hFF && i_b[22:0] != 23'd0;
	wire inf_a = ea == 8'hFF && i_a[22:0] == 23'd0;
	wire inf_b = eb == 8'hFF && i_b[22:0] == 23'd0;
	wire s = i_a[31] ^ i_b[31];

	wire [9:0] eab;
	wire eab_co_unused;
	am_add #(.W(10)) u_eab (.a({2'b00, ea}), .b({2'b00, eb}), .ci(1'b0), .s(eab), .co(eab_co_unused));

	wire v1_w = rst_n && i_valid;
	wire sp_nan1_w = nan_a || nan_b || ((inf_a || inf_b) && (za || zb));
	wire sp_inf1_w = !sp_nan1_w && (inf_a || inf_b);
	wire sp_zero1_w = !sp_nan1_w && !sp_inf1_w && (za || zb);
	wire sp1_w = sp_nan1_w || sp_inf1_w || sp_zero1_w;
	wire s1_w = sp_nan1_w ? 1'b0 : s;
	wire [9:0] eab1_w = eab;
	wire [23:0] ma1_w = {1'b1, i_a[22:0]};
	wire [23:0] mb1_w = {1'b1, i_b[22:0]};

	wire v1, sp1, sp_nan1, sp_inf1, s1;
	wire [9:0] eab1;
	wire [23:0] ma1, mb1;

	/* Stage 2: precompute eab - 127, eab - 126, eab - 125 (0 Post-LUTs after CARRY4). */
	wire [9:0] e2_0_w, e2_1_w, e2_2_w;
	wire e2_0_bo_unused, e2_1_bo_unused, e2_2_bo_unused;
	am_sub #(.W(10)) u_e2_0 (.a(eab1), .b(10'd127), .bi(1'b0), .d(e2_0_w), .bo(e2_0_bo_unused));
	am_sub #(.W(10)) u_e2_1 (.a(eab1), .b(10'd126), .bi(1'b0), .d(e2_1_w), .bo(e2_1_bo_unused));
	am_sub #(.W(10)) u_e2_2 (.a(eab1), .b(10'd125), .bi(1'b0), .d(e2_2_w), .bo(e2_2_bo_unused));

	wire v2, sp2, sp_nan2, sp_inf2, s2;
	wire [9:0] e2_0, e2_1, e2_2;
	wire [47:0] p2;

	/* Stage 3:
	 * - From DSP output p2: <= 1 Post-DSP LUT, p2[47] fanout = 11 (<= 16 soft limit).
	 * - From registered e2_0/1/2: pre-decode final exponents ef_0/1/2 and mantissa-zero flags.
	 */
	wire [5:0] m3_lo_w = p2[47] ? p2[29:24] : p2[28:23];
	wire g3_w = p2[47] ? p2[23] : p2[22];
	wire [3:0] st_c_w;
	assign st_c_w[0] = |p2[5:0];
	assign st_c_w[1] = |p2[11:6];
	assign st_c_w[2] = |p2[17:12];
	assign st_c_w[3] = p2[47] ? (|p2[22:18]) : (|p2[21:18]);

	wire ga6_0_w  = &p2[34:29];
	wire ga6_1_w  = &p2[35:30];
	wire ga12_0_w = &p2[40:35];
	wire ga12_1_w = &p2[41:36];
	wire ga18_0_w = &p2[45:41];
	wire ga18_1_w = &p2[46:42];

	wire ovf3_0 = !e2_0[9] && (e2_0[8] || (&e2_0[7:0]));
	wire udf3_0 = e2_0[9] || (e2_0[8:0] == 9'd0);
	wire ovf3_1 = !e2_1[9] && (e2_1[8] || (&e2_1[7:0]));
	wire udf3_1 = e2_1[9] || (e2_1[8:0] == 9'd0);
	wire ovf3_2 = !e2_2[9] && (e2_2[8] || (&e2_2[7:0]));
	wire udf3_2 = e2_2[9] || (e2_2[8:0] == 9'd0);

	wire [7:0] ef3_0_w = (sp_nan2 || sp_inf2 || (!sp2 && ovf3_0)) ? 8'hFF :
		(sp2 || udf3_0) ? 8'h00 : e2_0[7:0];
	wire [7:0] ef3_1_w = (sp_nan2 || sp_inf2 || (!sp2 && ovf3_1)) ? 8'hFF :
		(sp2 || udf3_1) ? 8'h00 : e2_1[7:0];
	wire [7:0] ef3_2_w = (sp_nan2 || sp_inf2 || (!sp2 && ovf3_2)) ? 8'hFF :
		(sp2 || udf3_2) ? 8'h00 : e2_2[7:0];

	wire mz3_0_w = sp2 || ovf3_0 || udf3_0;
	wire mz3_1_w = sp2 || ovf3_1 || udf3_1;

	wire v3, sp_nan3, s3, g3;
	wire p47_a, p47_b, p47_c;
	wire [5:0] m3_lo;
	wire [46:29] p3_hi;
	wire [3:0] st_c3;
	wire ga6_0, ga6_1, ga12_0, ga12_1, ga18_0, ga18_1;
	wire [7:0] ef3_0, ef3_1, ef3_2;
	wire mz3_0, mz3_1;

	/* Stage 4: Rounding and packing using am_add */
	(* keep = "true" *) wire round_inc = g3 && (m3_lo[0] || (|st_c3));
	(* keep = "true" *) wire mz_a    = p47_a ? mz3_1 : mz3_0;
	(* keep = "true" *) wire mz_b    = p47_b ? mz3_1 : mz3_0;

	(* keep = "true" *) wire [22:6] mu_hi;
	genvar gi;
	generate
	for (gi = 6; gi < 15; gi = gi + 1) begin : g_mu_6_14
		assign mu_hi[gi] = p47_a ? p3_hi[gi + 24] : p3_hi[gi + 23];
	end
	for (gi = 15; gi < 23; gi = gi + 1) begin : g_mu_15_22
		assign mu_hi[gi] = p47_b ? p3_hi[gi + 24] : p3_hi[gi + 23];
	end
	endgenerate

	wire [22:0] m_rounded;
	wire m0_cout;
	am_add #(.W(23)) u_add_round (
		.a({mu_hi, m3_lo}),
		.b(23'd0),
		.ci(round_inc),
		.s(m_rounded),
		.co(m0_cout)
	);

	wire [22:0] m_out;
	generate
	for (gi = 0; gi < 12; gi = gi + 1) begin : g_mout_lo
		assign m_out[gi] = !mz_a && m_rounded[gi];
	end
	for (gi = 12; gi < 22; gi = gi + 1) begin : g_mout_hi
		assign m_out[gi] = !mz_b && m_rounded[gi];
	end
	endgenerate
	assign m_out[22] = sp_nan3 || (!mz_b && m_rounded[22]);

	wire [7:0] e_out;
	generate
	for (gi = 0; gi < 8; gi = gi + 1) begin : g_eout
		assign e_out[gi] = (p47_c && m0_cout) ? ef3_2[gi] :
		                   (p47_c ^ m0_cout)  ? ef3_1[gi] : ef3_0[gi];
	end
	endgenerate

	wire unused_m = &{1'b0, eab_co_unused, e2_0_bo_unused, e2_1_bo_unused, e2_2_bo_unused,
		ga6_0, ga6_1, ga12_0, ga12_1, ga18_0, ga18_1};

	wire o_valid_comb = rst_n && v3;
	wire [31:0] o_r_comb = {s3, e_out, m_out};

	generate
		if (LAT == 0) begin : g_lat0
			wire [47:0] p1;
			am_mul #(.AW(24), .BW(24), .LAT(0)) u_p1 (.clk(clk), .en(1'b1), .a(ma1), .b(mb1), .p(p1));

			assign v1 = i_valid;
			assign sp1 = sp1_w;
			assign sp_nan1 = sp_nan1_w;
			assign sp_inf1 = sp_inf1_w;
			assign s1 = s1_w;
			assign eab1 = eab1_w;
			assign ma1 = ma1_w;
			assign mb1 = mb1_w;

			assign v2 = v1;
			assign sp2 = sp1;
			assign sp_nan2 = sp_nan1;
			assign sp_inf2 = sp_inf1;
			assign s2 = s1;
			assign e2_0 = e2_0_w;
			assign e2_1 = e2_1_w;
			assign e2_2 = e2_2_w;
			assign p2 = p1;

			assign v3 = v2;
			assign sp_nan3 = sp_nan2;
			assign s3 = s2;
			assign g3 = g3_w;
			assign p47_a = p2[47];
			assign p47_b = p2[47];
			assign p47_c = p2[47];
			assign m3_lo = m3_lo_w;
			assign p3_hi = p2[46:29];
			assign st_c3 = st_c_w;
			assign ga6_0 = ga6_0_w;
			assign ga6_1 = ga6_1_w;
			assign ga12_0 = ga12_0_w;
			assign ga12_1 = ga12_1_w;
			assign ga18_0 = ga18_0_w;
			assign ga18_1 = ga18_1_w;
			assign ef3_0 = ef3_0_w;
			assign ef3_1 = ef3_1_w;
			assign ef3_2 = ef3_2_w;
			assign mz3_0 = mz3_0_w;
			assign mz3_1 = mz3_1_w;

			assign o_valid = o_valid_comb;
			assign o_r = o_r_comb;

			wire unused_clk = &{1'b0, clk, v1_w, unused_m};
		end else begin : g_lat4
			wire [47:0] p1;
			am_mul #(.AW(24), .BW(24), .LAT(2)) u_p1 (.clk(clk), .en(1'b1), .a(ma1_w), .b(mb1_w), .p(p1));

			reg r_v1, r_sp1, r_sp_nan1, r_sp_inf1, r_s1;
			reg [9:0] r_eab1;

			always @(posedge clk) begin
				r_v1 <= v1_w;
				r_sp1 <= sp1_w;
				r_sp_nan1 <= sp_nan1_w;
				r_sp_inf1 <= sp_inf1_w;
				r_s1 <= s1_w;
				r_eab1 <= eab1_w;
			end

			assign v1 = r_v1;
			assign sp1 = r_sp1;
			assign sp_nan1 = r_sp_nan1;
			assign sp_inf1 = r_sp_inf1;
			assign s1 = r_s1;
			assign eab1 = r_eab1;
			assign ma1 = ma1_w;
			assign mb1 = mb1_w;

			reg r_v2, r_sp2, r_sp_nan2, r_sp_inf2, r_s2;
			reg [9:0] r_e2_0, r_e2_1, r_e2_2;

			always @(posedge clk) begin
				r_v2 <= rst_n && v1;
				r_sp2 <= sp1;
				r_sp_nan2 <= sp_nan1;
				r_sp_inf2 <= sp_inf1;
				r_s2 <= s1;
				r_e2_0 <= e2_0_w;
				r_e2_1 <= e2_1_w;
				r_e2_2 <= e2_2_w;
			end

			assign v2 = r_v2;
			assign sp2 = r_sp2;
			assign sp_nan2 = r_sp_nan2;
			assign sp_inf2 = r_sp_inf2;
			assign s2 = r_s2;
			assign e2_0 = r_e2_0;
			assign e2_1 = r_e2_1;
			assign e2_2 = r_e2_2;
			assign p2 = p1;

			reg r_v3, r_sp_nan3, r_s3, r_g3;
			(* keep = "true" *) reg r_p47_a, r_p47_b, r_p47_c;
			reg [5:0] r_m3_lo;
			reg [46:29] r_p3_hi;
			reg [3:0] r_st_c3;
			reg r_ga6_0, r_ga6_1, r_ga12_0, r_ga12_1, r_ga18_0, r_ga18_1;
			reg [7:0] r_ef3_0, r_ef3_1, r_ef3_2;
			reg r_mz3_0, r_mz3_1;

			always @(posedge clk) begin
				r_v3 <= rst_n && v2;
				r_sp_nan3 <= sp_nan2;
				r_s3 <= s2;
				r_g3 <= g3_w;
				r_p47_a <= p2[47];
				r_p47_b <= p2[47];
				r_p47_c <= p2[47];
				r_m3_lo <= m3_lo_w;
				r_p3_hi <= p2[46:29];
				r_st_c3 <= st_c_w;
				r_ga6_0 <= ga6_0_w;
				r_ga6_1 <= ga6_1_w;
				r_ga12_0 <= ga12_0_w;
				r_ga12_1 <= ga12_1_w;
				r_ga18_0 <= ga18_0_w;
				r_ga18_1 <= ga18_1_w;
				r_ef3_0 <= ef3_0_w;
				r_ef3_1 <= ef3_1_w;
				r_ef3_2 <= ef3_2_w;
				r_mz3_0 <= mz3_0_w;
				r_mz3_1 <= mz3_1_w;
			end

			assign v3 = r_v3;
			assign sp_nan3 = r_sp_nan3;
			assign s3 = r_s3;
			assign g3 = r_g3;
			assign p47_a = r_p47_a;
			assign p47_b = r_p47_b;
			assign p47_c = r_p47_c;
			assign m3_lo = r_m3_lo;
			assign p3_hi = r_p3_hi;
			assign st_c3 = r_st_c3;
			assign ga6_0 = r_ga6_0;
			assign ga6_1 = r_ga6_1;
			assign ga12_0 = r_ga12_0;
			assign ga12_1 = r_ga12_1;
			assign ga18_0 = r_ga18_0;
			assign ga18_1 = r_ga18_1;
			assign ef3_0 = r_ef3_0;
			assign ef3_1 = r_ef3_1;
			assign ef3_2 = r_ef3_2;
			assign mz3_0 = r_mz3_0;
			assign mz3_1 = r_mz3_1;

			reg r_ovalid;
			(* extract_reset = "no" *) reg [31:0] r_or;

			always @(posedge clk) begin
				r_ovalid <= o_valid_comb;
				r_or <= o_r_comb;
			end

			assign o_valid = r_ovalid;
			assign o_r = r_or;

			wire unused_lat4 = &{1'b0, unused_m};
		end
	endgenerate
endmodule

`default_nettype wire
