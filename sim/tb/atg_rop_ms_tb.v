/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_ms_tb: the render output with multisampling: atg_rop as a whole
 * (atg_rop_order, atg_rop_ms, atg_rop_ds, atg_rop_wb, atg_rop_blend)
 * against amb_mem and the reference model (sim/vec/rop_ms.txt from
 * tools/rx-msaa-vectors.py, tools/msmodel.py rop_quad_ms), in the two line
 * sizes at once.  Per run: the STATE (MS_CTRL, DEPTH, RT_FORMAT, BLEND,
 * WRITE_MASK, DEBUG_COLOR; the RT and DS of a 16x8 image in the
 * sample-interleaved layout), the RT and DS images, 60 quads in sequence
 * order (the SU's, with ex_ms: the sample mask, the lanes that exported
 * DEPTH, d_s; and some of the direct path's), then both images compared
 * word for word with the model's once the ROP is idle.  Prints:
 *   PASS atg_rop_ms.depth     4 samples: D32F and D24S8, BGRA8, RGBA8,
 *                             RGB565: the depth of each sample (z + d_s
 *                             clamped, or the exported depth), the test
 *                             and the write per sample, the colour per
 *                             sample, the direct path
 *   PASS atg_rop_ms.a2c       alpha to coverage, and with alpha to one
 *   PASS atg_rop_ms.blend     blend per sample
 *   PASS atg_rop_ms.bypass1x  one sample (MS_CTRL 0x100 and 0): the
 *                             layout, the test and the colour as before
 *   PASS atg_rop_ms
 * MUT_A2C_STEP fails .a2c.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_ms_tbc #(
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
	localparam [31:0] RT_BASE = 32'h1000, DS_BASE = 32'h5000;

	reg rst_n = 1'b0;
	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg ex_valid = 1'b0, ex_last = 1'b1, dx_valid = 1'b0, dx_last = 1'b1;
	reg [15:0] ex_seq = 0, dx_seq = 0;
	reg [31:0] ex_xy = 0, dx_xy = 0;
	reg [3:0] ex_mask = 0, dx_mask = 0;
	reg [511:0] ex_color = 0;
	reg [127:0] ex_depth = 0, dx_depth = 0;
	reg [148:0] ex_ms = 0;
	wire busy, ex_ready, dx_ready;
	wire [15:0] ex_next;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [LA_W-1:0] req_line;
	wire [LINE_BYTES-1:0] req_be;
	wire [LINE_BYTES*8-1:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;

	atg_rop #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) dut (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.busy(busy), .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy),
		.ex_mask(ex_mask), .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last),
		.ex_next(ex_next), .ex_ms(ex_ms),
		.dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy),
		.dx_mask(dx_mask), .dx_depth(dx_depth), .dx_last(dx_last),
		.ord_valid(1'b0), .ord_seq(16'd0), .occ_count(), .occ_clear(1'b0),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));

	amb_mem #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .MEM_WORDS(8192), .SEED(SEED)) mem (
		.clk(clk), .rst_n(rst_n),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));

	integer errs [0:7];	/* per run */
	integer nrun = 0, fd, code, i, n, nq, ns, ps, rtw, dsw, t;
	reg [7:0] tag;
	reg [31:0] ctrl, dep, fmt, bl, wm, dbgc, v, w, x, y, dbg;
	reg [3:0] m;
	reg [148:0] msv;
	reg [511:0] cv;
	reg [127:0] zv;
	reg [15:0] seq;

	task st;
		input [8:0] idx;
		input [31:0] val;
		begin
			@(posedge clk);
			st_we <= 1'b1;
			st_idx <= idx;
			st_wdata <= val;
			@(posedge clk);
			st_we <= 1'b0;
		end
	endtask

	initial begin
		fin = 1'b0;
		for (i = 0; i < 8; i = i + 1)
			errs[i] = 0;
		@(posedge go);
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		seq = 16'd0;
		fd = $fopen("sim/vec/rop_ms.txt", "r");
		if (fd == 0) begin
			errs[0] = errs[0] + 1;
			$display("FAIL atg_rop_ms: no sim/vec/rop_ms.txt");
		end
		code = fd != 0;
		while (code > 0) begin
			code = $fscanf(fd, "%c", tag);
			if (tag == "R") begin
				code = $fscanf(fd, " %h %h %h %h %h %h %d\n", ctrl, dep, fmt, bl, wm, dbgc, nq);
				ns = ctrl[3:0] == 4'd2 ? 4 : 1;
				ps = fmt == 2 ? 2 : 4;
				rtw = 16 * ns * ps * 8 / 4;
				dsw = 16 * ns * 4 * 8 / 4;
				st(GHCI_S_MS_CTRL, ctrl);
				st(GHCI_S_DEPTH, dep);
				st(GHCI_S_RT_FORMAT, fmt);
				st(GHCI_S_BLEND, bl);
				st(GHCI_S_WRITE_MASK, wm);
				st(GHCI_S_DEBUG_COLOR, dbgc);
				st(GHCI_S_RT_BASE, RT_BASE);
				st(GHCI_S_RT_STRIDE, 16 * ns * ps);
				st(GHCI_S_DS_BASE, DS_BASE);
				st(GHCI_S_DS_STRIDE, 16 * ns * 4);
				code = $fscanf(fd, "%c", tag);	/* I */
				for (i = 0; i < rtw; i = i + 1) begin
					code = $fscanf(fd, " %h", w);
					mem.poke(RT_BASE + 4 * i, w);
				end
				for (i = 0; i < dsw; i = i + 1) begin
					code = $fscanf(fd, " %h", w);
					mem.poke(DS_BASE + 4 * i, w);
				end
				code = $fscanf(fd, "%c", tag);	/* newline */
				for (n = 0; n < nq; n = n + 1) begin
					code = $fscanf(fd, "Q %h %h %h %h %h %h %h\n", dbg, x, y, m, msv, cv, zv);
					@(posedge clk);
					if (dbg[0]) begin
						dx_valid <= 1'b1;
						dx_seq <= seq;
						dx_xy <= {y[15:0], x[15:0]};
						dx_mask <= m;
						dx_depth <= zv;
						@(posedge clk);
						while (!dx_ready)
							@(posedge clk);
						dx_valid <= 1'b0;
					end else begin
						ex_valid <= 1'b1;
						ex_seq <= seq;
						ex_xy <= {y[15:0], x[15:0]};
						ex_mask <= m;
						ex_color <= cv;
						ex_depth <= zv;
						ex_ms <= msv;
						@(posedge clk);
						while (!ex_ready)
							@(posedge clk);
						ex_valid <= 1'b0;
					end
					seq = seq + 16'd1;
				end
				t = 0;
				@(posedge clk);
				while (busy && t < 100000) begin
					@(posedge clk);
					t = t + 1;
				end
				code = $fscanf(fd, "%c", tag);	/* F */
				for (i = 0; i < rtw + dsw; i = i + 1) begin
					code = $fscanf(fd, " %h", w);
					v = i < rtw ? mem.peek(RT_BASE + 4 * i) : mem.peek(DS_BASE + 4 * (i - rtw));
					if (v !== w) begin
						if (errs[nrun] < 3)
							$display("FAIL atg_rop_ms LB %0d: run %0d %s word %0d = %h, want %h",
								LINE_BYTES, nrun, i < rtw ? "RT" : "DS", i < rtw ? i : i - rtw,
								v, w);
						errs[nrun] = errs[nrun] + 1;
					end
				end
				code = $fscanf(fd, "%c", tag);	/* newline */
				nrun = nrun + 1;
			end else
				code = 0;
		end
		if (nrun != 8) begin
			errs[0] = errs[0] + 1;
			$display("FAIL atg_rop_ms LB %0d: %0d runs", LINE_BYTES, nrun);
		end
		fin = 1'b1;
	end
