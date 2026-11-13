/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_tb: the GPU with CP v0, BLT and MC, driven
 * only through its host port, as a host driver would, against
 * axi_mem; in the KC705's shape (64-byte lines, 512-bit AXI).  Checks:
 *
 *   - the identification registers, SCRATCH, CAPS, the capability list;
 *   - command ring execution: FILL and COPY (different alignments, clipping),
 *     16-bit pixels, blend-over, TILE/UNTILE, overlapping copies in both
 *     directions, against a reference model of memory, then random blits
 *     of every kind;
 *   - an aperture fault: FAULTED, FAULT_INFO, IRQ, then RESET: IDLE,
 *     and a FILL works again;
 *   - unsupported operations (refused pixel size): fault invalid opcode;
 *   - HALT/HALTED, IRQ_SET/W1C and the interrupt line;
 *   - Ring wrap-around, RESULT, WAIT_IDLE, WAIT_FENCE, STEP and watchdog timer.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_top_harness #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter DATA_W = 64,
	parameter NAME = "dut",
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	output reg finished,
	output integer errors
);
	`include "ghci_regs.vh"

	localparam [3:0] LS4 = LINE_SHIFT;
	integer seed;

	reg [16:0] h_awaddr = 0;
	reg [11:0] h_awid = 0;
	reg h_awvalid = 1'b0;
	wire h_awready;
	reg [63:0] h_wdata = 0;
	reg [7:0] h_wstrb = 0;
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
	wire [63:0] h_rdata;
	wire [11:0] h_rid;
	wire [1:0] h_rresp;
	wire h_rlast;
	wire h_rvalid;
	reg h_rready = 1'b0;
	wire irq;

	wire [63:0] awaddr, araddr;
	wire [7:0] awlen, arlen;
	wire [2:0] awsize, arsize, awprot, arprot;
	wire [1:0] awburst, arburst, bresp, rresp;
	wire [3:0] awcache, arcache;
	wire awvalid, awready, wlast, wvalid, wready, bvalid, bready;
	wire arvalid, arready, rlast, rvalid, rready;
	wire [DATA_W-1:0] wdata, rdata;
	wire [DATA_W/8-1:0] wstrb;

	/* The reference of 0x20000..0x5FFFF (64 Ki words). */
	localparam [31:0] REF_BASE = 32'h00020000;
	localparam REF_WORDS = 65536;
	reg [31:0] refm [0:REF_WORDS-1];

	atg_top #(
		.GCLK_HZ(32'd100000000),
		.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .DATA_W(DATA_W),
		.APERTURE_BASE_INIT(REF_BASE), .APERTURE_LIMIT_INIT(REF_BASE + REF_WORDS * 4),
		.HAS_BLT(1), .HAS_L2(0),
		.BLT_BLEND(1), .BLT_TILE(1), .BLT_SCALE(1)
	) dut (
		.clk(clk), .rst_n(rst_n), .irq(irq), .mem_ready(1'b1),
		.s_awaddr(h_awaddr), .s_awid(h_awid), .s_awvalid(h_awvalid), .s_awready(h_awready),
		.s_wdata(h_wdata), .s_wstrb(h_wstrb), .s_wlast(h_wlast), .s_wvalid(h_wvalid),
		.s_wready(h_wready), .s_bid(h_bid), .s_bresp(h_bresp), .s_bvalid(h_bvalid),
		.s_bready(h_bready), .s_araddr(h_araddr), .s_arid(h_arid), .s_arlen(h_arlen),
		.s_arvalid(h_arvalid), .s_arready(h_arready), .s_rdata(h_rdata), .s_rid(h_rid),
		.s_rresp(h_rresp), .s_rlast(h_rlast), .s_rvalid(h_rvalid), .s_rready(h_rready),
		.m_awid(), .m_bid(1'b0), .m_arid(), .m_rid(1'b0),
		.m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(awburst),
		.m_awcache(awcache), .m_awprot(awprot), .m_awvalid(awvalid), .m_awready(awready),
		.m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid),
		.m_wready(wready), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
		.m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(arburst),
		.m_arcache(arcache), .m_arprot(arprot), .m_arvalid(arvalid), .m_arready(arready),
		.m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast), .m_rvalid(rvalid),
		.m_rready(rready),
		/* Nothing outside the GPU here. */
		.xr_wr(), .xr_waddr(), .xr_wdata(), .xr_wstrb(), .xr_rd(), .xr_raddr(),
		.xr_rdata(32'd0),
		.x_req_valid(1'b0), .x_req_ready(), .x_req_write(1'b0), .x_req_line({(32-LINE_SHIFT){1'b0}}),
		.x_req_be({LINE_BYTES{1'b0}}), .x_req_wdata({(LINE_BYTES*8){1'b0}}), .x_req_tag(8'd0),
		.x_rsp_valid(), .x_rsp_write(), .x_rsp_tag(), .x_rsp_rdata(), .x_rsp_error(),
		.x_vsync(1'b0),
		.pclk(1'b0), .prst_n(1'b0), .scl_i(1'b1), .sda_i(1'b1),
		.j_wr(1'b0), .j_waddr(17'd0), .j_wdata(32'd0), .j_wstrb(4'd0), .j_rd(1'b0),
		.j_raddr(17'd0), .j_rdata(), .j_busy()
	);

	axi_mem #(.DATA_W(DATA_W), .MEM_BYTES(1 << 19), .READ_EARLY(1), .SEED(SEED + 7)) mem (
		.clk(clk), .rst_n(rst_n),
		.awaddr(awaddr[31:0]), .awlen(awlen), .awsize(awsize), .awburst(awburst),
		.awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
		.wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp),
		.bvalid(bvalid), .bready(bready), .araddr(araddr[31:0]), .arlen(arlen),
		.arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
		.rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
	);

	`include "axi_host.vh"

	task fail_msg;
		input [8*80-1:0] what;
		begin
			errors = errors + 1;
			$display("FAIL atg_top(%0s): %0s", NAME, what);
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
				$display("FAIL atg_top(%0s): reg %h = %h, expected %h (mask %h)", NAME,
					off, got, want, mask);
			end
		end
	endtask

	task wait_status_clear;
		input [31:0] bits;
		reg [31:0] st;
		integer n;
		begin
			n = 0;
			host_read(GHCI_STATUS, st);
			while ((st & bits) != 0 && n < 5000) begin
				host_read(GHCI_STATUS, st);
				n = n + 1;
			end
			if ((st & bits) != 0)
				fail_msg("STATUS bits do not clear");
		end
	endtask

	/* The ring: 1 KiB at RING, fences in the page FENCES. */
	localparam [31:0] RING = 32'h0005F000;
	localparam [31:0] FENCES = 32'h0005EF00;
	localparam RING_N = 1024;
	integer wp;	/* the driver's write pointer */
	integer fence_seq;

	task wait_reg;
		input [31:0] off;
		input [31:0] want;
		input [31:0] mask;
		reg [31:0] got;
		integer n;
		begin
			n = 0;
			host_read(off, got);
			while ((got & mask) != (want & mask) && n < 5000) begin
				host_read(off, got);
				n = n + 1;
			end
			if ((got & mask) != (want & mask)) begin
				errors = errors + 1;
				$display("FAIL atg_top(%0s): reg %h stays %h, waiting for %h (mask %h)", NAME,
					off, got, want, mask);
			end
		end
	endtask

	/* A word of GPU memory, in the memory and the reference. */
	task mem_put;
		input [31:0] addr;
		input [31:0] value;
		begin
			mem.poke32(addr, value);
			refm[(addr - REF_BASE) / 4] = value;
		end
	endtask

	task ring_put;
		input [31:0] value;
		begin
			mem_put(RING + wp * 4, value);
			wp = (wp + 1) % RING_N;
		end
	endtask

	task ring_reserve;
		input integer count;
		integer pad;
		begin
			if (wp + count > RING_N) begin
				pad = RING_N - wp - 1;
				ring_put({2'b11, 14'd0, pad[15:0]});
				wp = 0;
			end
		end
	endtask

	/* Class N headers: {class, op, tag, flags, n}. */
	function [31:0] hdr;
		input vendor;
		input [5:0] op;
		input [7:0] tag;
		input [7:0] flags;
		input [7:0] n;
		hdr = {1'b0, vendor, op, tag, flags, n};
	endfunction

	task ring_set;
		input [8:0] idx;
		input [31:0] value;
		begin
			ring_put({23'd0, idx});
			ring_put(value);
		end
	endtask

	task ring_fence;
		input [7:0] tag;
		input [31:0] value;
		begin
			ring_put(hdr(1'b0, 6'd5, tag, 8'd1, 8'd2));
			ring_put(FENCES);
			ring_put(value);
		end
	endtask

	task state_write;
		input [8:0] idx;
		input [31:0] value;
		begin
			ring_put(hdr(1'b0, 6'd1, 8'h01, 8'd0, 8'd2));
			ring_set(idx, value);
			host_write(GHCI_RING_WPTR, wp);
		end
	endtask

	/* A pixel of the reference: 32 bits, or 16 at a 2-byte address. */
	task ref_get;
		input [31:0] addr;
		input is16;
		output [31:0] v;
		reg [31:0] word;
		begin
			word = refm[(addr - REF_BASE) >> 2];
			v = !is16 ? word : addr[1] ? {16'd0, word[31:16]} : {16'd0, word[15:0]};
		end
	endtask

	task ref_put;
		input [31:0] addr;
		input is16;
		input [31:0] v;
		integer k2;
		begin
			k2 = (addr - REF_BASE) >> 2;
			if (!is16)
				refm[k2] = v;
			else if (addr[1])
				refm[k2][31:16] = v[15:0];
			else
				refm[k2][15:0] = v[15:0];
		end
	endtask

	/* The byte address of pixel (x, y): linear, or in 4x4 tiles. */
	function [31:0] pix_addr;
		input [31:0] base;
		input [31:0] stride;
		input integer x;
		input integer y;
		input tiled;
		input integer ps;
		begin
			if (tiled)
				pix_addr = base + (y / 4) * stride + (x / 4) * 16 * ps +
					((y % 4) * 4 + x % 4) * ps;
			else
				pix_addr = base + y * stride + x * ps;
		end
	endfunction

	/* Source-over with premultiplied alpha. */
	function [31:0] over;
		input [31:0] sp;
		input [31:0] dp;
		integer ch, t, q;
		begin
			for (ch = 0; ch < 4; ch = ch + 1) begin
				t = dp[ch*8 +: 8] * (255 - sp[31:24]);
				q = sp[ch*8 +: 8] + (t + 127) / 255;
				over[ch*8 +: 8] = q > 255 ? 8'hFF : q;
			end
		end
	endfunction

	reg [31:0] tmp [0:8191];

	/* One blit, and the same in the reference: every source pixel is
	 * read before any is written (what an overlapping copy in the right
	 * direction gives). */
	task blit;
		input [31:0] opw;
		input [31:0] dst, dstride, src, sstride;
		input [15:0] dx, dy, sx, sy, w, h;
		input [31:0] color;
		input [31:0] cmin, cmax;
		integer x, y, x0, y0, x1, y1, ps, i;
		reg is16, dtile, stile;
		reg [31:0] v, d, mask;
		begin
			ring_reserve(27);
			ring_put(hdr(1'b0, 6'd1, 8'h10, 8'd0, 8'd22));
			ring_set(GHCI_S_BLT_OP, opw);
			ring_set(GHCI_S_BLT_DST_BASE, dst);
			ring_set(GHCI_S_BLT_DST_STRIDE, dstride);
			ring_set(GHCI_S_BLT_SRC_BASE, src);
			ring_set(GHCI_S_BLT_SRC_STRIDE, sstride);
			ring_set(GHCI_S_BLT_DST_XY, {dy, dx});
			ring_set(GHCI_S_BLT_SRC_XY, {sy, sx});
			ring_set(GHCI_S_BLT_SIZE, {h, w});
			ring_set(GHCI_S_BLT_COLOR, color);
			ring_set(GHCI_S_BLT_CLIP_MIN, cmin);
			ring_set(GHCI_S_BLT_CLIP_MAX, cmax);
			ring_put(hdr(1'b0, 6'd2, 8'h11, 8'd1, 8'd0));
			fence_seq = fence_seq + 1;
			ring_fence(8'h12, fence_seq);
			refm[(FENCES - REF_BASE) / 4] = fence_seq;
			host_write(GHCI_RING_WPTR, wp);
			wait_reg(GHCI_LEGACY_FENCE_LAST, fence_seq, 32'hFFFFFFFF);
			is16 = opw[8];
			ps = is16 ? 2 : 4;
			mask = is16 ? 32'hFFFFFFFE : 32'hFFFFFFFC;
			dtile = opw[1:0] == GHCI_BLT_TILE;
			stile = opw[1:0] == GHCI_BLT_UNTILE;
			x0 = dx;
			y0 = dy;
			x1 = dx + w;
			y1 = dy + h;
			if (cmax != 0) begin
				if (cmin[15:0] > x0) x0 = cmin[15:0];
				if (cmin[31:16] > y0) y0 = cmin[31:16];
				if (cmax[15:0] < x1) x1 = cmax[15:0];
				if (cmax[31:16] < y1) y1 = cmax[31:16];
			end
			i = 0;
			for (y = y0; y < y1; y = y + 1)
				for (x = x0; x < x1; x = x + 1) begin
					if (opw[1:0] == GHCI_BLT_FILL)
						v = is16 ? {16'd0, color[15:0]} : color;
					else
						ref_get(pix_addr(src & mask, sstride & mask, sx + x - dx,
							sy + y - dy, stile, ps), is16, v);
					tmp[i] = v;
					i = i + 1;
				end
			i = 0;
			for (y = y0; y < y1; y = y + 1)
				for (x = x0; x < x1; x = x + 1) begin
					v = tmp[i];
					i = i + 1;
					if (opw[GHCI_BLT_OP_BLEND]) begin
						ref_get(pix_addr(dst & mask, dstride & mask, x, y, 1'b0, ps),
							is16, d);
						v = over(v, d);
					end
					ref_put(pix_addr(dst & mask, dstride & mask, x, y, dtile, ps), is16, v);
				end
		end
	endtask

	/* A forward 32-bit COPY in the wrong direction (the destination after
	 * the source in one row: a smear), modelled as the blitter does it:
	 * segment by segment (one destination line each), each reading memory
	 * as the earlier segments left it.  This shows that a read waits for
	 * the earlier writes to its lines. */
	task smear;
		input [31:0] base, stride;
		input [15:0] sx, dx, y, w;
		integer x, xs, k;
		reg [31:0] seg [0:15];
		begin
			ring_reserve(23);
			ring_put(hdr(1'b0, 6'd1, 8'h13, 8'd0, 8'd18));
			ring_set(GHCI_S_BLT_OP, 32'd1);
			ring_set(GHCI_S_BLT_DST_BASE, base);
			ring_set(GHCI_S_BLT_DST_STRIDE, stride);
			ring_set(GHCI_S_BLT_SRC_BASE, base);
			ring_set(GHCI_S_BLT_SRC_STRIDE, stride);
			ring_set(GHCI_S_BLT_DST_XY, {y, dx});
			ring_set(GHCI_S_BLT_SRC_XY, {y, sx});
			ring_set(GHCI_S_BLT_SIZE, {16'd1, w});
			ring_set(GHCI_S_BLT_CLIP_MAX, 0);
			ring_put(hdr(1'b0, 6'd2, 8'h14, 8'd1, 8'd0));
			fence_seq = fence_seq + 1;
			ring_fence(8'h15, fence_seq);
			refm[(FENCES - REF_BASE) / 4] = fence_seq;
			host_write(GHCI_RING_WPTR, wp);
			wait_reg(GHCI_LEGACY_FENCE_LAST, fence_seq, 32'hFFFFFFFF);
			x = dx;
			while (x < dx + w) begin
				xs = x;
				k = 0;
				while (x < dx + w && (k == 0 ||
				    ((base + y * stride + x * 4) >> LINE_SHIFT) ==
				    ((base + y * stride + xs * 4) >> LINE_SHIFT))) begin
					seg[k] = refm[(base + y * stride + (sx + x - dx) * 4 - REF_BASE) / 4];
					k = k + 1;
					x = x + 1;
				end
				for (k = 0; xs + k < x; k = k + 1)
					refm[(base + y * stride + (xs + k) * 4 - REF_BASE) / 4] = seg[k];
			end
		end
	endtask

	task compare_ref;
		input [8*40-1:0] what;
		integer k, bad;
		reg [31:0] got;
		begin
			bad = 0;
			for (k = 0; k < REF_WORDS; k = k + 1) begin
				got = mem.peek32(REF_BASE + k * 4);
				if (got !== refm[k]) begin
					if (bad < 5)
						$display("FAIL atg_top(%0s): %0s: %h = %h, expected %h", NAME, what,
							REF_BASE + k * 4, got, refm[k]);
					bad = bad + 1;
				end
			end
			if (bad != 0) begin
				errors = errors + 1;
				$display("FAIL atg_top(%0s): %0s: %0d words differ", NAME, what, bad);
			end
		end
	endtask

	/* A FILL through the ring: 11 SET_REG pairs and BLIT, into the reference. */
	task ring_fill;
		input [31:0] dst;
		input [31:0] stride;
		input [15:0] x;
		input [15:0] y;
		input [15:0] w;
		input [15:0] h;
		input [31:0] color;
		integer i, j;
		begin
			ring_reserve(27);
			ring_put(hdr(1'b0, 6'd1, 8'h21, 8'd0, 8'd22));
			ring_set(GHCI_S_BLT_OP, {30'd0, GHCI_BLT_FILL});
			ring_set(GHCI_S_BLT_DST_BASE, dst);
			ring_set(GHCI_S_BLT_DST_STRIDE, stride);
			ring_set(GHCI_S_BLT_SRC_BASE, 0);
			ring_set(GHCI_S_BLT_SRC_STRIDE, 0);
			ring_set(GHCI_S_BLT_DST_XY, {y, x});
			ring_set(GHCI_S_BLT_SRC_XY, 0);
			ring_set(GHCI_S_BLT_SIZE, {h, w});
			ring_set(GHCI_S_BLT_COLOR, color);
			ring_set(GHCI_S_BLT_CLIP_MIN, 0);
			ring_set(GHCI_S_BLT_CLIP_MAX, 0);
			ring_put(hdr(1'b0, 6'd2, 8'h22, 8'd1, 8'd0));
			for (j = 0; j < h; j = j + 1)
				for (i = 0; i < w; i = i + 1)
					refm[(dst + (y + j) * stride + (x + i) * 4 - REF_BASE) / 4] = color;
		end
	endtask

	task reset_gpu;
		reg [31:0] ctrl_val;
		begin
			host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RESET);
			ctrl_val = 32'd1;
			while (ctrl_val[0]) begin
				host_read(GHCI_CTRL, ctrl_val);
			end
			host_write(GHCI_IRQ_STATUS, 32'h1FF);
			wp = 0;
		end
	endtask

	integer k, n;
	reg [31:0] v;
	reg [31:0] dst, src, ds, ss;
	reg [15:0] dx, dy, sx, sy, w, h;
	reg [31:0] cmin, cmax;
	reg [31:0] opw;
	integer ps;

	initial begin
		finished = 1'b0;
		errors = 0;
		seed = SEED;
		if ($value$plusargs("seed=%d", k))
			seed = SEED + 1000 * k;
		for (k = 0; k < REF_WORDS; k = k + 1) begin
			v = $random(seed);
			refm[k] = v;
			mem.poke32(REF_BASE + k * 4, v);
		end
		wait (rst_n);
		repeat (3) @(posedge clk);

		/* Identification. */
		expect_reg(GHCI_MAGIC, 32'h47484349, 32'hFFFFFFFF);
		expect_reg(GHCI_VERSION, {GHCI_VERSION_MAJOR, GHCI_VERSION_MINOR}, 32'hFFFFFFFF);
		expect_reg(GHCI_VENDOR_ID, 32'h414D4154, 32'hFFFFFFFF);
		expect_reg(GHCI_DEVICE_ID, 32'h41544731, 32'hFFFFFFFF);
		expect_reg(GHCI_NATIVE_ISA_ID, 32'h47534931, 32'hFFFFFFFF);
		expect_reg(GHCI_GCLK_HZ, 32'd100000000, 32'hFFFFFFFF);
		expect_reg(GHCI_DEVICE_CAPS, 32'h20000480, 32'hFFFFFFFF);
		expect_reg(GHCI_DEVICE_VERSION, 32'h00010000, 32'hFFFFFFFF);

		/* The capability list: PERF, VEND, FMT. */
		expect_reg(GHCI_EXTCAP, 32'h00000100, 32'hFFFFFFFF);
		expect_reg(32'h0000_0100, {16'd2, 8'd1, GHCI_XCAP_PERF}, 32'hFFFFFFFF);
		expect_reg(32'h0000_0104, 32'h00000160, 32'hFFFFFFFF);
		expect_reg(32'h0000_0108, {16'd2, 8'd1, GHCI_XCAP_VEND}, 32'hFFFFFFFF);
		expect_reg(32'h0000_010C, 32'h00000180, 32'hFFFFFFFF);
		expect_reg(32'h0000_0110, {16'd0, 8'd1, GHCI_XCAP_FMT}, 32'hFFFFFFFF);
		expect_reg(32'h0000_0114, 32'h00000140, 32'hFFFFFFFF);

		/* Scratchpad register test. */
		host_write(GHCI_SCRATCH, 32'hCAFEF00D);
		expect_reg(GHCI_SCRATCH, 32'hCAFEF00D, 32'hFFFFFFFF);
		host_write_strb(GHCI_SCRATCH, 32'h11223344, 4'b1000);
		expect_reg(GHCI_SCRATCH, 32'h11FEF00D, 32'hFFFFFFFF);
		expect_reg(GHCI_STATUS, (32'd1 << GHCI_STATUS_AXI_IDLE) | (32'd1 << GHCI_STATUS_MEM_READY),
			(32'd1 << GHCI_STATUS_AXI_IDLE) | (32'd1 << GHCI_STATUS_MEM_READY));

		/* Command ring bring-up. */
		wp = 0;
		fence_seq = 0;
		host_write(GHCI_RING_BASE, RING);
		host_write(GHCI_RING_SIZE, 32'h00001000);
		expect_reg(GHCI_RING_SIZE, 32'h00001000, 32'hFFFFFFFF);
		host_write(GHCI_IRQ_STATUS, 32'h1FF);
		host_write(GHCI_IRQ_ENABLE, (32'd1 << GHCI_IRQ_FENCE) | (32'd1 << GHCI_IRQ_FAULT));
		mem_put(FENCES, 32'd0);
		host_write(GHCI_LEGACY_FENCE_LAST, 32'd0);
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));
		expect_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_RUNNING, 32'd1 << GHCI_STATUS_RUNNING);

		/* FILL, COPY at other alignments, a clipped FILL. */
		blit(GHCI_BLT_FILL, 32'h00030000, 256, 0, 0, 3, 2, 0, 0, 13, 5, 32'hAABBCCDD, 0, 0);
		compare_ref("fill");
		blit(GHCI_BLT_COPY, 32'h00048004, 1024, 32'h00030008, 256, 2, 3, 5, 1, 17, 4, 0, 0, 0);
		compare_ref("copy");
		blit(GHCI_BLT_COPY, 32'h00050000, 512, 32'h00030000, 256, 9, 0, 1, 0, 30, 7, 0, 0, 0);
		compare_ref("copy 2");
		blit(GHCI_BLT_FILL, 32'h00030000, 256, 0, 0, 0, 0, 0, 0, 40, 9, 32'h01020304,
			{16'd2, 16'd7}, {16'd6, 16'd25});
		compare_ref("clipped fill");

		/* 16-bit pixels: FILL at an odd pixel, COPY at other alignments. */
		blit(32'h100, 32'h00032002, 192, 0, 0, 3, 1, 0, 0, 21, 4, 32'h0000BEEF, 0, 0);
		compare_ref("fill 16");
		blit(32'h101, 32'h00034006, 320, 32'h00032000, 192, 1, 2, 4, 0, 27, 5, 0, 0, 0);
		compare_ref("copy 16");

		/* Blend-over: FILL with a translucent colour, COPY of random
		 * pixels (whose channels may exceed their alpha: saturation). */
		blit(32'h010, 32'h00036000, 256, 0, 0, 2, 1, 0, 0, 19, 3, 32'h80402010, 0, 0);
		compare_ref("fill blend");
		blit(32'h011, 32'h00037004, 256, 32'h00038000, 512, 1, 0, 3, 2, 22, 4, 0, 0, 0);
		compare_ref("copy blend");

		/* TILE then UNTILE: the image comes back. */
		blit({30'd0, GHCI_BLT_TILE}, 32'h0003A000, 4 * 64, 32'h00038000, 512, 1, 2, 0, 0,
			13, 9, 0, 0, 0);
		compare_ref("tile");
		blit({30'd0, GHCI_BLT_UNTILE}, 32'h0003C000, 256, 32'h0003A000, 4 * 64, 0, 0, 1, 2,
			13, 9, 0, 0, 0);
		compare_ref("untile");
		blit(32'h102, 32'h0003D000, 4 * 32, 32'h00032000, 192, 3, 1, 2, 0, 9, 6, 0, 0, 0);
		compare_ref("tile 16");

		/* Overlapping copies in one image: down and right in reverse,
		 * up and left forward, and one 16-bit pixel to the right. */
		blit(32'h1001, 32'h00040000, 256, 32'h00040000, 256, 3, 2, 0, 0, 20, 6, 0, 0, 0);
		compare_ref("overlap reverse");
		blit(32'h0001, 32'h00040000, 256, 32'h00040000, 256, 1, 1, 5, 4, 30, 5, 0, 0, 0);
		compare_ref("overlap forward");
		blit(32'h1101, 32'h00041000, 128, 32'h00041000, 128, 1, 0, 0, 0, 40, 3, 0, 0, 0);
		compare_ref("overlap reverse 16");
		blit(32'h1000, 32'h00042000, 256, 0, 0, 4, 3, 0, 0, 9, 4, 32'h13579BDF,
			{16'd4, 16'd5}, {16'd6, 16'd11});
		compare_ref("reverse clipped fill");
		smear(32'h00043000, 1024, 0, 3, 0, 60);
		smear(32'h00043000, 1024, 2, 3, 1, 61);
		compare_ref("smear");

		/* Random blits of every kind: destinations and sources in
		 * separate halves. */
		for (n = 0; n < 120; n = n + 1) begin
			k = $unsigned($random(seed)) % 8;
			opw = k < 2 ? GHCI_BLT_FILL : k < 5 ? GHCI_BLT_COPY : k < 7 ? GHCI_BLT_TILE :
				GHCI_BLT_UNTILE;
			if ($random(seed) & 1)
				opw = opw | 32'h100;
			if (opw[1] == 1'b0 && !opw[8] && ($unsigned($random(seed)) % 3) == 0)
				opw = opw | 32'h010;
			if (opw[1] == 1'b0 && ($unsigned($random(seed)) % 3) == 0)
				opw = opw | 32'h1000;
			ps = opw[8] ? 2 : 4;
			w = $unsigned($random(seed)) % 41;
			h = 1 + $unsigned($random(seed)) % 10;
			/* Linear images: any stride of 32 bytes, any pixel base;
			 * tiled ones: whole tiles. */
			if (opw[1:0] == GHCI_BLT_TILE) begin
				ds = (1 + $unsigned($random(seed)) % 8) * 16 * ps;
				dst = REF_BASE + ($unsigned($random(seed)) % 256) * 64;
			end else begin
				ds = (1 + $unsigned($random(seed)) % 32) * 32;
				dst = REF_BASE + ($unsigned($random(seed)) % 8192) * 2;
			end
			if (opw[1:0] == GHCI_BLT_UNTILE) begin
				ss = (1 + $unsigned($random(seed)) % 8) * 16 * ps;
				src = REF_BASE + ($unsigned($random(seed)) % 256) * 64;
			end else begin
				ss = (1 + $unsigned($random(seed)) % 32) * 32;
				src = REF_BASE + ($unsigned($random(seed)) % 8192) * 2;
			end
			if ($random(seed) & 1)
				dst = dst + 32'h00020000;
			else
				src = src + 32'h00020000;
			/* Row widths in pixels: a tiled stride holds stride / (4 ps). */
			if (w > (opw[1:0] == GHCI_BLT_TILE ? ds / (4 * ps) : ds / ps))
				w = opw[1:0] == GHCI_BLT_TILE ? ds / (4 * ps) : ds / ps;
			if (w > (opw[1:0] == GHCI_BLT_UNTILE ? ss / (4 * ps) : ss / ps))
				w = opw[1:0] == GHCI_BLT_UNTILE ? ss / (4 * ps) : ss / ps;
			dx = $unsigned($random(seed)) % ((opw[1:0] == GHCI_BLT_TILE ? ds / (4 * ps) :
				ds / ps) - w + 1);
			sx = $unsigned($random(seed)) % ((opw[1:0] == GHCI_BLT_UNTILE ? ss / (4 * ps) :
				ss / ps) - w + 1);
			dy = $unsigned($random(seed)) % 8;
			sy = $unsigned($random(seed)) % 8;
			cmin = 0;
			cmax = 0;
			if (($unsigned($random(seed)) % 4) == 0) begin
				cmin[31:16] = $unsigned($random(seed)) % 8;
				cmin[15:0] = $unsigned($random(seed)) % 16;
				cmax[31:16] = 4 + $unsigned($random(seed)) % 16;
				cmax[15:0] = 8 + $unsigned($random(seed)) % 64;
			end
			blit(opw, dst, ds, src, ss, dx, dy, sx, sy, w, h, $random(seed), cmin, cmax);
		end
		compare_ref("random blits");

		/* HALT in the middle of a COPY, then resume. */
		ring_reserve(27);
		ring_put(hdr(1'b0, 6'd1, 8'h16, 8'd0, 8'd18));
		ring_set(GHCI_S_BLT_OP, {30'd0, GHCI_BLT_COPY});
		ring_set(GHCI_S_BLT_DST_BASE, 32'h00044000);
		ring_set(GHCI_S_BLT_DST_STRIDE, 512);
		ring_set(GHCI_S_BLT_SRC_BASE, 32'h00020104);
		ring_set(GHCI_S_BLT_SRC_STRIDE, 256);
		ring_set(GHCI_S_BLT_DST_XY, {16'd2, 16'd3});
		ring_set(GHCI_S_BLT_SRC_XY, {16'd1, 16'd0});
		ring_set(GHCI_S_BLT_SIZE, {16'd20, 16'd50});
		ring_set(GHCI_S_BLT_CLIP_MAX, 0);
		ring_put(hdr(1'b0, 6'd2, 8'h17, 8'd1, 8'd0));
		fence_seq = fence_seq + 1;
		ring_fence(8'h18, fence_seq);
		refm[(FENCES - REF_BASE) / 4] = fence_seq;
		host_write(GHCI_RING_WPTR, wp);
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_HALT) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));
		wait_reg(GHCI_STATUS, (32'd1 << GHCI_STATUS_HALTED), (32'd1 << GHCI_STATUS_HALTED));
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));
		wait_reg(GHCI_LEGACY_FENCE_LAST, fence_seq, 32'hFFFFFFFF);
		for (n = 2; n < 22; n = n + 1)
			for (k = 3; k < 53; k = k + 1)
				refm[(32'h00044000 + n * 512 + k * 4 - REF_BASE) / 4] =
					refm[(32'h00020104 + (n - 1) * 256 + (k - 3) * 4 - REF_BASE) / 4];
		compare_ref("copy with a pause");

		/* An aperture fault, then RESET. */
		host_write(GHCI_IRQ_STATUS, 32'h1FF);
		host_write(GHCI_IRQ_ENABLE, 32'd1 << GHCI_IRQ_FAULT);
		ring_reserve(23);
		ring_put(hdr(1'b0, 6'd1, 8'h19, 8'd0, 8'd10));
		ring_set(GHCI_S_BLT_OP, {30'd0, GHCI_BLT_FILL});
		ring_set(GHCI_S_BLT_DST_BASE, 32'h00070000);
		ring_set(GHCI_S_BLT_DST_XY, 0);
		ring_set(GHCI_S_BLT_SIZE, {16'd2, 16'd8});
		ring_set(GHCI_S_BLT_CLIP_MAX, 0);
		ring_put(hdr(1'b0, 6'd2, 8'h1A, 8'd0, 8'd0));
		host_write(GHCI_RING_WPTR, wp);
		wait_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_FAULT, 32'd1 << GHCI_STATUS_FAULT);
		expect_reg(GHCI_FAULT_ADDR, 32'h00070000, 32'hFFFFFFFF);
		expect_reg(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_FAULT, 32'd1 << GHCI_IRQ_FAULT);
		if (!irq)
			fail_msg("no interrupt for the fault");
		reset_gpu();
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));
		expect_reg(GHCI_STATUS, 32'd0, 32'd1 << GHCI_STATUS_FAULT);
		expect_reg(GHCI_FAULT_INFO, 32'd0, 32'hFFFFFFFF);
		expect_reg(GHCI_IRQ_STATUS, 32'd0, 32'hFFFFFFFF);
		if (irq)
			fail_msg("interrupt after RESET");
		blit(GHCI_BLT_FILL, 32'h00031000, 128, 0, 0, 1, 1, 0, 0, 5, 3, 32'h0BADF00D, 0, 0);
		compare_ref("fill after reset");

		/* Unsupported operations: pixel size refused (BLT_OP[13] with 16-bit). */
		ring_reserve(10);
		ring_put(hdr(1'b0, 6'd1, 8'h1B, 8'd0, 8'd2));
		ring_set(GHCI_S_BLT_OP, 32'h2100);
		ring_put(hdr(1'b0, 6'd2, 8'h1C, 8'd0, 8'd0));
		host_write(GHCI_RING_WPTR, wp);
		wait_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_FAULT, 32'd1 << GHCI_STATUS_FAULT);
		expect_reg(GHCI_FAULT_INFO, {16'd0, 8'h1C, GHCI_FAULT_UNIT_BLT, GHCI_FAULT_KIND_INVALID_OP}, 32'hFFFFFFFF);
		reset_gpu();
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));

		/* Unsupported operation: blend-over of a tile. */
		ring_reserve(10);
		ring_put(hdr(1'b0, 6'd1, 8'h1D, 8'd0, 8'd2));
		ring_set(GHCI_S_BLT_OP, 32'h012);
		ring_put(hdr(1'b0, 6'd2, 8'h1E, 8'd0, 8'd0));
		host_write(GHCI_RING_WPTR, wp);
		wait_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_FAULT, 32'd1 << GHCI_STATUS_FAULT);
		expect_reg(GHCI_FAULT_INFO, {16'd0, 8'h1E, GHCI_FAULT_UNIT_BLT, GHCI_FAULT_KIND_INVALID_OP}, 32'hFFFFFFFF);
		reset_gpu();
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));

		/* HALT, the soft interrupt. */
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_HALT);
		expect_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_HALTED, 32'd1 << GHCI_STATUS_HALTED);
		expect_reg(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_HALTED, 32'hFFFFFFFF);
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));
		host_write(GHCI_IRQ_STATUS, 32'h1FF);
		host_write(GHCI_IRQ_ENABLE, 32'd1 << GHCI_IRQ_SOFT);
		host_write(GHCI_IRQ_SET, 32'd1 << GHCI_IRQ_SOFT);
		expect_reg(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_SOFT, 32'hFFFFFFFF);
		if (!irq)
			fail_msg("no soft interrupt");
		host_write(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_SOFT);
		expect_reg(GHCI_IRQ_STATUS, 32'd0, 32'hFFFFFFFF);
		if (irq)
			fail_msg("soft interrupt not cleared");

		/* X7: IRQ_GLOBAL = 0 test: IRQ_ENABLE[5] = 1, IRQ_SET[5] = 1, CTRL.IRQ_GLOBAL = 0 -> irq = 0.
		   Then CTRL.IRQ_GLOBAL = 1 -> irq = 1. */
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RUN); /* IRQ_GLOBAL = 0 */
		host_write(GHCI_IRQ_STATUS, 32'h1FF);
		host_write(GHCI_IRQ_ENABLE, 32'd1 << GHCI_IRQ_SOFT);
		host_write(GHCI_IRQ_SET, 32'd1 << GHCI_IRQ_SOFT);
		expect_reg(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_SOFT, 32'hFFFFFFFF);
		if (irq)
			fail_msg("irq asserted while IRQ_GLOBAL = 0");
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));
		repeat (2) @(posedge clk);
		if (!irq)
			fail_msg("irq not asserted after IRQ_GLOBAL = 1");
		host_write(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_SOFT);
		expect_reg(GHCI_IRQ_STATUS, 32'd0, 32'hFFFFFFFF);
		if (irq)
			fail_msg("soft interrupt not cleared");

		/* The ring: a FILL and a FENCE with its interrupt. */
		host_write(GHCI_IRQ_STATUS, 32'h1FF);
		host_write(GHCI_IRQ_ENABLE, 32'd1 << GHCI_IRQ_FENCE);
		mem_put(FENCES, 32'd0);
		host_write(GHCI_LEGACY_FENCE_LAST, 32'd0);
		ring_fill(32'h00033000, 256, 2, 1, 7, 4, 32'hC0FFEE01);
		ring_fence(8'h23, 32'd1);
		host_write(GHCI_RING_WPTR, wp);
		wait_reg(GHCI_LEGACY_FENCE_LAST, 32'd1, 32'hFFFFFFFF);
		refm[(FENCES - REF_BASE) / 4] = 32'd1;
		compare_ref("ring fill and fence");
		expect_reg(GHCI_RING_RPTR, wp, 32'hFFFFFFFF);
		expect_reg(GHCI_IRQ_STATUS, (32'd1 << GHCI_IRQ_FENCE), 32'd1 << GHCI_IRQ_FENCE);
		expect_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_RING_EMPTY, 32'd1 << GHCI_STATUS_RING_EMPTY);
		if (!irq)
			fail_msg("no interrupt for the fence");
		host_write(GHCI_IRQ_STATUS, 32'h1FF);

		/* Padding to the ring's end, then RESULT, WAIT_IDLE and a fence at 0. */
		v = RING_N - wp - 1;
		ring_put({2'b11, 14'd0, v[15:0]});
		wp = 0;
		ring_put(hdr(1'b0, 6'd13, 8'h31, 8'd0, 8'd3));
		ring_put(FENCES + 32'h10);
		ring_put(32'hAAAA0001);
		ring_put(32'hBBBB0002);
		ring_put(hdr(1'b0, 6'd6, 8'h32, 8'd0, 8'd0));
		ring_fence(8'h34, 32'd2);
		host_write(GHCI_RING_WPTR, wp);
		wait_reg(GHCI_LEGACY_FENCE_LAST, 32'd2, 32'hFFFFFFFF);
		refm[(FENCES - REF_BASE) / 4] = 32'd2;
		refm[(FENCES + 32'h10 - REF_BASE) / 4] = 32'hAAAA0001;
		refm[(FENCES + 32'h14 - REF_BASE) / 4] = 32'hBBBB0002;
		compare_ref("ring padding, RESULT, fence after the wrap");
		expect_reg(GHCI_RING_RPTR, wp, 32'hFFFFFFFF);

		/* WAIT_FENCE: the next fence waits until memory is updated. */
		mem_put(FENCES + 32'h20, 32'hFFFFFFF0);
		ring_put(hdr(1'b0, 6'd9, 8'h41, 8'd0, 8'd2));
		ring_put(FENCES + 32'h20);
		ring_put(32'h00000005);
		ring_fence(8'h42, 32'd3);
		host_write(GHCI_RING_WPTR, wp);
		repeat (400) @(posedge clk);
		expect_reg(GHCI_LEGACY_FENCE_LAST, 32'd2, 32'hFFFFFFFF);
		mem_put(FENCES + 32'h20, 32'h00000007);
		wait_reg(GHCI_LEGACY_FENCE_LAST, 32'd3, 32'hFFFFFFFF);
		refm[(FENCES - REF_BASE) / 4] = 32'd3;
		compare_ref("WAIT_FENCE");

		/* HALT with an empty ring, two fences, STEP runs one at a time. */
		repeat (10) @(posedge clk);
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_HALT) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));
		wait_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_HALTED, 32'd1 << GHCI_STATUS_HALTED);
		ring_fence(8'h51, 32'd10);
		ring_fence(8'h52, 32'd11);
		host_write(GHCI_RING_WPTR, wp);
		repeat (200) @(posedge clk);
		expect_reg(GHCI_LEGACY_FENCE_LAST, 32'd3, 32'hFFFFFFFF);
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_HALT) |
			(32'd1 << GHCI_CTRL_STEP) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));
		wait_reg(GHCI_LEGACY_FENCE_LAST, 32'd10, 32'hFFFFFFFF);
		repeat (200) @(posedge clk);
		expect_reg(GHCI_LEGACY_FENCE_LAST, 32'd10, 32'hFFFFFFFF);
		expect_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_HALTED, 32'd1 << GHCI_STATUS_HALTED);
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));
		wait_reg(GHCI_LEGACY_FENCE_LAST, 32'd11, 32'hFFFFFFFF);
		refm[(FENCES - REF_BASE) / 4] = 32'd11;
		expect_reg(GHCI_RING_RPTR, wp, 32'hFFFFFFFF);

		/* A class V packet without firmware: fault kind invalid op with its tag. */
		reset_gpu();
		host_write(GHCI_IRQ_ENABLE, 32'd1 << GHCI_IRQ_FAULT);
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));
		ring_put({2'b10, 6'd0, 8'h61, 16'd4});
		ring_put(32'd0);
		ring_put(32'd0);
		ring_put(32'd0);
		ring_put(32'd0);
		host_write(GHCI_RING_WPTR, wp);
		wait_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_FAULT, 32'd1 << GHCI_STATUS_FAULT);
		expect_reg(GHCI_FAULT_INFO, {16'd0, 8'h61, 4'd0, GHCI_FAULT_KIND_INVALID_OP}, 32'hFFFFFFFF);
		expect_reg(GHCI_FAULT_ADDR, RING, 32'hFFFFFFFF);
		expect_reg(GHCI_RING_RPTR, 32'd0, 32'hFFFFFFFF);
		if (!irq)
			fail_msg("no interrupt for the class V fault");

		/* Fault, RESET, recovery: the ring from 0 again. */
		reset_gpu();
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));
		ring_fill(32'h00033800, 128, 0, 0, 3, 2, 32'h0FEEDBAC);
		ring_fence(8'h62, 32'd12);
		host_write(GHCI_RING_WPTR, wp);
		wait_reg(GHCI_LEGACY_FENCE_LAST, 32'd12, 32'hFFFFFFFF);
		refm[(FENCES - REF_BASE) / 4] = 32'd12;
		compare_ref("ring after fault and RESET");

		/* A packet that runs past WPTR: fault kind ring bounds. */
		ring_put(hdr(1'b0, 6'd0, 8'h71, 8'd0, 8'd5));
		host_write(GHCI_RING_WPTR, wp);
		wait_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_FAULT, 32'd1 << GHCI_STATUS_FAULT);
		expect_reg(GHCI_FAULT_INFO, {16'd0, 8'h71, 4'd0, GHCI_FAULT_KIND_BAD_REG}, 32'hFFFFFFFF);
		reset_gpu();

		/* A fence outside the aperture: fault kind of the CP (client 0). */
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));
		ring_put(hdr(1'b0, 6'd5, 8'h81, 8'd0, 8'd2));
		ring_put(32'h00001000);
		ring_put(32'd1);
		host_write(GHCI_RING_WPTR, wp);
		wait_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_FAULT, 32'd1 << GHCI_STATUS_FAULT);
		expect_reg(GHCI_FAULT_INFO, {16'd0, 8'd0, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_FENCE_ERROR}, 32'hFFFFFFFF);
		expect_reg(GHCI_FAULT_ADDR, 32'h00001000, 32'hFFFFFFFF);
		reset_gpu();

		/* The watchdog: a WAIT_FENCE that never passes. */
		host_write(GHCI_WDT_CYCLES, 32'd300);
		host_write(GHCI_IRQ_ENABLE, (32'd1 << GHCI_IRQ_FAULT) | (32'd1 << GHCI_IRQ_WATCHDOG));
		host_write(GHCI_CTRL, (32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_WDT_EN) | (32'd1 << GHCI_CTRL_IRQ_GLOBAL));
		ring_put(hdr(1'b0, 6'd9, 8'h91, 8'd0, 8'd2));
		ring_put(FENCES + 32'h20);
		ring_put(32'h70000000);
		host_write(GHCI_RING_WPTR, wp);
		wait_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_FAULT, 32'd1 << GHCI_STATUS_FAULT);
		expect_reg(GHCI_FAULT_INFO, {16'd0, 8'd0, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_WATCHDOG}, 32'hFFFFFFFF);
		expect_reg(GHCI_IRQ_STATUS, (32'd1 << GHCI_IRQ_FAULT) | (32'd1 << GHCI_IRQ_WATCHDOG), (32'd1 << GHCI_IRQ_FAULT) | (32'd1 << GHCI_IRQ_WATCHDOG));
		if (!irq)
			fail_msg("no interrupt for the watchdog");
		reset_gpu();
		host_write(GHCI_CTRL, 32'd0);
		host_write(GHCI_WDT_CYCLES, 32'h10000000);
		host_write(GHCI_IRQ_ENABLE, 32'd0);
		compare_ref("after the ring tests");

		errors = errors + mem.errors;
		finished = 1'b1;
	end
endmodule

module atg_top_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	wire done_kc705;
	wire [31:0] err_kc705;

	always #5 clk = !clk;

	atg_top_harness #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .NAME("kc705"), .SEED(6)) kc705 (
		.clk(clk), .rst_n(rst_n), .finished(done_kc705), .errors(err_kc705)
	);

	initial begin
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		wait (done_kc705);
		if (err_kc705 == 0)
			$display("PASS atg_top");
		else
			$display("FAIL atg_top: %0d errors", err_kc705);
		$finish;
	end

	initial begin
		#50000000;
		$display("FAIL atg_top: timeout");
		$finish;
	end
endmodule

`default_nettype wire
