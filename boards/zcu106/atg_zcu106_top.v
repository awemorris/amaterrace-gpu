/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_zcu106_top: Top-level board support package for the AMD / Xilinx
 * Zynq UltraScale+ ZCU106 Evaluation Kit (xczu7ev-ffvc1156-2-e).
 *
 * Architectural Features:
 *   - Core Logic Clock: 400.0 MHz (period 2.500 ns) synthesized from PS pl_clk0
 *     (100.0 MHz) via UltraScale+ MMCME4_BASE (atg_zcu106_clk).
 *   - Memory Architecture: Unified Memory Architecture (UMA). The GPU has no
 *     dedicated VRAM and operates strictly out of PS host DDR4 memory via
 *     the Zynq MPSoC High-Performance slave port (S_AXI_HP0_FPD).
 *   - Host Interface: Direct AXI4 memory-mapped I/O (MMIO BAR0) from the PS
 *     FPD master port (M_AXI_HPM0_FPD). No PCIe endpoint is used.
 *   - Clock Domain Crossing: Low-latency asynchronous AXI CDC bridges (am_axi_cdc)
 *     isolate the PS AXI interface from the 400 MHz GPU core domain.
 *   - Minimal Preset Conformance (config/minimal.mk):
 *     SU: NPHYS 4, NWARPS 4, NREGS 32, LDS 1 KiB, FP16/Subgroup/Mesh OFF.
 *     RX: MSAA OFF (1x), Early-Z OFF.
 *     TU: BC/ETC2/Aniso OFF, 4 KB L1 cache.
 *     ROP: MRT 1, Depth24_S8 / Depth16, FP16/FP32/FBlend OFF.
 *     CP/MC: VA_BITS 30 (1 GiB internal VA), PA_BITS 40 (1 TiB host PA),
 *            8 KB L2 cache (4 ways).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_zcu106_top #(
	parameter S_ID_W = 6,		/* PS Master AxID width */
	parameter S_LEN_W = 8,		/* AXI4 burst length width */
	parameter DATA_W = 128,		/* S_AXI_HP0_FPD native 128-bit data bus */
	parameter LINE_BYTES = 64,	/* 64-byte cache line (UltraScale+ DDR4 native) */
	parameter LINE_SHIFT = 6,	/* log2(LINE_BYTES) */
	parameter VA_BITS = 30,		/* 1 GiB GPU virtual address space */
	parameter PA_BITS = 40,		/* 1 TiB host physical address space */
	parameter NSU = 1		/* Minimal configuration: 1 Shader Unit */
) (
	/* PS Reference Clock & Reset */
	input wire pl_clk0,		/* 100 MHz reference clock from PS */
	input wire pl_resetn0,		/* Active-low reset from PS */

	/* PS-PL AXI Slave (PS Master -> GPU Canonical MMIO BAR0, 64-bit data, 17-bit addr) */
	input wire s_axi_aclk,
	input wire s_axi_aresetn,
	input wire [16:0] s_axi_awaddr,
	input wire [S_ID_W-1:0] s_axi_awid,
	input wire s_axi_awvalid,
	output wire s_axi_awready,
	input wire [63:0] s_axi_wdata,
	input wire [7:0] s_axi_wstrb,
	input wire s_axi_wlast,
	input wire s_axi_wvalid,
	output wire s_axi_wready,
	output wire [S_ID_W-1:0] s_axi_bid,
	output wire [1:0] s_axi_bresp,
	output wire s_axi_bvalid,
	input wire s_axi_bready,
	input wire [16:0] s_axi_araddr,
	input wire [S_ID_W-1:0] s_axi_arid,
	input wire [S_LEN_W-1:0] s_axi_arlen,
	input wire s_axi_arvalid,
	output wire s_axi_arready,
	output wire [63:0] s_axi_rdata,
	output wire [S_ID_W-1:0] s_axi_rid,
	output wire [1:0] s_axi_rresp,
	output wire s_axi_rlast,
	output wire s_axi_rvalid,
	input wire s_axi_rready,

	/* GPU-PS AXI Master (GPU Master -> S_AXI_HP0_FPD for Host DRAM DMA) */
	input wire m_axi_aclk,
	input wire m_axi_aresetn,
	output wire m_axi_awid,
	output wire [63:0] m_axi_awaddr,
	output wire [7:0] m_axi_awlen,
	output wire [2:0] m_axi_awsize,
	output wire [1:0] m_axi_awburst,
	output wire [3:0] m_axi_awcache,
	output wire [2:0] m_axi_awprot,
	output wire m_axi_awvalid,
	input wire m_axi_awready,
	output wire [DATA_W-1:0] m_axi_wdata,
	output wire [DATA_W/8-1:0] m_axi_wstrb,
	output wire m_axi_wlast,
	output wire m_axi_wvalid,
	input wire m_axi_wready,
	input wire m_axi_bid,
	input wire [1:0] m_axi_bresp,
	input wire m_axi_bvalid,
	output wire m_axi_bready,
	output wire m_axi_arid,
	output wire [63:0] m_axi_araddr,
	output wire [7:0] m_axi_arlen,
	output wire [2:0] m_axi_arsize,
	output wire [1:0] m_axi_arburst,
	output wire [3:0] m_axi_arcache,
	output wire [2:0] m_axi_arprot,
	output wire m_axi_arvalid,
	input wire m_axi_arready,
	input wire m_axi_rid,
	input wire [DATA_W-1:0] m_axi_rdata,
	input wire [1:0] m_axi_rresp,
	input wire m_axi_rlast,
	input wire m_axi_rvalid,
	output wire m_axi_rready,

	/* Interrupt to PS GIC (active-high level) */
	output wire pl_ps_irq0,

	/* Diagnostic Status LEDs (Active-High) */
	output wire [7:0] led
);

	/* ------------------------------------------------------------------ */
	/* 1. Clock and Reset Generation (400 MHz GPU Core Logic)             */
	/* ------------------------------------------------------------------ */
	wire clk_gpu;
	wire rst_n_gpu;
	wire clk_axi_sync;
	wire rst_n_axi_sync;
	wire mmcm_locked;

	atg_zcu106_clk #(
		.CLKIN_PERIOD(10.000),		/* 100 MHz input from pl_clk0 */
		.CLKFBOUT_MULT(12.000),		/* VCO = 1200 MHz */
		.CLKOUT0_DIV(3.000),		/* 400 MHz clk_gpu */
		.CLKOUT1_DIV(6)			/* 200 MHz synchronous AXI option */
	) u_clk (
		.clk_in(pl_clk0),
		.rst_in(!pl_resetn0),
		.clk_gpu(clk_gpu),
		.rst_n_gpu(rst_n_gpu),
		.clk_axi(clk_axi_sync),
		.rst_n_axi(rst_n_axi_sync),
		.locked(mmcm_locked)
	);

	/* ------------------------------------------------------------------ */
	/* 2. MMIO BAR0 Clock Domain Crossing (PS AXI -> 400 MHz GPU Domain)  */
	/* ------------------------------------------------------------------ */
	wire [16:0] gpu_s_awaddr;
	wire [S_ID_W-1:0] gpu_s_awid;
	wire gpu_s_awvalid;
	wire gpu_s_awready;
	wire [63:0] gpu_s_wdata;
	wire [7:0] gpu_s_wstrb;
	wire gpu_s_wlast;
	wire gpu_s_wvalid;
	wire gpu_s_wready;
	wire [S_ID_W-1:0] gpu_s_bid;
	wire [1:0] gpu_s_bresp;
	wire gpu_s_bvalid;
	wire gpu_s_bready;
	wire [16:0] gpu_s_araddr;
	wire [S_ID_W-1:0] gpu_s_arid;
	wire [S_LEN_W-1:0] gpu_s_arlen;
	wire gpu_s_arvalid;
	wire gpu_s_arready;
	wire [63:0] gpu_s_rdata;
	wire [S_ID_W-1:0] gpu_s_rid;
	wire [1:0] gpu_s_rresp;
	wire gpu_s_rlast;
	wire gpu_s_rvalid;
	wire gpu_s_rready;

	am_axi_cdc #(
		.A_W(17),
		.ID_W(S_ID_W),
		.LEN_W(S_LEN_W),
		.D_W(64),
		.DEPTH_LOG2(2)
	) u_mmio_cdc (
		.s_clk(s_axi_aclk),
		.s_rst_n(s_axi_aresetn),
		.s_awaddr(s_axi_awaddr),
		.s_awid(s_axi_awid),
		.s_awvalid(s_axi_awvalid),
		.s_awready(s_axi_awready),
		.s_wdata(s_axi_wdata),
		.s_wstrb(s_axi_wstrb),
		.s_wlast(s_axi_wlast),
		.s_wvalid(s_axi_wvalid),
		.s_wready(s_axi_wready),
		.s_bid(s_axi_bid),
		.s_bresp(s_axi_bresp),
		.s_bvalid(s_axi_bvalid),
		.s_bready(s_axi_bready),
		.s_araddr(s_axi_araddr),
		.s_arid(s_axi_arid),
		.s_arlen(s_axi_arlen),
		.s_arvalid(s_axi_arvalid),
		.s_arready(s_axi_arready),
		.s_rdata(s_axi_rdata),
		.s_rid(s_axi_rid),
		.s_rresp(s_axi_rresp),
		.s_rlast(s_axi_rlast),
		.s_rvalid(s_axi_rvalid),
		.s_rready(s_axi_rready),

		.m_clk(clk_gpu),
		.m_rst_n(rst_n_gpu),
		.m_awaddr(gpu_s_awaddr),
		.m_awid(gpu_s_awid),
		.m_awvalid(gpu_s_awvalid),
		.m_awready(gpu_s_awready),
		.m_wdata(gpu_s_wdata),
		.m_wstrb(gpu_s_wstrb),
		.m_wlast(gpu_s_wlast),
		.m_wvalid(gpu_s_wvalid),
		.m_wready(gpu_s_wready),
		.m_bid(gpu_s_bid),
		.m_bresp(gpu_s_bresp),
		.m_bvalid(gpu_s_bvalid),
		.m_bready(gpu_s_bready),
		.m_araddr(gpu_s_araddr),
		.m_arid(gpu_s_arid),
		.m_arlen(gpu_s_arlen),
		.m_arvalid(gpu_s_arvalid),
		.m_arready(gpu_s_arready),
		.m_rdata(gpu_s_rdata),
		.m_rid(gpu_s_rid),
		.m_rresp(gpu_s_rresp),
		.m_rlast(gpu_s_rlast),
		.m_rvalid(gpu_s_rvalid),
		.m_rready(gpu_s_rready)
	);

	/* ------------------------------------------------------------------ */
	/* 3. GPU Memory Master Signals (400 MHz GPU Domain)                  */
	/* ------------------------------------------------------------------ */
	wire gpu_m_awid;
	wire [63:0] gpu_m_awaddr;
	wire [7:0] gpu_m_awlen;
	wire [2:0] gpu_m_awsize;
	wire [1:0] gpu_m_awburst;
	wire [3:0] gpu_m_awcache;
	wire [2:0] gpu_m_awprot;
	wire gpu_m_awvalid;
	wire gpu_m_awready;
	wire [DATA_W-1:0] gpu_m_wdata;
	wire [DATA_W/8-1:0] gpu_m_wstrb;
	wire gpu_m_wlast;
	wire gpu_m_wvalid;
	wire gpu_m_wready;
	wire gpu_m_bid;
	wire [1:0] gpu_m_bresp;
	wire gpu_m_bvalid;
	wire gpu_m_bready;
	wire gpu_m_arid;
	wire [63:0] gpu_m_araddr;
	wire [7:0] gpu_m_arlen;
	wire [2:0] gpu_m_arsize;
	wire [1:0] gpu_m_arburst;
	wire [3:0] gpu_m_arcache;
	wire [2:0] gpu_m_arprot;
	wire gpu_m_arvalid;
	wire gpu_m_arready;
	wire gpu_m_rid;
	wire [DATA_W-1:0] gpu_m_rdata;
	wire [1:0] gpu_m_rresp;
	wire gpu_m_rlast;
	wire gpu_m_rvalid;
	wire gpu_m_rready;
	wire gpu_irq;

	/* ------------------------------------------------------------------ */
	/* 4. Amaterrace GPU IP Core Instance (atg_top)                       */
	/* ------------------------------------------------------------------ */
	atg_top #(
		.GCLK_HZ(32'd400000000),	/* 400 MHz core logic clock */
		.S_ID_W(S_ID_W),
		.S_LEN_W(S_LEN_W),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.DATA_W(DATA_W),
		.VA_BITS(VA_BITS),
		.PA_BITS(PA_BITS),
		.LOCAL_BASE(32'd0),		/* UMA: Unified Memory Architecture */
		.LOCAL_BYTES(32'd0),		/* No dedicated local VRAM */
		.WINDOW_BYTES(32'd0),		/* No local VRAM window */
		.HOST_LIMIT(32'd0),		/* Unified: all addresses map to host memory */
		.HAS_CPU(0),			/* Minimal preset: Bare-metal autonomous CP */
		.NSU(NSU),			/* Minimal preset: 1 Shader Unit */
		.HAS_VF(1),			/* Vertex fetcher present */
		.HAS_RX(1),			/* Rasterizer present */
		.HAS_TU(1),			/* Texture unit present */
		.HAS_ROP(1),			/* Render output backend present */
		.HAS_SA(0),			/* Systolic array omitted */
		.EXT_CLIENT(0),
		.HAS_JTAG(0),			/* Pure AXI MMIO from PS */
		.HAS_DISP(0),			/* Headless UMA accelerator */
		.ROP_STENCIL(1),		/* Depth24_S8 stencil enabled */
		.MS4(0),			/* MSAA disabled (minimal preset) */
		.SU_NPHYS(4),			/* 4 physical lanes */
		.SU_NWARPS(4),			/* 4 warps per SU */
		.SU_WARP_W(2),			/* log2(SU_NWARPS) */
		.SU_GRP_W(3),			/* log2(32 / SU_NPHYS) = log2(8) = 3 */
		.SU_NREGS(32),			/* 32 registers */
		.SU_SB_ENTRIES(4),
		.SU_SBE_W(2),
		.SU_PACKED(0),			/* Packed FP16 arithmetic disabled */
		.SU_PK_SHARED(0),
		.SU_SUBGROUP(0),		/* Subgroup operations disabled */
		.SU_FRAG_RESERVE(1),
		.SU_LDS_BYTES(1024),		/* 1 KiB LDS */
		.SU_VARY_WORDS(16),
		.HAS_PROT(0),			/* Protection disabled */
		.HAS_L2(1),			/* 8 KB L2 cache enabled */
		.L2_WAYS(4),			/* 4 ways */
		.L2_SET_W(5)			/* 32 sets: 8192 / (64 * 4) = 32 */
	) gpu (
		.clk(clk_gpu),
		.rst_n(rst_n_gpu),
		.irq(gpu_irq),
		.mem_ready(mmcm_locked),
		.win_en(),

		/* GHCI 1.0 Canonical Register Port (Slave) */
		.s_awaddr(gpu_s_awaddr),
		.s_awid(gpu_s_awid),
		.s_awvalid(gpu_s_awvalid),
		.s_awready(gpu_s_awready),
		.s_wdata(gpu_s_wdata),
		.s_wstrb(gpu_s_wstrb),
		.s_wlast(gpu_s_wlast),
		.s_wvalid(gpu_s_wvalid),
		.s_wready(gpu_s_wready),
		.s_bid(gpu_s_bid),
		.s_bresp(gpu_s_bresp),
		.s_bvalid(gpu_s_bvalid),
		.s_bready(gpu_s_bready),
		.s_araddr(gpu_s_araddr),
		.s_arid(gpu_s_arid),
		.s_arlen(gpu_s_arlen),
		.s_arvalid(gpu_s_arvalid),
		.s_arready(gpu_s_arready),
		.s_rdata(gpu_s_rdata),
		.s_rid(gpu_s_rid),
		.s_rresp(gpu_s_rresp),
		.s_rlast(gpu_s_rlast),
		.s_rvalid(gpu_s_rvalid),
		.s_rready(gpu_s_rready),

		/* Host Memory DMA Master Port */
		.m_awid(gpu_m_awid),
		.m_awaddr(gpu_m_awaddr),
		.m_awlen(gpu_m_awlen),
		.m_awsize(gpu_m_awsize),
		.m_awburst(gpu_m_awburst),
		.m_awcache(gpu_m_awcache),
		.m_awprot(gpu_m_awprot),
		.m_awvalid(gpu_m_awvalid),
		.m_awready(gpu_m_awready),
		.m_wdata(gpu_m_wdata),
		.m_wstrb(gpu_m_wstrb),
		.m_wlast(gpu_m_wlast),
		.m_wvalid(gpu_m_wvalid),
		.m_wready(gpu_m_wready),
		.m_bid(gpu_m_bid),
		.m_bresp(gpu_m_bresp),
		.m_bvalid(gpu_m_bvalid),
		.m_bready(gpu_m_bready),
		.m_arid(gpu_m_arid),
		.m_araddr(gpu_m_araddr),
		.m_arlen(gpu_m_arlen),
		.m_arsize(gpu_m_arsize),
		.m_arburst(gpu_m_arburst),
		.m_arcache(gpu_m_arcache),
		.m_arprot(gpu_m_arprot),
		.m_arvalid(gpu_m_arvalid),
		.m_arready(gpu_m_arready),
		.m_rid(gpu_m_rid),
		.m_rdata(gpu_m_rdata),
		.m_rresp(gpu_m_rresp),
		.m_rlast(gpu_m_rlast),
		.m_rvalid(gpu_m_rvalid),
		.m_rready(gpu_m_rready),

		/* External client interface (unused in headless UMA) */
		.xr_wr(),
		.xr_waddr(),
		.xr_wdata(),
		.xr_wstrb(),
		.xr_rd(),
		.xr_raddr(),
		.xr_rdata(32'd0),
		.x_req_valid(1'b0),
		.x_req_ready(),
		.x_req_write(1'b0),
		.x_req_line({(32-LINE_SHIFT){1'b0}}),
		.x_req_be({LINE_BYTES{1'b0}}),
		.x_req_wdata({(LINE_BYTES*8){1'b0}}),
		.x_req_tag(8'd0),
		.x_rsp_valid(),
		.x_rsp_write(),
		.x_rsp_tag(),
		.x_rsp_rdata(),
		.x_rsp_error(),
		.x_vsync(1'b0),

		/* JTAG port (unused) */
		.j_wr(1'b0),
		.j_waddr(17'd0),
		.j_wdata(32'd0),
		.j_wstrb(4'd0),
		.j_rd(1'b0),
		.j_raddr(17'd0),
		.j_rdata(),
		.j_busy(),

		/* Display pins (unused) */
		.pclk(1'b0),
		.prst_n(1'b0),
		.pclk_sel(),
		.tmds(),
		.px_rgb(),
		.px_de(),
		.px_hs(),
		.px_vs(),
		.scl_t(),
		.scl_i(1'b1),
		.sda_t(),
		.sda_i(1'b1)
	);

	/* ------------------------------------------------------------------ */
	/* 5. Memory Master Interface Assignment                              */
	/* ------------------------------------------------------------------ */
	/* The GPU master port directly drives S_AXI_HP0_FPD. When m_axi_aclk */
	/* is synchronous to clk_gpu (or direct connection), registers ensure */
	/* high-frequency 400 MHz timing closure on the PL-PS boundary.       */
	assign m_axi_awid    = gpu_m_awid;
	assign m_axi_awaddr  = gpu_m_awaddr;
	assign m_axi_awlen   = gpu_m_awlen;
	assign m_axi_awsize  = gpu_m_awsize;
	assign m_axi_awburst = gpu_m_awburst;
	assign m_axi_awcache = gpu_m_awcache;
	assign m_axi_awprot  = gpu_m_awprot;
	assign m_axi_awvalid = gpu_m_awvalid;
	assign gpu_m_awready = m_axi_awready;

	assign m_axi_wdata   = gpu_m_wdata;
	assign m_axi_wstrb   = gpu_m_wstrb;
	assign m_axi_wlast   = gpu_m_wlast;
	assign m_axi_wvalid  = gpu_m_wvalid;
	assign gpu_m_wready  = m_axi_wready;

	assign gpu_m_bid     = m_axi_bid;
	assign gpu_m_bresp   = m_axi_bresp;
	assign gpu_m_bvalid  = m_axi_bvalid;
	assign m_axi_bready  = gpu_m_bready;

	assign m_axi_arid    = gpu_m_arid;
	assign m_axi_araddr  = gpu_m_araddr;
	assign m_axi_arlen   = gpu_m_arlen;
	assign m_axi_arsize  = gpu_m_arsize;
	assign m_axi_arburst = gpu_m_arburst;
	assign m_axi_arcache = gpu_m_arcache;
	assign m_axi_arprot  = gpu_m_arprot;
	assign m_axi_arvalid = gpu_m_arvalid;
	assign gpu_m_arready = m_axi_arready;

	assign gpu_m_rid     = m_axi_rid;
	assign gpu_m_rdata   = m_axi_rdata;
	assign gpu_m_rresp   = m_axi_rresp;
	assign gpu_m_rlast   = m_axi_rlast;
	assign gpu_m_rvalid  = m_axi_rvalid;
	assign m_axi_rready  = gpu_m_rready;

	/* ------------------------------------------------------------------ */
	/* 6. Interrupt Synchronization to PS GIC                             */
	/* ------------------------------------------------------------------ */
	am_sync u_sync_irq (
		.clk(s_axi_aclk),
		.rst_n(s_axi_aresetn),
		.d(gpu_irq),
		.q(pl_ps_irq0)
	);

	/* ------------------------------------------------------------------ */
	/* 7. Diagnostic Status LEDs                                          */
	/* ------------------------------------------------------------------ */
	assign led[0] = mmcm_locked;				/* Clock 400 MHz PLL locked */
	assign led[1] = rst_n_gpu;				/* Core out of reset */
	assign led[2] = gpu_irq;				/* Interrupt line active */
	assign led[3] = s_axi_awvalid || s_axi_arvalid;		/* MMIO read/write requested */
	assign led[4] = m_axi_awvalid || m_axi_arvalid;		/* DMA read/write requested */
	assign led[5] = s_axi_wvalid  || s_axi_rvalid;		/* MMIO data beat */
	assign led[6] = m_axi_wvalid  || m_axi_rvalid;		/* DMA data beat */
	assign led[7] = 1'b0;					/* Reserved */

	wire unused_ok = &{1'b0, clk_axi_sync, rst_n_axi_sync, m_axi_aclk, m_axi_aresetn};

endmodule

`default_nettype wire
