/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_mul: an AW x BW multiplier for the DSP48E1 slices: p = a * b, both
 * signed (SIGNED = 1, two's complement) or both unsigned, the full
 * AW + BW bits.  LAT = 0 is combinational; LAT = n registers the product
 * n times (en enables every stage), so that the DSP's MREG and PREG (and
 * further registers, retimed into the cascade) can be used.  The
 * multiply is marked use_dsp, so that Vivado maps it to DSPs and not to
 * LUTs at any width; one DSP48E1 takes 25 x 18 signed bits.
 * A unit whose multiplies are not used in the same cycle shares one
 * am_mul with its operands selected in front of it.
 *
 * Under SYNTH_KINTEX7, am_mul instantiates DSP48E1 primitives directly
 * with PCOUT -> PCIN cascade across all operand widths (8x8 to 42x42).
 * No fabric adders or * inference are used under SYNTH_KINTEX7.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_mul #(
	parameter AW = 18,
	parameter BW = 18,
	parameter SIGNED = 0,
	parameter LAT = 0
) (
	input wire clk,
	input wire en,
	input wire [AW-1:0] a,
	input wire [BW-1:0] b,
	output wire [AW+BW-1:0] p
);
`ifndef SYNTH_KINTEX7
	/* Constant helper: remaining vector count after `st` 3:2 CSA reduction stages. */
	function integer csa_cnt;
		input integer n0;
		input integer st;
		integer s, n;
		begin
			n = n0;
			for (s = 0; s < st; s = s + 1)
				n = (n > 2) ? ((n / 3) * 2 + (n % 3)) : n;
			csa_cnt = n;
		end
	endfunction

	generate
	if (LAT == 0) begin : g_c
		(* use_dsp = "yes" *) wire [AW+BW-1:0] m;
		if (SIGNED != 0) begin : g_s
			assign m = $signed(a) * $signed(b);
		end else begin : g_u
			assign m = a * b;
		end
		assign p = m;
	end else if (LAT == 1 || (AW <= 8 && BW <= 8)) begin : g_r1
		(* use_dsp = "yes" *) wire [AW+BW-1:0] m;
		if (SIGNED != 0) begin : g_s
			assign m = $signed(a) * $signed(b);
		end else begin : g_u
			assign m = a * b;
		end
		reg [AW+BW-1:0] r [0:LAT-1];
		integer i;
		always @(posedge clk)
			if (en) begin
				r[0] <= m;
				for (i = 1; i < LAT; i = i + 1)
					r[i] <= r[i-1];
			end
		assign p = r[LAT-1];
`ifdef SYNTH_ASIC
	end else begin : g_csa
		localparam PW = AW + BW;
		localparam integer DO_BW = (SIGNED != 0 && AW >= 2 && BW >= 2) ? 1 : 0;
		localparam integer NROW = BW + DO_BW;
		localparam integer SPLIT_ST = (NROW <= 6) ? 1 : ((NROW <= 12) ? 2 : 3);
		localparam integer MAX_ST = 10;

		wire [NROW*PW-1:0] pp_init;
		genvar gj, gi, gst, gk, grem;

		if (DO_BW != 0) begin : g_pp_bw
			for (gj = 0; gj < BW; gj = gj + 1) begin : g_row
				wire [AW-1:0] row_bits;
				for (gi = 0; gi < AW; gi = gi + 1) begin : g_col
					wire prod = a[gi] & b[gj];
					wire inv_bit = ((gi == AW - 1) ^ (gj == BW - 1));
					assign row_bits[gi] = inv_bit ? ~prod : prod;
				end
				wire [PW-1:0] row_pad = {{(PW-AW){1'b0}}, row_bits} << gj;
				assign pp_init[gj*PW +: PW] = row_pad;
			end
			wire [PW-1:0] bw_const =
				({{(PW-1){1'b0}}, 1'b1} << (PW - 1)) +
				({{(PW-1){1'b0}}, 1'b1} << (AW - 1)) +
				({{(PW-1){1'b0}}, 1'b1} << (BW - 1));
			assign pp_init[BW*PW +: PW] = bw_const;
		end else if (SIGNED != 0) begin : g_pp_s1
			wire signed [PW-1:0] prod_s = $signed(a) * $signed(b);
			assign pp_init[0 +: PW] = prod_s;
			if (NROW > 1) begin : g_pad
				assign pp_init[PW +: (NROW-1)*PW] = {((NROW-1)*PW){1'b0}};
			end
		end else begin : g_pp_u
			for (gj = 0; gj < BW; gj = gj + 1) begin : g_row
				wire [AW-1:0] row_bits = b[gj] ? a : {AW{1'b0}};
				wire [PW-1:0] row_pad = {{(PW-AW){1'b0}}, row_bits} << gj;
				assign pp_init[gj*PW +: PW] = row_pad;
			end
		end

		if (LAT >= 3) begin : g_lat3
			localparam integer M_CNT = csa_cnt(NROW, SPLIT_ST);
			wire [NROW*PW-1:0] st1_vec [0:SPLIT_ST];
			assign st1_vec[0] = pp_init;
			for (gst = 0; gst < SPLIT_ST; gst = gst + 1) begin : g_st1
				localparam integer IN_N  = csa_cnt(NROW, gst);
				localparam integer OUT_N = csa_cnt(NROW, gst + 1);
				if (IN_N > 2) begin : g_red
					localparam integer NTRP = IN_N / 3;
					localparam integer NREM = IN_N % 3;
					for (gk = 0; gk < NTRP; gk = gk + 1) begin : g_t
						wire [PW-1:0] x0 = st1_vec[gst][(3*gk+0)*PW +: PW];
						wire [PW-1:0] x1 = st1_vec[gst][(3*gk+1)*PW +: PW];
						wire [PW-1:0] x2 = st1_vec[gst][(3*gk+2)*PW +: PW];
						wire [PW-1:0] cs_s = x0 ^ x1 ^ x2;
						wire [PW-1:0] cs_c = (x0 & x1) | (x0 & x2) | (x1 & x2);
						assign st1_vec[gst+1][(2*gk+0)*PW +: PW] = cs_s;
						assign st1_vec[gst+1][(2*gk+1)*PW +: PW] = {cs_c[PW-2:0], 1'b0};
					end
					for (grem = 0; grem < NREM; grem = grem + 1) begin : g_r
						assign st1_vec[gst+1][(2*NTRP+grem)*PW +: PW] =
							st1_vec[gst][(3*NTRP+grem)*PW +: PW];
					end
					if (OUT_N < NROW) begin : g_z
						assign st1_vec[gst+1][OUT_N*PW +: (NROW-OUT_N)*PW] =
							{((NROW-OUT_N)*PW){1'b0}};
					end
				end else begin : g_pass
					assign st1_vec[gst+1] = st1_vec[gst];
				end
			end

			reg [M_CNT*PW-1:0] st1_r;
			always @(posedge clk)
				if (en)
					st1_r <= st1_vec[SPLIT_ST][0 +: M_CNT*PW];

			wire [M_CNT*PW-1:0] st2_vec [SPLIT_ST:MAX_ST];
			assign st2_vec[SPLIT_ST] = st1_r;
			for (gst = SPLIT_ST; gst < MAX_ST; gst = gst + 1) begin : g_st2
				localparam integer IN_N  = csa_cnt(NROW, gst);
				localparam integer OUT_N = csa_cnt(NROW, gst + 1);
				if (IN_N > 2) begin : g_red
					localparam integer NTRP = IN_N / 3;
					localparam integer NREM = IN_N % 3;
					for (gk = 0; gk < NTRP; gk = gk + 1) begin : g_t
						wire [PW-1:0] x0 = st2_vec[gst][(3*gk+0)*PW +: PW];
						wire [PW-1:0] x1 = st2_vec[gst][(3*gk+1)*PW +: PW];
						wire [PW-1:0] x2 = st2_vec[gst][(3*gk+2)*PW +: PW];
						wire [PW-1:0] cs_s = x0 ^ x1 ^ x2;
						wire [PW-1:0] cs_c = (x0 & x1) | (x0 & x2) | (x1 & x2);
						assign st2_vec[gst+1][(2*gk+0)*PW +: PW] = cs_s;
						assign st2_vec[gst+1][(2*gk+1)*PW +: PW] = {cs_c[PW-2:0], 1'b0};
					end
					for (grem = 0; grem < NREM; grem = grem + 1) begin : g_r
						assign st2_vec[gst+1][(2*NTRP+grem)*PW +: PW] =
							st2_vec[gst][(3*NTRP+grem)*PW +: PW];
					end
					if (OUT_N < M_CNT) begin : g_z
						assign st2_vec[gst+1][OUT_N*PW +: (M_CNT-OUT_N)*PW] =
							{((M_CNT-OUT_N)*PW){1'b0}};
					end
				end else begin : g_pass
					assign st2_vec[gst+1] = st2_vec[gst];
				end
			end

			reg [PW-1:0] st2_s, st2_c;
			wire [PW-1:0] st2_c_in = (M_CNT >= 2) ? st2_vec[MAX_ST][PW +: PW] : {PW{1'b0}};
			wire [PW-1:0] sum_w;
			wire sum_co_unused;
			am_add #(.W(PW)) u_fin_add (.a(st2_s), .b(st2_c), .ci(1'b0), .s(sum_w), .co(sum_co_unused));
			reg [PW-1:0] r [2:LAT-1];
			integer i;
			always @(posedge clk)
				if (en) begin
					st2_s <= st2_vec[MAX_ST][0 +: PW];
					st2_c <= st2_c_in;
					r[2]  <= sum_w;
					for (i = 3; i < LAT; i = i + 1)
						r[i] <= r[i-1];
				end
			assign p = r[LAT-1];
			wire unused_l3 = &{1'b0, sum_co_unused};
		end else begin : g_lat2
			wire [NROW*PW-1:0] st_vec [0:MAX_ST];
			assign st_vec[0] = pp_init;
			for (gst = 0; gst < MAX_ST; gst = gst + 1) begin : g_st
				localparam integer IN_N  = csa_cnt(NROW, gst);
				localparam integer OUT_N = csa_cnt(NROW, gst + 1);
				if (IN_N > 2) begin : g_red
					localparam integer NTRP = IN_N / 3;
					localparam integer NREM = IN_N % 3;
					for (gk = 0; gk < NTRP; gk = gk + 1) begin : g_t
						wire [PW-1:0] x0 = st_vec[gst][(3*gk+0)*PW +: PW];
						wire [PW-1:0] x1 = st_vec[gst][(3*gk+1)*PW +: PW];
						wire [PW-1:0] x2 = st_vec[gst][(3*gk+2)*PW +: PW];
						wire [PW-1:0] cs_s = x0 ^ x1 ^ x2;
						wire [PW-1:0] cs_c = (x0 & x1) | (x0 & x2) | (x1 & x2);
						assign st_vec[gst+1][(2*gk+0)*PW +: PW] = cs_s;
						assign st_vec[gst+1][(2*gk+1)*PW +: PW] = {cs_c[PW-2:0], 1'b0};
					end
					for (grem = 0; grem < NREM; grem = grem + 1) begin : g_r
						assign st_vec[gst+1][(2*NTRP+grem)*PW +: PW] =
							st_vec[gst][(3*NTRP+grem)*PW +: PW];
					end
					if (OUT_N < NROW) begin : g_z
						assign st_vec[gst+1][OUT_N*PW +: (NROW-OUT_N)*PW] =
							{((NROW-OUT_N)*PW){1'b0}};
					end
				end else begin : g_pass
					assign st_vec[gst+1] = st_vec[gst];
				end
			end

			reg [PW-1:0] st1_s, st1_c;
			wire [PW-1:0] st1_c_in = (NROW >= 2) ? st_vec[MAX_ST][PW +: PW] : {PW{1'b0}};
			wire [PW-1:0] sum_w;
			wire sum_co_unused;
			am_add #(.W(PW)) u_fin_add (.a(st1_s), .b(st1_c), .ci(1'b0), .s(sum_w), .co(sum_co_unused));
			reg [PW-1:0] r1;
			always @(posedge clk)
				if (en) begin
					st1_s <= st_vec[MAX_ST][0 +: PW];
					st1_c <= st1_c_in;
					r1    <= sum_w;
				end
			assign p = r1;
			wire unused_l2 = &{1'b0, sum_co_unused};
		end
	end
`else
	end else begin : g_sim_lat
		(* use_dsp = "yes" *) wire [AW+BW-1:0] m;
		if (SIGNED != 0) begin : g_s
			assign m = $signed(a) * $signed(b);
		end else begin : g_u
			assign m = a * b;
		end
		reg [AW+BW-1:0] r [0:LAT-1];
		integer i;
		always @(posedge clk)
			if (en) begin
				r[0] <= m;
				for (i = 1; i < LAT; i = i + 1)
					r[i] <= r[i-1];
			end
		assign p = r[LAT-1];
	end
`endif
	endgenerate

	wire unused_ok = &{1'b0, clk, en};
`else
	localparam MAX_A = (SIGNED != 0) ? 25 : 24;
	localparam MAX_B = (SIGNED != 0) ? 18 : 17;

	localparam SWAP =
		(AW <= MAX_A && BW <= MAX_B) ? 0 :
		(AW <= MAX_B && BW <= MAX_A) ? 1 :
		(AW > MAX_A && BW <= MAX_A)  ? 1 :
		0;

	localparam XW = SWAP ? BW : AW;
	localparam YW = SWAP ? AW : BW;

	wire [XW-1:0] x_in = SWAP ? b : a;
	wire [YW-1:0] y_in = SWAP ? a : b;

	localparam NX = (XW <= MAX_A) ? 1 : ((XW + 16) / 17);
	localparam NY = (YW <= MAX_B) ? 1 : ((YW + 16) / 17);
	localparam NUM_DSP = NX * NY;
	localparam NUM_WEIGHTS = NX + NY - 1;

	/* Functions for mapping DSP index d to tile (i, j, k) */
	function integer get_k;
		input integer d_idx;
		integer count, k_v, i_v, j_v;
		begin
			count = 0;
			get_k = 0;
			for (k_v = 0; k_v < NUM_WEIGHTS; k_v = k_v + 1) begin
				for (i_v = 0; i_v < NX; i_v = i_v + 1) begin
					j_v = k_v - i_v;
					if (j_v >= 0 && j_v < NY) begin
						if (count == d_idx)
							get_k = k_v;
						count = count + 1;
					end
				end
			end
		end
	endfunction

	function integer get_i;
		input integer d_idx;
		integer count, k_v, i_v, j_v;
		begin
			count = 0;
			get_i = 0;
			for (k_v = 0; k_v < NUM_WEIGHTS; k_v = k_v + 1) begin
				for (i_v = 0; i_v < NX; i_v = i_v + 1) begin
					j_v = k_v - i_v;
					if (j_v >= 0 && j_v < NY) begin
						if (count == d_idx)
							get_i = i_v;
						count = count + 1;
					end
				end
			end
		end
	endfunction

	function integer get_j;
		input integer d_idx;
		integer count, k_v, i_v, j_v;
		begin
			count = 0;
			get_j = 0;
			for (k_v = 0; k_v < NUM_WEIGHTS; k_v = k_v + 1) begin
				for (i_v = 0; i_v < NX; i_v = i_v + 1) begin
					j_v = k_v - i_v;
					if (j_v >= 0 && j_v < NY) begin
						if (count == d_idx)
							get_j = j_v;
						count = count + 1;
					end
				end
			end
		end
	endfunction

	function is_first_of_k;
		input integer d_idx;
		begin
			if (d_idx == 0)
				is_first_of_k = 1'b1;
			else
				is_first_of_k = (get_k(d_idx) != get_k(d_idx - 1)) ? 1'b1 : 1'b0;
		end
	endfunction

	function [6:0] get_opmode;
		input integer d_idx;
		begin
			if (d_idx == 0)
				get_opmode = 7'b0000101;
			else if (is_first_of_k(d_idx))
				get_opmode = 7'b1010101;
			else
				get_opmode = 7'b0010101;
		end
	endfunction

	function integer last_dsp_of_k;
		input integer k_target;
		integer d_idx;
		begin
			last_dsp_of_k = 0;
			for (d_idx = 0; d_idx < NUM_DSP; d_idx = d_idx + 1) begin
				if (get_k(d_idx) == k_target)
					last_dsp_of_k = d_idx;
			end
		end
	endfunction

	/* verilator lint_off UNUSEDSIGNAL */
	function integer d_areg;
		input integer d_idx;
		begin
			if (LAT == 0)
				d_areg = 0;
			else if (LAT == 1 || LAT == 2)
				d_areg = (d_idx == 0) ? 0 : 1;
			else
				d_areg = (d_idx == 0) ? 1 : 2;
		end
	endfunction

	function integer d_breg;
		input integer d_idx;
		begin
			if (LAT == 0)
				d_breg = 0;
			else if (LAT == 1 || LAT == 2)
				d_breg = (d_idx == 0) ? 0 : 1;
			else
				d_breg = (d_idx == 0) ? 1 : 2;
		end
	endfunction

	function integer d_mreg;
		input integer d_idx;
		begin
			if (LAT == 0 || LAT == 1)
				d_mreg = 0;
			else
				d_mreg = 1;
		end
	endfunction

	function integer d_preg;
		input integer d_idx;
		begin
			if (LAT == 0)
				d_preg = 0;
			else
				d_preg = (d_idx == 0) ? 1 : 0;
		end
	endfunction
	/* verilator lint_on UNUSEDSIGNAL */

	/* Tile generation for X (A-port) and Y (B-port) */
	wire [29:0] dsp_a [0:NX-1];
	wire [17:0] dsp_b [0:NY-1];

	genvar gi, gj;
	generate
	for (gi = 0; gi < NX; gi = gi + 1) begin : gen_tile_x
		if (NX == 1) begin : g_x_single
			wire [29:0] ext_x = { {(30 - XW){SIGNED ? x_in[XW-1] : 1'b0}}, x_in };
			assign dsp_a[0] = ext_x;
		end else if (gi < NX - 1) begin : g_x_lower
			assign dsp_a[gi] = { 13'd0, x_in[17*gi +: 17] };
		end else begin : g_x_top
			localparam X_LAST_W = XW - 17 * (NX - 1);
			wire [X_LAST_W-1:0] x_last = x_in[XW-1 : 17*(NX-1)];
			wire [29:0] ext_last = { {(30 - X_LAST_W){SIGNED ? x_last[X_LAST_W-1] : 1'b0}}, x_last };
			assign dsp_a[gi] = ext_last;
		end
	end

	for (gj = 0; gj < NY; gj = gj + 1) begin : gen_tile_y
		if (NY == 1) begin : g_y_single
			if (YW == 18) begin : g_y_full
				assign dsp_b[0] = y_in;
			end else begin : g_y_pad
				wire [17:0] ext_y = { {(18 - YW){SIGNED ? y_in[YW-1] : 1'b0}}, y_in };
				assign dsp_b[0] = ext_y;
			end
		end else if (gj < NY - 1) begin : g_y_lower
			assign dsp_b[gj] = { 1'b0, y_in[17*gj +: 17] };
		end else begin : g_y_top
			localparam Y_LAST_W = YW - 17 * (NY - 1);
			wire [Y_LAST_W-1:0] y_last = y_in[YW-1 : 17*(NY-1)];
			wire [17:0] ext_last = { {(18 - Y_LAST_W){SIGNED ? y_last[Y_LAST_W-1] : 1'b0}}, y_last };
			assign dsp_b[gj] = ext_last;
		end
	end
	endgenerate

	/* DSP cascade chain */
	wire [47:0] dsp_p [0:NUM_DSP-1];
	wire [47:0] dsp_pcout [0:NUM_DSP-1];

	genvar gd;
	generate
	for (gd = 0; gd < NUM_DSP; gd = gd + 1) begin : gen_dsp
		localparam integer I_VAL = get_i(gd);
		localparam integer J_VAL = get_j(gd);
		localparam integer AREG_VAL = d_areg(gd);
		localparam integer BREG_VAL = d_breg(gd);
		localparam integer MREG_VAL = d_mreg(gd);
		localparam integer PREG_VAL = d_preg(gd);
		localparam [6:0] OPMODE_VAL = get_opmode(gd);

		wire ce_a1 = (AREG_VAL > 1) ? en : 1'b0;
		wire ce_a2 = (AREG_VAL > 0) ? en : 1'b0;
		wire ce_b1 = (BREG_VAL > 1) ? en : 1'b0;
		wire ce_b2 = (BREG_VAL > 0) ? en : 1'b0;
		wire ce_m = (MREG_VAL > 0) ? en : 1'b0;
		wire ce_p = (PREG_VAL > 0) ? en : 1'b0;

		wire [47:0] pcin_in;
		if (gd == 0) begin : g_pcin_0
			assign pcin_in = 48'd0;
		end else begin : g_pcin_casc
			assign pcin_in = dsp_pcout[gd-1];
		end

		/* verilator lint_off PINCONNECTEMPTY */
		DSP48E1 #(
			.USE_MULT("MULTIPLY"),
			.USE_SIMD("ONE48"),
			.AUTORESET_PATDET("NO_RESET"),
			.A_INPUT("DIRECT"),
			.B_INPUT("DIRECT"),
			.USE_DPORT("FALSE"),
			.USE_PATTERN_DETECT("NO_PATDET"),
			.ACASCREG(AREG_VAL),
			.BCASCREG(BREG_VAL),
			.ALUMODEREG(0),
			.INMODEREG(0),
			.OPMODEREG(0),
			.CARRYINREG(0),
			.CARRYINSELREG(0),
			.CREG(0),
			.DREG(0),
			.ADREG(0),
			.AREG(AREG_VAL),
			.BREG(BREG_VAL),
			.MREG(MREG_VAL),
			.PREG(PREG_VAL)
		) u_dsp (
			.ACOUT(),
			.BCOUT(),
			.CARRYCASCOUT(),
			.CARRYOUT(),
			.MULTSIGNOUT(),
			.OVERFLOW(),
			.P(dsp_p[gd]),
			.PATTERNBDETECT(),
			.PATTERNDETECT(),
			.PCOUT(dsp_pcout[gd]),
			.UNDERFLOW(),
			.A(dsp_a[I_VAL]),
			.ACIN(30'd0),
			.ALUMODE(4'b0000),
			.B(dsp_b[J_VAL]),
			.BCIN(18'd0),
			.C(48'd0),
			.CARRYCASCIN(1'b0),
			.CARRYIN(1'b0),
			.CARRYINSEL(3'b000),
			.CEA1(ce_a1),
			.CEA2(ce_a2),
			.CEAD(1'b0),
			.CEALUMODE(1'b0),
			.CEB1(ce_b1),
			.CEB2(ce_b2),
			.CEC(1'b0),
			.CECARRYIN(1'b0),
			.CECTRL(1'b0),
			.CED(1'b0),
			.CEINMODE(1'b0),
			.CEM(ce_m),
			.CEP(ce_p),
			.CLK(clk),
			.D(25'd0),
			.INMODE(5'b00000),
			.MULTSIGNIN(1'b0),
			.OPMODE(OPMODE_VAL),
			.PCIN(pcin_in),
			.RSTA(1'b0),
			.RSTALLCARRYIN(1'b0),
			.RSTALUMODE(1'b0),
			.RSTB(1'b0),
			.RSTC(1'b0),
			.RSTCTRL(1'b0),
			.RSTD(1'b0),
			.RSTINMODE(1'b0),
			.RSTM(1'b0),
			.RSTP(1'b0)
		);
		/* verilator lint_on PINCONNECTEMPTY */
	end
	endgenerate

	/* Combinational output product reconstruction from cascade weights */
	wire [AW+BW-1:0] p_comb;
	genvar gk;
	generate
	for (gk = 0; gk < NUM_WEIGHTS; gk = gk + 1) begin : gen_comb_p
		localparam integer LAST_D = last_dsp_of_k(gk);
		if (gk < NUM_WEIGHTS - 1) begin : g_mid
			assign p_comb[17*gk +: 17] = dsp_p[LAST_D][16:0];
		end else begin : g_top
			localparam integer REM_W = (AW + BW) - 17 * (NUM_WEIGHTS - 1);
			assign p_comb[AW+BW-1 : 17*(NUM_WEIGHTS-1)] = dsp_p[LAST_D][REM_W-1 : 0];
		end
	end
	endgenerate

	/* Latency pipeline and output assignment: 0 fabric registers for LAT <= 3 */
	generate
	if (LAT <= 3) begin : g_direct
		assign p = p_comb;
	end else begin : g_extra
		reg [AW+BW-1:0] r [0:LAT-4];
		integer idx;
		always @(posedge clk)
			if (en) begin
				r[0] <= p_comb;
				for (idx = 1; idx <= LAT-4; idx = idx + 1)
					r[idx] <= r[idx-1];
			end
		assign p = r[LAT-4];
	end
	endgenerate
`endif
endmodule

`default_nettype wire
