/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_kc705_raster_tb: the KC705 board top, driven only through its JTAG
 * bridge as a host's JTAG tool would (the BSCANE2 model's scan
 * task, TCK 25 MHz), with the board's clock and memory wrappers replaced
 * by their simulation models (sim/models/kc705/: 200 MHz SYSCLK -> gclk
 * 100 MHz, the DDR3 as an axi_mem) and the CP firmware images of
 * fw/cp/images/.  Checks, in order:
 *
 *   - jtag: GHCI MAGIC through the bridge, SCRATCH written and read back,
 *     the DC's DC_ID and DC_CAPS (ADV7511) at +0x10000, CAPS and CAPS2 of
 *     the KC705 shape (packed, graphics, subgroup, TU), the MEM capability
 *     (1 GiB at 0x8000_0000, a 64 MiB window), 64 registers per lane in
 *     RESIDENT_WARPS, STATUS.MEM_READY
 *     after the memory model's calibration;
 *   - fill: the aperture, a BLT FILL of 20 x 3 pixels from STATE writes
 *     and KICK, STATUS.BLT_BUSY polled, then DBG_ADDR/DBG_DATA read back
 *     two pixels and one outside the area; the memory model holds exactly
 *     the area;
 *   - i2c: IIC_MUX_RESET_B high, and one byte to the I2C mux (0x74, a
 *     slave model on the board's pins) through the DC's I2C registers at
 *     CLK_DIV 250 (100 kHz), acknowledged;
 *   - pattern: a small mode (32 x 4, active-high syncs) with TEST_PATTERN:
 *     the HDMI pins sampled on the rising edge of the forwarded pixel
 *     clock give the first frame's 4 lines of 32 pixels as YCbCr 4:2:2
 *     of the test pattern (white border, eight bars of 4), and HSYNC and
 *     VSYNC come.
 *
 * sim-sources: boards/kc705/atg_kc705_raster.v boards/kc705/lib/atg_kc705_jtag.v
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_kc705_raster_tb;
	`include "ghci_regs.vh"

	reg sys_clk = 1'b0;
	reg cpu_reset = 1'b1;
	wire [63:0] ddr3_dq;
	wire [7:0] ddr3_dqs_p, ddr3_dqs_n, ddr3_dm;
	wire [13:0] ddr3_addr;
	wire [2:0] ddr3_ba;
	wire ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_reset_n, ddr3_ck_p, ddr3_ck_n;
	wire ddr3_cke, ddr3_cs_n, ddr3_odt;
	wire [7:0] led;
	wire [15:0] hdmi_d;
	wire hdmi_de, hdmi_hs, hdmi_vs, hdmi_clk;
	wire iic_scl, iic_sda, iic_mux_reset_n;
	integer errors = 0;

	always #2.5 sys_clk = !sys_clk;

	pullup (iic_scl);
	pullup (iic_sda);

	i2c_slave #(.ADDR(7'h74)) iic_mux (.scl(iic_scl), .sda(iic_sda));

	atg_kc705_raster #(
		.NSU(1),
		.CPU_IMEM_INIT("fw/cp/images/atg1-cp-kc705.imem.hex"),
		.CPU_DMEM_INIT("fw/cp/images/atg1-cp-kc705.dmem.hex")
	) dut (
		.sys_clk_p(sys_clk), .sys_clk_n(!sys_clk), .cpu_reset(cpu_reset),
		.ddr3_dq(ddr3_dq), .ddr3_dqs_p(ddr3_dqs_p), .ddr3_dqs_n(ddr3_dqs_n),
		.ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba), .ddr3_ras_n(ddr3_ras_n),
		.ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n), .ddr3_reset_n(ddr3_reset_n),
		.ddr3_ck_p(ddr3_ck_p), .ddr3_ck_n(ddr3_ck_n), .ddr3_cke(ddr3_cke),
		.ddr3_cs_n(ddr3_cs_n), .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt),
		.led(led), .hdmi_d(hdmi_d), .hdmi_de(hdmi_de), .hdmi_hs(hdmi_hs),
		.hdmi_vs(hdmi_vs), .hdmi_clk(hdmi_clk),
		.iic_scl(iic_scl), .iic_sda(iic_sda), .iic_mux_reset_n(iic_mux_reset_n),
		/* the PCIe link held in reset (atg_kc705_pcie_tb uses it) */
		.pcie_refclk_p(1'b0), .pcie_refclk_n(1'b1), .pcie_perst_n(1'b0), .pcie_txp(),
		.pcie_txn(), .pcie_rxp(4'd0), .pcie_rxn(4'hF)
	);

	task fail;
		input [8*64-1:0] what;
		begin
			errors = errors + 1;
			$display("FAIL atg_kc705_raster: %0s at %0t", what, $time);
		end
	endtask

	/* The JTAG register access of jtag-reg.sh: a command scan, then status
	 * scans until done; a read's value is the data field of the last. */
	reg [127:0] jo;

	task j_scan;
		input [7:0] cmd;
		input [31:0] addr;
		input [31:0] data;
		begin
			dut.jtag.bscan.scan(72, {56'd0, data, addr, cmd}, jo);
		end
	endtask

	task j_done;
		integer n;
		begin
			n = 0;
			j_scan(8'd3, 32'd0, 32'd0);
			while (!jo[0] && n < 100) begin
				j_scan(8'd3, 32'd0, 32'd0);
				n = n + 1;
			end
			if (!jo[0] || jo[1])
				fail("JTAG command not done, or dropped");
		end
	endtask

	task jw;
		input [31:0] addr;
		input [31:0] data;
		begin
			j_scan(8'd1, addr, data);
			j_done;
		end
	endtask

	task jr;
		input [31:0] addr;
		output [31:0] data;
		begin
			j_scan(8'd2, addr, 32'd0);
			j_done;
			data = jo[71:40];
		end
	endtask

	task expect_reg;
		input [31:0] addr;
		input [31:0] want;
		input [31:0] mask;
		reg [31:0] got;
		begin
			jr(addr, got);
			if ((got & mask) !== (want & mask)) begin
				errors = errors + 1;
				$display("FAIL atg_kc705_raster: reg %h = %h, expected %h (mask %h)", addr, got,
					want, mask);
			end
		end
	endtask

	task poll_clear;
		input [31:0] addr;
		input [31:0] bits;
		reg [31:0] v;
		integer n;
		begin
			n = 0;
			jr(addr, v);
			while ((v & bits) != 0 && n < 2000) begin
				jr(addr, v);
				n = n + 1;
			end
			if ((v & bits) != 0)
				fail("a busy bit does not clear");
		end
	endtask

	/* BT.601 studio range, as atg_dc_ycc (written as signed arithmetic). */
	function [7:0] f_y;
		input [23:0] p;
		integer t;
		begin
			t = 66 * p[23:16] + 129 * p[15:8] + 25 * p[7:0] + 128;
			f_y = (t >>> 8) + 16;
		end
	endfunction

	function [7:0] f_cb;
		input [23:0] p;
		integer t;
		begin
			t = -38 * $signed({1'b0, p[23:16]}) - 74 * $signed({1'b0, p[15:8]}) +
				112 * $signed({1'b0, p[7:0]}) + 128;
			f_cb = (t >>> 8) + 128;
		end
	endfunction

	function [7:0] f_cr;
		input [23:0] p;
		integer t;
		begin
			t = 112 * $signed({1'b0, p[23:16]}) - 94 * $signed({1'b0, p[15:8]}) -
				18 * $signed({1'b0, p[7:0]}) + 128;
			f_cr = (t >>> 8) + 128;
		end
	endfunction

	/* The test pattern of atg_dc_tgen (32 x 4: bars of 4, white border). */
	function [23:0] pattern;
		input integer x;
		input integer y;
		begin
			if (x == 0 || x == 31 || y == 0 || y == 3)
				pattern = 24'hFFFFFF;
			else
				case (x / 4)
				0: pattern = 24'hFFFFFF;
				1: pattern = 24'hFFFF00;
				2: pattern = 24'h00FFFF;
				3: pattern = 24'h00FF00;
				4: pattern = 24'hFF00FF;
				5: pattern = 24'hFF0000;
				6: pattern = 24'h0000FF;
				default: pattern = 24'h000000;
				endcase
		end
	endfunction

	/* The HDMI pins, sampled as the ADV7511 does: the first frame after a
	 * VSYNC, line by line. */
	reg capture = 1'b0;
	reg seen_vs = 1'b0;
	reg seen_hs = 1'b0;
	reg de_q = 1'b0;
	integer cap_line = -1;
	integer cap_x = 0;
	integer cap_bad_len = 0;
	reg [15:0] frame [0:3][0:31];

	always @(posedge hdmi_clk) begin
		if (capture) begin
			if (hdmi_vs)
				seen_vs = 1'b1;
			if (seen_vs && hdmi_hs)
				seen_hs = 1'b1;
			if (seen_vs && hdmi_de && !de_q) begin
				cap_line = cap_line + 1;
				cap_x = 0;
			end
			if (seen_vs && !hdmi_de && de_q && cap_x != 32)
				cap_bad_len = cap_bad_len + 1;
			if (seen_vs && hdmi_de && cap_line >= 0 && cap_line < 4 && cap_x < 32) begin
				frame[cap_line][cap_x] = hdmi_d;
				cap_x = cap_x + 1;
			end else if (seen_vs && hdmi_de) begin
				cap_x = cap_x + 1;
			end
			de_q = hdmi_de;
		end
	end

	localparam [31:0] DC = 32'h0001_0000;
	localparam [31:0] FB = 32'h8004_0000;	/* local memory (DDR3 offset 0x4_0000) */
	localparam [31:0] FB_OFF = 32'h0004_0000;
	localparam [31:0] COLOR = 32'hAABBCCDD;
	reg [31:0] v;
	integer x, y, n;
	reg [23:0] p0;
	reg [15:0] want;

	/*
	 * Walks the extended capability list: DISP must point at the DC
	 * (+0x10000), DBG be listed, MEM give the DDR3 and the window.
	 */
	task check_extcap;
		reg [31:0] off, w0, w1, m;
		integer k;
		reg disp, dbg, mem;
		begin
			disp = 1'b0;
			dbg = 1'b0;
			mem = 1'b0;
			jr(GHCI_EXTCAP, off);
			for (k = 0; k < 8 && off != 32'd0; k = k + 1) begin
				jr(off, w0);
				jr(off + 32'd4, w1);
				if (w0[7:0] == GHCI_XCAP_DISP) begin
					disp = 1'b1;
					if (w1 != DC)
						fail("the DISP capability does not point at the DC");
				end
				if (w0[7:0] == GHCI_XCAP_DBG)
					dbg = 1'b1;
				if (w0[7:0] == GHCI_XCAP_MEM) begin
					mem = 1'b1;
					jr(w1 + {15'd0, GHCI_MEM_LOCAL_BASE}, m);
					if (m != 32'h80000000)
						fail("MEM LOCAL_BASE is not 0x8000_0000");
					jr(w1 + {15'd0, GHCI_MEM_LOCAL_SIZE}, m);
					if (m != 32'h40000000)
						fail("MEM LOCAL_SIZE is not 1 GiB");
					jr(w1 + {15'd0, GHCI_MEM_WINDOW_SIZE}, m);
					if (m != 32'h04000000)
						fail("MEM WINDOW_SIZE is not 64 MiB");
					jr(w1 + {15'd0, GHCI_MEM_HOST_LIMIT}, m);
					if (m != 32'h80000000)
						fail("MEM HOST_LIMIT is not 0x8000_0000");
				end
				off = w0[31:16] == 16'd0 ? 32'd0 : off + {14'd0, w0[31:16], 2'd0};
			end
			if (!disp)
				fail("no DISP capability");
			if (!dbg)
				fail("no DBG capability");
			if (!mem)
				fail("no MEM capability");
		end
	endtask

	initial begin
		repeat (20) @(posedge sys_clk);
		cpu_reset = 1'b0;
		dut.jtag.bscan.idle(8);
		repeat (100) @(posedge sys_clk);

		/* jtag */
		expect_reg(GHCI_MAGIC, GHCI_MAGIC_VALUE, 32'hFFFFFFFF);
		jw(GHCI_SCRATCH, 32'h4B373035);
		expect_reg(GHCI_SCRATCH, 32'h4B373035, 32'hFFFFFFFF);
		expect_reg(DC + GHCI_DC_ID, GHCI_DC_ID_VALUE, 32'hFFFFFFFF);
		expect_reg(DC + GHCI_DC_CAPS, 32'h4, 32'h7);
		expect_reg(GHCI_CAPS, 32'h8, 32'h8);	/* CAPS[3]: the DC is in this window */
		/* The KC705 shape: CAPS[28] packed, [27] graphics, [24] subgroup,
		 * [23:20] 64-byte lines, [8] the TU, [2] the SU; CAPS2[27:24] 16
		 * texture slots / 4. */
		expect_reg(GHCI_CAPS, 32'h19600104, 32'h19F00104);
		expect_reg(GHCI_CAPS2, 32'h04000000, 32'h0F000000);
		check_extcap;
		/* RESIDENT_WARPS[23:16]: the SUs' 64 registers per lane. */
		expect_reg(GHCI_RESIDENT_WARPS, 32'h00400000, 32'h00FF0000);
		n = 0;
		jr(GHCI_STATUS, v);
		while (!v[GHCI_STATUS_MEM_READY] && n < 100) begin
			jr(GHCI_STATUS, v);
			n = n + 1;
		end
		if (!v[GHCI_STATUS_MEM_READY])
			fail("MEM_READY does not come");
		if (errors == 0)
			$display("PASS atg_kc705_raster.jtag");

		/* fill */
		jw(GHCI_APERTURE_BASE, 32'h8000_0000);
		jw(GHCI_APERTURE_LIMIT, 32'h8010_0000);
		jw(GHCI_STATE_BASE + GHCI_S_BLT_OP * 4, {30'd0, GHCI_BLT_FILL});
		jw(GHCI_STATE_BASE + GHCI_S_BLT_DST_BASE * 4, FB);
		jw(GHCI_STATE_BASE + GHCI_S_BLT_DST_STRIDE * 4, 32'd256);
		jw(GHCI_STATE_BASE + GHCI_S_BLT_DST_XY * 4, {16'd1, 16'd3});
		jw(GHCI_STATE_BASE + GHCI_S_BLT_SIZE * 4, {16'd3, 16'd20});
		jw(GHCI_STATE_BASE + GHCI_S_BLT_COLOR * 4, COLOR);
		jw(GHCI_STATE_BASE + GHCI_S_BLT_CLIP_MIN * 4, 32'd0);
		jw(GHCI_STATE_BASE + GHCI_S_BLT_CLIP_MAX * 4, 32'd0);
		jw(GHCI_KICK, 32'd1);
		poll_clear(GHCI_STATUS, 32'd1 << GHCI_STATUS_BLT_BUSY);
		jw(GHCI_DBG_ADDR, FB + 1 * 256 + 3 * 4);
		poll_clear(GHCI_DBG_STATUS, 32'd1);
		expect_reg(GHCI_DBG_DATA, COLOR, 32'hFFFFFFFF);
		jw(GHCI_DBG_ADDR, FB + 3 * 256 + 22 * 4);
		poll_clear(GHCI_DBG_STATUS, 32'd1);
		expect_reg(GHCI_DBG_DATA, COLOR, 32'hFFFFFFFF);
		jw(GHCI_DBG_ADDR, FB + 3 * 256 + 23 * 4);
		poll_clear(GHCI_DBG_STATUS, 32'd1);
		expect_reg(GHCI_DBG_DATA, 32'd0, 32'hFFFFFFFF);
		expect_reg(GHCI_STATUS, 32'd0, 32'd1 << GHCI_STATUS_FAULT);
		for (y = 0; y < 6; y = y + 1)
			for (x = 0; x < 64; x = x + 1)
				if (dut.mig.mem.peek32(FB_OFF + y * 256 + x * 4) !==
				    (y >= 1 && y < 4 && x >= 3 && x < 23 ? COLOR : 32'd0)) begin
					errors = errors + 1;
					if (errors < 10)
						$display("FAIL atg_kc705_raster: memory at (%0d, %0d) = %h", x, y,
							dut.mig.mem.peek32(FB_OFF + y * 256 + x * 4));
				end
		if (errors == 0)
			$display("PASS atg_kc705_raster.fill");

		/* i2c: select the mux's channel 5 (the ADV7511 on the KC705). */
		if (iic_mux_reset_n !== 1'b1)
			fail("IIC_MUX_RESET_B not high");
		jw(DC + GHCI_DC_I2C + 32'h4, 32'hE8);
		jw(DC + GHCI_DC_I2C, 32'd5);	/* START | WRITE */
		poll_clear(DC + GHCI_DC_I2C + 32'h8, 32'd1);
		jw(DC + GHCI_DC_I2C + 32'h4, 32'h20);
		jw(DC + GHCI_DC_I2C, 32'd6);	/* WRITE | STOP */
		poll_clear(DC + GHCI_DC_I2C + 32'h8, 32'd1);
		expect_reg(DC + GHCI_DC_I2C + 32'h8, 32'd0, 32'h3);
		if (iic_mux.last !== 8'h20 || iic_mux.wbytes != 1 || iic_mux.stops != 1)
			fail("I2C mux byte");
		if (errors == 0)
			$display("PASS atg_kc705_raster.i2c");

		/* pattern: 32 x 4, porches and syncs of a few pixels. */
		jw(DC + GHCI_DC_TIMING + 32'h00, 32'd32);
		jw(DC + GHCI_DC_TIMING + 32'h04, 32'd2);
		jw(DC + GHCI_DC_TIMING + 32'h08, 32'd4);
		jw(DC + GHCI_DC_TIMING + 32'h0C, 32'd4);
		jw(DC + GHCI_DC_TIMING + 32'h10, 32'd4);
		jw(DC + GHCI_DC_TIMING + 32'h14, 32'd1);
		jw(DC + GHCI_DC_TIMING + 32'h18, 32'd1);
		jw(DC + GHCI_DC_TIMING + 32'h1C, 32'd1);
		jw(DC + GHCI_DC_SYNC_POL, 32'd3);
		jw(DC + GHCI_DC_FB_SIZE, {16'd4, 16'd32});
		jw(DC + GHCI_DC_FB_STRIDE, 32'd128);
		capture = 1'b1;
		jw(DC + GHCI_DC_CTRL, (32'd1 << GHCI_DC_CTRL_ENABLE) | (32'd1 << GHCI_DC_CTRL_TEST_PATTERN));
		n = 0;
		while (cap_line < 4 && n < 200) begin
			dut.jtag.bscan.idle(10);
			n = n + 1;
		end
		if (cap_line < 3)
			fail("the frame's four lines did not come");
		if (!seen_hs)
			fail("no HSYNC");
		if (cap_bad_len != 0)
			fail("a line of another length than 32");
		for (y = 0; y < 4; y = y + 1)
			for (x = 0; x < 32; x = x + 1) begin
				p0 = pattern(x & ~1, y);
				if (!x[0])
					want = {f_cb(p0), f_y(p0)};
				else
					want = {f_cr(p0), f_y(pattern(x, y))};
				if (frame[y][x] !== want) begin
					errors = errors + 1;
					if (errors < 10)
						$display("FAIL atg_kc705_raster: pixel (%0d, %0d) = %h, expected %h",
							x, y, frame[y][x], want);
				end
			end
		if (errors == 0)
			$display("PASS atg_kc705_raster.pattern");

		if (errors == 0)
			$display("PASS atg_kc705_raster");
		else
			$display("FAIL atg_kc705_raster: %0d errors", errors);
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL atg_kc705_raster: timeout");
		$finish;
	end
endmodule

`default_nettype wire
