/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_axi_master_tb: am_axi_master against axi_mem (random ready and
 * latency, protocol checks) in two shapes, 32-byte lines on
 * 64-bit AXI (4 beats) and the KC705's (64-byte lines, 512-bit AXI,
 * 1 beat).  Random line reads and byte-masked writes are compared with a
 * reference copy of memory; reads and writes must each come back in order
 * with their user bits; addresses in the error region answer error.
 * Quiesce: with halt raised at random moments req_ready stays 0, idle
 * comes within a bound, and the traffic resumes after halt falls.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_axi_master_harness #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter DATA_W = 64,
	parameter NREQ = 2000,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	output reg finished,
	output integer errors
);
	localparam LB = LINE_BYTES * 8;
	localparam NLINES = 64;		/* lines under test, from 0 */
	localparam [31:0] ERR_BASE = 32'h00100000;

	reg halt = 1'b0;
	wire idle;
	reg req_valid = 1'b0;
	wire req_ready;
	reg req_write = 1'b0;
	reg [31-LINE_SHIFT:0] req_line = 0;
	reg [LINE_BYTES-1:0] req_be = 0;
	reg [LB-1:0] req_wdata = 0;
	reg [15:0] req_user = 0;
	wire rsp_valid;
	wire rsp_write;
	wire [15:0] rsp_user;
	wire [LB-1:0] rsp_rdata;
	wire rsp_error;

	wire [31:0] awaddr, araddr;
	wire [7:0] awlen, arlen;
	wire [2:0] awsize, arsize, awprot, arprot;
	wire [1:0] awburst, arburst, bresp, rresp;
	wire [3:0] awcache, arcache;
	wire awvalid, awready, wlast, wvalid, wready, bvalid, bready;
	wire arvalid, arready, rlast, rvalid, rready;
	wire [DATA_W-1:0] wdata, rdata;
	wire [DATA_W/8-1:0] wstrb;

	am_axi_master #(
		.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .DATA_W(DATA_W), .UW(16)
	) dut (
		.clk(clk), .rst_n(rst_n), .halt(halt), .idle(idle),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_user(req_user),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_user(rsp_user),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
		.m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(awburst),
		.m_awcache(awcache), .m_awprot(awprot), .m_awvalid(awvalid), .m_awready(awready),
		.m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid),
		.m_wready(wready), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
		.m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(arburst),
		.m_arcache(arcache), .m_arprot(arprot), .m_arvalid(arvalid), .m_arready(arready),
		.m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast), .m_rvalid(rvalid),
		.m_rready(rready)
	);

	axi_mem #(.DATA_W(DATA_W), .MEM_BYTES(1 << 16), .ERR_BASE(ERR_BASE), .SEED(SEED)) mem (
		.clk(clk), .rst_n(rst_n),
		.awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
		.awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
		.wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp),
		.bvalid(bvalid), .bready(bready), .araddr(araddr), .arlen(arlen),
		.arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
		.rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
	);

	/* The reference, per line; the expected data of each outstanding read
	 * by its user number. */
	reg [LB-1:0] ref [0:NLINES-1];
	integer rd_pend [0:NLINES-1];
	integer wr_pend [0:NLINES-1];
	reg [LB-1:0] rd_expect [0:255];
	reg rd_experr [0:255];
	reg [7:0] rd_line [0:255];
	reg wr_experr [0:255];
	reg [7:0] wr_line [0:255];
	integer seed;
	integer issued, answered;
	integer rd_seq, wr_seq;		/* user numbers given */
	integer rd_next, wr_next;	/* user numbers expected back */
	integer n, b, line, halt_wait;
	reg is_err;
	reg wr;
	reg [LB-1:0] mask;

	function [LB-1:0] be_mask;
		input [LINE_BYTES-1:0] be;
		integer k;
		begin
			for (k = 0; k < LINE_BYTES; k = k + 1)
				be_mask[k*8 +: 8] = {8{be[k]}};
		end
	endfunction

	/* Responses. */
	always @(posedge clk) begin
		if (rst_n && rsp_valid) begin
			answered = answered + 1;
			if (rsp_write) begin
				if (rsp_user[15] !== 1'b1 || rsp_user[7:0] !== wr_next[7:0]) begin
					errors = errors + 1;
					$display("FAIL am_axi_master: write response %h, expected %h", rsp_user, wr_next);
				end
				if (rsp_error !== wr_experr[wr_next % 256]) begin
					errors = errors + 1;
					$display("FAIL am_axi_master: write error %b", rsp_error);
				end
				if (!wr_experr[wr_next % 256])
					wr_pend[wr_line[wr_next % 256]] = wr_pend[wr_line[wr_next % 256]] - 1;
				wr_next = wr_next + 1;
			end else begin
				if (rsp_user[15] !== 1'b0 || rsp_user[7:0] !== rd_next[7:0]) begin
					errors = errors + 1;
					$display("FAIL am_axi_master: read response %h, expected %h", rsp_user, rd_next);
				end
				if (rsp_error !== rd_experr[rd_next % 256]) begin
					errors = errors + 1;
					$display("FAIL am_axi_master: read error %b", rsp_error);
				end else if (!rsp_error && rsp_rdata !== rd_expect[rd_next % 256]) begin
					errors = errors + 1;
					$display("FAIL am_axi_master: read data %h, expected %h", rsp_rdata,
						rd_expect[rd_next % 256]);
				end
				if (!rd_experr[rd_next % 256])
					rd_pend[rd_line[rd_next % 256]] = rd_pend[rd_line[rd_next % 256]] - 1;
				rd_next = rd_next + 1;
			end
		end
	end

	initial begin
		finished = 1'b0;
		errors = 0;
		seed = SEED;
		issued = 0;
		answered = 0;
		rd_seq = 0;
		wr_seq = 0;
		rd_next = 0;
		wr_next = 0;
		for (n = 0; n < NLINES; n = n + 1) begin
			ref[n] = {LB{1'b0}};
			rd_pend[n] = 0;
			wr_pend[n] = 0;
		end
		wait (rst_n);
		@(posedge clk);
		while (issued < NREQ) begin
			/* Sometimes: quiesce. */
			if ($unsigned($random(seed)) % 200 == 0) begin
				halt <= 1'b1;
				req_valid <= 1'b0;
				halt_wait = 0;
				@(posedge clk);
				while (!idle) begin
					if (req_ready) begin
						errors = errors + 1;
						$display("FAIL am_axi_master: req_ready under halt");
					end
					halt_wait = halt_wait + 1;
					if (halt_wait > 400) begin
						errors = errors + 1;
						$display("FAIL am_axi_master: no idle after halt");
						halt_wait = -100000;
					end
					@(posedge clk);
				end
				if (rd_seq != rd_next || wr_seq != wr_next) begin
					errors = errors + 1;
					$display("FAIL am_axi_master: idle with responses owed");
				end
				halt <= 1'b0;
				@(posedge clk);
			end
			/* A request on a line with nothing outstanding against it. */
			line = $unsigned($random(seed)) % NLINES;
			is_err = ($unsigned($random(seed)) % 50) == 0;
			wr = $random(seed);
			if (wr ? (rd_pend[line] != 0 || wr_pend[line] > 2) : (wr_pend[line] != 0)) begin
				@(posedge clk);
			end else begin
				req_write <= wr;
				req_line <= is_err ? (ERR_BASE >> LINE_SHIFT) + line : line;
				for (b = 0; b < LINE_BYTES; b = b + 1)
					req_be[b] <= $random(seed);
				for (b = 0; b < LB / 32; b = b + 1)
					req_wdata[b*32 +: 32] <= $random(seed);
				req_user <= wr ? {8'h80, wr_seq[7:0]} : {8'h00, rd_seq[7:0]};
				req_valid <= 1'b1;
				@(posedge clk);
				while (!req_ready)
					@(posedge clk);
				/* Taken at this edge. */
				if (wr) begin
					wr_experr[wr_seq % 256] = is_err;
					wr_line[wr_seq % 256] = line;
					if (!is_err) begin
						mask = be_mask(req_be);
						ref[line] = (ref[line] & ~mask) | (req_wdata & mask);
						wr_pend[line] = wr_pend[line] + 1;
					end
					wr_seq = wr_seq + 1;
				end else begin
					rd_experr[rd_seq % 256] = is_err;
					rd_line[rd_seq % 256] = line;
					rd_expect[rd_seq % 256] = ref[line];
					if (!is_err)
						rd_pend[line] = rd_pend[line] + 1;
					rd_seq = rd_seq + 1;
				end
				issued = issued + 1;
				req_valid <= 1'b0;
				if ($unsigned($random(seed)) % 2)
					@(posedge clk);
			end
		end
		req_valid <= 1'b0;
		n = 0;
		while (answered < issued && n < 1000) begin
			@(posedge clk);
			n = n + 1;
		end
		if (answered != issued) begin
			errors = errors + 1;
			$display("FAIL am_axi_master: %0d requests, %0d responses", issued, answered);
		end
		@(posedge clk);
		if (!idle) begin
			errors = errors + 1;
			$display("FAIL am_axi_master: not idle at the end");
		end
		errors = errors + mem.errors;
		finished = 1'b1;
	end
endmodule

module am_axi_master_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	wire done_l32, done_kc705;
	wire [31:0] err_l32, err_kc705;

	always #5 clk = !clk;

	am_axi_master_harness #(.LINE_BYTES(32), .LINE_SHIFT(5), .DATA_W(64), .SEED(11)) l32 (
		.clk(clk), .rst_n(rst_n), .finished(done_l32), .errors(err_l32)
	);
	am_axi_master_harness #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .SEED(23)) kc705 (
		.clk(clk), .rst_n(rst_n), .finished(done_kc705), .errors(err_kc705)
	);

	initial begin
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		wait (done_l32 && done_kc705);
		if (err_l32 == 0 && err_kc705 == 0)
			$display("PASS am_axi_master");
		else
			$display("FAIL am_axi_master: %0d + %0d errors", err_l32, err_kc705);
		$finish;
	end

	initial begin
		#5000000;
		$display("FAIL am_axi_master: timeout");
		$finish;
	end
endmodule

`default_nettype wire
