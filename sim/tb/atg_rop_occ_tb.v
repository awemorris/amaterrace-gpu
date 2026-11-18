/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_occ_tb: atg_rop_occ against a model: random increments (0-16
 * samples, as 1x and 4x quads give), ROP_CTRL[0] switched on and off by
 * STATE writes (other STATE words written too), clears alone and in the
 * same cycle as an increment; count compared every cycle.  Seeded.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_occ_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0, inc_valid = 1'b0, clear = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg [4:0] inc_n = 0;
	wire [39:0] count;

	atg_rop_occ dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .inc_valid(inc_valid), .inc_n(inc_n), .clear(clear),
		.count(count));

	integer seed, i, errs, nclr, ninc;
	reg on;
	reg [39:0] m;
	reg [31:0] r;

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		errs = 0;
		nclr = 0;
		ninc = 0;
		on = 1'b0;
		m = 40'd0;
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		for (i = 0; i < 20000; i = i + 1) begin
			@(negedge clk);
			if (count !== m) begin
				errs = errs + 1;
				if (errs < 6)
					$display("FAIL atg_rop_occ: cycle %0d count %0d, want %0d", i, count, m);
			end
			r = $random(seed);
			st_we = r[3:0] == 4'd0;
			st_idx = r[4] ? 9'h08D : 9'h07A + {7'd0, r[6:5]};
			st_wdata = $random(seed);
			inc_valid = r[8:7] != 2'd0;
			inc_n = r[9] ? {1'b0, r[13:10]} : (r[13:10] == 4'd0 ? 5'd16 : {3'd0, r[11:10]});
			clear = r[19:14] == 6'd0;
			/* the model, for the edge that follows */
			m = (clear ? 40'd0 : m) + (inc_valid && on ? {35'd0, inc_n} : 40'd0);
			if (clear)
				nclr = nclr + 1;
			if (inc_valid && on)
				ninc = ninc + 1;
			if (st_we && st_idx == 9'h08D)
				on = st_wdata[0];
		end
		@(negedge clk);
		st_we = 1'b0;
		inc_valid = 1'b0;
		clear = 1'b0;
		if (count !== m)
			errs = errs + 1;
		$display("atg_rop_occ: %0d counted increments, %0d clears", ninc, nclr);
		if (errs == 0 && ninc > 1000 && nclr > 100)
			$display("PASS atg_rop_occ.count");
		if (errs == 0 && ninc > 1000 && nclr > 100)
			$display("PASS atg_rop_occ");
		$finish;
	end
endmodule

`default_nettype wire
