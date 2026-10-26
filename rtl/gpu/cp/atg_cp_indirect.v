/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_indirect: Indirect draw and multiDrawIndirect argument fetcher (Phase 008).
 *
 * Fetches draw command argument structures from GPU memory without CPU intervention:
 * - VkDrawIndirectCommand (16 bytes: vertexCount, instanceCount, firstVertex, firstInstance)
 * - VkDrawIndexedIndirectCommand (20 bytes: indexCount, instanceCount, firstIndex,
 *   vertexOffset, firstInstance)
 *
 * Iterates across draw_count commands with given byte stride, automatically handling
 * 32-byte cache line alignment and boundary crossing.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_indirect (
	input wire clk,
	input wire rst_n,

	/* Indirect draw command request (from CP / ring decoder) */
	input wire cmd_valid,
	output wire cmd_ready,
	input wire [31:0] arg_buffer_addr,
	input wire [31:0] draw_count,
	input wire [31:0] stride,
	input wire is_indexed,

	/* Argument buffer DMA read (AMB client / memory reader) */
	output wire dma_req_valid,
	input wire dma_req_ready,
	output wire [25:0] dma_req_line,
	input wire dma_rsp_valid,
	input wire [255:0] dma_rsp_data,

	/* Dispatched draw call (to VF / CP controller) */
	output reg draw_valid,
	input wire draw_ready,
	output reg [31:0] vertex_count,
	output reg [31:0] instance_count,
	output reg [31:0] first_vertex,
	output reg [31:0] first_instance,
	output reg [31:0] first_index,
	output reg [31:0] vertex_offset
);

	localparam [2:0] S_IDLE      = 3'd0,
	                 S_REQ0      = 3'd1,
	                 S_RSP0      = 3'd2,
	                 S_REQ1      = 3'd3,
	                 S_RSP1      = 3'd4,
	                 S_EMIT      = 3'd5,
	                 S_WAIT_DRAW = 3'd6;

	reg [2:0] st;
	reg [31:0] cur_addr;
	reg [31:0] eff_stride;
	reg [31:0] draw_idx;
	reg [31:0] total_draws;
	reg indexed_r;
	reg [511:0] line_buf;

	/* Next line calculation */
	wire [25:0] next_line;
	wire line_co_unused;
	am_add #(.W(26)) u_add_line (
		.a(cur_addr[30:5]),
		.b(26'd0),
		.ci(1'b1),
		.s(next_line),
		.co(line_co_unused)
	);

	/* Next address calculation */
	wire [31:0] next_addr;
	wire addr_co_unused;
	am_add #(.W(32)) u_add_addr (
		.a(cur_addr),
		.b(eff_stride),
		.ci(1'b0),
		.s(next_addr),
		.co(addr_co_unused)
	);

	/* Next draw index calculation */
	wire [31:0] next_draw_idx;
	wire idx_co_unused;
	am_add #(.W(32)) u_add_idx (
		.a(draw_idx),
		.b(32'd0),
		.ci(1'b1),
		.s(next_draw_idx),
		.co(idx_co_unused)
	);

	/* Line crossing detection */
	wire [5:0] cmd_len = indexed_r ? 6'd20 : 6'd16;
	wire [5:0] end_byte;
	wire end_co_unused;
	am_add #(.W(6)) u_add_end (
		.a({1'b0, cur_addr[4:0]}),
		.b(cmd_len),
		.ci(1'b0),
		.s(end_byte),
		.co(end_co_unused)
	);
	wire crosses = end_byte > 6'd32;

	/* Word extraction from 64-byte line buffer */
	reg [31:0] w0, w1, w2, w3, w4;
	integer b_i;
	always @(*) begin
		w0 = 32'd0;
		w1 = 32'd0;
		w2 = 32'd0;
		w3 = 32'd0;
		w4 = 32'd0;
		for (b_i = 0; b_i < 32; b_i = b_i + 1) begin
			if (cur_addr[4:0] == b_i[4:0]) begin
				w0 = line_buf[b_i*8 +: 32];
				w1 = line_buf[(b_i+4)*8 +: 32];
				w2 = line_buf[(b_i+8)*8 +: 32];
				w3 = line_buf[(b_i+12)*8 +: 32];
				w4 = line_buf[(b_i+16)*8 +: 32];
			end
		end
	end

	assign cmd_ready = (st == S_IDLE);
	assign dma_req_valid = (st == S_REQ0) || (st == S_REQ1);
	assign dma_req_line = (st == S_REQ1) ? next_line : cur_addr[30:5];

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= S_IDLE;
			cur_addr <= 32'd0;
			eff_stride <= 32'd0;
			draw_idx <= 32'd0;
			total_draws <= 32'd0;
			indexed_r <= 1'b0;
			line_buf <= 512'd0;
			draw_valid <= 1'b0;
			vertex_count <= 32'd0;
			instance_count <= 32'd0;
			first_vertex <= 32'd0;
			first_instance <= 32'd0;
			first_index <= 32'd0;
			vertex_offset <= 32'd0;
		end else begin
			case (st)
			S_IDLE: begin
				draw_valid <= 1'b0;
				if (cmd_valid) begin
					cur_addr <= arg_buffer_addr;
					total_draws <= draw_count;
					eff_stride <= (stride != 32'd0) ? stride : (is_indexed ? 32'd20 : 32'd16);
					indexed_r <= is_indexed;
					draw_idx <= 32'd0;
					if (draw_count != 32'd0)
						st <= S_REQ0;
				end
			end

			S_REQ0: begin
				if (dma_req_ready)
					st <= S_RSP0;
			end

			S_RSP0: begin
				if (dma_rsp_valid) begin
					line_buf[255:0] <= dma_rsp_data;
					if (crosses)
						st <= S_REQ1;
					else
						st <= S_EMIT;
				end
			end

			S_REQ1: begin
				if (dma_req_ready)
					st <= S_RSP1;
			end

			S_RSP1: begin
				if (dma_rsp_valid) begin
					line_buf[511:256] <= dma_rsp_data;
					st <= S_EMIT;
				end
			end

			S_EMIT: begin
				if (!indexed_r) begin
					vertex_count <= w0;
					instance_count <= w1;
					first_vertex <= w2;
					first_instance <= w3;
					first_index <= 32'd0;
					vertex_offset <= 32'd0;
				end else begin
					vertex_count <= w0;
					instance_count <= w1;
					first_index <= w2;
					vertex_offset <= w3;
					first_instance <= w4;
					first_vertex <= 32'd0;
				end
				draw_valid <= 1'b1;
				st <= S_WAIT_DRAW;
			end

			S_WAIT_DRAW: begin
				if (draw_valid && draw_ready) begin
					draw_valid <= 1'b0;
					cur_addr <= next_addr;
					draw_idx <= next_draw_idx;
					if (next_draw_idx == total_draws)
						st <= S_IDLE;
					else
						st <= S_REQ0;
				end
			end

			default: st <= S_IDLE;
			endcase
		end
	end

endmodule
`default_nettype wire
