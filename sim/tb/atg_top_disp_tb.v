/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_disp_tb: the DISP2 display controller as a unit of the GPU
 * (docs/ghci.md section 13.2, design §18.12) in the KC705's shape (64-byte
 * lines, 512-bit AXI, HAS_DISP, the cursor plane), the BLT and the MC, no
 * CPU (DISP_SET and FLIP need no firmware), driven only through the host
 * port and the ring as the driver does; a 25 MHz pixel clock and a small
 * mode (32 x 4) so that a frame is about 1200 gclk cycles.  Groups (each
 * prints PASS atg_top_disp.GROUP):
 *   regs    DISP2 in the extended list at 0x200, DC_ID through it; in IDLE a
 *           host scan-out write passes
 *   on      the driver's lighting order through the ring: DISP_SET(WAIT_IDLE;
 *           CTRL), the mode, a BLIT fill, FLIP(COMPLETE) of plane 0 (taken at
 *           once, ENABLE 0), DISP_SET(CTRL | ENABLE), FENCE: the record
 *           {1, FRAME_COUNT}, IRQ_STATUS.FLIP, FB_BASE, and the frames scanned
 *           (SCAN_SUM, SCAN_WORDS) are the fill's
 *   gate    a host write of FB_NEXT while RUNNING: dropped, STATUS.BAD_WRITE,
 *           no device fault
 *   flip    a fill of a second image and FLIP(COMPLETE) without a FENCE: the
 *           record at a later frame, then the scan is the new image's
 *   wait    FLIP, then WAIT_FENCE of a fence nobody writes yet: the flip's
 *           record comes while the ring waits
 *   off     FLIP, then DISP_SET(WAIT_IDLE; CTRL without ENABLE): the pending
 *           flip is taken as cancelled (record value bit 31), STATUS.idle
 *   reset   a FLIP pending (STATUS[29]) and the GPU's CTRL.RESET: the DC goes
 *           on scanning, the flip is taken and its record written once the CP
 *           is IDLE (TAKEN0, STATUS[31] falls); then 30 GPU resets at random
 *           points of the frame: the scan stays whole (the MC's flush with
 *           the DC's reads out is atg_mc_tb's cases D and E: here a flush
 *           seldom meets one, and MUT_MC_NOKEEP does not fail this TB)
 *   dcerr   in IDLE the host makes the DC scan outside the aperture: the MC
 *           refuses its reads, the DC sets STATUS.read error, the CP stays
 *           IDLE without a fault
 * Not here: a draw (the RX and ROP into a flipped image: atg_top_tex and the
 * Verilator e2e), the cursor plane's image (atg_dc_cursor_tb), firmware.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_top_disp_tb;
	`include "ghci_regs.vh"

	localparam [31:0] W = {15'd0, GHCI_DISP2_BASE};	/* the DISP2 window */
	localparam [31:0] FB0 = 32'h00020000;
	localparam [31:0] FB1 = 32'h00030000;
	localparam [31:0] REC = 32'h00040000;	/* plane 0's record */
	localparam [31:0] FENCES = 32'h00040100;
	localparam [31:0] FENCE2 = 32'h00040140;	/* WAIT_FENCE's */
	localparam [31:0] RING = 32'h00050000;
	localparam RING_N = 1024;
	localparam [31:0] COLOR_A = 32'h11223344;
	localparam [31:0] COLOR_B = 32'h55667788;
	localparam [7:0] TAG = 8'h21;
	/* CTRL: FORMAT BGRA8 (0), OUTPUT HDMI. */
	localparam [31:0] CTRL_OFF = 32'd1 << GHCI_DC_CTRL_OUTPUT;
	localparam [31:0] CTRL_ON = CTRL_OFF | (32'd1 << GHCI_DC_CTRL_ENABLE);

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg pclk = 1'b0;
	reg prst_n = 1'b0;
	always #5 clk = !clk;
	always #20 pclk = !pclk;

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
	wire [31:0] awaddr, araddr;
	wire [7:0] awlen, arlen;
	wire [2:0] awsize, arsize, awprot, arprot;
	wire [1:0] awburst, arburst, bresp, rresp;
	wire [3:0] awcache, arcache;
	wire awvalid, awready, wlast, wvalid, wready, bvalid, bready;
	wire arvalid, arready, rlast, rvalid, rready;
	wire [511:0] wdata, rdata;
	wire [63:0] wstrb;
	wire [23:0] px_rgb;
	wire [29:0] tmds;
	wire px_de, px_hs, px_vs, pclk_sel, scl_t, sda_t;

	atg_top #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .HAS_DISP(1),
		.DC_FIFO_LOG2(11)) dut (
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
		.xr_wr(), .xr_waddr(), .xr_wdata(), .xr_wstrb(), .xr_rd(), .xr_raddr(),
		.xr_rdata(32'd0),
		.x_req_valid(1'b0), .x_req_ready(), .x_req_write(1'b0), .x_req_line(26'd0),
		.x_req_be(64'd0), .x_req_wdata(512'd0), .x_req_tag(8'd0),
		.x_rsp_valid(), .x_rsp_write(), .x_rsp_tag(), .x_rsp_rdata(), .x_rsp_error(),
		.x_vsync(1'b0),
		.j_wr(1'b0), .j_waddr(17'd0), .j_wdata(32'd0), .j_wstrb(4'd0), .j_rd(1'b0),
		.j_raddr(17'd0), .j_rdata(), .j_busy(),
		.pclk(pclk), .prst_n(prst_n), .pclk_sel(pclk_sel), .tmds(tmds), .px_rgb(px_rgb),
		.px_de(px_de), .px_hs(px_hs), .px_vs(px_vs), .scl_t(scl_t), .scl_i(1'b1),
		.sda_t(sda_t), .sda_i(1'b1)
	);

	axi_mem #(.DATA_W(512), .MEM_BYTES(1 << 20), .READ_EARLY(1), .SEED(7)) mem (
		.clk(clk), .rst_n(rst_n),
		.awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
		.awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
		.wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp),
		.bvalid(bvalid), .bready(bready), .araddr(araddr), .arlen(arlen),
		.arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
		.rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
	);

	`include "axi_host.vh"

	integer errors = 0, before = 0;
	reg [31:0] v, w, off, disp, fc;
	integer n, k, wp, fence_value;

	task check;
		input ok;
		input [8*40-1:0] what;
		begin
			if (!ok) begin
				errors = errors + 1;
				$display("FAIL atg_top_disp: %0s (%h)", what, v);
			end
		end
	endtask

	task group;
		input [8*8-1:0] name;
		begin
			if (errors == before)
				$display("PASS atg_top_disp.%0s", name);
			else
				$display("FAIL atg_top_disp.%0s: %0d errors", name, errors - before);
			before = errors;
		end
	endtask

	task wait_reg;
		input [16:0] reg_off;
		input [31:0] want;
		input [31:0] mask;
		input integer polls;
		integer t;
		begin
			t = 0;
			host_read(reg_off, v);
			while ((v & mask) != (want & mask) && t < polls) begin
				host_read(reg_off, v);
				t = t + 1;
			end
			check((v & mask) == (want & mask), "a register does not come");
		end
	endtask

	/* Waits until memory word a holds want (the record's value). */
	task wait_mem;
		input [31:0] a;
		input [31:0] want;
		input integer cycles;
		integer t;
		begin
			t = 0;
			while (mem.peek32(a) != want && t < cycles) begin
				@(posedge clk);
				t = t + 1;
			end
			v = mem.peek32(a);
			check(v == want, "a record does not come");
		end
	endtask

	/* Waits for n more frames (FRAME_COUNT). */
	task frames;
		input integer nf;
		reg [31:0] f0;
		begin
			host_read(W + GHCI_DC_FRAME_COUNT, f0);
			wait_reg(W + GHCI_DC_FRAME_COUNT, f0 + nf, 32'hFFFFFFFF, 2000);
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
		input [7:0] flags;
		input [7:0] n_;
		hdr = {2'b00, op, TAG, flags, n_};
	endfunction

	task ring_fence;
		begin
			fence_value = fence_value + 1;
			ring_put(hdr(6'd5, 8'd0, 8'd2));
			ring_put(FENCES);
			ring_put(fence_value);
		end
	endtask

	task doorbell;
		begin
			host_write(GHCI_RING_WPTR, wp);
		end
	endtask

	task ring_fill;
		input [31:0] dst;
		input [31:0] color;
		begin
			ring_put(hdr(6'd1, 8'd0, 8'd22));
			ring_put({23'd0, GHCI_S_BLT_OP}); ring_put({30'd0, GHCI_BLT_FILL});
			ring_put({23'd0, GHCI_S_BLT_DST_BASE}); ring_put(dst);
			ring_put({23'd0, GHCI_S_BLT_DST_STRIDE}); ring_put(32'd128);
			ring_put({23'd0, GHCI_S_BLT_SRC_BASE}); ring_put(32'd0);
			ring_put({23'd0, GHCI_S_BLT_SRC_STRIDE}); ring_put(32'd0);
			ring_put({23'd0, GHCI_S_BLT_DST_XY}); ring_put(32'd0);
			ring_put({23'd0, GHCI_S_BLT_SRC_XY}); ring_put(32'd0);
			ring_put({23'd0, GHCI_S_BLT_SIZE}); ring_put({16'd4, 16'd32});
			ring_put({23'd0, GHCI_S_BLT_COLOR}); ring_put(color);
			ring_put({23'd0, GHCI_S_BLT_CLIP_MIN}); ring_put(32'd0);
			ring_put({23'd0, GHCI_S_BLT_CLIP_MAX}); ring_put(32'd0);
			ring_put(hdr(6'd2, 8'd0, 8'd0));
		end
	endtask

	task flip;
		input [7:0] flags;
		input [31:0] base;
		input [31:0] value;
		begin
			ring_put(hdr(6'd16, flags, 8'd4));
			ring_put(32'd0);
			ring_put(base);
			ring_put(REC);
			ring_put(value);
		end
	endtask

	/* DISP_SET of one register. */
	task dset;
		input [7:0] flags;
		input [31:0] off_;
		input [31:0] value;
		begin
			ring_put(hdr(6'd15, flags, 8'd2));
			ring_put(off_);
			ring_put(value);
		end
	endtask

	initial begin
		seed = 3;
		wp = 0;
		fence_value = 0;
		repeat (4) @(posedge clk);
		rst_n = 1'b1;
		prst_n = 1'b1;
		repeat (8) @(posedge clk);

		/* regs */
		disp = 32'd0;
		host_read(GHCI_EXTCAP, off);
		n = 0;
		while (off != 32'd0 && n < 16) begin
			host_read(off[16:0], v);
			host_read(off[16:0] + 17'd4, w);
			if (v[7:0] == GHCI_XCAP_DISP2)
				disp = w;
			off = v[31:16] == 16'd0 ? 32'd0 : off + {14'd0, v[31:16], 2'b00};
			n = n + 1;
		end
		v = disp;
		check(disp == W, "DISP2 at 0x200 in the list");
		host_read(W + GHCI_DC_ID, v);
		check(v == GHCI_DC_ID_VALUE, "DC_ID through the window");
		host_write(W + GHCI_DC_FB_STRIDE, 32'd256);
		host_read(W + GHCI_DC_FB_STRIDE, v);
		check(v == 32'd256, "a host S write in IDLE");
		group("regs");

		/* on: the ring and the lighting order. */
		host_write(GHCI_APERTURE_BASE, 32'h00010000);
		host_write(GHCI_APERTURE_LIMIT, 32'h00080000);
		host_write(GHCI_RING_BASE, RING);
		host_write(GHCI_RING_SIZE, 32'd12);	/* 4 KiB: RING_N words */
		host_write(GHCI_IRQ_STATUS, 32'h1FFF);
		mem.poke32(REC, 32'd0);
		mem.poke32(REC + 4, 32'd0);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RUN);
		dset(8'd1, GHCI_DC_CTRL, CTRL_OFF);
		ring_put(hdr(6'd15, 8'd0, 8'd22));
		ring_put(GHCI_DC_TIMING + 32'h00); ring_put(32'd32);
		ring_put(GHCI_DC_TIMING + 32'h04); ring_put(32'd2);
		ring_put(GHCI_DC_TIMING + 32'h08); ring_put(32'd4);
		ring_put(GHCI_DC_TIMING + 32'h0C); ring_put(32'd4);
		ring_put(GHCI_DC_TIMING + 32'h10); ring_put(32'd4);
		ring_put(GHCI_DC_TIMING + 32'h14); ring_put(32'd1);
		ring_put(GHCI_DC_TIMING + 32'h18); ring_put(32'd1);
		ring_put(GHCI_DC_TIMING + 32'h1C); ring_put(32'd1);
		ring_put(GHCI_DC_SYNC_POL); ring_put(32'd3);
		ring_put(GHCI_DC_FB_STRIDE); ring_put(32'd128);
		ring_put(GHCI_DC_FB_SIZE); ring_put({16'd4, 16'd32});
		ring_fill(FB0, COLOR_A);
		flip(8'd1, FB0, 32'd1);
		dset(8'd0, GHCI_DC_CTRL, CTRL_ON);
		ring_fence;
		doorbell;
		wait_reg(GHCI_FENCE_LAST, fence_value, 32'hFFFFFFFF, 4000);
		wait_mem(REC, 32'd1, 2000);
		host_read(GHCI_IRQ_STATUS, v);
		check(v[GHCI_IRQ_FLIP], "IRQ_STATUS.FLIP");
		host_read(W + GHCI_DC_FB_BASE, v);
		check(v == FB0, "FB_BASE");
		frames(3);
		host_read(W + GHCI_DC_SCAN_SUM, v);
		check(v == COLOR_A * 128, "SCAN_SUM of the fill");
		host_read(W + GHCI_DC_SCAN_WORDS, v);
		check(v == 32'd128, "SCAN_WORDS");
		host_read(W + GHCI_DC_STATUS, v);
		check(v[0] && !v[1] && !v[3], "STATUS running, no underflow or error");
		host_read(GHCI_STATUS, v);
		check(v[19:16] == GHCI_ST_RUNNING, "the CP RUNNING");
		group("on");

		/* gate */
		host_write(W + GHCI_DC_FB_NEXT, FB1);
		host_read(W + GHCI_DC_STATUS, v);
		check(v[5], "BAD_WRITE");
		host_write(W + GHCI_DC_STATUS, 32'h20);
		host_read(W + GHCI_DC_STATUS, v);
		check(!v[5] && !v[29], "BAD_WRITE cleared, nothing pending");
		host_read(W + GHCI_DC_FB_BASE, v);
		check(v == FB0, "FB_BASE unchanged");
		host_read(GHCI_STATUS, v);
		check(v[19:16] == GHCI_ST_RUNNING, "no device fault");
		group("gate");

		/* flip: a second image, no FENCE. */
		host_read(W + GHCI_DC_FRAME_COUNT, fc);
		ring_fill(FB1, COLOR_B);
		flip(8'd1, FB1, 32'd2);
		doorbell;
		wait_mem(REC, 32'd2, 20000);
		v = mem.peek32(REC + 4);
		check(v > fc, "the record's FRAME_COUNT");
		host_read(W + GHCI_DC_FB_BASE, v);
		check(v == FB1, "FB_BASE of the second image");
		frames(2);
		host_read(W + GHCI_DC_SCAN_SUM, v);
		check(v == COLOR_B * 128, "SCAN_SUM of the second image");
		group("flip");

		/* wait: the record while the ring waits for a fence. */
		mem.poke32(FENCE2, 32'd0);
		flip(8'd0, FB0, 32'd3);
		ring_put(hdr(6'd9, 8'd0, 8'd2));
		ring_put(FENCE2);
		ring_put(32'd7);
		ring_fence;
		doorbell;
		wait_mem(REC, 32'd3, 20000);
		host_read(GHCI_FENCE_LAST, v);
		check(v != fence_value, "the ring went past WAIT_FENCE");
		mem.poke32(FENCE2, 32'd7);
		wait_reg(GHCI_FENCE_LAST, fence_value, 32'hFFFFFFFF, 4000);
		group("wait");

		/* off: a FLIP and the stop; the pending flip is cancelled. */
		frames(1);
		flip(8'd0, FB1, 32'd4);
		dset(8'd1, GHCI_DC_CTRL, CTRL_OFF);
		ring_fence;
		doorbell;
		wait_reg(GHCI_FENCE_LAST, fence_value, 32'hFFFFFFFF, 4000);
		wait_mem(REC, 32'h80000004, 2000);
		host_read(W + GHCI_DC_STATUS, v);
		check(!v[0] && v[2] && !v[29], "stopped, idle, nothing pending");
		host_read(W + GHCI_DC_FB_BASE, v);
		check(v == FB0, "FB_BASE kept by the cancelled flip");
		group("off");

		/* reset: a pending flip through the GPU's CTRL.RESET. */
		flip(8'd0, FB0, 32'd5);
		dset(8'd0, GHCI_DC_CTRL, CTRL_ON);
		ring_fence;
		doorbell;
		wait_reg(GHCI_FENCE_LAST, fence_value, 32'hFFFFFFFF, 4000);
		wait_mem(REC, 32'd5, 2000);
		frames(1);
		flip(8'd0, FB1, 32'd6);
		doorbell;
		wait_reg(W + GHCI_DC_STATUS, 32'h20000000, 32'h20000000, 100);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RESET);
		wait_reg(GHCI_STATUS, 32'd0, 32'h000F0000, 4000);
		wait_mem(REC, 32'd6, 20000);
		host_read(W + GHCI_DC_TAKEN0, v);
		check(v == 32'd6, "TAKEN0 after the reset");
		host_read(W + GHCI_DC_STATUS, v);
		check(v[0] && !v[31], "the DC scans on, no record due");
		host_read(W + GHCI_DC_FB_BASE, v);
		check(v == FB1, "the flip across the reset was shown");
		/* GPU resets at random points of the frame (some with the DC's reads
		 * out): the scan goes on whole. */
		for (k = 0; k < 30; k = k + 1) begin
			repeat ($unsigned($random(seed)) % 1300)
				@(posedge clk);
			host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RESET);
			wait_reg(GHCI_STATUS, 32'd0, 32'h000F0000, 4000);
		end
		host_write(W + GHCI_DC_STATUS, 32'h3A);
		frames(3);
		host_read(W + GHCI_DC_SCAN_WORDS, v);
		check(v == 32'd128, "SCAN_WORDS after the resets");
		host_read(W + GHCI_DC_SCAN_SUM, v);
		check(v == COLOR_B * 128, "SCAN_SUM after the resets");
		host_read(W + GHCI_DC_STATUS, v);
		check(v[0] && !v[1] && !v[3], "running, no underflow or error after the resets");
		group("reset");

		/* dcerr: the host (CP IDLE) scans outside the aperture. */
		host_write(W + GHCI_DC_FB_NEXT, 32'h00090000);
		frames(2);
		host_read(W + GHCI_DC_STATUS, v);
		check(v[3], "STATUS.read error");
		host_read(GHCI_STATUS, v);
		check(v[19:16] == GHCI_ST_IDLE, "no device fault for the DC's reads");
		host_read(GHCI_FAULT_INFO, v);
		check(v == 32'd0, "FAULT_INFO empty");
		host_write(W + GHCI_DC_FB_NEXT, FB0);
		frames(1);
		host_write(W + GHCI_DC_STATUS, 32'h3A);
		frames(2);
		host_read(W + GHCI_DC_STATUS, v);
		check(!v[3], "no read error once back inside");
		group("dcerr");

		if (errors == 0)
			$display("PASS atg_top_disp");
		else
			$display("FAIL atg_top_disp: %0d errors", errors);
		$finish;
	end

	initial begin
		#100000000;
		$display("FAIL atg_top_disp: timeout");
		$finish;
	end

	wire unused_ok = &{1'b0, irq, h_bid, h_bresp, h_rid, h_rresp, h_rlast, px_rgb, tmds, px_de,
		px_hs, px_vs, pclk_sel, scl_t, sda_t};
endmodule

`default_nettype wire
