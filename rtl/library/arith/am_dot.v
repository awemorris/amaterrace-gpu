/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_dot: 2-term dot-product / multiply-accumulate engine.
 * Computes:
 *   p = a0 * b0 + (SUB1 ? -a1 * b1 : a1 * b1) + c
 *
 * Supports signed (SIGNED = 1) or unsigned operands.
 * Pipeline latency LAT (0 to 4 cycles).
 *
 * Under SYNTH_KINTEX7:
 *   Mapped directly to DSP48E1 slices using DSP cascade.
 * Under ASIC / generic simulation:
 *   Standard behavioral arithmetic expressions for synthesis by ASIC PDKs.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_dot #(
	parameter AW = 24,
	parameter BW = 24,
	parameter CW = 48,
	parameter PW = 48,
	parameter SIGNED = 1,
	parameter LAT = 3,
	parameter SUB1 = 0
) (
	input wire clk,
	input wire en,
	input wire [AW-1:0] a0,
	input wire [BW-1:0] b0,
	input wire [AW-1:0] a1,
	input wire [BW-1:0] b1,
	input wire [CW-1:0] c,
	output wire [PW-1:0] p
);
	localparam MW = AW + BW;
	localparam SUM_W = (CW > MW ? CW : MW) + 2;

`ifdef SYNTH_KINTEX7
	/* Kintex-7 DSP48E1 implementation */
	generate
	if (LAT == 0) begin : g_lat0
		if (SIGNED != 0) begin : g_signed
			wire signed [MW-1:0] p0_s = $signed(a0) * $signed(b0);
			wire signed [MW-1:0] p1_s = $signed(a1) * $signed(b1);
			(* use_dsp = "yes" *) wire signed [SUM_W-1:0] prod0 = {{(SUM_W-MW){p0_s[MW-1]}}, p0_s};
			(* use_dsp = "yes" *) wire signed [SUM_W-1:0] prod1 = {{(SUM_W-MW){p1_s[MW-1]}}, p1_s};
			wire signed [SUM_W-1:0] c_ext = {{(SUM_W-CW){c[CW-1]}}, c};
			(* use_dsp = "yes" *) wire signed [SUM_W-1:0] sum = SUB1 ?
				(prod0 - prod1 + c_ext) :
				(prod0 + prod1 + c_ext);
			assign p = sum[PW-1:0];
		end else begin : g_unsigned
			wire [MW-1:0] p0_u = a0 * b0;
			wire [MW-1:0] p1_u = a1 * b1;
			(* use_dsp = "yes" *) wire [SUM_W-1:0] prod0 = {{(SUM_W-MW){1'b0}}, p0_u};
			(* use_dsp = "yes" *) wire [SUM_W-1:0] prod1 = {{(SUM_W-MW){1'b0}}, p1_u};
			wire [SUM_W-1:0] c_ext = {{(SUM_W-CW){1'b0}}, c};
			(* use_dsp = "yes" *) wire [SUM_W-1:0] sum = SUB1 ?
				(prod0 - prod1 + c_ext) :
				(prod0 + prod1 + c_ext);
			assign p = sum[PW-1:0];
		end
		wire unused_clk = &{1'b0, clk, en};
	end else if (LAT == 1) begin : g_lat1
		reg [PW-1:0] r_p;
		if (SIGNED != 0) begin : g_signed
			wire signed [MW-1:0] p0_s = $signed(a0) * $signed(b0);
			wire signed [MW-1:0] p1_s = $signed(a1) * $signed(b1);
			(* use_dsp = "yes" *) wire signed [SUM_W-1:0] prod0 = {{(SUM_W-MW){p0_s[MW-1]}}, p0_s};
			(* use_dsp = "yes" *) wire signed [SUM_W-1:0] prod1 = {{(SUM_W-MW){p1_s[MW-1]}}, p1_s};
			wire signed [SUM_W-1:0] c_ext = {{(SUM_W-CW){c[CW-1]}}, c};
			(* use_dsp = "yes" *) wire signed [SUM_W-1:0] sum = SUB1 ?
				(prod0 - prod1 + c_ext) :
				(prod0 + prod1 + c_ext);
			always @(posedge clk) begin
				if (en) r_p <= sum[PW-1:0];
			end
		end else begin : g_unsigned
			wire [MW-1:0] p0_u = a0 * b0;
			wire [MW-1:0] p1_u = a1 * b1;
			(* use_dsp = "yes" *) wire [SUM_W-1:0] prod0 = {{(SUM_W-MW){1'b0}}, p0_u};
			(* use_dsp = "yes" *) wire [SUM_W-1:0] prod1 = {{(SUM_W-MW){1'b0}}, p1_u};
			wire [SUM_W-1:0] c_ext = {{(SUM_W-CW){1'b0}}, c};
			(* use_dsp = "yes" *) wire [SUM_W-1:0] sum = SUB1 ?
				(prod0 - prod1 + c_ext) :
				(prod0 + prod1 + c_ext);
			always @(posedge clk) begin
				if (en) r_p <= sum[PW-1:0];
			end
		end
		assign p = r_p;
	end else if (LAT == 2) begin : g_lat2
		/* LAT=2: Input registers + registered DSP output */
		if (SIGNED != 0) begin : g_signed
			(* extract_reset = "no" *) reg signed [AW-1:0] r_a0, r_a1;
			(* extract_reset = "no" *) reg signed [BW-1:0] r_b0, r_b1;
			(* extract_reset = "no" *) reg signed [CW-1:0] r_c;
			reg signed [PW-1:0] r_p;
			always @(posedge clk) begin
				if (en) begin
					r_a0 <= a0;
					r_b0 <= b0;
					r_a1 <= a1;
					r_b1 <= b1;
					r_c  <= c;
				end
			end
			wire signed [MW-1:0] p0_s = r_a0 * r_b0;
			wire signed [MW-1:0] p1_s = r_a1 * r_b1;
			(* use_dsp = "yes" *) wire signed [SUM_W-1:0] prod0 = {{(SUM_W-MW){p0_s[MW-1]}}, p0_s};
			(* use_dsp = "yes" *) wire signed [SUM_W-1:0] prod1 = {{(SUM_W-MW){p1_s[MW-1]}}, p1_s};
			wire signed [SUM_W-1:0] c_ext = {{(SUM_W-CW){r_c[CW-1]}}, r_c};
			(* use_dsp = "yes" *) wire signed [SUM_W-1:0] sum = SUB1 ?
				(prod0 - prod1 + c_ext) :
				(prod0 + prod1 + c_ext);
			always @(posedge clk) begin
				if (en) r_p <= sum[PW-1:0];
			end
			assign p = r_p;
		end else begin : g_unsigned
			(* extract_reset = "no" *) reg [AW-1:0] r_a0, r_a1;
			(* extract_reset = "no" *) reg [BW-1:0] r_b0, r_b1;
			(* extract_reset = "no" *) reg [CW-1:0] r_c;
			reg [PW-1:0] r_p;
			always @(posedge clk) begin
				if (en) begin
					r_a0 <= a0;
					r_b0 <= b0;
					r_a1 <= a1;
					r_b1 <= b1;
					r_c  <= c;
				end
			end
			wire [MW-1:0] p0_u = r_a0 * r_b0;
			wire [MW-1:0] p1_u = r_a1 * r_b1;
			(* use_dsp = "yes" *) wire [SUM_W-1:0] prod0 = {{(SUM_W-MW){1'b0}}, p0_u};
			(* use_dsp = "yes" *) wire [SUM_W-1:0] prod1 = {{(SUM_W-MW){1'b0}}, p1_u};
			wire [SUM_W-1:0] c_ext = {{(SUM_W-CW){1'b0}}, r_c};
			(* use_dsp = "yes" *) wire [SUM_W-1:0] sum = SUB1 ?
				(prod0 - prod1 + c_ext) :
				(prod0 + prod1 + c_ext);
			always @(posedge clk) begin
				if (en) r_p <= sum[PW-1:0];
			end
			assign p = r_p;
		end
	end else begin : g_lat3
		/* LAT>=3: Input registers + Multiplier registers (MREG) + Accumulator (PREG) + pipeline */
		if (SIGNED != 0) begin : g_signed
			(* extract_reset = "no" *) reg signed [AW-1:0] r_a0, r_a1;
			(* extract_reset = "no" *) reg signed [BW-1:0] r_b0, r_b1;
			(* extract_reset = "no" *) reg signed [CW-1:0] r_c, r_c_pipe;
			(* use_dsp = "yes", extract_reset = "no" *) reg signed [MW-1:0] r_m0, r_m1;
			(* use_dsp = "yes" *) reg signed [PW-1:0] r_p;

			wire signed [SUM_W-1:0] prod0 = {{(SUM_W-MW){r_m0[MW-1]}}, r_m0};
			wire signed [SUM_W-1:0] prod1 = {{(SUM_W-MW){r_m1[MW-1]}}, r_m1};
			wire signed [SUM_W-1:0] c_ext = {{(SUM_W-CW){r_c_pipe[CW-1]}}, r_c_pipe};

			always @(posedge clk) begin
				if (en) begin
					r_a0 <= a0;
					r_b0 <= b0;
					r_a1 <= a1;
					r_b1 <= b1;
					r_c  <= c;
					r_m0 <= $signed(r_a0) * $signed(r_b0);
					r_m1 <= $signed(r_a1) * $signed(r_b1);
					r_c_pipe <= r_c;
					r_p  <= SUB1 ? (prod0 - prod1 + c_ext) : (prod0 + prod1 + c_ext);
				end
			end

			if (LAT == 3) begin : g_l3
				assign p = r_p;
			end else begin : g_l_more
				reg signed [PW-1:0] p_pipe [0:LAT-4];
				integer i;
				always @(posedge clk) begin
					if (en) begin
						p_pipe[0] <= r_p;
						for (i = 1; i <= LAT-4; i = i + 1)
							p_pipe[i] <= p_pipe[i-1];
					end
				end
				assign p = p_pipe[LAT-4];
			end
		end else begin : g_unsigned
			(* extract_reset = "no" *) reg [AW-1:0] r_a0, r_a1;
			(* extract_reset = "no" *) reg [BW-1:0] r_b0, r_b1;
			(* extract_reset = "no" *) reg [CW-1:0] r_c, r_c_pipe;
			(* use_dsp = "yes", extract_reset = "no" *) reg [MW-1:0] r_m0, r_m1;
			(* use_dsp = "yes" *) reg [PW-1:0] r_p;

			wire [SUM_W-1:0] prod0 = {{(SUM_W-MW){1'b0}}, r_m0};
			wire [SUM_W-1:0] prod1 = {{(SUM_W-MW){1'b0}}, r_m1};
			wire [SUM_W-1:0] c_ext = {{(SUM_W-CW){1'b0}}, r_c_pipe};

			always @(posedge clk) begin
				if (en) begin
					r_a0 <= a0;
					r_b0 <= b0;
					r_a1 <= a1;
					r_b1 <= b1;
					r_c  <= c;
					r_m0 <= r_a0 * r_b0;
					r_m1 <= r_a1 * r_b1;
					r_c_pipe <= r_c;
					r_p  <= SUB1 ? (prod0 - prod1 + c_ext) : (prod0 + prod1 + c_ext);
				end
			end

			if (LAT == 3) begin : g_l3
				assign p = r_p;
			end else begin : g_l_more
				reg [PW-1:0] p_pipe [0:LAT-4];
				integer i;
				always @(posedge clk) begin
					if (en) begin
						p_pipe[0] <= r_p;
						for (i = 1; i <= LAT-4; i = i + 1)
							p_pipe[i] <= p_pipe[i-1];
					end
				end
				assign p = p_pipe[LAT-4];
			end
		end
	end
	endgenerate
`else
	/* Generic / ASIC behavioral implementation for standard PDK synthesis */
	generate
	if (LAT == 0) begin : g_asic_lat0
		if (SIGNED != 0) begin : g_s
			wire signed [MW-1:0] p0_s = $signed(a0) * $signed(b0);
			wire signed [MW-1:0] p1_s = $signed(a1) * $signed(b1);
			wire signed [SUM_W-1:0] prod0 = {{(SUM_W-MW){p0_s[MW-1]}}, p0_s};
			wire signed [SUM_W-1:0] prod1 = {{(SUM_W-MW){p1_s[MW-1]}}, p1_s};
			wire signed [SUM_W-1:0] c_ext = {{(SUM_W-CW){c[CW-1]}}, c};
			wire signed [SUM_W-1:0] sum = SUB1 ?
				(prod0 - prod1 + c_ext) :
				(prod0 + prod1 + c_ext);
			assign p = sum[PW-1:0];
		end else begin : g_u
			wire [MW-1:0] p0_u = a0 * b0;
			wire [MW-1:0] p1_u = a1 * b1;
			wire [SUM_W-1:0] prod0 = {{(SUM_W-MW){1'b0}}, p0_u};
			wire [SUM_W-1:0] prod1 = {{(SUM_W-MW){1'b0}}, p1_u};
			wire [SUM_W-1:0] c_ext = {{(SUM_W-CW){1'b0}}, c};
			wire [SUM_W-1:0] sum = SUB1 ?
				(prod0 - prod1 + c_ext) :
				(prod0 + prod1 + c_ext);
			assign p = sum[PW-1:0];
		end
		wire unused_clk = &{1'b0, clk, en};
	end else begin : g_asic_lat_reg
		reg [PW-1:0] r_pipe [0:LAT-1];
		integer i;
		if (SIGNED != 0) begin : g_s
			wire signed [MW-1:0] p0_s = $signed(a0) * $signed(b0);
			wire signed [MW-1:0] p1_s = $signed(a1) * $signed(b1);
			wire signed [SUM_W-1:0] prod0 = {{(SUM_W-MW){p0_s[MW-1]}}, p0_s};
			wire signed [SUM_W-1:0] prod1 = {{(SUM_W-MW){p1_s[MW-1]}}, p1_s};
			wire signed [SUM_W-1:0] c_ext = {{(SUM_W-CW){c[CW-1]}}, c};
			wire signed [SUM_W-1:0] sum = SUB1 ?
				(prod0 - prod1 + c_ext) :
				(prod0 + prod1 + c_ext);
			always @(posedge clk) begin
				if (en) begin
					r_pipe[0] <= sum[PW-1:0];
					for (i = 1; i < LAT; i = i + 1)
						r_pipe[i] <= r_pipe[i-1];
				end
			end
		end else begin : g_u
			wire [MW-1:0] p0_u = a0 * b0;
			wire [MW-1:0] p1_u = a1 * b1;
			wire [SUM_W-1:0] prod0 = {{(SUM_W-MW){1'b0}}, p0_u};
			wire [SUM_W-1:0] prod1 = {{(SUM_W-MW){1'b0}}, p1_u};
			wire [SUM_W-1:0] c_ext = {{(SUM_W-CW){1'b0}}, c};
			wire [SUM_W-1:0] sum = SUB1 ?
				(prod0 - prod1 + c_ext) :
				(prod0 + prod1 + c_ext);
			always @(posedge clk) begin
				if (en) begin
					r_pipe[0] <= sum[PW-1:0];
					for (i = 1; i < LAT; i = i + 1)
						r_pipe[i] <= r_pipe[i-1];
				end
			end
		end
		assign p = r_pipe[LAT-1];
	end
	endgenerate
`endif
endmodule

`default_nettype wire