endmodule

module atg_rop_ms_tb;
	reg clk = 1'b0;
	reg go = 1'b0;
	always #5 clk = !clk;
	wire f32, f64;

	atg_rop_ms_tbc #(.LINE_BYTES(32), .LINE_SHIFT(5), .SEED(3)) c32 (.clk(clk), .go(go), .fin(f32));
	atg_rop_ms_tbc #(.LINE_BYTES(64), .LINE_SHIFT(6), .SEED(5)) c64 (.clk(clk), .go(go), .fin(f64));

	function integer e;
		input integer a, b;
		e = c32.errs[a] + c64.errs[a] + (b > a ? c32.errs[b] + c64.errs[b] : 0);
	endfunction

	initial begin
		#20000000;
		$display("FAIL atg_rop_ms: timeout");
		$finish;
	end

	integer tot;
	initial begin
		#20 go = 1'b1;
		wait (f32 && f64);
		tot = e(0, 2) + c32.errs[1] + c64.errs[1];
		if (tot == 0) $display("PASS atg_rop_ms.depth");
		if (e(3, 4) == 0) $display("PASS atg_rop_ms.a2c");
		if (e(5, 5) == 0) $display("PASS atg_rop_ms.blend");
		if (e(6, 7) == 0) $display("PASS atg_rop_ms.bypass1x");
		if (tot + e(3, 4) + e(5, 5) + e(6, 7) == 0)
			$display("PASS atg_rop_ms");
		$finish;
	end
endmodule

`default_nettype wire
