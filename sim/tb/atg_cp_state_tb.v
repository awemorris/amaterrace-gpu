/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_state_tb: host and µop writes reach the RAM and st_*, the locks
 * (not open, the BLT range while the BLT is busy) refuse host writes with
 * lock_fault, a µop write wins over a host write, the CPU port reads, and
 * a replay broadcasts all 768 words in order (0x200-0x2FF included).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_state_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg alias_we = 0, uop_we = 0, open = 1, blt_busy = 0, replay = 0;
	reg [9:0] alias_idx = 0, alias_ridx = 0, uop_idx = 0, cpu_ridx = 0;
	reg [31:0] alias_wdata = 0, uop_wdata = 0;
	wire [31:0] alias_rdata, cpu_rdata, st_wdata;
	wire lock_fault, st_we, replay_busy;
	wire [9:0] st_idx;

	atg_cp_state dut (
		.clk(clk), .rst_n(rst_n),
		.alias_we(alias_we), .alias_idx(alias_idx), .alias_wdata(alias_wdata),
		.alias_ridx(alias_ridx), .alias_rdata(alias_rdata),
		.uop_we(uop_we), .uop_idx(uop_idx), .uop_wdata(uop_wdata),
		.open(open), .blt_busy(blt_busy), .lock_fault(lock_fault),
		.st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.cpu_ridx(cpu_ridx), .cpu_rdata(cpu_rdata),
		.replay(replay), .replay_busy(replay_busy)
	);

	integer errors = 0;
	integer i;
	reg [31:0] model [0:767];

	/* Every st_we is checked against the expected (index, value). */
	reg exp_we;
	reg [9:0] exp_idx;
	reg [31:0] exp_val;
	reg exp_fault;

	task check;
		input [8*40-1:0] what;
		begin
			#1;
			if (st_we !== exp_we || (exp_we && (st_idx !== exp_idx || st_wdata !== exp_val)) ||
			    lock_fault !== exp_fault) begin
				errors = errors + 1;
				$display("FAIL atg_cp_state.%0s: st_we %b %h %h fault %b", what, st_we, st_idx,
					st_wdata, lock_fault);
			end
		end
	endtask

	task host;
		input [9:0] idx;
		input [31:0] v;
		input ok;
		begin
			@(negedge clk);
			alias_we = 1;
			alias_idx = idx;
			alias_wdata = v;
			exp_we = ok;
			exp_idx = idx;
			exp_val = v;
			exp_fault = !ok;
			check("host");
			if (ok)
				model[idx] = v;
			@(negedge clk);
			alias_we = 0;
		end
	endtask

	task uop;
		input [9:0] idx;
		input [31:0] v;
		begin
			@(negedge clk);
			uop_we = 1;
			uop_idx = idx;
			uop_wdata = v;
			exp_we = 1;
			exp_idx = idx;
			exp_val = v;
			exp_fault = 0;
			check("uop");
			model[idx] = v;
			@(negedge clk);
			uop_we = 0;
		end
	endtask

	task readback;
		input [8*40-1:0] what;
		input [9:0] idx;
		begin
			@(negedge clk);
			alias_ridx = idx;
			cpu_ridx = idx;
			@(negedge clk);
			if (alias_rdata !== model[idx] || cpu_rdata !== model[idx]) begin
				errors = errors + 1;
				$display("FAIL atg_cp_state.%0s: [%h] host %h cpu %h, expected %h", what, idx,
					alias_rdata, cpu_rdata, model[idx]);
			end
		end
	endtask

	integer e0, e1;
	reg [9:0] next;
	initial begin
		repeat (3) @(posedge clk);
		rst_n = 1;
		/* write */
		for (i = 0; i < 768; i = i + 1)
			uop(i, 32'h1000 * i + 7);
		host(9'h123, 32'hCAFE0123, 1'b1);
		host(9'h01F, 32'h0000B17F, 1'b1);
		uop(9'h1E9, 32'h00000044);
		host(10'h2A5, 32'h00002A5A, 1'b1);	/* the vertex stage's texture slots */
		readback("write", 9'h123);
		readback("write", 9'h01F);
		readback("write", 9'h1E9);
		readback("write", 9'h000);
		readback("write", 10'h2A5);
		readback("write", 10'h2FF);
		if (errors == 0)
			$display("PASS atg_cp_state.write");
		e0 = errors;
		/* lock */
		open = 0;
		host(9'h100, 32'h11111111, 1'b0);
		open = 1;
		blt_busy = 1;
		host(9'h010, 32'h22222222, 1'b0);
		host(9'h020, 32'h33333333, 1'b1);
		blt_busy = 0;
		/* A µop and a host write in the same cycle: the µop wins. */
		@(negedge clk);
		uop_we = 1;
		uop_idx = 9'h050;
		uop_wdata = 32'h55555555;
		alias_we = 1;
		alias_idx = 9'h060;
		alias_wdata = 32'h66666666;
		exp_we = 1;
		exp_idx = 9'h050;
		exp_val = 32'h55555555;
		exp_fault = 1;
		check("lock");
		model[9'h050] = 32'h55555555;
		@(negedge clk);
		uop_we = 0;
		alias_we = 0;
		readback("lock", 9'h100);
		readback("lock", 9'h010);
		readback("lock", 9'h020);
		readback("lock", 9'h060);
		if (errors == e0)
			$display("PASS atg_cp_state.lock");
		e1 = errors;
		/* cpu */
		for (i = 0; i < 768; i = i + 37)
			readback("cpu", i);
		if (errors == e1)
			$display("PASS atg_cp_state.cpu");
		e1 = errors;
		/* replay: every word once, in order. */
		@(negedge clk);
		replay = 1;
		@(negedge clk);
		replay = 0;
		next = 0;
		i = 0;
		while (replay_busy && i < 900) begin
			if (st_we) begin
				if (st_idx !== next[9:0] || st_wdata !== model[next[9:0]]) begin
					errors = errors + 1;
					$display("FAIL atg_cp_state.replay: %h %h", st_idx, st_wdata);
				end
				next = next + 1;
			end
			@(negedge clk);
			i = i + 1;
		end
		if (next != 768 || i != 769) begin
			errors = errors + 1;
			$display("FAIL atg_cp_state.replay: %0d words in %0d cycles", next, i);
		end
		if (errors == e1)
			$display("PASS atg_cp_state.replay");
		if (errors == 0)
			$display("PASS atg_cp_state");
		else
			$display("FAIL atg_cp_state: %0d errors", errors);
		$finish;
	end
endmodule

`default_nettype wire
