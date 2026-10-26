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
	(* use_dsp = "yes" *) wire [AW+BW-1:0] m;
	generate
	if (SIGNED != 0) begin : g_s
		assign m = $signed(a) * $signed(b);
	end else begin : g_u
		assign m = a * b;
	end
	if (LAT == 0) begin : g_c
		assign p = m;
	end else begin : g_r
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

	function integer d_areg;
		input integer d_idx;
		begin
			if (LAT < 3)
				d_areg = 0;
			else if (NUM_DSP == 1)
				d_areg = 1;
			else if (NUM_DSP == 2)
				d_areg = (d_idx == 1) ? 1 : 0;
			else
				d_areg = 0;
		end
	endfunction

	function integer d_breg;
		input integer d_idx;
		begin
			if (LAT < 3)
				d_breg = 0;
			else if (NUM_DSP == 1)
				d_breg = 1;
			else if (NUM_DSP == 2)
				d_breg = (d_idx == 1) ? 1 : 0;
			else
				d_breg = 0;
		end
	endfunction

	/* verilator lint_off UNUSEDSIGNAL */
	function integer d_mreg;
		input integer d_idx;
		begin
			d_mreg = (LAT < 2) ? 0 : 1;
		end
	endfunction

	function integer d_preg;
		input integer d_idx;
		begin
			if (LAT == 0)
				d_preg = 0;
			else if (LAT == 1 || LAT == 2)
				d_preg = (NUM_DSP == 1) ? 1 : 0;
			else if (NUM_DSP <= 2)
				d_preg = 1;
			else
				d_preg = 0;
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

		wire ce_a = (AREG_VAL > 0) ? en : 1'b0;
		wire ce_b = (BREG_VAL > 0) ? en : 1'b0;
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
			.CEA1(ce_a),
			.CEA2(ce_a),
			.CEAD(1'b0),
			.CEALUMODE(1'b0),
			.CEB1(ce_b),
			.CEB2(ce_b),
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

	/* Latency pipeline and output assignment */
	generate
	if (NUM_DSP == 1) begin : g_lat_1dsp
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
	end else if (NUM_DSP == 2) begin : g_lat_2dsp
		if (LAT == 0) begin : g_l0
			assign p = p_comb;
		end else if (LAT == 1 || LAT == 2) begin : g_l12
			/* LAT == 1: MREG=0, 1 cycle in fabric.
			 * LAT == 2: MREG=1 (1 cycle in DSP), 1 cycle in fabric -> total 2 cycles. */
			reg [AW+BW-1:0] r;
			always @(posedge clk)
				if (en)
					r <= p_comb;
			assign p = r;
		end else if (LAT == 3) begin : g_l3
			reg [16:0] p_lo_r;
			always @(posedge clk)
				if (en)
					p_lo_r <= dsp_p[0][16:0];
			assign p = { dsp_p[1][AW+BW-1-17 : 0], p_lo_r };
		end else begin : g_l_gt3
			reg [16:0] p_lo_r;
			always @(posedge clk)
				if (en)
					p_lo_r <= dsp_p[0][16:0];
			wire [AW+BW-1:0] p_l3 = { dsp_p[1][AW+BW-1-17 : 0], p_lo_r };
			reg [AW+BW-1:0] r [0:LAT-4];
			integer idx;
			always @(posedge clk)
				if (en) begin
					r[0] <= p_l3;
					for (idx = 1; idx <= LAT-4; idx = idx + 1)
						r[idx] <= r[idx-1];
				end
			assign p = r[LAT-4];
		end
	end else begin : g_lat_ndsp
		if (LAT == 0) begin : g_l0
			assign p = p_comb;
		end else if (LAT == 1) begin : g_l1
			reg [AW+BW-1:0] r;
			always @(posedge clk)
				if (en)
					r <= p_comb;
			assign p = r;
		end else begin : g_l2plus
			/* LAT >= 2: MREG gives 1 cycle delay, extra LAT-1 registers give remaining */
			reg [AW+BW-1:0] r [0:LAT-2];
			integer idx;
			always @(posedge clk)
				if (en) begin
					r[0] <= p_comb;
					for (idx = 1; idx <= LAT-2; idx = idx + 1)
						r[idx] <= r[idx-1];
				end
			assign p = r[LAT-2];
		end
	end
	endgenerate
`endif
endmodule

`default_nettype wire
