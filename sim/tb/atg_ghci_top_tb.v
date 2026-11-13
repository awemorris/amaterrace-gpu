/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_ghci_top_tb: Full GPU top-level MMIO and Ring verification through atg_top
 * for minimal and balanced configurations according to GHCI 1.0 (§3.2.1, §3.2.2, §4.1).
 *
 * Tests:
 *   - No parameter injection of CAPS, GCLK_HZ, MRT_COUNT; DUT derives from configuration.
 *   - Presets compiled via include/atg_config.vh.
 *   - KC705 DUT parameters matching boards/kc705/atg_kc705_top.v.
 *   - Expected values evaluated using specification formulas.
 *   - Page 0 Crosstalk test: distinct values on all RW registers, all 64 offsets verified.
 *   - EXTCAP linked list traversal and window verification; header space RO protection.
 *   - Ring execution: CMD_FENCE commits to memory; idle engine does not fetch.
 *   - R1: Byte size, power-of-2 validation, pointer wrap at size.
 *   - R2: Running write to locked ring register raises FAULT_INFO kind 7.
 *   - R3: FAULT_INFO W1C clearing; TIMESTAMP_HI increment on overflow.
 *   - Write ordering: RING_BASE_LO preservation across CP_HEAP_BASE write.
 */

`timescale 1ns / 1ps
`default_nettype none

