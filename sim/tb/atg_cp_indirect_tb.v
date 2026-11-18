/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_indirect_tb: Unit test for Indirect Drawing & Instancing (Phase 008, ws002-p008).
 *
 * Verifies:
 *   1. Non-indexed VkDrawIndirectCommand fetching and unpacking.
 *   2. Indexed VkDrawIndexedIndirectCommand with 20-byte alignment and line-crossing.
 *   3. MultiDrawIndirect: 100 consecutive indirect draw commands unpacked and executed GPU-side.
 *   4. Vertex Attribute Divisor: atg_vf_fetch with Divisor = 4 advances attribute address
 *      once every 4 instances.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_indirect_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	/* atg_cp_indirect signals */
	reg cmd_valid = 1'b0;
	wire cmd_ready;
	reg [31:0] arg_buffer_addr = 32'd0;
	reg [31:0] draw_count = 32'd0;
	reg [31:0] stride = 32'd0;
	reg is_indexed = 1'b0;

	wire dma_req_valid;
	reg dma_req_ready = 1'b1;
	wire [25:0] dma_req_line;
	reg dma_rsp_valid = 1'b0;
	reg [255:0] dma_rsp_data = 256'd0;

	wire draw_valid;
	reg draw_ready = 1'b1;
	wire [31:0] vertex_count;
	wire [31:0] instance_count;
	wire [31:0] first_vertex;
	wire [31:0] first_instance;
	wire [31:0] first_index;
	wire [31:0] vertex_offset;

	integer errors = 0;

	atg_cp_indirect dut_ind (
		.clk(clk),
		.rst_n(rst_n),
		.cmd_valid(cmd_valid),
		.cmd_ready(cmd_ready),
		.arg_buffer_addr(arg_buffer_addr),
		.draw_count(draw_count),
		.stride(stride),
		.is_indexed(is_indexed),
		.dma_req_valid(dma_req_valid),
		.dma_req_ready(dma_req_ready),
		.dma_req_line(dma_req_line),
		.dma_rsp_valid(dma_rsp_valid),
		.dma_rsp_data(dma_rsp_data),
		.draw_valid(draw_valid),
		.draw_ready(draw_ready),
		.vertex_count(vertex_count),
		.instance_count(instance_count),
		.first_vertex(first_vertex),
		.first_instance(first_instance),
		.first_index(first_index),
		.vertex_offset(vertex_offset)
	);

	/* Memory storage for indirect commands (1024 lines of 32 bytes = 32 KB) */
	reg [255:0] mem [0:1023];

	/* Helper task to write a 32-bit word into memory at byte address */
	task mem_write32;
		input [31:0] byte_addr;
		input [31:0] val;
		integer line_idx, byte_off;
		begin
			line_idx = byte_addr[31:5];
			byte_off = byte_addr[4:0];
			mem[line_idx][byte_off*8 +: 32] = val;
		end
	endtask

	/* DMA responder: responds after 1 cycle latency */
	reg dma_pend = 1'b0;
	reg [25:0] dma_line_latched = 26'd0;

	always @(posedge clk) begin
		if (!rst_n) begin
			dma_pend <= 1'b0;
			dma_rsp_valid <= 1'b0;
		end else begin
			dma_rsp_valid <= 1'b0;
			if (dma_pend) begin
				dma_rsp_valid <= 1'b1;
				dma_rsp_data <= mem[dma_line_latched];
				dma_pend <= 1'b0;
			end
			if (dma_req_valid && dma_req_ready && !dma_pend) begin
				dma_pend <= 1'b1;
				dma_line_latched <= dma_req_line;
			end
		end
	end

	/* atg_vf_fetch instance to verify Vertex Attribute Divisor */
	reg vf_st_we = 1'b0;
	reg [8:0] vf_st_idx = 9'd0;
	reg [31:0] vf_st_wdata = 32'd0;

	reg vf_vb_valid = 1'b0;
	reg [31:0] vf_vb_index = 32'd0;
	reg [31:0] vf_vb_inst = 32'd0;
	reg [4:0] vf_vb_lane = 5'd0;
	reg vf_vb_last = 1'b0;
	wire vf_vb_ready;

	wire vf_af_valid, vf_af_last, vf_af_oob, vf_busy;
	reg vf_af_ready = 1'b1;
	wire [3:0] vf_af_attr;
	wire [4:0] vf_af_lane;
	wire [127:0] vf_af_raw;

	wire vf_req_valid, vf_req_write;
	reg vf_req_ready = 1'b1;
	wire [26:0] vf_req_line;
	wire [31:0] vf_req_be;
	wire [255:0] vf_req_wdata;
	wire [7:0] vf_req_tag;
	reg vf_rsp_valid = 1'b0;
	reg [255:0] vf_rsp_rdata = 256'd0;

	atg_vf_fetch #(
		.ADDR_W(32),
		.LINE_BYTES(32),
		.LINE_SHIFT(5)
	) u_vf_fetch (
		.clk(clk),
		.rst_n(rst_n),
		.st_we(vf_st_we),
		.st_idx(vf_st_idx),
		.st_wdata(vf_st_wdata),
		.vb_valid(vf_vb_valid),
		.vb_ready(vf_vb_ready),
		.vb_index(vf_vb_index),
		.vb_inst(vf_vb_inst),
		.vb_lane(vf_vb_lane),
		.vb_last(vf_vb_last),
		.af_valid(vf_af_valid),
		.af_ready(vf_af_ready),
		.af_attr(vf_af_attr),
		.af_lane(vf_af_lane),
		.af_raw(vf_af_raw),
		.af_oob(vf_af_oob),
		.af_last(vf_af_last),
		.busy(vf_busy),
		.req_valid(vf_req_valid),
		.req_ready(vf_req_ready),
		.req_write(vf_req_write),
		.req_line(vf_req_line),
		.req_be(vf_req_be),
		.req_wdata(vf_req_wdata),
		.req_tag(vf_req_tag),
		.rsp_valid(vf_rsp_valid),
		.rsp_write(1'b0),
		.rsp_tag(8'd0),
		.rsp_rdata(vf_rsp_rdata),
		.rsp_error(1'b0)
	);

	task fail;
		input [8*48-1:0] what;
		begin
			$display("FAIL atg_cp_indirect.%0s", what);
			errors = errors + 1;
		end
	endtask

	task vf_st_put;
		input [8:0] i_;
		input [31:0] val;
		begin
			@(negedge clk);
			vf_st_we <= 1'b1;
			vf_st_idx <= i_;
			vf_st_wdata <= val;
			@(posedge clk);
			vf_st_we <= 1'b0;
		end
	endtask

	integer i, k, ec;
	reg [31:0] cur_req_line_addr;

	initial begin
		for (i = 0; i < 1024; i = i + 1)
			mem[i] = 256'd0;

		repeat (3) @(negedge clk);
		rst_n = 1'b1;
		repeat (3) @(posedge clk);

		/*
		 * TEST 1: Non-indexed VkDrawIndirectCommand
		 * 4 draw calls at buffer address 0x0100 (stride 16 bytes).
		 */
		ec = errors;

		/* Set up 4 VkDrawIndirectCommand structs in memory at 0x0100 */
		for (i = 0; i < 4; i = i + 1) begin
			mem_write32(32'h0100 + i*16 + 0,  32'd100 + i*10); /* vertexCount */
			mem_write32(32'h0100 + i*16 + 4,  32'd1 + i);      /* instanceCount */
			mem_write32(32'h0100 + i*16 + 8,  32'd1000 * i);   /* firstVertex */
			mem_write32(32'h0100 + i*16 + 12, 32'd50 * i);     /* firstInstance */
		end

		@(negedge clk);
		cmd_valid <= 1'b1;
		arg_buffer_addr <= 32'h0100;
		draw_count <= 32'd4;
		stride <= 32'd16;
		is_indexed <= 1'b0;
		@(posedge clk);
		while (!cmd_ready) @(posedge clk);
		@(negedge clk);
		cmd_valid <= 1'b0;

		/* Receive 4 draw calls */
		for (i = 0; i < 4; i = i + 1) begin
			@(posedge clk);
			while (!draw_valid) @(posedge clk);

			if (vertex_count !== 32'd100 + i*10) begin
				fail("basic vertex_count mismatch");
				$display("  draw %0d got vertex_count=%0d want %0d", i, vertex_count, 100 + i*10);
			end
			if (instance_count !== 32'd1 + i) begin
				fail("basic instance_count mismatch");
				$display("  draw %0d got instance_count=%0d want %0d", i, instance_count, 1 + i);
			end
			if (first_vertex !== 32'd1000 * i) begin
				fail("basic first_vertex mismatch");
				$display("  draw %0d got first_vertex=%0d want %0d", i, first_vertex, 1000 * i);
			end
			if (first_instance !== 32'd50 * i) begin
				fail("basic first_instance mismatch");
				$display("  draw %0d got first_instance=%0d want %0d", i, first_instance, 50 * i);
			end
		end

		/* Wait for completion */
		@(posedge clk);
		while (!cmd_ready) @(posedge clk);

		if (errors == ec)
			$display("PASS atg_cp_indirect.basic");

		/*
		 * TEST 2: Indexed VkDrawIndexedIndirectCommand (20 bytes per draw)
		 * Tests 20-byte stride that crosses 32-byte line boundaries.
		 */
		ec = errors;

		/* Set up 5 VkDrawIndexedIndirectCommand structs in memory at 0x0200 */
		for (i = 0; i < 5; i = i + 1) begin
			mem_write32(32'h0200 + i*20 + 0,  32'd30 + i*3);   /* indexCount */
			mem_write32(32'h0200 + i*20 + 4,  32'd2 + i);      /* instanceCount */
			mem_write32(32'h0200 + i*20 + 8,  32'd12 * i);     /* firstIndex */
			mem_write32(32'h0200 + i*20 + 12, 32'd4 * i);      /* vertexOffset */
			mem_write32(32'h0200 + i*20 + 16, 32'd1 + i*2);    /* firstInstance */
		end

		@(negedge clk);
		cmd_valid <= 1'b1;
		arg_buffer_addr <= 32'h0200;
		draw_count <= 32'd5;
		stride <= 32'd20;
		is_indexed <= 1'b1;
		@(posedge clk);
		while (!cmd_ready) @(posedge clk);
		@(negedge clk);
		cmd_valid <= 1'b0;

		for (i = 0; i < 5; i = i + 1) begin
			@(posedge clk);
			while (!draw_valid) @(posedge clk);

			if (vertex_count !== 32'd30 + i*3)
				fail("indexed index_count mismatch");
			if (instance_count !== 32'd2 + i)
				fail("indexed instance_count mismatch");
			if (first_index !== 32'd12 * i)
				fail("indexed first_index mismatch");
			if (vertex_offset !== 32'd4 * i)
				fail("indexed vertex_offset mismatch");
			if (first_instance !== 32'd1 + i*2)
				fail("indexed first_instance mismatch");
		end

		@(posedge clk);
		while (!cmd_ready) @(posedge clk);

		if (errors == ec)
			$display("PASS atg_cp_indirect.indexed");

		/*
		 * TEST 3: MultiDrawIndirect (100 Draw Calls GPU-side)
		 * 100 consecutive VkDrawIndexedIndirectCommand structs in memory.
		 */
		ec = errors;

		for (i = 0; i < 100; i = i + 1) begin
			mem_write32(32'h1000 + i*20 + 0,  32'd3 + 3*i);
			mem_write32(32'h1000 + i*20 + 4,  32'd1 + (i % 8));
			mem_write32(32'h1000 + i*20 + 8,  32'd12 * i);
			mem_write32(32'h1000 + i*20 + 12, 32'd4 * i);
			mem_write32(32'h1000 + i*20 + 16, i);
		end

		@(negedge clk);
		cmd_valid <= 1'b1;
		arg_buffer_addr <= 32'h1000;
		draw_count <= 32'd100;
		stride <= 32'd20;
		is_indexed <= 1'b1;
		@(posedge clk);
		while (!cmd_ready) @(posedge clk);
		@(negedge clk);
		cmd_valid <= 1'b0;

		for (i = 0; i < 100; i = i + 1) begin
			@(posedge clk);
			while (!draw_valid) @(posedge clk);

			if (vertex_count !== 32'd3 + 3*i ||
			    instance_count !== 32'd1 + (i % 8) ||
			    first_index !== 32'd12 * i ||
			    vertex_offset !== 32'd4 * i ||
			    first_instance !== i) begin
				fail("multidraw100 mismatch");
				$display("  draw %0d mismatch", i);
			end
		end

		@(posedge clk);
		while (!cmd_ready) @(posedge clk);

		if (errors == ec)
			$display("PASS atg_cp_indirect.multidraw100");

		/*
		 * TEST 4: Vertex Attribute Divisor (atg_vf_fetch)
		 * Configure Attribute 0 with:
		 *   - Base = 0x4000
		 *   - Stride = 16 bytes
		 *   - Per-instance = 1 (DESC[20] = 1)
		 *   - Divisor = 4 (DESC[31:24] = 4)
		 *   - Format = RGBA8 (4 bytes)
		 * Verify that as instance advances 0, 1, 2, 3, 4, 5, 6, 7, 8:
		 *   - Instances 0..3 read from element 0 (line 0x4000 >> 5 = 0x200)
		 *   - Instances 4..7 read from element 1 (address 0x4000 + 16 = 0x4010)
		 *   - Instance 8 reads from element 2 (address 0x4000 + 32 = 0x4020 -> line 0x201)
		 */
		ec = errors;

		/* Set FIRST_INSTANCE = 0 */
		vf_st_put(GHCI_S_FIRST_INSTANCE, 32'd0);

		/* ATTR[0]_BASE = 0x00004000 (GHCI_S_ATTR + 0) */
		vf_st_put(GHCI_S_ATTR + 9'd0, 32'h00004000);

		/* ATTR[0]_DESC = {Divisor 8'd4, 3'd0, per_instance 1'b1, format 4'd0, stride 16'd16}
		 * = {8'd4, 3'b000, 1'b1, 4'd0, 16'd16} = 32'h04100010 */
		vf_st_put(GHCI_S_ATTR + 9'd1, 32'h04100010);

		/* Enable Attribute 0 in ATTR_DST[0] (0x1C0) */
		vf_st_put(GHCI_S_ATTR_DST + 9'd0, 32'h00000001);

		/* Issue vertices for inst 0, 1, 2, 3, 4, 5, 6, 7, 8 */
		for (i = 0; i <= 8; i = i + 1) begin
			@(negedge clk);
			vf_vb_valid <= 1'b1;
			vf_vb_index <= 32'd0;
			vf_vb_inst <= i;
			vf_vb_lane <= 5'd0;
			vf_vb_last <= 1'b1;

			@(posedge clk);
			while (!vf_vb_ready) @(posedge clk);
			@(negedge clk);
			vf_vb_valid <= 1'b0;

			/* Wait for attribute fetch request or completion */
			@(posedge clk);
			while (!vf_req_valid && !vf_af_valid) @(posedge clk);

			if (vf_req_valid) begin
				/* Check requested line address */
				cur_req_line_addr = {vf_req_line, 5'd0};
				/*
				 * Expected address: 0x4000 + (i / 4) * 16:
				 * i in 0..3: addr = 0x4000, line = 0x4000 >> 5 = 0x200
				 * i in 4..7: addr = 0x4010, line = 0x4010 >> 5 = 0x200 (same line, offset 16!)
				 * i = 8: addr = 0x4020, line = 0x4020 >> 5 = 0x201
				 */
				if (i >= 8) begin
					if (cur_req_line_addr !== 32'h00004020) begin
						fail("divisor inst 8 line addr mismatch");
						$display("  got req line addr %h, want 00004020", cur_req_line_addr);
					end
				end else begin
					if (cur_req_line_addr !== 32'h00004000) begin
						fail("divisor line addr mismatch");
						$display("  inst %0d got req line addr %h, want 00004000", i, cur_req_line_addr);
					end
				end

				/* Respond with dummy line data */
				@(negedge clk);
				vf_rsp_valid <= 1'b1;
				vf_rsp_rdata <= 256'hDEADBEEF;
				@(posedge clk);
				@(negedge clk);
				vf_rsp_valid <= 1'b0;
			end

			/* Wait for attribute completion */
			@(posedge clk);
			while (!vf_af_valid) @(posedge clk);
			@(posedge clk);
			while (vf_busy) @(posedge clk);
		end

		if (errors == ec)
			$display("PASS atg_cp_indirect.divisor");

		if (errors == 0)
			$display("PASS atg_cp_indirect");

		$finish;
	end

	initial begin
		#10000000;
		$display("FAIL atg_cp_indirect timeout");
		$finish;
	end

endmodule
`default_nettype wire
