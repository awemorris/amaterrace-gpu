/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_prot_tb: session protection in the GPU (docs/ghci.md section
 * 11.6) in the KC705's shape with the CPU, its firmware and HAS_PROT,
 * driven only through the host port.  Groups (each prints
 * PASS atg_top_prot.GROUP):
 *   regs   the PROT capability in the extended list, PROT_CAPS (31 sessions,
 *          4 KiB granules, 64 grants), PROT_TABLE (4 KiB aligned) and
 *          PROT_TABLE_BYTES for the aperture, PROT_TABLE 0 after an
 *          aperture write and after CTRL.RESET
 * The sessions, the firmware's gpu-ops and the units' checks are added with
 * the firmware's session protection.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_top_prot_tb;
	`include "ghci_regs.vh"

	localparam IMEM = "fw/cp/images/atg1-cp-kc705.imem.hex";
	localparam DMEM = "fw/cp/images/atg1-cp-kc705.dmem.hex";

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

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
	wire [511:0] wdata, rdata;
	wire [63:0] wstrb;

	atg_top #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .HAS_CPU(1),
		.CPU_IMEM_INIT(IMEM), .CPU_DMEM_INIT(DMEM), .CPU_IMEM_WORDS(16384),
		.CPU_DMEM_WORDS(8192), .HAS_PROT(1), .PROT_SLOTS(31), .PROT_GRANTS(64),
		.PROT_GIDX_W(6), .PROT_PLB(16), .PROT_PLB_W(4)) dut (
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
		.x_req_valid(1'b0), .x_req_ready(), .x_req_write(1'b0), .x_req_line(26'd0),
		.x_req_be(64'd0), .x_req_wdata(512'd0), .x_req_tag(8'd0),
		.x_rsp_valid(), .x_rsp_write(), .x_rsp_tag(), .x_rsp_rdata(), .x_rsp_error(),
		.x_vsync(1'b0),
		.j_wr(1'b0), .j_waddr(17'd0), .j_wdata(32'd0), .j_wstrb(4'd0), .j_rd(1'b0),
		.j_raddr(17'd0), .j_rdata(), .j_busy()
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
	reg [31:0] v, w, prot, off;
	integer n;

	task check;
		input ok;
		input [8*32-1:0] what;
		begin
			if (!ok) begin
				errors = errors + 1;
				$display("FAIL atg_top_prot: %0s (%h)", what, v);
			end
		end
	endtask

	task group;
		input [8*8-1:0] name;
		begin
			if (errors == before)
				$display("PASS atg_top_prot.%0s", name);
			else
				$display("FAIL atg_top_prot.%0s: %0d errors", name, errors - before);
			before = errors;
		end
	endtask

	initial begin
		seed = 3;
		repeat (4) @(posedge clk);
		rst_n = 1'b1;
		repeat (4) @(posedge clk);

		/* regs: find PROT (id 9) in the list. */
		prot = 32'd0;
		host_read(GHCI_EXTCAP, off);
		n = 0;
		while (off != 32'd0 && n < 16) begin
			host_read(off[16:0], v);
			host_read(off[16:0] + 17'd4, w);
			if (v[7:0] == GHCI_XCAP_PROT)
				prot = w;
			off = v[31:16] == 16'd0 ? 32'd0 : off + {14'd0, v[31:16], 2'b00};
			n = n + 1;
		end
		v = prot;
		check(prot != 32'd0, "PROT in the list");
		host_read(prot[16:0] + GHCI_PROT_CAPS, v);
		check(v == {16'd64, 8'd12, 8'd31}, "PROT_CAPS");
		host_write(GHCI_APERTURE_BASE, 32'h00001000);
		host_write(GHCI_APERTURE_LIMIT, 32'h00100000);
		host_read(prot[16:0] + GHCI_PROT_TABLE_BYTES, v);
		check(v == 32'h00001000, "PROT_TABLE_BYTES");
		host_write(prot[16:0] + GHCI_PROT_TABLE, 32'h000F0123);
		host_read(prot[16:0] + GHCI_PROT_TABLE, v);
		check(v == 32'h000F0000, "PROT_TABLE");
		host_write(GHCI_APERTURE_LIMIT, 32'h00100000);
		host_read(prot[16:0] + GHCI_PROT_TABLE, v);
		check(v == 32'd0, "PROT_TABLE after APERTURE");
		host_write(prot[16:0] + GHCI_PROT_TABLE, 32'h000F0000);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RESET);
		n = 0;
		v = 32'd1 << GHCI_CTRL_RESET;
		while (v[GHCI_CTRL_RESET] && n < 2000) begin
			host_read(GHCI_CTRL, v);
			n = n + 1;
		end
		host_read(prot[16:0] + GHCI_PROT_TABLE, v);
		check(v == 32'd0, "PROT_TABLE after RESET");
		group("regs");

		if (errors == 0)
			$display("PASS atg_top_prot");
		else
			$display("FAIL atg_top_prot: %0d errors", errors);
		$finish;
	end

	initial begin
		#5000000;
		$display("FAIL atg_top_prot: timeout");
		$finish;
	end

	wire unused_ok = &{1'b0, irq, h_bid, h_bresp, h_rid, h_rresp, h_rlast};
endmodule

`default_nettype wire
