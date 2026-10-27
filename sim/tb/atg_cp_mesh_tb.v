/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_mesh_tb: Unit test for CP CMD_DRAW_MESH_TASKS (0x2A) command
 * decoding, payload dispatch to STATE/GRID registers, dependency tracking,
 * and mesh shader workgroup kick (Phase 003, ws004-p003).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_mesh_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	integer errors = 0;

	/* Ring FIFO */
	reg [31:0] fifo_mem [0:63];
	integer fifo_head = 0, fifo_tail = 0;

	wire n_valid = fifo_head != fifo_tail;
	wire [31:0] n_data = fifo_mem[fifo_head % 64];
	wire n_ready;

	always @(posedge clk) begin
		if (n_valid && n_ready)
			fifo_head <= fifo_head + 1;
	end

	task push_word(input [31:0] w);
		begin
			fifo_mem[fifo_tail % 64] = w;
			fifo_tail = fifo_tail + 1;
		end
	endtask

	wire uop_we, kick;
	wire [2:0] kick_code;
	wire [9:0] uop_idx;
	wire [31:0] uop_wdata;
	wire [3:0] inv;
	reg [8:0] busy_in = 9'd0;
	wire [1:0] u_req;
	wire busy, cmd_active, fault;

	atg_cp_seq #(.UNITS(8'hFF), .HAS_VSYNC(1), .HAS_DISP(1)) dut (
		.clk(clk), .rst_n(rst_n),
		.fw_side(7'd0), .u_fw(), .u_side(), .u_req(u_req), .u_ok(1'b1),
		.n_valid(n_valid), .n_ready(n_ready), .n_data(n_data),
		.fw_valid(1'b0), .fw_ready(), .fw_data(32'd0),
		.fw_active(1'b0), .halt(1'b0),
		.uop_we(uop_we), .uop_idx(uop_idx), .uop_wdata(uop_wdata),
		.kick(kick), .kick_code(kick_code), .inv(inv), .busy_in(busy_in),
		.vsync(1'b0),
		.f_valid(), .f_ready(1'b1), .f_op(), .f_addr(), .f_value(),
		.f_aux(), .f_irq(), .f_busy(1'b0),
		.occ_count(40'd0), .occ_clear(),
		.busy(busy), .cmd_active(cmd_active),
		.fault(fault), .fault_kind(), .fault_addr(), .fault_tag()
	);

	reg saw_grid_x = 0, saw_grid_y = 0, saw_grid_z = 0;
	reg saw_cs_kick = 0, saw_inv = 0;

	always @(posedge clk) begin
		if (uop_we) begin
			if (uop_idx == {1'b0, GHCI_S_GRID_X} && uop_wdata == 32'd12)
				saw_grid_x <= 1;
			if (uop_idx == {1'b0, GHCI_S_GRID_Y} && uop_wdata == 32'd4)
				saw_grid_y <= 1;
			if (uop_idx == {1'b0, GHCI_S_GRID_Z} && uop_wdata == 32'd1)
				saw_grid_z <= 1;
		end
		if (kick && kick_code == 3'd2)
			saw_cs_kick <= 1;
		if (inv == 4'b0011)
			saw_inv <= 1;
	end

	initial begin
		#100000;
		$display("FAIL atg_cp_mesh timeout");
		$finish;
	end

	initial begin
		rst_n = 1'b0;
		#20;
		rst_n = 1'b1;
		#20;

		$display("--- Test 1: Send CMD_DRAW_MESH_TASKS (0x2A, count 12x4x1) ---");
		/* Header: size 4 dwords, opcode 0x2A (GHCI2 Structured Command) */
		push_word(32'h0000_042a);
		push_word(32'd12);	/* groupCountX */
		push_word(32'd4);	/* groupCountY */
		push_word(32'd1);	/* groupCountZ */

		/* Wait for execution and kick */
		repeat (20) @(posedge clk);

		if (!saw_grid_x) begin
			$display("FAIL: GRID_X not updated to 12");
			errors = errors + 1;
		end else begin
			$display("PASS: GRID_X correctly updated to 12");
		end

		if (!saw_grid_y) begin
			$display("FAIL: GRID_Y not updated to 4");
			errors = errors + 1;
		end else begin
			$display("PASS: GRID_Y correctly updated to 4");
		end

		if (!saw_grid_z) begin
			$display("FAIL: GRID_Z not updated to 1");
			errors = errors + 1;
		end else begin
			$display("PASS: GRID_Z correctly updated to 1");
		end

		if (!saw_cs_kick) begin
			$display("FAIL: Compute/Mesh kick (kick_code=2) not asserted");
			errors = errors + 1;
		end else begin
			$display("PASS: Compute/Mesh kick correctly asserted");
		end

		if (!saw_inv) begin
			$display("FAIL: Pipeline cache invalidate (inv=0011) not asserted");
			errors = errors + 1;
		end else begin
			$display("PASS: Pipeline cache invalidate correctly asserted");
		end

		$display("--- Test 2: Verify SU Busy Pre-Dependency Hold ---");
		saw_cs_kick = 0;
		busy_in[6] = 1'b1;	/* SU busy */
		push_word(32'h0000_042a);
		push_word(32'd1);
		push_word(32'd1);
		push_word(32'd1);

		/* Wait 15 cycles while SU is busy */
		repeat (15) @(posedge clk);
		if (saw_cs_kick) begin
			$display("FAIL: Kick fired while SU was busy!");
			errors = errors + 1;
		end else begin
			$display("PASS: Kick held while SU was busy");
		end

		/* Release SU */
		busy_in[6] = 1'b0;
		repeat (15) @(posedge clk);
		if (!saw_cs_kick) begin
			$display("FAIL: Kick did not fire after SU became idle");
			errors = errors + 1;
		end else begin
			$display("PASS: Kick fired after SU became idle");
		end

		if (errors == 0) begin
			$display("PASS atg_cp_mesh");
		end else begin
			$display("FAIL atg_cp_mesh: %0d errors", errors);
		end
		$finish;
	end
endmodule

`default_nettype wire