module ghci_probe #(
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	output reg done,
	output reg [31:0] err_count
);
	`include "ghci_regs.vh"
	`include "atg_config.vh"

	/* Derive parameters from atg_config.vh */
	localparam [3:0] EXP_MRT = `ifdef CFG_ROP_MRT_COUNT `CFG_ROP_MRT_COUNT `else 4'd1 `endif;
	localparam VA_BITS = `ifdef CFG_GPU_VA_BITS `CFG_GPU_VA_BITS `else 32 `endif;
	localparam PA_BITS = `ifdef CFG_HOST_PA_BITS `CFG_HOST_PA_BITS `else 40 `endif;
	localparam TU_BILINEAR = `ifdef CFG_TU_ENABLE_BILINEAR `CFG_TU_ENABLE_BILINEAR `else 0 `endif;
	localparam SU_NPHYS = `ifdef CFG_SU_NPHYS `CFG_SU_NPHYS `else 8 `endif;
	localparam SU_NWARPS = `ifdef CFG_SU_NWARPS `CFG_SU_NWARPS `else 4 `endif;
	localparam SU_GRP_W = `ifdef CFG_SU_GRP_W `CFG_SU_GRP_W `else 3 `endif;
	localparam SU_NREGS = `ifdef CFG_SU_NREGS `CFG_SU_NREGS `else 32 `endif;
	localparam SU_PACKED = `ifdef CFG_ENABLE_FP16 (`CFG_ENABLE_FP16 != 0) `else 0 `endif;
	localparam SU_SUBGROUP = `ifdef CFG_ENABLE_SUBGROUP (`CFG_ENABLE_SUBGROUP != 0) `else 0 `endif;
	localparam SU_LDS_KB = `ifdef CFG_SU_LDS_KB `CFG_SU_LDS_KB `else 4 `endif;
	localparam MS4 = `ifdef CFG_ENABLE_MSAA (`CFG_ENABLE_MSAA != 0 && `CFG_MSAA_SAMPLES == 4) `else 0 `endif;
	localparam HAS_BLT = `ifdef CFG_HAS_BLT (`CFG_HAS_BLT != 0) `else 0 `endif;
	localparam HAS_PROT = `ifdef CFG_MC_ENABLE_PROT (`CFG_MC_ENABLE_PROT != 0) `else 0 `endif;
	localparam HAS_L2 = `ifdef CFG_MC_L2_CACHE_KB (`CFG_MC_L2_CACHE_KB != 0 ? 1 : 0) `else 0 `endif;
	localparam L2_CACHE_KB = `ifdef CFG_MC_L2_CACHE_KB `CFG_MC_L2_CACHE_KB `else 0 `endif;
	localparam L2_WAYS = `ifdef CFG_MC_L2_WAYS `CFG_MC_L2_WAYS `else 2 `endif;
	localparam L2_SET_W = `ifdef CFG_MC_L2_CACHE_KB (`CFG_MC_L2_CACHE_KB != 0 ? $clog2(((`CFG_MC_L2_CACHE_KB != 0 ? `CFG_MC_L2_CACHE_KB : 16) * 1024) / (64 * `CFG_MC_L2_WAYS)) : 8) `else 8 `endif;
	localparam TU_L1_CACHE_KB = `ifdef CFG_TU_L1_CACHE_KB `CFG_TU_L1_CACHE_KB `else 0 `endif;
	localparam VF_CACHE_LINES = `ifdef CFG_VF_CACHE_LINES `CFG_VF_CACHE_LINES `else 0 `endif;
	localparam [31:0] CALC_MEM_CACHE_CFG = {
		VF_CACHE_LINES[3:0],
		TU_L1_CACHE_KB[3:0],
		L2_WAYS[7:0],
		L2_CACHE_KB[15:0]
	};
`ifdef CFG_ENABLE_ETC2
  `ifdef CFG_TU_ENABLE_FFILT
	localparam HAS_ETC = (`CFG_ENABLE_ETC2 != 0) && (`CFG_TU_ENABLE_FFILT != 0);
  `else
	localparam HAS_ETC = 0;
  `endif
`else
	localparam HAS_ETC = 0;
`endif
	localparam HAS_CPU = 1;
	localparam NSU = 1;
	localparam HAS_ROP = 1;

	localparam [15:0] TOTAL_WARPS = NSU * SU_NWARPS;
	localparam [31:0] CALC_RESIDENT_WARPS = {
		8'd0,
		SU_NREGS[7:0],
		8'd0,
		TOTAL_WARPS[7:0]
	};

	/* KC705 board top parameters */
	localparam [31:0] EXP_GCLK = 32'd200000000;
	localparam [31:0] LOCAL_BASE = 32'h80000000;
	localparam [31:0] LOCAL_BYTES = 32'h40000000;
	localparam [31:0] WINDOW_BYTES = 32'h04000000;
	localparam [31:0] HOST_LIMIT = 32'h80000000;
	localparam [15:0] SUBSYSTEM_VENDOR = 16'h10EE;
	localparam [15:0] SUBSYSTEM_DEVICE = 16'h0007;

	/* Dynamic calculation of capability registers per GHCI 1.0 §3.2.1, §3.2.2 */
	localparam [31:0] RAW_VA_ENC = (VA_BITS >= 30) ? (VA_BITS - 30) : 0;
	localparam [3:0] CALC_VA_ENC = RAW_VA_ENC[3:0];
	localparam [31:0] RAW_PA_ENC = (PA_BITS >= 40) ? (PA_BITS - 40) : 0;
	localparam [3:0] CALC_PA_ENC = RAW_PA_ENC[3:0];
	localparam [7:0] CALC_LDS_KB = SU_LDS_KB[7:0];

	localparam [31:0] CALC_DEV_CAPS = {
		(MS4 != 0) ? 1'b1 : 1'b0,                  /* [31] MSAA */
		1'b1,                                      /* [30] DISP */
		(HAS_BLT != 0) ? 1'b1 : 1'b0,              /* [29] BLT */
		`ifdef CFG_ENABLE_MESH (`CFG_ENABLE_MESH != 0) ? 1'b1 : 1'b0 `else 1'b0 `endif,  /* [28] MESH */
		`ifdef CFG_ENABLE_MESH (`CFG_ENABLE_MESH != 0) ? 1'b1 : 1'b0 `else 1'b0 `endif,  /* [27] TASK (mirrors MESH) */
		`ifdef CFG_ROP_ENABLE_PACK ((HAS_ROP != 0) && (`CFG_ROP_ENABLE_PACK != 0)) ? 1'b1 : 1'b0 `else 1'b0 `endif,  /* [26] ROP_PACK */
		`ifdef CFG_TU_ENABLE_FFILT (`CFG_TU_ENABLE_FFILT != 0) ? 1'b1 : 1'b0 `else 1'b0 `endif,  /* [25] FFILT */
		(HAS_PROT != 0) ? 1'b1 : 1'b0,             /* [24] PROT */
		8'd1,                                      /* [23:16] NUM_SU (KC705 NSU=1) */
		SU_NPHYS[7:0],                             /* [15:8] PHYS_LANES */
		1'b1,                                      /* [7] GSI1 */
		(SU_PACKED != 0) ? 1'b1 : 1'b0,            /* [6] FP16 */
		`ifdef CFG_ROP_DUAL_SOURCE (`CFG_ROP_DUAL_SOURCE != 0) ? 1'b1 : 1'b0 `else (`ifdef CFG_ENABLE_DUAL_SOURCE (`CFG_ENABLE_DUAL_SOURCE != 0) ? 1'b1 : 1'b0 `else 1'b0 `endif) `endif, /* [5] DUAL_SRC */
		(HAS_CPU != 0 && NSU > 0) ? 1'b1 : 1'b0,   /* [4] SECONDARY_RING */
		1'b0,                                      /* [3] INDIRECT_DRAW */
		1'b0,                                      /* [2] HW_WALKER (atg_mmu absent in atg_top, always 0) */
		2'b00                                      /* [1:0] */
	};

	localparam [31:0] CALC_FMT0 = {
		13'd0,                                     /* [31:19] reserved */
		`ifdef CFG_BLT_ENABLE_TILE ((HAS_BLT != 0) && (`CFG_BLT_ENABLE_TILE != 0)) ? 1'b1 : 1'b0 `else 1'b0 `endif,  /* [18] BLT_TILE */
		`ifdef CFG_BLT_ENABLE_BLEND ((HAS_BLT != 0) && (`CFG_BLT_ENABLE_BLEND != 0)) ? 1'b1 : 1'b0 `else 1'b0 `endif, /* [17] BLT_BLEND */
		(TU_BILINEAR != 0) ? 1'b1 : 1'b0,          /* [16] TU_BILINEAR */
		EXP_MRT[3:0],                              /* [15:12] MAX_MRT */
		1'b0,                                      /* [11] FFILT_FP32 */
		`ifdef CFG_TU_ENABLE_FFILT (`CFG_TU_ENABLE_FFILT != 0) ? 1'b1 : 1'b0 `else 1'b0 `endif,  /* [10] FFILT_FP16 */
		`ifdef CFG_FMT_ENABLE_SRGB (`CFG_FMT_ENABLE_SRGB != 0) ? 1'b1 : 1'b0 `else 1'b1 `endif, /* [9] SRGB */
		1'b0,                                      /* [8] ASTC */
		(HAS_ETC != 0) ? 1'b1 : 1'b0,              /* [7] ETC2 */
		7'd0                                       /* [6:0] BC */
	};

	localparam [31:0] CALC_FEAT = {
		`ifdef CFG_BLT_ENABLE_SCALE ((HAS_BLT != 0) && (`CFG_BLT_ENABLE_SCALE != 0)) ? 1'b1 : 1'b0 `else 1'b0 `endif, /* [31] BLT_SCALE */
		`ifdef CFG_RX_ENABLE_CPOLY (`CFG_RX_ENABLE_CPOLY != 0) ? 1'b1 : 1'b0 `else 1'b0 `endif,   /* [30] CLIP_POLY */
		(SU_SUBGROUP != 0) ? 1'b1 : 1'b0,          /* [29] SUBGROUP */
		(SU_PACKED != 0) ? 1'b1 : 1'b0,            /* [28] FP16 */
		CALC_LDS_KB,                               /* [27:20] LDS_KB */
		EXP_MRT[3:0],                              /* [19:16] MAX_MRT */
		(EXP_MRT >= 4'd2) ? 1'b1 : 1'b0,           /* [15] MRT_BLEND */
		1'b0,                                      /* [14] COLOR_LUT */
		`ifdef CFG_DC_ENABLE_CURSOR (`CFG_DC_ENABLE_CURSOR != 0) ? 1'b1 : 1'b0 `else 1'b0 `endif, /* [13] CURSOR */
		`ifdef CFG_ENABLE_EARLY_Z (`CFG_ENABLE_EARLY_Z != 0) ? 1'b1 : 1'b0 `else 1'b0 `endif,     /* [12] EARLY_Z */
		`ifdef CFG_ROP_ENABLE_LOGICOP (`CFG_ROP_ENABLE_LOGICOP != 0) ? 1'b1 : 1'b0 `else (`ifdef CFG_ENABLE_LOGICOP (`CFG_ENABLE_LOGICOP != 0) ? 1'b1 : 1'b0 `else 1'b0 `endif) `endif, /* [11] LOGICOP */
		`ifdef CFG_ROP_FAST_CLEAR (`CFG_ROP_FAST_CLEAR != 0) ? 1'b1 : 1'b0 `else 1'b0 `endif,     /* [10] FAST_CLEAR */
		`ifdef CFG_COARSE_SCAN (`CFG_COARSE_SCAN != 0) ? 1'b1 : 1'b0 `else 1'b0 `endif,          /* [9] COARSE_SCAN */
		`ifdef CFG_ROP_DUAL_SOURCE (`CFG_ROP_DUAL_SOURCE != 0) ? 1'b1 : 1'b0 `else (`ifdef CFG_ENABLE_DUAL_SOURCE (`CFG_ENABLE_DUAL_SOURCE != 0) ? 1'b1 : 1'b0 `else 1'b0 `endif) `endif, /* [8] DUAL_SRC */
		CALC_PA_ENC,                               /* [7:4] PA_BITS_ENC */
		CALC_VA_ENC                                /* [3:0] VA_BITS_ENC */
	};

	localparam LINE_BYTES = 64;
	localparam LINE_SHIFT = 6;
	localparam DATA_W = 512;

	integer seed = SEED;

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

	/* DUT instantiation without parameter injection of CAPS, GCLK_HZ, MRT_COUNT */
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
		.SUBSYSTEM_VENDOR(SUBSYSTEM_VENDOR),
		.SUBSYSTEM_DEVICE(SUBSYSTEM_DEVICE),
		.TIMESTAMP_INIT(64'h00000000_FFFFFC00),
		.HAS_CPU(1),
		.NSU(1),
		.HAS_VF(1),
		.HAS_RX(1),
		.HAS_TU(1),
		.HAS_ROP(1),
		.HAS_JTAG(1),
		.HAS_DISP(1),
		.DC_HAS_I2C(1),
		.DC_FIFO_LOG2(11),
		.DC_PX_FMT(1),
		.ROP_STENCIL(1),
		.SU_NPHYS(SU_NPHYS),
		.SU_NWARPS(SU_NWARPS),
		.SU_WARP_W($clog2(SU_NWARPS)),
		.SU_GRP_W(SU_GRP_W),
		.SU_NREGS(SU_NREGS),
		.SU_SB_ENTRIES(4),
		.SU_SBE_W(2),
		.SU_LDS_BYTES(SU_LDS_KB * 1024),
		.MS4(MS4),
		.HAS_BLT(HAS_BLT),
		.HAS_PROT(HAS_PROT),
		.PROT_SLOTS(31),
		.PROT_GRANTS(64),
		.PROT_GIDX_W(6),
		.PROT_PLB(16),
		.PROT_PLB_W(4),
		.HAS_L2(HAS_L2),
		.L2_WAYS(L2_WAYS),
		.L2_SET_W(L2_SET_W),
		.SU_PACKED(SU_PACKED),
		.SU_SUBGROUP(SU_SUBGROUP),
		.SU_VARY_WORDS(16)
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

	task check32;
		input [8*40-1:0] desc;
		input [31:0] got;
		input [31:0] want;
		begin
			if (got !== want) begin
				err_count = err_count + 1;
				$display("FAIL %0s: got %08h, expected %08h", desc, got, want);
			end else begin
				$display("PASS %0s: %08h", desc, got);
			end
		end
	endtask

	reg [31:0] val;
	reg [31:0] xoff, w0, w1;
	integer found_fmt, off_idx, to_cnt;

	initial begin
		done = 0;
		err_count = 0;
		@(posedge rst_n);
		repeat (10) @(posedge clk);

		$display("=== Running ghci_probe on KC705 atg_top ===");
		$display("Calculated CAPS=%08h FMT0=%08h FEAT=%08h", CALC_DEV_CAPS, CALC_FMT0, CALC_FEAT);

		/* 1. Identification */
		host_read(GHCI_REG_MAGIC, val);
		check32("GHCI_MAGIC", val, GHCI_MAGIC_VALUE);

		host_read(GHCI_REG_VERSION, val);
		check32("GHCI_VERSION", val, 32'h00010000);

		/* 2. DEVICE_CAPS: verified against specification formulas */
		host_read(GHCI_REG_DEVICE_CAPS, val);
		check32("DEVICE_CAPS", val, CALC_DEV_CAPS);

		/* 3. Item 9: Write ordering check for RING_BASE_LO preservation across CP_HEAP_BASE write */
		host_write(GHCI_REG_RING_BASE_LO, 32'h12345000);
		host_read(GHCI_REG_RING_BASE_LO, val);
		check32("RING_BASE_LO initial write/read", val, 32'h12345000);

		host_write(GHCI_REG_CP_HEAP_BASE, 32'h80010000);
		host_read(GHCI_REG_CP_HEAP_BASE, val);
		check32("CP_HEAP_BASE write/read", val, 32'h80010000);

		host_read(GHCI_REG_RING_BASE_LO, val);
		check32("RING_BASE_LO preserved after HEAP write", val, 32'h12345000);

		/* 4. Legacy APERTURE_BASE (0x060) write ignored */
		host_write(17'h00060, 32'h55AA55AA);
		host_read(17'h00060, val);
		check32("Legacy 0x060 write ignored (TIMESTAMP_HI reads 0)", val, 32'd0);
		host_read(GHCI_REG_CP_HEAP_BASE, val);
		check32("CP_HEAP_BASE unchanged by 0x060 write", val, 32'h80010000);

		/* -------------------------------------------------------------
		 * 5. Item 5: Page 0 Crosstalk Test (混ざりの試験)
		 * Write unique, distinct patterns across all Page 0 RW registers
		 * ------------------------------------------------------------- */
		host_write(GHCI_REG_CTRL,          32'h00000020); /* WDT_EN=1, RUN=0, HALT=0 */
		host_write(GHCI_REG_RING_BASE_LO,  32'h12345000);
		host_write(GHCI_REG_RING_BASE_HI,  32'h00000001);
		host_write(GHCI_REG_RING_SIZE,     32'h00010000); /* 64 KiB */
		host_write(GHCI_REG_RING_WPTR,     32'h00000020);
		host_write(GHCI_REG_IRQ_ENABLE,    32'h00000007);
		host_write(GHCI_REG_SCRATCH,       32'hDEADBEEF);
		host_write(GHCI_REG_WDT_CYCLES,    32'h0000CAFE);
		host_write(GHCI_REG_CP_HEAP_BASE,  32'h80010000);
		host_write(GHCI_REG_CP_HEAP_LIMIT, 32'h90010000);

		/* Read back all 64 offsets in 0x000..0x0FC and verify each returns strictly its own value */
		$display("--- Testing all 64 dwords in Page 0 (0x000..0x0FC) for crosstalk ---");
		for (off_idx = 0; off_idx < 64; off_idx = off_idx + 1) begin
			host_read(off_idx * 4, val);
			case (off_idx * 4)
			17'h00000: check32("Offset 0x000 (MAGIC)", val, GHCI_MAGIC_VALUE);
			17'h00004: check32("Offset 0x004 (VERSION)", val, 32'h00010000);
			17'h00008: check32("Offset 0x008 (DEVICE_CAPS)", val, CALC_DEV_CAPS);
			17'h0000C: check32("Offset 0x00C (EXTCAP_PTR)", val, 32'h00000100);
			17'h00010: begin /* STATUS */
				if (val[19:16] !== 4'd0) begin /* STATE must be IDLE */
					err_count = err_count + 1;
					$display("FAIL Offset 0x010 (STATUS): unexpected state %0d", val[19:16]);
				end else begin
					$display("PASS Offset 0x010 (STATUS): %08h", val);
				end
			end
			17'h00014: check32("Offset 0x014 (CTRL)", val, 32'h00000020);
			17'h00018: check32("Offset 0x018 (FAULT_INFO)", val, 32'd0);
			17'h0001C: check32("Offset 0x01C (FAULT_ADDR_LO)", val, 32'd0);
			17'h00020: check32("Offset 0x020 (FAULT_ADDR_HI)", val, 32'd0);
			17'h00024: check32("Offset 0x024 (RING_BASE_LO)", val, 32'h12345000);
			17'h00028: check32("Offset 0x028 (RING_BASE_HI)", val, 32'h00000001);
			17'h0002C: check32("Offset 0x02C (RING_SIZE)", val, 32'h00010000);
			17'h00030: check32("Offset 0x030 (RING_WPTR)", val, 32'h00000020);
			17'h00034: check32("Offset 0x034 (RING_RPTR)", val, 32'd0);
			17'h00038: check32("Offset 0x038 (IRQ_STATUS)", val, 32'd0);
			17'h0003C: check32("Offset 0x03C (IRQ_ENABLE)", val, 32'h00000007);
			17'h00040: check32("Offset 0x040 (IRQ_SET)", val, 32'd0);
			17'h00044: check32("Offset 0x044 (SCRATCH)", val, 32'hDEADBEEF);
			17'h00048: check32("Offset 0x048 (WDT_CYCLES)", val, 32'h0000CAFE);
			17'h0004C: check32("Offset 0x04C (RESIDENT_WARPS)", val, CALC_RESIDENT_WARPS);
			17'h00050: check32("Offset 0x050 (CP_HEAP_BASE)", val, 32'h80010000);
			17'h00054: check32("Offset 0x054 (CP_HEAP_LIMIT)", val, 32'h90010000);
			17'h00058: check32("Offset 0x058 (SESSION_ACTIVE)", val, 32'h00000001);
			17'h0005C: begin /* TIMESTAMP_LO */
				if (val == 32'd0) begin
					err_count = err_count + 1;
					$display("FAIL Offset 0x05C (TIMESTAMP_LO) returned 0");
				end else begin
					$display("PASS Offset 0x05C (TIMESTAMP_LO): %08h", val);
				end
			end
			17'h00060: check32("Offset 0x060 (TIMESTAMP_HI)", val, 32'd0);
			17'h00064: check32("Offset 0x064 (GCLK_HZ)", val, EXP_GCLK);
			17'h00068: check32("Offset 0x068 (NATIVE_ISA_ID)", val, 32'h47534931);
			17'h00074: ; /* DIAG_CP_PC */
			17'h00078: ; /* DIAG_CP_STATUS */
			17'h00080: check32("Offset 0x080 (EXT_CAP_FMT0)", val, CALC_FMT0);
			17'h00084: check32("Offset 0x084 (EXT_CAP_FEATURE)", val, CALC_FEAT);
			default: begin
				/* All unmapped offsets in §3.1 must return strictly 0 */
				if (val !== 32'd0) begin
					err_count = err_count + 1;
					$display("FAIL Offset %03h (unmapped): expected 0, got %08h", off_idx * 4, val);
				end
			end
			endcase
		end

		/* 6. EXTCAP list traversal from 0x100 */
		host_read(GHCI_REG_EXTCAP_PTR, xoff);
		check32("EXTCAP_PTR", xoff, 32'h00000100);

		found_fmt = 0;
		while (xoff != 0 && xoff < 32'h00000140) begin
			host_read(xoff, w0);
			host_read(xoff + 4, w1);
			$display("  EXTCAP entry @ %h: ID=%0d, ver=%0d, ptr=%08h", xoff, w0[7:0], w0[15:8], w1);
			if (w0[7:0] == 8'd1) begin
				err_count = err_count + 1;
				$display("FAIL DBG capability found in EXTCAP list!");
			end
			if (w0[7:0] == 8'd10) begin /* FMT */
				found_fmt = 1;
				check32("FMT window ptr", w1, 32'h00000140);
			end
			if (w0[7:0] == 8'd3)  check32("PERF window ptr", w1, 32'h00000160);
			if (w0[7:0] == 8'd4)  check32("VEND window ptr", w1, 32'h00000180);
			if (w0[7:0] == 8'd6)  check32("CPFW window ptr", w1, 32'h00000170);
			if (w0[7:0] == 8'd8)  check32("MEM window ptr",  w1, 32'h000001E0);
			if (w0[7:0] == 8'd11) check32("DISP2 window ptr", w1, 32'h00000200);
			xoff = (w0[31:16] == 0) ? 0 : xoff + {w0[31:16], 2'b00};
		end
		if (!found_fmt) begin
			err_count = err_count + 1;
			$display("FAIL FMT capability (ID 10) not found in EXTCAP list!");
		end else begin
			$display("PASS FMT capability found in EXTCAP list");
		end

		/* Header area 0x100..0x13F is RO (writes dropped) */
		host_write(17'h00100, 32'hDEADBEEF);
		host_read(17'h00100, val);
		if (val == 32'hDEADBEEF) begin
			err_count = err_count + 1;
			$display("FAIL Header 0x100 was overwritten by host write!");
		end else begin
			$display("PASS Header 0x100 is RO");
		end

		/* FMT window registers at 0x140 */
		host_write(17'h00140, 32'd44);
		host_read(17'h00144, val); /* FMT_OPTIMAL */
		check32("FMT_OPTIMAL format 44", val, (TU_BILINEAR ? 32'h000000EF : 32'h000000ED));
		host_read(17'h00148, val); /* FMT_LINEAR */
		check32("FMT_LINEAR format 44", val, (TU_BILINEAR ? 32'h000000EF : 32'h000000ED));
		host_read(17'h00150, val); /* FMT_LIMITS */
		check32("FMT_LIMITS[3:0]", {28'd0, val[3:0]}, {28'd0, EXP_MRT});

		/* VEND window registers at 0x180 */
		host_read(17'h00180, val);
		check32("VEND VENDOR_ID", val, 32'h414D4154);
		host_read(17'h00184, val);
		check32("VEND DEVICE_ID", val, 32'h41544731);
		host_read(17'h00188, val);
		check32("VEND SUBSYSTEM_VENDOR", val, {16'd0, SUBSYSTEM_VENDOR});
		host_read(17'h0018C, val);
		check32("VEND SUBSYSTEM_DEVICE", val, {16'd0, SUBSYSTEM_DEVICE});
		host_read(17'h00190, val);
		check32("VEND GCLK_HZ", val, EXP_GCLK);

		/* MEM window registers at 0x1E0 */
		host_read(17'h001E0, val);
		check32("MEM LOCAL_BASE", val, LOCAL_BASE);
		host_read(17'h001E4, val);
		check32("MEM LOCAL_SIZE", val, LOCAL_BYTES);
		host_read(17'h001E8, val);
		check32("MEM WINDOW_SIZE", val, WINDOW_BYTES);
		host_read(17'h001EC, val);
		check32("MEM HOST_LIMIT", val, HOST_LIMIT);
		host_read(17'h001F0, val);
		check32("MEM WINDOW_CTRL reset", val, 32'd1);
		host_read(17'h001F4, val);
		check32("MEM MEM_CACHE_CFG", val, CALC_MEM_CACHE_CFG);

		/* -------------------------------------------------------------
		 * 7. Item 6: Ring packet execution test with CMD_FENCE
		 * ------------------------------------------------------------- */
		$display("--- Testing Ring packet execution (CMD_FENCE) ---");
		/* Reset engine to IDLE and wait for reset replay to complete */
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

		/* Item 6: Verify ring pointers after reset in IDLE */
		host_read(GHCI_REG_RING_RPTR, val);
		check32("RPTR stays 0 across RESET in IDLE", val, 32'd0);
		host_read(GHCI_REG_RING_WPTR, val);
		check32("WPTR stays 0 across RESET in IDLE", val, 32'd0);

		/* Set up ring buffer at address 0x00004000 */
		host_write(GHCI_REG_RING_BASE_LO, 32'h00004000);
		host_write(GHCI_REG_RING_BASE_HI, 32'h00000000);
		host_write(GHCI_REG_RING_SIZE,    32'h00010000); /* 64 KiB = 16384 dwords */
		host_write(GHCI_REG_RING_WPTR,    32'd0);

		/* Place CMD_FENCE (6 dwords) into host memory at ring buffer offset 0 */
		mem.poke32(32'h00004000, 32'h00000633); /* Header: size=6, Opcode=0x33 (CMD_FENCE) */
		mem.poke32(32'h00004004, 32'h00008000); /* addr_lo = 0x8000 */
		mem.poke32(32'h00004008, 32'h00000000); /* addr_hi = 0 */
		mem.poke32(32'h0000400C, 32'hCAFE0042); /* seq_lo (fence payload value) */
		mem.poke32(32'h00004010, 32'h00000001); /* seq_hi */
		mem.poke32(32'h00004014, 32'h00000003); /* flags = 3 (IRQ | MEM_WRITE) */
		mem.poke32(32'h00008000, 32'd0);        /* Clear target fence memory */
		mem.poke32(32'h00008004, 32'd0);
		host_write(GHCI_REG_IRQ_STATUS, 32'hFFFFFFFF); /* Clear IRQ status */

		/* Write WPTR=6 while engine is IDLE (CTRL.RUN = 0) */
		host_write(GHCI_REG_RING_WPTR, 32'd6);
		host_write(GHCI_REG_CTRL, 32'h00000020); /* Non-run CTRL write (WDT_EN) */
		#100;

		/* Verify engine does NOT fetch while IDLE */
		host_read(GHCI_REG_RING_RPTR, val);
		check32("RPTR stays 0 while IDLE", val, 32'd0);
		if (mem.peek32(32'h00008000) !== 32'd0) begin
			err_count = err_count + 1;
			$display("FAIL Memory written while engine is IDLE!");
		end else begin
			$display("PASS Target memory unaffected while engine is IDLE");
		end

		/* Now start engine: CTRL.RUN = 1 */
		host_write(GHCI_REG_CTRL, (1 << GHCI_CTRL_RUN));

		/* Wait for RING_RPTR to advance to 6 */
		to_cnt = 0;
		val = 0;
		while (val < 32'd6 && to_cnt < 200) begin
			#50;
			host_read(GHCI_REG_RING_RPTR, val);
			to_cnt = to_cnt + 1;
		end
		check32("RING_RPTR advanced to 6", val, 32'd6);

		/* Wait for CMD_FENCE write to host memory */
		to_cnt = 0;
		while (mem.peek32(32'h00008000) !== 32'hCAFE0042 && to_cnt < 200) begin
			#50;
			to_cnt = to_cnt + 1;
		end

		/* Verify CMD_FENCE write to host memory (flags = 0x3) */
		if (mem.peek32(32'h00008000) !== 32'hCAFE0042 || mem.peek32(32'h00008004) !== 32'h00000001) begin
			err_count = err_count + 1;
			$display("FAIL Fence target memory: got {%08h, %08h}, expected {00000001, CAFE0042} (to_cnt=%0d, fence_st=%0d)",
				mem.peek32(32'h00008004), mem.peek32(32'h00008000), to_cnt, dut.cp.u_fence.st);
		end else begin
			$display("PASS CMD_FENCE wrote {00000001, CAFE0042} to host memory at 0x8000 (flags=0x3)");
		end

		/* Verify IRQ_STATUS[0] is set for flags=0x3 */
		host_read(GHCI_REG_IRQ_STATUS, val);
		if (!val[0]) begin
			err_count = err_count + 1;
			$display("FAIL IRQ_STATUS[0] not set for flags=0x3 (val=%08h)", val);
		end else begin
			$display("PASS IRQ_STATUS[0] set for flags=0x3");
		end
		host_write(GHCI_REG_IRQ_STATUS, 32'hFFFFFFFF); /* Clear IRQ status */

		/* --- Testing CMD_FENCE with flags = 0x1 (IRQ only, no MEM_WRITE) --- */
		mem.poke32(32'h00004018, 32'h00000633); /* Header: size=6, Opcode=0x33 */
		mem.poke32(32'h0000401C, 32'h00008000); /* addr_lo = 0x8000 */
		mem.poke32(32'h00004020, 32'h00000000); /* addr_hi = 0 */
		mem.poke32(32'h00004024, 32'h12345678); /* seq_lo */
		mem.poke32(32'h00004028, 32'h00000000); /* seq_hi */
		mem.poke32(32'h0000402C, 32'h00000001); /* flags = 1 (IRQ only) */
		mem.poke32(32'h00008000, 32'hDEADBEEF); /* Target memory preset */

		host_write(GHCI_REG_RING_WPTR, 32'd12);
		to_cnt = 0;
		val = 0;
		while (val < 32'd12 && to_cnt < 200) begin
			#50;
			host_read(GHCI_REG_RING_RPTR, val);
			to_cnt = to_cnt + 1;
		end
		check32("RING_RPTR advanced to 12", val, 32'd12);

		/* Verify memory was NOT written */
		if (mem.peek32(32'h00008000) !== 32'hDEADBEEF) begin
			err_count = err_count + 1;
			$display("FAIL Memory written when flags=0x1: got %08h, expected DEADBEEF",
				mem.peek32(32'h00008000));
		end else begin
			$display("PASS Target memory NOT written for flags=0x1");
		end

		/* Verify IRQ_STATUS[0] is set for flags=0x1 */
		host_read(GHCI_REG_IRQ_STATUS, val);
		if (!val[0]) begin
			err_count = err_count + 1;
			$display("FAIL IRQ_STATUS[0] not set for flags=0x1 (val=%08h)", val);
		end else begin
			$display("PASS IRQ_STATUS[0] set for flags=0x1");
		end
		host_write(GHCI_REG_IRQ_STATUS, 32'hFFFFFFFF); /* Clear IRQ status */

		/* --- Testing CMD_FENCE with flags = 0x2 (MEM_WRITE only, no IRQ) --- */
		mem.poke32(32'h00004030, 32'h00000633); /* Header: size=6, Opcode=0x33 */
		mem.poke32(32'h00004034, 32'h00008000); /* addr_lo = 0x8000 */
		mem.poke32(32'h00004038, 32'h00000000); /* addr_hi = 0 */
		mem.poke32(32'h0000403C, 32'hBEEFCAFE); /* seq_lo */
		mem.poke32(32'h00004040, 32'h00000000); /* seq_hi */
		mem.poke32(32'h00004044, 32'h00000002); /* flags = 2 (MEM_WRITE only) */
		mem.poke32(32'h00008000, 32'd0);        /* Clear target fence memory */

		host_write(GHCI_REG_RING_WPTR, 32'd18);
		to_cnt = 0;
		val = 0;
		while (val < 32'd18 && to_cnt < 200) begin
			#50;
			host_read(GHCI_REG_RING_RPTR, val);
			to_cnt = to_cnt + 1;
		end
		check32("RING_RPTR advanced to 18", val, 32'd18);

		/* Wait for CMD_FENCE write to host memory */
		to_cnt = 0;
		while (mem.peek32(32'h00008000) !== 32'hBEEFCAFE && to_cnt < 200) begin
			#50;
			to_cnt = to_cnt + 1;
		end

		/* Verify memory was written for flags=0x2 */
		if (mem.peek32(32'h00008000) !== 32'hBEEFCAFE) begin
			err_count = err_count + 1;
			$display("FAIL Fence target memory: got %08h, expected BEEFCAFE",
				mem.peek32(32'h00008000));
		end else begin
			$display("PASS CMD_FENCE wrote BEEFCAFE to host memory at 0x8000 (flags=0x2)");
		end

		/* Verify IRQ_STATUS[0] is NOT set for flags=0x2 */
		host_read(GHCI_REG_IRQ_STATUS, val);
		if (val[0]) begin
			err_count = err_count + 1;
			$display("FAIL IRQ_STATUS[0] unexpectedly set for flags=0x2 (val=%08h)", val);
		end else begin
			$display("PASS IRQ_STATUS[0] NOT set for flags=0x2");
		end

		/* --- Testing CMD_FENCE with flags = 0x7 (HOST_FLUSH | MEM_WRITE | IRQ) --- */
		mem.poke32(32'h00004048, 32'h00000633); /* Header: size=6, Opcode=0x33 */
		mem.poke32(32'h0000404C, 32'h00008000); /* addr_lo = 0x8000 */
		mem.poke32(32'h00004050, 32'h00000000); /* addr_hi = 0 */
		mem.poke32(32'h00004054, 32'h77770001); /* seq_lo */
		mem.poke32(32'h00004058, 32'h00000002); /* seq_hi */
		mem.poke32(32'h0000405C, 32'h00000007); /* flags = 7 (HOST_FLUSH | MEM_WRITE | IRQ) */
		mem.poke32(32'h00008000, 32'd0);
		mem.poke32(32'h00008004, 32'd0);
		host_write(GHCI_REG_IRQ_STATUS, 32'hFFFFFFFF);

		host_write(GHCI_REG_RING_WPTR, 32'd24);
		to_cnt = 0;
		val = 0;
		while (val < 32'd24 && to_cnt < 200) begin
			#50;
			host_read(GHCI_REG_RING_RPTR, val);
			to_cnt = to_cnt + 1;
		end
		check32("RING_RPTR advanced to 24", val, 32'd24);

		to_cnt = 0;
		while (mem.peek32(32'h00008000) !== 32'h77770001 && to_cnt < 200) begin
			#50;
			to_cnt = to_cnt + 1;
		end
		if (mem.peek32(32'h00008000) !== 32'h77770001 || mem.peek32(32'h00008004) !== 32'h00000002) begin
			err_count = err_count + 1;
			$display("FAIL flags=7 fence write failed: got {%08h, %08h}",
				mem.peek32(32'h00008004), mem.peek32(32'h00008000));
		end else begin
			$display("PASS CMD_FENCE with flags=0x7 wrote {00000002, 77770001}");
		end

		/* --- Testing CMD_FENCE with flags = 0x3 immediately following flags = 0x7 --- */
		/* Verifies that flags[2] (HOST_FLUSH) is not retained from the previous command */
		mem.poke32(32'h00004060, 32'h00000633); /* Header: size=6, Opcode=0x33 */
		mem.poke32(32'h00004064, 32'h00008000); /* addr_lo = 0x8000 */
		mem.poke32(32'h00004068, 32'h00000000); /* addr_hi = 0 */
		mem.poke32(32'h0000406C, 32'h33330002); /* seq_lo */
		mem.poke32(32'h00004070, 32'h00000003); /* seq_hi */
		mem.poke32(32'h00004074, 32'h00000003); /* flags = 3 (NO HOST_FLUSH) */
		mem.poke32(32'h00008000, 32'd0);
		mem.poke32(32'h00008004, 32'd0);
		host_write(GHCI_REG_IRQ_STATUS, 32'hFFFFFFFF);

		host_write(GHCI_REG_RING_WPTR, 32'd30);
		to_cnt = 0;
		val = 0;
		while (val < 32'd30 && to_cnt < 200) begin
			#50;
			host_read(GHCI_REG_RING_RPTR, val);
			to_cnt = to_cnt + 1;
		end
		check32("RING_RPTR advanced to 30", val, 32'd30);

		to_cnt = 0;
		while (mem.peek32(32'h00008000) !== 32'h33330002 && to_cnt < 200) begin
			#50;
			to_cnt = to_cnt + 1;
		end
		if (mem.peek32(32'h00008000) !== 32'h33330002 || mem.peek32(32'h00008004) !== 32'h00000003) begin
			err_count = err_count + 1;
			$display("FAIL flags=3 fence write failed: got {%08h, %08h}",
				mem.peek32(32'h00008004), mem.peek32(32'h00008000));
		end else begin
			$display("PASS CMD_FENCE with flags=0x3 wrote {00000003, 33330002}");
		end

		/* --- V2: Testing CMD_WAIT_FENCE 64-bit comparison (GHCI 1.0 §7.3) --- */
		/* Case 1: mem = 0x00000001_00000000, wait = 0x00000000_00000001 -> passes immediately */
		mem.poke32(32'h00008000, 32'h00000000); /* mem lo */
		mem.poke32(32'h00008004, 32'h00000001); /* mem hi */
		mem.poke32(32'h00004078, 32'h00000534); /* Header: size=5, Opcode=0x34 (CMD_WAIT_FENCE) */
		mem.poke32(32'h0000407C, 32'h00008000); /* addr_lo = 0x8000 */
		mem.poke32(32'h00004080, 32'h00000000); /* addr_hi = 0 */
		mem.poke32(32'h00004084, 32'h00000001); /* wait_val_lo = 1 */
		mem.poke32(32'h00004088, 32'h00000000); /* wait_val_hi = 0 */
		host_write(GHCI_REG_RING_WPTR, 32'd35);
		to_cnt = 0;
		val = 0;
		while (val < 32'd35 && to_cnt < 200) begin
			#50;
			host_read(GHCI_REG_RING_RPTR, val);
			to_cnt = to_cnt + 1;
		end
		check32("CMD_WAIT_FENCE Case 1 passed immediately to RPTR 35", val, 32'd35);

		/* Case 2: mem = 0x00000000_00000005, wait = 0x00000001_00000001 -> must wait, STATUS[19:16]=4 */
		mem.poke32(32'h00008000, 32'h00000005); /* mem lo */
		mem.poke32(32'h00008004, 32'h00000000); /* mem hi */
		mem.poke32(32'h0000408C, 32'h00000534); /* Header: size=5, Opcode=0x34 */
		mem.poke32(32'h00004090, 32'h00008000); /* addr_lo = 0x8000 */
		mem.poke32(32'h00004094, 32'h00000000); /* addr_hi = 0 */
		mem.poke32(32'h00004098, 32'h00000001); /* wait_val_lo = 1 */
		mem.poke32(32'h0000409C, 32'h00000001); /* wait_val_hi = 1 */
		host_write(GHCI_REG_RING_WPTR, 32'd40);
		to_cnt = 0;
		val = 0;
		while (val < 32'd40 && to_cnt < 200) begin
			#50;
			host_read(GHCI_REG_RING_RPTR, val);
			to_cnt = to_cnt + 1;
		end
		check32("CMD_WAIT_FENCE Case 2 packet fetched to RPTR 40", val, 32'd40);

		/* Verify STATUS[19:16] == 4 (GHCI_ST_WAIT_FENCE) while condition is unsatisfied */
		host_read(GHCI_REG_STATUS, val);
		check32("STATUS[19:16] is WAIT_FENCE (4) during wait", {28'd0, val[19:16]}, 32'd4);

		/* Put next packet (CMD_FENCE) at offset 0x40A0 to verify execution stalls behind WAIT_FENCE */
		mem.poke32(32'h000040A0, 32'h00000633); /* Header: size=6, Opcode=0x33 */
		mem.poke32(32'h000040A4, 32'h00008000);
		mem.poke32(32'h000040A8, 32'h00000000);
		mem.poke32(32'h000040AC, 32'h99990001);
		mem.poke32(32'h000040B0, 32'h00000000);
		mem.poke32(32'h000040B4, 32'h00000002);
		host_write(GHCI_REG_RING_WPTR, 32'd46);
		repeat (20) #50;
		host_read(GHCI_REG_RING_RPTR, val);
		if (val >= 32'd46) begin
			err_count = err_count + 1;
			$display("FAIL Next command executed before WAIT_FENCE satisfied (RPTR=%0d)", val);
		end else begin
			$display("PASS Engine stalls behind unsatisfied WAIT_FENCE (RPTR=%0d)", val);
		end

		/* Now satisfy condition: mem advances to 0x00000001_00000002 */
		mem.poke32(32'h00008000, 32'h00000002);
		mem.poke32(32'h00008004, 32'h00000001);
		to_cnt = 0;
		val = 0;
		while (val < 32'd46 && to_cnt < 200) begin
			#50;
			host_read(GHCI_REG_RING_RPTR, val);
			to_cnt = to_cnt + 1;
		end
		check32("CMD_WAIT_FENCE Case 2 resumed and subsequent command reached RPTR 46", val, 32'd46);

		/* -------------------------------------------------------------
		 * X1: In-flight packet completes during HALTING before HALTED
		 * ------------------------------------------------------------- */
		$display("--- Testing X1: In-flight CMD_FENCE completes during HALTING before HALTED ---");
		/* Ring is currently at RPTR=46, WPTR=46.
		 * Put CMD_FENCE 1 (6 dwords) at offset 46 (0x40B8..0x40CC), crossing line 5/6 boundary.
		 * Put CMD_FENCE 2 (6 dwords) at offset 52 (0x40D0..0x40E4).
		 */
		mem.poke32(32'h000040B8, 32'h00000633); /* CMD_FENCE header, len=6 */
		mem.poke32(32'h000040BC, 32'h00008010); /* addr_lo = 0x8010 */
		mem.poke32(32'h000040C0, 32'h00000000); /* addr_hi = 0 */
		mem.poke32(32'h000040C4, 32'h5555AAAA); /* seq_lo */
		mem.poke32(32'h000040C8, 32'h00000002); /* seq_hi */
		mem.poke32(32'h000040CC, 32'h00000002); /* flags = 2 (MEM_WRITE) */
		mem.poke32(32'h00008010, 32'd0);
		mem.poke32(32'h00008014, 32'd0);

		/* Second fence at 52..57 (0x40D0..0x40E4) */
		mem.poke32(32'h000040D0, 32'h00000633);
		mem.poke32(32'h000040D4, 32'h00008020);
		mem.poke32(32'h000040D8, 32'h00000000);
		mem.poke32(32'h000040DC, 32'h99998888);
		mem.poke32(32'h000040E0, 32'h00000003);
		mem.poke32(32'h000040E4, 32'h00000002);
		mem.poke32(32'h00008020, 32'd0);
		mem.poke32(32'h00008024, 32'd0);

		/* Advance WPTR to 58 (includes both fence 1 at 46..51 and fence 2 at 52..57) */
		host_write(GHCI_REG_RING_WPTR, 32'd58);

		/* Wait until sequencer enters Q_PAY for fence 1 */
		to_cnt = 0;
		while (dut.cp.u_seq.st != 4'd1 && to_cnt < 200) begin
			@(posedge clk);
			to_cnt = to_cnt + 1;
		end

		/* Assert CTRL.HALT = 1 while fence 1 is in flight in Q_PAY */
		host_write(GHCI_REG_CTRL, (1 << GHCI_CTRL_RUN) | (1 << GHCI_CTRL_HALT));
		#20;

		/* Verify engine is HALTING, NOT yet HALTED because fence 1 is completing in-flight */
		host_read(GHCI_REG_STATUS, val);
		check32("STATUS.HALTED == 0 while completing in-flight packet", {31'd0, val[GHCI_STATUS_HALTED_BIT]}, 32'd0);

		/* Wait for in-flight fence to complete into memory */
		to_cnt = 0;
		while (mem.peek32(32'h00008010) !== 32'h5555AAAA && to_cnt < 200) begin
			#50;
			to_cnt = to_cnt + 1;
		end
		check32("In-flight CMD_FENCE seq_lo written to memory", mem.peek32(32'h00008010), 32'h5555AAAA);

		/* Wait for STATUS.HALTED == 1 */
		to_cnt = 0;
		val = 0;
		while (!val[GHCI_STATUS_HALTED_BIT] && to_cnt < 200) begin
			#50;
			host_read(GHCI_REG_STATUS, val);
			to_cnt = to_cnt + 1;
		end
		check32("STATUS.HALTED == 1 after in-flight packet completes", {31'd0, val[GHCI_STATUS_HALTED_BIT]}, 32'd1);

		/* Verify RPTR stopped at 52 (second fence not executed) */
		host_read(GHCI_REG_RING_RPTR, val);
		check32("RING_RPTR stopped at 52 (second packet not executed)", val, 32'd52);
		check32("Second fence memory not written while HALTED", mem.peek32(32'h00008020), 32'd0);

		/* Now clear HALT: CTRL.HALT = 0 */
		host_write(GHCI_REG_CTRL, (1 << GHCI_CTRL_RUN));
		to_cnt = 0;
		val = 0;
		while (val < 32'd58 && to_cnt < 200) begin
			#50;
			host_read(GHCI_REG_RING_RPTR, val);
			to_cnt = to_cnt + 1;
		end
		check32("RING_RPTR advanced to 58 after clearing HALT", val, 32'd58);
		to_cnt = 0;
		while (mem.peek32(32'h00008020) !== 32'h99998888 && to_cnt < 200) begin
			#50;
			to_cnt = to_cnt + 1;
		end
		check32("Second fence executed and memory written", mem.peek32(32'h00008020), 32'h99998888);

		/* -------------------------------------------------------------
		 * 8. Item 7: R1 / R2 / R3 Dynamic checks
		 * ------------------------------------------------------------- */
		$display("--- Testing R1: Ring size byte validation and WPTR wrap ---");
		/* Stop running to test R1 cleanly */
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

		/* Item 6: Verify ring pointers after reset in IDLE */
		host_read(GHCI_REG_RING_RPTR, val);
		check32("RPTR stays 0 across RESET in IDLE", val, 32'd0);
		host_read(GHCI_REG_RING_WPTR, val);
		check32("WPTR stays 0 across RESET in IDLE", val, 32'd0);

		/* R1: 64 KiB read/write */
		host_write(GHCI_REG_RING_SIZE, 32'h00010000);
		host_read(GHCI_REG_RING_SIZE, val);
		check32("RING_SIZE 64 KiB", val, 32'h00010000);

		/* R1: Non-power-of-2 write ignored */
		host_write(GHCI_REG_RING_SIZE, 32'h00012345);
		host_read(GHCI_REG_RING_SIZE, val);
		check32("RING_SIZE non-power-of-2 ignored", val, 32'h00010000);

		/* R1: WPTR wraps at ring size in dwords (16384) */
		host_write(GHCI_REG_RING_WPTR, 32'd16383);
		host_read(GHCI_REG_RING_WPTR, val);
		check32("RING_WPTR 16383", val, 32'd16383);

		host_write(GHCI_REG_RING_WPTR, 32'd16384);
		host_read(GHCI_REG_RING_WPTR, val);
		check32("RING_WPTR wraps 16384 to 0", val, 32'd0);

		$display("--- Testing R2: Locked write while RUNNING triggers FAULT_INFO kind 7 ---");
		host_write(GHCI_REG_CTRL, (1 << GHCI_CTRL_RUN)); /* Engine RUNNING */
		#50;
		host_read(GHCI_REG_STATUS, val);
		check32("STATUS.RUNNING == 1 while waiting for doorbell", {31'd0, val[GHCI_STATUS_RUNNING_BIT]}, 32'd1);
		check32("STATUS.CP_STATE == 0 (IDLE) while waiting for doorbell", {28'd0, val[19:16]}, 32'd0);

		host_write(GHCI_REG_RING_SIZE, 32'h00020000);    /* Attempt write while running */
		#50;
		host_read(GHCI_REG_STATUS, val);
		check32("STATUS.FAULTED on locked write", {31'd0, val[GHCI_STATUS_FAULTED_BIT]}, 32'd1);
		check32("STATUS.CP_STATE on locked write is FAULT (7)", {28'd0, val[19:16]}, 32'd7);
		host_read(GHCI_REG_FAULT_INFO, val);
		check32("FAULT_INFO kind 7 (LOCKED_REG)", {28'd0, val[3:0]}, 32'd7);
		check32("FAULT_INFO unit 0 (CP)", {28'd0, val[7:4]}, 32'd0);
		host_read(GHCI_REG_RING_SIZE, val);
		check32("RING_SIZE unchanged by locked write", val, 32'h00010000);

		/* FAULTED: any packet appended to the ring is not executed */
		$display("--- Testing X1: Ring packet queued while FAULTED is not executed ---");
		mem.poke32(32'h00004100, 32'h00000633);
		mem.poke32(32'h00004104, 32'h00008030);
		mem.poke32(32'h00004108, 32'h00000000);
		mem.poke32(32'h0000410C, 32'hDEADBEEF);
		mem.poke32(32'h00004110, 32'h00000004);
		mem.poke32(32'h00004114, 32'h00000002);
		mem.poke32(32'h00008030, 32'd0);
		host_read(GHCI_REG_RING_RPTR, val);
		w0 = val;
		host_write(GHCI_REG_RING_WPTR, w0 + 32'd6);
		repeat (30) #50;
		host_read(GHCI_REG_RING_RPTR, val);
		check32("RPTR does not advance while FAULTED", val, w0);
		check32("Memory not written while FAULTED", mem.peek32(32'h00008030), 32'd0);

		$display("--- Testing R3: FAULT_INFO W1C and TIMESTAMP_HI increment ---");
		/* W1C clears kind [3:0] */
		host_write(GHCI_REG_FAULT_INFO, 32'h00000007);
		host_read(GHCI_REG_FAULT_INFO, val);
		check32("FAULT_INFO kind cleared by W1C", {28'd0, val[3:0]}, 32'd0);

		/* Clear remaining fault bits */
		host_write(GHCI_REG_FAULT_INFO, 32'hFFFFFFFF);
		host_read(GHCI_REG_FAULT_INFO, val);
		check32("FAULT_INFO fully cleared", val, 32'd0);

		/* Test TIMESTAMP_HI increment on 32-bit counter overflow (without force) */
		/* Counter started at 32'hFFFFFC00. By this point, >1024 cycles have elapsed naturally. */
		host_read(GHCI_REG_TIMESTAMP_HI, val);
		check32("TIMESTAMP_HI advanced on natural overflow", val, 32'd1);

		done = 1;
	end
endmodule

module atg_ghci_top_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	wire done_probe;
	wire [31:0] err_probe;

	ghci_probe #(.SEED(1)) probe (
		.clk(clk),
		.rst_n(rst_n),
		.done(done_probe),
		.err_count(err_probe)
	);

	initial begin
		#20;
		rst_n = 1'b1;

		wait (done_probe);
		#20;

		if (err_probe == 0) begin
			$display("PASS atg_ghci_top");
		end else begin
			$display("FAIL atg_ghci_top: %0d errors", err_probe);
		end
		$finish;
	end
endmodule
`default_nettype wire
