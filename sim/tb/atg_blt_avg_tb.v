/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_avg_tb: atg_blt_avg against integer rounding written here: every
 * sum 0..1020 of four UNORM8 samples in every byte of the four pixels
 * (each pixel and byte its own sum), every sum 0..124 and 0..252 of the
 * UNORM565 fields, and SAMPLE0, both pixel sizes.  Prints PASS
 * atg_blt_avg.unorm8, .rgb565, .sample0 and PASS atg_blt_avg.
 * MUT_RSV_RNE (ties rounded up) fails .unorm8 and .rgb565.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_avg_tb;
	reg [2:0] fmt = 3'd0;
	reg is16 = 1'b0;
	reg [511:0] in_s = 512'd0;
	wire [127:0] out_p;
	integer e0 = 0, e1 = 0, e2 = 0;
	integer sum, p, k, s, f, v, w, seed;

	atg_blt_avg dut (.fmt(fmt), .psl(is16 ? 3'd1 : 3'd2), .in_s(in_s), .out_p(out_p));

	function integer rne4;
		input integer x;
		integer q;
		begin
			q = x / 4;
			rne4 = q + ((x % 4 == 3 || (x % 4 == 2 && q % 2 == 1)) ? 1 : 0);
		end
	endfunction

	/* Split sum into four samples of at most m each. */
	function integer part;
		input integer x, m, s;
		integer r;
		begin
			r = x - s * m;
			part = r < 0 ? 0 : r > m ? m : r;
		end
	endfunction

	initial begin
		seed = 7;
		/* UNORM8, 32- and 16-bit pixels: pixel p byte k gets the sum
		 * (sum + 37 (4 p + k)) mod 1021, so every sum meets every byte. */
		for (w = 0; w < 2; w = w + 1) begin
			is16 = w;
			fmt = 2'd0;
			for (sum = 0; sum <= 1020; sum = sum + 1) begin
				in_s = 512'd0;
				for (p = 0; p < 4; p = p + 1)
					for (k = 0; k < (w ? 2 : 4); k = k + 1)
						for (s = 0; s < 4; s = s + 1) begin
							v = part((sum + 37 * (4 * p + k)) % 1021, 255, s);
							in_s[8 * ((w ? 2 : 4) * (4 * p + s) + k) +: 8] = v;
						end
				#1;
				for (p = 0; p < 4; p = p + 1)
					for (k = 0; k < (w ? 2 : 4); k = k + 1)
						if (out_p[8 * ((w ? 2 : 4) * p + k) +: 8] !==
						    rne4((sum + 37 * (4 * p + k)) % 1021)) begin
							if (e0 < 5)
								$display("FAIL atg_blt_avg.unorm8: sum %0d px %0d byte %0d: %h",
									(sum + 37 * (4 * p + k)) % 1021, p, k,
									out_p[8 * ((w ? 2 : 4) * p + k) +: 8]);
							e0 = e0 + 1;
						end
			end
		end
		if (e0 == 0)
			$display("PASS atg_blt_avg.unorm8");
		/* UNORM565: the fields' sums. */
		is16 = 1'b1;
		fmt = 2'd1;
		for (sum = 0; sum <= 252; sum = sum + 1) begin
			in_s = 512'd0;
			for (p = 0; p < 4; p = p + 1)
				for (s = 0; s < 4; s = s + 1) begin
					in_s[16 * (4 * p + s) +: 5] = part((sum + 11 * p) % 125, 31, s);
					in_s[16 * (4 * p + s) + 5 +: 6] = part((sum + 29 * p) % 253, 63, s);
					in_s[16 * (4 * p + s) + 11 +: 5] = part((sum + 53 * p) % 125, 31, s);
				end
			#1;
			for (p = 0; p < 4; p = p + 1)
				if (out_p[16 * p +: 5] !== rne4((sum + 11 * p) % 125) ||
				    out_p[16 * p + 5 +: 6] !== rne4((sum + 29 * p) % 253) ||
				    out_p[16 * p + 11 +: 5] !== rne4((sum + 53 * p) % 125)) begin
					if (e1 < 5)
						$display("FAIL atg_blt_avg.rgb565: sum %0d px %0d: %h", sum, p,
							out_p[16 * p +: 16]);
					e1 = e1 + 1;
				end
		end
		if (out_p[127:64] !== 64'd0)
			e1 = e1 + 1;
		if (e1 == 0)
			$display("PASS atg_blt_avg.rgb565");
		/* SAMPLE0. */
		fmt = 2'd2;
		for (k = 0; k < 50; k = k + 1) begin
			for (s = 0; s < 16; s = s + 1)
				in_s[32 * s +: 32] = $random(seed);
			is16 = k % 2;
			#1;
			for (p = 0; p < 4; p = p + 1)
				if (is16 ? out_p[16 * p +: 16] !== in_s[64 * p +: 16] :
				    out_p[32 * p +: 32] !== in_s[128 * p +: 32])
					e2 = e2 + 1;
		end
		if (e2 == 0)
			$display("PASS atg_blt_avg.sample0");
		else
			$display("FAIL atg_blt_avg.sample0: %0d", e2);
		if (e0 + e1 + e2 == 0)
			$display("PASS atg_blt_avg");
		$finish;
	end
endmodule

`default_nettype wire
