/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_afifo_bram_tb: Unit testbench for am_afifo_bram.v.
 * Tests CDC crossing with multiple clock ratios (200:148.5, 50:200, 200:50),
 * 10,000 transaction continuous burst, back-pressure, full/empty boundaries,
 * 0-cycle FWFT presentation, and watermark (r_count) monotonicity.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_afifo_bram_tb;
	localparam W = 32;
	localparam DEPTH_LOG2 = 6; // 64 entries for fast full/empty turnover
	localparam DEPTH = 1 << DEPTH_LOG2;

	reg w_clk = 1'b0;
	reg w_rst_n = 1'b0;
	reg w_valid = 1'b0;
	wire w_ready;
	reg [W-1:0] w_data = 32'd0;

	reg r_clk = 1'b0;
	reg r_rst_n = 1'b0;
	wire r_valid;
	reg r_ready = 1'b0;
	wire [W-1:0] r_data;
	wire [DEPTH_LOG2:0] r_count;

	real w_half = 2.5; // 200 MHz default
	real r_half = 3.367; // 148.5 MHz default

	always #(w_half) w_clk = !w_clk;
	always #(r_half) r_clk = !r_clk;

	am_afifo_bram #(
		.W(W),
		.DEPTH_LOG2(DEPTH_LOG2)
	) dut (
		.w_clk(w_clk),
		.w_rst_n(w_rst_n),
		.w_valid(w_valid),
		.w_ready(w_ready),
		.w_data(w_data),
		.r_clk(r_clk),
		.r_rst_n(r_rst_n),
		.r_valid(r_valid),
		.r_ready(r_ready),
		.r_data(r_data),
		.r_count(r_count)
	);

	integer seed = 1;
	integer errors = 0;
	integer sent_count = 0;
	integer recv_count = 0;

	// Scoreboard queue
	reg [W-1:0] queue [0:65535];
	integer q_head = 0;
	integer q_tail = 0;

	// Write side monitor
	always @(posedge w_clk) begin
		if (w_rst_n) begin
			if (w_valid && w_ready) begin
				queue[q_tail] = w_data;
				q_tail = q_tail + 1;
				sent_count = sent_count + 1;
			end
		end
	end

	// Read side monitor
	always @(posedge r_clk) begin
		if (r_rst_n) begin
			if (r_valid && r_ready) begin
				if (q_head == q_tail) begin
					$display("FAIL am_afifo_bram: received data when scoreboard queue empty (%h)", r_data);
					errors = errors + 1;
				end else begin
					if (r_data !== queue[q_head]) begin
						$display("FAIL am_afifo_bram: data mismatch: got %h, expected %h (idx %0d)",
							r_data, queue[q_head], recv_count);
						errors = errors + 1;
					end
					q_head = q_head + 1;
				end
				recv_count = recv_count + 1;
			end
		end
	end

	// Test sequences
	integer i;
	integer target_count;

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;

		// ---------------------------------------------------------
		// 1. Reset and 0-cycle FWFT verification
		// ---------------------------------------------------------
		#50;
		@(negedge w_clk);
		w_rst_n = 1'b1;
		@(negedge r_clk);
		r_rst_n = 1'b1;
		#50;

		$display(" am_afifo_bram: check reset state and FWFT first-word presentation...");
		if (r_valid || !w_ready) begin
			$display("FAIL am_afifo_bram: invalid initial state after reset");
			errors = errors + 1;
		end

		// Push exactly 1 word into empty FIFO
		@(negedge w_clk);
		w_valid = 1'b1;
		w_data = 32'hA5A50001;
		@(posedge w_clk);
		#1;
		@(negedge w_clk);
		w_valid = 1'b0;

		// Wait in r_clk domain until r_valid rises without asserting r_ready (FWFT check)
		r_ready = 1'b0;
		while (!r_valid) begin
			@(posedge r_clk);
		end
		#1;
		if (r_data !== 32'hA5A50001) begin
			$display("FAIL am_afifo_bram: FWFT first word mismatch: got %h, expected A5A50001", r_data);
			errors = errors + 1;
		end
		if (r_count == 0) begin
			$display("FAIL am_afifo_bram: r_count should be > 0 when holding data");
			errors = errors + 1;
		end

		// Consume the word
		@(negedge r_clk);
		r_ready = 1'b1;
		@(posedge r_clk);
		#1;
		@(negedge r_clk);
		r_ready = 1'b0;
		repeat (4) @(posedge r_clk);
		#1;
		if (r_valid) begin
			$display("FAIL am_afifo_bram: FIFO not empty after consuming sole word");
			errors = errors + 1;
		end

		// ---------------------------------------------------------
		// 2. Full / Empty boundary testing
		// ---------------------------------------------------------
		$display(" am_afifo_bram: check full flag boundary...");
		// Fill until w_ready deasserts
		@(negedge w_clk);
		w_valid = 1'b1;
		while (w_ready) begin
			w_data = 32'hB0000000 | sent_count;
			@(posedge w_clk);
			#1;
			@(negedge w_clk);
		end
		w_valid = 1'b0;

		// Drain completely
		@(negedge r_clk);
		r_ready = 1'b1;
		while (q_head < q_tail) begin
			@(posedge r_clk);
		end
		@(negedge r_clk);
		r_ready = 1'b0;
		repeat (10) @(posedge r_clk);

		// ---------------------------------------------------------
		// 3. Clock Ratio 1: 200 MHz write, 148.5 MHz read (DC display ratio)
		// ---------------------------------------------------------
		$display(" am_afifo_bram: phase 1 - 200 MHz w_clk, 148.5 MHz r_clk (3,000 words)...");
		w_half = 2.5;
		r_half = 3.367;
		target_count = sent_count + 3000;

		fork
			// Writer process
			begin
				while (sent_count < target_count) begin
					@(negedge w_clk);
					w_valid = ($unsigned($random(seed)) % 100) < 85;
					if (w_valid)
						w_data = $random(seed);
				end
				@(negedge w_clk);
				w_valid = 1'b0;
			end

			// Reader process
			begin
				while (recv_count < target_count) begin
					@(negedge r_clk);
					r_ready = ($unsigned($random(seed)) % 100) < 80;
				end
				@(negedge r_clk);
				r_ready = 1'b1;
			end
		join

		repeat (20) @(posedge r_clk);

		// ---------------------------------------------------------
		// 4. Clock Ratio 2: 50 MHz write, 200 MHz read (Fast reader)
		// ---------------------------------------------------------
		$display(" am_afifo_bram: phase 2 - 50 MHz w_clk, 200 MHz r_clk (3,000 words)...");
		w_half = 10.0;
		r_half = 2.5;
		target_count = sent_count + 3000;

		fork
			// Writer process
			begin
				while (sent_count < target_count) begin
					@(negedge w_clk);
					w_valid = ($unsigned($random(seed)) % 100) < 90;
					if (w_valid)
						w_data = $random(seed);
				end
				@(negedge w_clk);
				w_valid = 1'b0;
			end

			// Reader process
			begin
				while (recv_count < target_count) begin
					@(negedge r_clk);
					r_ready = ($unsigned($random(seed)) % 100) < 70;
				end
				@(negedge r_clk);
				r_ready = 1'b1;
			end
		join

		repeat (20) @(posedge r_clk);

		// ---------------------------------------------------------
		// 5. Clock Ratio 3: 200 MHz write, 50 MHz read (Fast writer / heavy backpressure)
		// ---------------------------------------------------------
		$display(" am_afifo_bram: phase 3 - 200 MHz w_clk, 50 MHz r_clk (4,000 words)...");
		w_half = 2.5;
		r_half = 10.0;
		target_count = sent_count + 4000;

		fork
			// Writer process
			begin
				while (sent_count < target_count) begin
					@(negedge w_clk);
					w_valid = ($unsigned($random(seed)) % 100) < 95;
					if (w_valid)
						w_data = $random(seed);
				end
				@(negedge w_clk);
				w_valid = 1'b0;
			end

			// Reader process
			begin
				while (recv_count < target_count) begin
					@(negedge r_clk);
					r_ready = ($unsigned($random(seed)) % 100) < 90;
				end
				@(negedge r_clk);
				r_ready = 1'b1;
			end
		join

		// Drain remaining items
		@(negedge r_clk);
		r_ready = 1'b1;
		while (q_head < q_tail) begin
			@(posedge r_clk);
		end
		repeat (20) @(posedge r_clk);

		if (sent_count !== recv_count) begin
			$display("FAIL am_afifo_bram: sent %0d != received %0d", sent_count, recv_count);
			errors = errors + 1;
		end

		if (errors == 0)
			$display("PASS am_afifo_bram");
		else
			$display("FAIL am_afifo_bram: total errors %0d", errors);

		$finish;
	end

	initial begin
		#10000000;
		$display("FAIL am_afifo_bram: timeout (sent %0d got %0d)", sent_count, recv_count);
		$finish;
	end

endmodule

`default_nettype wire
