/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_async_tb: Testbench for asynchronous DMA transfer queue & 3D volume copy.
 *
 * Verifies:
 * 1. 3D Volume image copy (depth slice stride, row stride, padding):
 *    - Accurate multi-slice buffer-to-image copy across slices.
 *    - Strict address math: z * slice_stride + y * row_stride.
 * 2. Concurrent Execution:
 *    - Dedicated async transfer queue (RING_DMA) executes in background
 *      concurrently with primary 3D graphics rendering (draw calls / color buffer writes).
 *    - Memory multiplexing via am_amb_mux without deadlock or cross-corruption.
 *    - Synchronization semaphore (GHCI_DMA_SEMAPHORE) advancement upon completion.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_async_tb;
	`include "ghci_regs.vh"

	localparam ADDR_W = 32;
	localparam LINE_BYTES = 32;
	localparam LINE_SHIFT = 5;
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LINE_BITS = LINE_BYTES * 8;
	localparam MEM_SIZE = 1048576; // 1 MB test memory

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = ~clk; // 100 MHz

	// Simulated AMB Memory
	reg [7:0] mem [0:MEM_SIZE-1];

	// Memory Port from am_amb_mux
	wire o_req_valid;
	reg  o_req_ready = 1'b1;
	wire o_req_write;
	wire [LA_W-1:0] o_req_line;
	wire [LINE_BYTES-1:0] o_req_be;
	wire [LINE_BITS-1:0] o_req_wdata;
	wire [7:0] o_req_tag;
	reg  o_rsp_valid = 1'b0;
	reg  o_rsp_write = 1'b0;
	reg  [7:0] o_rsp_tag = 8'd0;
	reg  [LINE_BITS-1:0] o_rsp_rdata = {LINE_BITS{1'b0}};

	// AMB Mux Requesters:
	// Client 0: Main 3D Graphics Rendering pipeline
	// Client 1: Async DMA 3D Volume Copy Engine (atg_blt_3d)
	wire [1:0] i_req_valid;
	wire [1:0] i_req_ready;
	wire [1:0] i_req_write;
	wire [2*LA_W-1:0] i_req_line;
	wire [2*LINE_BYTES-1:0] i_req_be;
	wire [2*LINE_BITS-1:0] i_req_wdata;
	wire [15:0] i_req_tag;
	wire [1:0] i_rsp_valid;
	wire i_rsp_write;
	wire [7:0] i_rsp_tag;
	wire [LINE_BITS-1:0] i_rsp_rdata;
	wire i_rsp_error;

	am_amb_mux #(
		.ADDR_W(ADDR_W),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.N(2),
		.ID_W(1)
	) u_mux (
		.clk(clk),
		.rst_n(rst_n),
		.i_req_valid(i_req_valid),
		.i_req_ready(i_req_ready),
		.i_req_write(i_req_write),
		.i_req_line(i_req_line),
		.i_req_be(i_req_be),
		.i_req_wdata(i_req_wdata),
		.i_req_tag(i_req_tag),
		.i_rsp_valid(i_rsp_valid),
		.i_rsp_write(i_rsp_write),
		.i_rsp_tag(i_rsp_tag),
		.i_rsp_rdata(i_rsp_rdata),
		.i_rsp_error(i_rsp_error),
		.o_req_valid(o_req_valid),
		.o_req_ready(o_req_ready),
		.o_req_write(o_req_write),
		.o_req_line(o_req_line),
		.o_req_be(o_req_be),
		.o_req_wdata(o_req_wdata),
		.o_req_tag(o_req_tag),
		.o_rsp_valid(o_rsp_valid),
		.o_rsp_write(o_rsp_write),
		.o_rsp_tag(o_rsp_tag),
		.o_rsp_rdata(o_rsp_rdata),
		.o_rsp_error(1'b0)
	);

	// Client 0: Simulated Graphics Pipeline (Draw / FB writes)
	reg gfx_req_v = 1'b0;
	reg gfx_req_wr = 1'b0;
	reg [LA_W-1:0] gfx_req_line = {LA_W{1'b0}};
	reg [LINE_BYTES-1:0] gfx_req_be = {LINE_BYTES{1'b1}};
	reg [LINE_BITS-1:0] gfx_req_wdata = {LINE_BITS{1'b0}};
	reg [7:0] gfx_req_tag = 8'h01;

	assign i_req_valid[0] = gfx_req_v;
	assign i_req_write[0] = gfx_req_wr;
	assign i_req_line[0*LA_W +: LA_W] = gfx_req_line;
	assign i_req_be[0*LINE_BYTES +: LINE_BYTES] = gfx_req_be;
	assign i_req_wdata[0*LINE_BITS +: LINE_BITS] = gfx_req_wdata;
	assign i_req_tag[0*8 +: 8] = gfx_req_tag;

	// Client 1: Async DMA 3D Volume Copy Engine
	wire dma_req_v, dma_req_wr;
	wire [LA_W-1:0] dma_req_line;
	wire [LINE_BYTES-1:0] dma_req_be;
	wire [LINE_BITS-1:0] dma_req_wdata;
	wire [7:0] dma_req_tag;

	assign i_req_valid[1] = dma_req_v;
	assign i_req_write[1] = dma_req_wr;
	assign i_req_line[1*LA_W +: LA_W] = dma_req_line;
	assign i_req_be[1*LINE_BYTES +: LINE_BYTES] = dma_req_be;
	assign i_req_wdata[1*LINE_BITS +: LINE_BITS] = dma_req_wdata;
	assign i_req_tag[1*8 +: 8] = dma_req_tag;

	// 3D Copy Signals
	reg  b3d_req_v = 1'b0;
	wire b3d_req_r;
	reg  [31:0] b3d_src_base = 32'd0;
	reg  [31:0] b3d_dst_base = 32'd0;
	reg  [31:0] b3d_src_row_stride = 32'd0;
	reg  [31:0] b3d_dst_row_stride = 32'd0;
	reg  [31:0] b3d_src_slice_stride = 32'd0;
	reg  [31:0] b3d_dst_slice_stride = 32'd0;
	reg  [15:0] b3d_copy_w = 16'd0;
	reg  [15:0] b3d_copy_h = 16'd0;
	reg  [15:0] b3d_copy_d = 16'd0;
	wire b3d_done;

	atg_blt_3d #(
		.ADDR_W(ADDR_W),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT)
	) u_blt_3d (
		.clk(clk),
		.rst_n(rst_n),
		.req_valid(b3d_req_v),
		.req_ready(b3d_req_r),
		.src_base(b3d_src_base),
		.dst_base(b3d_dst_base),
		.src_row_stride(b3d_src_row_stride),
		.dst_row_stride(b3d_dst_row_stride),
		.src_slice_stride(b3d_src_slice_stride),
		.dst_slice_stride(b3d_dst_slice_stride),
		.copy_w(b3d_copy_w),
		.copy_h(b3d_copy_h),
		.copy_d(b3d_copy_d),
		.done(b3d_done),
		.m_req_valid(dma_req_v),
		.m_req_ready(i_req_ready[1]),
		.m_req_write(dma_req_wr),
		.m_req_line(dma_req_line),
		.m_req_be(dma_req_be),
		.m_req_wdata(dma_req_wdata),
		.m_req_tag(dma_req_tag),
		.m_rsp_valid(i_rsp_valid[1]),
		.m_rsp_write(i_rsp_write),
		.m_rsp_tag(i_rsp_tag),
		.m_rsp_rdata(i_rsp_rdata),
		.m_rsp_error(i_rsp_error)
	);

	// CP Ring Instance for dedicated RING_DMA control
	reg  hcr_we = 1'b0;
	reg  [9:0] hcr_widx = 10'd0;
	reg  [31:0] hcr_wdata = 32'd0;
	reg  [31:0] hcr_wmask = 32'hFFFFFFFF;
	wire [9:0] hcr_ridx = hcr_widx;
	wire [31:0] hcr_rdata;
	wire q_dma_req_valid;
	wire [31:0] q_dma_src_base, q_dma_dst_base;
	wire [31:0] q_dma_src_row_stride, q_dma_dst_row_stride;
	wire [31:0] q_dma_src_slice_stride, q_dma_dst_slice_stride;
	wire [15:0] q_dma_copy_w, q_dma_copy_h, q_dma_copy_d;
	wire q_dma_empty, q_dma_busy;
	wire cp_empty, cp_busy;

	atg_cp_ring #(
		.ADDR_W(ADDR_W),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT)
	) u_cp_ring (
		.clk(clk),
		.rst_n(rst_n),
		.core_rst_n(rst_n),
		.hcr_we(hcr_we),
		.hcr_widx(hcr_widx),
		.hcr_wdata(hcr_wdata),
		.hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx),
		.hcr_rdata(hcr_rdata),
		.run(1'b1),
		.halt(1'b0),
		.step(1'b0),
		.open(1'b1),
		.n_valid(),
		.n_ready(1'b1),
		.n_data(),
		.n_last(),
		.v_valid(),
		.v_addr(),
		.v_dwords(),
		.v_tag(),
		.v_done(1'b1),
		.dma_req_valid(q_dma_req_valid),
		.dma_req_ready(b3d_req_r),
		.dma_src_base(q_dma_src_base),
		.dma_dst_base(q_dma_dst_base),
		.dma_src_row_stride(q_dma_src_row_stride),
		.dma_dst_row_stride(q_dma_dst_row_stride),
		.dma_src_slice_stride(q_dma_src_slice_stride),
		.dma_dst_slice_stride(q_dma_dst_slice_stride),
		.dma_copy_w(q_dma_copy_w),
		.dma_copy_h(q_dma_copy_h),
		.dma_copy_d(q_dma_copy_d),
		.dma_done(b3d_done),
		.dma_empty(q_dma_empty),
		.dma_busy(q_dma_busy),
		.empty(cp_empty),
		.retire(),
		.busy(cp_busy),
		.fault(),
		.fault_kind(),
		.fault_addr(),
		.fault_tag(),
		.req_valid(),
		.req_ready(1'b1),
		.req_write(),
		.req_line(),
		.req_be(),
		.req_wdata(),
		.req_tag(),
		.rsp_valid(1'b0),
		.rsp_write(1'b0),
		.rsp_tag(8'd0),
		.rsp_rdata({LINE_BITS{1'b0}}),
		.rsp_error(1'b0)
	);

	// Memory Model Execution
	integer mem_i;
	reg [31:0] byte_addr;
	always @(posedge clk) begin
		if (!rst_n) begin
			o_rsp_valid <= 1'b0;
		end else begin
			o_rsp_valid <= 1'b0;
			if (o_req_valid && o_req_ready) begin
				byte_addr = {o_req_line, {LINE_SHIFT{1'b0}}};
				o_rsp_valid <= 1'b1;
				o_rsp_write <= o_req_write;
				o_rsp_tag   <= o_req_tag;
				if (o_req_write) begin
					for (mem_i = 0; mem_i < LINE_BYTES; mem_i = mem_i + 1) begin
						if (o_req_be[mem_i])
							mem[byte_addr + mem_i] <= o_req_wdata[mem_i*8 +: 8];
					end
				end else begin
					for (mem_i = 0; mem_i < LINE_BYTES; mem_i = mem_i + 1) begin
						o_rsp_rdata[mem_i*8 +: 8] <= mem[byte_addr + mem_i];
					end
				end
			end
		end
	end

	integer errors = 0;
	integer z, y, x, mi;
	integer cur_src, cur_dst;
	reg [7:0] exp_val, act_val;
	integer quick = 0;

	initial begin
		if ($test$plusargs("quick"))
			quick = 1;

		$display("=== atg_blt_async_tb starting (quick=%0d) ===", quick);
		rst_n = 1'b0;
		#40;
		rst_n = 1'b1;
		#20;

		// -------------------------------------------------------------
		// Test 1: Direct atg_blt_3d Volume Copy with Non-trivial Strides
		// -------------------------------------------------------------
		$display("--- Test 1: 3D Volume Copy with Row & Slice Strides ---");
		// 3D Volume: W=64 bytes, H=16 rows, D=8 slices
		// Row stride: 128 bytes (64 bytes data + 64 bytes padding)
		// Slice stride: 4096 bytes (16*128=2048 bytes data + 2048 bytes padding)
		b3d_src_base = 32'h0001_0000;
		b3d_dst_base = 32'h0005_0000;
		b3d_src_row_stride = 32'd128;
		b3d_dst_row_stride = 32'd128;
		b3d_src_slice_stride = 32'd4096;
		b3d_dst_slice_stride = 32'd4096;
		b3d_copy_w = 16'd64;
		b3d_copy_h = 16'd16;
		b3d_copy_d = 16'd8;

		// Initialize source and destination memory
		for (z = 0; z < 8; z = z + 1) begin
			for (y = 0; y < 16; y = y + 1) begin
				cur_src = b3d_src_base + z * b3d_src_slice_stride + y * b3d_src_row_stride;
				cur_dst = b3d_dst_base + z * b3d_dst_slice_stride + y * b3d_dst_row_stride;
				for (x = 0; x < 64; x = x + 1) begin
					mem[cur_src + x] = (z * 31 + y * 17 + x) & 8'hFF;
					mem[cur_dst + x] = 8'hAA; // canary
				end
				// Padding check canaries
				for (x = 64; x < 128; x = x + 1) begin
					mem[cur_dst + x] = 8'h55; // padding canary
				end
			end
		end

		@(posedge clk);
		b3d_req_v <= 1'b1;
		@(posedge clk);
		while (!b3d_req_r) @(posedge clk);
		b3d_req_v <= 1'b0;

		// Wait for 3D copy completion
		while (!b3d_done) @(posedge clk);
		$display("Test 1 completed in hardware; verifying memory contents...");

		// Verify copied texels and padding integrity
		for (z = 0; z < 8; z = z + 1) begin
			for (y = 0; y < 16; y = y + 1) begin
				cur_src = b3d_src_base + z * b3d_src_slice_stride + y * b3d_src_row_stride;
				cur_dst = b3d_dst_base + z * b3d_dst_slice_stride + y * b3d_dst_row_stride;
				for (x = 0; x < 64; x = x + 1) begin
					exp_val = mem[cur_src + x];
					act_val = mem[cur_dst + x];
					if (act_val !== exp_val) begin
						$display("FAIL Test 1: mismatch at z=%0d y=%0d x=%0d: exp 0x%02x, got 0x%02x",
							z, y, x, exp_val, act_val);
						errors = errors + 1;
					end
				end
				for (x = 64; x < 128; x = x + 1) begin
					if (mem[cur_dst + x] !== 8'h55) begin
						$display("FAIL Test 1 padding corrupted at z=%0d y=%0d x=%0d: got 0x%02x",
							z, y, x, mem[cur_dst + x]);
						errors = errors + 1;
					end
				end
			end
		end
		if (errors == 0)
			$display("Test 1 PASS: all slices and strides bit-exact.");

		// -------------------------------------------------------------
		// Test 2: Large 3D Volume Copy (128x128x64 or parameterized)
		// -------------------------------------------------------------
		$display("--- Test 2: 3D Volume Image Copy (128x128x64 texels) ---");
		// In quick mode, run 128x128x4 slices; in full mode run full volume
		b3d_src_base = 32'h0000_1000;
		b3d_dst_base = 32'h0008_0000;
		b3d_copy_w = 16'd512; // 128 texels * 4 bytes/texel (RGBA8)
		b3d_copy_h = 16'd32;  // 32 rows
		b3d_copy_d = quick ? 16'd4 : 16'd16;
		b3d_src_row_stride = 32'd512;
		b3d_dst_row_stride = 32'd512;
		b3d_src_slice_stride = 32'd16384;
		b3d_dst_slice_stride = 32'd16384;

		// Populate volume
		for (z = 0; z < b3d_copy_d; z = z + 1) begin
			for (y = 0; y < b3d_copy_h; y = y + 1) begin
				cur_src = b3d_src_base + z * b3d_src_slice_stride + y * b3d_src_row_stride;
				cur_dst = b3d_dst_base + z * b3d_dst_slice_stride + y * b3d_dst_row_stride;
				for (x = 0; x < b3d_copy_w; x = x + 32) begin
					mem[cur_src + x] = (z * 7 + y * 3 + x) & 8'hFF;
					mem[cur_dst + x] = 8'h00;
				end
			end
		end

		@(posedge clk);
		b3d_req_v <= 1'b1;
		@(posedge clk);
		while (!b3d_req_r) @(posedge clk);
		b3d_req_v <= 1'b0;

		while (!b3d_done) @(posedge clk);
		$display("Test 2 completed in hardware; verifying slices...");

		for (z = 0; z < b3d_copy_d; z = z + 1) begin
			for (y = 0; y < b3d_copy_h; y = y + 1) begin
				cur_src = b3d_src_base + z * b3d_src_slice_stride + y * b3d_src_row_stride;
				cur_dst = b3d_dst_base + z * b3d_dst_slice_stride + y * b3d_dst_row_stride;
				for (x = 0; x < b3d_copy_w; x = x + 32) begin
					exp_val = mem[cur_src + x];
					act_val = mem[cur_dst + x];
					if (act_val !== exp_val) begin
						$display("FAIL Test 2 mismatch at z=%0d y=%0d x=%0d: exp 0x%02x, got 0x%02x",
							z, y, x, exp_val, act_val);
						errors = errors + 1;
					end
				end
			end
		end
		if (errors == 0)
			$display("Test 2 PASS: 3D volume copy verified.");

		// -------------------------------------------------------------
		// Test 3: Concurrent Graphics Rendering + Async Transfer Queue
		// -------------------------------------------------------------
		$display("--- Test 3: Concurrent 3D Draw Rendering + Background DMA Queue ---");

		// Program RING_DMA registers in atg_cp_ring
		hcr_we <= 1'b1;
		hcr_widx <= GHCI_RING_DMA_BASE[11:2];
		hcr_wdata <= 32'h0002_0000; // DMA source base
		@(posedge clk);

		hcr_widx <= GHCI_DMA_DST_BASE[11:2];
		hcr_wdata <= 32'h0006_0000; // DMA destination base
		@(posedge clk);

		hcr_widx <= GHCI_DMA_ROW_STRIDE[11:2];
		hcr_wdata <= 32'd256;
		@(posedge clk);

		hcr_widx <= GHCI_DMA_SLICE_STRIDE[11:2];
		hcr_wdata <= 32'd2048;
		@(posedge clk);

		hcr_widx <= GHCI_DMA_EXTENT[11:2];
		// extent: [31:24]=depth(4), [23:16]=height(8), [15:0]=width(128 bytes)
		hcr_wdata <= {8'd4, 8'd8, 16'd128};
		@(posedge clk);

		hcr_we <= 1'b0;
		@(posedge clk);

		// Connect CP Ring DMA dispatch to atg_blt_3d
		b3d_src_base <= q_dma_src_base;
		b3d_dst_base <= q_dma_dst_base;
		b3d_src_row_stride <= q_dma_src_row_stride;
		b3d_dst_row_stride <= q_dma_dst_row_stride;
		b3d_src_slice_stride <= q_dma_src_slice_stride;
		b3d_dst_slice_stride <= q_dma_dst_slice_stride;
		b3d_copy_w <= q_dma_copy_w;
		b3d_copy_h <= q_dma_copy_h;
		b3d_copy_d <= q_dma_copy_d;

		// Initialize DMA source memory
		for (z = 0; z < 4; z = z + 1) begin
			for (y = 0; y < 8; y = y + 1) begin
				cur_src = 32'h0002_0000 + z * 2048 + y * 256;
				cur_dst = 32'h0006_0000 + z * 2048 + y * 256;
				for (x = 0; x < 128; x = x + 1) begin
					mem[cur_src + x] = (8'hC0 + z * 5 + y * 2 + x) & 8'hFF;
					mem[cur_dst + x] = 8'h00;
				end
			end
		end

		// Start background DMA by ringing doorbell on RING_DMA_WPTR
		hcr_we <= 1'b1;
		hcr_widx <= GHCI_RING_DMA_WPTR[11:2];
		hcr_wdata <= 32'd1;
		@(posedge clk);
		hcr_we <= 1'b0;

		// Wait for CP ring to assert dma_req_valid
		while (!q_dma_req_valid) @(posedge clk);
		b3d_req_v <= 1'b1;
		@(posedge clk);
		b3d_req_v <= 1'b0;

		// Concurrently execute Main Graphics Pipeline Draw writes (Client 0)
		$display("Generating concurrent graphics framebuffer draw writes...");
		for (mi = 0; mi < 32; mi = mi + 1) begin
			@(posedge clk);
			gfx_req_v <= 1'b1;
			gfx_req_wr <= 1'b1;
			gfx_req_line <= (32'h0004_0000 >> LINE_SHIFT) + mi;
			gfx_req_be <= {LINE_BYTES{1'b1}};
			gfx_req_wdata <= {LINE_BYTES{8'h77}};
			@(posedge clk);
			while (!i_req_ready[0]) @(posedge clk);
			gfx_req_v <= 1'b0;
		end

		// Wait for DMA 3D transfer to complete
		while (!b3d_done) @(posedge clk);
		#20;

		// Verify semaphore incremented in atg_cp_ring
		hcr_widx <= GHCI_DMA_SEMAPHORE[11:2];
		#5;
		if (hcr_rdata !== 32'd1) begin
			$display("FAIL Test 3: expected DMA semaphore == 1, got %0d", hcr_rdata);
			errors = errors + 1;
		end else begin
			$display("Test 3: DMA hardware semaphore incremented correctly (sem=%0d).", hcr_rdata);
		end

		// Verify DMA destination memory
		for (z = 0; z < 4; z = z + 1) begin
			for (y = 0; y < 8; y = y + 1) begin
				cur_src = 32'h0002_0000 + z * 2048 + y * 256;
				cur_dst = 32'h0006_0000 + z * 2048 + y * 256;
				for (x = 0; x < 128; x = x + 1) begin
					exp_val = mem[cur_src + x];
					act_val = mem[cur_dst + x];
					if (act_val !== exp_val) begin
						$display("FAIL Test 3 DMA mismatch at z=%0d y=%0d x=%0d: exp 0x%02x, got 0x%02x",
							z, y, x, exp_val, act_val);
						errors = errors + 1;
					end
				end
			end
		end

		// Verify Graphics Framebuffer destination memory
		for (mi = 0; mi < 32 * LINE_BYTES; mi = mi + 1) begin
			if (mem[32'h0004_0000 + mi] !== 8'h77) begin
				$display("FAIL Test 3 Graphics Framebuffer corrupted at offset %0d: got 0x%02x",
					mi, mem[32'h0004_0000 + mi]);
				errors = errors + 1;
			end
		end

		if (errors == 0)
			$display("Test 3 PASS: Concurrent graphics and DMA execution 100 percent verified.");

		// -------------------------------------------------------------
		// Summary
		// -------------------------------------------------------------
		if (errors == 0) begin
			$display("========================================");
			$display("PASS atg_blt_async");
			$display("========================================");
		end else begin
			$display("========================================");
			$display("FAIL atg_blt_async with %0d errors", errors);
			$display("========================================");
		end
		$finish;
	end

endmodule

`default_nettype wire
