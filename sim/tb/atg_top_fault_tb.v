/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_fault_tb: Full GPU top-level integration testbench for GHCI 1.0
 * fault reporting and pipeline stage tracking (§3.5, §7.3, §12.6, §12.8).
 *
 * Tests:
 *   - Scenario 1 & 2: Fragment Shader (FS) invalid opcode during concurrent
 *     VS + FS draw:
 *       * FAULT_INFO KIND = 1 (GHCI_FAULT_KIND_INVALID_OP)
 *       * FAULT_INFO UNIT = 2 (GHCI_FAULT_UNIT_SU)
 *       * FAULT_INFO SHADER_STAGE = 1 (GHCI_STAGE_FS, not VS)
 *       * FAULT_ADDR = 1 (relative instruction index from FS entry point)
 *       * Subsequent CMD_FENCE in ring is not executed (unwritten to memory)
 *       * IRQ_STATUS bit 1 (FAULT) asserted
 *   - Scenario 3: Fragment Shader out-of-bounds load (MC aperture refusal):
 *       * FAULT_INFO KIND = 9 (GHCI_FAULT_KIND_PAGE_FAULT)
 *       * FAULT_INFO UNIT = 2 (GHCI_FAULT_UNIT_SU)
 *       * FAULT_INFO SHADER_STAGE = 1 (GHCI_STAGE_FS)
 *       * FAULT_ADDR = faulting aperture address (0xE0000000)
 *   - Scenario 4: Command Processor CMD_FENCE memory write triggering AXI SLVERR:
 *       * FAULT_INFO KIND = 5 (GHCI_FAULT_KIND_AXI_ERROR)
 *       * FAULT_INFO UNIT = 0 (GHCI_FAULT_UNIT_CP)
 *       * FAULT_ADDR = fence memory address (0xF0000000)
 *   - Scenario 5: HAS_CPU = 0 configuration VF client mapping:
 *       * Verified in sim/tb/atg_cp_ctl_tb.v lines 632-643 (C_VF=2 maps to UNIT 1).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_top_fault_tb;
	`include "ghci_regs.vh"

	localparam LINE_BYTES = 64;
	localparam LINE_SHIFT = 6;
	localparam DATA_W = 512;
	localparam [31:0] EXP_GCLK = 32'd200000000;
	localparam [31:0] LOCAL_BASE = 32'h80000000;
	localparam [31:0] LOCAL_BYTES = 32'h40000000;
	localparam [31:0] WINDOW_BYTES = 32'h04000000;
	localparam [31:0] HOST_LIMIT = 32'h80000000;
	localparam [31:0] APERTURE_BASE_INIT = 32'h00000000;
	localparam [31:0] APERTURE_LIMIT_INIT = 32'hC0000000;
	localparam [15:0] SUBSYSTEM_VENDOR = 16'h10EE;
	localparam [15:0] SUBSYSTEM_DEVICE = 16'h0007;

	localparam RING   = 32'h00004000;
	localparam FENCES = 32'h00008000;
	localparam POS    = 32'h00010000;
	localparam COL    = 32'h00010100;
	localparam VS_PC  = 32'h00012000;
	localparam FS_PC  = 32'h00013000;
	localparam RT     = 32'h00020000;
	localparam DS     = 32'h00030000;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	/* Host AXI-Lite interface */
	reg [16:0] h_awaddr = 0;
	reg [3:0] h_awid = 0;
	reg h_awvalid = 1'b0;
	wire h_awready;
	reg [63:0] h_wdata = 0;
	reg [7:0] h_wstrb = 0;
	reg h_wlast = 1'b0;
	reg h_wvalid = 1'b0;
	wire h_wready;
	wire [3:0] h_bid;
	wire [1:0] h_bresp;
	wire h_bvalid;
	reg h_bready = 1'b0;
	reg [16:0] h_araddr = 0;
	reg [3:0] h_arid = 0;
	reg [7:0] h_arlen = 0;
	reg h_arvalid = 1'b0;
	wire h_arready;
	wire [63:0] h_rdata;
	wire [3:0] h_rid;
	wire [1:0] h_rresp;
	wire h_rlast;
	wire h_rvalid;
	reg h_rready = 1'b0;
	wire irq;

	/* Memory AXI interface */
	wire [63:0] awaddr, araddr;
	wire [7:0] awlen, arlen;
	wire [2:0] awsize, arsize, awprot, arprot;
	wire [1:0] awburst, arburst, bresp, rresp;
	wire [3:0] awcache, arcache;
	wire awvalid, awready, wlast, wvalid, wready, bvalid, bready;
	wire arvalid, arready, rlast, rvalid, rready;
	wire [DATA_W-1:0] wdata, rdata;
	wire [DATA_W/8-1:0] wstrb;
	wire m_awid, m_bid, m_arid, m_rid;

	reg [15:0] ar_id_q = 0;
	reg [3:0] ar_id_wp = 0, ar_id_rp = 0;
	reg [15:0] aw_id_q = 0;
	reg [3:0] aw_id_wp = 0, aw_id_rp = 0;

	always @(posedge clk) begin
		if (!rst_n) begin
			ar_id_wp <= 4'd0;
			ar_id_rp <= 4'd0;
			aw_id_wp <= 4'd0;
			aw_id_rp <= 4'd0;
		end else begin
			if (arvalid && arready) begin
				ar_id_q[ar_id_wp] <= m_arid;
				ar_id_wp <= ar_id_wp + 1'b1;
			end
			if (rvalid && rready && rlast) begin
				ar_id_rp <= ar_id_rp + 1'b1;
			end
			if (awvalid && awready) begin
				aw_id_q[aw_id_wp] <= m_awid;
				aw_id_wp <= aw_id_wp + 1'b1;
			end
			if (bvalid && bready) begin
				aw_id_rp <= aw_id_rp + 1'b1;
			end
		end
	end
	assign m_rid = ar_id_q[ar_id_rp];
	assign m_bid = aw_id_q[aw_id_rp];

	atg_top #(
		.GCLK_HZ(EXP_GCLK),
		.S_ID_W(4),
		.S_LEN_W(8),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.DATA_W(DATA_W),
		.LOCAL_BASE(LOCAL_BASE),
		.LOCAL_BYTES(LOCAL_BYTES),
		.WINDOW_BYTES(WINDOW_BYTES),
		.HOST_LIMIT(HOST_LIMIT),
		.APERTURE_BASE_INIT(APERTURE_BASE_INIT),
		.APERTURE_LIMIT_INIT(APERTURE_LIMIT_INIT),
		.SUBSYSTEM_VENDOR(SUBSYSTEM_VENDOR),
		.SUBSYSTEM_DEVICE(SUBSYSTEM_DEVICE),
		.HAS_CPU(1),
		.NSU(1),
		.HAS_VF(1),
		.HAS_RX(1),
		.HAS_TU(1),
		.HAS_ROP(1),
		.HAS_DISP(0),
		.HAS_BLT(1),
		.HAS_L2(0),
		.SU_NPHYS(8),
		.SU_NWARPS(4),
		.SU_WARP_W(2),
		.SU_GRP_W(2),
		.SU_NREGS(32),
		.SU_SB_ENTRIES(4),
		.SU_SBE_W(2),
		.SU_LDS_BYTES(4096),
		.SU_VARY_WORDS(16),
		.ROP_STENCIL(1)
	) dut (
		.clk(clk), .rst_n(rst_n), .irq(irq), .mem_ready(1'b1),
		.win_en(),
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
		.pclk(1'b0), .prst_n(1'b0), .scl_i(1'b1), .sda_i(1'b1),
		.j_wr(1'b0), .j_waddr(17'd0), .j_wdata(32'd0), .j_wstrb(4'd0), .j_rd(1'b0),
		.j_raddr(17'd0), .j_rdata(), .j_busy()
	);

	axi_mem #(.DATA_W(DATA_W), .MEM_BYTES(1 << 19), .READ_EARLY(1), .SEED(1)) mem (
		.clk(clk), .rst_n(rst_n),
		.awaddr(awaddr[31:0]), .awlen(awlen), .awsize(awsize), .awburst(awburst),
		.awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
		.wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp),
		.bvalid(bvalid), .bready(bready), .araddr(araddr[31:0]), .arlen(arlen),
		.arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
		.rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
	);

	integer seed = 1;
	`include "axi_host.vh"

	integer errors = 0;
	task check32;
		input [8*60-1:0] msg;
		input [31:0] got;
		input [31:0] want;
		begin
			if (got !== want) begin
				errors = errors + 1;
				$display("FAIL atg_top_fault: %0s got %08h, expected %08h", msg, got, want);
			end else begin
				$display("PASS atg_top_fault: %0s == %08h", msg, got);
			end
		end
	endtask

	task reset_gpu;
		reg [31:0] val;
		integer to_cnt;
		begin
			host_write(GHCI_REG_CTRL, (1 << GHCI_CTRL_RESET));
			#50;
			host_write(GHCI_REG_CTRL, 32'd0);
			#100;
			to_cnt = 0;
			host_read(GHCI_REG_CTRL, val);
			while (val[GHCI_CTRL_RESET] && to_cnt < 2000) begin
				#50;
				host_read(GHCI_REG_CTRL, val);
				to_cnt = to_cnt + 1;
			end
			host_write(GHCI_REG_RING_BASE_LO, RING);
			host_write(GHCI_REG_RING_BASE_HI, 32'h00000000);
			host_write(GHCI_REG_RING_SIZE,    32'h00010000);
			host_write(GHCI_REG_RING_WPTR,    32'd0);
			host_write(GHCI_REG_CTRL, (1 << GHCI_CTRL_RUN) | (1 << GHCI_CTRL_IRQ_GLOBAL));
			host_write(GHCI_REG_IRQ_ENABLE, (1 << GHCI_IRQ_FAULT) | (1 << GHCI_IRQ_FENCE));
			/* Clear FAULT_INFO latch */
			host_write(GHCI_REG_FAULT_INFO, 32'hFFFFFFFF);
			host_write(GHCI_REG_IRQ_STATUS, 32'hFFFFFFFF);
		end
	endtask

	integer i, wp, to_cnt;
	reg [31:0] val;

	initial begin
		errors = 0;
		#20;
		rst_n = 1'b1;
		#50;

		$display("=== atg_top_fault_tb: Top-level Fault Verification ===");

		/* -------------------------------------------------------------
		 * Initialize Common Geometic Data and Vertex Shader
		 * ------------------------------------------------------------- */
		/* POS: 2 clip-space triangles (6 vertices, 16 bytes each) */
		/* V0: (0.0, 0.5, 0.5, 1.0) */
		mem.poke32(POS +  0, 32'h00000000); mem.poke32(POS +  4, 32'h3F000000);
		mem.poke32(POS +  8, 32'h3F000000); mem.poke32(POS + 12, 32'h3F800000);
		/* V1: (-0.5, -0.5, 0.5, 1.0) */
		mem.poke32(POS + 16, 32'hBF000000); mem.poke32(POS + 20, 32'hBF000000);
		mem.poke32(POS + 24, 32'h3F000000); mem.poke32(POS + 28, 32'h3F800000);
		/* V2: (0.5, -0.5, 0.5, 1.0) */
		mem.poke32(POS + 32, 32'h3F000000); mem.poke32(POS + 36, 32'hBF000000);
		mem.poke32(POS + 40, 32'h3F000000); mem.poke32(POS + 44, 32'h3F800000);
		/* V3: (0.0, 0.8, 0.5, 1.0) */
		mem.poke32(POS + 48, 32'h00000000); mem.poke32(POS + 52, 32'h3F4CCCCD);
		mem.poke32(POS + 56, 32'h3F000000); mem.poke32(POS + 60, 32'h3F800000);
		/* V4: (-0.8, -0.2, 0.5, 1.0) */
		mem.poke32(POS + 64, 32'hBF4CCCCD); mem.poke32(POS + 68, 32'hBE4CCCCD);
		mem.poke32(POS + 72, 32'h3F000000); mem.poke32(POS + 76, 32'h3F800000);
		/* V5: (0.8, -0.2, 0.5, 1.0) */
		mem.poke32(POS + 80, 32'h3F4CCCCD); mem.poke32(POS + 84, 32'hBE4CCCCD);
		mem.poke32(POS + 88, 32'h3F000000); mem.poke32(POS + 92, 32'h3F800000);

		/* COL: 6 vertices of RGBA8_UNORM (4 bytes each) */
		for (i = 0; i < 6; i = i + 1) begin
			mem.poke32(COL + i * 4, 32'hFFFFFFFF);
		end

		/* VS Program (9 instructions: exports position and colour attributes, then end) */
		mem.poke32(VS_PC +  0, 32'h0000402b); mem.poke32(VS_PC +  4, 32'h00000000); /* exp r0, 0x000 */
		mem.poke32(VS_PC +  8, 32'h001040ab); mem.poke32(VS_PC + 12, 32'h00000000); /* exp r1, 0x001 */
		mem.poke32(VS_PC + 16, 32'h0020412b); mem.poke32(VS_PC + 20, 32'h00000000); /* exp r2, 0x002 */
		mem.poke32(VS_PC + 24, 32'h003041ab); mem.poke32(VS_PC + 28, 32'h00000000); /* exp r3, 0x003 */
		mem.poke32(VS_PC + 32, 32'h0040482b); mem.poke32(VS_PC + 36, 32'h00000000); /* exp r4, 0x010 */
		mem.poke32(VS_PC + 40, 32'h005048ab); mem.poke32(VS_PC + 44, 32'h00000000); /* exp r5, 0x011 */
		mem.poke32(VS_PC + 48, 32'h0060492b); mem.poke32(VS_PC + 52, 32'h00000000); /* exp r6, 0x012 */
		mem.poke32(VS_PC + 56, 32'h007049ab); mem.poke32(VS_PC + 60, 32'h00000000); /* exp r7, 0x013 */
		mem.poke32(VS_PC + 64, 32'h0000700b); mem.poke32(VS_PC + 68, 32'h00000000); /* end */

		/* =============================================================
		 * Scenario 1 & 2: FS Shader Invalid Opcode during Concurrent VS/FS Draw
		 * ============================================================= */
		$display("--- Scenario 1 & 2: FS Invalid Opcode during Concurrent VS+FS Draw ---");
		reset_gpu();

		/* FS Program: Inst 0 is valid exp, Inst 1 is undefined/illegal opcode (0x00000000) */
		mem.poke32(FS_PC +  0, 32'h10c0402b); mem.poke32(FS_PC +  4, 32'h00000000); /* exp r12, 0x100 */
		mem.poke32(FS_PC +  8, 32'h00000000); mem.poke32(FS_PC + 12, 32'h00000000); /* ILLEGAL INSTRUCTION (PC=1) */
		mem.poke32(FS_PC + 16, 32'h0000700b); mem.poke32(FS_PC + 20, 32'h00000000); /* end */

		/* Build command ring */
		wp = 0;
		/* 1. SET_REG (34 pairs = 68 dwords) */
		mem.poke32(RING + wp * 4, 32'h01400044); wp = wp + 1;
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 0); mem.poke32(RING + (wp+1) * 4, 32'h42000000); wp = wp + 2; /* 32.0 */
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 1); mem.poke32(RING + (wp+1) * 4, 32'h41C00000); wp = wp + 2; /* 24.0 */
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 2); mem.poke32(RING + (wp+1) * 4, 32'h42000000); wp = wp + 2; /* 32.0 */
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 3); mem.poke32(RING + (wp+1) * 4, 32'h41C00000); wp = wp + 2; /* 24.0 */
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 4); mem.poke32(RING + (wp+1) * 4, 32'h3F800000); wp = wp + 2; /* 1.0 */
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 5); mem.poke32(RING + (wp+1) * 4, 32'h00000000); wp = wp + 2; /* 0.0 */
		mem.poke32(RING + wp * 4, GHCI_S_RT_BASE);      mem.poke32(RING + (wp+1) * 4, RT);            wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_RT_STRIDE);    mem.poke32(RING + (wp+1) * 4, 32'd256);        wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_RT_FORMAT);    mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_RT_SIZE);      mem.poke32(RING + (wp+1) * 4, (48 << 16) | 64); wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_DS_BASE);      mem.poke32(RING + (wp+1) * 4, DS);            wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_DS_STRIDE);    mem.poke32(RING + (wp+1) * 4, 32'd256);        wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_DEPTH);        mem.poke32(RING + (wp+1) * 4, 32'h00000047);  wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_WRITE_MASK);   mem.poke32(RING + (wp+1) * 4, 32'h0000000F);  wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_BLEND);        mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_CULL);         mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_VARYING_COUNT);mem.poke32(RING + (wp+1) * 4, 32'd4);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_PROVOKING);    mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_VS_BASE);      mem.poke32(RING + (wp+1) * 4, VS_PC);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_FS_BASE);      mem.poke32(RING + (wp+1) * 4, FS_PC);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_TOPOLOGY);     mem.poke32(RING + (wp+1) * 4, 32'd3);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_INDEX_FORMAT); mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_FIRST);        mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_COUNT);        mem.poke32(RING + (wp+1) * 4, 32'd6);         wp = wp + 2; /* 2 triangles -> concurrent VS & FS */
		mem.poke32(RING + wp * 4, GHCI_S_PRIM_RESTART); mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_INSTANCE_COUNT);mem.poke32(RING + (wp+1) * 4, 32'd1);        wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_FIRST_INSTANCE);mem.poke32(RING + (wp+1) * 4, 32'd0);        wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_VERTEX_OFFSET);mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_ATTR + 0);     mem.poke32(RING + (wp+1) * 4, POS);           wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_ATTR + 1);     mem.poke32(RING + (wp+1) * 4, 16 | (3 << 16));wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_ATTR + 2);     mem.poke32(RING + (wp+1) * 4, COL);           wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_ATTR + 3);     mem.poke32(RING + (wp+1) * 4, 4 | (4 << 16)); wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_ATTR_DST + 0); mem.poke32(RING + (wp+1) * 4, 32'h000000C0);  wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_ATTR_DST + 1); mem.poke32(RING + (wp+1) * 4, 32'h000000C4);  wp = wp + 2;

		/* 2. OP_DRAW (0x03, len=0) */
		mem.poke32(RING + wp * 4, 32'h03500000); wp = wp + 1;

		/* 3. Trailing CMD_FENCE (should NOT be written) */
		mem.poke32(RING + wp * 4, 32'h00000633); wp = wp + 1;
		mem.poke32(RING + wp * 4, FENCES);       wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'h00000000); wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'hA5A50001); wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'h00000000); wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'h00000003); wp = wp + 1;

		mem.poke32(FENCES, 32'd0);

		/* Launch DRAW */
		host_write(GHCI_REG_RING_WPTR, wp);

		/* Wait for STATUS.FAULTED */
		to_cnt = 0;
		val = 0;
		while (!val[GHCI_STATUS_FAULTED] && to_cnt < 10000) begin
			#50;
			host_read(GHCI_REG_STATUS, val);
			to_cnt = to_cnt + 1;
		end
		check32("Scenario 1: STATUS.FAULTED asserted", {31'd0, val[GHCI_STATUS_FAULTED]}, 32'd1);

		/* Verify FAULT_INFO fields */
		host_read(GHCI_REG_FAULT_INFO, val);
		check32("Scenario 1: KIND == 1 (INVALID_OP)", {28'd0, val[3:0]}, 32'd1);
		check32("Scenario 1: UNIT == 2 (SU)", {28'd0, val[7:4]}, 32'd2);
		check32("Scenario 1 & 2: SHADER_STAGE == 1 (FS)", {28'd0, val[19:16]}, 32'd1);

		/* Verify FAULT_ADDR is relative instruction index (1) */
		host_read(GHCI_REG_FAULT_ADDR_LO, val);
		check32("Scenario 1: FAULT_ADDR == 1 (relative PC of illegal inst)", val, 32'd1);

		/* Verify trailing CMD_FENCE unwritten */
		check32("Scenario 1: Trailing CMD_FENCE stays unwritten in memory", mem.peek32(FENCES), 32'd0);

		/* Verify IRQ_FAULT */
		host_read(GHCI_REG_IRQ_STATUS, val);
		check32("Scenario 1: IRQ_STATUS[FAULT] asserted", {31'd0, val[GHCI_IRQ_FAULT]}, 32'd1);


		/* =============================================================
		 * Scenario 3: FS Shader Out-of-bounds Load (MC Refusal)
		 * ============================================================= */
		$display("--- Scenario 3: FS Shader Out-of-bounds Load (MC Refusal) ---");
		reset_gpu();

		/* FS Program:
		 * Inst 0: lui r5, 0xE0000 (r5 = 0xE0000000, outside aperture limit 0xC0000000)
		 * Inst 1: lw  r4, 0(r5)   (triggers MC aperture refusal on client C_SU_D)
		 * Inst 2: end
		 */
		mem.poke32(FS_PC +  0, 32'hE00002B7); mem.poke32(FS_PC +  4, 32'h00000000); /* lui r5, 0xE0000 */
		mem.poke32(FS_PC +  8, 32'h0002A203); mem.poke32(FS_PC + 12, 32'h00000000); /* lw r4, 0(r5) */
		mem.poke32(FS_PC + 16, 32'h0000700B); mem.poke32(FS_PC + 20, 32'h00000000); /* end */

		/* 1. SET_REG (34 pairs = 68 dwords) */
		mem.poke32(RING + wp * 4, 32'h01400044); wp = wp + 1;
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 0); mem.poke32(RING + (wp+1) * 4, 32'h42000000); wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 1); mem.poke32(RING + (wp+1) * 4, 32'h41C00000); wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 2); mem.poke32(RING + (wp+1) * 4, 32'h42000000); wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 3); mem.poke32(RING + (wp+1) * 4, 32'h41C00000); wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 4); mem.poke32(RING + (wp+1) * 4, 32'h3F800000); wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 5); mem.poke32(RING + (wp+1) * 4, 32'h00000000); wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_RT_BASE);      mem.poke32(RING + (wp+1) * 4, RT);            wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_RT_STRIDE);    mem.poke32(RING + (wp+1) * 4, 32'd256);        wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_RT_FORMAT);    mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_RT_SIZE);      mem.poke32(RING + (wp+1) * 4, (48 << 16) | 64); wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_DS_BASE);      mem.poke32(RING + (wp+1) * 4, DS);            wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_DS_STRIDE);    mem.poke32(RING + (wp+1) * 4, 32'd256);        wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_DEPTH);        mem.poke32(RING + (wp+1) * 4, 32'h00000047);  wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_WRITE_MASK);   mem.poke32(RING + (wp+1) * 4, 32'h0000000F);  wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_BLEND);        mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_CULL);         mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_VARYING_COUNT);mem.poke32(RING + (wp+1) * 4, 32'd4);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_PROVOKING);    mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_VS_BASE);      mem.poke32(RING + (wp+1) * 4, VS_PC);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_FS_BASE);      mem.poke32(RING + (wp+1) * 4, FS_PC);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_TOPOLOGY);     mem.poke32(RING + (wp+1) * 4, 32'd3);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_INDEX_FORMAT); mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_FIRST);        mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_COUNT);        mem.poke32(RING + (wp+1) * 4, 32'd3);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_PRIM_RESTART); mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_INSTANCE_COUNT);mem.poke32(RING + (wp+1) * 4, 32'd1);        wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_FIRST_INSTANCE);mem.poke32(RING + (wp+1) * 4, 32'd0);        wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_VERTEX_OFFSET);mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_ATTR + 0);     mem.poke32(RING + (wp+1) * 4, POS);           wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_ATTR + 1);     mem.poke32(RING + (wp+1) * 4, 16 | (3 << 16));wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_ATTR + 2);     mem.poke32(RING + (wp+1) * 4, COL);           wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_ATTR + 3);     mem.poke32(RING + (wp+1) * 4, 4 | (4 << 16)); wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_ATTR_DST + 0); mem.poke32(RING + (wp+1) * 4, 32'h000000C0);  wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_ATTR_DST + 1); mem.poke32(RING + (wp+1) * 4, 32'h000000C4);  wp = wp + 2;

		/* OP_DRAW */
		mem.poke32(RING + wp * 4, 32'h03500000); wp = wp + 1;

		/* Trailing CMD_FENCE */
		mem.poke32(RING + wp * 4, 32'h00000633); wp = wp + 1;
		mem.poke32(RING + wp * 4, FENCES);       wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'h00000000); wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'hA5A50002); wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'h00000000); wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'h00000003); wp = wp + 1;

		mem.poke32(FENCES, 32'd0);

		host_write(GHCI_REG_RING_WPTR, wp);

		to_cnt = 0;
		val = 0;
		while (!val[GHCI_STATUS_FAULTED] && to_cnt < 10000) begin
			#50;
			host_read(GHCI_REG_STATUS, val);
			to_cnt = to_cnt + 1;
		end
		check32("Scenario 3: STATUS.FAULTED asserted", {31'd0, val[GHCI_STATUS_FAULTED]}, 32'd1);

		host_read(GHCI_REG_FAULT_INFO, val);
		check32("Scenario 3: UNIT == 2 (SU)", {28'd0, val[7:4]}, 32'd2);
		check32("Scenario 3: SHADER_STAGE == 1 (FS)", {28'd0, val[19:16]}, 32'd1);
		check32("Scenario 3: KIND == 9 (PAGE_FAULT)", {28'd0, val[3:0]}, 32'd9);

		host_read(GHCI_REG_FAULT_ADDR_LO, val);
		check32("Scenario 3: FAULT_ADDR == 0xE0000000 (out-of-bounds address)", val, 32'hE0000000);


		/* =============================================================
		 * Scenario 4: CMD_FENCE Memory Write Triggering AXI SLVERR
		 * ============================================================= */
		$display("--- Scenario 4: CMD_FENCE AXI Error (KIND 5, UNIT 0) ---");
		reset_gpu();

		wp = 0;
		/* CMD_FENCE to address 0xF0000000 (>= ERR_BASE in axi_mem) */
		mem.poke32(RING + wp * 4, 32'h00000633); wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'hF0000000); wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'h00000000); wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'hDEADBEEF); wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'h00000000); wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'h00000003); wp = wp + 1; /* flags=3: write + irq */

		host_write(GHCI_REG_RING_WPTR, wp);

		to_cnt = 0;
		val = 0;
		while (!val[GHCI_STATUS_FAULTED] && to_cnt < 5000) begin
			#50;
			host_read(GHCI_REG_STATUS, val);
			to_cnt = to_cnt + 1;
		end
		check32("Scenario 4: STATUS.FAULTED asserted", {31'd0, val[GHCI_STATUS_FAULTED]}, 32'd1);

		host_read(GHCI_REG_FAULT_INFO, val);
		check32("Scenario 4: KIND == 5 (AXI_ERROR)", {28'd0, val[3:0]}, 32'd5);
		check32("Scenario 4: UNIT == 0 (CP)", {28'd0, val[7:4]}, 32'd0);

		host_read(GHCI_REG_FAULT_ADDR_LO, val);
		check32("Scenario 4: FAULT_ADDR == 0xF0000000", val, 32'hF0000000);

		host_read(GHCI_REG_IRQ_STATUS, val);
		check32("Scenario 4: IRQ_STATUS[FAULT] asserted", {31'd0, val[GHCI_IRQ_FAULT]}, 32'd1);


		/* =============================================================
		 * Conclusion
		 * ============================================================= */
		#100;
		if (errors == 0) begin
			$display("PASS atg_top_fault");
		end else begin
			$display("FAIL atg_top_fault: %0d errors", errors);
		end
		$finish;
	end
endmodule
`default_nettype wire
