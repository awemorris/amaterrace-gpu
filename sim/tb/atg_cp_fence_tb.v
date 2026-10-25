/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_fence_tb: the fence unit against amb_mem: FENCE writes its word
 * and only then updates FENCE_LAST and (with f_irq) pulses ev_fence;
 * RESULT writes its two words; WAIT_FENCE polls until the memory word has
 * passed the value, across the 32-bit wrap; an error response is a fault
 * of kind 1 with the address; the host writes FENCE_LAST.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_fence_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg hcr_we = 0;
	reg [9:0] hcr_widx = 0, hcr_ridx = 0;
	reg [31:0] hcr_wdata = 0, hcr_wmask = 0;
	wire [31:0] hcr_rdata;
	reg f_valid = 0, f_irq = 0;
	reg [1:0] f_op = 0;
	reg [31:0] f_addr = 0, f_value = 0, f_aux = 0;
	wire f_ready, f_busy, ev_fence, fault;
	wire [31:0] fence_last, fault_addr;
	wire [3:0] fault_kind;
	wire [7:0] fault_tag;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;

	atg_cp_fence #(.POLL(16)) dut (
		.clk(clk), .rst_n(rst_n),
		.f_chk(1'b1), .f_slot(6'd9), .req_chk(req_chk), .req_slot(req_slot),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx), .hcr_rdata(hcr_rdata),
		.f_valid(f_valid), .f_ready(f_ready), .f_op(f_op), .f_addr(f_addr),
		.f_value(f_value), .f_aux(f_aux), .f_irq(f_irq), .f_busy(f_busy),
		.ev_fence(ev_fence), .fence_last(fence_last),
		.fault(fault), .fault_kind(fault_kind), .fault_addr(fault_addr), .fault_tag(fault_tag),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	amb_mem #(.MEM_WORDS(4096), .ERR_BASE(32'h00008000), .SEED(9)) mem (
		.clk(clk), .rst_n(rst_n),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	`include "hcr_snoop.vh"

	integer errors = 0;
	integer fences = 0, faults = 0, reads = 0;
	integer e0, i;
	reg [31:0] v;

	/* Session protection: the request's side band goes with its memory requests. */
	wire req_chk;
	wire [5:0] req_slot;
	always @(posedge clk)
		if (req_valid && (req_chk !== 1'b1 || req_slot !== 6'd9)) begin
			errors = errors + 1;
			$display("FAIL atg_cp_fence: protection side %b %0d", req_chk, req_slot);
		end

	always @(posedge clk) begin
		if (ev_fence) begin
			fences = fences + 1;
			/* The word is in memory before the event. */
			if (mem.peek(f_addr) !== fence_last && mem.peek(f_addr) !== f_value) begin
				errors = errors + 1;
				$display("FAIL atg_cp_fence.fence: event before the word");
			end
		end
		if (fault)
			faults = faults + 1;
		if (req_valid && req_ready && !req_write)
			reads = reads + 1;
	end

	task request;
		input [1:0] op;
		input [31:0] addr;
		input [31:0] value;
		input [31:0] aux;
		input irq;
		begin
			@(negedge clk);
			f_valid = 1;
			f_op = op;
			f_addr = addr;
			f_value = value;
			f_aux = aux;
			f_irq = irq;
			#1;
			while (!f_ready) begin
				@(negedge clk);
				#1;
			end
			@(negedge clk);
			f_valid = 0;
		end
	endtask

	task wait_done;
		integer n;
		begin
			n = 0;
			while (f_busy && n < 2000) begin
				@(negedge clk);
				n = n + 1;
			end
			if (f_busy) begin
				errors = errors + 1;
				$display("FAIL atg_cp_fence: stays busy");
			end
		end
	endtask

	task expect_eq;
		input [8*40-1:0] what;
		input [31:0] got;
		input [31:0] want;
		if (got !== want) begin
			errors = errors + 1;
			$display("FAIL atg_cp_fence.%0s: %h, expected %h", what, got, want);
		end
	endtask

	initial begin
		for (i = 0; i < 64; i = i + 1)
			mem.poke(i * 4, 32'h77000000 + i);
		repeat (3) @(posedge clk);
		rst_n = 1;
		/* fence */
		request(2'd0, 32'h0000004C, 32'h00000101, 32'h0, 1'b0);
		expect_eq("fence busy", {31'd0, f_busy}, 32'd1);
		wait_done();
		expect_eq("fence word", mem.peek(32'h4C), 32'h101);
		expect_eq("fence neighbours", mem.peek(32'h48), 32'h77000012);
		expect_eq("fence neighbours", mem.peek(32'h50), 32'h77000014);
		expect_eq("FENCE_LAST", fence_last, 32'h101);
		expect_eq("no event without f_irq", fences, 0);
		request(2'd0, 32'h00000044, 32'h00000102, 32'h0, 1'b1);
		wait_done();
		@(negedge clk);
		expect_eq("event", fences, 1);
		hcr_read(GHCI_FENCE_LAST[11:0], v);
		expect_eq("FENCE_LAST read", v, 32'h102);
		hcr_write(GHCI_FENCE_LAST[11:0], 32'h00000100);
		expect_eq("FENCE_LAST host write", fence_last, 32'h100);
		if (errors == 0)
			$display("PASS atg_cp_fence.fence");
		e0 = errors;
		/* result */
		request(2'd1, 32'h00000068, 32'h5A5A0001, 32'hC3C30002, 1'b1);
		wait_done();
		expect_eq("result status", mem.peek(32'h68), 32'h5A5A0001);
		expect_eq("result aux", mem.peek(32'h6C), 32'hC3C30002);
		expect_eq("result neighbours", mem.peek(32'h64), 32'h77000019);
		expect_eq("result neighbours", mem.peek(32'h70), 32'h7700001C);
		expect_eq("result: no fence event", fences, 1);
		if (errors == e0)
			$display("PASS atg_cp_fence.result");
		e0 = errors;
		/* wait: 0xFFFFFFF0 has not passed 5; 6 has (across the wrap). */
		mem.poke(32'h80, 32'hFFFFFFF0);
		reads = 0;
		request(2'd2, 32'h00000080, 32'h00000005, 32'h0, 1'b0);
		repeat (200) @(negedge clk);
		expect_eq("wait busy", {31'd0, f_busy}, 32'd1);
		if (reads < 3) begin
			errors = errors + 1;
			$display("FAIL atg_cp_fence.wait: %0d polls", reads);
		end
		mem.poke(32'h80, 32'h00000006);
		wait_done();
		expect_eq("wait: no write", mem.writes, 3);
		/* A value already passed: one read. */
		reads = 0;
		request(2'd2, 32'h00000080, 32'h80000007, 32'h0, 1'b0);
		wait_done();
		expect_eq("wait passed", reads, 1);
		if (errors == e0)
			$display("PASS atg_cp_fence.wait");
		e0 = errors;
		/* error */
		request(2'd0, 32'h00009004, 32'h00000200, 32'h0, 1'b1);
		wait_done();
		repeat (20) @(negedge clk);
		expect_eq("error fault", faults, 1);
		expect_eq("error kind", {28'd0, fault_kind}, {28'd0, GHCI_FAULT_APERTURE});
		expect_eq("error addr", fault_addr, 32'h00009004);
		expect_eq("error: FENCE_LAST kept", fence_last, 32'h100);
		expect_eq("error: no event", fences, 1);
		expect_eq("error: stopped", {31'd0, f_ready}, 32'd0);
		if (errors == e0)
			$display("PASS atg_cp_fence.error");
		if (errors == 0)
			$display("PASS atg_cp_fence");
		else
			$display("FAIL atg_cp_fence: %0d errors", errors);
		$finish;
	end
endmodule

`default_nettype wire
