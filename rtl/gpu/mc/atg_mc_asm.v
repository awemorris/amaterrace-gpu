/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_asm: an assembly buffer of the MC's root (spec/gpu/mc/atg_mc.md):
 * it takes a request's header flit and, for a write, its data flit from
 * the tree (t_*), and offers the complete request (full, head, data) until
 * take.  A flit is taken when the buffer is empty or its request is taken
 * in the same cycle (t_ready).  rst_n and flush empty it.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_asm #(
	parameter LINE_BYTES = 32
) (
	input wire clk,
	input wire rst_n,
	input wire flush,
	input wire t_valid,
	output wire t_ready,
	input wire [LINE_BYTES*8-1:0] t_data,
	input wire t_last,
	input wire t_ap,
	output reg full,
	output reg [LINE_BYTES*8-1:0] head,
	output reg [LINE_BYTES*8-1:0] data,
	output reg ap_ok,
	input wire take
);
	/* A write's header is in, its data flit is not. */
	reg hdr;

	assign t_ready = !full;

	wire head_en = t_valid && t_ready && !hdr;
	wire data_en = t_valid && hdr;

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire asm_rst_sync;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hD)) u_asm_rst (
		.I0(rst_n), .I1(flush), .O(asm_rst_sync)
	);
`else
	wire asm_rst_sync = !rst_n || flush;
`endif

	always @(posedge clk) begin
		if (asm_rst_sync) begin
			hdr <= 1'b0;
			full <= 1'b0;
		end else begin
			if (take)
				full <= 1'b0;
			if (t_valid && t_ready) begin
				if (!hdr) begin
					hdr <= !t_last;
					full <= t_last;
				end else begin
					hdr <= 1'b0;
					full <= 1'b1;
				end
			end
		end
	end

`ifdef SYNTH_KINTEX7
	wire [2:0] tv_g, hdr_g;
	wire [1:0] full_g;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_tv0  (.I0(t_valid), .O(tv_g[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_tv1  (.I0(t_valid), .O(tv_g[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_tv2  (.I0(t_valid), .O(tv_g[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hdr0 (.I0(hdr),     .O(hdr_g[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hdr1 (.I0(hdr),     .O(hdr_g[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hdr2 (.I0(hdr),     .O(hdr_g[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_fl0  (.I0(full),    .O(full_g[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_fl1  (.I0(full),    .O(full_g[1]));

	localparam NSLICE = (LINE_BYTES * 8) / 16;
	wire [NSLICE-1:0] head_en_b, data_en_b;
	genvar gs;
	generate
		for (gs = 0; gs < NSLICE; gs = gs + 1) begin : g_en_buf
			localparam HGRP = (gs >= 11) ? 2 : ((gs >= 5) ? 1 : 0);
			localparam FGRP = (gs >= 8) ? 1 : 0;
			/* head_en = t_valid && !hdr && !full in 1 LUT4 */
			(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0002)) u_he (
				.I0(tv_g[HGRP]), .I1(full_g[FGRP]), .I2(1'b0), .I3(hdr_g[HGRP]),
				.O(head_en_b[gs])
			);
			/* data_en = t_valid && hdr in 1 LUT2 (full is always 0 when hdr is 1) */
			(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_de (
				.I0(tv_g[HGRP]), .I1(hdr_g[HGRP]), .O(data_en_b[gs])
			);
			always @(posedge clk) begin
				if (head_en_b[gs])
					head[gs*16 +: 16] <= t_data[gs*16 +: 16];
				if (data_en_b[gs])
					data[gs*16 +: 16] <= t_data[gs*16 +: 16];
			end
		end
	endgenerate
	always @(posedge clk) begin
		if (head_en_b[0])
			ap_ok <= t_ap;
	end
`else
	always @(posedge clk) begin
		if (!rst_n || flush) begin
			head <= {LINE_BYTES*8{1'b0}};
			data <= {LINE_BYTES*8{1'b0}};
			ap_ok <= 1'b0;
		end else begin
			if (head_en) begin
				head <= t_data;
				ap_ok <= t_ap;
			end
			if (data_en) begin
				data <= t_data;
			end
		end
	end
`endif
endmodule

`default_nettype wire
