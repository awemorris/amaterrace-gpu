/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_mrt_tb: four colour attachments (CAPS[30]) through atg_rop_wb,
 * atg_rop_wpix (with atg_rop_fblend) and atg_rop_blend against amb_mem and
 * the reference model (sim/vec/rop_mrt.txt from tools/rop-vectors.py):
 * 72 runs, one and four samples in turn, of attachments of every format
 * with the colour-attachment feature (pixels of 1 to 16 bytes, rows of one
 * line or several), absent attachments (RT_FORMATS byte 0) and attachment
 * 0 by RT_FORMAT's code, random blends, write masks and constants (8-bit
 * and fp32), 24 quads each as one beat per attachment written (some beats
 * without colour), at 32- and 64-byte lines.  Checks the region of the
 * four targets in memory once busy has fallen.
 *   PASS atg_rop_mrt.one     the runs with one sample
 *   PASS atg_rop_mrt.four    the runs with four samples
 *   PASS atg_rop_mrt
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_mrt_tbc #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter SEED = 1
) (
	input wire clk,
	input wire go,
	output reg fin
);
	`include "ghci_regs.vh"
	localparam LA_W = 32 - LINE_SHIFT;
	localparam [31:0] RT_REG = 32'h2000;

	reg rst_n = 1'b0;
	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg d_valid = 1'b0, d_nocol = 1'b0;
	reg [31:0] d_xy = 0;
	reg [15:0] d_smask = 0;
	reg [511:0] d_color = 0;
	reg [1:0] d_rt = 0;
	wire d_ready, b_valid, b_rvalid, busy;
	wire [511:0] b_src;
	wire [127:0] b_dst, b_pix;
	wire [3:0] b_mask;
	wire [1:0] b_rt;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [LA_W-1:0] req_line;
	wire [LINE_BYTES-1:0] req_be;
	wire [LINE_BYTES*8-1:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;

	atg_rop_wb #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) dut (.clk(clk),
		.rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.d_valid(d_valid), .d_ready(d_ready), .d_xy(d_xy), .d_smask(d_smask),
		.d_color(d_color), .d_rt(d_rt), .d_nocol(d_nocol), .b_valid(b_valid), .b_src(b_src),
		.b_dst(b_dst), .b_mask(b_mask), .b_rt(b_rt), .b_rvalid(b_rvalid), .b_pix(b_pix),
		.busy(busy), .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));
	atg_rop_blend blend (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .b_valid(b_valid), .b_src(b_src), .b_dst(b_dst), .b_mask(b_mask),
		.b_rt(b_rt), .b_rvalid(b_rvalid), .b_pix(b_pix));
	amb_mem #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .MEM_WORDS(8192), .SEED(SEED)) mem (
		.clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready),
		.req_write(req_write), .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata),
		.req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));

	integer fd, code, i, j, k, nrun, nw, seed;
	integer errs [0:1];	/* one sample, four samples */
	reg [7:0] tag;
	reg [31:0] ms4, ctrl, fmts, kc8, fmt0, wms, x, y, rt, nocol, sm, wt;
	reg [31:0] bl [0:3];
	reg [31:0] kcf [0:3];
	reg [31:0] base [0:3];
	reg [31:0] stride [0:3];
	reg [31:0] want [0:4095];
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

	initial begin
		fin = 1'b0;
		errs[0] = 0;
		errs[1] = 0;
		seed = SEED;
		wait (go);
		fd = $fopen("sim/vec/rop_mrt.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rop_mrt: no sim/vec/rop_mrt.txt");
			errs[0] = 1;
			fin = 1'b1;
		end else begin
			repeat (3) @(posedge clk);
			rst_n <= 1'b1;
			@(posedge clk);
			nrun = 0;
			code = 1;
			while (code > 0) begin
				code = $fscanf(fd, " %c", tag);
				if (code <= 0 || tag == "E")
					code = 0;
				else if (tag == "R") begin
					code = $fscanf(fd, " %h %h %h %h %h %h %h %h %h %h %h %h %h %h", ms4, ctrl,
						fmts, bl[0], bl[1], bl[2], bl[3], kc8, kcf[0], kcf[1], kcf[2], kcf[3],
						fmt0, wms);
					for (k = 0; k < 4; k = k + 1)
						code = $fscanf(fd, " %h", base[k]);
					for (k = 0; k < 4; k = k + 1)
						code = $fscanf(fd, " %h", stride[k]);
					code = $fscanf(fd, " %h", nw);
					st_put(GHCI_S_MS_CTRL, ms4[0] ? 32'd2 : 32'd0);
					st_put(GHCI_S_ROP_CTRL, ctrl);
					st_put(GHCI_S_RT_FORMATS, fmts);
					st_put(GHCI_S_RT_FORMAT, fmt0);
					st_put(GHCI_S_BLEND, bl[0]);
					for (k = 1; k < 4; k = k + 1)
						st_put(GHCI_S_BLEND1 + k - 1, bl[k]);
					st_put(GHCI_S_BLEND_CONST, kc8);
					for (k = 0; k < 4; k = k + 1)
						st_put(GHCI_S_BLEND_CONST_R + k, kcf[k]);
					st_put(GHCI_S_WRITE_MASK, wms);
					st_put(GHCI_S_RT_BASE, base[0]);
					st_put(GHCI_S_RT_STRIDE, stride[0]);
					for (k = 1; k < 4; k = k + 1) begin
						st_put(GHCI_S_RT1_BASE + 2 * (k - 1), base[k]);
						st_put(GHCI_S_RT1_BASE + 2 * (k - 1) + 1, stride[k]);
					end
				end else if (tag == "M") begin
					for (i = 0; i < nw; i = i + 1) begin
						code = $fscanf(fd, " %h", wt);
						mem.poke(RT_REG + 4 * i, wt);
					end
				end else if (tag == "B") begin
					code = $fscanf(fd, " %h %h %h %h %h", x, y, rt, nocol, sm);
					for (j = 0; j < 16; j = j + 1) begin
						code = $fscanf(fd, " %h", wt);
						col[32 * j +: 32] = wt;
					end
					d_valid <= 1'b1;
					d_xy <= {y[15:0], x[15:0]};
					d_rt <= rt[1:0];
					d_nocol <= nocol[0];
					d_smask <= sm[15:0];
					d_color <= col;
					@(posedge clk);
					while (!d_ready)
						@(posedge clk);
					d_valid <= 1'b0;
					repeat ($unsigned($random(seed)) % 3) @(posedge clk);
				end else if (tag == "F") begin
					for (i = 0; i < nw; i = i + 1) begin
						code = $fscanf(fd, " %h", wt);
						want[i] = wt;
					end
					j = 0;
					@(posedge clk);
					while (busy && j < 200000) begin
						@(posedge clk);
						j = j + 1;
					end
					k = 0;
					for (i = 0; i < nw; i = i + 1)
						if (mem.peek(RT_REG + 4 * i) !== want[i]) begin
							if (k < 4)
								$display("FAIL atg_rop_mrt LB %0d: run %0d (ms4 %0d fmts %h) word %h = %h, want %h",
									LINE_BYTES, nrun, ms4, fmts, RT_REG + 4 * i,
									mem.peek(RT_REG + 4 * i), want[i]);
							k = k + 1;
						end
					if (busy) begin
						$display("FAIL atg_rop_mrt LB %0d: run %0d still busy", LINE_BYTES, nrun);
						k = k + 1;
					end
					errs[ms4[0]] = errs[ms4[0]] + k;
					nrun = nrun + 1;
				end else begin
					$display("FAIL atg_rop_mrt: bad line tag %h", tag);
					errs[0] = errs[0] + 1;
					code = 0;
				end
			end
			$fclose(fd);
			$display("atg_rop_mrt LB %0d: %0d runs", LINE_BYTES, nrun);
			if (nrun != 72)
				errs[0] = errs[0] + 1;
			fin = 1'b1;
		end
	end
endmodule

module atg_rop_mrt_tb;
	reg clk = 1'b0;
	reg go = 1'b0;
	always #5 clk = !clk;
	wire f32, f64;

	atg_rop_mrt_tbc #(.LINE_BYTES(32), .LINE_SHIFT(5), .SEED(3)) c32 (.clk(clk), .go(go), .fin(f32));
	atg_rop_mrt_tbc #(.LINE_BYTES(64), .LINE_SHIFT(6), .SEED(5)) c64 (.clk(clk), .go(go), .fin(f64));

	initial begin
		#200000000;
		$display("FAIL atg_rop_mrt: timeout");
		$finish;
	end

	initial begin
		#20 go = 1'b1;
		wait (f32 && f64);
		if (c32.errs[0] + c64.errs[0] == 0)
			$display("PASS atg_rop_mrt.one");
		if (c32.errs[1] + c64.errs[1] == 0)
			$display("PASS atg_rop_mrt.four");
		if (c32.errs[0] + c64.errs[0] + c32.errs[1] + c64.errs[1] == 0)
			$display("PASS atg_rop_mrt");
		$finish;
	end
endmodule

`default_nettype wire
