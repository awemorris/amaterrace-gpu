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
 *   regs    the PROT capability in the extended list, PROT_CAPS (31 sessions,
 *           4 KiB granules, 64 grants), PROT_TABLE (4 KiB aligned) and
 *           PROT_TABLE_BYTES for the aperture, PROT_TABLE 0 after an
 *           aperture write and after CTRL.RESET
 *   own     the driver's order (aperture not at 0, the table zeroed,
 *           PROT_TABLE, GHCI_HEAP), sessions A and B opened PROTECTED and C
 *           not; B fills its memory b and A fills and copies inside its
 *           memory a through recorded command buffers (the BLT checked for
 *           their slots), the driver's FENCE with the session's tag; the
 *           table's bytes say the owners, the built-in part is public
 *   refuse  A imports b without a grant and copies b to a: FAULT kind 1 with
 *           [9] and A's tag, a is not written
 *   grant   after CTRL.RESET and the driver's order again: GRANT(A, read, b)
 *           before A's frame, the copy b to a succeeds; C (unprotected)
 *           copies b to its memory unchecked; a second grant of b, one
 *           REVOKE, the copy still succeeds
 *   revoke  the second REVOKE: the copy faults again (kind 1, [9], A's tag)
 * Not here (unit testbenches and later work): the scrubs of the SU's RAM
 * between sessions through programs, the firmware's slabs on the GPU
 * (fw/cp/tests: fwtest.prot), the Verilator mode.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_top_prot_tb;
	`include "ghci_regs.vh"

	localparam IMEM = "fw/cp/images/atg1-cp-kc705.imem.hex";
	localparam DMEM = "fw/cp/images/atg1-cp-kc705.dmem.hex";

	/* Memory: the sessions' areas, the driver's (ring, staging, results, table) and the heap. */
	localparam [31:0] APERTURE = 32'h00001000;
	localparam [31:0] AREA_A = 32'h00020000;
	localparam [31:0] AREA_B = 32'h00030000;
	localparam [31:0] AREA_C = 32'h00040000;
	localparam [31:0] AREA_BYTES = 32'h00008000;
	localparam [31:0] STAGING = 32'h00050000;
	localparam [31:0] RESULTS = 32'h00058000;
	localparam [31:0] FRAME_RESULT = 32'h00058800;
	localparam [31:0] RING_RESULT = 32'h00058C00;
	localparam [31:0] FENCES = 32'h0005EF00;
	localparam [31:0] RING = 32'h0005F000;
	localparam RING_N = 256;
	localparam [31:0] HEAP = 32'h00080000;
	localparam [31:0] HEAP_BYTES = 32'h00060000;
	localparam [31:0] TABLE = 32'h000F0000;
	localparam [7:0] TAG_A = 8'd5;
	localparam [7:0] TAG_B = 8'd6;
	localparam [7:0] TAG_C = 8'd7;
	localparam [31:0] DATA_A = 32'hA0A0A0A1;
	localparam [31:0] DATA_B = 32'hB0B0B0B1;
	localparam [31:0] NO_RESULT = 32'hFFFFFFFF;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

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

	atg_top #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .HAS_CPU(1),
		.CPU_IMEM_INIT(IMEM), .CPU_DMEM_INIT(DMEM), .CPU_IMEM_WORDS(32768),
		.CPU_DMEM_WORDS(16384), .HAS_PROT(1), .PROT_SLOTS(31), .PROT_GRANTS(64),
		.PROT_GIDX_W(6), .PROT_PLB(16), .PROT_PLB_W(4)) dut (
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
		.pclk(1'b0), .prst_n(1'b0), .scl_i(1'b1), .sda_i(1'b1)
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
	integer n, k;
	integer wp;		/* the driver's ring write pointer */
	integer sp;		/* the staging's write pointer (words) */
	integer fence_value;

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

	`include "atg_top_prot_tb.vh"

	initial begin
		seed = 3;
		wp = 0;
		sp = 0;
		fence_value = 0;
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

		/* own: the driver's order, the sessions, each session's work in its memory. */
		bring_up;
		ring_open(TAG_A, 32'd1, 0);
		ring_open(TAG_B, 32'd1, 1);
		ring_open(TAG_C, 32'd0, 2);
		frame_begin;
		memory(0, 64'h100, AREA_B, 32'd0);
		buffer(1, 64'h200, 64'h100, 64'h0);
		pool(3, 64'h300);
		fill(4, 64'h400, 64'h200, DATA_B);
		frame_run(TAG_B, 9);
		check(mem.peek32(RING_RESULT) == 0 && mem.peek32(RING_RESULT + 8) == 0 &&
		      mem.peek32(RING_RESULT + 16) == 0 && mem.peek32(RING_RESULT + 56) == 0, "HEAP, the opens");
		check(results_ok(9), "B's frame");
		v = mem.peek32(AREA_B + 32'h1FFC);
		check(mem.peek32(AREA_B) == DATA_B && v == DATA_B, "B's fill");
		frame_begin;
		memory(0, 64'h100, AREA_A, 32'd0);
		buffer(1, 64'h200, 64'h100, 64'h0);
		buffer(3, 64'h201, 64'h100, 64'h4000);
		pool(5, 64'h300);
		fill(6, 64'h400, 64'h200, DATA_A);
		frame_run(TAG_A, 11);
		frame_begin;
		copy(0, 64'h401, 64'h200, 64'h201);
		frame_run(TAG_A, 5);
		check(results_ok(5), "A's frames");
		v = mem.peek32(AREA_A + 32'h4FFC);
		check(mem.peek32(AREA_A + 32'h4000) == DATA_A && v == DATA_A, "A's copy inside a");
		v = table_byte(AREA_A);
		check(v[5:0] != 6'd0 && v[7:6] == 2'd0 && table_byte(AREA_A + AREA_BYTES - 1) == v, "a's bytes");
		w = table_byte(AREA_B);
		check(w[5:0] != 6'd0 && w != v && table_byte(AREA_C) == 0, "b's bytes, c's none");
		check(table_byte(HEAP) == 32'h80, "the built-in part is public");
		group("own");

		/* refuse: A imports b with no grant and copies b to a. */
		frame_begin;
		memory(0, 64'h101, AREA_B, 32'd2);
		buffer(1, 64'h202, 64'h101, 64'h0);
		copy(3, 64'h402, 64'h202, 64'h200);
		ring_frame(TAG_A, 8);
		ring_fence(TAG_A);
		host_write(GHCI_RING_WPTR, wp);
		wait_state(GHCI_ST_FAULTED);
		host_read(GHCI_FAULT_INFO, v);
		check(v[15:12] == GHCI_FAULT_APERTURE && v[9] && v[31:24] == TAG_A, "FAULT_INFO of the copy");
		check(mem.peek32(AREA_A) == DATA_A, "a is not written");
		group("refuse");

		/* grant: RESET, the driver's order again, then GRANT(A, read, b) before A's frame. */
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RESET);
		wait_state(4'd0);
		bring_up;
		ring_open(TAG_A, 32'd1, 0);
		ring_open(TAG_B, 32'd1, 1);
		ring_open(TAG_C, 32'd0, 2);
		frame_begin;
		memory(0, 64'h100, AREA_B, 32'd0);
		frame_run(TAG_B, 1);
		ring_grant(TAG_A, AREA_B, 3);
		frame_begin;
		memory(0, 64'h100, AREA_A, 32'd0);
		buffer(1, 64'h200, 64'h100, 64'h0);
		memory(3, 64'h101, AREA_B, 32'd2);
		buffer(4, 64'h202, 64'h101, 64'h0);
		pool(6, 64'h300);
		copy(7, 64'h402, 64'h202, 64'h200);
		frame_run(TAG_A, 12);
		check(mem.peek32(RING_RESULT + 24) == 0 && results_ok(12), "GRANT and A's frame");
		check(mem.peek32(AREA_A) == DATA_B, "the granted copy b to a");
		frame_begin;
		memory(0, 64'h100, AREA_C, 32'd0);
		buffer(1, 64'h200, 64'h100, 64'h0);
		memory(3, 64'h101, AREA_B, 32'd2);
		buffer(4, 64'h202, 64'h101, 64'h0);
		pool(6, 64'h300);
		copy(7, 64'h402, 64'h202, 64'h200);
		frame_run(TAG_C, 12);
		check(results_ok(12) && mem.peek32(AREA_C) == DATA_B, "C copies b unchecked");
		ring_grant(TAG_A, AREA_B, 4);
		ring_revoke(TAG_A, AREA_B, 5);
		frame_begin;
		copy(0, 64'h403, 64'h202, 64'h200);
		frame_run(TAG_A, 5);
		check(mem.peek32(RING_RESULT + 32) == 0 && mem.peek32(RING_RESULT + 40) == 0 && results_ok(5),
		      "a second grant, one revoke");
		group("grant");

		/* revoke: the last grant goes; the copy faults. */
		ring_revoke(TAG_A, AREA_B, 6);
		frame_begin;
		copy(0, 64'h404, 64'h202, 64'h200);
		ring_frame(TAG_A, 5);
		ring_fence(TAG_A);
		host_write(GHCI_RING_WPTR, wp);
		wait_state(GHCI_ST_FAULTED);
		host_read(GHCI_FAULT_INFO, v);
		check(mem.peek32(RING_RESULT + 48) == 0 && v[15:12] == GHCI_FAULT_APERTURE && v[9] &&
		      v[31:24] == TAG_A, "FAULT_INFO after the revoke");
		group("revoke");

		if (errors == 0)
			$display("PASS atg_top_prot");
		else
			$display("FAIL atg_top_prot: %0d errors", errors);
		$finish;
	end

	initial begin
		#400000000;
		$display("FAIL atg_top_prot: timeout");
		$finish;
	end

	wire unused_ok = &{1'b0, irq, h_bid, h_bresp, h_rid, h_rresp, h_rlast};
endmodule

`default_nettype wire
