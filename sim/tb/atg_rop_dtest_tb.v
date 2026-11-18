/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_dtest_tb: atg_rop_dtest (combinational) against the model of
 * tools/rxmodel.py (dtest; sim/vec/rop_dtest.txt from tools/rop-vectors.py):
 * D24S8 with the stencil test (every op and compare op, both faces, random
 * masks and references, the clamp and wrap edges), D16 (codes next to the
 * new depth's), depth bounds of the three formats (at the bounds, NaN), and
 * the order and the cases without an attachment.  pass, wbe and the
 * enabled bytes of wword are compared.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_dtest_tb;
	reg [9:0] depth = 0;
	reg [26:0] sfront = 0, sback = 0;
	reg [24:0] sops = 0;
	reg [31:0] bmin = 0, bmax = 0, zf = 0, stored = 0;
	reg cov = 0, front = 0;
	wire pass;
	wire [31:0] wword;
	wire [3:0] wbe;

	atg_rop_dtest dut (.depth(depth), .sfront(sfront), .sback(sback), .sops(sops),
		.bmin(bmin), .bmax(bmax), .cov(cov), .front(front), .zf(zf), .stored(stored),
		.pass(pass), .wword(wword), .wbe(wbe));

	integer fd, code, sect, n, i;
	integer e_s [0:3];
	reg [7:0] tag;
	reg [31:0] v_depth, v_sf, v_sb, v_sops, v_cov, v_front, x_pass, x_word, x_be;
	reg [31:0] m;

	initial begin
		for (i = 0; i < 4; i = i + 1)
			e_s[i] = 0;
		n = 0;
		fd = $fopen("sim/vec/rop_dtest.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rop_dtest: no sim/vec/rop_dtest.txt");
			$finish;
		end
		code = 1;
		while (code > 0) begin
			code = $fscanf(fd, "%c", tag);
			if (tag == "D") begin
				code = $fscanf(fd, " %d %h %h %h %h %h %h %d %d %h %h %d %h %h\n", sect, v_depth,
					v_sf, v_sb, v_sops, bmin, bmax, v_cov, v_front, zf, stored, x_pass, x_word,
					x_be);
				depth = v_depth[9:0];
				sfront = v_sf[26:0];
				sback = v_sb[26:0];
				sops = v_sops[24:0];
				cov = v_cov[0];
				front = v_front[0];
				#1;
				m = {{8{x_be[3]}}, {8{x_be[2]}}, {8{x_be[1]}}, {8{x_be[0]}}};
				if (pass !== x_pass[0] || wbe !== x_be[3:0] || (wword & m) !== (x_word & m)) begin
					e_s[sect] = e_s[sect] + 1;
					if (e_s[0] + e_s[1] + e_s[2] + e_s[3] < 8)
						$display("FAIL atg_rop_dtest: case %0d (section %0d depth %h) pass %b wbe %h word %h, want %b %h %h",
							n, sect, depth, pass, wbe, wword, x_pass[0], x_be[3:0], x_word);
				end
				n = n + 1;
			end else
				code = 0;
		end
		$fclose(fd);
		$display("atg_rop_dtest: %0d cases", n);
		if (e_s[0] == 0 && n > 0)
			$display("PASS atg_rop_dtest.stencil");
		if (e_s[1] == 0 && n > 0)
			$display("PASS atg_rop_dtest.d16");
		if (e_s[2] == 0 && n > 0)
			$display("PASS atg_rop_dtest.bounds");
		if (e_s[3] == 0 && n > 0)
			$display("PASS atg_rop_dtest.order");
		if (e_s[0] + e_s[1] + e_s[2] + e_s[3] == 0 && n > 0)
			$display("PASS atg_rop_dtest");
		$finish;
	end
endmodule

`default_nettype wire
