/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_kc705_pcie_tb: the KC705 board top through its PCIe endpoint, as a
 * host would use it (the model sim/models/kc705/atg_kc705_pcie.v: its
 * BAR0/BAR2 tasks and MSI counts), with the clock and memory wrappers'
 * models (sim/models/kc705/) and the CP firmware images.  Checks, in
 * order:
 *
 *   - bar0: GHCI_MAGIC and the major version, SCRATCH written and read
 *     back, the DC's DC_ID in the DISP2 window, STATUS.MEM_READY, RING_BASE
 *     written and read back, a doorbell (RING_WPTR) taken (OKAY);
 *   - bar2: one 16-byte beat written and read back, the DDR3 model holds
 *     it at the window's offset, a write with byte strobes changes only
 *     those bytes, a 64-byte burst written and read back; the GPU reads
 *     the same word at LOCAL_BASE + offset (DBG_ADDR/DBG_DATA through
 *     BAR0, aperture over the window);
 *   - msi (one vector, docs/ghci.md section 15.2): a message for IRQ_SET
 *     of the soft interrupt (IRQ_ENABLE set), again after an IRQ_ENABLE
 *     write that leaves the line 1, none after the IRQ_STATUS write that
 *     clears it, one for the next IRQ_SET; one for the DC's VBLANK
 *     (IRQ_STATUS [9], a 32 x 4 test-pattern mode, the CP IDLE so the
 *     host writes the DISP2 window), and no more while it stays set;
 *   - no fault (STATUS.FAULT 0).
 *
 * sim-sources: boards/kc705/atg_kc705_raster.v boards/kc705/lib/atg_kc705_jtag.v
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_kc705_pcie_tb;
	`include "ghci_regs.vh"

	reg sys_clk = 1'b0;
	reg cpu_reset = 1'b1;
	reg perst_n = 1'b0;
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
	wire [3:0] txp, txn;
	integer errors = 0;

	always #2.5 sys_clk = !sys_clk;

	pullup (iic_scl);
	pullup (iic_sda);

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
		.pcie_refclk_p(1'b0), .pcie_refclk_n(1'b1), .pcie_perst_n(perst_n),
		.pcie_txp(txp), .pcie_txn(txn), .pcie_rxp(4'd0), .pcie_rxn(4'hF)
	);

	task fail;
		input [8*64-1:0] what;
		begin
			errors = errors + 1;
			$display("FAIL atg_kc705_pcie: %0s at %0t", what, $time);
		end
	endtask

	reg [31:0] v;
	task rd;
		input [16:0] off;
		output [31:0] data;
		begin
			dut.pcie.bar0_read(off, data);
			if (dut.pcie.bar0_resp != 2'b00)
				fail("a BAR0 read not OKAY");
		end
	endtask
	task wr;
		input [16:0] off;
		input [31:0] data;
		begin
			dut.pcie.bar0_write(off, data);
			if (dut.pcie.bar0_resp != 2'b00)
				fail("a BAR0 write not OKAY");
		end
	endtask
	task expect_reg;
		input [16:0] off;
		input [31:0] want;
		input [31:0] mask;
		reg [31:0] got;
		begin
			rd(off, got);
			if ((got & mask) !== (want & mask)) begin
				errors = errors + 1;
				$display("FAIL atg_kc705_pcie: reg %h = %h, expected %h (mask %h)", off, got,
					want, mask);
			end
		end
	endtask
	task wait_uclk;
		input integer n;
		repeat (n) @(posedge dut.pcie.user_clk);
	endtask
	task expect_msi;
		input integer want;
		begin
			wait_uclk(100);
			if (dut.pcie.msi_count != want) begin
				errors = errors + 1;
				$display("FAIL atg_kc705_pcie: %0d MSI messages, expected %0d",
					dut.pcie.msi_count, want);
			end
		end
	endtask

	localparam [16:0] DC = GHCI_DISP2_BASE;
	reg [127:0] q, q2;
	reg [511:0] b4, b4r;
	integer n, i;

	initial begin
		repeat (20) @(posedge sys_clk);
		cpu_reset = 1'b0;
		repeat (20) @(posedge sys_clk);
		perst_n = 1'b1;
		n = 0;
		while (!dut.pcie.user_rst_n && n < 1000) begin
			@(posedge sys_clk);
			n = n + 1;
		end
		wait_uclk(10);
		/* bar0 */
		expect_reg(GHCI_MAGIC, GHCI_MAGIC_VALUE, 32'hFFFFFFFF);
		expect_reg(GHCI_VERSION, {GHCI_VERSION_MAJOR, 16'd0}, 32'hFFFF0000);
		wr(GHCI_SCRATCH, 32'h1234_5678);
		expect_reg(GHCI_SCRATCH, 32'h1234_5678, 32'hFFFFFFFF);
		expect_reg(DC | GHCI_DC_ID, GHCI_DC_ID_VALUE, 32'hFFFFFFFF);
		n = 0;
		rd(GHCI_STATUS, v);
		while (!v[GHCI_STATUS_MEM_READY] && n < 200) begin
			rd(GHCI_STATUS, v);
			n = n + 1;
		end
		if (!v[GHCI_STATUS_MEM_READY])
			fail("MEM_READY does not come");
		wr(GHCI_RING_BASE, 32'h8000_4000);
		expect_reg(GHCI_RING_BASE, 32'h8000_4000, 32'hFFFFFFFF);
		wr(GHCI_RING_WPTR, 32'd0);
		if (errors == 0)
			$display("PASS atg_kc705_pcie.bar0");
		/* bar2 */
		q = 128'h0f0e0d0c_0b0a0908_07060504_03020100;
		dut.pcie.bar2_write(26'h100, q, 16'hFFFF);
		if (dut.pcie.bar2_resp != 2'b00)
			fail("a BAR2 write not OKAY");
		dut.pcie.bar2_read(26'h100, q2);
		if (q2 !== q || dut.pcie.bar2_resp != 2'b00)
			fail("BAR2 read back");
		if (dut.mig.mem.peek32(32'h104) !== 32'h07060504)
			fail("the DDR3 model at the window's offset");
		dut.pcie.bar2_write(26'h100, {4{32'hA5A5A5A5}}, 16'h00F0);
		dut.pcie.bar2_read(26'h100, q2);
		if (q2 !== {32'h0f0e0d0c, 32'h0b0a0908, 32'hA5A5A5A5, 32'h03020100})
			fail("BAR2 byte strobes");
		for (i = 0; i < 16; i = i + 1)
			b4[i*32 +: 32] = 32'hC0DE0000 + i;
		dut.pcie.bar2_write4(26'h2000, b4);
		dut.pcie.bar2_read4(26'h2000, b4r);
		if (b4r !== b4 || dut.pcie.bar2_resp != 2'b00)
			fail("BAR2 burst read back");
		/* the GPU's view: LOCAL_BASE + offset */
		wr(GHCI_APERTURE_BASE, 32'h8000_0000);
		wr(GHCI_APERTURE_LIMIT, 32'h8010_0000);
		wr(GHCI_DBG_ADDR, 32'h8000_2008);
		n = 0;
		rd(GHCI_DBG_STATUS, v);
		while (v[0] && n < 200) begin
			rd(GHCI_DBG_STATUS, v);
			n = n + 1;
		end
		expect_reg(GHCI_DBG_DATA, 32'hC0DE0002, 32'hFFFFFFFF);
		if (errors == 0)
			$display("PASS atg_kc705_pcie.bar2");
		/* msi */
		wr(GHCI_IRQ_ENABLE, 32'd1 << GHCI_IRQ_SOFT);
		expect_msi(0);
		wr(GHCI_IRQ_SET, 32'd1 << GHCI_IRQ_SOFT);
		expect_msi(1);
		wr(GHCI_IRQ_ENABLE, 32'd1 << GHCI_IRQ_SOFT);	/* leaves it 1 */
		expect_msi(2);
		wr(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_SOFT);	/* clears it */
		expect_msi(2);
		wr(GHCI_IRQ_SET, 32'd1 << GHCI_IRQ_SOFT);
		expect_msi(3);
		wr(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_SOFT);
		/* the DC's VBLANK: 32 x 4 */
		wr(DC | GHCI_DC_TIMING, 32'd32);
		wr(DC | (GHCI_DC_TIMING + 17'h04), 32'd2);
		wr(DC | (GHCI_DC_TIMING + 17'h08), 32'd4);
		wr(DC | (GHCI_DC_TIMING + 17'h0C), 32'd4);
		wr(DC | (GHCI_DC_TIMING + 17'h10), 32'd4);
		wr(DC | (GHCI_DC_TIMING + 17'h14), 32'd1);
		wr(DC | (GHCI_DC_TIMING + 17'h18), 32'd1);
		wr(DC | (GHCI_DC_TIMING + 17'h1C), 32'd1);
		wr(DC | GHCI_DC_FB_SIZE, {16'd4, 16'd32});
		wr(DC | GHCI_DC_FB_STRIDE, 32'd128);
		wr(GHCI_IRQ_ENABLE, 32'd1 << GHCI_IRQ_VBLANK);
		expect_msi(3);
		wr(DC | GHCI_DC_CTRL, (32'd1 << GHCI_DC_CTRL_ENABLE) |
			(32'd1 << GHCI_DC_CTRL_TEST_PATTERN));
		n = 0;
		while (dut.pcie.msi_count == 3 && n < 400) begin
			wait_uclk(25);
			n = n + 1;
		end
		if (dut.pcie.msi_count == 3)
			fail("no MSI for the DC's VBLANK");
		rd(GHCI_IRQ_STATUS, v);
		if (!v[GHCI_IRQ_VBLANK])
			fail("IRQ_STATUS.VBLANK not set");
		/* more frames: the line stays 1, no more messages */
		wait_uclk(5000);
		if (dut.pcie.msi_count != 4)
			fail("not one MSI for the DC's VBLANK");
		wr(DC | GHCI_DC_CTRL, 32'd0);
		wr(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_VBLANK);
		wr(GHCI_IRQ_ENABLE, 32'd0);
		if (errors == 0)
			$display("PASS atg_kc705_pcie.msi");
		expect_reg(GHCI_STATUS, 32'd0, 32'd1 << GHCI_STATUS_FAULT);
		if (errors == 0)
			$display("PASS atg_kc705_pcie");
		else
			$display("FAIL atg_kc705_pcie: %0d errors", errors);
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL atg_kc705_pcie: timeout");
		$finish;
	end

	wire unused_ok = &{1'b0, txp, txn, led, hdmi_d, hdmi_de, hdmi_hs, hdmi_vs, hdmi_clk,
		iic_mux_reset_n};
endmodule

`default_nettype wire
