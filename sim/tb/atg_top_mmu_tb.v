/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_mmu_tb: end-to-end hardware MMU (atg_mmu + am_mmu_bridge + atg_cp_mmu
 * + atg_mc walker) integration test in atg_top with 40-bit VA and 48-bit PA.
 *
 * Driven strictly through the AXI host register port against dual AXI memory
 * (mem_lo at 0x0..0xFFFFF for ring/heap/PT, mem_hi at 48'h00AB_0000_0000 for
 * >4 GiB 48-bit physical targets behind am_axi_split).
 *
 * Groups:
 *   boot_caps          BOOT_CAPS reports HW_WALKER=1, PROT=1, VA=40, PA=48
 *   map_blt_hi48       SESSION_OPEN(2) + 4-level VM_MAP + BIND_SESSION + BLT FILL -> 48b PA
 *   su_exec_and_data   SU I$ (EXEC) + D$ (WRITE) via MMU -> 48b PA
 *   ro_perm_fault      L1-cached RO hit BLT write trap -> PERM_FAULT + session 2 isolation
 *   su_exec_perm_fault SU I$ fetch from NX page -> PERM_FAULT (UNIT_SU) + session 3 isolation
 *   unmap_s0_fault     Session 0 VM_MAP -> write -> VM_UNMAP -> PAGE_FAULT & STATUS.FAULTED
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_top_mmu_tb;
	`include "ghci_regs.vh"

	localparam IMEM = "fw/cp/images/atg1-cp-kc705.imem.hex";
	localparam DMEM = "fw/cp/images/atg1-cp-kc705.dmem.hex";

	localparam [47:0] PA_HI_BASE = 48'h00AB_0000_0000;
	localparam [31:0] APERTURE   = 32'h00001000;
	localparam [31:0] RING       = 32'h0005F000;
	localparam        RING_N     = 512;
	localparam [31:0] FENCES     = 32'h0005EF00;
	localparam [31:0] HEAP       = 32'h00080000;
	localparam [31:0] HEAP_BYTES = 32'h00060000;
	localparam [31:0] TABLE      = 32'h000F0000;
	localparam [31:0] RING_RESULT = 32'h00058C00;
	localparam [31:0] NO_RESULT  = 32'hFFFFFFFF;

	localparam [31:0] VM_FLAG_R  = 32'h00000001;
	localparam [31:0] VM_FLAG_W  = 32'h00000002;
	localparam [31:0] VM_FLAG_X  = 32'h00000004;

	localparam [7:0]  TAG_A      = 8'd2;
	localparam [7:0]  TAG_B      = 8'd3;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	integer seed = 7;
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

	wire m_awid, m_arid;
	wire [63:0] awaddr, araddr;
	wire [7:0] awlen, arlen;
	wire [2:0] awsize, arsize, awprot, arprot;
	wire [1:0] awburst, arburst, bresp, rresp;
	wire [3:0] awcache, arcache;
	wire awvalid, awready, wlast, wvalid, wready, bvalid, bready;
	wire arvalid, arready, rlast, rvalid, rready;
	wire [511:0] wdata, rdata;
	wire [63:0] wstrb;
	wire m_bid, m_rid;

	atg_top #(
		.VA_BITS(40),
		.PA_BITS(48),
		.LINE_BYTES(64),
		.LINE_SHIFT(6),
		.DATA_W(512),
		.HAS_CPU(1),
		.CPU_IMEM_INIT(IMEM),
		.CPU_DMEM_INIT(DMEM),
		.CPU_IMEM_WORDS(32768),
		.CPU_DMEM_WORDS(16384),
		.HAS_PROT(0),
		.HAS_HW_WALKER(1),
		.HAS_BLT(1),
		.NSU(1),
		.SU_NPHYS(8),
		.SU_GRP_W(2),
		.HAS_L2(0),
		.APERTURE_BASE_INIT(32'h00001000),
		.APERTURE_LIMIT_INIT(32'hFFFFFFFF)
	) dut (
		.clk(clk), .rst_n(rst_n), .irq(irq), .mem_ready(1'b1), .win_en(),
		.s_awaddr(h_awaddr), .s_awid(h_awid), .s_awvalid(h_awvalid), .s_awready(h_awready),
		.s_wdata(h_wdata), .s_wstrb(h_wstrb), .s_wlast(h_wlast), .s_wvalid(h_wvalid),
		.s_wready(h_wready), .s_bid(h_bid), .s_bresp(h_bresp), .s_bvalid(h_bvalid),
		.s_bready(h_bready), .s_araddr(h_araddr), .s_arid(h_arid), .s_arlen(h_arlen),
		.s_arvalid(h_arvalid), .s_arready(h_arready), .s_rdata(h_rdata), .s_rid(h_rid),
		.s_rresp(h_rresp), .s_rlast(h_rlast), .s_rvalid(h_rvalid), .s_rready(h_rready),
		.m_awid(m_awid), .m_bid(m_bid), .m_arid(m_arid), .m_rid(m_rid),
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
		.pclk(1'b0), .prst_n(1'b0), .pclk_sel(), .tmds(), .px_rgb(), .px_de(),
		.px_hs(), .px_vs(), .scl_t(), .scl_i(1'b1), .sda_t(), .sda_i(1'b1)
	);

	wire [47:0] m0_awaddr, m0_araddr, m1_awaddr, m1_araddr;
	wire [7:0] m0_awlen, m0_arlen, m1_awlen, m1_arlen;
	wire [2:0] m0_awsize, m0_arsize, m1_awsize, m1_arsize;
	wire [1:0] m0_awburst, m0_arburst, m0_bresp, m0_rresp;
	wire [1:0] m1_awburst, m1_arburst, m1_bresp, m1_rresp;
	wire m0_awvalid, m0_awready, m0_wlast, m0_wvalid, m0_wready, m0_bvalid, m0_bready;
	wire m0_arvalid, m0_arready, m0_rlast, m0_rvalid, m0_rready;
	wire m1_awvalid, m1_awready, m1_wlast, m1_wvalid, m1_wready, m1_bvalid, m1_bready;
	wire m1_arvalid, m1_arready, m1_rlast, m1_rvalid, m1_rready;
	wire [511:0] m0_wdata, m0_rdata, m1_wdata, m1_rdata;
	wire [63:0] m0_wstrb, m1_wstrb;
	wire m0_awid, m0_arid, m1_awid, m1_arid;

	am_axi_split #(
		.A_W(48),
		.D_W(512),
		.ID_W(1),
		.BASE0(48'h0000_0000_0000),
		.SIZE0(48'h0000_0010_0000),
		.BASE1(PA_HI_BASE),
		.SIZE1(48'h0000_0001_0000)
	) u_split (
		.clk(clk), .rst_n(rst_n),
		.s_awid(m_awid), .s_awaddr(awaddr[47:0]), .s_awlen(awlen), .s_awsize(awsize),
		.s_awburst(awburst), .s_awcache(awcache), .s_awprot(awprot),
		.s_awvalid(awvalid), .s_awready(awready),
		.s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast), .s_wvalid(wvalid), .s_wready(wready),
		.s_bid(m_bid), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
		.s_arid(m_arid), .s_araddr(araddr[47:0]), .s_arlen(arlen), .s_arsize(arsize),
		.s_arburst(arburst), .s_arcache(arcache), .s_arprot(arprot),
		.s_arvalid(arvalid), .s_arready(arready),
		.s_rid(m_rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast),
		.s_rvalid(rvalid), .s_rready(rready),
		.m0_awid(m0_awid), .m0_awaddr(m0_awaddr), .m0_awlen(m0_awlen), .m0_awsize(m0_awsize),
		.m0_awburst(m0_awburst), .m0_awcache(), .m0_awprot(),
		.m0_awvalid(m0_awvalid), .m0_awready(m0_awready),
		.m0_wdata(m0_wdata), .m0_wstrb(m0_wstrb), .m0_wlast(m0_wlast),
		.m0_wvalid(m0_wvalid), .m0_wready(m0_wready),
		.m0_bid(m0_awid), .m0_bresp(m0_bresp), .m0_bvalid(m0_bvalid), .m0_bready(m0_bready),
		.m0_arid(m0_arid), .m0_araddr(m0_araddr), .m0_arlen(m0_arlen), .m0_arsize(m0_arsize),
		.m0_arburst(m0_arburst), .m0_arcache(), .m0_arprot(),
		.m0_arvalid(m0_arvalid), .m0_arready(m0_arready),
		.m0_rid(m0_arid), .m0_rdata(m0_rdata), .m0_rresp(m0_rresp), .m0_rlast(m0_rlast),
		.m0_rvalid(m0_rvalid), .m0_rready(m0_rready),
		.m1_awid(m1_awid), .m1_awaddr(m1_awaddr), .m1_awlen(m1_awlen), .m1_awsize(m1_awsize),
		.m1_awburst(m1_awburst), .m1_awcache(), .m1_awprot(),
		.m1_awvalid(m1_awvalid), .m1_awready(m1_awready),
		.m1_wdata(m1_wdata), .m1_wstrb(m1_wstrb), .m1_wlast(m1_wlast),
		.m1_wvalid(m1_wvalid), .m1_wready(m1_wready),
		.m1_bid(m1_awid), .m1_bresp(m1_bresp), .m1_bvalid(m1_bvalid), .m1_bready(m1_bready),
		.m1_arid(m1_arid), .m1_araddr(m1_araddr), .m1_arlen(m1_arlen), .m1_arsize(m1_arsize),
		.m1_arburst(m1_arburst), .m1_arcache(), .m1_arprot(),
		.m1_arvalid(m1_arvalid), .m1_arready(m1_arready),
		.m1_rid(m1_arid), .m1_rdata(m1_rdata), .m1_rresp(m1_rresp), .m1_rlast(m1_rlast),
		.m1_rvalid(m1_rvalid), .m1_rready(m1_rready)
	);

	axi_mem #(.DATA_W(512), .MEM_BYTES(1 << 20), .READ_EARLY(1), .SEED(7)) mem (
		.clk(clk), .rst_n(rst_n),
		.awaddr(m0_awaddr[31:0]), .awlen(m0_awlen), .awsize(m0_awsize), .awburst(m0_awburst),
		.awvalid(m0_awvalid), .awready(m0_awready), .wdata(m0_wdata), .wstrb(m0_wstrb),
		.wlast(m0_wlast), .wvalid(m0_wvalid), .wready(m0_wready), .bresp(m0_bresp),
		.bvalid(m0_bvalid), .bready(m0_bready), .araddr(m0_araddr[31:0]), .arlen(m0_arlen),
		.arsize(m0_arsize), .arburst(m0_arburst), .arvalid(m0_arvalid), .arready(m0_arready),
		.rdata(m0_rdata), .rresp(m0_rresp), .rlast(m0_rlast), .rvalid(m0_rvalid), .rready(m0_rready)
	);

	axi_mem #(.DATA_W(512), .MEM_BYTES(1 << 16), .READ_EARLY(1), .SEED(11)) mem_hi (
		.clk(clk), .rst_n(rst_n),
		.awaddr({16'd0, m1_awaddr[15:0]}), .awlen(m1_awlen), .awsize(m1_awsize), .awburst(m1_awburst),
		.awvalid(m1_awvalid), .awready(m1_awready), .wdata(m1_wdata), .wstrb(m1_wstrb),
		.wlast(m1_wlast), .wvalid(m1_wvalid), .wready(m1_wready), .bresp(m1_bresp),
		.bvalid(m1_bvalid), .bready(m1_bready),
		.araddr({16'd0, m1_araddr[15:0]}), .arlen(m1_arlen), .arsize(m1_arsize), .arburst(m1_arburst),
		.arvalid(m1_arvalid), .arready(m1_arready),
		.rdata(m1_rdata), .rresp(m1_rresp), .rlast(m1_rlast), .rvalid(m1_rvalid), .rready(m1_rready)
	);

	`include "axi_host.vh"

	integer errors = 0, before = 0;
	integer wp = 0;
	integer fence_value = 0;
	reg [31:0] v, prot, off, w;
	integer n;

	task check;
		input ok;
		input [8*40-1:0] what;
		begin
			if (!ok) begin
				errors = errors + 1;
				$display("FAIL atg_top_mmu: %0s (%h)", what, v);
			end
		end
	endtask

	task group;
		input [8*20-1:0] name;
		begin
			if (errors == before)
				$display("PASS atg_top_mmu.%0s", name);
			else
				$display("FAIL atg_top_mmu.%0s: %0d errors", name, errors - before);
			before = errors;
		end
	endtask

	task wait_reg;
		input [16:0] reg_off;
		input [31:0] want;
		input [31:0] mask;
		input integer polls;
		reg [31:0] got;
		integer k;
		begin
			k = 0;
			host_read(reg_off, got);
			while ((got & mask) != (want & mask) && k < polls) begin
				host_read(reg_off, got);
				k = k + 1;
			end
			if ((got & mask) != (want & mask)) begin : g_wreg_fail
				reg [31:0] st_v, fi_v, fa_v, rp_v, sa_v;
				errors = errors + 1;
				$display("FAIL atg_top_mmu: reg %h stays %h (want %h)", reg_off, got, want);
				host_read(GHCI_STATUS, st_v);
				host_read(GHCI_FAULT_INFO, fi_v);
				host_read(GHCI_FAULT_ADDR, fa_v);
				host_read(GHCI_RING_RPTR, rp_v);
				host_read(GHCI_REG_SESSION_ACTIVE, sa_v);
				$display("  STATUS=%h FAULT_INFO=%h FAULT_ADDR=%h RPTR=%0d (WP=%0d) SESS_ACT=%h",
					st_v, fi_v, fa_v, rp_v, wp, sa_v);
				$finish;
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
		begin
			fence_value = fence_value + 1;
			ring_put({2'b00, 6'd5, tag, 8'd1, 8'd2});
			ring_put(FENCES);
			ring_put(fence_value);
		end
	endtask

	task ring_doorbell;
		begin
			ring_fence(8'd0);
			host_write(GHCI_RING_WPTR, wp);
			wait_reg(GHCI_LEGACY_FENCE_LAST, fence_value, 32'hFFFFFFFF, 60000);
		end
	endtask

	task ring_open;
		input [7:0] tag;
		input [31:0] flags;
		input integer slot;
		begin
			ring_put({2'b10, 6'd0, tag, 16'd7});
			ring_put(32'h00010100);	/* GHCI_SESSION_OPEN */
			ring_put(32'd2);
			ring_put(RING_RESULT + slot * 8);
			ring_put({24'd0, tag});
			ring_put(flags);
			ring_put(32'h00040000);
			ring_put(32'd0);
			ring_doorbell;
		end
	endtask

	task ring_vm_map;
		input [31:0] sess;
		input [31:0] flags;
		input [63:0] va;
		input [63:0] pa;
		input [63:0] sz;
		input integer slot;
		begin
			ring_put({2'b10, 6'd0, 8'd0, 16'd12});
			ring_put(32'h00010110);	/* GHCI_GPU_OP_VM_MAP */
			ring_put(32'd2);
			ring_put(RING_RESULT + slot * 8);
			ring_put(sess);
			ring_put(flags);
			ring_put(32'd0);
			ring_put(va[31:0]);
			ring_put(va[63:32]);
			ring_put(pa[31:0]);
			ring_put(pa[63:32]);
			ring_put(sz[31:0]);
			ring_put(sz[63:32]);
			ring_doorbell;
		end
	endtask

	task ring_vm_unmap;
		input [31:0] sess;
		input [63:0] va;
		input [63:0] sz;
		input integer slot;
		begin
			ring_put({2'b10, 6'd0, 8'd0, 16'd10});
			ring_put(32'h00010111);	/* GHCI_GPU_OP_VM_UNMAP */
			ring_put(32'd2);
			ring_put(RING_RESULT + slot * 8);
			ring_put(sess);
			ring_put(32'd0);
			ring_put(32'd0);
			ring_put(va[31:0]);
			ring_put(va[63:32]);
			ring_put(sz[31:0]);
			ring_put(sz[63:32]);
			ring_doorbell;
		end
	endtask

	task ring_bind_session;
		input [3:0] sess;
		begin
			ring_put(32'h00000214);	/* CMD_BIND_SESSION (opcode 0x14, dwords=2) */
			ring_put({28'd0, sess});
		end
	endtask

	task bring_up;
		integer i;
		begin
			wp = 0;
			host_write(GHCI_LEGACY_APERTURE_BASE, APERTURE);
			host_write(GHCI_LEGACY_APERTURE_LIMIT, 32'hFFFFFFFF);
			host_write(GHCI_RING_BASE, RING);
			host_write(GHCI_RING_SIZE, 32'h00001000);
			host_write(GHCI_IRQ_STATUS, 32'h1FF);
			mem.poke32(FENCES, fence_value);
			host_write(GHCI_LEGACY_FENCE_LAST, fence_value);
			host_write(GHCI_CPFW_CTRL, 32'd1 << GHCI_CPFW_CTRL_RUN);
			wait_reg(GHCI_CPFW_STATUS, 32'h0201, 32'hFF09, 80000);
			host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RUN);
			if (prot != 32'd0) begin
				for (i = 0; i < 1024; i = i + 1)
					mem.poke32(TABLE + i * 4, 32'd0);
				host_write(prot[16:0] + GHCI_PROT_TABLE, TABLE);
			end
			for (i = 0; i < 16; i = i + 1)
				mem.poke32(RING_RESULT + i * 4, NO_RESULT);
			ring_put({2'b10, 6'd0, 8'd0, 16'd8});
			ring_put(32'h00010108);	/* GHCI_HEAP */
			ring_put(32'd2);
			ring_put(RING_RESULT + 56);
			ring_put(HEAP);
			ring_put(32'd0);
			ring_put(HEAP_BYTES);
			ring_put(32'd0);
			ring_put(32'd4);
			ring_doorbell;
			v = mem.peek32(RING_RESULT + 56);
			check(v == 32'd0, "GHCI_HEAP status");
		end
	endtask

	task wait_session_fault;
		input [7:0] tag;
		reg [31:0] act, info;
		integer polls;
		begin
			polls = 0;
			host_read(GHCI_REG_SESSION_ACTIVE, act);
			host_read(GHCI_FAULT_INFO, info);
			while ((act[tag] != 1'b0 || info == 32'd0) && polls < 40000) begin
				host_read(GHCI_REG_SESSION_ACTIVE, act);
				host_read(GHCI_FAULT_INFO, info);
				polls = polls + 1;
			end
			v = info;
			check(act[tag] == 1'b0 && info != 32'd0, "session fault captured");
		end
	endtask

	initial begin
		repeat (4) @(posedge clk);
		rst_n = 1'b1;
		repeat (4) @(posedge clk);

		/* 1. boot_caps */
		host_read(GHCI_REG_BOOT_CAPS, v);
		check(v[0] == 1'b1 && v[1] == 1'b1 && v[2] == 1'b0, "BOOT_CAPS WALKER=1 PROT=0");
		check(v[11:8] == 4'd10 && v[15:12] == 4'd8, "BOOT_CAPS VA=40 PA=48");

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
		group("boot_caps");

		/* 2. map_blt_hi48: open session 2, map VA 0x80000000 -> PA 48'h00AB_0000_2000 */
		bring_up;
		ring_open(TAG_A, 32'd0, 0);
		v = mem.peek32(RING_RESULT);
		check(v == 32'd0, "SESSION_OPEN(TAG_A)");
		host_read(GHCI_REG_SESSION_ACTIVE, v);
		check(v[TAG_A] == 1'b1, "SESSION_ACTIVE[TAG_A]");

		ring_vm_map({24'd0, TAG_A}, VM_FLAG_R | VM_FLAG_W, 64'h0000_0000_8000_0000,
			PA_HI_BASE + 48'h2000, 64'h2000, 1);
		v = mem.peek32(RING_RESULT + 8);
		check(v == 32'd0, "VM_MAP(TAG_A, RW, PA_HI)");

		ring_bind_session(TAG_A[3:0]);
		ring_put({1'b0, 1'b0, 6'd1, TAG_A, 8'd0, 8'd14});	/* OP_SET_REG (7 pairs) */
		ring_set(GHCI_S_BLT_OP, {30'd0, GHCI_BLT_FILL});
		ring_set(GHCI_S_BLT_DST_BASE, 32'h8000_0000);
		ring_set(GHCI_S_BLT_DST_STRIDE, 32'd16);
		ring_set(GHCI_S_BLT_DST_XY, 32'd0);
		ring_set(GHCI_S_BLT_SIZE, {16'd1, 16'd4});
		ring_set(GHCI_S_BLT_COLOR, 32'hCAFE_BABE);
		ring_set(GHCI_S_BLT_CLIP_MAX, 32'd0);
		ring_put({1'b0, 1'b0, 6'd2, TAG_A, 8'd1, 8'd0});	/* KICK BLT + WAIT */
		ring_doorbell;

		v = mem_hi.peek32(32'h2000);
		check(v == 32'hCAFE_BABE, "mem_hi[0x2000] == CAFE_BABE");
		v = mem_hi.peek32(32'h200C);
		check(v == 32'hCAFE_BABE, "mem_hi[0x200C] == CAFE_BABE");
		group("map_blt_hi48");

		/* 3. su_exec_and_data: SU I$ (EXEC) + D$ (WRITE) -> PA_HI */
		mem_hi.poke32(32'h8000, 32'h800000b7);	/* lui x1, 0x80000 (VA 0x8000_0000) */
		mem_hi.poke32(32'h8004, 32'h00000000);
		mem_hi.poke32(32'h8008, 32'h12345137);	/* lui x2, 0x12345 */
		mem_hi.poke32(32'h800C, 32'h00000000);
		mem_hi.poke32(32'h8010, 32'h67810113);	/* addi x2, x2, 0x678 -> 0x12345678 */
		mem_hi.poke32(32'h8014, 32'h00000000);
		mem_hi.poke32(32'h8018, 32'h1020a023);	/* sw x2, 0x100(x1) -> VA 0x8000_0100 */
		mem_hi.poke32(32'h801C, 32'h00000000);
		mem_hi.poke32(32'h8020, 32'h0000700b);	/* exit */
		mem_hi.poke32(32'h8024, 32'h00000000);

		ring_vm_map({24'd0, TAG_A}, VM_FLAG_R | VM_FLAG_X, 64'h0000_0000_8001_0000,
			PA_HI_BASE + 48'h8000, 64'h1000, 2);
		v = mem.peek32(RING_RESULT + 16);
		check(v == 32'd0, "VM_MAP(TAG_A, RX, code PA_HI)");

		ring_bind_session(TAG_A[3:0]);
		ring_put({1'b0, 1'b0, 6'd1, TAG_A, 8'd0, 8'd6});	/* OP_SET_REG (3 pairs) */
		ring_set(9'h194, 32'h8001_0000);	/* CS_BASE */
		ring_set(9'h195, 32'd10);		/* CS_WORDS */
		ring_set(9'h199, 32'h0001_0101);	/* WG_SIZE = 1x1x1 */
		ring_put({1'b0, 1'b0, 6'd12, TAG_A, 8'd1, 8'd0}); /* INVALIDATE */
		ring_put({1'b0, 1'b0, 6'd8, TAG_A, 8'd0, 8'd1});	/* LOAD_PROGRAM(CS) */
		ring_put(32'h00000002);
		ring_put({1'b0, 1'b0, 6'd4, TAG_A, 8'd0, 8'd3});	/* DISPATCH 1x1x1 */
		ring_put(32'd1);
		ring_put(32'd1);
		ring_put(32'd1);
		ring_doorbell;

		v = mem_hi.peek32(32'h2100);
		check(v == 32'h12345678, "SU D$ wrote 0x12345678 to mem_hi[0x2100]");
		group("su_exec_and_data");

		/* 4. ro_perm_fault: cached L1 RO page rejects write in session 2 without halting GPU */
		mem_hi.poke32(32'h4000, 32'hA5A5_5A5A);
		ring_vm_map({24'd0, TAG_A}, VM_FLAG_R, 64'h0000_0000_8002_0000,
			PA_HI_BASE + 48'h4000, 64'h1000, 3);
		v = mem.peek32(RING_RESULT + 24);
		check(v == 32'd0, "VM_MAP(TAG_A, RO, 0x80020000)");

		/* Read from RO page -> warms L1 TLB with W=0 */
		ring_bind_session(TAG_A[3:0]);
		ring_put({1'b0, 1'b0, 6'd1, TAG_A, 8'd0, 8'd18});	/* OP_SET_REG (9 pairs) */
		ring_set(GHCI_S_BLT_OP, {30'd0, GHCI_BLT_COPY});
		ring_set(GHCI_S_BLT_DST_BASE, 32'h8000_0200);
		ring_set(GHCI_S_BLT_DST_STRIDE, 32'd16);
		ring_set(GHCI_S_BLT_SRC_BASE, 32'h8002_0000);
		ring_set(GHCI_S_BLT_SRC_STRIDE, 32'd16);
		ring_set(GHCI_S_BLT_DST_XY, 32'd0);
		ring_set(GHCI_S_BLT_SRC_XY, 32'd0);
		ring_set(GHCI_S_BLT_SIZE, {16'd1, 16'd1});
		ring_set(GHCI_S_BLT_CLIP_MAX, 32'd0);
		ring_put({1'b0, 1'b0, 6'd2, TAG_A, 8'd1, 8'd0});	/* KICK BLT + WAIT */
		ring_doorbell;
		v = mem_hi.peek32(32'h2200);
		check(v == 32'hA5A5_5A5A, "BLT COPY from RO page succeeded");

		/* Now write to cached RO page -> triggers L1-hit PERM_FAULT (kind 10) on TAG_A */
		ring_put({1'b0, 1'b0, 6'd1, TAG_A, 8'd0, 8'd14});
		ring_set(GHCI_S_BLT_OP, {30'd0, GHCI_BLT_FILL});
		ring_set(GHCI_S_BLT_DST_BASE, 32'h8002_0000);
		ring_set(GHCI_S_BLT_DST_STRIDE, 32'd16);
		ring_set(GHCI_S_BLT_DST_XY, 32'd0);
		ring_set(GHCI_S_BLT_SIZE, {16'd1, 16'd1});
		ring_set(GHCI_S_BLT_COLOR, 32'hDEAD_BEEF);
		ring_set(GHCI_S_BLT_CLIP_MAX, 32'd0);
		ring_put({1'b0, 1'b0, 6'd2, TAG_A, 8'd0, 8'd0});
		ring_fence(TAG_A);
		host_write(GHCI_RING_WPTR, wp);
		wait_session_fault(TAG_A);

		host_read(GHCI_STATUS, v);
		check(v[GHCI_STATUS_FAULTED] == 1'b0 && v[GHCI_STATUS_RUNNING] == 1'b1, "GPU running after RO perm fault");
		host_read(GHCI_FAULT_INFO, v);
		check(v[3:0] == GHCI_FAULT_KIND_PERM_FAULT && v[7:4] == GHCI_FAULT_UNIT_BLT && v[15:8] == TAG_A,
			"FAULT_INFO BLT PERM_FAULT TAG_A");
		host_write(GHCI_REG_FAULT_INFO, v);	/* W1C clear */
		v = mem_hi.peek32(32'h4000);
		check(v == 32'hA5A5_5A5A, "RO page mem_hi untouched");
		group("ro_perm_fault");

		/* 5. su_exec_perm_fault: open session 3, map code without EXEC -> SU I$ traps PERM_FAULT */
		ring_open(TAG_B, 32'd0, 4);
		v = mem.peek32(RING_RESULT + 32);
		check(v == 32'd0, "SESSION_OPEN(TAG_B)");
		ring_vm_map({24'd0, TAG_B}, VM_FLAG_R | VM_FLAG_W, 64'h0000_0000_8003_0000,
			PA_HI_BASE + 48'h8000, 64'h1000, 5);
		v = mem.peek32(RING_RESULT + 40);
		check(v == 32'd0, "VM_MAP(TAG_B, RW no EXEC)");

		ring_bind_session(TAG_B[3:0]);
		ring_put({1'b0, 1'b0, 6'd1, TAG_B, 8'd0, 8'd6});
		ring_set(9'h194, 32'h8003_0000);
		ring_set(9'h195, 32'd10);
		ring_set(9'h199, 32'h0001_0101);
		ring_put({1'b0, 1'b0, 6'd12, TAG_B, 8'd1, 8'd0});
		ring_put({1'b0, 1'b0, 6'd8, TAG_B, 8'd0, 8'd1});	/* LOAD_PROGRAM(CS) */
		ring_put(32'h00000002);
		ring_put({1'b0, 1'b0, 6'd4, TAG_B, 8'd0, 8'd3});	/* DISPATCH 1x1x1 */
		ring_put(32'd1);
		ring_put(32'd1);
		ring_put(32'd1);
		ring_fence(TAG_B);
		host_write(GHCI_RING_WPTR, wp);
		wait_session_fault(TAG_B);

		host_read(GHCI_STATUS, v);
		check(v[GHCI_STATUS_FAULTED] == 1'b0 && v[GHCI_STATUS_RUNNING] == 1'b1, "GPU running after SU NX fault");
		host_read(GHCI_FAULT_INFO, v);
		check(v[3:0] == GHCI_FAULT_KIND_PERM_FAULT && v[7:4] == GHCI_FAULT_UNIT_SU && v[15:8] == TAG_B,
			"FAULT_INFO SU PERM_FAULT TAG_B");
		host_write(GHCI_REG_FAULT_INFO, v);
		group("su_exec_perm_fault");

		/* 6. unmap_s0_fault: Session 0 map -> write -> VM_UNMAP -> PAGE_FAULT + STATUS.FAULTED */
		ring_open(8'd0, 32'd0, 6);
		v = mem.peek32(RING_RESULT + 48);
		check(v == 32'd0, "SESSION_OPEN(0)");
		ring_vm_map(32'd0, VM_FLAG_R | VM_FLAG_W, 64'h0000_0000_8004_0000,
			PA_HI_BASE + 48'h6000, 64'h1000, 7);
		v = mem.peek32(RING_RESULT + 56);
		check(v == 32'd0, "VM_MAP(0, RW)");

		ring_bind_session(4'd0);
		ring_put({1'b0, 1'b0, 6'd1, 8'd0, 8'd0, 8'd14});
		ring_set(GHCI_S_BLT_OP, {30'd0, GHCI_BLT_FILL});
		ring_set(GHCI_S_BLT_DST_BASE, 32'h8004_0000);
		ring_set(GHCI_S_BLT_DST_STRIDE, 32'd16);
		ring_set(GHCI_S_BLT_DST_XY, 32'd0);
		ring_set(GHCI_S_BLT_SIZE, {16'd1, 16'd1});
		ring_set(GHCI_S_BLT_COLOR, 32'hBEEF_F00D);
		ring_set(GHCI_S_BLT_CLIP_MAX, 32'd0);
		ring_put({1'b0, 1'b0, 6'd2, 8'd0, 8'd1, 8'd0});
		ring_doorbell;
		v = mem_hi.peek32(32'h6000);
		check(v == 32'hBEEF_F00D, "Session 0 mapped write succeeded");

		ring_vm_unmap(32'd0, 64'h0000_0000_8004_0000, 64'h1000, 6);
		v = mem.peek32(RING_RESULT + 48);
		check(v == 32'd0, "VM_UNMAP(0, 0x80040000)");

		ring_bind_session(4'd0);
		ring_put({1'b0, 1'b0, 6'd1, 8'd0, 8'd0, 8'd14});
		ring_set(GHCI_S_BLT_OP, {30'd0, GHCI_BLT_FILL});
		ring_set(GHCI_S_BLT_DST_BASE, 32'h8004_0000);
		ring_set(GHCI_S_BLT_DST_STRIDE, 32'd16);
		ring_set(GHCI_S_BLT_DST_XY, 32'd0);
		ring_set(GHCI_S_BLT_SIZE, {16'd1, 16'd1});
		ring_set(GHCI_S_BLT_COLOR, 32'hBAD0_0000);
		ring_set(GHCI_S_BLT_CLIP_MAX, 32'd0);
		ring_put({1'b0, 1'b0, 6'd2, 8'd0, 8'd0, 8'd0});
		host_write(GHCI_RING_WPTR, wp);

		wait_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_FAULTED, 32'd1 << GHCI_STATUS_FAULTED, 40000);
		host_read(GHCI_FAULT_INFO, v);
		check(v[3:0] == GHCI_FAULT_KIND_PAGE_FAULT && v[7:4] == GHCI_FAULT_UNIT_BLT && v[15:8] == 8'd0,
			"Session 0 PAGE_FAULT FAULT_INFO");
		host_read(GHCI_FAULT_ADDR, v);
		check(v == 32'h8004_0000, "Session 0 PAGE_FAULT FAULT_ADDR");
		v = mem_hi.peek32(32'h6000);
		check(v == 32'hBEEF_F00D, "Unmapped write did not reach mem_hi");
		group("unmap_s0_fault");

		if (errors == 0)
			$display("PASS atg_top_mmu");
		else
			$display("FAIL atg_top_mmu: %0d errors", errors);
		$finish;
	end

	initial begin
		#300000000;
		$display("FAIL atg_top_mmu: timeout");
		$finish;
	end

	wire unused_ok = &{1'b0, irq, h_bid, h_bresp, h_rid, h_rresp, h_rlast};
endmodule

`default_nettype wire
