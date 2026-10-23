/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_icache_tb: the I$ (2 KiB, 32-byte lines) behind amb_mem.  hit:
 * after the first miss of a line its instructions come one cycle after the
 * request, without memory reads; conflict: two addresses 2 KiB apart
 * replace each other; inv: inv forces misses, and a fill during which inv
 * pulsed answers its request but is not kept; an error response returns
 * the instruction 0.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_icache_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg ic_req = 1'b0;
	wire ic_ready, ic_rvalid;
	reg [31:0] ic_addr = 0;
	wire [63:0] ic_rdata;
	reg inv = 1'b0;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;
	integer errors = 0, ec;
	integer reads = 0;
	integer lat, i;

	always #5 clk = !clk;

	atg_su_icache dut (
		.clk(clk), .rst_n(rst_n), .ic_req(ic_req), .ic_ready(ic_ready), .ic_addr(ic_addr),
		.ic_rvalid(ic_rvalid), .ic_rdata(ic_rdata), .inv(inv),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);
	amb_mem #(.ERR_BASE(32'h3000)) mem (
		.clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready),
		.req_write(req_write), .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata),
		.req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	always @(posedge clk)
		if (req_valid && req_ready)
			reads = reads + 1;

	function [63:0] want;
		input [31:0] a;
		want = a >= 32'h3000 ? 64'd0 : {a ^ 32'h5A5A0004, a ^ 32'hA5A50000};
	endfunction

	/* One fetch: lat is cycles from the request to the instruction. */
	task fetch;
		input [31:0] a;
		input inv_mid;
		begin
			@(negedge clk);
			ic_req = 1'b1;
			ic_addr = a;
			lat = 0;
			#1;
			while (!ic_ready) begin
				if (inv_mid && lat == 3) begin
					inv = 1'b1;
				end
				@(negedge clk);
				inv = 1'b0;
				lat = lat + 1;
				#1;
			end
			@(negedge clk);
			ic_req = 1'b0;
			lat = lat + 1;
			if (!ic_rvalid || ic_rdata !== want(a)) begin
				$display("FAIL atg_su_icache: %h gave %h (%b) want %h", a, ic_rdata, ic_rvalid,
					want(a));
				errors = errors + 1;
			end
		end
	endtask

	initial begin
		for (i = 0; i < 16384; i = i + 8) begin
			mem.poke(i, i ^ 32'hA5A50000);
			mem.poke(i + 4, i ^ 32'h5A5A0004);
		end
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		/* hit */
		ec = errors;
		fetch(32'h100, 0);
		if (lat < 3 || reads != 1) begin
			$display("FAIL atg_su_icache.hit first miss lat %0d reads %0d", lat, reads);
			errors = errors + 1;
		end
		for (i = 0; i < 4; i = i + 1) begin
			fetch(32'h100 + 8 * i, 0);
			if (lat != 1 || reads != 1) begin
				$display("FAIL atg_su_icache.hit lat %0d reads %0d", lat, reads);
				errors = errors + 1;
			end
		end
		/* Back-to-back hits: one per cycle. */
		@(negedge clk);
		ic_req = 1'b1;
		for (i = 0; i < 4; i = i + 1) begin
			ic_addr = 32'h100 + 8 * i;
			#1;
			if (!ic_ready) begin
				$display("FAIL atg_su_icache.hit back-to-back");
				errors = errors + 1;
			end
			@(negedge clk);
			if (!ic_rvalid || ic_rdata !== want(32'h100 + 8 * i)) begin
				$display("FAIL atg_su_icache.hit back-to-back data");
				errors = errors + 1;
			end
		end
		ic_req = 1'b0;
		if (errors == ec)
			$display("PASS atg_su_icache.hit");
		/* conflict */
		ec = errors;
		reads = 0;
		fetch(32'h900, 0);
		fetch(32'h100, 0);
		fetch(32'h908, 0);
		if (reads != 3) begin
			$display("FAIL atg_su_icache.conflict reads %0d", reads);
			errors = errors + 1;
		end
		fetch(32'h200, 0);
		fetch(32'h90C - 4, 0);
		if (reads != 4) begin
			$display("FAIL atg_su_icache.conflict other index reads %0d", reads);
			errors = errors + 1;
		end
		if (errors == ec)
			$display("PASS atg_su_icache.conflict");
		/* inv */
		ec = errors;
		reads = 0;
		@(negedge clk);
		inv = 1'b1;
		@(negedge clk);
		inv = 1'b0;
		fetch(32'h908, 0);
		if (reads != 1) begin
			$display("FAIL atg_su_icache.inv no miss after inv");
			errors = errors + 1;
		end
		fetch(32'h400, 1);	/* inv during the fill */
		fetch(32'h408, 0);
		if (reads != 3) begin
			$display("FAIL atg_su_icache.inv fill kept after inv (reads %0d)", reads);
			errors = errors + 1;
		end
		fetch(32'h410, 0);
		if (reads != 3) begin
			$display("FAIL atg_su_icache.inv clean fill lost");
			errors = errors + 1;
		end
		fetch(32'h3008, 0);	/* error response: instruction 0 */
		if (errors == ec)
			$display("PASS atg_su_icache.inv");
		if (errors == 0)
			$display("PASS atg_su_icache");
		$finish;
	end

	initial begin
		#1000000;
		$display("FAIL atg_su_icache timeout");
		$finish;
	end
endmodule

`default_nettype wire
