/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_tb: the GPU of bitstream 1 (CP v0, BLT, MC) driven
 * only through its host port, as fpgareg would on the ZYBO, against
 * axi_mem; in the ZYBO's shape (32-byte lines, 64-bit AXI3-sized bursts)
 * and the KC705's (64-byte lines, 512-bit).  Checks:
 *
 *   - the identification registers, SCRATCH, CAPS, the STATE alias, the
 *     extended capability list and the PERF counters;
 *   - DBG_ADDR/DATA: a word written and read back through the GPU;
 *   - FILL and COPY (different alignments, clipping), 16-bit pixels,
 *     blend-over, TILE/UNTILE, overlapping copies in both directions,
 *     against a reference model of memory, then random blits of every
 *     kind;
 *   - an aperture fault: FAULTED, FAULT_INFO (kind 1, client 1, write),
 *     IRQ, locked STATE writes, then RESET: IDLE, the aperture kept, and a
 *     FILL works again;
 *   - unsupported operations (a pixel size of 2, KICK.DRAW): fault kind 2;
 *   - HALT/HALTED, IRQ_SET/W1C and the interrupt line.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_top_harness #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter DATA_W = 64,
	parameter NAME = "zybo",
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

	atg_top #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .DATA_W(DATA_W)) dut (
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
		.m_rready(rready)
	);

	axi_mem #(.DATA_W(DATA_W), .MEM_BYTES(1 << 19), .READ_EARLY(1), .SEED(SEED + 7)) mem (
		.clk(clk), .rst_n(rst_n),
		.awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
		.awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
		.wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp),
		.bvalid(bvalid), .bready(bready), .araddr(araddr), .arlen(arlen),
		.arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
		.rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
	);

	`include "axi_host.vh"

	/* The reference of 0x20000..0x5FFFF (64 Ki words). */
	localparam [31:0] REF_BASE = 32'h00020000;
	localparam REF_WORDS = 65536;
	reg [31:0] refm [0:REF_WORDS-1];

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

	task state_write;
		input [8:0] idx;
		input [31:0] value;
		begin
			host_write(GHCI_STATE_BASE + idx * 4, value);
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
			state_write(GHCI_S_BLT_OP, opw);
			state_write(GHCI_S_BLT_DST_BASE, dst);
			state_write(GHCI_S_BLT_DST_STRIDE, dstride);
			state_write(GHCI_S_BLT_SRC_BASE, src);
			state_write(GHCI_S_BLT_SRC_STRIDE, sstride);
			state_write(GHCI_S_BLT_DST_XY, {dy, dx});
			state_write(GHCI_S_BLT_SRC_XY, {sy, sx});
			state_write(GHCI_S_BLT_SIZE, {h, w});
			state_write(GHCI_S_BLT_COLOR, color);
			state_write(GHCI_S_BLT_CLIP_MIN, cmin);
			state_write(GHCI_S_BLT_CLIP_MAX, cmax);
			host_write(GHCI_KICK, 32'd1);
			wait_status_clear(32'd1 << GHCI_STATUS_BLT_BUSY);
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
		expect_reg(GHCI_VERSION, 32'h00010000, 32'hFFFFFFFF);
		expect_reg(GHCI_VENDOR_ID, 32'h414D4154, 32'hFFFFFFFF);
		expect_reg(GHCI_DEVICE_ID, 32'h41544731, 32'hFFFFFFFF);
		expect_reg(GHCI_ISA_ID, 32'd0, 32'hFFFFFFFF);
		expect_reg(GHCI_GCLK_HZ, 32'd100000000, 32'hFFFFFFFF);
		expect_reg(GHCI_CAPS, {8'd0, LS4, 4'd0, 4'd1, 4'b1000, 4'd0, 4'b0010}, 32'hFFFFFFFF);
		expect_reg(GHCI_DEVICE_VERSION, 32'h00000002, 32'hFFFFFFFF);
		/* The capability list: one PERF entry. */
		expect_reg(GHCI_EXTCAP, 32'h00000100, 32'hFFFFFFFF);
		expect_reg(32'h0000_0100, {16'd0, 8'd1, GHCI_XCAP_PERF}, 32'hFFFFFFFF);
		expect_reg(32'h0000_0104, 32'h00000110, 32'hFFFFFFFF);
		expect_reg(32'h0000_0110, 32'd1, 32'hFFFFFFFF);
		expect_reg(32'h0000_0114, 32'd8, 32'hFFFFFFFF);
		expect_reg(32'h0000_0118, 32'hFF, 32'hFFFFFFFF);
		expect_reg(32'h0000_011C, 32'hFF, 32'hFFFFFFFF);
		expect_reg(32'h0000_0120, 32'd0, 32'hFFFFFFFF);
		expect_reg(32'h0000_0F04, 32'd0, 32'hFFFFFFFF);
		expect_reg(32'h0001_0000, 32'd0, 32'hFFFFFFFF);
		host_write(GHCI_SCRATCH, 32'hCAFEF00D);
		expect_reg(GHCI_SCRATCH, 32'hCAFEF00D, 32'hFFFFFFFF);
		host_write_strb(GHCI_SCRATCH, 32'h11223344, 4'b1000);
		expect_reg(GHCI_SCRATCH, 32'h11FEF00D, 32'hFFFFFFFF);
		expect_reg(GHCI_STATUS, (32'd1 << GHCI_STATUS_AXI_IDLE) | (32'd1 << GHCI_STATUS_MEM_READY),
			32'h000FFFFF & ~(32'd1 << GHCI_STATUS_RING_EMPTY));
		state_write(9'h123, 32'h5A5A1234);
		expect_reg(GHCI_STATE_BASE + 9'h123 * 4, 32'h5A5A1234, 32'hFFFFFFFF);
		host_write_strb(GHCI_STATE_BASE + 9'h123 * 4, 32'h0, 4'b0001);
		expect_reg(GHCI_STATE_BASE + 9'h123 * 4, 32'h5A5A1234, 32'hFFFFFFFF);

		/* The aperture: the reference region only. */
		host_write(GHCI_APERTURE_BASE, REF_BASE + 32'h1F);
		host_write(GHCI_APERTURE_LIMIT, REF_BASE + REF_WORDS * 4);
		expect_reg(GHCI_APERTURE_BASE, REF_BASE, 32'hFFFFFFFF);

		/* DBG: write a word, read it back. */
		host_write(GHCI_DBG_ADDR, REF_BASE + 32'h44);
		wait_dbg();
		expect_reg(GHCI_DBG_DATA, refm[17], 32'hFFFFFFFF);
		host_write(GHCI_DBG_DATA, 32'h12345678);
		wait_dbg();
		refm[17] = 32'h12345678;
		if (mem.peek32(REF_BASE + 32'h44) !== 32'h12345678)
			fail_msg("DBG write did not reach memory");
		host_write(GHCI_DBG_ADDR, REF_BASE + 32'h40);
		wait_dbg();
		expect_reg(GHCI_DBG_DATA, refm[16], 32'hFFFFFFFF);
		expect_reg(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_DBG_DONE, 32'hFFFFFFFF);
		host_write(GHCI_IRQ_STATUS, 32'h7F);
		host_write(GHCI_DBG_ADDR, 32'h00001000);
		wait_dbg();
		expect_reg(GHCI_DBG_STATUS, 32'd2, 32'hFFFFFFFF);
		expect_reg(GHCI_STATUS, 32'd0, 32'd1 << GHCI_STATUS_FAULT);

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

		/* The counters saw the blitter and the memory busy; PERF_CTRL
		 * clears them. */
		host_read(GHCI_PERF0, v);
		if (v == 0)
			fail_msg("PERF0 counted no blitter cycle");
		host_read(GHCI_PERF0 + 4, v);
		if (v == 0)
			fail_msg("PERF1 counted no memory cycle");
		host_write(GHCI_PERF_CTRL, 32'd1);
		expect_reg(GHCI_PERF0, 32'd0, 32'hFFFFFFFF);

		/* HALT in the middle of a COPY, then resume: the result is the
		 * same as without the pause. */
		state_write(GHCI_S_BLT_OP, {30'd0, GHCI_BLT_COPY});
		state_write(GHCI_S_BLT_DST_BASE, 32'h00044000);
		state_write(GHCI_S_BLT_DST_STRIDE, 512);
		state_write(GHCI_S_BLT_SRC_BASE, 32'h00020104);
		state_write(GHCI_S_BLT_SRC_STRIDE, 256);
		state_write(GHCI_S_BLT_DST_XY, {16'd2, 16'd3});
		state_write(GHCI_S_BLT_SRC_XY, {16'd1, 16'd0});
		state_write(GHCI_S_BLT_SIZE, {16'd20, 16'd50});
		state_write(GHCI_S_BLT_CLIP_MAX, 0);
		host_write(GHCI_KICK, 32'd1);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_HALT);
		repeat (50) @(posedge clk);
		expect_reg(GHCI_STATUS, (32'd3 << GHCI_STATUS_STATE) | (32'd1 << GHCI_STATUS_HALTED) |
			(32'd1 << GHCI_STATUS_BLT_BUSY), (32'hF << GHCI_STATUS_STATE) |
			(32'd1 << GHCI_STATUS_HALTED) | (32'd1 << GHCI_STATUS_BLT_BUSY));
		repeat (300) @(posedge clk);
		expect_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_BLT_BUSY, 32'd1 << GHCI_STATUS_BLT_BUSY);
		host_write(GHCI_CTRL, 32'd0);
		host_write(GHCI_IRQ_STATUS, 32'h7F);
		wait_status_clear(32'd1 << GHCI_STATUS_BLT_BUSY);
		for (n = 2; n < 22; n = n + 1)
			for (k = 3; k < 53; k = k + 1)
				refm[(32'h00044000 + n * 512 + k * 4 - REF_BASE) / 4] =
					refm[(32'h00020104 + (n - 1) * 256 + (k - 3) * 4 - REF_BASE) / 4];
		compare_ref("copy with a pause");

		/* An aperture fault, then RESET. */
		host_write(GHCI_IRQ_STATUS, 32'h7F);
		host_write(GHCI_IRQ_ENABLE, 32'd1 << GHCI_IRQ_FAULT);
		state_write(GHCI_S_BLT_OP, {30'd0, GHCI_BLT_FILL});
		state_write(GHCI_S_BLT_DST_BASE, 32'h00070000);
		state_write(GHCI_S_BLT_DST_XY, 0);
		state_write(GHCI_S_BLT_SIZE, {16'd2, 16'd8});
		state_write(GHCI_S_BLT_CLIP_MAX, 0);
		host_write(GHCI_KICK, 32'd1);
		/* The BLT stays busy, its next request held by the quiesce,
		 * until RESET. */
		repeat (200) @(posedge clk);
		expect_reg(GHCI_STATUS, (32'd1 << GHCI_STATUS_FAULT) | (32'd4 << GHCI_STATUS_STATE) |
			(32'd1 << GHCI_STATUS_QUIESCED), (32'd1 << GHCI_STATUS_FAULT) |
			(32'hF << GHCI_STATUS_STATE) | (32'd1 << GHCI_STATUS_QUIESCED));
		expect_reg(GHCI_FAULT_INFO, {8'd0, 8'd1, GHCI_FAULT_APERTURE, 3'd0, 1'b1, 8'd1},
			32'hFFFFFFFF);
		expect_reg(GHCI_FAULT_ADDR, 32'h00070000, 32'hFFFFFFFF);
		expect_reg(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_FAULT, 32'd1 << GHCI_IRQ_FAULT);
		if (!irq)
			fail_msg("no interrupt for the fault");
		state_write(GHCI_S_BLT_COLOR, 32'h77777777);
		expect_reg(GHCI_STATE_BASE + GHCI_S_BLT_COLOR * 4, 32'h77777777, 32'd0);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RESET);
		wait_status_clear(32'hF << GHCI_STATUS_STATE);
		expect_reg(GHCI_STATUS, (32'd1 << GHCI_STATUS_AXI_IDLE) | (32'd1 << GHCI_STATUS_MEM_READY),
			32'h000F7EFF & ~32'h800);
		expect_reg(GHCI_FAULT_INFO, 32'd0, 32'hFFFFFFFF);
		expect_reg(GHCI_IRQ_STATUS, 32'd0, 32'hFFFFFFFF);
		expect_reg(GHCI_APERTURE_LIMIT, REF_BASE + REF_WORDS * 4, 32'hFFFFFFFF);
		if (irq)
			fail_msg("interrupt after RESET");
		blit(GHCI_BLT_FILL, 32'h00031000, 128, 0, 0, 1, 1, 0, 0, 5, 3, 32'h0BADF00D, 0, 0);
		compare_ref("fill after reset");

		/* Unsupported operations: a pixel size of 2, blend-over of a
		 * tile, KICK.DRAW. */
		state_write(GHCI_S_BLT_OP, 32'h200);
		host_write(GHCI_KICK, 32'd1);
		expect_reg(GHCI_FAULT_INFO, {8'd0, 8'd1, GHCI_FAULT_OPCODE, 3'd0, 1'b0, 8'd1},
			32'hFFFFFFFF);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RESET);
		wait_status_clear(32'hF << GHCI_STATUS_STATE);
		state_write(GHCI_S_BLT_OP, 32'h012);
		host_write(GHCI_KICK, 32'd1);
		expect_reg(GHCI_FAULT_INFO, {8'd0, 8'd1, GHCI_FAULT_OPCODE, 3'd0, 1'b0, 8'd1},
			32'hFFFFFFFF);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RESET);
		wait_status_clear(32'hF << GHCI_STATUS_STATE);
		host_write(GHCI_KICK, 32'd1 << GHCI_KICK_DRAW);
		expect_reg(GHCI_FAULT_INFO, {16'd0, GHCI_FAULT_OPCODE, 12'd0}, 32'hFFFFFFFF);
		expect_reg(GHCI_STATUS, 32'd4 << GHCI_STATUS_STATE, 32'hF << GHCI_STATUS_STATE);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RESET);
		wait_status_clear(32'hF << GHCI_STATUS_STATE);

		/* HALT, the soft interrupt. */
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_HALT);
		expect_reg(GHCI_STATUS, (32'd3 << GHCI_STATUS_STATE) | (32'd1 << GHCI_STATUS_HALTED),
			(32'hF << GHCI_STATUS_STATE) | (32'd1 << GHCI_STATUS_HALTED));
		expect_reg(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_HALTED, 32'hFFFFFFFF);
		host_write(GHCI_CTRL, 32'd0);
		host_write(GHCI_IRQ_STATUS, 32'h7F);
		host_write(GHCI_IRQ_ENABLE, 32'd1 << GHCI_IRQ_SOFT);
		host_write(GHCI_IRQ_SET, 32'd1 << GHCI_IRQ_SOFT);
		expect_reg(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_SOFT, 32'hFFFFFFFF);
		if (!irq)
			fail_msg("no soft interrupt");
		host_write(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_SOFT);
		expect_reg(GHCI_IRQ_STATUS, 32'd0, 32'hFFFFFFFF);
		if (irq)
			fail_msg("soft interrupt not cleared");

		errors = errors + mem.errors;
		finished = 1'b1;
	end

	task wait_dbg;
		reg [31:0] st;
		integer n2;
		begin
			n2 = 0;
			host_read(GHCI_DBG_STATUS, st);
			while (st[0] && n2 < 1000) begin
				host_read(GHCI_DBG_STATUS, st);
				n2 = n2 + 1;
			end
			if (st[0])
				fail_msg("DBG stays busy");
		end
	endtask
endmodule

module atg_top_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	wire done_zybo, done_kc705;
	wire [31:0] err_zybo, err_kc705;

	always #5 clk = !clk;

	atg_top_harness #(.LINE_BYTES(32), .LINE_SHIFT(5), .DATA_W(64), .NAME("zybo"), .SEED(5)) zybo (
		.clk(clk), .rst_n(rst_n), .finished(done_zybo), .errors(err_zybo)
	);
	atg_top_harness #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .NAME("kc705"), .SEED(6)) kc705 (
		.clk(clk), .rst_n(rst_n), .finished(done_kc705), .errors(err_kc705)
	);

	initial begin
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		wait (done_zybo && done_kc705);
		if (err_zybo == 0 && err_kc705 == 0)
			$display("PASS atg_top");
		else
			$display("FAIL atg_top: %0d + %0d errors", err_zybo, err_kc705);
		$finish;
	end

	initial begin
		#50000000;
		$display("FAIL atg_top: timeout");
		$finish;
	end
endmodule

`default_nettype wire
