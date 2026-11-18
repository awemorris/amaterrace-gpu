/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_fp_tb: atg_rx_fadd, atg_rx_fmul and atg_rx_fdiv against the
 * reference model's results (sim/vec/rx_fp.hex from tools/rx-vectors.py:
 * random operands, special values, near cancellation, overflow and
 * underflow).  The adder and the multiplier get one operation per cycle
 * (their pipelines full); the divider one at a time.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_fp_tb;
	localparam N = 6000;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg [127:0] vec [0:N-1];
	integer errors = 0;
	integer i, j, nadd, nmul, ndiv, fd, code;
	reg [3:0] op;
	reg [31:0] a, b, r;

	reg av = 1'b0, asub = 1'b0, mv = 1'b0, ds = 1'b0;
	reg [31:0] aa = 0, ab = 0, ma = 0, mb = 0, da = 0, db = 0;
	wire aov, mov, dbusy, ddone;
	wire [31:0] ar, mr, dr;

	am_fp_add #(.LAT(4)) add (.clk(clk), .rst_n(rst_n), .i_valid(av), .i_a(aa), .i_b(ab),
		.i_sub(asub), .o_valid(aov), .o_r(ar));
	am_fp_mul #(.LAT(4)) mul (.clk(clk), .rst_n(rst_n), .i_valid(mv), .i_a(ma), .i_b(mb),
		.o_valid(mov), .o_r(mr));
	atg_rx_fdiv div (.clk(clk), .rst_n(rst_n), .i_start(ds), .i_a(da), .i_b(db),
		.busy(dbusy), .o_done(ddone), .o_r(dr));

	/* Expected results of the pipelines, in issue order. */
	reg [31:0] aexp [0:N-1];
	reg [63:0] ain [0:N-1];
	reg [31:0] mexp [0:N-1];
	reg [63:0] min_ [0:N-1];
	integer ahead = 0, atail = 0, mhead = 0, mtail = 0;

	always @(posedge clk) begin
		if (aov) begin
			if (ar !== aexp[ahead]) begin
				errors = errors + 1;
				if (errors < 20)
					$display("FAIL atg_rx_fp: add %h %h = %h, expected %h",
						ain[ahead][63:32], ain[ahead][31:0], ar, aexp[ahead]);
			end
			ahead = ahead + 1;
		end
		if (mov) begin
			if (mr !== mexp[mhead]) begin
				errors = errors + 1;
				if (errors < 20)
					$display("FAIL atg_rx_fp: mul %h %h = %h, expected %h",
						min_[mhead][63:32], min_[mhead][31:0], mr, mexp[mhead]);
			end
			mhead = mhead + 1;
		end
	end

	initial begin
		fd = $fopen("sim/vec/rx_fp.hex", "r");
		if (fd == 0) begin
			$display("FAIL atg_rx_fp: no sim/vec/rx_fp.hex");
			$finish;
		end
		for (i = 0; i < N; i = i + 1) begin
			code = $fscanf(fd, "%h %h %h %h\n", op, a, b, r);
			vec[i] = {28'd0, op, a, b, r};
		end
		$fclose(fd);
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		/* Adds and subtracts, then multiplies, one per cycle. */
		nadd = 0;
		for (i = 0; i < N; i = i + 1) begin
			op = vec[i][99:96];
			if (op == 4'd0 || op == 4'd1) begin
				aexp[atail] = vec[i][31:0];
				ain[atail] = vec[i][95:32];
				atail = atail + 1;
				av <= 1'b1;
				aa <= vec[i][95:64];
				ab <= vec[i][63:32];
				asub <= op == 4'd1;
				@(posedge clk);
				nadd = nadd + 1;
			end
		end
		av <= 1'b0;
		nmul = 0;
		for (i = 0; i < N; i = i + 1) begin
			op = vec[i][99:96];
			if (op == 4'd2) begin
				mexp[mtail] = vec[i][31:0];
				min_[mtail] = vec[i][95:32];
				mtail = mtail + 1;
				mv <= 1'b1;
				ma <= vec[i][95:64];
				mb <= vec[i][63:32];
				@(posedge clk);
				nmul = nmul + 1;
			end
		end
		mv <= 1'b0;
		repeat (8) @(posedge clk);
		if (ahead != atail || mhead != mtail) begin
			errors = errors + 1;
			$display("FAIL atg_rx_fp: %0d/%0d adds, %0d/%0d multiplies answered", ahead,
				atail, mhead, mtail);
		end
		if (errors == 0)
			$display("PASS atg_rx_fp.add (%0d)", nadd);
		if (errors == 0)
			$display("PASS atg_rx_fp.mul (%0d)", nmul);
		/* Divides, one at a time. */
		ndiv = 0;
		for (i = 0; i < N; i = i + 1) begin
			op = vec[i][99:96];
			if (op == 4'd3) begin
				ds <= 1'b1;
				da <= vec[i][95:64];
				db <= vec[i][63:32];
				@(posedge clk);
				ds <= 1'b0;
				j = 0;
				#1;
				while (!ddone && j < 40) begin
					@(posedge clk);
					#1;
					j = j + 1;
				end
				if (!ddone || dr !== vec[i][31:0]) begin
					errors = errors + 1;
					if (errors < 20)
						$display("FAIL atg_rx_fp: div %h %h = %h (done %b), expected %h",
							vec[i][95:64], vec[i][63:32], dr, ddone, vec[i][31:0]);
				end
				@(posedge clk);
				ndiv = ndiv + 1;
			end
		end
		if (errors == 0)
			$display("PASS atg_rx_fp.div (%0d)", ndiv);
		if (errors == 0)
			$display("PASS atg_rx_fp");
		$finish;
	end
endmodule

`default_nettype wire
