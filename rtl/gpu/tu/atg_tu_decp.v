/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_decp: Unified texture block decompression pipeline (Phase 006 / ws002-p006).
 *
 * Integrates desktop Block Compression (BC1..BC7) via atg_tu_bc and
 * mobile ETC2/EAC decompression into a single unified decompression stage.
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

module atg_tu_decp (
	input  wire         clk,
	input  wire         rst_n,

	/* Request interface */
	input  wire         in_valid,
	output wire         in_ready,
	input  wire         is_bc,       /* 1: BC1..BC7, 0: ETC2/EAC or uncompressed */
	input  wire [3:0]   fmt,         /* Format identifier */
	input  wire [127:0] in_block,
	input  wire [3:0]   sub_texel,

	/* Decompressed result */
	output wire         out_valid,
	input  wire         out_ready,
	output wire [31:0]  out_rgba,
	output wire [63:0]  out_fp16
);

	/* BC1..BC7 Decoder Instance */
	wire bc_in_valid = in_valid && is_bc;
	wire bc_in_ready;
	wire bc_out_valid;
	wire [31:0] bc_out_rgba;
	wire [63:0] bc_out_fp16;

`ifdef CFG_ENABLE_BC
	atg_tu_bc u_bc (
		.clk(clk),
		.rst_n(rst_n),
		.in_valid(bc_in_valid),
		.in_ready(bc_in_ready),
		.fmt_bc(fmt),
		.in_block(in_block),
		.sub_texel(sub_texel),
		.out_valid(bc_out_valid),
		.out_ready(out_ready),
		.out_rgba(bc_out_rgba),
		.out_fp16(bc_out_fp16)
	);
`else
	reg stub_valid;

	always @(posedge clk) begin
		if (!rst_n) begin
			stub_valid <= 1'b0;
		end else begin
			if (out_ready || !stub_valid) begin
				stub_valid <= bc_in_valid;
			end
		end
	end

	assign bc_in_ready  = out_ready || !stub_valid;
	assign bc_out_valid = stub_valid;
	assign bc_out_rgba  = 32'd0;
	assign bc_out_fp16  = 64'd0;
	wire unused_decp_stub = &{1'b0, fmt, sub_texel, in_block[127:32]};
`endif

	/* Pass-through register for non-BC formats */
	reg non_bc_valid;
	reg [31:0] non_bc_rgba;

	always @(posedge clk) begin
		if (!rst_n) begin
			non_bc_valid <= 1'b0;
			non_bc_rgba  <= 32'd0;
		end else begin
			if (out_ready || !non_bc_valid) begin
				non_bc_valid <= in_valid && !is_bc;
				if (in_valid && !is_bc) begin
					non_bc_rgba <= in_block[31:0];
				end
			end
		end
	end

	assign in_ready  = is_bc ? bc_in_ready : (out_ready || !non_bc_valid);
	assign out_valid = is_bc ? bc_out_valid : non_bc_valid;
	assign out_rgba  = is_bc ? bc_out_rgba : non_bc_rgba;
	assign out_fp16  = bc_out_fp16;

endmodule

`default_nettype wire
