/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_skid: fanout-buffered register slice / skid buffer for ROP.
 * Compliant with ASIC 5nm 1.5 GHz / Kintex-7 fanout <= 16 limits.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_rop_skid #(
	parameter W = 32
) (
	input wire clk,
	input wire rst_n,

	input wire in_valid,
	output reg in_ready,
	input wire [W-1:0] in_data,

	output reg out_valid,
	input wire out_ready,
	output wire [W-1:0] out_data
);
	reg skid_valid;

	wire load_out_raw = skid_valid ? out_ready : (in_valid && (out_ready || !out_valid));
	wire load_skid_raw = in_valid && in_ready && !out_ready && out_valid;

	always @(posedge clk) begin
		if (!rst_n) begin
			in_ready   <= 1'b1;
			out_valid  <= 1'b0;
			skid_valid <= 1'b0;
		end else begin
			if (skid_valid) begin
				if (out_ready) begin
					out_valid  <= 1'b1;
					skid_valid <= 1'b0;
					in_ready   <= 1'b1;
				end
			end else begin
				if (out_ready || !out_valid) begin
					out_valid <= in_valid;
				end else if (in_valid && in_ready) begin
					skid_valid <= 1'b1;
					in_ready   <= 1'b0;
				end
			end
		end
	end

	localparam NUM_SLICES = (W + 15) / 16;
	localparam NUM_GROUPS = (NUM_SLICES + 15) / 16;

	reg [W-1:0] r_out_data;
	reg [W-1:0] r_skid_data;
	assign out_data = r_out_data;

	wire [NUM_GROUPS-1:0] ld_out_grp;
	wire [NUM_GROUPS-1:0] ld_skid_grp;
	wire [NUM_GROUPS-1:0] sk_val_grp;

	genvar gi, si;
	generate
		for (gi = 0; gi < NUM_GROUPS; gi = gi + 1) begin : g_grp
`ifdef SYNTH_KINTEX7
			(* keep = "true", dont_touch = "true" *) wire ldo_g;
			(* keep = "true", dont_touch = "true" *) wire lds_g;
			(* keep = "true", dont_touch = "true" *) wire skv_g;
			LUT1 #(.INIT(2'b10)) u_g_ldo (.I0(load_out_raw), .O(ldo_g));
			LUT1 #(.INIT(2'b10)) u_g_lds (.I0(load_skid_raw), .O(lds_g));
			LUT1 #(.INIT(2'b10)) u_g_skv (.I0(skid_valid), .O(skv_g));
			assign ld_out_grp[gi] = ldo_g;
			assign ld_skid_grp[gi] = lds_g;
			assign sk_val_grp[gi] = skv_g;
`else
			assign ld_out_grp[gi] = load_out_raw;
			assign ld_skid_grp[gi] = load_skid_raw;
			assign sk_val_grp[gi] = skid_valid;
`endif
		end

		for (si = 0; si < NUM_SLICES; si = si + 1) begin : g_slice
			localparam LO = si * 16;
			localparam HI = (si == NUM_SLICES - 1) ? (W - 1) : (si * 16 + 15);
			localparam GRP_IDX = si / 16;

`ifdef SYNTH_KINTEX7
			(* keep = "true", dont_touch = "true" *) wire ld_out_b;
			(* keep = "true", dont_touch = "true" *) wire ld_skid_b;
			(* keep = "true", dont_touch = "true" *) wire sk_valid_b;
			LUT1 #(.INIT(2'b10)) u_ldo (.I0(ld_out_grp[GRP_IDX]), .O(ld_out_b));
			LUT1 #(.INIT(2'b10)) u_lds (.I0(ld_skid_grp[GRP_IDX]), .O(ld_skid_b));
			LUT1 #(.INIT(2'b10)) u_skv (.I0(sk_val_grp[GRP_IDX]), .O(sk_valid_b));
`else
			wire ld_out_b = ld_out_grp[GRP_IDX];
			wire ld_skid_b = ld_skid_grp[GRP_IDX];
			wire sk_valid_b = sk_val_grp[GRP_IDX];
`endif

			always @(posedge clk) begin
				if (ld_skid_b)
					r_skid_data[HI:LO] <= in_data[HI:LO];
				if (ld_out_b)
					r_out_data[HI:LO] <= sk_valid_b ? r_skid_data[HI:LO] : in_data[HI:LO];
			end
		end
	endgenerate

endmodule

`default_nettype wire
