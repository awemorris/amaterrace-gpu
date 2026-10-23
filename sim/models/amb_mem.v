/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * amb_mem: a behavioural memory behind one AMB client port (design §4.1),
 * for the unit testbenches of AMB clients.  req_ready is random (seeded),
 * requests are answered in order after 2..9 cycles, one response per
 * request; a request whose byte address is at or above ERR_BASE gets an
 * error response and does not touch memory.  MEM_WORDS 32-bit words from
 * address 0, out-of-range words read 0.  peek/poke for the testbench;
 * writes counts the write requests that reached memory.
 */

`timescale 1ns / 1ps
`default_nettype none

module amb_mem #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter MEM_WORDS = 4096,
	parameter [31:0] ERR_BASE = 32'h80000000,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	input wire req_valid,
	output reg req_ready,
	input wire req_write,
	input wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	input wire [LINE_BYTES-1:0] req_be,
	input wire [LINE_BYTES*8-1:0] req_wdata,
	input wire [7:0] req_tag,
	output reg rsp_valid,
	output reg rsp_write,
	output reg [7:0] rsp_tag,
	output reg [LINE_BYTES*8-1:0] rsp_rdata,
	output reg rsp_error
);
	localparam WPL = LINE_BYTES / 4;

	reg [31:0] mem [0:MEM_WORDS-1];
	integer seed;
	integer writes;
	integer i, b;

	/* The queue of accepted requests (at most 16). */
	reg q_write [0:15];
	reg [7:0] q_tag [0:15];
	reg [LINE_BYTES*8-1:0] q_data [0:15];
	reg q_err [0:15];
	integer q_due [0:15];
	integer q_head, q_tail, now;

	function [31:0] peek;
		input [31:0] addr;
		peek = addr / 4 < MEM_WORDS ? mem[addr / 4] : 32'd0;
	endfunction

	task poke;
		input [31:0] addr;
		input [31:0] value;
		mem[addr / 4] = value;
	endtask

	initial begin
		seed = SEED;
		writes = 0;
		q_head = 0;
		q_tail = 0;
		now = 0;
		req_ready = 1'b0;
		rsp_valid = 1'b0;
		rsp_write = 1'b0;
		rsp_tag = 8'd0;
		rsp_rdata = 0;
		rsp_error = 1'b0;
		for (i = 0; i < MEM_WORDS; i = i + 1)
			mem[i] = 32'd0;
	end

	reg [31:0] base;
	reg [31:0] w;
	reg [LINE_BYTES*8-1:0] line;

	always @(posedge clk) begin
		now = now + 1;
		rsp_valid <= 1'b0;
		if (!rst_n) begin
			q_head = 0;
			q_tail = 0;
			req_ready <= 1'b0;
		end else begin
			if (req_valid && req_ready && q_tail - q_head < 16) begin
				base = {req_line, {LINE_SHIFT{1'b0}}};
				q_write[q_tail % 16] = req_write;
				q_tag[q_tail % 16] = req_tag;
				q_err[q_tail % 16] = base >= ERR_BASE;
				q_due[q_tail % 16] = now + 2 + ($unsigned($random(seed)) % 8);
				line = 0;
				for (i = 0; i < WPL; i = i + 1) begin
					w = peek(base + i * 4);
					if (req_write && base < ERR_BASE)
						for (b = 0; b < 4; b = b + 1)
							if (req_be[i * 4 + b])
								w[b * 8 +: 8] = req_wdata[(i * 4 + b) * 8 +: 8];
					if (req_write && base < ERR_BASE && (base + i * 4) / 4 < MEM_WORDS)
						mem[(base + i * 4) / 4] = w;
					line[i * 32 +: 32] = w;
				end
				if (req_write && base < ERR_BASE)
					writes = writes + 1;
				q_data[q_tail % 16] = line;
				q_tail = q_tail + 1;
			end
			req_ready <= ($random(seed) & 3) != 0;
			if (q_head != q_tail && q_due[q_head % 16] <= now) begin
				rsp_valid <= 1'b1;
				rsp_write <= q_write[q_head % 16];
				rsp_tag <= q_tag[q_head % 16];
				rsp_rdata <= q_data[q_head % 16];
				rsp_error <= q_err[q_head % 16];
				q_head = q_head + 1;
			end
		end
	end
endmodule

`default_nettype wire
