/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_order_tb: consecutive sequence numbers from 0, ord_* echoing each
 * issue, the 16-bit wrap.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_order_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;
	reg sq_req = 1'b0;
	wire [15:0] sq_seq, ord_seq;
	wire ord_valid;
	integer errors = 0;
	integer i, seed;
	reg [15:0] want;

	atg_rx_order dut (.clk(clk), .rst_n(rst_n), .sq_req(sq_req), .sq_seq(sq_seq),
		.ord_valid(ord_valid), .ord_seq(ord_seq));

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		repeat (2) @(posedge clk);
		rst_n <= 1'b1;
		want = 16'd0;
		for (i = 0; i < 100000; i = i + 1) begin
			sq_req <= ($random(seed) & 3) != 0;
			@(posedge clk);
			#1;
			if (sq_req) begin
				want = want + 16'd1;
			end
			if (sq_seq !== want) begin
				errors = errors + 1;
				if (errors < 10)
					$display("FAIL atg_rx_order: seq %h, expected %h", sq_seq, want);
			end
		end
		sq_req <= 1'b1;
		#1;
		if (!ord_valid || ord_seq !== sq_seq) begin
			errors = errors + 1;
			$display("FAIL atg_rx_order: ord %b %h, seq %h", ord_valid, ord_seq, sq_seq);
		end
		if (want > 16'd20000) begin
			errors = errors + 1;	/* 100000 x 3/4 issues wrap past 0 */
			$display("FAIL atg_rx_order: no wrap (%h)", want);
		end
		if (errors == 0)
			$display("PASS atg_rx_order.seq");
		if (errors == 0)
			$display("PASS atg_rx_order");
		$finish;
	end
endmodule

`default_nettype wire
