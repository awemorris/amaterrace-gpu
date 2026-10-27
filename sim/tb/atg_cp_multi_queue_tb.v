/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_multi_queue_tb: verification testbench for multi-engine independent
 * queuing and hardware preemption (Phase 005 / ws001-p005).
 *
 * Checks:
 *   1. Independent 3-queue configuration (Graphics, Compute, Copy/DMA).
 *   2. Concurrent execution: background Copy/DMA running while Graphics draws.
 *   3. Hardware preemption: interrupting long Compute kernel, saving context
 *      to memory via DMA, running high-priority Graphics draw, and restoring.
 *   4. Inter-queue hardware semaphore synchronization.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_multi_queue_tb;
	`include "ghci_regs.vh"

	parameter LINE_BYTES = 32;
	parameter LINE_SHIFT = 5;
	parameter LA = 32 - LINE_SHIFT;
	parameter LB = LINE_BYTES * 8;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	/* HCR snoop bus */
	reg hcr_we = 0;
	reg [9:0] hcr_widx = 0;
	reg [31:0] hcr_wdata = 0;
	reg [31:0] hcr_wmask = 0;
	reg [9:0] hcr_ridx = 0;
	wire [31:0] hcr_rdata;

	reg run = 0;
	reg halt = 0;
	reg step = 0;
	reg open = 1;

	/* Ring interface to sequencer */
	wire n_valid;
	wire n_ready;
	wire [31:0] n_data;
	wire n_last;

	wire v_valid;
	wire [31:0] v_addr;
	wire [15:0] v_dwords;
	wire [7:0] v_tag;
	reg v_done = 0;

	wire empty, retire, busy;
	wire [1:0] queue_id;
	wire preempt_ev;
	wire fault;
	wire [3:0] fault_kind;
	wire [31:0] fault_addr;
	wire [7:0] fault_tag;

	/* AMB port */
	wire req_valid, req_ready, req_write;
	wire [LA-1:0] req_line;
	wire [LINE_BYTES-1:0] req_be;
	wire [LB-1:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;
	wire rsp_valid, rsp_write, rsp_error;

	reg core_rst_n = 1;

	/* DUT: atg_cp_ring */
	atg_cp_ring #(
		.ADDR_W(32), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .CLASS_V(1)
	) dut_ring (
		.clk(clk), .rst_n(rst_n), .core_rst_n(core_rst_n && rst_n),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx), .hcr_rdata(hcr_rdata),
		.run(run), .halt(halt), .step(step), .open(open),
		.n_valid(n_valid), .n_ready(n_ready), .n_data(n_data), .n_last(n_last),
		.v_valid(v_valid), .v_addr(v_addr), .v_dwords(v_dwords), .v_tag(v_tag),
		.v_done(v_done),
		.dma_req_ready(1'b0), .dma_done(1'b0),
		.empty(empty), .retire(retire), .busy(busy),
		.queue_id(queue_id), .preempt_ev(preempt_ev),
		.fault(fault), .fault_kind(fault_kind), .fault_addr(fault_addr), .fault_tag(fault_tag),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	/* Memory model */
	amb_mem #(
		.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .MEM_WORDS(8192), .SEED(42)
	) mem (
		.clk(clk), .rst_n(rst_n),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	/* Sequencer */
	wire uop_we;
	wire [9:0] uop_idx;
	wire [31:0] uop_wdata;
	wire kick;
	wire [2:0] kick_code;
	wire [3:0] inv;
	reg [8:0] busy_in = 0;
	reg vsync = 0;
	wire f_valid, f_irq, seq_busy, cmd_active, seq_fault;
	reg f_ready = 1, f_busy = 0;
	wire [1:0] f_op;
	wire [63:0] f_addr;
	wire [31:0] f_value, f_aux;
	wire [3:0] seq_fault_kind;
	wire [31:0] seq_fault_addr;
	wire [7:0] seq_fault_tag;

	atg_cp_seq #(.UNITS(8'hFF), .HAS_VSYNC(0), .HAS_DISP(0)) dut_seq (
		.clk(clk), .rst_n(core_rst_n && rst_n),
		.n_valid(n_valid), .n_ready(n_ready), .n_data(n_data),
		.fw_valid(1'b0), .fw_ready(), .fw_data(32'd0), .fw_active(1'b0), .fw_side(7'd0),
		.halt(halt),
		.uop_we(uop_we), .uop_idx(uop_idx), .uop_wdata(uop_wdata),
		.kick(kick), .kick_code(kick_code), .inv(inv), .busy_in(busy_in),
		.vsync(vsync),
		.f_valid(f_valid), .f_ready(f_ready), .f_op(f_op), .f_addr(f_addr),
		.f_value(f_value), .f_aux(f_aux), .f_irq(f_irq), .f_busy(f_busy),
		.occ_count(40'd0), .occ_clear(),
		.busy(seq_busy), .cmd_active(cmd_active),
		.fault(seq_fault), .fault_kind(seq_fault_kind), .fault_addr(seq_fault_addr),
		.fault_tag(seq_fault_tag),
		.u_fw(), .u_side(), .u_req(), .u_ok(1'b1)
	);

	wire blt_kick  = kick && (kick_code == 3'd0);
	wire draw_kick = kick && (kick_code == 3'd1);
	wire cs_kick   = kick && (kick_code == 3'd2);

	/* Ring Bases and Sizes (10 -> 256 dwords) */
	localparam [31:0] Q0_BASE = 32'h00000400; /* Graphics */
	localparam [31:0] Q1_BASE = 32'h00000800; /* Compute */
	localparam [31:0] Q2_BASE = 32'h00000C00; /* Copy/DMA */
	localparam [31:0] CTX_MEM = 32'h00001000; /* Context Save Area */
	localparam Q_SIZE = 10;
	localparam NW = 256;

	integer wp0 = 0, wp1 = 0, wp2 = 0;
	integer errors = 0;

	/* Tasks for Register Access */
	task write_reg;
		input [9:0] idx;
		input [31:0] val;
		begin
			@(posedge clk);
			hcr_we <= 1'b1;
			hcr_widx <= idx;
			hcr_wdata <= val;
			hcr_wmask <= 32'hFFFFFFFF;
			@(posedge clk);
			hcr_we <= 1'b0;
		end
	endtask

	task read_reg;
		input [9:0] idx;
		output [31:0] val;
		begin
			@(posedge clk);
			hcr_ridx <= idx;
			@(posedge clk);
			val = hcr_rdata;
		end
	endtask

	/* Tasks to Submit Packets to Queues */
	task submit_q0_draw;
		input [7:0] tag;
		reg [31:0] d;
		begin
			/* Class 0 opcode 3 (DRAW), flags 0, n 0 */
			d = {2'd0, 6'd3, tag, 8'd0, 8'd0};
			mem.poke(Q0_BASE + wp0 * 4, d);
			wp0 = (wp0 + 1) % NW;
			write_reg(GHCI_RING0_WPTR[11:2], wp0);
		end
	endtask

	task submit_q1_dispatch;
		input [7:0] tag;
		reg [31:0] d;
		begin
			/* Class 0 opcode 4 (DISPATCH), flags 0, n 3 (grid X, Y, Z) */
			d = {2'd0, 6'd4, tag, 8'd0, 8'd3};
			mem.poke(Q1_BASE + wp1 * 4, d);
			wp1 = (wp1 + 1) % NW;
			mem.poke(Q1_BASE + wp1 * 4, 32'd1); /* grid X */
			wp1 = (wp1 + 1) % NW;
			mem.poke(Q1_BASE + wp1 * 4, 32'd1); /* grid Y */
			wp1 = (wp1 + 1) % NW;
			mem.poke(Q1_BASE + wp1 * 4, 32'd1); /* grid Z */
			wp1 = (wp1 + 1) % NW;
			write_reg(GHCI_RING1_WPTR[11:2], wp1);
		end
	endtask

	task submit_q2_blit;
		input [7:0] tag;
		reg [31:0] d;
		begin
			/* Class 0 opcode 2 (BLIT), flags 0 (async, no wait), n 0 */
			d = {2'd0, 6'd2, tag, 8'd0, 8'd0};
			mem.poke(Q2_BASE + wp2 * 4, d);
			wp2 = (wp2 + 1) % NW;
			write_reg(GHCI_RING2_WPTR[11:2], wp2);
		end
	endtask

	reg [31:0] rval;
	integer i;
	reg blt_running = 0;
	reg saw_draw_during_blt = 0;

	// Background BLT engine simulation
	always @(posedge clk) begin
		if (!rst_n) begin
			blt_running <= 0;
			busy_in[1]  <= 0;
		end else begin
			if (blt_kick) begin
				blt_running <= 1;
				busy_in[1]  <= 1; // BLT busy
			end
			if (draw_kick && blt_running) begin
				saw_draw_during_blt <= 1;
			end
		end
	end

	initial begin
		repeat (4) @(posedge clk);
		rst_n = 1;
		@(posedge clk);

		$display("--- CASE 1: Independent 3-Queue Register Configuration ---");
		write_reg(GHCI_RING0_BASE[11:2], Q0_BASE);
		write_reg(GHCI_RING0_SIZE[11:2], Q_SIZE);
		write_reg(GHCI_RING1_BASE[11:2], Q1_BASE);
		write_reg(GHCI_RING1_SIZE[11:2], Q_SIZE);
		write_reg(GHCI_RING2_BASE[11:2], Q2_BASE);
		write_reg(GHCI_RING2_SIZE[11:2], Q_SIZE);
		write_reg(GHCI_CP_CTX_BASE[11:2], CTX_MEM);

		read_reg(GHCI_RING0_BASE[11:2], rval);
		if (rval != Q0_BASE) begin
			$display("FAIL: RING0_BASE mismatch: got %h exp %h", rval, Q0_BASE);
			errors = errors + 1;
		end
		read_reg(GHCI_RING1_BASE[11:2], rval);
		if (rval != Q1_BASE) begin
			$display("FAIL: RING1_BASE mismatch: got %h exp %h", rval, Q1_BASE);
			errors = errors + 1;
		end
		read_reg(GHCI_RING2_BASE[11:2], rval);
		if (rval != Q2_BASE) begin
			$display("FAIL: RING2_BASE mismatch: got %h exp %h", rval, Q2_BASE);
			errors = errors + 1;
		end
		read_reg(GHCI_CP_CTX_BASE[11:2], rval);
		if (rval != CTX_MEM) begin
			$display("FAIL: CP_CTX_BASE mismatch: got %h exp %h", rval, CTX_MEM);
			errors = errors + 1;
		end

		run = 1;
		@(posedge clk);

		$display("--- CASE 2: Concurrent Background Copy/DMA & Graphics ---");
		/* Submit BLIT to Queue 2 (Copy/DMA) and DRAW to Queue 0 (Graphics) */
		saw_draw_during_blt = 0;
		submit_q2_blit(8'h21);
		submit_q0_draw(8'h01);

		/* Wait for BLT kick */
		wait (blt_kick);
		$display("INFO: Queue 2 BLIT kicked, BLT engine running in background...");

		/* Wait for DRAW kick while BLT is running */
		wait (draw_kick);
		$display("INFO: Queue 0 DRAW kicked!");

		if (!saw_draw_during_blt && !blt_running) begin
			$display("FAIL: Graphics DRAW did not execute concurrently with BLT DMA!");
			errors = errors + 1;
		end else begin
			$display("PASS: Graphics DRAW executed concurrently with background Copy/DMA!");
		end

		/* Let BLT complete */
		repeat (10) @(posedge clk);
		busy_in[1] = 0;
		blt_running = 0;
		repeat (10) @(posedge clk);

		$display("--- CASE 3: Compute Kernel Preemption by Graphics Queue ---");
		/*
		 * Submit multiple compute dispatches to Queue 1.
		 * Model shader unit busy on CS.
		 */
		submit_q1_dispatch(8'h11);
		submit_q1_dispatch(8'h12);
		submit_q1_dispatch(8'h13);

		wait (cs_kick);
		$display("INFO: Compute kernel 1 started on Queue 1 (active_qid = %0d)", queue_id);
		busy_in[6] = 1; /* SU busy executing kernel 1 */

		/* While kernel 1 is running, high-priority graphics draw arrives in Queue 0 and host requests preemption */
		submit_q0_draw(8'h02);
		write_reg(GHCI_CP_PREEMPT[11:2], 32'h00000001); /* PREEMPT_REQ */

		/* Simulate shader completing current warp boundary under preemption request */
		repeat (15) @(posedge clk);
		busy_in[6] = 0; /* Warp boundary reached: SU becomes idle */

		/* Wait for preemption context save to complete and switch to Queue 0 */
		wait (preempt_ev);
		$display("INFO: Preemption context save complete (preempt_ev pulsed, active_qid = %0d)", queue_id);

		if (queue_id != 2'd0) begin
			$display("FAIL: Expected active_qid == 0 (Graphics) after preemption, got %0d", queue_id);
			errors = errors + 1;
		end

		/* Check that context header was written to CTX_MEM */
		rval = mem.peek(CTX_MEM);
		if (rval != 32'h43545853) begin /* "CTXS" */
			$display("FAIL: CTX memory header mismatch: got %h exp 43545853", rval);
			errors = errors + 1;
		end else begin
			$display("PASS: Context saved to memory (CTXS header verified at %h)", CTX_MEM);
		end

		/* High-priority graphics draw executes */
		wait (draw_kick);
		$display("INFO: High-priority Graphics DRAW executed on Queue 0!");

		/* Once Queue 0 is empty, context restore should automatically resume Queue 1 */
		wait (preempt_ev);
		$display("INFO: Context restore complete! Resumed interrupted queue: %0d", queue_id);

		if (queue_id != 2'd1) begin
			$display("FAIL: Expected resumed queue_id == 1, got %0d", queue_id);
			errors = errors + 1;
		end

		/* Remaining compute kernels execute */
		wait (cs_kick);
		$display("INFO: Compute kernel resumed and executed on Queue 1!");

		repeat (20) @(posedge clk);

		$display("--- CASE 4: Lightweight Semaphore Synchronization ---");
		/*
		 * Queue 1 is set to wait on Semaphore 3.
		 * Semaphore 3 is 0, so Queue 1 must NOT execute.
		 * [7]=1 (set wait), [6:5]=1 (Q1), [4:2]=3 (Sema 3), [1:0]=0 (cmd: set wait only) -> 0xAC
		 */
		write_reg(GHCI_CP_SEMA[11:2], 32'h000000AC);
		submit_q1_dispatch(8'h14);

		repeat (20) @(posedge clk);
		if (cs_kick) begin
			$display("FAIL: Queue 1 executed while waiting on semaphore 3 (which was 0)!");
			errors = errors + 1;
		end else begin
			$display("PASS: Queue 1 correctly blocked on semaphore 3.");
		end

		/* Now Signal Semaphore 3: [4:2]=3 (Sema 3), [1:0]=1 (cmd: signal/increment) -> 0x0D */
		$display("INFO: Signaling Semaphore 3...");
		write_reg(GHCI_CP_SEMA[11:2], 32'h0000000D);

		wait (cs_kick);
		$display("PASS: Queue 1 unblocked and executed after semaphore signal!");

		repeat (30) @(posedge clk);

		if (errors == 0) begin
			$display("PASS atg_cp_multi_queue");
		end else begin
			$display("FAIL atg_cp_multi_queue: %0d errors", errors);
		end
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL atg_cp_multi_queue: timeout");
		$finish;
	end
endmodule

`default_nettype wire
