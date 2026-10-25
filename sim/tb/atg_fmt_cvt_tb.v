/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_cvt_tb: atg_fmt_cvt against atg_fmt_comp (its combinational
 * form, checked against tools/fmtmodel.py by atg_fmt_tb), one conversion a cycle (seeded): every
 * VkFormat code 0-255 (atg_fmt_info, entries or not), the block kinds of
 * atg_tu_ffilt (atg_fmt_i of RGBA8 and the 11- and 10-bit EAC words),
 * each component, the stencil aspect, and texels of random bits, small
 * and large values, zeros, ones and the floats' specials.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_cvt_tb;
	`include "atg_fmt_info.vh"
	reg clk = 1'b0;
	always #5 clk = !clk;

	reg [127:0] raw = 128'd0;
	reg [67:0] inf = 68'd0;
	reg [1:0] k = 2'd0;
	reg sten = 1'b0;
	wire [31:0] val;

	atg_fmt_cvt dut (.clk(clk), .i_raw(raw), .i_inf(inf), .i_k(k), .i_sten(sten), .o_val(val));
	wire [31:0] ref_v;
	atg_fmt_comp u_ref (.raw(raw), .inf(inf), .k(k), .sten(sten), .v(ref_v));

	localparam LAT = 7;
	integer seed, errs, j, n;
	reg [31:0] xq [0:LAT];
	reg vq [0:LAT];
	reg [31:0] r0;
	reg [127:0] rr;
	reg [7:0] f;

	initial begin
		seed = 1;
		if ($value$plusargs("seed=%d", seed))
			seed = seed + 0;
		errs = 0;
		n = 0;
		for (j = 0; j <= LAT; j = j + 1)
			vq[j] = 1'b0;
		for (j = 0; j < 400000; j = j + 1) begin
			r0 = $random(seed);
			rr = {$random(seed), $random(seed), $random(seed), $random(seed)};
			case (r0[3:0])
			4'd0: rr = 128'd0;
			4'd1: rr = ~128'd0;
			4'd2: rr = rr & {4{32'h000000FF}};
			4'd3: rr = rr | {4{32'h7C007C00}};	/* fp16 infinities and NaNs */
			4'd4: rr = rr & {4{32'h83FF83FF}};	/* fp16 denormals */
			4'd5: rr = rr & {4{32'h0000001F}};
			4'd6: rr = rr | {4{32'h80008000}};
			default: ;
			endcase
			f = $random(seed);
			case (r0[6:4])
			3'd0: inf = atg_fmt_i(5'd4, 3'd2, ATG_FMT_UNORM, 3'b000, atg_fmt_c(7'd0, 6'd11),
				atg_fmt_c(7'd16, 6'd11), atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
			3'd1: inf = atg_fmt_i(5'd4, 3'd2, ATG_FMT_UNORM, 3'b000, atg_fmt_c(7'd0, 6'd10),
				atg_fmt_c(7'd16, 6'd10), atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
			default: inf = atg_fmt_info(f);
			endcase
			raw <= rr;
			k <= r0[9:8];
			sten <= r0[12:10] == 3'd0;
			@(posedge clk);
			/* the expected value of the inputs just taken (o_val 6 edges later) */
			for (n = LAT; n > 0; n = n - 1) begin
				xq[n] = xq[n - 1];
				vq[n] = vq[n - 1];
			end
			xq[0] = ref_v;
			vq[0] = 1'b1;
			#1;
			if (vq[LAT - 1] && val !== xq[LAT - 1]) begin
				if (errs < 10)
					$display("FAIL atg_fmt_cvt: %h, model %h", val, xq[LAT - 1]);
				errs = errs + 1;
			end
		end
		if (errs == 0)
			$display("PASS atg_fmt_cvt");
		else
			$display("FAIL atg_fmt_cvt: %0d errors", errs);
		$finish;
	end
endmodule

`default_nettype wire
