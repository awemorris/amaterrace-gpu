/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_dma_tb: atg_cpu_dma with a real atg_cpu_mem and a behavioural
 * AMB memory (random request acceptance and response latency, responses
 * in order per direction, an error for lines in a bad range), in both
 * line sizes (32 and 64 bytes) at once.  read: memory -> DMEM of several
 * lines (up to 4 reads outstanding, more than 1 seen).  write: DMEM ->
 * memory, the write counter rises and falls to 0 on the responses.
 * load: an image load of a word count that is not a whole number of
 * lines into IMEM and into DMEM.  error: an error response stops a read,
 * a write and a load and reports it.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_dma_harness #(
	parameter LB = 32,
	parameter LS = 5
) (
	input wire clk,
	input wire [31:0] seed0,
	output reg done,
	output reg [31:0] fails,
	output reg [3:0] passed
);
	localparam LW = 32 - LS;
	localparam WPL = LB / 4;
	localparam MLINES = 1024;	/* AMB model: lines 0x100.. */
	localparam BASE = 32'h0010_0000;
	localparam [LW-1:0] BAD_LINE = (BASE >> LS) + 700;

	reg rst_n = 1'b0;
	reg sb_we = 1'b0, sb_re = 1'b0;
	reg [5:0] sb_idx = 0;
	reg [31:0] sb_wdata = 0;
	wire [31:0] sb_rdata;
	reg ld_start = 1'b0, ld_imem = 1'b0;
	reg [31:0] ld_addr = 0, ld_words = 0;
	wire ld_done, ld_error;
	wire x_en, x_we, x_imem;
	wire [31:0] x_addr, x_wdata, x_rdata;
	wire wait_amb;
	wire req_valid, req_write;
	reg req_ready = 1'b0;
	wire [LW-1:0] req_line;
	wire [LB-1:0] req_be;
	wire [LB*8-1:0] req_wdata;
	wire [7:0] req_tag;
	reg rsp_valid = 1'b0, rsp_write = 1'b0, rsp_error = 1'b0;
	reg [7:0] rsp_tag = 0;
	reg [LB*8-1:0] rsp_rdata = 0;
	wire [31:0] i_rdata, d_rdata;

	atg_cpu_dma #(.ADDR_W(32), .LINE_BYTES(LB), .LINE_SHIFT(LS)) dut (
		.clk(clk), .rst_n(rst_n),
		.sb_we(sb_we), .sb_re(sb_re), .sb_idx(sb_idx), .sb_wdata(sb_wdata), .sb_rdata(sb_rdata),
		.ld_start(ld_start), .ld_imem(ld_imem), .ld_addr(ld_addr), .ld_words(ld_words),
		.ld_done(ld_done), .ld_error(ld_error),
		.x_en(x_en), .x_we(x_we), .x_imem(x_imem), .x_addr(x_addr), .x_wdata(x_wdata),
		.x_rdata(x_rdata), .wait_amb(wait_amb),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
		.req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
		.rsp_error(rsp_error)
	);

	atg_cpu_mem #(.IMEM_WORDS(1024), .DMEM_WORDS(1024)) mem (
		.clk(clk),
		.i_en(1'b0), .i_addr(32'd0), .i_rdata(i_rdata),
		.d_en(1'b0), .d_we(4'd0), .d_addr(32'd0), .d_wdata(32'd0), .d_rdata(d_rdata),
		.x_en(x_en), .x_we(x_we), .x_imem(x_imem), .x_addr(x_addr), .x_wdata(x_wdata),
		.x_rdata(x_rdata)
	);

	/* AMB model: queues of accepted requests, answered in order per direction. */
	reg [LB*8-1:0] amem [0:MLINES-1];
	reg [LW-1:0] rq_line [0:63];
	reg [7:0] rq_tag [0:63];
	integer rq_w = 0, rq_r = 0, rq_t = 0;
	integer wq_n = 0, wq_t = 0;
	reg [LW-1:0] wq_line [0:63];
	integer wq_w = 0, wq_r = 0;
	integer outstanding_rd = 0, max_rd = 0, max_wr = 0;
	integer seed;
	integer errors = 0;
	integer i, j, e0, n;
	reg [31:0] w;

	function bad;
		input [LW-1:0] l;
		bad = l == BAD_LINE || l < (BASE >> LS) || l >= (BASE >> LS) + MLINES;
	endfunction

	always @(posedge clk) begin
		rsp_valid <= 1'b0;
		rsp_error <= 1'b0;
		if (req_valid && req_ready) begin
			if (req_write) begin
				if (!bad(req_line))
					amem[req_line - (BASE >> LS)] <= req_wdata;
				wq_line[wq_w % 64] = req_line;
				wq_w = wq_w + 1;
				if (req_be != {LB{1'b1}}) begin
					$display("FAIL write without all bytes");
					errors = errors + 1;
				end
			end else begin
				rq_line[rq_w % 64] = req_line;
				rq_tag[rq_w % 64] = req_tag;
				rq_w = rq_w + 1;
			end
		end
		if (rq_w - rq_r > max_rd)
			max_rd = rq_w - rq_r;
		if (dut.wr_out > max_wr)
			max_wr = dut.wr_out;
		/* One response per cycle: a read or a write when its delay ran out. */
		if (rq_w != rq_r && rq_t <= 0) begin
			rsp_valid <= 1'b1;
			rsp_write <= 1'b0;
			rsp_tag <= rq_tag[rq_r % 64];
			rsp_error <= bad(rq_line[rq_r % 64]);
			rsp_rdata <= bad(rq_line[rq_r % 64]) ? {LB{8'hEE}} :
				amem[rq_line[rq_r % 64] - (BASE >> LS)];
			rq_r = rq_r + 1;
			rq_t = $random(seed) & 15;
		end else if (wq_w != wq_r && wq_t <= 0) begin
			rsp_valid <= 1'b1;
			rsp_write <= 1'b1;
			rsp_tag <= 8'h80;
			rsp_error <= bad(wq_line[wq_r % 64]);
			wq_r = wq_r + 1;
			wq_t = $random(seed) & 31;
		end else begin
			rq_t = rq_t - 1;
			wq_t = wq_t - 1;
		end
	end

	always @(negedge clk)
		req_ready = ($random(seed) & 3) != 0;

	/* Sub-bus access like atg_cpu_win. */
	task sbw;
		input [5:0] idx;
		input [31:0] data;
		begin
			@(negedge clk);
			sb_we = 1'b1;
			sb_idx = idx;
			sb_wdata = data;
			@(negedge clk);
			sb_we = 1'b0;
		end
	endtask

	task sbr;
		input [5:0] idx;
		begin
			@(negedge clk);
			sb_re = 1'b1;
			sb_idx = idx;
			#1;
			w = sb_rdata;
			@(negedge clk);
			sb_re = 1'b0;
		end
	endtask

	task wait_idle;
		begin
			n = 0;
			sbr(6'h13);
			while (w[0] && n < 20000) begin
				sbr(6'h13);
				n = n + 1;
			end
			if (w[0]) begin
				$display("FAIL LB=%0d DMA stays busy", LB);
				errors = errors + 1;
			end
		end
	endtask

	task load;
		input im;
		input [31:0] addr;
		input [31:0] words;
		begin
			@(negedge clk);
			ld_start = 1'b1;
			ld_imem = im;
			ld_addr = addr;
			ld_words = words;
			@(negedge clk);
			ld_start = 1'b0;
			n = 0;
			while (!ld_done && n < 20000) begin
				@(posedge clk);
				#1;
				n = n + 1;
			end
		end
	endtask

	function [31:0] aword;
		input integer line;
		input integer k;
		reg [LB*8-1:0] l;
		begin
			l = amem[line];
			aword = l[32 * k +: 32];
		end
	endfunction

	initial begin
		done = 1'b0;
		passed = 4'd0;
		fails = 0;
		seed = seed0;
		for (i = 0; i < MLINES; i = i + 1)
			for (j = 0; j < WPL; j = j + 1)
				amem[i][32 * j +: 32] = {i[15:0], j[7:0], 8'hA5} ^ (LB << 24);
		for (i = 0; i < 1024; i = i + 1) begin
			mem.dmem[i] = 32'hD0D0_0000 + i;
			mem.imem[i] = 32'h1111_0000 + i;
		end
		repeat (3) @(negedge clk);
		rst_n = 1'b1;

		/* read: 20 lines from line 10 into DMEM at 2 lines in. */
		e0 = errors;
		sbw(6'h10, BASE + 10 * LB);
		sbw(6'h11, 2 * LB);
		sbr(6'h10);
		if (w != BASE + 10 * LB) begin
			$display("FAIL LB=%0d DMA_AMB readback %h", LB, w);
			errors = errors + 1;
		end
		sbw(6'h12, 20);
		wait_idle;
		for (i = 0; i < 1024; i = i + 1) begin
			j = i - 2 * WPL;
			if (j >= 0 && j < 20 * WPL)
				w = aword(10 + j / WPL, j % WPL);
			else
				w = 32'hD0D0_0000 + i;
			if (mem.dmem[i] !== w) begin
				$display("FAIL LB=%0d read: dmem[%0d] %h want %h", LB, i, mem.dmem[i], w);
				errors = errors + 1;
			end
		end
		if (max_rd > 4 || max_rd < 2) begin
			$display("FAIL LB=%0d reads outstanding max %0d", LB, max_rd);
			errors = errors + 1;
		end
		sbr(6'h13);
		if (w[1]) begin
			$display("FAIL LB=%0d read error flag", LB);
			errors = errors + 1;
		end
		if (errors == e0)
			passed[0] = 1'b1;

		/* write: 12 lines of DMEM from offset 0 to line 200. */
		e0 = errors;
		for (i = 0; i < 1024; i = i + 1)
			mem.dmem[i] = 32'hC0DE_0000 + i * 3;
		sbw(6'h10, BASE + 200 * LB);
		sbw(6'h11, 0);
		sbw(6'h12, 32'h0001_0000 | 12);
		wait_idle;
		n = 0;
		sbr(6'h13);
		while (w[15:8] != 0 && n < 2000) begin
			sbr(6'h13);
			n = n + 1;
		end
		if (w[15:8] != 0 || w[1] || max_wr < 1) begin
			$display("FAIL LB=%0d write status %h max outstanding %0d", LB, w, max_wr);
			errors = errors + 1;
		end
		for (i = 0; i < 12 * WPL; i = i + 1)
			if (aword(200 + i / WPL, i % WPL) !== 32'hC0DE_0000 + i * 3) begin
				$display("FAIL LB=%0d write: word %0d %h", LB, i, aword(200 + i / WPL, i % WPL));
				errors = errors + 1;
			end
		if (aword(212, 0) !== ({16'd212, 8'd0, 8'hA5} ^ (LB << 24))) begin
			$display("FAIL LB=%0d write past the end", LB);
			errors = errors + 1;
		end
		if (errors == e0)
			passed[1] = 1'b1;

		/* load: 5 lines + 3 words into IMEM, then 2 words into DMEM. */
		e0 = errors;
		load(1, BASE + 300 * LB, 5 * WPL + 3);
		if (!ld_done || ld_error) begin
			$display("FAIL LB=%0d load done %b error %b", LB, ld_done, ld_error);
			errors = errors + 1;
		end
		for (i = 0; i < 1024; i = i + 1) begin
			w = (i < 5 * WPL + 3) ? aword(300 + i / WPL, i % WPL) : 32'h1111_0000 + i;
			if (mem.imem[i] !== w) begin
				$display("FAIL LB=%0d load: imem[%0d] %h want %h", LB, i, mem.imem[i], w);
				errors = errors + 1;
			end
		end
		load(0, BASE + 310 * LB, 2);
		if (mem.dmem[0] !== aword(310, 0) || mem.dmem[1] !== aword(310, 1) ||
			mem.dmem[2] !== 32'hC0DE_0006) begin
			$display("FAIL LB=%0d DMEM load", LB);
			errors = errors + 1;
		end
		@(posedge clk);
		#1;
		if (ld_done) begin
			$display("FAIL LB=%0d ld_done longer than one cycle", LB);
			errors = errors + 1;
		end
		if (errors == e0)
			passed[2] = 1'b1;

		/* error: a read across the bad line, a write onto it, a load across it. */
		e0 = errors;
		sbw(6'h10, BASE + 690 * LB);
		sbw(6'h11, 0);
		sbw(6'h12, 30);
		wait_idle;
		if (!w[1]) begin
			$display("FAIL LB=%0d read error not reported", LB);
			errors = errors + 1;
		end
		if (mem.dmem[11 * WPL] === aword(701, 0) || mem.dmem[9 * WPL] !== aword(699, 0)) begin
			$display("FAIL LB=%0d read went on after the error", LB);
			errors = errors + 1;
		end
		sbw(6'h10, BASE + 700 * LB);
		sbw(6'h12, 32'h0001_0000 | 3);
		wait_idle;
		n = 0;
		sbr(6'h13);
		while (w[15:8] != 0 && n < 2000) begin
			sbr(6'h13);
			n = n + 1;
		end
		if (!w[1] || w[15:8] != 0) begin
			$display("FAIL LB=%0d write error status %h", LB, w);
			errors = errors + 1;
		end
		/* A good copy afterwards clears the error. */
		sbw(6'h10, BASE);
		sbw(6'h12, 1);
		wait_idle;
		if (w[1]) begin
			$display("FAIL LB=%0d error not cleared by the next copy", LB);
			errors = errors + 1;
		end
		load(1, BASE + 698 * LB, 4 * WPL);
		if (!ld_done || !ld_error) begin
			$display("FAIL LB=%0d load error: done %b error %b", LB, ld_done, ld_error);
			errors = errors + 1;
		end
		/* Requests outside the model's range would be errors: none expected. */
		if (errors == e0)
			passed[3] = 1'b1;
		fails = errors;
		done = 1'b1;
	end
endmodule

module atg_cpu_dma_tb;
	reg clk = 1'b0;
	integer seed = 1;
	wire done32, done64;
	wire [31:0] f32, f64;
	wire [3:0] p32, p64;
	reg [31:0] s32, s64;

	always #5 clk = !clk;

	atg_cpu_dma_harness #(.LB(32), .LS(5)) h32 (.clk(clk), .seed0(s32), .done(done32),
		.fails(f32), .passed(p32));
	atg_cpu_dma_harness #(.LB(64), .LS(6)) h64 (.clk(clk), .seed0(s64), .done(done64),
		.fails(f64), .passed(p64));

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;
		s32 = seed;
		s64 = seed + 1000;
		wait (done32 && done64);
		if (p32[0] && p64[0])
			$display("PASS atg_cpu_dma.read");
		if (p32[1] && p64[1])
			$display("PASS atg_cpu_dma.write");
		if (p32[2] && p64[2])
			$display("PASS atg_cpu_dma.load");
		if (p32[3] && p64[3])
			$display("PASS atg_cpu_dma.error");
		if (f32 == 0 && f64 == 0 && (&p32) && (&p64))
			$display("PASS atg_cpu_dma");
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL timeout");
		$finish;
	end
endmodule

`default_nettype wire
