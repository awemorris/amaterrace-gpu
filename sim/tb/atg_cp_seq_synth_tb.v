/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_seq_synth_tb: Verification of atg_cp_seq under SYNTH_KINTEX7.
 * Tests that CMD_FENCE with flags 0x4 (HOST_FLUSH) asserts f_flush and inv=4'b1111,
 * followed by CMD_FENCE with flags 0x3 (no HOST_FLUSH) which does NOT assert f_flush.
 * Verifies that exactly one flush occurs across the sequence (flags 0x4 -> flags 0x3).
 */

`timescale 1ns / 1ps
`default_nettype none

`define SYNTH_KINTEX7 1

module atg_cp_seq_synth_tb;
	reg clk = 0;
	always #5 clk = ~clk;

	reg rst_n = 0;
	reg n_valid = 0;
	wire n_ready;
	reg [31:0] n_data = 0;

	wire [1:0] u_req;
	wire [9:0] uop_idx;
	wire [31:0] uop_wdata;
	wire kick;
	wire [2:0] kick_code;
	wire [3:0] inv;
	wire f_valid;
	reg f_ready = 1'b0;
	wire [1:0] f_op;
	wire [63:0] f_addr;
	wire [31:0] f_value;
	wire [31:0] f_aux;
	wire f_irq;
	wire f_mem;
	wire f_flush;
	reg l2_flush_done = 1'b0;
	wire busy;
	wire cmd_active;
	wire [3:0] seq_st;
	wire fault;
	wire [3:0] fault_kind;
	wire [31:0] fault_addr;
	wire [7:0] fault_tag;
	wire occ_clear;

	atg_cp_seq #(.UNITS(8'hFF), .HAS_VSYNC(1), .HAS_DISP(1)) dut (
		.clk(clk), .rst_n(rst_n),
		.fw_side(7'd0), .u_fw(), .u_side(), .u_req(u_req), .u_ok(1'b1),
		.n_valid(n_valid), .n_ready(n_ready), .n_data(n_data),
		.fw_valid(1'b0), .fw_ready(), .fw_data(32'd0),
		.fw_active(1'b0), .halt(1'b0), .seq_abort(1'b0),
		.uop_we(), .uop_idx(uop_idx), .uop_wdata(uop_wdata),
		.kick(kick), .kick_code(kick_code), .inv(inv),
		.busy_in(9'd0), .vsync(1'b0), .l2_flush_done(l2_flush_done), .l2_idle(1'b1),
		.f_valid(f_valid), .f_ready(f_ready), .f_op(f_op), .f_addr(f_addr),
		.f_value(f_value), .f_aux(f_aux), .f_irq(f_irq), .f_mem(f_mem), .f_flush(f_flush),
		.f_busy(1'b0), .occ_count(40'd0), .occ_clear(occ_clear),
		.busy(busy), .cmd_active(cmd_active), .seq_st(seq_st),
		.fault(fault), .fault_kind(fault_kind), .fault_addr(fault_addr), .fault_tag(fault_tag)
	);

	integer errors = 0;
	integer flush_count = 0;
	reg f_flush_seen = 0;

	always @(posedge clk) begin
		if (f_flush && !f_flush_seen) begin
			flush_count = flush_count + 1;
			f_flush_seen <= 1'b1;
		end else if (!f_flush) begin
			f_flush_seen <= 1'b0;
		end
	end

	task send_word;
		input [31:0] d;
		begin
			@(posedge clk);
			n_valid <= 1'b1;
			n_data <= d;
			@(posedge clk);
			while (!n_ready)
				@(posedge clk);
			n_valid <= 1'b0;
		end
	endtask

	task send_fence;
		input [31:0] flags_val;
		begin
			send_word({16'd0, 8'd6, 8'h33}); /* CMD_FENCE len=6 */
			send_word(32'h00008000);          /* addr_lo */
			send_word(32'h00000000);          /* addr_hi */
			send_word(32'hAABB0001);          /* seq_lo */
			send_word(32'h00000000);          /* seq_hi */
			send_word(flags_val);             /* flags */
		end
	endtask

	initial begin
		rst_n = 0;
		n_valid = 0;
		f_ready = 0;
		l2_flush_done = 0;
		repeat (10) @(posedge clk);
		rst_n = 1;
		repeat (5) @(posedge clk);

		$display("=== atg_cp_seq_synth_tb: Testing SYNTH_KINTEX7 path ===");

		/* 1. Send CMD_FENCE with flags = 0x4 (HOST_FLUSH bit 2 = 1) */
		$display("--- Step 1: CMD_FENCE flags=0x4 (HOST_FLUSH) ---");
		send_fence(32'h00000004);

		/* Wait for Q_FLUSH (st == 11) and f_flush == 1 */
		while (!f_flush)
			@(posedge clk);

		if (!f_flush) begin
			errors = errors + 1;
			$display("FAIL flags=0x4 did not assert f_flush");
		end else begin
			$display("PASS flags=0x4 asserted f_flush (st=%0d)", seq_st);
		end

		/* Hold in Q_FLUSH for 5 cycles, verify f_flush stays high */
		repeat (5) @(posedge clk);
		if (!f_flush) begin
			errors = errors + 1;
			$display("FAIL f_flush dropped prematurely during Q_FLUSH");
		end

		/* Assert l2_flush_done to complete flush */
		@(posedge clk);
		l2_flush_done <= 1'b1;
		@(posedge clk);
		l2_flush_done <= 1'b0;

		/* Wait for Q_FREQ (f_valid == 1) */
		while (!f_valid)
			@(posedge clk);

		/* Handshake fence completion */
		f_ready <= 1'b1;
		@(posedge clk);
		f_ready <= 1'b0;

		/* Wait for IDLE */
		while (seq_st != 4'd0)
			@(posedge clk);

		if (flush_count !== 1) begin
			errors = errors + 1;
			$display("FAIL after flags=0x4, flush_count=%0d, expected 1", flush_count);
		end else begin
			$display("PASS flags=0x4 triggered exactly 1 flush");
		end

		/* 2. Send CMD_FENCE with flags = 0x3 (no HOST_FLUSH, bit 2 = 0) */
		$display("--- Step 2: CMD_FENCE flags=0x3 (no HOST_FLUSH) ---");
		send_fence(32'h00000003);

		/* Wait for Q_FREQ (f_valid == 1) */
		while (!f_valid) begin
			if (f_flush) begin
				errors = errors + 1;
				$display("FAIL flags=0x3 unexpectedly asserted f_flush!");
			end
			@(posedge clk);
		end

		/* Handshake fence completion */
		f_ready <= 1'b1;
		@(posedge clk);
		f_ready <= 1'b0;

		/* Wait for IDLE */
		while (seq_st != 4'd0)
			@(posedge clk);

		repeat (10) @(posedge clk);

		if (flush_count !== 1) begin
			errors = errors + 1;
			$display("FAIL across flags 0x4 -> flags 0x3, flush_count=%0d, expected 1", flush_count);
		end else begin
			$display("PASS flags 0x4 -> flags 0x3 sequence triggered exactly 1 flush total");
		end

		if (errors == 0)
			$display("PASS atg_cp_seq_synth");
		else
			$display("FAIL atg_cp_seq_synth: %0d errors", errors);

		$finish;
	end

endmodule
