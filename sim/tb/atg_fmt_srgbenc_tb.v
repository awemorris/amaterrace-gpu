/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_srgbenc_tb: atg_fmt_srgbenc against tools/fmtmodel.py
 * (sim/vec/fmt_srgbenc.txt: every threshold and the fp32 on each side of
 * it, every decoded code, the specials (0, -0, 1, +infinity, NaN, -1,
 * values above 1) and random values in [2^-37, 1)).  The values go in back
 * to back with random gaps and random o_ready (seeded); each code must
 * come out once, in order, 9 cycles after its accept, and i_ready must be
 * low while one is in flight.  Prints "PASS atg_fmt_srgbenc.exhaustive"
 * and "PASS atg_fmt_srgbenc".
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_srgbenc_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg i_valid = 1'b0;
	reg [31:0] i_x = 32'd0;
	reg o_ready = 1'b0;
	wire i_ready, o_valid;
	wire [7:0] o_code;

	atg_fmt_srgbenc dut (.clk(clk), .rst_n(rst_n), .i_valid(i_valid), .i_ready(i_ready),
		.i_x(i_x), .o_valid(o_valid), .o_ready(o_ready), .o_code(o_code));

	integer fd, code, seed, n, errors, cyc, t_acc, i;
	reg [31:0] xs [0:4095];
	reg [7:0] want [0:4095];
	integer nx, nin, nout;

	always @(posedge clk) begin
		cyc <= cyc + 1;
		if (rst_n) begin
			if (i_ready && nin != nout) begin
				errors = errors + 1;
				$display("FAIL atg_fmt_srgbenc: i_ready with one in flight");
			end
			if (i_valid && i_ready) begin
				t_acc = cyc;
				nin = nin + 1;
			end
			if (o_valid && o_ready) begin
				if (o_code !== want[nout]) begin
					errors = errors + 1;
					if (errors < 10)
						$display("FAIL atg_fmt_srgbenc: x %h: %h, want %h", xs[nout],
							o_code, want[nout]);
				end
				nout = nout + 1;
			end
		end
	end

	/* o_valid exactly 9 cycles after the accept */
	reg ov_q = 1'b0;
	always @(posedge clk) begin
		ov_q <= o_valid;
		if (rst_n && o_valid && !ov_q && cyc - t_acc != 9) begin
			errors = errors + 1;
			$display("FAIL atg_fmt_srgbenc: o_valid %0d cycles after the accept", cyc - t_acc);
		end
	end

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		errors = 0;
		cyc = 0;
		t_acc = 0;
		nx = 0;
		nin = 0;
		nout = 0;
		fd = $fopen("sim/vec/fmt_srgbenc.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_fmt_srgbenc: no sim/vec/fmt_srgbenc.txt");
			$finish;
		end
		while (!$feof(fd)) begin
			code = $fscanf(fd, "%h %h\n", xs[nx], want[nx]);
			if (code == 2)
				nx = nx + 1;
		end
		$fclose(fd);
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		fork
			begin
				for (i = 0; i < nx; i = i + 1) begin
					repeat ($unsigned($random(seed)) % 3) @(posedge clk);
					i_valid <= 1'b1;
					i_x <= xs[i];
					@(posedge clk);
					while (!i_ready)
						@(posedge clk);
					i_valid <= 1'b0;
				end
			end
			begin
				while (nout < nx) begin
					o_ready <= ($random(seed) & 3) != 0;
					@(posedge clk);
				end
			end
		join
		o_ready <= 1'b0;
		repeat (4) @(posedge clk);
		if (errors == 0 && nout == nx && nx > 1500)
			$display("PASS atg_fmt_srgbenc.exhaustive (%0d values)", nx);
		else
			$display("FAIL atg_fmt_srgbenc.exhaustive: %0d errors, %0d of %0d", errors, nout, nx);
		if (errors == 0 && nout == nx && nx > 1500)
			$display("PASS atg_fmt_srgbenc");
		else
			$display("FAIL atg_fmt_srgbenc: %0d errors", errors);
		$finish;
	end

	initial begin
		#5000000;
		$display("FAIL atg_fmt_srgbenc: timeout");
		$finish;
	end
endmodule

`default_nettype wire
