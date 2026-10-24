/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_tb: the format functions of include/atg_fmt_info.vh,
 * atg_fmt_unpack.vh and atg_fmt_pack.vh against tools/fmtmodel.py
 * (python3 -I tools/fmtmodel.py --vectors):
 *   info      sim/vec/fmt_info.txt: atg_fmt_info and atg_fmt_feat (with and
 *             without the ETC2 decoder) for every 8-bit format value;
 *   unpack    sim/vec/fmt_unpack.txt: every format (and three without an
 *             entry), the stencil aspect, all codes of the single 1- to
 *             11-bit components, random texels and the float specials;
 *   pack      sim/vec/fmt_pack.txt: every format with random components
 *             and write masks, and every UNORM code of 5, 6, 8 and 10 bits
 *             from its fp32 and the fp32 next to it;
 *   required  sim/vec/fmt_required.txt (from tools/vk-required-formats.txt,
 *             Vulkan 1.0's required features, not from the model):
 *             atg_fmt_feat with the decoder has every required
 *             fixed-function bit, and one format or family of each "one
 *             of" group has its bits.
 * No clock: the functions are combinational (all of it runs at time 0).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_tb;
	`include "atg_srgb.vh"
	`include "atg_fmt_info.vh"
	`include "atg_fmt_unpack.vh"
	`include "atg_fmt_pack.vh"

	integer fd, code, n, errors, total;
	reg [7:0] fmt;
	reg [67:0] x_info;
	reg [15:0] x_o, x_b, x_o0, x_b0, bits;
	reg [25:0] ft;
	reg st, x_int;
	reg [3:0] wm;
	reg [127:0] raw, keep;
	reg [31:0] c0, c1, c2, c3;
	reg [128:0] got;
	reg [255:0] pk;
	reg [31:0] word;
	integer ng, g, cnt, k, ok_group, any;

	task open;
		input [8*32-1:0] name;
		begin
			fd = $fopen(name, "r");
			if (fd == 0) begin
				$display("FAIL atg_fmt: no %0s", name);
				$finish;
			end
		end
	endtask

	initial begin
		total = 0;
		/* info and features */
		errors = 0;
		n = 0;
		open("sim/vec/fmt_info.txt");
		while (!$feof(fd)) begin
			code = $fscanf(fd, "%h %h %h %h %h %h\n", fmt, x_info, x_o, x_b, x_o0, x_b0);
			if (code == 6) begin
				n = n + 1;
				ft = atg_fmt_feat(fmt, 1'b1);
				if (atg_fmt_info(fmt) !== x_info || ft !== {x_b[12:0], x_o[12:0]} ||
				    atg_fmt_feat(fmt, 1'b0) !== {x_b0[12:0], x_o0[12:0]}) begin
					errors = errors + 1;
					if (errors < 10)
						$display("FAIL atg_fmt.info: fmt %0d info %h feat %h, want %h %h %h",
							fmt, atg_fmt_info(fmt), ft, x_info, x_b, x_o);
				end
			end
		end
		$fclose(fd);
		if (errors == 0 && n == 256)
			$display("PASS atg_fmt.info (%0d formats)", n);
		else
			$display("FAIL atg_fmt.info: %0d errors in %0d", errors, n);
		total = total + errors + (n == 256 ? 0 : 1);

		/* unpack */
		errors = 0;
		n = 0;
		open("sim/vec/fmt_unpack.txt");
		while (!$feof(fd)) begin
			code = $fscanf(fd, "%h %h %h %h %h %h %h %h\n", fmt, st, raw, c0, c1, c2, c3, x_int);
			if (code == 8) begin
				n = n + 1;
				got = atg_fmt_unpack(raw, fmt, st);
				if (got !== {x_int, c3, c2, c1, c0}) begin
					errors = errors + 1;
					if (errors < 10)
						$display("FAIL atg_fmt.unpack: fmt %0d st %0d raw %h: %h, want %h",
							fmt, st, raw, got, {x_int, c3, c2, c1, c0});
				end
			end
		end
		$fclose(fd);
		if (errors == 0 && n > 4000)
			$display("PASS atg_fmt.unpack (%0d texels)", n);
		else
			$display("FAIL atg_fmt.unpack: %0d errors in %0d", errors, n);
		total = total + errors + (n > 4000 ? 0 : 1);

		/* pack */
		errors = 0;
		n = 0;
		open("sim/vec/fmt_pack.txt");
		while (!$feof(fd)) begin
			code = $fscanf(fd, "%h %h %h %h %h %h %h %h\n", fmt, wm, c0, c1, c2, c3, raw, keep);
			if (code == 8) begin
				n = n + 1;
				pk = atg_fmt_pack({c3, c2, c1, c0}, fmt, wm);
				if (pk !== {keep, raw}) begin
					errors = errors + 1;
					if (errors < 10)
						$display("FAIL atg_fmt.pack: fmt %0d wm %h %h %h %h %h: %h %h, want %h %h",
							fmt, wm, c0, c1, c2, c3, pk[255:128], pk[127:0], keep, raw);
				end
			end
		end
		$fclose(fd);
		if (errors == 0 && n > 6000)
			$display("PASS atg_fmt.pack (%0d pixels)", n);
		else
			$display("FAIL atg_fmt.pack: %0d errors in %0d", errors, n);
		total = total + errors + (n > 6000 ? 0 : 1);

		/* required */
		errors = 0;
		n = 0;
		open("sim/vec/fmt_required.txt");
		while (!$feof(fd)) begin
			code = $fscanf(fd, "%h", fmt);
			if (code == 1 && fmt != 8'hFF) begin
				code = $fscanf(fd, "%h %h\n", x_o, x_b);
				n = n + 1;
				ft = atg_fmt_feat(fmt, 1'b1);
				if ((ft[12:0] & x_o[12:0]) !== x_o[12:0] ||
				    (ft[25:13] & x_b[12:0]) !== x_b[12:0]) begin
					errors = errors + 1;
					$display("FAIL atg_fmt.required: fmt %0d has %h %h, Vulkan needs %h %h",
						fmt, ft[12:0], ft[25:13], x_o, x_b);
				end
			end else if (code == 1) begin
				code = $fscanf(fd, "%h %h\n", bits, ng);
				any = 0;
				for (g = 0; g < ng; g = g + 1) begin
					code = $fscanf(fd, "%h", cnt);
					ok_group = 1;
					for (k = 0; k < cnt; k = k + 1) begin
						code = $fscanf(fd, "%h", word);
						ft = atg_fmt_feat(word[7:0], 1'b1);
						if ((ft[12:0] & bits[12:0]) !== bits[12:0])
							ok_group = 0;
					end
					if (ok_group)
						any = 1;
				end
				n = n + 1;
				if (!any) begin
					errors = errors + 1;
					$display("FAIL atg_fmt.required: no format of a one-of group has %h", bits);
				end
			end
		end
		$fclose(fd);
		if (errors == 0 && n > 50)
			$display("PASS atg_fmt.required (%0d rows)", n);
		else
			$display("FAIL atg_fmt.required: %0d errors in %0d", errors, n);
		total = total + errors + (n > 50 ? 0 : 1);

		if (total == 0)
			$display("PASS atg_fmt");
		else
			$display("FAIL atg_fmt: %0d errors", total);
		$finish;
	end

	initial begin
		#1000000;
		$display("FAIL atg_fmt: timeout");
		$finish;
	end
endmodule

`default_nettype wire
