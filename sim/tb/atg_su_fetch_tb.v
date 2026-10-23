/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fetch_tb: random fetches against an I$ model with random
 * ic_ready and in-order answers after 1-6 cycles, and a random d_ready;
 * every instruction must leave once, in order, with its own warp and pc.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_fetch_tb;
	localparam N = 2000;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg f_valid = 1'b0;
	wire f_ready;
	reg [1:0] f_warp = 0;
	reg [15:0] f_pc = 0;
	reg [31:0] f_addr = 0;
	wire ic_req;
	reg ic_ready = 1'b0;
	wire [31:0] ic_addr;
	reg ic_rvalid = 1'b0;
	reg [63:0] ic_rdata = 0;
	wire d_valid;
	reg d_ready = 1'b0;
	wire [1:0] d_warp;
	wire [15:0] d_pc;
	wire [63:0] d_instr;
	integer seed = 1;
	integer errors = 0;
	integer n_in = 0, n_out = 0, now = 0;
	reg [31:0] iq_addr [0:63];
	integer iq_due [0:63];
	integer iq_h = 0, iq_t = 0;

	always #5 clk = !clk;

	atg_su_fetch dut (
		.clk(clk), .rst_n(rst_n), .f_valid(f_valid), .f_ready(f_ready), .f_warp(f_warp),
		.f_pc(f_pc), .f_addr(f_addr), .ic_req(ic_req), .ic_ready(ic_ready),
		.ic_addr(ic_addr), .ic_rvalid(ic_rvalid), .ic_rdata(ic_rdata),
		.d_valid(d_valid), .d_ready(d_ready), .d_warp(d_warp), .d_pc(d_pc),
		.d_instr(d_instr)
	);

	function [63:0] ins;
		input [31:0] a;
		ins = {~a, a};
	endfunction

	/* The I$ model (blocking, in order: an answer waits for the previous). */
	always @(posedge clk) begin
		now = now + 1;
		ic_rvalid <= 1'b0;
		if (rst_n) begin
			if (ic_req && ic_ready) begin
				iq_addr[iq_t % 64] = ic_addr;
				iq_due[iq_t % 64] = now + ($unsigned($random(seed)) % 6);
				iq_t = iq_t + 1;
			end
			if (iq_h != iq_t && iq_due[iq_h % 64] <= now) begin
				ic_rvalid <= 1'b1;
				ic_rdata <= ins(iq_addr[iq_h % 64]);
				iq_h = iq_h + 1;
			end
			ic_ready <= ($random(seed) & 3) != 0 && iq_t - iq_h < 2;
		end
	end

	/* The source: hold valid and payload until taken. */
	always @(negedge clk) begin
		if (rst_n)
			d_ready = ($random(seed) & 3) != 0;
	end
	always @(posedge clk) begin
		if (rst_n) begin
			if (f_valid && f_ready) begin
				n_in = n_in + 1;
				f_valid <= 1'b0;
			end
			if (d_valid && d_ready) begin
				if (d_warp !== n_out % 4 || d_pc !== n_out || d_instr !== ins(n_out * 8 + 32'h4000)) begin
					$display("FAIL atg_su_fetch.order at %0d: warp %0d pc %0d", n_out, d_warp,
						d_pc);
					errors = errors + 1;
				end
				n_out = n_out + 1;
			end
		end
	end
	always @(negedge clk) begin
		if (rst_n && !f_valid && n_in < N && ($random(seed) & 1)) begin
			f_valid = 1'b1;
			f_warp = n_in % 4;
			f_pc = n_in;
			f_addr = n_in * 8 + 32'h4000;
		end
	end

	initial begin
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		wait (n_out == N);
		repeat (5) @(negedge clk);
		if (errors == 0 && !d_valid) begin
			$display("PASS atg_su_fetch.order");
			$display("PASS atg_su_fetch");
		end
		$finish;
	end

	initial begin
		#1000000;
		$display("FAIL atg_su_fetch timeout (%0d out)", n_out);
		$finish;
	end
endmodule

`default_nettype wire
