/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mmu_tb: unit testbench for Autonomous GPU MMU (atg_mmu).
 *
 * Tests:
 * 1. In-flight transaction counter.
 * 2. Hardware Page Table Walker 2-level lookup (PDE -> PTE) and L1/L2 refills.
 * 3. 1-cycle L1 TLB hits.
 * 4. Shared L2 TLB hits across different clients.
 * 5. FAULT_GPU_PAGE_FAULT (9) on unmapped PDE / PTE.
 * 6. FAULT_GPU_PERM_VIOLATION (10) on read/write permission violations.
 * 7. Invalidation / Flush of per-session TLBs via CP registers.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mmu_tb;
	parameter NUM_CLIENTS = 5;
	parameter MAX_SESSIONS = 16;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	/* Client signals */
	reg  [NUM_CLIENTS-1:0]    client_req_valid;
	reg  [NUM_CLIENTS*4-1:0]  client_req_session;
	reg  [NUM_CLIENTS*32-1:0] client_req_va;
	reg  [NUM_CLIENTS*2-1:0]  client_req_type;
	wire [NUM_CLIENTS-1:0]    client_ack;
	wire [NUM_CLIENTS*32-1:0] client_pa;
	wire [NUM_CLIENTS*6-1:0]  client_flags;
	wire [NUM_CLIENTS-1:0]    client_fault;

	/* In-flight */
	reg mem_req_fire;
	reg mem_rsp_fire;
	wire [15:0] inflight_count;

	/* CP Register Interface */
	reg        cp_pt_root_we;
	reg [3:0]  cp_pt_root_session;
	reg [19:0] cp_pt_root_base;
	reg        cp_flush_trigger;
	reg        cp_flush_all;
	reg [3:0]  cp_flush_session;

	/* Fault reporting */
	wire        fault_valid;
	wire [3:0]  fault_kind;
	wire [3:0]  fault_session;
	wire [2:0]  fault_client;
	wire [31:0] fault_addr;

	/* Walker Memory Master */
	wire        walker_mem_req_valid;
	wire [31:0] walker_mem_req_addr;
	reg         walker_mem_req_ready;
	reg         walker_mem_rsp_valid;
	reg [63:0]  walker_mem_rsp_data;

	atg_mmu #(
		.NUM_CLIENTS(NUM_CLIENTS),
		.MAX_SESSIONS(MAX_SESSIONS)
	) dut (
		.clk(clk),
		.rst_n(rst_n),
		.client_req_valid(client_req_valid),
		.client_req_session(client_req_session),
		.client_req_va(client_req_va),
		.client_req_type(client_req_type),
		.client_ack(client_ack),
		.client_pa(client_pa),
		.client_flags(client_flags),
		.client_fault(client_fault),
		.mem_req_fire(mem_req_fire),
		.mem_rsp_fire(mem_rsp_fire),
		.inflight_count(inflight_count),
		.cp_pt_root_we(cp_pt_root_we),
		.cp_pt_root_session(cp_pt_root_session),
		.cp_pt_root_base(cp_pt_root_base),
		.cp_flush_trigger(cp_flush_trigger),
		.cp_flush_all(cp_flush_all),
		.cp_flush_session(cp_flush_session),
		.fault_valid(fault_valid),
		.fault_kind(fault_kind),
		.fault_session(fault_session),
		.fault_client(fault_client),
		.fault_addr(fault_addr),
		.walker_mem_req_valid(walker_mem_req_valid),
		.walker_mem_req_addr(walker_mem_req_addr),
		.walker_mem_req_ready(walker_mem_req_ready),
		.walker_mem_rsp_valid(walker_mem_rsp_valid),
		.walker_mem_rsp_data(walker_mem_rsp_data)
	);

	/* Simulated memory array for Page Tables (64K words = 256 KiB) */
	reg [31:0] sim_mem [0:65535];

	always @(posedge clk) begin
		walker_mem_req_ready <= 1'b1;
		walker_mem_rsp_valid <= 1'b0;
		if (!rst_n) begin
			walker_mem_rsp_valid <= 1'b0;
			walker_mem_rsp_data  <= 64'd0;
		end else if (walker_mem_req_valid && walker_mem_req_ready) begin
			walker_mem_rsp_valid <= 1'b1;
			walker_mem_rsp_data  <= {32'd0, sim_mem[walker_mem_req_addr[17:2]]};
		end
	end

	integer errors;
	integer timeout;
	integer m;

	initial begin
		errors = 0;
		client_req_valid   = {NUM_CLIENTS{1'b0}};
		client_req_session = {(NUM_CLIENTS*4){1'b0}};
		client_req_va      = {(NUM_CLIENTS*32){1'b0}};
		client_req_type    = {(NUM_CLIENTS*2){1'b0}};
		mem_req_fire       = 1'b0;
		mem_rsp_fire       = 1'b0;
		cp_pt_root_we      = 1'b0;
		cp_pt_root_session = 4'd0;
		cp_pt_root_base    = 20'd0;
		cp_flush_trigger   = 1'b0;
		cp_flush_all       = 1'b0;
		cp_flush_session   = 4'd0;

		for (m = 0; m < 65536; m = m + 1)
			sim_mem[m] = 32'd0;

		/* Reset */
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		repeat (2) @(posedge clk);

		/* -----------------------------------------------------------------
		 * 1. In-flight Counter Test
		 * ----------------------------------------------------------------- */
		if (inflight_count != 16'd0) begin
			$display("FAIL atg_mmu.inflight: initial non-zero (%0d)", inflight_count);
			errors = errors + 1;
		end

		@(posedge clk); #1 mem_req_fire = 1'b1;
		@(posedge clk); #1 mem_req_fire = 1'b1;
		@(posedge clk); #1 mem_req_fire = 1'b0;
		@(posedge clk); #1;
		if (inflight_count != 16'd2) begin
			$display("FAIL atg_mmu.inflight: expected 2, got %0d", inflight_count);
			errors = errors + 1;
		end

		mem_rsp_fire = 1'b1;
		@(posedge clk); #1 mem_rsp_fire = 1'b0;
		@(posedge clk); #1;
		if (inflight_count != 16'd1) begin
			$display("FAIL atg_mmu.inflight: expected 1, got %0d", inflight_count);
			errors = errors + 1;
		end

		mem_rsp_fire = 1'b1;
		@(posedge clk); #1 mem_rsp_fire = 1'b0;
		@(posedge clk); #1;
		if (inflight_count != 16'd0) begin
			$display("FAIL atg_mmu.inflight: expected 0, got %0d", inflight_count);
			errors = errors + 1;
		end

		/* -----------------------------------------------------------------
		 * Setup Page Tables for Session 1:
		 * Root PT at 0x00010000 (PFN = 0x00010).
		 * Level 2 PT at 0x00020000 (PFN = 0x00020).
		 *
		 * Target mapping:
		 * GPU VA 0x4000_1234 -> PA 0x8888_1234
		 * VPN = 0x40001 -> PDI = 256 (0x100), PTI = 1 (0x001).
		 * PDE address: 0x00010000 + 256*4 = 0x00010400 (word idx 0x4100).
		 * PDE = {20'h00020, 12'h001} (points to L2 PT, valid=1).
		 *
		 * PTE address: 0x00020000 + 1*4 = 0x00020004 (word idx 0x8001).
		 * PTE = {20'h88881, 6'd1, 6'b000011} (PFN=0x88881, Session=1, R=1, Valid=1).
		 * ----------------------------------------------------------------- */
		sim_mem[32'h0001_0400 >> 2] = {20'h00020, 12'h001};
		sim_mem[32'h0002_0004 >> 2] = {20'h88881, 6'd1, 6'b000011};

		/* Configure Session 1 Root Page Directory base */
		@(posedge clk); #1;
		cp_pt_root_session = 4'd1;
		cp_pt_root_base    = 20'h00010;
		cp_pt_root_we      = 1'b1;
		@(posedge clk); #1;
		cp_pt_root_we      = 1'b0;
		@(posedge clk); #1;

		/* -----------------------------------------------------------------
		 * 2. Hardware Walker Lookup (Client 0 Read Miss)
		 * ----------------------------------------------------------------- */
		client_req_valid[0]           = 1'b1;
		client_req_session[0*4 +: 4]   = 4'd1;
		client_req_va[0*32 +: 32]     = 32'h4000_1234;
		client_req_type[0*2 +: 2]     = 2'd0; /* Read */

		timeout = 0;
		while (!client_ack[0] && timeout < 50) begin
			@(posedge clk);
			timeout = timeout + 1;
		end

		if (!client_ack[0]) begin
			$display("FAIL atg_mmu.walk: timeout waiting for client_ack[0]");
			errors = errors + 1;
		end else if (client_pa[0*32 +: 32] != 32'h8888_1234) begin
			$display("FAIL atg_mmu.walk: expected PA 0x88881234, got 0x%08x", client_pa[0*32 +: 32]);
			errors = errors + 1;
		end
		@(posedge clk); #1;
		client_req_valid[0] = 1'b0;
		@(posedge clk); #1;

		/* -----------------------------------------------------------------
		 * 3. 1-Cycle L1 TLB Hit (Client 0 same page)
		 * ----------------------------------------------------------------- */
		client_req_valid[0]           = 1'b1;
		client_req_session[0*4 +: 4]   = 4'd1;
		client_req_va[0*32 +: 32]     = 32'h4000_1ABC;
		client_req_type[0*2 +: 2]     = 2'd0;

		#1; /* Combinatorial evaluation */
		if (!client_ack[0] || client_pa[0*32 +: 32] != 32'h8888_1ABC) begin
			$display("FAIL atg_mmu.l1_hit: 1-cycle hit failed (ack=%b, pa=0x%08x)",
				client_ack[0], client_pa[0*32 +: 32]);
			errors = errors + 1;
		end
		@(posedge clk); #1;
		client_req_valid[0] = 1'b0;
		@(posedge clk); #1;

		/* -----------------------------------------------------------------
		 * 4. Shared L2 TLB Hit (Client 1 requests same VA, L1 miss, L2 hit)
		 * ----------------------------------------------------------------- */
		client_req_valid[1]           = 1'b1;
		client_req_session[1*4 +: 4]   = 4'd1;
		client_req_va[1*32 +: 32]     = 32'h4000_1DEF;
		client_req_type[1*2 +: 2]     = 2'd0;

		timeout = 0;
		while (!client_ack[1] && timeout < 10) begin
			@(posedge clk);
			timeout = timeout + 1;
		end

		if (!client_ack[1]) begin
			$display("FAIL atg_mmu.l2_hit: timeout waiting for client_ack[1]");
			errors = errors + 1;
		end else if (client_pa[1*32 +: 32] != 32'h8888_1DEF) begin
			$display("FAIL atg_mmu.l2_hit: expected PA 0x88881DEF, got 0x%08x", client_pa[1*32 +: 32]);
			errors = errors + 1;
		end
		@(posedge clk); #1;
		client_req_valid[1] = 1'b0;
		@(posedge clk); #1;

		/* -----------------------------------------------------------------
		 * 5. FAULT_GPU_PAGE_FAULT (Client 2 unmapped address)
		 * ----------------------------------------------------------------- */
		/* VA = 0x5000_0000 -> PDI = 320 (0x140). PDE is 0 (invalid) */
		client_req_valid[2]           = 1'b1;
		client_req_session[2*4 +: 4]   = 4'd1;
		client_req_va[2*32 +: 32]     = 32'h5000_0000;
		client_req_type[2*2 +: 2]     = 2'd0;

		timeout = 0;
		while (!client_fault[2] && timeout < 50) begin
			@(posedge clk);
			timeout = timeout + 1;
		end

		if (!client_fault[2]) begin
			$display("FAIL atg_mmu.page_fault: expected client_fault[2]");
			errors = errors + 1;
		end
		if (!fault_valid || fault_kind != 4'd9 || fault_addr != 32'h5000_0000 ||
		    fault_session != 4'd1 || fault_client != 3'd2) begin
			$display("FAIL atg_mmu.page_fault: fault trap mismatch (v=%b, kind=%0d, addr=0x%08x, sess=%0d, cl=%0d)",
				fault_valid, fault_kind, fault_addr, fault_session, fault_client);
			errors = errors + 1;
		end
		@(posedge clk); #1;
		client_req_valid[2] = 1'b0;
		@(posedge clk); #1;

		/* -----------------------------------------------------------------
		 * 6. FAULT_GPU_PERM_VIOLATION (Write to Read-Only Page)
		 * Map page VA 0x6000_0000 as Read-Only:
		 * VPN = 0x60000 -> PDI = 384 (0x180), PTI = 0.
		 * ----------------------------------------------------------------- */
		sim_mem[32'h0001_0600 >> 2] = {20'h00020, 12'h001}; /* points to L2 PT */
		sim_mem[32'h0002_0000 >> 2] = {20'h99990, 6'd1, 6'b000011}; /* R=1, W=0, Valid=1 */

		client_req_valid[3]           = 1'b1;
		client_req_session[3*4 +: 4]   = 4'd1;
		client_req_va[3*32 +: 32]     = 32'h6000_0000;
		client_req_type[3*2 +: 2]     = 2'd1; /* Write */

		timeout = 0;
		while (!client_fault[3] && timeout < 50) begin
			@(posedge clk);
			timeout = timeout + 1;
		end

		if (!client_fault[3]) begin
			$display("FAIL atg_mmu.perm_fault: expected client_fault[3]");
			errors = errors + 1;
		end
		if (!fault_valid || fault_kind != 4'd10 || fault_addr != 32'h6000_0000 ||
		    fault_session != 4'd1 || fault_client != 3'd3) begin
			$display("FAIL atg_mmu.perm_fault: fault trap mismatch (v=%b, kind=%0d, addr=0x%08x, sess=%0d, cl=%0d)",
				fault_valid, fault_kind, fault_addr, fault_session, fault_client);
			errors = errors + 1;
		end
		@(posedge clk); #1;
		client_req_valid[3] = 1'b0;
		@(posedge clk); #1;

		/* -----------------------------------------------------------------
		 * 7. TLB Invalidation / Flush Test
		 * Flush Session 1 TLBs.
		 * ----------------------------------------------------------------- */
		@(posedge clk); #1;
		cp_flush_session = 4'd1;
		cp_flush_all     = 1'b0;
		cp_flush_trigger = 1'b1;
		@(posedge clk); #1;
		cp_flush_trigger = 1'b0;
		@(posedge clk); #1;

		/* Client 0 requests 0x4000_1ABC again: should now MISS L1 & L2 and re-walk */
		client_req_valid[0]           = 1'b1;
		client_req_session[0*4 +: 4]   = 4'd1;
		client_req_va[0*32 +: 32]     = 32'h4000_1ABC;
		client_req_type[0*2 +: 2]     = 2'd0;

		#1;
		if (client_ack[0]) begin
			$display("FAIL atg_mmu.flush: L1 hit immediately after flush (should have missed)");
			errors = errors + 1;
		end

		timeout = 0;
		while (!client_ack[0] && timeout < 50) begin
			@(posedge clk);
			timeout = timeout + 1;
		end

		if (!client_ack[0] || client_pa[0*32 +: 32] != 32'h8888_1ABC) begin
			$display("FAIL atg_mmu.flush: re-walk after flush failed");
			errors = errors + 1;
		end
		@(posedge clk); #1;
		client_req_valid[0] = 1'b0;
		@(posedge clk); #1;

		/* Summary */
		if (errors == 0)
			$display("PASS atg_mmu");
		else
			$display("FAIL atg_mmu: %0d errors", errors);

		$finish;
	end
endmodule

`default_nettype wire
