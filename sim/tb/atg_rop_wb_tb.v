/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_wb_tb: atg_rop_wb with atg_rop_blend against amb_mem and the
 * reference model (sim/vec/rop_wb.txt from tools/rx-vectors.py): for each
 * of BGRA8, RGBA8 and RGB565 a run of plain writes, source-over, a random
 * blend and a partial WRITE_MASK, 80 quads each (mostly walking a row,
 * sometimes jumping, so lines hit, miss and are written back), on a 32x16
 * target of random pixels.  Checks that busy falls only when the target
 * in memory equals the model's (the writes answered), and the target then.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_wb_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg d_valid = 1'b0;
	reg [31:0] d_xy = 0;
	reg [3:0] d_mask = 0;
	reg [511:0] d_color = 0;
	wire d_ready, b_valid, b_rvalid, busy;
	wire [511:0] b_src;
	wire [127:0] b_dst, b_pix;
	wire [3:0] b_mask;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;

	atg_rop_wb dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .d_valid(d_valid), .d_ready(d_ready), .d_xy(d_xy),
		.d_mask(d_mask), .d_color(d_color), .b_valid(b_valid), .b_src(b_src), .b_dst(b_dst),
		.b_mask(b_mask), .b_rvalid(b_rvalid), .b_pix(b_pix), .busy(busy),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));
	atg_rop_blend blend (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .b_valid(b_valid), .b_src(b_src), .b_dst(b_dst), .b_mask(b_mask),
		.b_rvalid(b_rvalid), .b_pix(b_pix));
	amb_mem #(.MEM_WORDS(8192), .SEED(9)) mem (.clk(clk), .rst_n(rst_n),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));

	localparam [31:0] RT_BASE = 32'h2000;
	integer fd, code, i, j, nrun, seed, e_write = 0, e_blend = 0, e_drain = 0;
	reg [7:0] tag;
	reg [3:0] fmt, wm, m;
	reg [23:0] bl;
	reg [31:0] kc, stride, wt, x, y, v, want;
	reg [31:0] fin [0:511];
	reg [31:0] lo;
	reg [511:0] col;

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

	/* the target's pixel i from memory */
	function [31:0] pix;
		input integer i_;
		reg [31:0] w;
		begin
			if (fmt == 4'd2) begin
				w = mem.peek(RT_BASE + 2 * i_ - (i_ & 1) * 2);
				pix = i_ & 1 ? {16'd0, w[31:16]} : {16'd0, w[15:0]};
			end else
				pix = mem.peek(RT_BASE + 4 * i_);
		end
	endfunction

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		fd = $fopen("sim/vec/rop_wb.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rop_wb: no sim/vec/rop_wb.txt");
			$finish;
		end
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		st_put(9'h070, RT_BASE);
		nrun = 0;
		code = 1;
		while (code > 0) begin
			code = $fscanf(fd, "%c", tag);
			if (tag == "R") begin
				code = $fscanf(fd, " %h %h %h %h %h", fmt, bl, kc, wm, stride);
				for (i = 0; i < 512; i = i + 1) begin
					code = $fscanf(fd, " %h", wt);
					if (fmt == 4'd2) begin
						if (i & 1)
							mem.poke(RT_BASE + 2 * i - 2, {wt[15:0], lo[15:0]});
						else
							lo = wt;
					end else
						mem.poke(RT_BASE + 4 * i, wt);
				end
				code = $fscanf(fd, "%c", tag);
				st_put(9'h071, stride);
				st_put(9'h072, {28'd0, fmt});
				st_put(9'h07A, {8'd0, bl});
				st_put(9'h07B, kc);
				st_put(9'h07C, {28'd0, wm});
			end else if (tag == "Q") begin
				code = $fscanf(fd, " %h %h %h", x, y, m);
				for (j = 0; j < 16; j = j + 1) begin
					code = $fscanf(fd, " %h", wt);
					col[32 * j +: 32] = wt;
				end
				code = $fscanf(fd, "%c", tag);
				d_valid <= 1'b1;
				d_xy <= {y[15:0], x[15:0]};
				d_mask <= m;
				d_color <= col;
				@(posedge clk);
				while (!d_ready)
					@(posedge clk);
				d_valid <= 1'b0;
				repeat ($random(seed) & 3) @(posedge clk);
			end else if (tag == "F") begin
				for (i = 0; i < 512; i = i + 1) begin
					code = $fscanf(fd, " %h", wt);
					fin[i] = wt;
				end
				code = $fscanf(fd, "%c", tag);
				/* busy falls only once every pixel is in memory */
				j = 0;
				@(posedge clk);
				while (busy && j < 5000) begin
					@(posedge clk);
					j = j + 1;
				end
				for (i = 0; i < 512; i = i + 1) begin
					v = pix(i);
					if (v !== fin[i]) begin
						if (bl[0])
							e_blend = e_blend + 1;
						else
							e_write = e_write + 1;
						if (e_blend + e_write < 8)
							$display("FAIL atg_rop_wb: run %0d (fmt %0d blend %h wm %h) pixel %0d = %h, expected %h",
								nrun, fmt, bl, wm, i, v, fin[i]);
					end
				end
				if (busy || req_valid) begin
					e_drain = e_drain + 1;
					$display("FAIL atg_rop_wb: run %0d still busy", nrun);
				end
				nrun = nrun + 1;
			end else
				code = 0;
		end
		$fclose(fd);
		$display("atg_rop_wb: %0d runs", nrun);
		if (e_write == 0)
			$display("PASS atg_rop_wb.write");
		if (e_blend == 0)
			$display("PASS atg_rop_wb.blend");
		if (e_drain == 0 && e_write + e_blend == 0)
			$display("PASS atg_rop_wb.drain");
		if (e_write + e_blend + e_drain == 0)
			$display("PASS atg_rop_wb");
		$finish;
	end
endmodule

`default_nettype wire
