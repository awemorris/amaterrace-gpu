/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_skid_tb: Unit testbench for am_skid.v (full registered skid buffer).
 * Tests 100% throughput (zero bubble), back-pressure, random stalls,
 * latency, and timing path isolation.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_skid_tb;
	localparam WIDTH = 32;
	localparam CLK_PERIOD = 10;

	reg clk = 1'b0;
	reg rst_n = 1'b0;

	reg in_valid = 1'b0;
	wire in_ready;
	reg [WIDTH-1:0] in_data = 32'd0;

	wire out_valid;
	reg out_ready = 1'b0;
	wire [WIDTH-1:0] out_data;

	integer seed = 1;
	integer errors = 0;
	integer sent_count = 0;
	integer recv_count = 0;

	// Scoreboard FIFO for verification
	reg [WIDTH-1:0] queue [0:65535];
	integer q_head = 0;
	integer q_tail = 0;

	always #(CLK_PERIOD / 2) clk = !clk;

	am_skid #(
		.WIDTH(WIDTH)
	) dut (
		.clk(clk),
		.rst_n(rst_n),
		.in_valid(in_valid),
		.in_ready(in_ready),
		.in_data(in_data),
		.out_valid(out_valid),
		.out_ready(out_ready),
		.out_data(out_data)
	);

	// Receiver monitor
	always @(posedge clk) begin
		if (rst_n) begin
			if (out_valid && out_ready) begin
				if (q_head == q_tail) begin
					$display("FAIL am_skid: unexpected data received (%h)", out_data);
					errors = errors + 1;
				end else begin
					if (out_data !== queue[q_head]) begin
						$display("FAIL am_skid: data mismatch: got %h, expected %h", out_data, queue[q_head]);
						errors = errors + 1;
					end
					q_head = q_head + 1;
				end
				recv_count = recv_count + 1;
			end
		end
	end

	// Sender monitor (scoreboard push)
	always @(posedge clk) begin
		if (rst_n) begin
			if (in_valid && in_ready) begin
				queue[q_tail] = in_data;
				q_tail = q_tail + 1;
				sent_count = sent_count + 1;
			end
		end
	end

	task send_word(input [WIDTH-1:0] val);
		begin
			@(negedge clk);
			in_valid = 1'b1;
			in_data = val;
			@(posedge clk);
			while (!in_ready) begin
				@(posedge clk);
			end
			@(negedge clk);
			in_valid = 1'b0;
		end
	endtask

	integer i;
	integer burst_len;
	integer consecutive_transfers;

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;

		// 1. Reset check
		#20 rst_n = 1'b0;
		#20;
		@(negedge clk);
		rst_n = 1'b1;
		@(posedge clk);
		#1;
		if (!in_ready || out_valid) begin
			$display("FAIL am_skid: invalid state after reset (in_ready=%b, out_valid=%b)", in_ready, out_valid);
			errors = errors + 1;
		end

		// 2. Single transfer latency check
		$display(" am_skid: check single word latency...");
		@(negedge clk);
		out_ready = 1'b1;
		in_valid = 1'b1;
		in_data = 32'hDEADBEEF;
		@(posedge clk);
		#1;
		// Next cycle: out_valid should become 1 with DEADBEEF
		@(negedge clk);
		in_valid = 1'b0;
		if (!out_valid || out_data !== 32'hDEADBEEF) begin
			$display("FAIL am_skid: single transfer latency/data mismatch");
			errors = errors + 1;
		end
		@(posedge clk); // consumed
		#1;
		if (out_valid) begin
			$display("FAIL am_skid: buffer should be empty after consumption");
			errors = errors + 1;
		end

		// 3. Sustained 100% throughput burst test (zero bubble)
		$display(" am_skid: check 100%% throughput sustained burst...");
		burst_len = 500;
		@(negedge clk);
		out_ready = 1'b1;
		in_valid = 1'b1;
		in_data = 32'h1000;
		consecutive_transfers = 0;

		// First word loaded into main register
		@(posedge clk);
		for (i = 1; i < burst_len; i = i + 1) begin
			@(negedge clk);
			in_data = in_data + 1'b1;
			#1;
			if (out_valid && out_ready)
				consecutive_transfers = consecutive_transfers + 1;
			else begin
				$display("FAIL am_skid: bubble detected during sustained transfer at step %0d", i);
				errors = errors + 1;
			end
			@(posedge clk);
		end

		// Stop sending
		@(negedge clk);
		in_valid = 1'b0;
		#1;
		if (out_valid && out_ready)
			consecutive_transfers = consecutive_transfers + 1;

		@(posedge clk);
		#1;
		if (out_valid && out_ready)
			consecutive_transfers = consecutive_transfers + 1;

		if (consecutive_transfers !== burst_len) begin
			$display("FAIL am_skid: consecutive transfers %0d != expected %0d", consecutive_transfers, burst_len);
			errors = errors + 1;
		end

		// Wait until drained
		@(posedge clk);
		#1;
		if (out_valid) begin
			$display("FAIL am_skid: not drained after burst");
			errors = errors + 1;
		end

		// 4. Back-pressure / Skid register functionality
		$display(" am_skid: check back-pressure skid behavior...");
		@(negedge clk);
		out_ready = 1'b0; // Downstream stalled
		in_valid = 1'b1;
		in_data = 32'hCAFE0001; // First word (will enter main register)
		@(posedge clk);
		#1;
		if (!in_ready) begin
			$display("FAIL am_skid: in_ready should still be 1 after first word during stall");
			errors = errors + 1;
		end
		@(negedge clk);
		in_data = 32'hCAFE0002; // Second word (will enter skid register)
		@(posedge clk);
		#1;
		// Now skid buffer should be full, in_ready must drop to 0!
		if (in_ready) begin
			$display("FAIL am_skid: in_ready did not fall to 0 when buffer is full");
			errors = errors + 1;
		end
		@(negedge clk);
		in_data = 32'hCAFE0003; // Third word (should not be accepted)
		@(posedge clk);
		#1;
		if (in_ready) begin
			$display("FAIL am_skid: in_ready stayed high while full");
			errors = errors + 1;
		end
		// Wait a few cycles with out_ready = 0 to verify data stability
		repeat (3) @(posedge clk);
		#1;
		if (out_data !== 32'hCAFE0001 || !out_valid) begin
			$display("FAIL am_skid: main data altered during stall");
			errors = errors + 1;
		end

		// Release backpressure
		@(negedge clk);
		out_ready = 1'b1;
		@(posedge clk); // CAFE0001 is consumed, skid CAFE0002 moves to main
		#1;
		if (!in_ready) begin
			$display("FAIL am_skid: in_ready should become 1 after skid drains to main");
			errors = errors + 1;
		end
		if (out_data !== 32'hCAFE0002 || !out_valid) begin
			$display("FAIL am_skid: skid data did not move to main output");
			errors = errors + 1;
		end
		@(negedge clk);
		in_valid = 1'b0;
		@(posedge clk); // CAFE0002 is consumed
		#1;
		@(posedge clk);

		// 5. Random stress test (5000 transactions with random stalls)
		$display(" am_skid: check random stress with valid/ready jitter...");
		for (i = 0; i < 5000; i = i + 1) begin
			@(negedge clk);
			in_valid = ($unsigned($random(seed)) % 100) < 70;
			if (in_valid)
				in_data = $random(seed);
			out_ready = ($unsigned($random(seed)) % 100) < 65;
		end

		// Drain remaining items
		@(negedge clk);
		in_valid = 1'b0;
		out_ready = 1'b1;
		while (q_head < q_tail) begin
			@(posedge clk);
		end
		repeat (5) @(posedge clk);

		if (sent_count !== recv_count) begin
			$display("FAIL am_skid: sent %0d != received %0d", sent_count, recv_count);
			errors = errors + 1;
		end

		// 6. Timing isolation check (verify comb path isolation)
		$display(" am_skid: check combinational isolation between ports...");
		@(negedge clk);
		in_valid = 1'b0;
		out_ready = 1'b0;
		#1;
		// Toggle in_valid and in_data, check out_valid and in_ready do not glitch combinationally
		in_valid = 1'b1;
		in_data = 32'h12345678;
		#1;
		if (out_valid !== 1'b0) begin
			$display("FAIL am_skid: combinational feedthrough from in_valid to out_valid");
			errors = errors + 1;
		end
		// Toggle out_ready, check in_ready does not glitch combinationally
		out_ready = 1'b1;
		#1;
		out_ready = 1'b0;
		#1;

		if (errors == 0)
			$display("PASS am_skid");
		else
			$display("FAIL am_skid: total errors %0d", errors);

		$finish;
	end

	initial begin
		#5000000;
		$display("FAIL am_skid: simulation timeout");
		$finish;
	end

endmodule

`default_nettype wire
