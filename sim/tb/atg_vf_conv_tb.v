/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_conv_tb: atg_vf_conv against the reference conversion of
 * tools/vf-vectors.py (sim/vec/vf_conv.txt).  Each batch sets ATTR_DESC
 * (format) and ATTR_DST of up to 16 attributes and sends their af back to
 * back (random gaps, seeded), the last with af_last; every vl_* word is
 * checked in order (register, lane, data), and conv_done must pulse once,
 * after the batch's last word.  "formats": every format with ATTR_DST's
 * count equal to the format's components (all 256 UNORM8 values, fp16
 * zeros, denormals, infinities and NaNs), fewer words, disabled attributes;
 * "fill": more components than the format has, reserved formats.  Then
 * sim/vec/vf_conv_vk.txt (CAPS[30]): ATTR_DST[31:24] a VkFormat, every
 * value 0-255 against tools/fmtmodel.py ("vkformats"), and af_oob with any
 * format ("oob").
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_conv_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg af_valid = 1'b0;
	reg [3:0] af_attr = 0;
	reg [4:0] af_lane = 0;
	reg [127:0] af_raw = 0;
	reg af_last = 1'b0;
	reg af_oob = 1'b0;
	wire af_ready, vl_we, conv_done;
	wire [5:0] vl_reg;
	wire [4:0] vl_lane;
	wire [31:0] vl_data;

	atg_vf_conv dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .af_valid(af_valid), .af_ready(af_ready), .af_attr(af_attr),
		.af_lane(af_lane), .af_raw(af_raw), .af_oob(af_oob), .af_last(af_last), .vl_we(vl_we),
		.vl_reg(vl_reg), .vl_lane(vl_lane), .vl_data(vl_data), .conv_done(conv_done));

	integer fd, code, seed, n, j, c, nw, xn, xg, ndone, tmo, oob;
	integer e_k [0:3];	/* errors of formats, fill, vkformats, oob */
	reg [7:0] tag;
	reg [3:0] k, fmt;
	reg [7:0] dst, vk;
	reg [4:0] lane;
	reg [127:0] raw;
	reg [31:0] wd;
	reg [1:0] kind;	/* 0 formats, 1 fill, 2 vkformats, 3 oob */
	reg [1:0] bkind;
	reg [3:0] b_k [0:15];
	reg b_oob [0:15];
	reg [4:0] b_lane [0:15];
	reg [127:0] b_raw [0:15];
	reg [5:0] x_reg [0:63];
	reg [4:0] x_lane [0:63];
	reg [31:0] x_data [0:63];
	reg [1:0] x_kind [0:63];

	task st_put;
		input [8:0] i_;
		input [31:0] val;
		begin
			st_we <= 1'b1;
			st_idx <= i_;
			st_wdata <= val;
			@(posedge clk);
			st_we <= 1'b0;
		end
	endtask

	task fail;
		input [1:0] kd;
		e_k[kd] = e_k[kd] + 1;
	endtask

	always @(posedge clk) begin
		if (vl_we) begin
			if (xg >= xn) begin
				$display("FAIL atg_vf_conv: word %0d beyond %0d", xg, xn);
				fail(bkind);
			end else if (vl_reg !== x_reg[xg] || vl_lane !== x_lane[xg] ||
				vl_data !== x_data[xg]) begin
				$display("FAIL atg_vf_conv: word %0d r%0d lane %0d %h, want r%0d %0d %h",
					xg, vl_reg, vl_lane, vl_data, x_reg[xg], x_lane[xg], x_data[xg]);
				fail(x_kind[xg]);
			end
			xg = xg + 1;
		end
		if (conv_done) begin
			if (xg != xn || ndone != 0) begin
				$display("FAIL atg_vf_conv: conv_done at word %0d of %0d (pulse %0d)",
					xg, xn, ndone + 1);
				fail(bkind);
			end
			ndone = ndone + 1;
		end
	end

	/* The batches of one vector file; vkf: its lines have vk and oob. */
	task run_file;
		input vkf;
		begin
			code = $fscanf(fd, "%c %d\n", tag, n);
			while (code == 2 && tag == "B") begin
				xn = 0;
				xg = 0;
				ndone = 0;
				for (j = 0; j < n; j = j + 1) begin
					vk = 8'd0;
					oob = 0;
					if (vkf)
						code = $fscanf(fd, "%c %h %h %h %h %h %h %d %d", tag, k, fmt, vk,
							dst, lane, raw, oob, nw);
					else
						code = $fscanf(fd, "%c %h %h %h %h %h %d", tag, k, fmt, dst,
							lane, raw, nw);
					kind = tag == "L" ? 2'd1 : tag == "V" ? 2'd2 : tag == "O" ? 2'd3 : 2'd0;
					bkind = kind;
					for (c = 0; c < nw; c = c + 1) begin
						code = $fscanf(fd, " %h", wd);
						x_reg[xn] = dst[5:0] + c;
						x_lane[xn] = lane;
						x_data[xn] = wd;
						x_kind[xn] = kind;
						xn = xn + 1;
					end
					code = $fscanf(fd, "%c", tag);
					b_k[j] = k;
					b_lane[j] = lane;
					b_raw[j] = raw;
					b_oob[j] = oob != 0;
					st_put(9'h031 + 2 * k, {12'd0, fmt, 16'd4});
					st_put(9'h1C0 + k, {vk, 16'd0, dst});
				end
				for (j = 0; j < n; j = j + 1) begin
					af_valid <= 1'b1;
					af_attr <= b_k[j];
					af_lane <= b_lane[j];
					af_raw <= b_raw[j];
					af_oob <= b_oob[j];
					af_last <= j == n - 1;
					@(negedge clk);
					while (!af_ready)
						@(negedge clk);
					@(posedge clk);
					af_valid <= 1'b0;
					if (($random(seed) & 3) == 0)
						@(posedge clk);
				end
				tmo = 0;
				while ((xg < xn || ndone == 0) && tmo < 1000) begin
					@(negedge clk);
					tmo = tmo + 1;
				end
				repeat (4) @(negedge clk);
				if (xg != xn || ndone != 1) begin
					$display("FAIL atg_vf_conv: batch of %0d: %0d of %0d words, %0d conv_done",
						n, xg, xn, ndone);
					fail(bkind);
				end
				code = $fscanf(fd, "%c %d\n", tag, n);
			end
		end
	endtask

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		for (j = 0; j < 4; j = j + 1)
			e_k[j] = 0;
		xn = 0;
		xg = 0;
		ndone = 0;
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		fd = $fopen("sim/vec/vf_conv.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_vf_conv: no sim/vec/vf_conv.txt");
			$finish;
		end
		run_file(1'b0);
		$fclose(fd);
		if (e_k[0] == 0)
			$display("PASS atg_vf_conv.formats");
		if (e_k[1] == 0)
			$display("PASS atg_vf_conv.fill");
		fd = $fopen("sim/vec/vf_conv_vk.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_vf_conv: no sim/vec/vf_conv_vk.txt");
			$finish;
		end
		run_file(1'b1);
		$fclose(fd);
		if (e_k[2] == 0)
			$display("PASS atg_vf_conv.vkformats");
		if (e_k[3] == 0)
			$display("PASS atg_vf_conv.oob");
		if (e_k[0] + e_k[1] + e_k[2] + e_k[3] == 0)
			$display("PASS atg_vf_conv");
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL atg_vf_conv: timeout");
		$finish;
	end
endmodule

`default_nettype wire
