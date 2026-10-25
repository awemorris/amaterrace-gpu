/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_fw_tb: the GPU with CP, CPU with the CP firmware of
 * fw/cp/images/, BLT and MC, driven only through its host port,
 * against axi_mem, in the KC705's shape.  Checks:
 *
 *   - CAPS[17] VKCP and [18] FWLOAD, the extended capability list (PERF,
 *     then CPFW at 0x120), CPFW_STATUS READY and STOPPED before RUN;
 *   - the firmware starts on CPFW_CTRL.RUN: its state, CPFW_VERSION, the
 *     .data word in MBOX3;
 *   - a class N ring packet that FILLs and COPYs (16-bit pixels) one area,
 *     then the ring-only gpu-ops GHCI_HEAP and GHCI_SESSION_OPEN and a
 *     class V GHCI_FRAME whose staged commands (memory, two buffers and
 *     their binding, a command pool and buffer, the recorded
 *     vkCmdFillBuffer and vkCmdCopyBuffer, END, QUEUE_SUBMIT) do the same
 *     to another area: both areas match each other and the model, with
 *     every result record, the frame's result and the RESULT and RETIRE
 *     interrupts;
 *   - a frame with an unknown command: its record and the frame's result
 *     are VK_ERROR_FEATURE_NOT_PRESENT, the record after it is not run;
 *   - the watchdog on a class V packet that nothing takes (CPFW RUN 0):
 *     FAULT kind 4, RESET, and the firmware restarts with .data restored;
 *   - CPFW LOAD: an image of zeros faults at PC 0 (CPFW_STATUS.FAULT,
 *     kind 4), then the real image from memory with a changed .data word
 *     runs, and a frame works again.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_top_fw_harness #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter DATA_W = 64,
	parameter NAME = "dut",
	parameter IMEM = "fw/cp/images/atg1-cp-kc705.imem.hex",
	parameter DMEM = "fw/cp/images/atg1-cp-kc705.dmem.hex",
	parameter IMEM_WORDS = 32768,	/* the KC705's CPU memories (the images' sizes) */
	parameter DMEM_WORDS = 8192,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	output reg finished,
	output integer errors
);
	`include "ghci_regs.vh"

	integer seed;
	reg [16:0] h_awaddr = 0;
	reg [11:0] h_awid = 0;
	reg h_awvalid = 1'b0;
	wire h_awready;
	reg [31:0] h_wdata = 0;
	reg [3:0] h_wstrb = 0;
	reg h_wlast = 1'b0;
	reg h_wvalid = 1'b0;
	wire h_wready;
	wire [11:0] h_bid;
	wire [1:0] h_bresp;
	wire h_bvalid;
	reg h_bready = 1'b0;
	reg [16:0] h_araddr = 0;
	reg [11:0] h_arid = 0;
	reg [3:0] h_arlen = 0;
	reg h_arvalid = 1'b0;
	wire h_arready;
	wire [31:0] h_rdata;
	wire [11:0] h_rid;
	wire [1:0] h_rresp;
	wire h_rlast;
	wire h_rvalid;
	reg h_rready = 1'b0;
	wire irq;

	wire [31:0] awaddr, araddr;
	wire [7:0] awlen, arlen;
	wire [2:0] awsize, arsize, awprot, arprot;
	wire [1:0] awburst, arburst, bresp, rresp;
	wire [3:0] awcache, arcache;
	wire awvalid, awready, wlast, wvalid, wready, bvalid, bready;
	wire arvalid, arready, rlast, rvalid, rready;
	wire [DATA_W-1:0] wdata, rdata;
	wire [DATA_W/8-1:0] wstrb;

	atg_top #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .DATA_W(DATA_W), .HAS_CPU(1),
		.CPU_IMEM_INIT(IMEM), .CPU_DMEM_INIT(DMEM), .CPU_IMEM_WORDS(IMEM_WORDS),
		.CPU_DMEM_WORDS(DMEM_WORDS)) dut (
		.clk(clk), .rst_n(rst_n), .irq(irq), .mem_ready(1'b1),
		.s_awaddr(h_awaddr), .s_awid(h_awid), .s_awvalid(h_awvalid), .s_awready(h_awready),
		.s_wdata(h_wdata), .s_wstrb(h_wstrb), .s_wlast(h_wlast), .s_wvalid(h_wvalid),
		.s_wready(h_wready), .s_bid(h_bid), .s_bresp(h_bresp), .s_bvalid(h_bvalid),
		.s_bready(h_bready), .s_araddr(h_araddr), .s_arid(h_arid), .s_arlen(h_arlen),
		.s_arvalid(h_arvalid), .s_arready(h_arready), .s_rdata(h_rdata), .s_rid(h_rid),
		.s_rresp(h_rresp), .s_rlast(h_rlast), .s_rvalid(h_rvalid), .s_rready(h_rready),
		.m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(awburst),
		.m_awcache(awcache), .m_awprot(awprot), .m_awvalid(awvalid), .m_awready(awready),
		.m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid),
		.m_wready(wready), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
		.m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(arburst),
		.m_arcache(arcache), .m_arprot(arprot), .m_arvalid(arvalid), .m_arready(arready),
		.m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast), .m_rvalid(rvalid),
		.m_rready(rready),
		.xr_wr(), .xr_waddr(), .xr_wdata(), .xr_wstrb(), .xr_rd(), .xr_raddr(),
		.xr_rdata(32'd0),
		.x_req_valid(1'b0), .x_req_ready(), .x_req_write(1'b0), .x_req_line({(32-LINE_SHIFT){1'b0}}),
		.x_req_be({LINE_BYTES{1'b0}}), .x_req_wdata({(LINE_BYTES*8){1'b0}}), .x_req_tag(8'd0),
		.x_rsp_valid(), .x_rsp_write(), .x_rsp_tag(), .x_rsp_rdata(), .x_rsp_error(),
		.x_vsync(1'b0),
		.j_wr(1'b0), .j_waddr(17'd0), .j_wdata(32'd0), .j_wstrb(4'd0), .j_rd(1'b0),
		.j_raddr(17'd0), .j_rdata(), .j_busy()
	);

	axi_mem #(.DATA_W(DATA_W), .MEM_BYTES(1 << 20), .READ_EARLY(1), .SEED(SEED + 7)) mem (
		.clk(clk), .rst_n(rst_n),
		.awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
		.awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
		.wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp),
		.bvalid(bvalid), .bready(bready), .araddr(araddr), .arlen(arlen),
		.arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
		.rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
	);

	`include "axi_host.vh"

	/* Memory: the two areas, the frame's staging and results, the images, the ring. */
	localparam [31:0] AREA_N = 32'h00020000;	/* class N: fill at +0, copy at +0x4000 */
	localparam [31:0] AREA_V = 32'h00030000;	/* class V: the memory object */
	localparam [31:0] AREA_BYTES = 32'h00008000;
	localparam [31:0] IMG_I = 32'h00080000;	/* CPFW images: IMEM 128 KiB, DMEM 32 KiB (in the heap: */
	localparam [31:0] IMG_D = 32'h000A0000;	/* lent again after the load) */
	localparam [31:0] HEAP = 32'h00080000;	/* the firmware's heap (GHCI_HEAP) */
	localparam [31:0] HEAP_BYTES = 32'h00080000;
	localparam [31:0] RING_RESULT = 32'h00058C00;	/* the results of the ring-only gpu-ops */
	localparam [31:0] STAGING = 32'h00050000;
	localparam [31:0] RESULTS = 32'h00058000;	/* the result page */
	localparam [31:0] FRAME_RESULT = 32'h00058800;
	localparam [31:0] FENCES = 32'h0005EF00;
	localparam [31:0] RING = 32'h0005F000;
	localparam RING_N = 256;
	localparam FILL_WORDS = 1300;	/* one 1024-pixel row and a short one */
	localparam COPY_BYTES = 5198;	/* not whole words: 16-bit pixels */
	localparam [31:0] FILL_DATA = 32'hC0DE1234;
	localparam [7:0] TAG = 8'd5;
	localparam [31:0] NO_RESULT = 32'hFFFFFFFF;
	localparam [31:0] DATA_CHECK = 32'h0DA7A001;
	localparam [31:0] VK_FEATURE_NOT_PRESENT = 32'hFFFFFFF8;

	integer wp;	/* the driver's ring write pointer */
	integer sp;	/* the staging's write pointer (words) */
	integer fence_value;
	reg [31:0] img [0:IMEM_WORDS-1];

	task fail_msg;
		input [8*80-1:0] what;
		begin
			errors = errors + 1;
			$display("FAIL atg_top_fw(%0s): %0s", NAME, what);
		end
	endtask

	task expect_reg;
		input [31:0] off;
		input [31:0] want;
		input [31:0] mask;
		reg [31:0] got;
		begin
			host_read(off, got);
			if ((got & mask) !== (want & mask)) begin
				errors = errors + 1;
				$display("FAIL atg_top_fw(%0s): reg %h = %h, expected %h (mask %h)", NAME,
					off, got, want, mask);
			end
		end
	endtask

	task wait_reg;
		input [31:0] off;
		input [31:0] want;
		input [31:0] mask;
		input integer polls;
		reg [31:0] got;
		integer n;
		begin
			n = 0;
			host_read(off, got);
			while ((got & mask) != (want & mask) && n < polls) begin
				host_read(off, got);
				n = n + 1;
			end
			if ((got & mask) != (want & mask)) begin
				errors = errors + 1;
				$display("FAIL atg_top_fw(%0s): reg %h stays %h, waiting for %h (mask %h)", NAME,
					off, got, want, mask);
			end
		end
	endtask

	task expect_mem;
		input [31:0] addr;
		input [31:0] want;
		input [8*40-1:0] what;
		reg [31:0] got;
		begin
			got = mem.peek32(addr);
			if (got !== want) begin
				errors = errors + 1;
				$display("FAIL atg_top_fw(%0s): %0s: mem %h = %h, expected %h", NAME, what,
					addr, got, want);
			end
		end
	endtask

	task ring_put;
		input [31:0] value;
		begin
			mem.poke32(RING + wp * 4, value);
			wp = (wp + 1) % RING_N;
		end
	endtask

	function [31:0] hdr;
		input [5:0] op;
		input [7:0] tag;
		input [7:0] flags;
		input [7:0] n;
		hdr = {2'b00, op, tag, flags, n};
	endfunction

	task ring_set;
		input [8:0] idx;
		input [31:0] value;
		begin
			ring_put({23'd0, idx});
			ring_put(value);
		end
	endtask

	/* A whole-state blit through the ring (BLIT waits for the end). */
	task ring_blit;
		input [31:0] op;
		input [31:0] src;
		input [31:0] dst;
		input [31:0] stride;
		input [15:0] w;
		input [15:0] h;
		input [31:0] color;
		begin
			ring_put(hdr(6'd1, TAG, 8'd0, 8'd22));
			ring_set(GHCI_S_BLT_OP, op);
			ring_set(GHCI_S_BLT_DST_BASE, dst);
			ring_set(GHCI_S_BLT_DST_STRIDE, stride);
			ring_set(GHCI_S_BLT_SRC_BASE, src);
			ring_set(GHCI_S_BLT_SRC_STRIDE, stride);
			ring_set(GHCI_S_BLT_DST_XY, 0);
			ring_set(GHCI_S_BLT_SRC_XY, 0);
			ring_set(GHCI_S_BLT_SIZE, {h, w});
			ring_set(GHCI_S_BLT_COLOR, color);
			ring_set(GHCI_S_BLT_CLIP_MIN, 0);
			ring_set(GHCI_S_BLT_CLIP_MAX, 0);
			ring_put(hdr(6'd2, TAG, 8'd1, 8'd0));
		end
	endtask

	task ring_fence;
		begin
			fence_value = fence_value + 1;
			ring_put(hdr(6'd5, TAG, 8'd1, 8'd2));
			ring_put(FENCES);
			ring_put(fence_value);
		end
	endtask

	/* GHCI_FRAME of the staging's first sp words with `records` records. */
	task ring_frame;
		input integer records;
		begin
			ring_put({2'b10, 6'd0, TAG, 16'd8});
			ring_put(32'h00010105);
			ring_put(32'd2);	/* RESULT */
			ring_put(FRAME_RESULT);
			ring_put(STAGING);
			ring_put(32'd0);
			ring_put(sp * 4);
			ring_put(RESULTS);
			ring_put(records);
		end
	endtask

	/* GHCI_HEAP as a ring packet: the heap, its result at RING_RESULT. */
	task ring_heap;
		begin
			ring_put({2'b10, 6'd0, TAG, 16'd8});
			ring_put(32'h00010108);
			ring_put(32'd2);	/* RESULT */
			ring_put(RING_RESULT);
			ring_put(HEAP);
			ring_put(32'd0);
			ring_put(HEAP_BYTES);
			ring_put(32'd0);
			ring_put(32'd4);	/* warps: one SU of 4 */
		end
	endtask

	/* GHCI_SESSION_OPEN of TAG as a ring packet, its result at RING_RESULT + 8. */
	task ring_session_open;
		begin
			ring_put({2'b10, 6'd0, TAG, 16'd7});
			ring_put(32'h00010100);
			ring_put(32'd2);	/* RESULT */
			ring_put(RING_RESULT + 8);
			ring_put(TAG);
			ring_put(32'd0);	/* flags */
			ring_put(32'h00080000);	/* heap limit */
			ring_put(32'd0);
		end
	endtask

	/* Rings the doorbell, waits for the fence, prints the cycles it took. */
	task doorbell_and_wait;
		input [8*24-1:0] what;
		time t0;
		begin
			t0 = $time;
			host_write(GHCI_RING_WPTR, wp);
			wait_reg(GHCI_FENCE_LAST, fence_value, 32'hFFFFFFFF, 20000);
			expect_reg(GHCI_RING_RPTR, wp, 32'hFFFFFFFF);
			$display("info atg_top_fw(%0s): %0s: %0d cycles to the fence", NAME, what,
				($time - t0) / 10);
		end
	endtask

	/* The staging: words, u64 as two words. */
	task st;
		input [31:0] value;
		begin
			mem.poke32(STAGING + sp * 4, value);
			sp = sp + 1;
		end
	endtask

	task st64;
		input [63:0] value;
		begin
			st(value[31:0]);
			st(value[63:32]);
		end
	endtask

	/* A record's envelope: [number][flags][result index]. */
	task rec;
		input [31:0] number;
		input [31:0] index;
		begin
			st(number);
			st(32'd1);	/* REPLY, as libvulkan sends it */
			st(index);
		end
	endtask

	task create_buffer;
		input [31:0] index;
		input [63:0] id;
		input chain;
		begin
			rec(32'd50, index);
			st64(64'h1);	/* device */
			st64(64'h1);
			st(32'd12);	/* VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO */
			if (chain) begin
				st64(64'h1);
				st(32'd1000072000);
				st64(64'h0);
				st(32'h00000200);
			end else begin
				st64(64'h0);
			end
			st(32'd0);	/* flags */
			st64(64'h2000);	/* size */
			st(32'h3);	/* usage */
			st(32'd0);	/* exclusive */
			st(32'd0);
			st64(64'h0);	/* no queue family indices */
			st64(64'h0);	/* no allocator */
			st64(64'h1);
			st64(id);
		end
	endtask

	task bind;
		input [31:0] index;
		input [63:0] buffer;
		input [63:0] offset;
		begin
			rec(32'd28, index);
			st64(64'h1);
			st64(buffer);
			st64(64'h100);	/* the memory */
			st64(offset);
		end
	endtask

	task expect_result;
		input [31:0] index;
		input [31:0] status;
		input [31:0] aux;
		begin
			expect_mem(RESULTS + index * 8, status, "record status");
			expect_mem(RESULTS + index * 8 + 4, aux, "record aux");
		end
	endtask

	/* Pattern of the areas before the work: a function of the offset. */
	function [31:0] pattern;
		input [31:0] off;
		pattern = 32'h5A5A0000 ^ (off * 32'h9E3779B1);
	endfunction

	/* Loads a $readmemh image into memory at addr. */
	task put_image;
		input [31:0] addr;
		input integer words;
		integer k;
		begin
			for (k = 0; k < words; k = k + 1)
				mem.poke32(addr + k * 4, img[k]);
		end
	endtask

	integer k;
	reg [31:0] v, w16, model;

	initial begin
		errors = 0;
		finished = 1'b0;
		seed = SEED;
		if ($value$plusargs("seed=%d", k))
			seed = SEED + 1000 * k;
		wp = 0;
		sp = 0;
		fence_value = 0;
		@(posedge rst_n);
		repeat (4) @(posedge clk);

		/* Identification of the firmware's capability. */
		expect_reg(GHCI_CAPS, 32'h00060000, 32'h00060000);
		expect_reg(GHCI_EXTCAP, 32'h00000100, 32'hFFFFFFFF);
		expect_reg(32'h100, 32'h00020103, 32'hFFFFFFFF);	/* PERF, next 2 dwords */
		expect_reg(32'h108, 32'h00000106, 32'hFFFFFFFF);	/* CPFW, the last */
		expect_reg(32'h10C, 32'h00000120, 32'hFFFFFFFF);
		expect_reg(GHCI_CPFW_STATUS, 32'h00000009, 32'h0000001B);	/* READY, STOPPED */

		/* The aperture, the ring, the firmware. */
		host_write(GHCI_APERTURE_BASE, AREA_N);
		host_write(GHCI_APERTURE_LIMIT, 32'h00100000);
		host_write(GHCI_RING_BASE, RING);
		host_write(GHCI_RING_SIZE, 32'd10);
		host_write(GHCI_IRQ_STATUS, 32'h1FF);
		host_write(GHCI_IRQ_ENABLE, (32'd1 << GHCI_IRQ_FENCE) | (32'd1 << GHCI_IRQ_RESULT));
		mem.poke32(FENCES, 32'd0);
		host_write(GHCI_FENCE_LAST, 32'd0);
		host_write(GHCI_CPFW_CTRL, 32'd1 << GHCI_CPFW_CTRL_RUN);
		wait_reg(GHCI_CPFW_STATUS, 32'h0201, 32'hFF09, 20000);	/* IDLE, READY, running */
		expect_reg(GHCI_CPFW_VERSION, 32'h00020000, 32'hFFFFFFFF);
		expect_reg(GHCI_CPFW_MBOX0 + 12, DATA_CHECK, 32'hFFFFFFFF);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RUN);

		/* Both areas start with the same pattern; the result page with no-result marks. */
		for (k = 0; k < AREA_BYTES / 4; k = k + 1) begin
			mem.poke32(AREA_N + k * 4, pattern(k));
			mem.poke32(AREA_V + k * 4, pattern(k));
		end
		for (k = 0; k < 64; k = k + 1)
			mem.poke32(RESULTS + k * 4, NO_RESULT);

		/* Class N: the fill and the copy of area N. */
		ring_blit({30'd0, GHCI_BLT_FILL}, 0, AREA_N, FILL_WORDS * 4, FILL_WORDS, 1, FILL_DATA);
		ring_blit({30'd0, GHCI_BLT_COPY} | (32'd1 << GHCI_BLT_OP_BPP16), AREA_N, AREA_N + 32'h4000, COPY_BYTES,
			COPY_BYTES / 2, 1, 0);
		ring_fence;
		doorbell_and_wait("class N fill, copy");

		/*
		 * Class V: the same in area V, through the firmware.  The heap and
		 * the session are ring packets (they are never staged), then the
		 * frame.
		 */
		for (k = 0; k < 4; k = k + 1)
			mem.poke32(RING_RESULT + k * 4, NO_RESULT);
		ring_heap;
		ring_session_open;
		sp = 0;
		rec(32'h00010102, 0);	/* GHCI_MEMORY */
		st64(64'h100);
		st64(AREA_V);
		st64(AREA_BYTES);
		st(32'd0);
		create_buffer(1, 64'h200, 1'b0);
		create_buffer(2, 64'h201, 1'b1);
		bind(3, 64'h200, 64'h0);
		bind(4, 64'h201, 64'h4000);
		rec(32'd85, 5);	/* CREATE_COMMAND_POOL */
		st64(64'h1);
		st64(64'h1);
		st(32'd39);
		st64(64'h0);
		st(32'd0);
		st(32'd0);
		st64(64'h0);
		st64(64'h1);
		st64(64'h300);
		rec(32'd88, 6);	/* ALLOCATE_COMMAND_BUFFERS */
		st64(64'h1);
		st64(64'h1);
		st(32'd40);
		st64(64'h0);
		st64(64'h300);
		st(32'd0);
		st(32'd1);
		st64(64'h1);
		st64(64'h400);
		rec(32'd90, 7);	/* BEGIN_COMMAND_BUFFER */
		st64(64'h400);
		st64(64'h1);
		st(32'd42);
		st64(64'h0);
		st(32'd1);
		st64(64'h0);
		st(32'd118);	/* CMD_FILL_BUFFER, no result */
		st(32'd0);
		st(NO_RESULT);
		st64(64'h400);
		st64(64'h200);
		st64(64'h0);
		st64(FILL_WORDS * 4);
		st(FILL_DATA);
		st(32'd112);	/* CMD_COPY_BUFFER, no result */
		st(32'd0);
		st(NO_RESULT);
		st64(64'h400);
		st64(64'h200);
		st64(64'h201);
		st(32'd1);
		st64(64'h1);
		st64(64'h0);
		st64(64'h0);
		st64(COPY_BYTES);
		rec(32'd91, 10);	/* END_COMMAND_BUFFER */
		st64(64'h400);
		rec(32'd18, 11);	/* QUEUE_SUBMIT */
		st64(64'h9);
		st(32'd1);
		st64(64'h1);
		st(32'd4);
		st64(64'h0);
		st(32'd0);
		st64(64'h0);
		st64(64'h0);
		st(32'd1);
		st64(64'h1);
		st64(64'h400);
		st(32'd0);
		st64(64'h0);
		st64(64'h0);
		ring_frame(12);
		ring_fence;
		doorbell_and_wait("class V frame, 12 rec");
		expect_mem(RING_RESULT, 32'd0, "GHCI_HEAP status");
		expect_mem(RING_RESULT + 8, 32'd0, "GHCI_SESSION_OPEN status");

		/* The two areas are equal, and as the model says. */
		for (k = 0; k < AREA_BYTES / 4; k = k + 1) begin
			v = mem.peek32(AREA_V + k * 4);
			if (v !== mem.peek32(AREA_N + k * 4)) begin
				fail_msg("class V and class N areas differ");
				$display("  word %0d: V %h N %h", k, v, mem.peek32(AREA_N + k * 4));
				k = AREA_BYTES;
			end
		end
		for (k = 0; k < AREA_BYTES / 4; k = k + 1) begin
			model = pattern(k);
			if (k < FILL_WORDS)
				model = FILL_DATA;
			if (k >= 32'h1000 && k < 32'h1000 + COPY_BYTES / 4)
				model = FILL_DATA;
			if (k == 32'h1000 + COPY_BYTES / 4) begin
				w16 = pattern(k);
				model = {w16[31:16], FILL_DATA[15:0]};
			end
			v = mem.peek32(AREA_V + k * 4);
			if (v !== model) begin
				fail_msg("class V area against the model");
				$display("  word %0d: %h, expected %h", k, v, model);
				k = AREA_BYTES;
			end
		end

		/* Every record succeeded; the recorded ones have none; the frame's result. */
		for (k = 0; k < 12; k = k + 1) begin
			if (k == 8 || k == 9)
				expect_result(k, NO_RESULT, NO_RESULT);
			else
				expect_result(k, 32'd0, 32'd0);
		end
		expect_mem(FRAME_RESULT, 32'd0, "frame status");
		expect_mem(FRAME_RESULT + 4, 32'd12, "frame records");
		expect_reg(GHCI_IRQ_STATUS, (32'd1 << GHCI_IRQ_RESULT) | (32'd1 << 8), 32'h180);
		if (!irq)
			fail_msg("no interrupt for the frame");
		host_write(GHCI_IRQ_STATUS, 32'h1FF);
		if (errors == 0)
			$display("PASS atg_top_fw(%0s).frame", NAME);

		/* A frame with an unknown command: it ends there. */
		sp = 0;
		for (k = 0; k < 64; k = k + 1)
			mem.poke32(RESULTS + k * 4, NO_RESULT);
		rec(32'd9999, 0);
		rec(32'h00010101, 1);	/* GHCI_SESSION_CLOSE: must not run */
		st(TAG);
		ring_frame(2);
		ring_fence;
		doorbell_and_wait("frame, unknown command");
		expect_result(0, VK_FEATURE_NOT_PRESENT, 32'd0);
		expect_result(1, NO_RESULT, NO_RESULT);
		expect_mem(FRAME_RESULT, VK_FEATURE_NOT_PRESENT, "stopped frame status");
		expect_mem(FRAME_RESULT + 4, 32'd1, "stopped frame records");
		if (errors == 0)
			$display("PASS atg_top_fw(%0s).unknown", NAME);

		/* The watchdog on a class V packet nothing takes, then RESET restarts the firmware. */
		host_write(GHCI_CPFW_CTRL, 32'd0);	/* RUN 0: the core stops */
		wait_reg(GHCI_CPFW_STATUS, 32'h08, 32'h08, 200);
		host_write(GHCI_WDT_CYCLES, 32'd3000);
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_WDT_EN));
		sp = 0;
		rec(32'h00010101, 0);
		st(TAG);
		ring_frame(1);
		host_write(GHCI_RING_WPTR, wp);
		wait_reg(GHCI_STATUS, 32'd4 << GHCI_STATUS_STATE, 32'hF << GHCI_STATUS_STATE, 2000);
		expect_reg(GHCI_FAULT_INFO, {16'd0, GHCI_FAULT_WATCHDOG, 12'd0}, 32'h0000F000);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RESET);
		wait_reg(GHCI_STATUS, 32'd0, 32'hF << GHCI_STATUS_STATE, 2000);
		wp = 0;
		host_write(GHCI_IRQ_STATUS, 32'h1FF);
		mem.poke32(FENCES, fence_value);
		host_write(GHCI_FENCE_LAST, fence_value);
		host_write(GHCI_CPFW_CTRL, 32'd1 << GHCI_CPFW_CTRL_RUN);
		wait_reg(GHCI_CPFW_STATUS, 32'h0201, 32'hFF09, 20000);
		expect_reg(GHCI_CPFW_MBOX0 + 12, DATA_CHECK, 32'hFFFFFFFF);	/* .data restored */
		if (errors == 0)
			$display("PASS atg_top_fw(%0s).watchdog", NAME);

		/* CPFW LOAD: zeros fault at PC 0, then the image with a changed .data word. */
		host_write(GHCI_CPFW_CTRL, 32'd0);
		wait_reg(GHCI_CPFW_STATUS, 32'h08, 32'h08, 200);
		for (k = 0; k < 64; k = k + 1)
			mem.poke32(IMG_I + k * 4, 32'd0);
		host_write(GHCI_CPFW_IBASE, IMG_I);
		host_write(GHCI_CPFW_IWORDS, 32'd64);
		host_write(GHCI_CPFW_DBASE, IMG_D);
		host_write(GHCI_CPFW_DWORDS, 32'd16);
		host_write(GHCI_CPFW_CTRL, (32'd1 << GHCI_CPFW_CTRL_LOAD) | (32'd1 << GHCI_CPFW_CTRL_RUN));
		wait_reg(GHCI_CPFW_STATUS, 32'h03, 32'h03, 2000);	/* READY, FAULT */
		expect_reg(GHCI_FAULT_INFO, {16'd0, GHCI_FAULT_WATCHDOG, 12'd0}, 32'h0000F000);
		expect_reg(GHCI_FAULT_ADDR, 32'd0, 32'hFFFFFFFF);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RESET);
		wait_reg(GHCI_STATUS, 32'd0, 32'hF << GHCI_STATUS_STATE, 2000);
		$readmemh(IMEM, img, 0, IMEM_WORDS - 1);
		put_image(IMG_I, IMEM_WORDS);
		$readmemh(DMEM, img, 0, DMEM_WORDS - 1);
		/* The .data original: the word after .rodata that holds DATA_CHECK. */
		for (k = 0; k < DMEM_WORDS; k = k + 1) begin
			if (img[k] === DATA_CHECK)
				img[k] = DATA_CHECK + 1;
		end
		put_image(IMG_D, DMEM_WORDS);
		host_write(GHCI_CPFW_IWORDS, IMEM_WORDS);
		host_write(GHCI_CPFW_DWORDS, DMEM_WORDS);
		host_write(GHCI_CPFW_CTRL, (32'd1 << GHCI_CPFW_CTRL_LOAD) | (32'd1 << GHCI_CPFW_CTRL_RUN));
		wait_reg(GHCI_CPFW_STATUS, 32'h0201, 32'hFF0B, 80000);	/* the load of the whole IMEM, then the boot */
		expect_reg(GHCI_CPFW_MBOX0 + 12, DATA_CHECK + 1, 32'hFFFFFFFF);

		/* The reloaded firmware runs a frame (a fill of the second buffer's start). */
		wp = 0;
		host_write(GHCI_IRQ_STATUS, 32'h1FF);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RUN);
		sp = 0;
		for (k = 0; k < 64; k = k + 1)
			mem.poke32(RESULTS + k * 4, NO_RESULT);
		for (k = 0; k < 4; k = k + 1)
			mem.poke32(RING_RESULT + k * 4, NO_RESULT);
		ring_heap;
		ring_session_open;
		rec(32'h00010102, 0);
		st64(64'h100);
		st64(AREA_V);
		st64(AREA_BYTES);
		st(32'd0);
		ring_frame(1);
		ring_fence;
		doorbell_and_wait("reloaded frame");
		expect_mem(RING_RESULT, 32'd0, "reloaded GHCI_HEAP status");
		expect_mem(RING_RESULT + 8, 32'd0, "reloaded GHCI_SESSION_OPEN status");
		expect_result(0, 32'd0, 32'd0);
		expect_mem(FRAME_RESULT + 4, 32'd1, "reloaded frame records");
		if (errors == 0)
			$display("PASS atg_top_fw(%0s).reload", NAME);

		finished = 1'b1;
	end
endmodule

module atg_top_fw_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	wire done_kc705;
	wire [31:0] err_kc705;

	always #5 clk = !clk;

	atg_top_fw_harness #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .NAME("kc705"),
		.IMEM("fw/cp/images/atg1-cp-kc705.imem.hex"), .DMEM("fw/cp/images/atg1-cp-kc705.dmem.hex"),
		.SEED(6)) kc705 (
		.clk(clk), .rst_n(rst_n), .finished(done_kc705), .errors(err_kc705)
	);

	initial begin
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		wait (done_kc705);
		if (err_kc705 == 0)
			$display("PASS atg_top_fw");
		else
			$display("FAIL atg_top_fw: %0d errors", err_kc705);
		$finish;
	end

	initial begin
		#100000000;
		$display("FAIL atg_top_fw: timeout");
		$finish;
	end
endmodule

`default_nettype wire
