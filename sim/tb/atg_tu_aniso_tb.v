/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_aniso_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg req_valid = 1'b0;
	wire req_ready;
	reg [31:0] dudx = 0;
	reg [31:0] dudy = 0;
	reg [31:0] dvdx = 0;
	reg [31:0] dvdy = 0;
	reg [3:0] max_aniso = 0;

	wire samp_valid;
	reg samp_ready = 1'b1;
	wire [31:0] samp_u;
	wire [31:0] samp_v;
	wire [16:0] samp_weight;

	reg filt_valid = 1'b0;
	reg [31:0] filt_texel = 0;
	wire res_valid;
	wire [31:0] res_texel;

	atg_tu_aniso #(.MAX_SAMPLES(16)) dut (
		.clk(clk),
		.rst_n(rst_n),
		.req_valid(req_valid),
		.req_ready(req_ready),
		.dudx(dudx),
		.dudy(dudy),
		.dvdx(dvdx),
		.dvdy(dvdy),
		.max_aniso(max_aniso),
		.samp_valid(samp_valid),
		.samp_ready(samp_ready),
		.samp_u(samp_u),
		.samp_v(samp_v),
		.samp_weight(samp_weight),
		.filt_valid(filt_valid),
		.filt_texel(filt_texel),
		.res_valid(res_valid),
		.res_texel(res_texel)
	);

	integer errors = 0;
	integer sample_count = 0;
	integer total_weight = 0;
	integer timeout = 0;

	task reset_dut;
		begin
			rst_n = 1'b0;
			req_valid = 1'b0;
			samp_ready = 1'b1;
			filt_valid = 1'b0;
			filt_texel = 0;
			repeat (4) @(posedge clk);
			rst_n = 1'b1;
			repeat (2) @(posedge clk);
		end
	endtask

	task run_test;
		input [31:0] t_dudx;
		input [31:0] t_dudy;
		input [31:0] t_dvdx;
		input [31:0] t_dvdy;
		input [3:0]  t_max_aniso;
		input integer exp_samples;
		input [31:0] uniform_color;
		input [31:0] exp_color;

		integer i;
		reg [31:0] saved_samples [0:15];
		reg [16:0] saved_weights [0:15];
		begin
			sample_count = 0;
			total_weight = 0;

			// Wait until ready with timeout
			timeout = 0;
			while (!req_ready && timeout < 1000) begin
				@(posedge clk);
				timeout = timeout + 1;
			end
			if (timeout >= 1000) begin
				$display("FAIL: TIMEOUT waiting for req_ready");
				errors = errors + 1;
			end

			// Issue request
			@(posedge clk);
			req_valid <= 1'b1;
			dudx <= t_dudx;
			dudy <= t_dudy;
			dvdx <= t_dvdx;
			dvdy <= t_dvdy;
			max_aniso <= t_max_aniso;

			@(posedge clk);
			req_valid <= 1'b0;

			// Collect samples as they are produced with timeout
			timeout = 0;
			while (sample_count < exp_samples && timeout < 1000) begin
				@(posedge clk);
				timeout = timeout + 1;
				if (samp_valid && samp_ready) begin
					saved_samples[sample_count] = samp_u;
					saved_weights[sample_count] = samp_weight;
					sample_count = sample_count + 1;
					total_weight = total_weight + samp_weight;
				end
			end
			if (timeout >= 1000) begin
				$display("FAIL: TIMEOUT collecting samples (got %0d of %0d)", sample_count, exp_samples);
				errors = errors + 1;
			end

			// Verify sample count
			if (sample_count != exp_samples) begin
				$display("FAIL: expected %0d samples, got %0d", exp_samples, sample_count);
				errors = errors + 1;
			end

			// Verify total pre-normalized weight sums to 65536
			if (total_weight != 65536) begin
				$display("FAIL: total weight sum %0d != 65536", total_weight);
				errors = errors + 1;
			end

			// Feed back the filtered texels sequentially
			for (i = 0; i < exp_samples; i = i + 1) begin
				@(posedge clk);
				filt_valid <= 1'b1;
				filt_texel <= uniform_color;
			end
			@(posedge clk);
			filt_valid <= 1'b0;

			// Wait for res_valid with timeout
			timeout = 0;
			while (!res_valid && timeout < 1000) begin
				@(posedge clk);
				timeout = timeout + 1;
			end
			if (timeout >= 1000) begin
				$display("FAIL: TIMEOUT waiting for res_valid");
				errors = errors + 1;
			end

			// Check result texel
			if (res_texel !== exp_color) begin
				$display("FAIL: res_texel 0x%08x != expected 0x%08x", res_texel, exp_color);
				errors = errors + 1;
			end else begin
				$display("PASS: test with exp_samples=%0d color=0x%08x", exp_samples, res_texel);
			end
			@(posedge clk);
		end
	endtask

	initial begin
		$display("Starting atg_tu_aniso_tb...");
		reset_dut();

		// Test 1: Isotropic 1:1 ratio (dudx=1.0, dvdy=1.0) -> 1 sample
		// Q16.16: 1.0 = 32'h0001_0000
		run_test(32'h0001_0000, 32'd0, 32'd0, 32'h0001_0000, 4'd0, 1, 32'hAABBCCDD, 32'hAABBCCDD);

		// Test 2: Anisotropic 16:1 ratio (dudx=16.0, dvdy=1.0), max_aniso = 0 (16x) -> 16 samples
		// Q16.16: 16.0 = 32'h0010_0000
		run_test(32'h0010_0000, 32'd0, 32'd0, 32'h0001_0000, 4'd0, 16, 32'h80402010, 32'h80402010);

		// Test 3: Anisotropic 16:1 ratio, clamped to max_aniso = 4 -> 4 samples
		run_test(32'h0010_0000, 32'd0, 32'd0, 32'h0001_0000, 4'd4, 4, 32'hFF00AA55, 32'hFF00AA55);

		// Test 4: Anisotropic 16:1 ratio, clamped to max_aniso = 8 -> 8 samples
		run_test(32'h0010_0000, 32'd0, 32'd0, 32'h0001_0000, 4'd8, 8, 32'h11223344, 32'h11223344);

		// Test 5: Major axis along Y (dudy=8.0, dvdx=1.0) -> 8 samples
		run_test(32'd0, 32'h0008_0000, 32'h0001_0000, 32'd0, 4'd0, 8, 32'hCAFE1234, 32'hCAFE1234);

		// Test 6: Anisotropic 2:1 ratio (dudx=2.0, dvdy=1.0) -> 2 samples
		run_test(32'h0002_0000, 32'd0, 32'd0, 32'h0001_0000, 4'd0, 2, 32'h55AA33CC, 32'h55AA33CC);

		// Test 7: Non-uniform texel accumulation with bubbles between filt_valid
		// N=2: sample 0 gets 0x00000000, sample 1 gets 0xFFFFFFFF
		// Weights for N=2 are 32768 each -> result channel: (0*32768 + 255*32768)/65536 = 127 = 0x7F
		begin : test7
			integer t_to;
			sample_count = 0;
			total_weight = 0;
			t_to = 0;
			while (!req_ready && t_to < 1000) begin
				@(posedge clk);
				t_to = t_to + 1;
			end
			@(posedge clk);
			req_valid <= 1'b1;
			dudx <= 32'h0002_0000;
			dudy <= 32'd0;
			dvdx <= 32'd0;
			dvdy <= 32'h0001_0000;
			max_aniso <= 4'd0;
			@(posedge clk);
			req_valid <= 1'b0;

			t_to = 0;
			while (sample_count < 2 && t_to < 1000) begin
				@(posedge clk);
				t_to = t_to + 1;
				if (samp_valid && samp_ready) begin
					sample_count = sample_count + 1;
				end
			end

			// Feed sample 0 with 0x00000000
			@(posedge clk);
			filt_valid <= 1'b1;
			filt_texel <= 32'h00000000;
			@(posedge clk);
			filt_valid <= 1'b0;

			// Bubble for 3 cycles
			repeat (3) @(posedge clk);

			// Feed sample 1 with 0xFFFFFFFF
			filt_valid <= 1'b1;
			filt_texel <= 32'hFFFFFFFF;
			@(posedge clk);
			filt_valid <= 1'b0;

			t_to = 0;
			while (!res_valid && t_to < 1000) begin
				@(posedge clk);
				t_to = t_to + 1;
			end
			if (t_to >= 1000) begin
				$display("FAIL: TIMEOUT waiting for res_valid in test 7");
				errors = errors + 1;
			end else if (res_texel !== 32'h7F7F7F7F) begin
				$display("FAIL: test 7 non-uniform texel 0x%08x != expected 0x7F7F7F7F", res_texel);
				errors = errors + 1;
			end else begin
				$display("PASS: test 7 non-uniform with bubble cycles color=0x%08x", res_texel);
			end
			@(posedge clk);
		end

		// Test 8: Backpressure on samp_ready (stall downstream)
		begin : test8
			integer t_to, i;
			sample_count = 0;
			total_weight = 0;
			t_to = 0;
			while (!req_ready && t_to < 1000) begin
				@(posedge clk);
				t_to = t_to + 1;
			end
			@(posedge clk);
			req_valid <= 1'b1;
			dudx <= 32'h0004_0000;
			dudy <= 32'd0;
			dvdx <= 32'd0;
			dvdy <= 32'h0001_0000;
			max_aniso <= 4'd0;
			@(posedge clk);
			req_valid <= 1'b0;

			t_to = 0;
			while (sample_count < 4 && t_to < 1000) begin
				@(posedge clk);
				t_to = t_to + 1;
				// Toggle samp_ready every 2 cycles
				samp_ready <= !samp_ready;
				if (samp_valid && samp_ready) begin
					sample_count = sample_count + 1;
				end
			end
			samp_ready <= 1'b1;

			// Feed back 4 texels
			for (i = 0; i < 4; i = i + 1) begin
				@(posedge clk);
				filt_valid <= 1'b1;
				filt_texel <= 32'h12345678;
			end
			@(posedge clk);
			filt_valid <= 1'b0;

			t_to = 0;
			while (!res_valid && t_to < 1000) begin
				@(posedge clk);
				t_to = t_to + 1;
			end
			if (t_to >= 1000) begin
				$display("FAIL: TIMEOUT waiting for res_valid in test 8");
				errors = errors + 1;
			end else if (res_texel !== 32'h12345678) begin
				$display("FAIL: test 8 stalled result 0x%08x != expected 0x12345678", res_texel);
				errors = errors + 1;
			end else begin
				$display("PASS: test 8 backpressure / stall test color=0x%08x", res_texel);
			end
			@(posedge clk);
		end

		if (errors == 0) begin
			$display("PASS atg_tu_aniso");
		end else begin
			$display("FAIL atg_tu_aniso with %0d errors", errors);
		end
		$finish;
	end

endmodule

`default_nettype wire
