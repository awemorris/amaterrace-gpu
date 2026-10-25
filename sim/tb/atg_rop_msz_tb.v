/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_msz_tb: the depths of atg_rop_ms (CAPS[30]) against the model of
 * tools/rop-vectors.py (ms_depth; sim/vec/rop_msz.txt): one and four
 * samples, exported depths, DEPTH_CLAMP 0-3 with random viewport depth
 * ranges (also reversed, n > f) and depths outside them, NaN and -0
 * ("clamp"), and DEPTH_CLAMP 0, the earlier behaviour ("legacy").  Every
 * sample's o_sdepth is compared; o_front follows i_aux[148].
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_msz_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0, i_valid = 1'b0, o_ready = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg [3:0] i_mask = 0;
	reg [127:0] i_depth = 0;
	reg [153:0] i_aux = 0;
	wire i_ready, o_valid, o_dbg, o_front, busy;
	wire [31:0] o_xy;
	wire [15:0] o_smask;
	wire [511:0] o_color, o_sdepth;

	atg_rop_ms dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .i_valid(i_valid), .i_ready(i_ready), .i_xy(32'h00020004),
		.i_mask(i_mask), .i_color(512'd0), .i_depth(i_depth), .i_dbg(1'b0), .i_aux(i_aux),
		.o_valid(o_valid), .o_ready(o_ready), .o_xy(o_xy), .o_smask(o_smask),
		.o_color(o_color), .o_sdepth(o_sdepth), .o_dbg(o_dbg), .o_front(o_front), .o_beat(),
		.busy(busy));

	task st_put;
		input [8:0] i_;
		input [31:0] v;
		begin
			st_we <= 1'b1;
			st_idx <= i_;
			st_wdata <= v;
			@(posedge clk);
			st_we <= 1'b0;
		end
	endtask

	integer fd, code, j, sect, dc, ms4, n, tmo;
	integer e_s [0:1];
	reg [7:0] tag;
	reg [31:0] zs, zo, mk, ze, w;
	reg [511:0] xs;
	reg [127:0] dsv;

	initial begin
		e_s[0] = 0;
		e_s[1] = 0;
		n = 0;
		fd = $fopen("sim/vec/rop_msz.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rop_msz: no sim/vec/rop_msz.txt");
			$finish;
		end
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		code = 1;
		while (code > 0) begin
			code = $fscanf(fd, "%c", tag);
			if (tag == "Z") begin
				code = $fscanf(fd, " %d %d %h %h %d %h %h", sect, dc, zs, zo, ms4, mk, ze);
				for (j = 0; j < 4; j = j + 1) begin
					code = $fscanf(fd, " %h", w);
					i_depth[32 * j +: 32] = w;
				end
				for (j = 0; j < 4; j = j + 1) begin
					code = $fscanf(fd, " %h", w);
					dsv[32 * j +: 32] = w;
				end
				for (j = 0; j < 16; j = j + 1) begin
					code = $fscanf(fd, " %h", w);
					xs[32 * j +: 32] = w;
				end
				code = $fscanf(fd, "%c", tag);
				st_put(9'h059, dc);
				st_put(9'h054, zs);
				st_put(9'h055, zo);
				st_put(9'h05E, ms4 ? 32'd2 : 32'd0);
				repeat (6) @(posedge clk);
				i_mask <= mk[3:0];
				i_aux <= {2'd0, 3'b110, n[0], dsv, ze[3:0], 16'hFFFF};
				i_valid <= 1'b1;
				@(posedge clk);
				while (!i_ready)
					@(posedge clk);
				i_valid <= 1'b0;
				tmo = 0;
				while (!o_valid && tmo < 100) begin
					@(posedge clk);
					tmo = tmo + 1;
				end
				if (!o_valid || o_sdepth !== xs || o_front !== n[0]) begin
					e_s[sect] = e_s[sect] + 1;
					if (e_s[0] + e_s[1] < 8)
						$display("FAIL atg_rop_msz: case %0d (dc %0d ms4 %0d)\n got %h\n exp %h", n,
							dc, ms4, o_sdepth, xs);
				end
				o_ready <= 1'b1;
				@(posedge clk);
				o_ready <= 1'b0;
				@(posedge clk);
				n = n + 1;
			end else
				code = 0;
		end
		$fclose(fd);
		$display("atg_rop_msz: %0d quads", n);
		if (e_s[0] == 0 && n > 0)
			$display("PASS atg_rop_msz.clamp");
		if (e_s[1] == 0 && n > 0)
			$display("PASS atg_rop_msz.legacy");
		if (e_s[0] + e_s[1] == 0 && n > 0)
			$display("PASS atg_rop_msz");
		$finish;
	end
endmodule

`default_nettype wire
