/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_afifo_tb: pushes a counting sequence through am_afifo between two
 * unrelated clocks (10 ns and 7.3 ns, then swapped) with random valid and
 * ready, and checks that every word comes out once and in order, that the
 * FIFO fills (w_ready falls) and drains.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_afifo_tb;
	localparam W = 16;
	localparam N = 3000;

	reg w_clk = 1'b0;
	reg r_clk = 1'b0;
	reg rst_n = 1'b0;
	reg w_valid = 1'b0;
	wire w_ready;
	reg [W-1:0] w_data = 0;
	wire r_valid;
	reg r_ready = 1'b0;
	wire [W-1:0] r_data;

	real w_half = 5.0;
	real r_half = 3.65;
	integer seed = 1;
	integer sent = 0;
	integer got = 0;
	integer errors = 0;
	integer full_seen = 0;
	integer phase = 0;

	always #(w_half) w_clk = !w_clk;
	always #(r_half) r_clk = !r_clk;

	am_afifo #(.W(W), .DEPTH_LOG2(3)) dut (
		.w_clk(w_clk),
		.w_rst_n(rst_n),
		.w_valid(w_valid),
		.w_ready(w_ready),
		.w_data(w_data),
		.r_clk(r_clk),
		.r_rst_n(rst_n),
		.r_valid(r_valid),
		.r_ready(r_ready),
		.r_data(r_data)
	);

	always @(posedge w_clk) begin
		if (rst_n) begin
			if (w_valid && w_ready) begin
				sent = sent + 1;
				w_data <= w_data + 1'b1;
			end
			if (w_valid && !w_ready)
				full_seen = full_seen + 1;
			w_valid <= sent < N * (phase + 1) && ($unsigned($random(seed)) % 100) < (phase == 0 ? 90 : 30);
		end
	end

	always @(posedge r_clk) begin
		if (rst_n) begin
			if (r_valid && r_ready) begin
				if (r_data !== got[W-1:0]) begin
					errors = errors + 1;
					$display("FAIL am_afifo: got %h, expected %h", r_data, got[W-1:0]);
				end
				got = got + 1;
			end
			r_ready <= ($unsigned($random(seed)) % 100) < (phase == 0 ? 30 : 90);
		end
	end

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;
		#100 rst_n = 1'b1;
		wait (got == N);
		/* Swap the clocks' speeds and the pressure: now the reader is
		 * fast and the writer slow. */
		phase = 1;
		w_half = 3.65;
		r_half = 5.0;
		wait (got == 2 * N);
		#200;
		if (full_seen == 0) begin
			errors = errors + 1;
			$display("FAIL am_afifo: never full");
		end
		if (r_valid) begin
			errors = errors + 1;
			$display("FAIL am_afifo: not empty at the end");
		end
		if (errors == 0)
			$display("PASS am_afifo");
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL am_afifo: timeout (sent %0d got %0d)", sent, got);
		$finish;
	end
endmodule

`default_nettype wire
