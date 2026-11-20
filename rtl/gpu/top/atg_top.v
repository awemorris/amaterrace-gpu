/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top: the GPU IP.  An AXI slave for the GHCI registers (s_*, the low
 * 17 address bits of the window), one AXI master to memory (m_*) and a
 * level interrupt.  The CP, the blitter and the MC are always present; the
 * other blocks come with the HAS_* and NSU parameters (design §7.6).
 *
 * One clock (gclk = mclk; the KC705's MIG clock is crossed outside, in its
 * board top) and one synchronous active-low reset, already synchronised to clk.
 * S_ID_W/S_LEN_W fit the host port (12/4 for the Zynq GP0, AXI3); the
 * master is AXI4-shaped (see am_axi_master for an AXI3 port).
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

module atg_top #(
	parameter [31:0] GCLK_HZ = 32'd0,
	parameter S_ID_W = 12,
	parameter S_LEN_W = 4,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter DATA_W = 64,
	/* Address space parameters (docs/addressing_architecture.md) */
	parameter VA_BITS = `ifdef CFG_GPU_VA_BITS `CFG_GPU_VA_BITS `else 32 `endif,
	parameter PA_BITS = `ifdef CFG_HOST_PA_BITS `CFG_HOST_PA_BITS `else 40 `endif,
	/* The MEM capability (GHCI §11.3): local memory and the window onto it
	 * (KC705: 1 GiB of DDR3 at 0x8000_0000, a 64 MiB BAR2); 0 bytes = unified. */
	parameter [31:0] LOCAL_BASE = 32'd0,
	parameter [31:0] LOCAL_BYTES = 32'd0,
	parameter [31:0] WINDOW_BYTES = 32'd0,
	/* The host addresses the GPU reaches: below HOST_LIMIT, outside local memory (MEM
	 * HOST_LIMIT, GHCI §11.2; 0 = all; KC705 0x8000_0000).  With local memory the MC
	 * sends local accesses with AXI ID 0 and host accesses with ID 1 (m_awid/m_arid). */
	parameter [63:0] TIMESTAMP_INIT = 64'd0,
	parameter [31:0] HOST_LIMIT = 32'd0,
	parameter [31:0] APERTURE_BASE_INIT = 32'd0,
	parameter [31:0] APERTURE_LIMIT_INIT = 32'hFFFFFFFF,
	parameter [15:0] SUBSYSTEM_VENDOR = 16'h0000,
	parameter [15:0] SUBSYSTEM_DEVICE = 16'h0000,
	parameter [31:0] DEVICE_VERSION = 32'h00000003,
	parameter [31:0] MEM_CACHE_CFG = 32'd0,
`ifdef CFG_TU_ENABLE_BILINEAR
	parameter TU_BILINEAR = `CFG_TU_ENABLE_BILINEAR,
`else
	parameter TU_BILINEAR = 0,
`endif
	/* Which blocks are present (design §7.6; 0 = absent). */
	parameter HAS_CPU = 0,	/* atg_cpu, the CP's firmware processor */
	parameter CPU_IMEM_INIT = "",	/* its IMEM image ($readmemh) */
	parameter CPU_DMEM_INIT = "",	/* its DMEM image */
	parameter CPU_IMEM_WORDS = 8192,	/* its IMEM in 32-bit words (KC705: 32768, 128 KiB) */
	parameter CPU_DMEM_WORDS = 4096,	/* its DMEM in words (KC705: 8192, 32 KiB) */
	parameter NSU = 0,	/* shader units */
	parameter HAS_VF = 0,	/* vertex fetcher */
	parameter HAS_RX = 0,	/* rasterizer */
	parameter HAS_TU = 0,	/* texture unit */
	parameter HAS_ROP = 0,	/* buffer writer */
	parameter HAS_SA = 0,	/* systolic array: reserved, 0 in v1 (design §3.9) */
	parameter EXT_CLIENT = 0,	/* one more MC client outside (the KC705's DC), high priority */
	parameter HAS_JTAG = 0,	/* a second register-bus master (am_jtag_regs, KC705) */
	parameter HAS_DISP = 0,	/* the display controller atg_dc, a unit of the GPU (KC705): its
				 * registers in the CP's DISP2 window (0x200), MC client C_DC (not with EXT_CLIENT) */
	parameter DC_HAS_I2C = 0,	/* atg_dc's I2C master (the KC705's ADV7511) */
`ifdef CFG_DC_ENABLE_CURSOR
	parameter DC_HAS_CURSOR = (`CFG_DC_ENABLE_CURSOR != 0),
`else
	parameter DC_HAS_CURSOR = 1,
`endif
	parameter DC_FIFO_LOG2 = 11,	/* atg_dc's pixel FIFO (720p: 11) */
	parameter DC_PX_FMT = 0,	/* atg_dc's parallel output (1: the ADV7511's YCbCr 4:2:2) */
	parameter DC_TEST_MODE = 0,	/* 1: atg_dc names a simulation's one small mode (the Verilator link) */
	parameter ROP_STENCIL = 0,
`ifdef CFG_ROP_MRT_COUNT
	parameter [3:0] MRT_COUNT = `CFG_ROP_MRT_COUNT,
`else
	parameter [3:0] MRT_COUNT = 4'd1,
`endif
`ifdef CFG_ENABLE_MSAA
	parameter MS4 = (`CFG_ENABLE_MSAA != 0 && `CFG_MSAA_SAMPLES == 4),
	parameter RX_ENABLE_MSAA = (`CFG_ENABLE_MSAA != 0),
`else
	parameter MS4 = 0,
	parameter RX_ENABLE_MSAA = 0,
`endif
`ifdef CFG_MSAA_SAMPLES
	parameter RX_MSAA_SAMPLES = `CFG_MSAA_SAMPLES,
`else
	parameter RX_MSAA_SAMPLES = 1,
`endif
`ifdef CFG_ENABLE_EARLY_Z
	parameter RX_ENABLE_EARLY_Z = (`CFG_ENABLE_EARLY_Z != 0),
`else
	parameter RX_ENABLE_EARLY_Z = 0,
`endif
`ifdef CFG_COARSE_SCAN
	parameter RX_COARSE_SCAN = (`CFG_COARSE_SCAN != 0),
`else
	parameter RX_COARSE_SCAN = 0,
`endif
`ifdef CFG_RX_ENABLE_CPOLY
	parameter RX_ENABLE_CPOLY = (`CFG_RX_ENABLE_CPOLY != 0),
`else
	parameter RX_ENABLE_CPOLY = 1,
`endif
`ifdef CFG_FMT_ENABLE_DEPTH32F
	parameter ROP_ENABLE_DEPTH32F = (`CFG_FMT_ENABLE_DEPTH32F != 0),
`else
	parameter ROP_ENABLE_DEPTH32F = 1,
`endif
`ifdef CFG_FMT_ENABLE_DEPTH24_S8
	parameter ROP_ENABLE_DEPTH24_S8 = (`CFG_FMT_ENABLE_DEPTH24_S8 != 0),
`else
	parameter ROP_ENABLE_DEPTH24_S8 = 1,
`endif
`ifdef CFG_FMT_ENABLE_DEPTH16
	parameter ROP_ENABLE_DEPTH16 = (`CFG_FMT_ENABLE_DEPTH16 != 0),
`else
	parameter ROP_ENABLE_DEPTH16 = 1,
`endif
`ifdef CFG_HAS_BLT
	parameter HAS_BLT = (`CFG_HAS_BLT != 0),
`else
	parameter HAS_BLT = 0,
`endif
`ifdef CFG_BLT_ENABLE_SCALE
	parameter BLT_SCALE = (`CFG_BLT_ENABLE_SCALE != 0),
`else
	parameter BLT_SCALE = 1,
`endif
`ifdef CFG_BLT_ENABLE_BLEND
	parameter BLT_BLEND = (`CFG_BLT_ENABLE_BLEND != 0),
`else
	parameter BLT_BLEND = 1,
`endif
`ifdef CFG_BLT_ENABLE_TILE
	parameter BLT_TILE = (`CFG_BLT_ENABLE_TILE != 0),
`else
	parameter BLT_TILE = 1,
`endif
`ifdef CFG_TU_ENABLE_FFILT
	parameter HAS_FFILT = (`CFG_TU_ENABLE_FFILT != 0),
`else
	parameter HAS_FFILT = 0,
`endif
`ifdef CFG_ROP_ENABLE_PACK
	parameter HAS_ROP_PACK = (`CFG_ROP_ENABLE_PACK != 0),
`else
	parameter HAS_ROP_PACK = 0,
`endif
`ifdef CFG_ROP_ENABLE_FBLEND
	parameter HAS_ROP_FBLEND = (`CFG_ROP_ENABLE_FBLEND != 0),
`else
	parameter HAS_ROP_FBLEND = 1,
`endif
`ifdef CFG_ROP_FAST_CLEAR
	parameter ROP_FAST_CLEAR = 1,
`else
	parameter ROP_FAST_CLEAR = 0,
`endif
`ifdef CFG_ROP_ENABLE_LOGICOP
	parameter ROP_ENABLE_LOGICOP = 1,
`else
	parameter ROP_ENABLE_LOGICOP = 0,
`endif
`ifdef CFG_ROP_DUAL_SOURCE
	parameter ROP_DUAL_SOURCE = 1,
`else
	parameter ROP_DUAL_SOURCE = 0,
`endif
`ifdef CFG_ENABLE_ARRAY
	parameter HAS_TEX_ARRAY = (`CFG_ENABLE_ARRAY != 0),
`else
	parameter HAS_TEX_ARRAY = 1,
`endif
`ifdef CFG_ENABLE_3D_CUBE
	parameter HAS_TEX_3D_CUBE = (`CFG_ENABLE_3D_CUBE != 0),
`else
	parameter HAS_TEX_3D_CUBE = 1,
`endif
`ifdef CFG_ENABLE_TRILINEAR
	parameter HAS_TEX_TRILINEAR = (`CFG_ENABLE_TRILINEAR != 0),
`else
	parameter HAS_TEX_TRILINEAR = 1,
`endif
`ifdef CFG_ENABLE_BC
	parameter TU_ENABLE_BC = (`CFG_ENABLE_BC != 0),
`else
	parameter TU_ENABLE_BC = 1,
`endif
`ifdef CFG_ENABLE_ANISO
	parameter TU_ENABLE_ANISO = (`CFG_ENABLE_ANISO != 0),
`else
	parameter TU_ENABLE_ANISO = 1,
`endif
`ifdef CFG_ENABLE_SEAMLESS_CUBE
	parameter TU_ENABLE_SEAMLESS_CUBE = (`CFG_ENABLE_SEAMLESS_CUBE != 0),
`else
	parameter TU_ENABLE_SEAMLESS_CUBE = 1,
`endif
`ifdef CFG_ENABLE_MULTIVIEWPORT
	parameter RX_ENABLE_MULTIVIEWPORT = (`CFG_ENABLE_MULTIVIEWPORT != 0),
`else
	parameter RX_ENABLE_MULTIVIEWPORT = 0,
`endif
`ifdef CFG_FMT_ENABLE_SRGB
	parameter HAS_FMT_SRGB = (`CFG_FMT_ENABLE_SRGB != 0),
`else
	parameter HAS_FMT_SRGB = 0,
`endif
`ifdef CFG_FMT_ENABLE_RGB565
	parameter HAS_FMT_RGB565 = (`CFG_FMT_ENABLE_RGB565 != 0),
`else
	parameter HAS_FMT_RGB565 = 1,
`endif
`ifdef CFG_ENABLE_ETC2
	parameter HAS_ETC = (`CFG_ENABLE_ETC2 != 0 && `CFG_TU_ENABLE_FFILT != 0),
`else
	parameter HAS_ETC = 0,
`endif
`ifdef CFG_ENABLE_MESH
	parameter HAS_MESH = (`CFG_ENABLE_MESH != 0),
`else
	parameter HAS_MESH = 0,
`endif
	parameter HAS_INDIRECT_DRAW = 0,
	parameter HAS_SECONDARY_RING = 0,
	parameter HAS_HW_WALKER = 0,
	/* The SUs' shape (design §3.7). */
`ifdef CFG_SU_NPHYS
	parameter SU_NPHYS = `CFG_SU_NPHYS,
`else
	parameter SU_NPHYS = 8,	/* Physical lanes of an SU: 4, 8, 16 or 32 */
`endif
	parameter SU_NWARPS = 4,
	parameter SU_WARP_W = 2,	/* log2(SU_NWARPS) */
`ifdef CFG_SU_GRP_W
	parameter SU_GRP_W = `CFG_SU_GRP_W,	/* log2(32/SU_NPHYS), 1 for SU_NPHYS 32 */
`else
	parameter SU_GRP_W = 2,	/* log2(32/SU_NPHYS), 1 for SU_NPHYS 32 */
`endif
	parameter SU_NREGS = 32,
	parameter SU_SB_ENTRIES = 4,
	parameter SU_SBE_W = 2,	/* log2(SU_SB_ENTRIES) */
`ifdef CFG_ENABLE_FP16
	parameter SU_PACKED = (NSU > 0) ? `CFG_ENABLE_FP16 : 0,
`else
	parameter SU_PACKED = 0,
`endif
	parameter SU_PK_SHARED = 0,	/* with SU_PACKED: the fp16 arithmetic on the FPU's fp32 datapath, a half a cycle (atg_su_fpu) */
`ifdef CFG_ENABLE_SUBGROUP
	parameter SU_SUBGROUP = (NSU > 0) ? `CFG_ENABLE_SUBGROUP : 0,
`else
	parameter SU_SUBGROUP = 0,
`endif
	parameter SU_FRAG_RESERVE = 1,	/* slots kept for fragment warps (design §3.8; KC705 2) */
`ifdef CFG_SU_LDS_KB
	parameter SU_LDS_BYTES = (NSU > 0) ? (`CFG_SU_LDS_KB * 1024) : 0,
`else
	parameter SU_LDS_BYTES = 0,
`endif
	parameter SU_VARY_WORDS = 16,
	/* Session protection (docs/ghci.md section 11.6; needs HAS_CPU): the MC's check, the CP's
	 * atg_cp_prot.  Slots, grant entries (and clog2), PLB lines (and clog2). */
`ifdef CFG_MC_ENABLE_PROT
	parameter HAS_PROT = (`CFG_MC_ENABLE_PROT != 0),
`else
	parameter HAS_PROT = 0,
`endif
	parameter PROT_SLOTS = 31,
	parameter PROT_GRANTS = 8,
	parameter PROT_GIDX_W = 3,
	parameter PROT_PLB = 4,
	parameter PROT_PLB_W = 2,
`ifdef CFG_USE_NOC_FABRIC
	parameter USE_NOC_FABRIC = (`CFG_USE_NOC_FABRIC != 0),
`else
	parameter USE_NOC_FABRIC = 0,
`endif
	parameter HAS_L2 = 0,
	parameter L2_WAYS = 16,
	parameter L2_SET_W = 8
) (
	input wire clk,
	input wire rst_n,
	output wire irq,
	input wire mem_ready,
	/* MEM WINDOW_CTRL.ENABLE (GHCI §11.1): the board's local window path answers host
	 * accesses itself while it is 0 (1 after rst_n; 0 without a window) */
	output wire win_en,

	input wire [16:0] s_awaddr,
	input wire [S_ID_W-1:0] s_awid,
	input wire s_awvalid,
	output wire s_awready,
	input wire [63:0] s_wdata,
	input wire [7:0] s_wstrb,
	input wire s_wlast,
	input wire s_wvalid,
	output wire s_wready,
	output wire [S_ID_W-1:0] s_bid,
	output wire [1:0] s_bresp,
	output wire s_bvalid,
	input wire s_bready,
	input wire [16:0] s_araddr,
	input wire [S_ID_W-1:0] s_arid,
	input wire [S_LEN_W-1:0] s_arlen,
	input wire s_arvalid,
	output wire s_arready,
	output wire [63:0] s_rdata,
	output wire [S_ID_W-1:0] s_rid,
	output wire [1:0] s_rresp,
	output wire s_rlast,
	output wire s_rvalid,
	input wire s_rready,

	output wire m_awid,
	output wire [63:0] m_awaddr,
	output wire [7:0] m_awlen,
	output wire [2:0] m_awsize,
	output wire [1:0] m_awburst,
	output wire [3:0] m_awcache,
	output wire [2:0] m_awprot,
	output wire m_awvalid,
	input wire m_awready,
	output wire [DATA_W-1:0] m_wdata,
	output wire [DATA_W/8-1:0] m_wstrb,
	output wire m_wlast,
	output wire m_wvalid,
	input wire m_wready,
	input wire m_bid,
	input wire [1:0] m_bresp,
	input wire m_bvalid,
	output wire m_bready,
	output wire m_arid,
	output wire [63:0] m_araddr,
	output wire [7:0] m_arlen,
	output wire [2:0] m_arsize,
	output wire [1:0] m_arburst,
	output wire [3:0] m_arcache,
	output wire [2:0] m_arprot,
	output wire m_arvalid,
	input wire m_arready,
	input wire m_rid,
	input wire [DATA_W-1:0] m_rdata,
	input wire [1:0] m_rresp,
	input wire m_rlast,
	input wire m_rvalid,
	output wire m_rready,

	/*
	 * What lives next to the GPU (the KC705's DC): the register
	 * bus for the window above 0x10000 (the other module returns 0 outside
	 * its registers; the read data is ORed), one MC client (EXT_CLIENT) and
	 * the display's vsync pulse.
	 */
	output wire xr_wr,
	output wire [16:0] xr_waddr,
	output wire [31:0] xr_wdata,
	output wire [3:0] xr_wstrb,
	output wire xr_rd,
	output wire [16:0] xr_raddr,
	input wire [31:0] xr_rdata,
	input wire x_req_valid,
	output wire x_req_ready,
	input wire x_req_write,
	input wire [31-LINE_SHIFT:0] x_req_line,
	input wire [LINE_BYTES-1:0] x_req_be,
	input wire [LINE_BYTES*8-1:0] x_req_wdata,
	input wire [7:0] x_req_tag,
	output wire x_rsp_valid,
	output wire x_rsp_write,
	output wire [7:0] x_rsp_tag,
	output wire [LINE_BYTES*8-1:0] x_rsp_rdata,
	output wire x_rsp_error,
	input wire x_vsync,
	/* The second register-bus master (HAS_JTAG): served when the AXI slave is idle. */
	input wire j_wr,
	input wire [16:0] j_waddr,
	input wire [31:0] j_wdata,
	input wire [3:0] j_wstrb,
	input wire j_rd,
	input wire [16:0] j_raddr,
	output wire [31:0] j_rdata,
	output wire j_busy,
	/* The display controller (HAS_DISP): its pixel clock and reset, the
	 * clock choice, the video outputs (pclk) and the I2C pins (open drain). */
	input wire pclk,
	input wire prst_n,
	output wire pclk_sel,
	output wire [29:0] tmds,
	output wire [23:0] px_rgb,
	output wire px_de,
	output wire px_hs,
	output wire px_vs,
	output wire scl_t,
	input wire scl_i,
	output wire sda_t,
	input wire sda_i
);
	/*
	 * MC clients: 0 CP, 1 BLT, then the present blocks in this order: CPU,
	 * VF, TU, ROP, the atomic unit (with any SU), SA, EXT, and two per SU.
	 */
	localparam HAS_ATOM = NSU > 0 ? 1 : 0;
	/* Vulkan 1.0 core rendering (CAPS[30] and the FMT capability): every graphics block and
	 * Vulkan's 64 varying components (the KC705's shape). */
	localparam CORE1 = HAS_VF != 0 && HAS_RX != 0 && HAS_ROP != 0 && HAS_TU != 0 && NSU != 0 &&
		SU_VARY_WORDS >= 64;
	localparam C_CPU = 2;
	/* RESIDENT_WARPS: the warps the shader units run at once. */
	localparam [31:0] CP_RESIDENT_WARPS = NSU * SU_NWARPS;
	/* RESIDENT_WARPS[23:16]: the general registers of a lane. */
	localparam [31:0] CP_NREGS = NSU != 0 ? SU_NREGS : 0;
	localparam C_VF = C_CPU + (HAS_CPU != 0 ? 1 : 0);
	localparam C_TU = C_VF + (HAS_VF != 0 ? 1 : 0);
	localparam C_ROP = C_TU + (HAS_TU != 0 ? 1 : 0);
	localparam C_ATOM = C_ROP + (HAS_ROP != 0 ? 1 : 0);
	localparam C_SA = C_ATOM + HAS_ATOM;
	localparam C_EXT = C_SA + (HAS_SA != 0 ? 1 : 0);
	localparam C_DC = C_EXT;	/* the DC takes the outside client's place (HAS_DISP) */
	localparam [7:0] C_DC8 = C_DC;
	localparam HAS_EXT = EXT_CLIENT != 0 || HAS_DISP != 0;
	localparam C_SU = C_EXT + (HAS_EXT ? 1 : 0);	/* SU k: C_SU+2k (D$), C_SU+2k+1 (I$) */
	localparam NCLIENT = C_SU + 2 * NSU;
	localparam [NCLIENT-1:0] HIGH = {{(NCLIENT-1){1'b0}}, 1'b1} |
		({{(NCLIENT-1){1'b0}}, HAS_EXT} << C_EXT);
	localparam UNIT_ADDR_W = (HAS_HW_WALKER != 0) ? VA_BITS : ((VA_BITS < 32) ? 32 : VA_BITS);
	localparam MC_ADDR_W = PA_BITS;
	localparam UNIT_LA_W = UNIT_ADDR_W - LINE_SHIFT;
	localparam MC_LA_W = MC_ADDR_W - LINE_SHIFT;
	localparam LA_W = MC_LA_W;
	localparam LINE_BITS = LINE_BYTES * 8;
	localparam [63:0] P_LOCAL_BASE_64 = {32'd0, LOCAL_BASE};
	localparam [63:0] P_LOCAL_BYTES_64 = {32'd0, LOCAL_BYTES};
	wire unused_addr_params = &{1'b0, VA_BITS[15:0], PA_BITS[15:0]};

	/* The register bus. */
	wire reg_wr;
	wire [16:0] reg_waddr;
	wire [31:0] reg_wdata;
	wire [3:0] reg_wstrb;
	wire reg_rd;
	wire [16:0] reg_raddr;
	wire [31:0] reg_rdata;
	wire [31:0] cp_reg_rdata;

	/* The AXI slave's bus (a_*) and the JTAG master (j_*, HAS_JTAG) share it. */
	wire a_reg_wr, a_reg_rd;
	wire [16:0] a_reg_waddr, a_reg_raddr;
	wire [31:0] a_reg_wdata;
	wire [3:0] a_reg_wstrb;

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire rst_top_high;
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b01)) u_rst_top (.I0(rst_n), .O(rst_top_high));

	(* keep = "true", dont_touch = "true" *) wire a_busy;
	(* dont_touch = "true" *) LUT2 #(.INIT(4'hE)) u_abusy (.I0(a_reg_wr), .I1(a_reg_rd), .O(a_busy));
	wire j_go = HAS_JTAG != 0 && !a_busy;

	(* keep = "true", dont_touch = "true" *) wire [4:0] a_busy_b;
	genvar gab;
	generate
		for (gab = 0; gab < 5; gab = gab + 1) begin : g_abusy_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_abb (.I0(a_busy), .O(a_busy_b[gab]));
		end
	endgenerate

	(* dont_touch = "true" *) reg [4:0] reg_wr_q;
	(* dont_touch = "true" *) reg [16:0] reg_waddr_cp, reg_waddr_xr;
	(* dont_touch = "true" *) reg [31:0] reg_wdata_cp, reg_wdata_xr;
	(* dont_touch = "true" *) reg [3:0] reg_wstrb_cp, reg_wstrb_xr;
	(* dont_touch = "true" *) reg [3:0] reg_rd_q;
	(* dont_touch = "true" *) reg [16:0] reg_raddr_cp, reg_raddr_xr;
	(* dont_touch = "true" *) reg [31:0] xr_rdata_q;
	(* dont_touch = "true" *) reg [31:0] j_rdata_q;
	(* dont_touch = "true" *) reg j_busy_q;

	wire reg_wr_d = a_reg_wr || (j_go && j_wr);
	wire [16:0] reg_waddr_d = a_busy_b[0] ? a_reg_waddr : j_waddr;
	wire [31:0] reg_wdata_d = {
		a_busy_b[2] ? a_reg_wdata[31:16] : j_wdata[31:16],
		a_busy_b[1] ? a_reg_wdata[15:0]  : j_wdata[15:0]
	};
	wire [3:0] reg_wstrb_d = a_busy_b[3] ? a_reg_wstrb : j_wstrb;
	wire reg_rd_d = a_reg_rd || (j_go && j_rd);
	wire [16:0] reg_raddr_d = a_busy_b[4] ? a_reg_raddr : j_raddr;

	always @(posedge clk or posedge rst_top_high) begin
		if (rst_top_high) begin
			reg_wr_q <= 5'd0;
			reg_waddr_cp <= 17'd0;
			reg_waddr_xr <= 17'd0;
			reg_wdata_cp <= 32'd0;
			reg_wdata_xr <= 32'd0;
			reg_wstrb_cp <= 4'd0;
			reg_wstrb_xr <= 4'd0;
			reg_rd_q <= 4'd0;
			reg_raddr_cp <= 17'd0;
			reg_raddr_xr <= 17'd0;
			xr_rdata_q <= 32'd0;
			j_rdata_q <= 32'd0;
			j_busy_q <= 1'b0;
		end else begin
			reg_wr_q <= {5{reg_wr_d}};
			reg_waddr_cp <= reg_waddr_d;
			reg_waddr_xr <= reg_waddr_d;
			reg_wdata_cp <= reg_wdata_d;
			reg_wdata_xr <= reg_wdata_d;
			reg_wstrb_cp <= reg_wstrb_d;
			reg_wstrb_xr <= reg_wstrb_d;
			reg_rd_q <= {4{reg_rd_d}};
			reg_raddr_cp <= reg_raddr_d;
			reg_raddr_xr <= reg_raddr_d;
			xr_rdata_q <= xr_rdata;
			j_rdata_q <= reg_rdata;
			j_busy_q <= a_busy_b[3];
		end
	end

	assign reg_wr = reg_wr_q[0];
	assign reg_waddr = reg_waddr_cp;
	assign reg_wdata = reg_wdata_cp;
	assign reg_wstrb = reg_wstrb_cp;
	assign reg_rd = reg_rd_q[0];
	assign reg_raddr = reg_raddr_cp;
	assign j_rdata = j_rdata_q;
	assign j_busy = j_busy_q;
`else
	reg        j_wr_q, j_rd_q;
	reg [16:0] j_waddr_q, j_raddr_q;
	reg [31:0] j_wdata_q;
	reg [3:0]  j_wstrb_q;
	reg [31:0] j_rdata_q;
	reg        j_busy_q;
	wire a_busy = a_reg_wr || a_reg_rd;
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			j_wr_q    <= 1'b0;
			j_waddr_q <= 17'd0;
			j_wdata_q <= 32'd0;
			j_wstrb_q <= 4'd0;
			j_rd_q    <= 1'b0;
			j_raddr_q <= 17'd0;
			j_rdata_q <= 32'd0;
			j_busy_q  <= 1'b0;
		end else begin
			j_wr_q    <= (HAS_JTAG != 0) ? j_wr      : 1'b0;
			j_waddr_q <= (HAS_JTAG != 0) ? j_waddr   : 17'd0;
			j_wdata_q <= (HAS_JTAG != 0) ? j_wdata   : 32'd0;
			j_wstrb_q <= (HAS_JTAG != 0) ? j_wstrb   : 4'd0;
			j_rd_q    <= (HAS_JTAG != 0) ? j_rd      : 1'b0;
			j_raddr_q <= (HAS_JTAG != 0) ? j_raddr   : 17'd0;
			j_rdata_q <= (HAS_JTAG != 0) ? reg_rdata : 32'd0;
			j_busy_q  <= (HAS_JTAG != 0) ? a_busy    : 1'b0;
		end
	end
	wire j_go_wr = (HAS_JTAG != 0) && !a_reg_wr;
	wire j_go_rd = (HAS_JTAG != 0) && !a_reg_rd;
	assign reg_wr    = a_reg_wr || (j_go_wr && j_wr_q);
	assign reg_waddr = a_reg_wr ? a_reg_waddr : j_waddr_q;
	assign reg_wdata = a_reg_wr ? a_reg_wdata : j_wdata_q;
	assign reg_wstrb = a_reg_wr ? a_reg_wstrb : j_wstrb_q;
	assign reg_rd    = a_reg_rd || (j_go_rd && j_rd_q);
	assign reg_raddr = a_reg_rd ? a_reg_raddr : j_raddr_q;
	assign j_rdata   = j_rdata_q;
	assign j_busy    = j_busy_q;
`endif

	/* The DC (HAS_DISP) and the CP's atg_cp_disp: its register bus, flips and events. */
	wire dc_vsync, dc_ev_error, dc_ev_hotplug, dc_idle, dc_irq_display;
	wire cp_dc_d_we;
	wire [5:0] cp_dc_d_idx;
	wire [31:0] cp_dc_d_wdata, cp_dc_d_wmask;
	(* keep = "true" *) reg dc_d_we;
	(* keep = "true" *) reg [5:0] dc_d_idx;
	(* keep = "true" *) reg [31:0] dc_d_wdata, dc_d_wmask;
	wire cp_dc_flip_valid, cp_dc_flip_plane;
	wire [31:0] cp_dc_flip_base;
	(* keep = "true" *) reg dc_flip_valid, dc_flip_plane;
	(* keep = "true" *) reg [31:0] dc_flip_base;
	wire [5:0] dc_d_ridx;
	wire [31:0] dc_d_rdata, dc_frame_count;
	wire [1:0] dc_taken, dc_taken_cancel, dc_pending, dc_err;

	/*
	 * Pipeline register isolating CP sequencer from DC register decode (Rule 3).
	 * Register writes and FLIP commands are pipelined together to maintain strict
	 * program order.
	 *
	 * CP observes DC as idle only when DC itself is idle and no write or flip
	 * is currently in-flight in this pipeline register (!dc_d_we && !dc_flip_valid).
	 *
	 * Furthermore, CP observes dc_pending with any in-flight flip factored in so
	 * back-to-back flips to the same plane correctly observe pending status during
	 * the 1-cycle pipeline transition.
	 *
	 * Note on read path (dc_d_ridx, dc_d_rdata): CP sequencer does not read back
	 * DC registers immediately after writing. Host HCR reads occur via AXI MMIO,
	 * which inherently incurs multi-cycle latency, so unpipelined read path
	 * introduces no read-after-write hazard.
	 */
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			dc_d_we       <= 1'b0;
			dc_d_idx      <= 6'd0;
			dc_d_wdata    <= 32'd0;
			dc_d_wmask    <= 32'd0;
			dc_flip_valid <= 1'b0;
			dc_flip_plane <= 1'b0;
			dc_flip_base  <= 32'd0;
		end else begin
			dc_d_we       <= cp_dc_d_we;
			dc_d_idx      <= cp_dc_d_idx;
			dc_d_wdata    <= cp_dc_d_wdata;
			dc_d_wmask    <= cp_dc_d_wmask;
			dc_flip_valid <= cp_dc_flip_valid;
			dc_flip_plane <= cp_dc_flip_plane;
			dc_flip_base  <= cp_dc_flip_base;
		end
	end

	wire [1:0] cp_seen_dc_pending = dc_pending | (dc_flip_valid ? (dc_flip_plane ? 2'b10 : 2'b01) : 2'b00);
	wire cp_seen_dc_idle = dc_idle && !dc_d_we && !dc_flip_valid;
`ifdef SYNTH_KINTEX7
	assign reg_rdata = cp_reg_rdata | xr_rdata_q;
	assign xr_wr = reg_wr_q[1];
	assign xr_waddr = reg_waddr_xr;
	assign xr_wdata = reg_wdata_xr;
	assign xr_wstrb = reg_wstrb_xr;
	assign xr_rd = reg_rd_q[1];
	assign xr_raddr = reg_raddr_xr;
`else
	assign reg_rdata = cp_reg_rdata | xr_rdata;
	assign xr_wr = reg_wr;
	assign xr_waddr = reg_waddr;
	assign xr_wdata = reg_wdata;
	assign xr_wstrb = reg_wstrb;
	assign xr_rd = reg_rd;
	assign xr_raddr = reg_raddr;
`endif

	am_axi_regs #(.ADDR_BITS(17), .ID_W(S_ID_W), .LEN_W(S_LEN_W)) regs (
		.clk(clk),
		.rst_n(rst_n),
		.s_awaddr(s_awaddr),
		.s_awid(s_awid),
		.s_awvalid(s_awvalid),
		.s_awready(s_awready),
		.s_wdata(s_wdata),
		.s_wstrb(s_wstrb),
		.s_wlast(s_wlast),
		.s_wvalid(s_wvalid),
		.s_wready(s_wready),
		.s_bid(s_bid),
		.s_bresp(s_bresp),
		.s_bvalid(s_bvalid),
		.s_bready(s_bready),
		.s_araddr(s_araddr),
		.s_arid(s_arid),
		.s_arlen(s_arlen),
		.s_arvalid(s_arvalid),
		.s_arready(s_arready),
		.s_rdata(s_rdata),
		.s_rid(s_rid),
		.s_rresp(s_rresp),
		.s_rlast(s_rlast),
		.s_rvalid(s_rvalid),
		.s_rready(s_rready),
		.reg_wr(a_reg_wr),
		.reg_waddr(a_reg_waddr),
		.reg_wdata(a_reg_wdata),
		.reg_wstrb(a_reg_wstrb),
		.reg_rd(a_reg_rd),
		.reg_raddr(a_reg_raddr),
		.reg_rdata(reg_rdata)
	);

	/* The CP's controls. */
	wire core_rst_n;
	wire mc_quiesce;
	wire mc_flush;
	wire [3:0] mc_flush_rep;
	wire l2_flush;
	wire l2_flush_done;
	wire l2_idle;
	wire [MC_ADDR_W-1:0] aperture_base;
	wire [MC_ADDR_W-1:0] aperture_limit;
	wire mc_idle;
	wire mc_fault;
	wire [7:0] mc_fault_client;
	wire [MC_ADDR_W-1:0] mc_fault_addr;
	wire mc_fault_write;
	/*
	 * The MC's clients whose requests unit_idle counts: all but the CP's
	 * (ring, fences, debug port) and the outside client (the DC).
	 */
	localparam [NCLIENT-1:0] MC_UNITS = ~({{(NCLIENT-1){1'b0}}, 1'b1} |
		(HAS_EXT ? {{(NCLIENT-1){1'b0}}, 1'b1} << C_EXT : {NCLIENT{1'b0}}));
	wire mc_unit_idle;
	/* Session protection: the MC's and the CP's sides (atg_cp_prot). */
	localparam PROT = HAS_PROT != 0 && HAS_CPU != 0;
	localparam [NCLIENT-1:0] RMW = HAS_ATOM != 0 ? {{(NCLIENT-1){1'b0}}, 1'b1} << C_ATOM :
		{NCLIENT{1'b0}};
	wire mc_fault_prot, mc_fault_mem, mc_chk_idle, mc_inv_pending;
	wire [5:0] mc_fault_slot;
	wire [7:0] mc_fault_tag;
	wire [7:0] mc_fault_req_tag;
	wire [NCLIENT-1:0] c_req_chk, c_req_tbl;
	wire [NCLIENT*6-1:0] c_req_slot;
	wire [MC_ADDR_W-1:0] prot_tbase;
	wire [31:0] prot_inv_n;
	wire [MC_ADDR_W-13:0] prot_inv_g;
	wire prot_inv_valid, prot_gw_valid;
	wire [PROT_GIDX_W-1:0] prot_gw_idx;
	wire [49:0] prot_gw_data;
	wire [5:0] prot_unit;
	wire prot_sw_inv;
	wire cp_req_chk, cpu_req_chk, cpu_req_tbl;
	wire [5:0] cp_req_slot, cpu_req_slot;
	wire st_we;
	wire [9:0] st_idx;
	/* The blocks but the TU see STATE[0..511] (0x200-0x2FF is the TU's). */
	wire ust_we = st_we && !st_idx[9];
	wire [8:0] ust_idx = st_idx[8:0];
	wire [31:0] st_wdata;
	wire blt_kick;
	wire blt_busy;
	wire blt_done;
	wire blt_error;
	wire [3:0] blt_error_kind;

	/* The AMB: one request port per client, the responses shared. */
	wire [NCLIENT-1:0] c_req_valid;
	wire [NCLIENT-1:0] c_req_ready;
	wire [NCLIENT-1:0] c_req_write;
	wire [NCLIENT*LA_W-1:0] c_req_line;
	wire [NCLIENT*LINE_BYTES-1:0] c_req_be;
	wire [NCLIENT*LINE_BITS-1:0] c_req_wdata;
	wire [NCLIENT*8-1:0] c_req_tag;
	wire [NCLIENT*4-1:0] c_req_session;
	wire [NCLIENT*2-1:0] c_req_exec_type;
	wire [NCLIENT-1:0] rsp_valid;
	wire [NCLIENT-1:0] rsp_write_v;
	wire [NCLIENT*8-1:0] rsp_tag_v;
	wire [NCLIENT*LINE_BITS-1:0] rsp_rdata_v;
	wire [NCLIENT-1:0] rsp_error_v;

	/* Upstream GPU-unit AMB ports (before optional am_mmu_bridge) */
	wire [NCLIENT-1:0] u_req_valid;
	wire [NCLIENT-1:0] u_req_ready;
	wire [NCLIENT-1:0] u_req_write;
	wire [NCLIENT*UNIT_LA_W-1:0] u_req_line;
	wire [NCLIENT*LINE_BYTES-1:0] u_req_be;
	wire [NCLIENT*LINE_BITS-1:0] u_req_wdata;
	wire [NCLIENT*8-1:0] u_req_tag;
	wire [NCLIENT-1:0] u_req_chk, u_req_tbl;
	wire [NCLIENT*6-1:0] u_req_slot;
	wire [NCLIENT-1:0] u_rsp_valid;
	wire [NCLIENT-1:0] u_rsp_write;
	wire [NCLIENT*8-1:0] u_rsp_tag;
	wire [NCLIENT*LINE_BITS-1:0] u_rsp_rdata;
	wire [NCLIENT-1:0] u_rsp_error;

	/* Hardware MMU & per-client VA->PA bridge signals (HAS_HW_WALKER=1) */
	localparam MMU_BLT  = 0;
	localparam MMU_VF   = (HAS_BLT != 0) ? 1 : 0;
	localparam MMU_TU   = MMU_VF + ((HAS_VF != 0) ? 1 : 0);
	localparam MMU_ROP  = MMU_TU + ((HAS_TU != 0) ? 1 : 0);
	localparam MMU_ATOM = MMU_ROP + ((HAS_ROP != 0) ? 1 : 0);
	localparam MMU_SA   = MMU_ATOM + ((HAS_ATOM != 0) ? 1 : 0);
	localparam MMU_SU   = MMU_SA + ((HAS_SA != 0) ? 1 : 0);
	localparam MMU_NCLIENTS_RAW = MMU_SU + 2 * NSU;
	localparam MMU_NCLIENTS = (MMU_NCLIENTS_RAW > 0) ? MMU_NCLIENTS_RAW : 1;
	localparam MMU_FC_W = (MMU_NCLIENTS > 8) ? 4 : 3;

	wire [3:0] cp_active_session;
	wire [31:0] mmu_sb_rdata;
	wire [31:0] mmu_hcr_rdata;
	wire ctl_mmu_fault;
	wire [3:0] ctl_mmu_fault_kind, ctl_mmu_fault_session;
	wire [7:0] ctl_mmu_fault_client;
	wire [VA_BITS-1:0] ctl_mmu_fault_addr;
	wire mmu_walk_req_valid, mmu_walk_req_ready, mmu_walk_rsp_valid, mmu_walk_rsp_error;
	wire [PA_BITS-1:0] mmu_walk_req_addr;
	wire [63:0] mmu_walk_rsp_data;
	wire any_brg_inflight;
	wire effective_mc_unit_idle = mc_unit_idle && !any_brg_inflight;

	/* The CP's links to the blocks of design §7.6. */
	wire draw_kick, cs_kick, cs_mesh, lc_kick, raw_kick;
	wire [3:0] inv, cp_inv;
	wire hcr_we;
	wire [9:0] hcr_widx, hcr_ridx;
	wire [31:0] hcr_wdata, hcr_wmask;
	wire v_valid, v_done;
	wire [31:0] v_addr;
	wire [15:0] v_dwords;
	wire [7:0] v_tag;
	wire fw_valid, fw_ready, fw_last, fw_active;
	wire [31:0] fw_data;
	wire [9:0] cpu_st_ridx;
	wire [31:0] cpu_st_rdata, cp_fence_last, cpu_hcr_rdata, cpu_fault_addr;
	wire [31:0] diag_cp_pc, diag_cp_status, diag_pipe_fsm;
	wire [3:0] blt_fsm, mc_fsm, vf_fsm, rx_fsm, rop_fsm;
	wire cp_fence_ev, cp_halt, cp_open, cpu_fault, cpu_stall, cpu_result;
	wire [39:0] occ_count;	/* atg_rop's occlusion counter, for QUERY */
	wire occ_clear, cp_occ_clear;
	/* The sequencer's µop and the CPU's window, for atg_cp_prot. */
	wire [6:0] fw_side, u_side;
	wire u_fw, u_ok, u_active, f_chk;
	wire prot_kick_ok;	/* KICK: the units are session 0's */
	wire [7:0] prot_wdt_tag;	/* a watchdog fault's job tag */
	wire [1:0] u_req;
	wire [7:0] u_tag;
	wire [5:0] f_slot, v_slot;
	wire sb_we, sb_re;
	wire [5:0] sb_idx;
	wire [31:0] sb_wdata, prot_sb_rdata, prot_hcr_rdata, cp_sb_rdata;
	wire cp_fault_session_clear;
	wire [7:0] cp_fault_session_tag;

	assign inv = cp_inv | {4{prot_sw_inv}};
	assign occ_clear = cp_occ_clear || prot_sw_inv;

	atg_cp #(
		.ADDR_W(MC_ADDR_W),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.GCLK_HZ(GCLK_HZ),
		.UNITS({HAS_SA != 0, NSU != 0, HAS_TU != 0, HAS_ROP != 0, HAS_RX != 0, HAS_VF != 0,
			2'b11}),
		.HAS_CPU(HAS_CPU),
		.HAS_DISP(HAS_DISP),
		.DISP_PLANES(DC_HAS_CURSOR ? 2 : 1),
		.DC_CLIENT(C_DC8),
		.HAS_DBG(HAS_JTAG),
		.PACKED(NSU != 0 && SU_PACKED != 0),
		.SUBGROUP(NSU != 0 && SU_SUBGROUP != 0),
		.RESIDENT_WARPS(CP_RESIDENT_WARPS[15:0]),
		.NREGS(CP_NREGS[7:0]),
		.LOCAL_BASE(LOCAL_BASE),
		.LOCAL_BYTES(LOCAL_BYTES),
		.WINDOW_BYTES(WINDOW_BYTES),
		.HOST_LIMIT(HOST_LIMIT),
		.APERTURE_BASE_INIT(APERTURE_BASE_INIT),
		.APERTURE_LIMIT_INIT(APERTURE_LIMIT_INIT),
		.SUBSYSTEM_VENDOR(SUBSYSTEM_VENDOR),
		.SUBSYSTEM_DEVICE(SUBSYSTEM_DEVICE),
		.DEVICE_VERSION(DEVICE_VERSION),
		.MEM_CACHE_CFG(MEM_CACHE_CFG),
		.VA_BITS(VA_BITS),
		.PA_BITS(PA_BITS),
		.NSU(NSU),
		.SU_NPHYS(SU_NPHYS),
		.SU_PACKED(SU_PACKED),
		.SU_SUBGROUP(SU_SUBGROUP),
		.SU_LDS_KB(SU_LDS_BYTES >> 10),
		.HAS_BLT(HAS_BLT),
		.BLT_SCALE(BLT_SCALE),
		.BLT_BLEND(BLT_BLEND),
		.BLT_TILE(BLT_TILE),
		.HAS_TU(HAS_TU),
		.TU_BILINEAR(TU_BILINEAR),
		.HAS_FFILT(HAS_FFILT && (HAS_TU != 0)),
		.HAS_ROP(HAS_ROP),
		.HAS_ROP_PACK(HAS_ROP_PACK && (HAS_ROP != 0)),
		.HAS_D16(ROP_ENABLE_DEPTH16 && (HAS_ROP != 0)),
		.HAS_D24S8(ROP_ENABLE_DEPTH24_S8 && (HAS_ROP != 0)),
		.HAS_D32F(ROP_ENABLE_DEPTH32F && (HAS_ROP != 0)),
		.HAS_STENCIL(ROP_STENCIL && (HAS_ROP != 0)),
		.HAS_FBLEND(HAS_ROP_FBLEND && (HAS_ROP != 0)),
		.HAS_VF(HAS_VF),
		.HAS_TEX_ARRAY(HAS_TEX_ARRAY),
		.HAS_TEX_3D_CUBE(HAS_TEX_3D_CUBE),
		.HAS_TEX_TRILINEAR(HAS_TEX_TRILINEAR),
		.HAS_FMT_SRGB(HAS_FMT_SRGB),
		.HAS_FMT_RGB565(HAS_FMT_RGB565),
		.HAS_MESH(HAS_MESH),
		.MS4(MS4),
		.CORE1(CORE1),
		.HAS_ETC(HAS_ETC && (HAS_TU != 0)),
		.HAS_PROT(PROT),
		.PROT_SLOTS(PROT_SLOTS[7:0]),
		.PROT_GRANTS(PROT_GRANTS[15:0]),
		.HAS_INDIRECT_DRAW(HAS_INDIRECT_DRAW),
		.HAS_SECONDARY_RING(HAS_SECONDARY_RING),
		.HAS_HW_WALKER(HAS_HW_WALKER),
		.TIMESTAMP_INIT(TIMESTAMP_INIT),
		.MRT_COUNT(MRT_COUNT),
		.C_CPU(C_CPU),
		.C_VF(C_VF),
		.C_TU(C_TU),
		.C_ROP(C_ROP),
		.C_ATOM(C_ATOM),
		.C_SA(C_SA),
		.C_DC(C_DC),
		.C_SU(C_SU),
		.RX_ENABLE_CPOLY(RX_ENABLE_CPOLY),
		.RX_ENABLE_EARLY_Z(RX_ENABLE_EARLY_Z),
		.RX_COARSE_SCAN(RX_COARSE_SCAN),
		.ROP_FAST_CLEAR(ROP_FAST_CLEAR),
		.ROP_ENABLE_LOGICOP(ROP_ENABLE_LOGICOP),
		.ROP_DUAL_SOURCE(ROP_DUAL_SOURCE)
	) cp (
		.clk(clk),
		.rst_n(rst_n),
		.reg_wr(reg_wr),
		.reg_waddr(reg_waddr),
		.reg_wdata(reg_wdata),
		.reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd),
		.reg_raddr(reg_raddr),
		.reg_rdata(cp_reg_rdata),
		.irq(irq),
		.mem_ready(mem_ready),
		.core_rst_n(core_rst_n),
		.win_en(win_en),
		.mc_quiesce(mc_quiesce),
		.mc_flush(mc_flush),
		.mc_flush_rep(mc_flush_rep),
		.l2_flush(l2_flush),
		.l2_flush_done(l2_flush_done),
		.l2_idle(l2_idle),
		.aperture_base(aperture_base),
		.aperture_limit(aperture_limit),
		.mc_idle(mc_idle),
		.mc_fault(mc_fault),
		.mc_fault_client(mc_fault_client),
		.mc_fault_addr(mc_fault_addr),
		.mc_fault_write(mc_fault_write),
		.mc_fault_prot(mc_fault_prot),
		.mc_fault_mem(mc_fault_mem),
		.mc_fault_tag(mc_fault_tag),
		.mc_fault_req_tag(mc_fault_req_tag),
		.mmu_fault(ctl_mmu_fault),
		.mmu_fault_kind(ctl_mmu_fault_kind),
		.mmu_fault_client(ctl_mmu_fault_client),
		.mmu_fault_session(ctl_mmu_fault_session),
		.mmu_fault_addr(ctl_mmu_fault_addr),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.blt_kick(blt_kick),
		.blt_busy(blt_busy),
		.blt_error(blt_error),
		.blt_error_kind(blt_error_kind),
		.req_valid(c_req_valid[0]),
		.req_ready(c_req_ready[0]),
		.req_write(c_req_write[0]),
		.req_line(c_req_line[0*LA_W +: LA_W]),
		.req_be(c_req_be[0*LINE_BYTES +: LINE_BYTES]),
		.req_wdata(c_req_wdata[0*LINE_BITS +: LINE_BITS]),
		.req_tag(c_req_tag[0*8 +: 8]),
		.req_chk(cp_req_chk),
		.req_slot(cp_req_slot),
		.rsp_valid(rsp_valid[0]),
		.rsp_write(rsp_write_v[0]),
		.rsp_tag(rsp_tag_v[0*8 +: 8]),
		.rsp_rdata(rsp_rdata_v[0*LINE_BITS +: LINE_BITS]),
		.rsp_error(rsp_error_v[0]),
		.draw_kick(draw_kick),
		.cs_kick(cs_kick),
		.cs_mesh(cs_mesh),
		.lc_kick(lc_kick),
		.raw_kick(raw_kick),
		.inv(cp_inv),
		.busy_ext({sa_busy, su_busy, tu_busy, rop_busy, rx_busy, vf_busy, 1'b0, !effective_mc_unit_idle}),
		.vsync(HAS_DISP != 0 ? dc_vsync : x_vsync),
		.x_fault({1'b0, su_fault}),
		.x_fault_kind(8'h01),
		.x_fault_addr({32'd0, su_fault_addr}),
		.x_fault_tag({8'd0, (HAS_PROT != 0) ? prot_unit_tag : (HAS_HW_WALKER != 0 ? {4'd0, active_mmu_session} : 8'd0)}),
		.su_fault_stage(su_fault_stage),
		.hcr_we(hcr_we),
		.hcr_widx(hcr_widx),
		.hcr_wdata(hcr_wdata),
		.hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx),
		.x_rdata(cpu_hcr_rdata | sa_hcr_rdata | prot_hcr_rdata | mmu_hcr_rdata),
		.v_valid(v_valid),
		.v_addr(v_addr),
		.v_dwords(v_dwords),
		.v_tag(v_tag),
		.v_done(v_done),
		.fw_valid(fw_valid),
		.fw_ready(fw_ready),
		.fw_data(fw_data),
		.fw_last(fw_last),
		.fw_active(fw_active),
		.fw_side(fw_side),
		.u_fw(u_fw),
		.u_side(u_side),
		.u_req(u_req),
		.u_tag(u_tag),
		.u_ok(u_ok),
		.u_active(u_active),
		.wdt_tag(prot_wdt_tag),
		.fault_session_clear(cp_fault_session_clear),
		.fault_session_tag(cp_fault_session_tag),
		.f_chk(f_chk),
		.f_slot(f_slot),
		.cpu_st_ridx(cpu_st_ridx),
		.cpu_st_rdata(cpu_st_rdata),
		.cp_fence_last(cp_fence_last),
		.cp_fence_ev(cp_fence_ev),
		.cp_halt(cp_halt),
		.cp_open(cp_open),
		.cpu_fault(cpu_fault),
		.cpu_fault_addr(cpu_fault_addr),
		.cpu_stall(cpu_stall),
		.cpu_result(cpu_result),
		.occ_count(occ_count), .occ_clear(cp_occ_clear),
		.d_we(cp_dc_d_we), .d_idx(cp_dc_d_idx), .d_wdata(cp_dc_d_wdata), .d_wmask(cp_dc_d_wmask),
		.d_ridx(dc_d_ridx), .d_rdata(dc_d_rdata), .flip_valid(cp_dc_flip_valid),
		.flip_plane(cp_dc_flip_plane), .flip_base(cp_dc_flip_base), .taken(dc_taken),
		.taken_cancel(dc_taken_cancel), .dc_pending(cp_seen_dc_pending), .dc_idle(cp_seen_dc_idle),
		.frame_count(dc_frame_count), .dc_err(dc_err),
		.dc_ev({dc_ev_hotplug, dc_ev_error, dc_vsync}),
		.dc_irq_display(dc_irq_display),
		.diag_cp_pc(diag_cp_pc),
		.diag_cp_status(diag_cp_status),
		.diag_pipe_fsm(diag_pipe_fsm),
		.sb_we(sb_we),
		.sb_re(sb_re),
		.sb_idx(sb_idx),
		.sb_wdata(sb_wdata),
		.sb_rdata(cp_sb_rdata),
		.active_session(cp_active_session),
		.boot_caps()
	);

	generate
	if (HAS_BLT != 0) begin : gen_blt
		atg_blt #(
			.ADDR_W(UNIT_ADDR_W),
			.LINE_BYTES(LINE_BYTES),
			.LINE_SHIFT(LINE_SHIFT),
			.MS4(MS4),
			.ENABLE_SCALE(BLT_SCALE),
			.ENABLE_BLEND(BLT_BLEND),
			.ENABLE_TILE(BLT_TILE)
		) blt (
			.clk(clk),
			.rst_n(core_rst_n),
			.st_we(ust_we),
			.st_idx(ust_idx),
			.st_wdata(st_wdata),
			.kick(blt_kick),
			.busy(blt_busy),
			.done(blt_done),
			.error(blt_error),
			.error_kind(blt_error_kind),
			.req_valid(u_req_valid[1]),
			.req_ready(u_req_ready[1]),
			.req_write(u_req_write[1]),
			.req_line(u_req_line[1*UNIT_LA_W +: UNIT_LA_W]),
			.req_be(u_req_be[1*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(u_req_wdata[1*LINE_BITS +: LINE_BITS]),
			.req_tag(u_req_tag[1*8 +: 8]),
			.rsp_valid(u_rsp_valid[1]),
			.rsp_write(u_rsp_write[1]),
			.rsp_tag(u_rsp_tag[1*8 +: 8]),
			.rsp_rdata(u_rsp_rdata[1*LINE_BITS +: LINE_BITS]),
			.rsp_error(u_rsp_error[1]),
			.fsm(blt_fsm)
		);
	end else begin : gen_no_blt
		reg r_blt_err;
		always @(posedge clk or negedge core_rst_n) begin
			if (!core_rst_n)
				r_blt_err <= 1'b0;
			else
				r_blt_err <= blt_kick;
		end
		assign blt_busy = 1'b0;
		assign blt_done = 1'b0;
		assign blt_error = r_blt_err;
		assign blt_error_kind = 4'd1;	/* OPCODE error */
		assign blt_fsm = 4'd0;
		assign u_req_valid[1] = 1'b0;
		assign u_req_write[1] = 1'b0;
		assign u_req_line[1*UNIT_LA_W +: UNIT_LA_W] = {UNIT_LA_W{1'b0}};
		assign u_req_be[1*LINE_BYTES +: LINE_BYTES] = {LINE_BYTES{1'b0}};
		assign u_req_wdata[1*LINE_BITS +: LINE_BITS] = {LINE_BITS{1'b0}};
		assign u_req_tag[1*8 +: 8] = 8'd0;
	end
	endgenerate

	wire [MC_ADDR_W-1:0] mc_awaddr, mc_araddr;
	assign m_awaddr = {{(64-MC_ADDR_W){1'b0}}, mc_awaddr};
	assign m_araddr = {{(64-MC_ADDR_W){1'b0}}, mc_araddr};

	atg_mc #(
		.NCLIENT(NCLIENT),
		.HIGH_MASK(HIGH),
		/* the CP (its debug port) and the DC (scan-out goes on through HALTED, FAULTED
		 * and RESET; design §18.2) */
		.QUIESCE_EXEMPT({{(NCLIENT-1){1'b0}}, 1'b1} |
			(HAS_DISP != 0 ? {{(NCLIENT-1){1'b0}}, 1'b1} << C_DC : {NCLIENT{1'b0}})),
		.ROOT_CLIENT(HAS_EXT ? C_EXT : -1),
		.ROOT_KEEP(HAS_DISP != 0 ? 1 : 0),	/* flush and axi_idle leave the DC alone */
		.ADDR_W(MC_ADDR_W),
		.VRAM_AW(MC_ADDR_W),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.DATA_W(DATA_W),
		.OUTSTANDING_LOG2(2),
		.LOCAL_BASE(P_LOCAL_BASE_64[MC_ADDR_W-1:0]),
		.LOCAL_BYTES(P_LOCAL_BYTES_64[MC_ADDR_W-1:0]),
		.UNIT_MASK(MC_UNITS),
		.HAS_PROT(PROT),
		.RMW_MASK(RMW),
		.PROT_PLB(PROT_PLB),
		.PROT_PLB_W(PROT_PLB_W),
		.PROT_GRANTS(PROT_GRANTS),
		.PROT_GIDX_W(PROT_GIDX_W),
		.HAS_L2(HAS_L2),
		.L2_WAYS(L2_WAYS),
		.L2_SET_W(L2_SET_W),
		.USE_FLUSH_REP(1),
		.HAS_MMU_WALK(HAS_HW_WALKER != 0 ? 1 : 0),
		.USE_NOC_FABRIC(USE_NOC_FABRIC != 0 ? 1 : 0),
		.SU_BASE(C_SU)
	) mc (
		.clk(clk),
		.rst_n(rst_n),
		.c_req_valid(c_req_valid),
		.c_req_ready(c_req_ready),
		.c_req_write(c_req_write),
		.c_req_line(c_req_line),
		.c_req_be(c_req_be),
		.c_req_wdata(c_req_wdata),
		.c_req_tag(c_req_tag),
		.c_req_chk(c_req_chk),
		.c_req_tbl(c_req_tbl),
		.c_req_slot(c_req_slot),
		.c_req_session(c_req_session),
		.c_req_exec_type(c_req_exec_type),
		.rsp_valid(rsp_valid),
		.rsp_write(rsp_write_v),
		.rsp_tag(rsp_tag_v),
		.rsp_rdata(rsp_rdata_v),
		.rsp_error(rsp_error_v),
		.quiesce(mc_quiesce),
		.flush(mc_flush),
		.flush_rep(mc_flush_rep),
		.l2_flush(l2_flush),
		.l2_flush_done(l2_flush_done),
		.l2_idle_out(l2_idle),
		.aperture_base(aperture_base),
		.aperture_limit(aperture_limit),
		.axi_idle(mc_idle),
		.fault(mc_fault),
		.fault_client(mc_fault_client),
		.fault_addr(mc_fault_addr),
		.fault_write(mc_fault_write),
		.fault_prot(mc_fault_prot),
		.fault_slot(mc_fault_slot),
		.fault_mem(mc_fault_mem),
		.fault_tag(mc_fault_req_tag),
		.chk_idle(mc_chk_idle),
		.unit_idle(mc_unit_idle),
		.dc_urgent(dc_urgent),
		.dc_panic(dc_panic),
		.prot_tbase(prot_tbase),
		.prot_inv_valid(prot_inv_valid),
		.prot_inv_g(prot_inv_g),
		.prot_inv_n(prot_inv_n),
		.prot_inv_pending(mc_inv_pending),
		.prot_gw_valid(prot_gw_valid),
		.prot_gw_idx(prot_gw_idx),
		.prot_gw_data(prot_gw_data),
		.mmu_walk_req_valid(mmu_walk_req_valid),
		.mmu_walk_req_ready(mmu_walk_req_ready),
		.mmu_walk_req_addr(mmu_walk_req_addr),
		.mmu_walk_rsp_valid(mmu_walk_rsp_valid),
		.mmu_walk_rsp_data(mmu_walk_rsp_data),
		.mmu_walk_rsp_error(mmu_walk_rsp_error),
		.m_awid(m_awid),
		.m_awaddr(mc_awaddr),
		.m_awlen(m_awlen),
		.m_awsize(m_awsize),
		.m_awburst(m_awburst),
		.m_awcache(m_awcache),
		.m_awprot(m_awprot),
		.m_awvalid(m_awvalid),
		.m_awready(m_awready),
		.m_wdata(m_wdata),
		.m_wstrb(m_wstrb),
		.m_wlast(m_wlast),
		.m_wvalid(m_wvalid),
		.m_wready(m_wready),
		.m_bid(m_bid),
		.m_bresp(m_bresp),
		.m_bvalid(m_bvalid),
		.m_bready(m_bready),
		.m_arid(m_arid),
		.m_araddr(mc_araddr),
		.m_arlen(m_arlen),
		.m_arsize(m_arsize),
		.m_arburst(m_arburst),
		.m_arcache(m_arcache),
		.m_arprot(m_arprot),
		.m_arvalid(m_arvalid),
		.m_arready(m_arready),
		.m_rid(m_rid),
		.m_rdata(m_rdata),
		.m_rresp(m_rresp),
		.m_rlast(m_rlast),
		.m_rvalid(m_rvalid),
		.m_rready(m_rready),
		.fsm(mc_fsm)
	);

	/* The CP's firmware processor. */
	generate
	if (HAS_CPU != 0) begin : g_cpu
		atg_cpu #(
			.ADDR_W(MC_ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
			.IMEM_WORDS(CPU_IMEM_WORDS), .DMEM_WORDS(CPU_DMEM_WORDS),
			.IMEM_INIT(CPU_IMEM_INIT), .DMEM_INIT(CPU_DMEM_INIT)
		) cpu (
			.clk(clk), .rst_n(core_rst_n), .por_n(rst_n),
			.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata),
			.hcr_wmask(hcr_wmask), .hcr_ridx(hcr_ridx), .hcr_rdata(cpu_hcr_rdata),
			.v_valid(v_valid), .v_addr(v_addr), .v_dwords(v_dwords), .v_tag(v_tag),
			.v_done(v_done),
			.fw_valid(fw_valid), .fw_ready(fw_ready), .fw_data(fw_data), .fw_last(fw_last),
			.fw_active(fw_active), .fw_side(fw_side),
			.sb_we(sb_we), .sb_re(sb_re), .sb_idx(sb_idx), .sb_wdata(sb_wdata),
			.prot_rdata(prot_sb_rdata | cp_sb_rdata | mmu_sb_rdata), .v_slot(v_slot),
			.st_ridx(cpu_st_ridx), .st_rdata(cpu_st_rdata), .fence_last(cp_fence_last),
			.fence_ev(cp_fence_ev), .halt_req(cp_halt), .open(cp_open),
			.diag_cp_pc(diag_cp_pc), .diag_cp_status(diag_cp_status),
			.ev_result(cpu_result), .stall(cpu_stall), .fault(cpu_fault),
			.fault_addr(cpu_fault_addr),
			.req_valid(c_req_valid[C_CPU]), .req_ready(c_req_ready[C_CPU]),
			.req_write(c_req_write[C_CPU]), .req_line(c_req_line[C_CPU*LA_W +: LA_W]),
			.req_be(c_req_be[C_CPU*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(c_req_wdata[C_CPU*LINE_BITS +: LINE_BITS]),
			.req_tag(c_req_tag[C_CPU*8 +: 8]),
			.req_chk(cpu_req_chk), .req_tbl(cpu_req_tbl), .req_slot(cpu_req_slot),
			.rsp_valid(rsp_valid[C_CPU]), .rsp_write(rsp_write_v[C_CPU]), .rsp_tag(rsp_tag_v[C_CPU*8 +: 8]),
			.rsp_rdata(rsp_rdata_v[C_CPU*LINE_BITS +: LINE_BITS]), .rsp_error(rsp_error_v[C_CPU])
		);
	end else begin : g_no_cpu
		assign cpu_hcr_rdata = 32'd0;
		assign v_done = 1'b0;
		assign fw_valid = 1'b0;
		assign fw_data = 32'd0;
		assign fw_last = 1'b0;
		assign fw_active = 1'b0;
		assign fw_side = 7'd0;
		assign sb_we = 1'b0;
		assign sb_re = 1'b0;
		assign sb_idx = 6'd0;
		assign sb_wdata = 32'd0;
		assign cpu_req_chk = 1'b0;
		assign cpu_req_tbl = 1'b0;
		assign cpu_req_slot = 6'd0;
		assign cpu_st_ridx = 10'd0;
		assign cpu_result = 1'b0;
		assign cpu_stall = 1'b0;
		assign cpu_fault = 1'b0;
		assign cpu_fault_addr = 32'd0;
		assign diag_cp_pc = 32'd0;
		assign diag_cp_status = 32'd0;
		wire unused_cpu = &{1'b0, hcr_we, hcr_widx, hcr_wdata, hcr_wmask, hcr_ridx, v_valid,
			v_addr, v_dwords, v_tag, fw_ready, cpu_st_rdata, cp_fence_last, cp_fence_ev,
			cp_halt, cp_open, cp_sb_rdata, mmu_sb_rdata};
	end
	endgenerate

	/*
	 * Session protection (PROT): atg_cp_prot beside the CPU.  The units'
	 * requests carry prot_unit; the CP's fence unit and the CPU's DMA their
	 * own; the DC's none.  drain_ok: the units idle, none of their requests
	 * waiting at a leaf, none with chk in the MC, all of theirs answered.
	 */
	localparam [NCLIENT-1:0] UNIT_LEAF = MC_UNITS &
		~(HAS_CPU != 0 ? {{(NCLIENT-1){1'b0}}, 1'b1} << C_CPU : {NCLIENT{1'b0}});
	wire prot_scrub, su_scrub_any;
	wire [7:0] prot_fault_tag, prot_unit_tag;
	wire units_busy = blt_busy || vf_busy || rx_busy || rop_busy || tu_busy || su_busy || sa_busy;
	wire drain_ok = !units_busy && !(|(c_req_valid & UNIT_LEAF)) && !any_brg_inflight && mc_chk_idle && mc_unit_idle;

	genvar pc;
	generate
	for (pc = 0; pc < NCLIENT; pc = pc + 1) begin : g_side
		if (pc == 0) begin : g_cp
			assign c_req_chk[pc] = PROT && cp_req_chk;
			assign c_req_tbl[pc] = 1'b0;
			assign c_req_slot[pc*6 +: 6] = PROT ? cp_req_slot : 6'd0;
			assign c_req_session[pc*4 +: 4] = 4'd0;
			assign c_req_exec_type[pc*2 +: 2] = c_req_write[pc] ? 2'b01 : 2'b00;
			assign u_req_chk[pc] = 1'b0;
			assign u_req_tbl[pc] = 1'b0;
			assign u_req_slot[pc*6 +: 6] = 6'd0;
		end else if (HAS_CPU != 0 && pc == C_CPU) begin : g_cpu
			assign c_req_chk[pc] = PROT && cpu_req_chk;
			assign c_req_tbl[pc] = PROT && cpu_req_tbl;
			assign c_req_slot[pc*6 +: 6] = PROT ? cpu_req_slot : 6'd0;
			assign c_req_session[pc*4 +: 4] = 4'd0;
			assign c_req_exec_type[pc*2 +: 2] = c_req_write[pc] ? 2'b01 : 2'b00;
			assign u_req_chk[pc] = 1'b0;
			assign u_req_tbl[pc] = 1'b0;
			assign u_req_slot[pc*6 +: 6] = 6'd0;
		end else if (HAS_EXT && pc == C_EXT) begin : g_ext	/* the DC or the outside client: root */
			assign c_req_chk[pc] = 1'b0;
			assign c_req_tbl[pc] = 1'b0;
			assign c_req_slot[pc*6 +: 6] = 6'd0;
			assign c_req_session[pc*4 +: 4] = 4'd0;
			assign c_req_exec_type[pc*2 +: 2] = 2'b00;
			assign u_req_chk[pc] = 1'b0;
			assign u_req_tbl[pc] = 1'b0;
			assign u_req_slot[pc*6 +: 6] = 6'd0;
		end else begin : g_unit
			assign u_req_chk[pc] = PROT && prot_unit != 6'd0;
			assign u_req_tbl[pc] = 1'b0;
			assign u_req_slot[pc*6 +: 6] = PROT ? prot_unit : 6'd0;
		end
	end

	if (PROT) begin : g_prot
		atg_cp_prot #(
			.ADDR_W(MC_ADDR_W), .SLOTS(PROT_SLOTS[7:0]), .GRANTS(PROT_GRANTS[15:0]),
			.GIDX_W(PROT_GIDX_W)
		) prot (
			.clk(clk), .rst_n(core_rst_n),
			.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
			.hcr_ridx(hcr_ridx), .hcr_rdata(prot_hcr_rdata),
			.aperture_base(aperture_base), .aperture_limit(aperture_limit),
			.sb_we(sb_we), .sb_idx(sb_idx), .sb_wdata(sb_wdata), .sb_rdata(prot_sb_rdata),
			.v_tag(v_tag), .v_slot(v_slot),
			.u_tag(u_tag), .u_fw(u_fw), .u_side(u_side), .u_req(u_req), .u_ok(u_ok),
			.u_active(u_active),
			.f_chk(f_chk), .f_slot(f_slot),
			.drain_ok(drain_ok), .sw_inv(prot_sw_inv), .scrub(prot_scrub),
			.scrub_busy(su_scrub_any), .prot_unit(prot_unit),
			.tbase(prot_tbase), .inv_valid(prot_inv_valid), .inv_g(prot_inv_g),
			.inv_n(prot_inv_n), .inv_pending(mc_inv_pending), .gw_valid(prot_gw_valid),
			.gw_idx(prot_gw_idx), .gw_data(prot_gw_data),
			.fault_slot(mc_fault_slot), .fault_tag(prot_fault_tag), .unit_tag(prot_unit_tag),
			.wdt_tag(prot_wdt_tag), .fault_clear_en(cp_fault_session_clear),
			.fault_clear_tag(cp_fault_session_tag),
			.kick_ok(prot_kick_ok), .su_kick(draw_kick || cs_kick)
		);
		/* The MC's refusal: the slot's session; a unit's other faults: prot_unit's. */
		reg [7:0] f_tag;
		integer fc;
		always @(*) begin
			f_tag = 8'd0;
			for (fc = 0; fc < NCLIENT; fc = fc + 1)
				if (UNIT_LEAF[fc] && mc_fault_client == fc[7:0])
					f_tag = prot_unit_tag;
			if (mc_fault_prot)
				f_tag = prot_fault_tag;
		end
		assign mc_fault_tag = f_tag;
		wire unused_p = &{1'b0, sb_re};
	end else begin : g_no_prot
		assign prot_hcr_rdata = 32'd0;
		assign prot_sb_rdata = 32'd0;
		assign v_slot = 6'd0;
		assign u_ok = 1'b1;
		assign u_active = 1'b1;
		assign f_chk = 1'b0;
		assign f_slot = 6'd0;
		assign prot_sw_inv = 1'b0;
		assign prot_scrub = 1'b0;
		assign prot_unit = 6'd0;
		assign prot_tbase = {MC_ADDR_W{1'b0}};
		assign prot_inv_valid = 1'b0;
		assign prot_inv_g = {(MC_ADDR_W-12){1'b0}};
		assign prot_inv_n = 32'd0;
		assign prot_gw_valid = 1'b0;
		assign prot_gw_idx = {PROT_GIDX_W{1'b0}};
		assign prot_gw_data = 50'd0;
		assign prot_fault_tag = 8'd0;
		assign prot_unit_tag = 8'd0;
		assign prot_wdt_tag = 8'd0;
		assign prot_kick_ok = 1'b1;
		assign mc_fault_tag = 8'd0;
		wire unused_np = &{1'b0, sb_we, sb_re, sb_idx, sb_wdata, u_tag, u_fw, u_side, u_req,
			mc_fault_prot, mc_fault_mem, mc_fault_slot, mc_inv_pending, mc_chk_idle, drain_ok,
			cp_req_chk, cp_req_slot, cpu_req_chk, cpu_req_tbl, cpu_req_slot, su_scrub_any, v_slot,
			prot_scrub,
			prot_sb_rdata, prot_fault_tag, prot_unit_tag};
	end
	endgenerate

	/*
	 * The blocks of design §7.6 behind their parameters.  The graphics
	 * links (VF, RX, TU, ROP, SA) go to SU 0 only; the other SUs run
	 * compute (the work is not yet distributed over the SUs).
	 */
	localparam DW = SU_NPHYS * 32;

	wire vf_busy, rx_busy, tu_busy, rop_busy, sa_busy, su_busy;
	wire su_fault;
	wire [31:0] su_fault_addr;
	wire [3:0] su_fault_stage;
	wire [31:0] sa_hcr_rdata;

	/* VF ↔ SU 0. */
	wire vl_req, vl_gnt, vl_we, vl_go;
	wire [7:0] vl_ptbase;
	wire [5:0] vl_reg;
	wire [4:0] vl_lane;
	wire [31:0] vl_data, vl_mask;
	/* VF → RX (a primitive waits until SU 0's vertex warp of its PT block has
	 * ended: pt_done, atg_su_pt). */
	wire prim_valid, prim_ready, prim_last, rx_prim_ready;
	wire [7:0] pt_done;
	wire prim_ok = pt_done[prim_vtx[7:5]];
	wire [25:0] prim_vtx;
	wire [2:0] prim_free;
	/* RX ↔ SU 0. */
	wire pt_rd, pt_free;
	wire [7:0] pt_idx, pt_free_idx;
	wire [6:0] pt_word;
	wire [31:0] pt_rdata;
	wire fl_req, fl_gnt, fl_we, fl_pw_we, fl_go;
	wire [5:0] fl_reg;
	wire [4:0] fl_lane;
	wire [31:0] fl_data, fl_pw_data, fl_mask;
	wire [11:0] fl_pw_addr;
	wire [63:0] fl_info;
	/* Mesh Stream: SU 0 → RX */
	wire su_mesh_valid, su_mesh_ready, su_mesh_last;
	wire [701:0] su_mesh_tri;
	wire [15:0] su_mesh_id;
	/* RX → ROP. */
	wire dx_valid, dx_ready, dx_last, ord_valid;
	wire [15:0] dx_seq, ord_seq;
	wire [31:0] dx_xy;
	wire [3:0] dx_mask;
	wire [127:0] dx_depth;
	/* SU 0 ↔ TU. */
	wire tx_valid, tx_ready, tx_last, tr_valid, tr_ready, tr_last;
	wire [7:0] tx_op;
	wire [3:0] tx_slot, tx_samp_slot, tx_mask;
	wire tx_vs;
	wire [639:0] tx_coord;
	wire [11:0] tx_off;
	wire [15:0] tx_tag, tr_tag;
	wire [511:0] tr_data;
	/* SU 0 → ROP. */
	wire ex_valid, ex_ready, ex_last;
	wire [15:0] ex_seq, ex_next;
	wire [31:0] ex_xy;
	wire [3:0] ex_mask;
	wire [511:0] ex_color, ex_color1;
	wire ex_has_src1;
	wire [154:0] ex_aux;
	wire [127:0] ex_depth;
	/* SU 0 ↔ SA. */
	wire sa_push_valid, sa_push_ready, sa_pop_valid, sa_pop_ready, sa_ctl_valid;
	wire [DW-1:0] sa_push_data, sa_pop_data;
	wire [31:0] sa_ctl_data, sa_qstat, sa_stat, sa_qtag;
	/* SUs ↔ the atomic unit. */
	wire [(NSU > 0 ? NSU : 1)-1:0] at_valid, at_ready, at_rsp_valid;
	wire [(NSU > 0 ? NSU : 1)*4-1:0] at_op;
	wire [(NSU > 0 ? NSU : 1)*30-1:0] at_addr;
	wire [(NSU > 0 ? NSU : 1)*32-1:0] at_a, at_b;
	wire [31:0] at_old;
	wire at_error;
	wire [(NSU > 0 ? NSU : 1)-1:0] su_busy_v, su_fault_v, su_scrub_v;
	wire spine_pt_scrub_busy;
	assign su_scrub_any = (NSU > 0 && |su_scrub_v) || spine_pt_scrub_busy;
	wire [(NSU > 0 ? NSU : 1)*32-1:0] su_fault_addr_v;	/* each SU's fault PC */
	wire [(NSU > 0 ? NSU : 1)*4-1:0] su_fault_stage_v;	/* each SU's fault stage */
	wire [(NSU > 0 ? NSU : 1)*2-1:0] su_at_stage;
	wire [(NSU > 0 ? NSU : 1)*4-1:0] su_fsm_v;
	wire [3:0] su_fsm = NSU > 0 ? su_fsm_v[3:0] : 4'd0;
	wire [7:0] pipe_busy_mask = {blt_busy, sa_busy, su_busy, tu_busy, rop_busy, rx_busy, vf_busy, !mc_unit_idle};
	assign diag_pipe_fsm = {pipe_busy_mask, blt_fsm, mc_fsm, su_fsm, rop_fsm, rx_fsm, vf_fsm};
	wire unused_su_fsm = &{1'b0, su_fsm_v};

	generate
	if (HAS_VF != 0) begin : g_vf
		atg_vf #(.ADDR_W(UNIT_ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) vf (
			.clk(clk), .rst_n(core_rst_n), .st_we(ust_we), .st_idx(ust_idx), .st_wdata(st_wdata),
			.draw_kick(draw_kick), .busy(vf_busy), .fsm(vf_fsm),
			.vl_req(vl_req), .vl_gnt(vl_gnt), .vl_ptbase(vl_ptbase), .vl_go(vl_go),
			.vl_mask(vl_mask), .vl_we(vl_we), .vl_reg(vl_reg), .vl_lane(vl_lane),
			.vl_data(vl_data),
			.prim_valid(prim_valid), .prim_ready(prim_ready), .prim_vtx(prim_vtx),
			.prim_free(prim_free), .prim_last(prim_last),
			.req_valid(u_req_valid[C_VF]), .req_ready(u_req_ready[C_VF]),
			.req_write(u_req_write[C_VF]), .req_line(u_req_line[C_VF*UNIT_LA_W +: UNIT_LA_W]),
			.req_be(u_req_be[C_VF*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(u_req_wdata[C_VF*LINE_BITS +: LINE_BITS]),
			.req_tag(u_req_tag[C_VF*8 +: 8]),
			.rsp_valid(u_rsp_valid[C_VF]), .rsp_write(u_rsp_write[C_VF]), .rsp_tag(u_rsp_tag[C_VF*8 +: 8]),
			.rsp_rdata(u_rsp_rdata[C_VF*LINE_BITS +: LINE_BITS]), .rsp_error(u_rsp_error[C_VF])
		);
	end else begin : g_no_vf
		assign vf_busy = 1'b0;
		assign vf_fsm = 4'd0;
		assign vl_req = 1'b0;
		assign vl_go = 1'b0;
		assign vl_mask = 32'd0;
		assign vl_we = 1'b0;
		assign vl_reg = 6'd0;
		assign vl_lane = 5'd0;
		assign vl_data = 32'd0;
		assign prim_valid = 1'b0;
		assign prim_vtx = 26'd0;
		assign prim_free = 3'd0;
		assign prim_last = 1'b0;
		wire unused_vf = &{1'b0, draw_kick, vl_gnt, vl_ptbase, prim_ready};
	end

	if (HAS_RX != 0) begin : g_rx
		atg_rx #(
			.HAS_SU(NSU > 0 ? 1 : 0),
			.ENABLE_MSAA(RX_ENABLE_MSAA),
			.MSAA_SAMPLES(RX_MSAA_SAMPLES),
			.ENABLE_EARLY_Z(RX_ENABLE_EARLY_Z),
			.COARSE_SCAN(RX_COARSE_SCAN),
			.ENABLE_CPOLY(RX_ENABLE_CPOLY),
			.ENABLE_MULTIVIEWPORT(RX_ENABLE_MULTIVIEWPORT)
		) rx (
			.clk(clk), .rst_n(core_rst_n), .st_we(ust_we), .st_idx(ust_idx), .st_wdata(st_wdata),
			.raw_kick(raw_kick), .busy(rx_busy), .fsm(rx_fsm),
			.prim_valid(prim_valid && prim_ok), .prim_ready(rx_prim_ready),
			.prim_vtx(prim_vtx), .prim_free(prim_free), .prim_last(prim_last),
			.pt_rd(pt_rd), .pt_idx(pt_idx), .pt_word(pt_word), .pt_rdata(pt_rdata),
			.pt_free(pt_free), .pt_free_idx(pt_free_idx),
			.fl_req(fl_req), .fl_gnt(fl_gnt), .fl_we(fl_we), .fl_reg(fl_reg), .fl_lane(fl_lane),
			.fl_data(fl_data), .fl_pw_we(fl_pw_we), .fl_pw_addr(fl_pw_addr),
			.fl_pw_data(fl_pw_data), .fl_go(fl_go), .fl_mask(fl_mask), .fl_info(fl_info),
			.dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy),
			.dx_mask(dx_mask), .dx_depth(dx_depth), .dx_last(dx_last),
			.ord_valid(ord_valid), .ord_seq(ord_seq),
			.mesh_valid(su_mesh_valid), .mesh_ready(su_mesh_ready),
			.mesh_tri(su_mesh_tri), .mesh_last(su_mesh_last), .mesh_id(su_mesh_id)
		);
		assign prim_ready = rx_prim_ready && prim_ok;
	end else begin : g_no_rx
		assign rx_busy = 1'b0;
		assign rx_fsm = 4'd0;
		assign prim_ready = 1'b0;
		assign rx_prim_ready = 1'b0;
		assign su_mesh_ready = 1'b0;
		assign pt_rd = 1'b0;
		assign pt_idx = 8'd0;
		assign pt_word = 7'd0;
		assign pt_free = 1'b0;
		assign pt_free_idx = 8'd0;
		assign fl_req = 1'b0;
		assign fl_we = 1'b0;
		assign fl_reg = 6'd0;
		assign fl_lane = 5'd0;
		assign fl_data = 32'd0;
		assign fl_pw_we = 1'b0;
		assign fl_pw_addr = 12'd0;
		assign fl_pw_data = 32'd0;
		assign fl_go = 1'b0;
		assign fl_mask = 32'd0;
		assign fl_info = 64'd0;
		assign dx_valid = 1'b0;
		assign dx_seq = 16'd0;
		assign dx_xy = 32'd0;
		assign dx_mask = 4'd0;
		assign dx_depth = 128'd0;
		assign dx_last = 1'b0;
		assign ord_valid = 1'b0;
		assign ord_seq = 16'd0;
		wire unused_rx = &{1'b0, raw_kick, prim_valid, prim_vtx, prim_free, prim_last,
			pt_rdata, fl_gnt, dx_ready, prim_ok, rx_prim_ready,
			su_mesh_valid, su_mesh_last, su_mesh_tri, su_mesh_id};
	end

	if (HAS_TU != 0) begin : g_tu
		atg_tu #(
			.ADDR_W(UNIT_ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
			.ENABLE_BILINEAR(TU_BILINEAR != 0),
			.ENABLE_FFILT(HAS_FFILT != 0),
			.ENABLE_ETC2(HAS_ETC != 0),
			.ENABLE_ARRAY(HAS_TEX_ARRAY != 0),
			.ENABLE_3D_CUBE(HAS_TEX_3D_CUBE != 0),
			.ENABLE_TRILINEAR(HAS_TEX_TRILINEAR != 0),
			.ENABLE_BC(TU_ENABLE_BC != 0),
			.ENABLE_ANISO(TU_ENABLE_ANISO != 0),
			.ENABLE_SEAMLESS_CUBE(TU_ENABLE_SEAMLESS_CUBE != 0),
			.ENABLE_MSAA(RX_ENABLE_MSAA != 0)
		) tu (
			.clk(clk), .rst_n(core_rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
			.inv(inv[1]), .busy(tu_busy),
			.tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op), .tx_slot(tx_slot),
			.tx_samp_slot(tx_samp_slot), .tx_vs(tx_vs),
			.tx_mask(tx_mask), .tx_coord(tx_coord), .tx_off(tx_off), .tx_tag(tx_tag),
			.tx_last(tx_last),
			.tr_valid(tr_valid), .tr_ready(tr_ready), .tr_tag(tr_tag), .tr_data(tr_data),
			.tr_last(tr_last),
			.req_valid(u_req_valid[C_TU]), .req_ready(u_req_ready[C_TU]),
			.req_write(u_req_write[C_TU]), .req_line(u_req_line[C_TU*UNIT_LA_W +: UNIT_LA_W]),
			.req_be(u_req_be[C_TU*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(u_req_wdata[C_TU*LINE_BITS +: LINE_BITS]),
			.req_tag(u_req_tag[C_TU*8 +: 8]),
			.rsp_valid(u_rsp_valid[C_TU]), .rsp_write(u_rsp_write[C_TU]), .rsp_tag(u_rsp_tag[C_TU*8 +: 8]),
			.rsp_rdata(u_rsp_rdata[C_TU*LINE_BITS +: LINE_BITS]), .rsp_error(u_rsp_error[C_TU])
		);
	end else begin : g_no_tu
		assign tu_busy = 1'b0;
		assign tx_ready = 1'b0;
		assign tr_valid = 1'b0;
		assign tr_tag = 16'd0;
		assign tr_data = 512'd0;
		assign tr_last = 1'b0;
		wire unused_tu = &{1'b0, tx_valid, tx_op, tx_slot, tx_samp_slot, tx_vs, tx_mask, tx_coord, tx_off, tx_tag, tx_last,
			tr_ready};
	end

	if (HAS_ROP != 0) begin : g_rop
		atg_rop #(
			.ADDR_W(UNIT_ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
			.STENCIL(ROP_STENCIL),
			.MRT_COUNT(MRT_COUNT),
			.ENABLE_MSAA(RX_ENABLE_MSAA),
			.ENABLE_DEPTH32F(ROP_ENABLE_DEPTH32F),
			.ENABLE_DEPTH24_S8(ROP_ENABLE_DEPTH24_S8),
			.ENABLE_DEPTH16(ROP_ENABLE_DEPTH16),
			.ENABLE_FBLEND(HAS_ROP_FBLEND),
			.ENABLE_PACK(HAS_ROP_PACK)
		) rop (
			.clk(clk), .rst_n(core_rst_n), .st_we(ust_we), .st_idx(ust_idx), .st_wdata(st_wdata),
			.busy(rop_busy), .fsm(rop_fsm),
			.ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy),
			.ex_mask(ex_mask), .ex_color(ex_color), .ex_color1(ex_color1), .ex_has_src1(ex_has_src1), .ex_depth(ex_depth), .ex_last(ex_last),
			.ex_next(ex_next), .ex_aux(ex_aux),
			.dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy),
			.dx_mask(dx_mask), .dx_depth(dx_depth), .dx_last(dx_last),
			.ord_valid(ord_valid), .ord_seq(ord_seq),
			.occ_count(occ_count), .occ_clear(occ_clear),
			.req_valid(u_req_valid[C_ROP]), .req_ready(u_req_ready[C_ROP]),
			.req_write(u_req_write[C_ROP]), .req_line(u_req_line[C_ROP*UNIT_LA_W +: UNIT_LA_W]),
			.req_be(u_req_be[C_ROP*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(u_req_wdata[C_ROP*LINE_BITS +: LINE_BITS]),
			.req_tag(u_req_tag[C_ROP*8 +: 8]),
			.rsp_valid(u_rsp_valid[C_ROP]), .rsp_write(u_rsp_write[C_ROP]), .rsp_tag(u_rsp_tag[C_ROP*8 +: 8]),
			.rsp_rdata(u_rsp_rdata[C_ROP*LINE_BITS +: LINE_BITS]), .rsp_error(u_rsp_error[C_ROP])
		);
	end else begin : g_no_rop
		assign rop_busy = 1'b0;
		assign rop_fsm = 4'd0;
		assign occ_count = 40'd0;
		assign ex_ready = 1'b0;
		assign ex_next = 16'd0;
		assign dx_ready = 1'b0;
		wire unused_rop = &{1'b0, ex_valid, ex_seq, ex_xy, ex_mask, ex_color, ex_color1, ex_has_src1, ex_depth, ex_last, ex_aux,
			dx_valid, dx_seq, dx_xy, dx_mask, dx_depth, dx_last, ord_valid, ord_seq, occ_clear};
	end

	if (HAS_SA != 0) begin : g_sa
		atg_sa #(.ADDR_W(UNIT_ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .NPHYS(SU_NPHYS)) sa (
			.clk(clk), .rst_n(core_rst_n), .st_we(ust_we), .st_idx(ust_idx), .st_wdata(st_wdata),
			.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
			.hcr_ridx(hcr_ridx), .hcr_rdata(sa_hcr_rdata),
			.push_valid(sa_push_valid), .push_ready(sa_push_ready), .push_data(sa_push_data),
			.pop_valid(sa_pop_valid), .pop_ready(sa_pop_ready), .pop_data(sa_pop_data),
			.ctl_valid(sa_ctl_valid), .ctl_data(sa_ctl_data),
			.qstat(sa_qstat), .sastat(sa_stat), .qtag(sa_qtag), .busy(sa_busy),
			.req_valid(u_req_valid[C_SA]), .req_ready(u_req_ready[C_SA]),
			.req_write(u_req_write[C_SA]), .req_line(u_req_line[C_SA*UNIT_LA_W +: UNIT_LA_W]),
			.req_be(u_req_be[C_SA*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(u_req_wdata[C_SA*LINE_BITS +: LINE_BITS]),
			.req_tag(u_req_tag[C_SA*8 +: 8]),
			.rsp_valid(u_rsp_valid[C_SA]), .rsp_write(u_rsp_write[C_SA]), .rsp_tag(u_rsp_tag[C_SA*8 +: 8]),
			.rsp_rdata(u_rsp_rdata[C_SA*LINE_BITS +: LINE_BITS]), .rsp_error(u_rsp_error[C_SA])
		);
	end else begin : g_no_sa
		assign sa_busy = 1'b0;
		assign sa_hcr_rdata = 32'd0;
		assign sa_push_ready = 1'b0;
		assign sa_pop_valid = 1'b0;
		assign sa_pop_data = {DW{1'b0}};
		assign sa_qstat = 32'd0;
		assign sa_stat = 32'd0;
		assign sa_qtag = 32'd0;
		wire unused_sa = &{1'b0, sa_push_valid, sa_push_data, sa_pop_ready, sa_ctl_valid,
			sa_ctl_data};
	end

	wire dc_urgent, dc_panic;

	if (HAS_DISP != 0) begin : g_dc
		/*
		 * The display controller: board reset only (CTRL.RESET does not
		 * reset it).  The host reaches its registers only through the CP's
		 * DISP2 window (atg_cp_disp, HCR 0x200), which also flips its planes
		 * and takes its events.
		 */
		atg_dc #(
			.ADDR_W(MC_ADDR_W),
			.HAS_I2C(DC_HAS_I2C), .HAS_CURSOR(DC_HAS_CURSOR), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
			.FIFO_LOG2(DC_FIFO_LOG2), .PX_FMT(DC_PX_FMT), .TEST_MODE(DC_TEST_MODE)
		) dc (
			.clk(clk), .rst_n(rst_n), .pclk(pclk), .prst_n(prst_n),
			.d_we(dc_d_we), .d_idx(dc_d_idx), .d_wdata(dc_d_wdata), .d_wmask(dc_d_wmask),
			.d_ridx(dc_d_ridx), .d_rdata(dc_d_rdata),
			.flip_valid(dc_flip_valid), .flip_plane(dc_flip_plane), .flip_base(dc_flip_base),
			.taken(dc_taken), .taken_cancel(dc_taken_cancel), .pending(dc_pending),
			.dc_err(dc_err), .idle(dc_idle), .frame_count(dc_frame_count),
			.ev_vblank(dc_vsync), .ev_error(dc_ev_error), .ev_hotplug(dc_ev_hotplug),
			.irq_display(dc_irq_display),
			.pclk_sel(pclk_sel),
			.dc_urgent(dc_urgent), .dc_panic(dc_panic),
			.req_valid(c_req_valid[C_DC]), .req_ready(c_req_ready[C_DC]),
			.req_write(c_req_write[C_DC]), .req_line(c_req_line[C_DC*LA_W +: LA_W]),
			.req_be(c_req_be[C_DC*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(c_req_wdata[C_DC*LINE_BITS +: LINE_BITS]),
			.req_tag(c_req_tag[C_DC*8 +: 8]),
			.rsp_valid(rsp_valid[C_DC]), .rsp_write(rsp_write_v[C_DC]),
			.rsp_tag(rsp_tag_v[C_DC*8 +: 8]),
			.rsp_rdata(rsp_rdata_v[C_DC*LINE_BITS +: LINE_BITS]),
			.rsp_error(rsp_error_v[C_DC]),
			.tmds(tmds), .px_rgb(px_rgb), .px_de(px_de), .px_hs(px_hs), .px_vs(px_vs),
			.scl_t(scl_t), .scl_i(scl_i), .sda_t(sda_t), .sda_i(sda_i)
		);
	end else begin : g_no_dc
		assign dc_urgent = 1'b0;
		assign dc_panic = 1'b0;
		assign dc_vsync = 1'b0;
		assign dc_ev_error = 1'b0;
		assign dc_ev_hotplug = 1'b0;
		assign dc_irq_display = 1'b0;
		assign dc_idle = 1'b1;
		assign dc_d_rdata = 32'd0;
		assign dc_frame_count = 32'd0;
		assign dc_taken = 2'b00;
		assign dc_taken_cancel = 2'b00;
		assign dc_pending = 2'b00;
		assign pclk_sel = 1'b0;
		assign tmds = 30'd0;
		assign px_rgb = 24'd0;
		assign px_de = 1'b0;
		assign px_hs = 1'b0;
		assign px_vs = 1'b0;
		assign scl_t = 1'b1;
		assign sda_t = 1'b1;
		wire unused_no_dc = &{1'b0, pclk, prst_n, scl_i, sda_i, dc_d_we, dc_d_idx, dc_d_ridx,
			dc_d_wdata, dc_d_wmask, dc_flip_valid, dc_flip_plane, dc_flip_base, dc_err};
	end

	if (HAS_DISP == 0 && EXT_CLIENT != 0) begin : g_ext
		assign c_req_valid[C_EXT] = x_req_valid;
		assign x_req_ready = c_req_ready[C_EXT];
		assign c_req_write[C_EXT] = x_req_write;
		wire [63:0] ext_req_line64 = {{(64-(32-LINE_SHIFT)){1'b0}}, x_req_line};
		assign c_req_line[C_EXT*LA_W +: LA_W] = ext_req_line64[LA_W-1:0];
		assign c_req_be[C_EXT*LINE_BYTES +: LINE_BYTES] = x_req_be;
		assign c_req_wdata[C_EXT*LINE_BITS +: LINE_BITS] = x_req_wdata;
		assign c_req_tag[C_EXT*8 +: 8] = x_req_tag;
		assign x_rsp_valid = rsp_valid[C_EXT];
		assign x_rsp_write = rsp_write_v[C_EXT];
		assign x_rsp_tag = rsp_tag_v[C_EXT*8 +: 8];
		assign x_rsp_rdata = rsp_rdata_v[C_EXT*LINE_BITS +: LINE_BITS];
		assign x_rsp_error = rsp_error_v[C_EXT];
	end else begin : g_no_ext
		assign x_req_ready = 1'b0;
		assign x_rsp_valid = 1'b0;
		assign x_rsp_write = 1'b0;
		assign x_rsp_tag = 8'd0;
		assign x_rsp_rdata = {LINE_BITS{1'b0}};
		assign x_rsp_error = 1'b0;
		wire unused_ext = &{1'b0, x_req_valid, x_req_write, x_req_line, x_req_be, x_req_wdata,
			x_req_tag, HAS_DISP != 0 ? x_vsync : 1'b0};
	end
	endgenerate


	/* The SUs, Spine PT/warp/tex/export interconnect, and MC atomics. */
	localparam SU_HAS_GFX = (HAS_VF != 0) || (HAS_RX != 0) || (HAS_ROP != 0);
	localparam SU_SHARED_PT = (NSU > 1 && SU_HAS_GFX != 0) ? 1 : 0;
	localparam SU_PT_W = 1 + 3 + SU_GRP_W + 7 + SU_NPHYS + DW;
	localparam NSU_V = (NSU > 0) ? NSU : 1;
	localparam SU_PT_ENTRIES = (NSU >= 8) ? 256 : ((NSU >= 4) ? 128 : 64);

	/* Packed per-SU fabric vectors */
	wire [NSU_V-1:0] su_vl_req_v, su_vl_gnt_v, su_vl_avail_v, su_vl_we_v, su_vl_go_v;
	wire [NSU_V*8-1:0] su_vl_ptbase_v, su_vl_go_ptbase_v;
	wire [NSU_V*6-1:0] su_vl_reg_v;
	wire [NSU_V*5-1:0] su_vl_lane_v;
	wire [NSU_V*32-1:0] su_vl_data_v, su_vl_mask_v;

	wire [NSU_V-1:0] su_fl_req_v, su_fl_gnt_v, su_fl_avail_v, su_fl_we_v, su_fl_pw_we_v, su_fl_go_v;
	wire [NSU_V*6-1:0] su_fl_reg_v;
	wire [NSU_V*5-1:0] su_fl_lane_v;
	wire [NSU_V*32-1:0] su_fl_data_v, su_fl_pw_data_v, su_fl_mask_v;
	wire [NSU_V*12-1:0] su_fl_pw_addr_v;
	wire [NSU_V*64-1:0] su_fl_info_v;

	wire [NSU_V-1:0] su_pt_rd_v, su_pt_free_v;
	wire [NSU_V*8-1:0] su_pt_idx_v, su_pt_free_idx_v, su_pt_done_v;
	wire [NSU_V*7-1:0] su_pt_word_v;
	wire [NSU_V*32-1:0] su_pt_rdata_v;

	wire [NSU_V-1:0] su_pt_exp_valid_v, su_pt_exp_ready_v;
	wire [NSU_V*SU_PT_W-1:0] su_pt_exp_data_v;

	wire [NSU_V-1:0] su_tx_valid_v, su_tx_ready_v, su_tx_vs_v, su_tx_last_v;
	wire [NSU_V*8-1:0] su_tx_op_v;
	wire [NSU_V*4-1:0] su_tx_slot_v, su_tx_samp_slot_v, su_tx_mask_v;
	wire [NSU_V*640-1:0] su_tx_coord_v;
	wire [NSU_V*12-1:0] su_tx_off_v;
	wire [NSU_V*16-1:0] su_tx_tag_v;
	wire [NSU_V-1:0] su_tr_valid_v, su_tr_ready_v, su_tr_last_v;
	wire [NSU_V*16-1:0] su_tr_tag_v;
	wire [NSU_V*512-1:0] su_tr_data_v;

	wire [NSU_V-1:0] su_ex_valid_v, su_ex_ready_v, su_ex_has_src1_v, su_ex_last_v;
	wire [NSU_V*16-1:0] su_ex_seq_v, su_ex_next_v;
	wire [NSU_V*32-1:0] su_ex_xy_v;
	wire [NSU_V*4-1:0] su_ex_mask_v;
	wire [NSU_V*512-1:0] su_ex_color_v, su_ex_color1_v;
	wire [NSU_V*128-1:0] su_ex_depth_v;
	wire [NSU_V*155-1:0] su_ex_aux_v;

	genvar k, gs, gg, gl;
	generate
	for (k = 0; k < NSU; k = k + 1) begin : g_su
		localparam CD = C_SU + 2 * k;
		localparam CI = C_SU + 2 * k + 1;
		wire s_vl_gnt, s_fl_gnt, s_vl_avail, s_fl_avail;
		wire s_tx_valid, s_tx_last, s_tr_ready, s_ex_valid, s_ex_last;
		wire s_pt_exp_valid, s_pt_exp_end;
		wire [2:0] s_pt_exp_blk;
		wire [SU_GRP_W-1:0] s_pt_exp_grp;
		wire [6:0] s_pt_exp_word;
		wire [SU_NPHYS-1:0] s_pt_exp_mask;
		wire [DW-1:0] s_pt_exp_data;
		wire s_mesh_valid, s_mesh_last;
		wire [701:0] s_mesh_tri;
		wire [15:0] s_mesh_id;
		wire s_sa_push_valid, s_sa_pop_ready, s_sa_ctl_valid;
		wire [SU_WARP_W-1:0] s_vl_slot, s_fl_slot;
		wire [7:0] s_vl_ptbase, s_pt_done;
		wire [31:0] s_pt_rdata, s_ex_xy, s_sa_ctl_data;
		wire [7:0] s_tx_op;
		wire [3:0] s_tx_slot, s_tx_samp_slot, s_tx_mask, s_ex_mask;
		wire s_tx_vs;
		wire [639:0] s_tx_coord;
		wire [11:0] s_tx_off;
		wire [15:0] s_tx_tag, s_ex_seq;
		wire [511:0] s_ex_color, s_ex_color1;
		wire s_ex_has_src1;
		wire [127:0] s_ex_depth;
		wire [154:0] s_ex_aux;
		wire [DW-1:0] s_sa_push_data;
		wire g0 = k == 0;

		atg_su #(
			.NPHYS(SU_NPHYS), .NWARPS(SU_NWARPS), .WARP_W(SU_WARP_W), .GRP_W(SU_GRP_W),
			.NREGS(SU_NREGS), .SB_ENTRIES(SU_SB_ENTRIES), .SBE_W(SU_SBE_W), .NSU(NSU),
			.SU_INDEX(k), .FRAG_RESERVE(SU_FRAG_RESERVE), .PACKED(SU_PACKED),
			.PK_SHARED(SU_PK_SHARED), .SUBGROUP(SU_SUBGROUP), .HAS_SA(0), .MS4(MS4),
			.HAS_MESH(HAS_MESH),
			.LDS_BYTES(SU_LDS_BYTES), .PT_ENTRIES(SU_PT_ENTRIES), .VARY_WORDS(SU_VARY_WORDS),
			.ADDR_W(UNIT_ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
			.MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(ROP_DUAL_SOURCE),
			.SHARED_PT(SU_SHARED_PT), .HAS_GFX(SU_HAS_GFX ? 1 : 0), .HAS_TU(HAS_TU != 0 ? 1 : 0)
		) su (
			.clk(clk), .rst_n(core_rst_n), .st_we(ust_we), .st_idx(ust_idx), .st_wdata(st_wdata),
			.cs_kick(cs_kick), .cs_mesh(cs_mesh), .lc_kick(lc_kick), .inv(inv),
			.vl_req(su_vl_req_v[k]), .vl_gnt(s_vl_gnt), .vl_slot(s_vl_slot),
			.vl_ptbase(s_vl_ptbase), .vl_avail(s_vl_avail),
			.vl_we(su_vl_we_v[k]), .vl_reg(su_vl_reg_v[k*6 +: 6]),
			.vl_lane(su_vl_lane_v[k*5 +: 5]), .vl_data(su_vl_data_v[k*32 +: 32]),
			.vl_go(su_vl_go_v[k]), .vl_mask(su_vl_mask_v[k*32 +: 32]),
			.vl_go_ptbase(su_vl_go_ptbase_v[k*8 +: 8]),
			.fl_req(su_fl_req_v[k]), .fl_gnt(s_fl_gnt), .fl_slot(s_fl_slot),
			.fl_avail(s_fl_avail),
			.fl_we(su_fl_we_v[k]), .fl_reg(su_fl_reg_v[k*6 +: 6]),
			.fl_lane(su_fl_lane_v[k*5 +: 5]), .fl_data(su_fl_data_v[k*32 +: 32]),
			.fl_pw_we(su_fl_pw_we_v[k]), .fl_pw_addr(su_fl_pw_addr_v[k*12 +: 12]),
			.fl_pw_data(su_fl_pw_data_v[k*32 +: 32]),
			.fl_go(su_fl_go_v[k]), .fl_mask(su_fl_mask_v[k*32 +: 32]),
			.fl_info(su_fl_info_v[k*64 +: 64]),
			.pt_rd(su_pt_rd_v[k]), .pt_idx(su_pt_idx_v[k*8 +: 8]),
			.pt_word(su_pt_word_v[k*7 +: 7]), .pt_rdata(s_pt_rdata),
			.pt_free(su_pt_free_v[k]), .pt_free_idx(su_pt_free_idx_v[k*8 +: 8]),
			.pt_done(s_pt_done),
			.pt_exp_valid(s_pt_exp_valid), .pt_exp_ready(su_pt_exp_ready_v[k]),
			.pt_exp_end(s_pt_exp_end), .pt_exp_blk(s_pt_exp_blk),
			.pt_exp_grp(s_pt_exp_grp), .pt_exp_word(s_pt_exp_word),
			.pt_exp_mask(s_pt_exp_mask), .pt_exp_data(s_pt_exp_data),
			.tx_valid(s_tx_valid), .tx_ready(su_tx_ready_v[k]), .tx_op(s_tx_op),
			.tx_slot(s_tx_slot), .tx_samp_slot(s_tx_samp_slot), .tx_vs(s_tx_vs),
			.tx_mask(s_tx_mask), .tx_coord(s_tx_coord), .tx_off(s_tx_off),
			.tx_tag(s_tx_tag), .tx_last(s_tx_last),
			.tr_valid(su_tr_valid_v[k]), .tr_ready(s_tr_ready),
			.tr_tag(su_tr_tag_v[k*16 +: 16]), .tr_data(su_tr_data_v[k*512 +: 512]),
			.tr_last(su_tr_last_v[k]),
			.ex_valid(s_ex_valid), .ex_ready(su_ex_ready_v[k]),
			.ex_seq(s_ex_seq), .ex_xy(s_ex_xy),
			.ex_mask(s_ex_mask), .ex_color(s_ex_color), .ex_color1(s_ex_color1),
			.ex_has_src1(s_ex_has_src1), .ex_depth(s_ex_depth),
			.ex_last(s_ex_last), .ex_next(su_ex_next_v[k*16 +: 16]), .ex_aux(s_ex_aux),
			.mesh_valid(s_mesh_valid), .mesh_ready(g0 ? su_mesh_ready : 1'b1), .mesh_tri(s_mesh_tri),
			.mesh_last(s_mesh_last), .mesh_id(s_mesh_id),
			.d_req_valid(u_req_valid[CD]), .d_req_ready(u_req_ready[CD]),
			.d_req_write(u_req_write[CD]), .d_req_line(u_req_line[CD*UNIT_LA_W +: UNIT_LA_W]),
			.d_req_be(u_req_be[CD*LINE_BYTES +: LINE_BYTES]),
			.d_req_wdata(u_req_wdata[CD*LINE_BITS +: LINE_BITS]),
			.d_req_tag(u_req_tag[CD*8 +: 8]),
			.d_rsp_valid(u_rsp_valid[CD]), .d_rsp_write(u_rsp_write[CD]), .d_rsp_tag(u_rsp_tag[CD*8 +: 8]),
			.d_rsp_rdata(u_rsp_rdata[CD*LINE_BITS +: LINE_BITS]), .d_rsp_error(u_rsp_error[CD]),
			.i_req_valid(u_req_valid[CI]), .i_req_ready(u_req_ready[CI]),
			.i_req_write(u_req_write[CI]), .i_req_line(u_req_line[CI*UNIT_LA_W +: UNIT_LA_W]),
			.i_req_be(u_req_be[CI*LINE_BYTES +: LINE_BYTES]),
			.i_req_wdata(u_req_wdata[CI*LINE_BITS +: LINE_BITS]),
			.i_req_tag(u_req_tag[CI*8 +: 8]),
			.i_rsp_valid(u_rsp_valid[CI]), .i_rsp_write(u_rsp_write[CI]), .i_rsp_tag(u_rsp_tag[CI*8 +: 8]),
			.i_rsp_rdata(u_rsp_rdata[CI*LINE_BITS +: LINE_BITS]), .i_rsp_error(u_rsp_error[CI]),
			.at_valid(at_valid[k]), .at_stage(su_at_stage[k*2 +: 2]), .at_ready(at_ready[k]), .at_op(at_op[k*4 +: 4]),
			.at_addr(at_addr[k*30 +: 30]), .at_a(at_a[k*32 +: 32]), .at_b(at_b[k*32 +: 32]),
			.at_rsp_valid(at_rsp_valid[k]), .at_old(at_old), .at_error(at_error),
			.sa_push_valid(s_sa_push_valid), .sa_push_ready(g0 && sa_push_ready),
			.sa_push_data(s_sa_push_data), .sa_pop_valid(g0 && sa_pop_valid),
			.sa_pop_ready(s_sa_pop_ready), .sa_pop_data(sa_pop_data),
			.sa_ctl_valid(s_sa_ctl_valid), .sa_ctl_data(s_sa_ctl_data),
			.sa_qstat(sa_qstat), .sa_stat(sa_stat), .sa_qtag(sa_qtag),
			.busy(su_busy_v[k]), .fault(su_fault_v[k]),
			.scrub(prot_scrub), .scrub_busy(su_scrub_v[k]),
			.fault_addr(su_fault_addr_v[k*32 +: 32]),
			.fault_stage(su_fault_stage_v[k*4 +: 4]),
			.fsm(su_fsm_v[k*4 +: 4])
		);

		assign su_vl_gnt_v[k] = s_vl_gnt;
		assign su_vl_ptbase_v[k*8 +: 8] = s_vl_ptbase;
		assign su_vl_avail_v[k] = s_vl_avail;
		assign su_fl_gnt_v[k] = s_fl_gnt;
		assign su_fl_avail_v[k] = s_fl_avail;
		assign su_pt_rdata_v[k*32 +: 32] = s_pt_rdata;
		assign su_pt_done_v[k*8 +: 8] = s_pt_done;
		assign su_pt_exp_valid_v[k] = s_pt_exp_valid;
		assign su_pt_exp_data_v[k*SU_PT_W +: SU_PT_W] = {
			s_pt_exp_end, s_pt_exp_blk, s_pt_exp_grp, s_pt_exp_word, s_pt_exp_mask, s_pt_exp_data
		};
		assign su_tx_valid_v[k] = s_tx_valid;
		assign su_tx_op_v[k*8 +: 8] = s_tx_op;
		assign su_tx_slot_v[k*4 +: 4] = s_tx_slot;
		assign su_tx_samp_slot_v[k*4 +: 4] = s_tx_samp_slot;
		assign su_tx_vs_v[k] = s_tx_vs;
		assign su_tx_mask_v[k*4 +: 4] = s_tx_mask;
		assign su_tx_coord_v[k*640 +: 640] = s_tx_coord;
		assign su_tx_off_v[k*12 +: 12] = s_tx_off;
		assign su_tx_tag_v[k*16 +: 16] = s_tx_tag;
		assign su_tx_last_v[k] = s_tx_last;
		assign su_tr_ready_v[k] = s_tr_ready;
		assign su_ex_valid_v[k] = s_ex_valid;
		assign su_ex_seq_v[k*16 +: 16] = s_ex_seq;
		assign su_ex_xy_v[k*32 +: 32] = s_ex_xy;
		assign su_ex_mask_v[k*4 +: 4] = s_ex_mask;
		assign su_ex_color_v[k*512 +: 512] = s_ex_color;
		assign su_ex_color1_v[k*512 +: 512] = s_ex_color1;
		assign su_ex_has_src1_v[k] = s_ex_has_src1;
		assign su_ex_depth_v[k*128 +: 128] = s_ex_depth;
		assign su_ex_last_v[k] = s_ex_last;
		assign su_ex_aux_v[k*155 +: 155] = s_ex_aux;

		if (k == 0) begin : g_su0
			assign sa_push_valid = s_sa_push_valid;
			assign sa_push_data = s_sa_push_data;
			assign sa_pop_ready = s_sa_pop_ready;
			assign sa_ctl_valid = s_sa_ctl_valid;
			assign sa_ctl_data = s_sa_ctl_data;
			assign su_mesh_valid = s_mesh_valid;
			assign su_mesh_tri = s_mesh_tri;
			assign su_mesh_last = s_mesh_last;
			assign su_mesh_id = s_mesh_id;
		end else begin : g_sun
			wire unused_sun = &{1'b0, s_sa_push_valid, s_sa_push_data, s_sa_pop_ready,
				s_sa_ctl_valid, s_sa_ctl_data, s_mesh_valid, s_mesh_last, s_mesh_tri, s_mesh_id};
		end
		wire unused_slots = &{1'b0, s_vl_slot, s_fl_slot};
	end

	if (NSU == 1) begin : g_su_spine_1
		assign spine_pt_scrub_busy = 1'b0;
		assign su_vl_req_v[0] = vl_req;
		assign vl_gnt = su_vl_gnt_v[0];
		assign vl_ptbase = su_vl_ptbase_v[7:0];
		assign su_vl_we_v[0] = vl_we;
		assign su_vl_reg_v[5:0] = vl_reg;
		assign su_vl_lane_v[4:0] = vl_lane;
		assign su_vl_data_v[31:0] = vl_data;
		assign su_vl_go_v[0] = vl_go;
		assign su_vl_mask_v[31:0] = vl_mask;
		assign su_vl_go_ptbase_v[7:0] = 8'd0;

		assign su_fl_req_v[0] = fl_req;
		assign fl_gnt = su_fl_gnt_v[0];
		assign su_fl_we_v[0] = fl_we;
		assign su_fl_reg_v[5:0] = fl_reg;
		assign su_fl_lane_v[4:0] = fl_lane;
		assign su_fl_data_v[31:0] = fl_data;
		assign su_fl_pw_we_v[0] = fl_pw_we;
		assign su_fl_pw_addr_v[11:0] = fl_pw_addr;
		assign su_fl_pw_data_v[31:0] = fl_pw_data;
		assign su_fl_go_v[0] = fl_go;
		assign su_fl_mask_v[31:0] = fl_mask;
		assign su_fl_info_v[63:0] = fl_info;

		assign su_pt_rd_v[0] = pt_rd;
		assign su_pt_idx_v[7:0] = pt_idx;
		assign su_pt_word_v[6:0] = pt_word;
		assign pt_rdata = su_pt_rdata_v[31:0];
		assign su_pt_free_v[0] = pt_free;
		assign su_pt_free_idx_v[7:0] = pt_free_idx;
		assign pt_done = su_pt_done_v[7:0];
		assign su_pt_exp_ready_v[0] = 1'b1;

		assign tx_valid = su_tx_valid_v[0];
		assign su_tx_ready_v[0] = tx_ready;
		assign tx_op = su_tx_op_v[7:0];
		assign tx_slot = su_tx_slot_v[3:0];
		assign tx_samp_slot = su_tx_samp_slot_v[3:0];
		assign tx_vs = su_tx_vs_v[0];
		assign tx_mask = su_tx_mask_v[3:0];
		assign tx_coord = su_tx_coord_v[639:0];
		assign tx_off = su_tx_off_v[11:0];
		assign tx_tag = su_tx_tag_v[15:0];
		assign tx_last = su_tx_last_v[0];
		assign su_tr_valid_v[0] = tr_valid;
		assign tr_ready = su_tr_ready_v[0];
		assign su_tr_tag_v[15:0] = tr_tag;
		assign su_tr_data_v[511:0] = tr_data;
		assign su_tr_last_v[0] = tr_last;

		assign ex_valid = su_ex_valid_v[0];
		assign su_ex_ready_v[0] = ex_ready;
		assign ex_seq = su_ex_seq_v[15:0];
		assign ex_xy = su_ex_xy_v[31:0];
		assign ex_mask = su_ex_mask_v[3:0];
		assign ex_color = su_ex_color_v[511:0];
		assign ex_color1 = su_ex_color1_v[511:0];
		assign ex_has_src1 = su_ex_has_src1_v[0];
		assign ex_depth = su_ex_depth_v[127:0];
		assign ex_last = su_ex_last_v[0];
		assign su_ex_next_v[15:0] = ex_next;
		assign ex_aux = su_ex_aux_v[154:0];
		wire unused_s1 = &{1'b0, su_vl_avail_v, su_fl_avail_v, su_pt_exp_valid_v, su_pt_exp_data_v};
	end else if (NSU > 1) begin : g_su_spine_n
		/* Temporary Phase 3 K<=4 tree (up to 16 SUs); replaced by atg_su_fabric_n1..n128 in Phase 4 */
		localparam NG = (NSU > 4) ? ((NSU + 3) / 4) : 1;
		assign su_pt_rd_v = {NSU_V{1'b0}};
		assign su_pt_idx_v = {(NSU_V*8){1'b0}};
		assign su_pt_word_v = {(NSU_V*7){1'b0}};
		assign su_pt_free_v = {NSU_V{1'b0}};
		assign su_pt_free_idx_v = {(NSU_V*8){1'b0}};

		if (SU_HAS_GFX != 0) begin : g_sp_gfx
			wire spine_pt_ok;
			wire [7:0] spine_pt_base;
			wire sp_pt_exp_valid, sp_pt_exp_ready;
			wire [SU_PT_W-1:0] sp_pt_exp_data;
			wire sp_pt_exp_end;
			wire [2:0] sp_pt_exp_blk;
			wire [SU_GRP_W-1:0] sp_pt_exp_grp;
			wire [6:0] sp_pt_exp_word;
			wire [SU_NPHYS-1:0] sp_pt_exp_mask;
			wire [DW-1:0] sp_pt_exp_wdata;
			assign {sp_pt_exp_end, sp_pt_exp_blk, sp_pt_exp_grp, sp_pt_exp_word, sp_pt_exp_mask, sp_pt_exp_wdata} = sp_pt_exp_data;

			wire dist_vl_gnt, dist_vl_avail, dist_fl_avail;
			reg spine_vl_wait;
			reg [7:0] vl_ptbase_hold;
			always @(posedge clk or negedge core_rst_n) begin
				if (!core_rst_n) begin
					spine_vl_wait <= 1'b0;
					vl_ptbase_hold <= 8'd0;
				end else begin
					if (dist_vl_gnt) begin
						spine_vl_wait <= 1'b1;
						vl_ptbase_hold <= spine_pt_base;
					end else if (vl_go) begin
						spine_vl_wait <= 1'b0;
					end
				end
			end

			assign vl_gnt = dist_vl_gnt;
			assign vl_ptbase = spine_pt_base;
			wire dist_vl_req = vl_req && spine_pt_ok && !spine_vl_wait;

			atg_su_pt #(
				.NPHYS(SU_NPHYS), .NWARPS(SU_NWARPS), .WARP_W(SU_WARP_W), .GRP_W(SU_GRP_W),
				.UOP_W(108), .PT_ENTRIES(SU_PT_ENTRIES), .VARY_WORDS(SU_VARY_WORDS), .SHARED_PT(1)
			) spine_pt (
				.clk(clk), .rst_n(core_rst_n),
				.x_valid(1'b0), .x_warp({SU_WARP_W{1'b0}}), .x_grp({SU_GRP_W{1'b0}}),
				.x_uop(108'd0), .x_b({DW{1'b0}}), .x_mask({(2*SU_NPHYS){1'b0}}), .x_info(32'd0),
				.pt_exp_valid(sp_pt_exp_valid), .pt_exp_ready(sp_pt_exp_ready),
				.pt_exp_end(sp_pt_exp_end), .pt_exp_blk(sp_pt_exp_blk),
				.pt_exp_grp(sp_pt_exp_grp), .pt_exp_word(sp_pt_exp_word),
				.pt_exp_mask(sp_pt_exp_mask), .pt_exp_data(sp_pt_exp_wdata),
				.pt_rd(pt_rd), .pt_idx(pt_idx), .pt_word(pt_word), .pt_rdata(pt_rdata),
				.pt_free(pt_free), .pt_free_idx(pt_free_idx),
				.pt_ok(spine_pt_ok), .pt_take(dist_vl_gnt), .pt_warp({SU_WARP_W{1'b0}}),
				.pt_base(spine_pt_base), .vl_go(vl_go), .vl_mask(vl_mask), .pt_done(pt_done),
				.wc_end(1'b0), .wc_warp({SU_WARP_W{1'b0}}),
				.scrub(prot_scrub), .scrub_busy(spine_pt_scrub_busy)
			);

			if (NG == 1) begin : g_gfx_l1
				wire [5:0] l1_vl_reg, l1_fl_reg;
				wire [4:0] l1_vl_lane, l1_fl_lane;
				wire [31:0] l1_vl_data, l1_vl_mask, l1_fl_data, l1_fl_pw_data, l1_fl_mask;
				wire [7:0] l1_vl_go_ptbase;
				wire [11:0] l1_fl_pw_addr;
				wire [63:0] l1_fl_info;

				atg_warp_dist #(.K(NSU)) u_wdist (
					.clk(clk), .rst_n(core_rst_n),
					.p_vl_req(dist_vl_req), .p_vl_gnt(dist_vl_gnt), .p_vl_ptbase(), .p_vl_avail(dist_vl_avail),
					.p_vl_we(vl_we), .p_vl_reg(vl_reg), .p_vl_lane(vl_lane), .p_vl_data(vl_data),
					.p_vl_go(vl_go), .p_vl_mask(vl_mask), .p_vl_go_ptbase(vl_ptbase_hold),
					.c_vl_req(su_vl_req_v), .c_vl_gnt(su_vl_gnt_v), .c_vl_ptbase(su_vl_ptbase_v), .c_vl_avail(su_vl_avail_v),
					.c_vl_we(su_vl_we_v), .c_vl_reg(l1_vl_reg), .c_vl_lane(l1_vl_lane),
					.c_vl_data(l1_vl_data), .c_vl_go(su_vl_go_v), .c_vl_mask(l1_vl_mask),
					.c_vl_go_ptbase(l1_vl_go_ptbase),
					.p_fl_req(fl_req), .p_fl_gnt(fl_gnt), .p_fl_avail(dist_fl_avail),
					.p_fl_we(fl_we), .p_fl_reg(fl_reg), .p_fl_lane(fl_lane), .p_fl_data(fl_data),
					.p_fl_pw_we(fl_pw_we), .p_fl_pw_addr(fl_pw_addr), .p_fl_pw_data(fl_pw_data),
					.p_fl_go(fl_go), .p_fl_mask(fl_mask), .p_fl_info(fl_info),
					.c_fl_req(su_fl_req_v), .c_fl_gnt(su_fl_gnt_v), .c_fl_avail(su_fl_avail_v),
					.c_fl_we(su_fl_we_v), .c_fl_reg(l1_fl_reg), .c_fl_lane(l1_fl_lane),
					.c_fl_data(l1_fl_data), .c_fl_pw_we(su_fl_pw_we_v),
					.c_fl_pw_addr(l1_fl_pw_addr), .c_fl_pw_data(l1_fl_pw_data),
					.c_fl_go(su_fl_go_v), .c_fl_mask(l1_fl_mask), .c_fl_info(l1_fl_info)
				);
				for (gs = 0; gs < NSU; gs = gs + 1) begin : g_wd_shr
					assign su_vl_reg_v[gs*6 +: 6] = l1_vl_reg;
					assign su_vl_lane_v[gs*5 +: 5] = l1_vl_lane;
					assign su_vl_data_v[gs*32 +: 32] = l1_vl_data;
					assign su_vl_mask_v[gs*32 +: 32] = l1_vl_mask;
					assign su_vl_go_ptbase_v[gs*8 +: 8] = l1_vl_go_ptbase;
					assign su_fl_reg_v[gs*6 +: 6] = l1_fl_reg;
					assign su_fl_lane_v[gs*5 +: 5] = l1_fl_lane;
					assign su_fl_data_v[gs*32 +: 32] = l1_fl_data;
					assign su_fl_pw_addr_v[gs*12 +: 12] = l1_fl_pw_addr;
					assign su_fl_pw_data_v[gs*32 +: 32] = l1_fl_pw_data;
					assign su_fl_mask_v[gs*32 +: 32] = l1_fl_mask;
					assign su_fl_info_v[gs*64 +: 64] = l1_fl_info;
				end
				atg_pt_exp_rt #(.K(NSU), .W(SU_PT_W)) u_ptrt (
					.clk(clk), .rst_n(core_rst_n),
					.c_valid(su_pt_exp_valid_v), .c_ready(su_pt_exp_ready_v), .c_data(su_pt_exp_data_v),
					.p_valid(sp_pt_exp_valid), .p_ready(sp_pt_exp_ready), .p_data(sp_pt_exp_data)
				);
			end else begin : g_gfx_l2
				wire [NG-1:0] w_vl_req, w_vl_gnt, w_vl_avail, w_vl_we, w_vl_go;
				wire [NG*8-1:0] w_vl_ptbase;
				wire [5:0] w_vl_reg; wire [4:0] w_vl_lane;
				wire [31:0] w_vl_data, w_vl_mask; wire [7:0] w_vl_go_ptbase;
				wire [NG-1:0] w_fl_req, w_fl_gnt, w_fl_avail, w_fl_we, w_fl_pw_we, w_fl_go;
				wire [5:0] w_fl_reg; wire [4:0] w_fl_lane;
				wire [31:0] w_fl_data, w_fl_pw_data, w_fl_mask; wire [11:0] w_fl_pw_addr; wire [63:0] w_fl_info;
				wire [NG-1:0] w_pt_v, w_pt_r;
				wire [NG*SU_PT_W-1:0] w_pt_d;

				atg_warp_dist #(.K(NG)) u_wdist_root (
					.clk(clk), .rst_n(core_rst_n),
					.p_vl_req(dist_vl_req), .p_vl_gnt(dist_vl_gnt), .p_vl_ptbase(), .p_vl_avail(dist_vl_avail),
					.p_vl_we(vl_we), .p_vl_reg(vl_reg), .p_vl_lane(vl_lane), .p_vl_data(vl_data),
					.p_vl_go(vl_go), .p_vl_mask(vl_mask), .p_vl_go_ptbase(vl_ptbase_hold),
					.c_vl_req(w_vl_req), .c_vl_gnt(w_vl_gnt), .c_vl_ptbase(w_vl_ptbase), .c_vl_avail(w_vl_avail),
					.c_vl_we(w_vl_we), .c_vl_reg(w_vl_reg), .c_vl_lane(w_vl_lane),
					.c_vl_data(w_vl_data), .c_vl_go(w_vl_go), .c_vl_mask(w_vl_mask), .c_vl_go_ptbase(w_vl_go_ptbase),
					.p_fl_req(fl_req), .p_fl_gnt(fl_gnt), .p_fl_avail(dist_fl_avail),
					.p_fl_we(fl_we), .p_fl_reg(fl_reg), .p_fl_lane(fl_lane), .p_fl_data(fl_data),
					.p_fl_pw_we(fl_pw_we), .p_fl_pw_addr(fl_pw_addr), .p_fl_pw_data(fl_pw_data),
					.p_fl_go(fl_go), .p_fl_mask(fl_mask), .p_fl_info(fl_info),
					.c_fl_req(w_fl_req), .c_fl_gnt(w_fl_gnt), .c_fl_avail(w_fl_avail),
					.c_fl_we(w_fl_we), .c_fl_reg(w_fl_reg), .c_fl_lane(w_fl_lane),
					.c_fl_data(w_fl_data), .c_fl_pw_we(w_fl_pw_we),
					.c_fl_pw_addr(w_fl_pw_addr), .c_fl_pw_data(w_fl_pw_data),
					.c_fl_go(w_fl_go), .c_fl_mask(w_fl_mask), .c_fl_info(w_fl_info)
				);
				atg_pt_exp_rt #(.K(NG), .W(SU_PT_W)) u_ptrt_root (
					.clk(clk), .rst_n(core_rst_n),
					.c_valid(w_pt_v), .c_ready(w_pt_r), .c_data(w_pt_d),
					.p_valid(sp_pt_exp_valid), .p_ready(sp_pt_exp_ready), .p_data(sp_pt_exp_data)
				);
				for (gg = 0; gg < NG; gg = gg + 1) begin : g_l2_grp
					localparam GB = gg * 4;
					localparam GS = (GB + 4 <= NSU) ? 4 : (NSU - GB);
					if (GS == 1) begin : g_gs1
						assign su_vl_req_v[GB] = w_vl_req[gg];
						assign w_vl_gnt[gg] = su_vl_gnt_v[GB];
						assign w_vl_ptbase[gg*8 +: 8] = su_vl_ptbase_v[GB*8 +: 8];
						assign w_vl_avail[gg] = su_vl_avail_v[GB];
						assign su_vl_we_v[GB] = w_vl_we[gg];
						assign su_vl_reg_v[GB*6 +: 6] = w_vl_reg;
						assign su_vl_lane_v[GB*5 +: 5] = w_vl_lane;
						assign su_vl_data_v[GB*32 +: 32] = w_vl_data;
						assign su_vl_go_v[GB] = w_vl_go[gg];
						assign su_vl_mask_v[GB*32 +: 32] = w_vl_mask;
						assign su_vl_go_ptbase_v[GB*8 +: 8] = w_vl_go_ptbase;
						assign su_fl_req_v[GB] = w_fl_req[gg];
						assign w_fl_gnt[gg] = su_fl_gnt_v[GB];
						assign w_fl_avail[gg] = su_fl_avail_v[GB];
						assign su_fl_we_v[GB] = w_fl_we[gg];
						assign su_fl_reg_v[GB*6 +: 6] = w_fl_reg;
						assign su_fl_lane_v[GB*5 +: 5] = w_fl_lane;
						assign su_fl_data_v[GB*32 +: 32] = w_fl_data;
						assign su_fl_pw_we_v[GB] = w_fl_pw_we[gg];
						assign su_fl_pw_addr_v[GB*12 +: 12] = w_fl_pw_addr;
						assign su_fl_pw_data_v[GB*32 +: 32] = w_fl_pw_data;
						assign su_fl_go_v[GB] = w_fl_go[gg];
						assign su_fl_mask_v[GB*32 +: 32] = w_fl_mask;
						assign su_fl_info_v[GB*64 +: 64] = w_fl_info;
						assign w_pt_v[gg] = su_pt_exp_valid_v[GB];
						assign su_pt_exp_ready_v[GB] = w_pt_r[gg];
						assign w_pt_d[gg*SU_PT_W +: SU_PT_W] = su_pt_exp_data_v[GB*SU_PT_W +: SU_PT_W];
					end else begin : g_gsn
						wire [5:0] g_vl_reg; wire [4:0] g_vl_lane;
						wire [31:0] g_vl_data, g_vl_mask; wire [7:0] g_vl_go_ptbase;
						wire [5:0] g_fl_reg; wire [4:0] g_fl_lane;
						wire [31:0] g_fl_data, g_fl_pw_data, g_fl_mask; wire [11:0] g_fl_pw_addr; wire [63:0] g_fl_info;
						atg_warp_dist #(.K(GS)) u_wdist_l2 (
							.clk(clk), .rst_n(core_rst_n),
							.p_vl_req(w_vl_req[gg]), .p_vl_gnt(w_vl_gnt[gg]), .p_vl_ptbase(w_vl_ptbase[gg*8 +: 8]), .p_vl_avail(w_vl_avail[gg]),
							.p_vl_we(w_vl_we[gg]), .p_vl_reg(w_vl_reg), .p_vl_lane(w_vl_lane), .p_vl_data(w_vl_data),
							.p_vl_go(w_vl_go[gg]), .p_vl_mask(w_vl_mask), .p_vl_go_ptbase(w_vl_go_ptbase),
							.c_vl_req(su_vl_req_v[GB +: GS]), .c_vl_gnt(su_vl_gnt_v[GB +: GS]),
							.c_vl_ptbase(su_vl_ptbase_v[GB*8 +: GS*8]), .c_vl_avail(su_vl_avail_v[GB +: GS]),
							.c_vl_we(su_vl_we_v[GB +: GS]), .c_vl_reg(g_vl_reg), .c_vl_lane(g_vl_lane),
							.c_vl_data(g_vl_data), .c_vl_go(su_vl_go_v[GB +: GS]), .c_vl_mask(g_vl_mask), .c_vl_go_ptbase(g_vl_go_ptbase),
							.p_fl_req(w_fl_req[gg]), .p_fl_gnt(w_fl_gnt[gg]), .p_fl_avail(w_fl_avail[gg]),
							.p_fl_we(w_fl_we[gg]), .p_fl_reg(w_fl_reg), .p_fl_lane(w_fl_lane), .p_fl_data(w_fl_data),
							.p_fl_pw_we(w_fl_pw_we[gg]), .p_fl_pw_addr(w_fl_pw_addr), .p_fl_pw_data(w_fl_pw_data),
							.p_fl_go(w_fl_go[gg]), .p_fl_mask(w_fl_mask), .p_fl_info(w_fl_info),
							.c_fl_req(su_fl_req_v[GB +: GS]), .c_fl_gnt(su_fl_gnt_v[GB +: GS]),
							.c_fl_avail(su_fl_avail_v[GB +: GS]), .c_fl_we(su_fl_we_v[GB +: GS]),
							.c_fl_reg(g_fl_reg), .c_fl_lane(g_fl_lane), .c_fl_data(g_fl_data),
							.c_fl_pw_we(su_fl_pw_we_v[GB +: GS]), .c_fl_pw_addr(g_fl_pw_addr), .c_fl_pw_data(g_fl_pw_data),
							.c_fl_go(su_fl_go_v[GB +: GS]), .c_fl_mask(g_fl_mask), .c_fl_info(g_fl_info)
						);
						for (gl = 0; gl < GS; gl = gl + 1) begin : g_l2_shr
							assign su_vl_reg_v[(GB+gl)*6 +: 6] = g_vl_reg;
							assign su_vl_lane_v[(GB+gl)*5 +: 5] = g_vl_lane;
							assign su_vl_data_v[(GB+gl)*32 +: 32] = g_vl_data;
							assign su_vl_mask_v[(GB+gl)*32 +: 32] = g_vl_mask;
							assign su_vl_go_ptbase_v[(GB+gl)*8 +: 8] = g_vl_go_ptbase;
							assign su_fl_reg_v[(GB+gl)*6 +: 6] = g_fl_reg;
							assign su_fl_lane_v[(GB+gl)*5 +: 5] = g_fl_lane;
							assign su_fl_data_v[(GB+gl)*32 +: 32] = g_fl_data;
							assign su_fl_pw_addr_v[(GB+gl)*12 +: 12] = g_fl_pw_addr;
							assign su_fl_pw_data_v[(GB+gl)*32 +: 32] = g_fl_pw_data;
							assign su_fl_mask_v[(GB+gl)*32 +: 32] = g_fl_mask;
							assign su_fl_info_v[(GB+gl)*64 +: 64] = g_fl_info;
						end
						atg_pt_exp_rt #(.K(GS), .W(SU_PT_W)) u_ptrt_l2 (
							.clk(clk), .rst_n(core_rst_n),
							.c_valid(su_pt_exp_valid_v[GB +: GS]),
							.c_ready(su_pt_exp_ready_v[GB +: GS]),
							.c_data(su_pt_exp_data_v[GB*SU_PT_W +: GS*SU_PT_W]),
							.p_valid(w_pt_v[gg]), .p_ready(w_pt_r[gg]), .p_data(w_pt_d[gg*SU_PT_W +: SU_PT_W])
						);
					end
				end
			end
			wire unused_wd_av = &{1'b0, dist_vl_avail, dist_fl_avail};
		end else begin : g_sp_nogfx
			assign spine_pt_scrub_busy = 1'b0;
			assign vl_gnt = 1'b0;
			assign vl_ptbase = 8'd0;
			assign fl_gnt = 1'b0;
			assign pt_rdata = 32'd0;
			assign pt_done = 8'd0;
			assign su_vl_req_v = {NSU_V{1'b0}};
			assign su_vl_we_v = {NSU_V{1'b0}};
			assign su_vl_reg_v = {(NSU_V*6){1'b0}};
			assign su_vl_lane_v = {(NSU_V*5){1'b0}};
			assign su_vl_data_v = {(NSU_V*32){1'b0}};
			assign su_vl_go_v = {NSU_V{1'b0}};
			assign su_vl_mask_v = {(NSU_V*32){1'b0}};
			assign su_vl_go_ptbase_v = {(NSU_V*8){1'b0}};
			assign su_fl_req_v = {NSU_V{1'b0}};
			assign su_fl_we_v = {NSU_V{1'b0}};
			assign su_fl_reg_v = {(NSU_V*6){1'b0}};
			assign su_fl_lane_v = {(NSU_V*5){1'b0}};
			assign su_fl_data_v = {(NSU_V*32){1'b0}};
			assign su_fl_pw_we_v = {NSU_V{1'b0}};
			assign su_fl_pw_addr_v = {(NSU_V*12){1'b0}};
			assign su_fl_pw_data_v = {(NSU_V*32){1'b0}};
			assign su_fl_go_v = {NSU_V{1'b0}};
			assign su_fl_mask_v = {(NSU_V*32){1'b0}};
			assign su_fl_info_v = {(NSU_V*64){1'b0}};
			assign su_pt_exp_ready_v = {NSU_V{1'b1}};
			wire unused_sp_ng = &{1'b0, vl_req, vl_we, vl_reg, vl_lane, vl_data, vl_go, vl_mask,
				fl_req, fl_we, fl_reg, fl_lane, fl_data, fl_pw_we, fl_pw_addr, fl_pw_data,
				fl_go, fl_mask, fl_info, pt_rd, pt_idx, pt_word, pt_free, pt_free_idx,
				su_vl_gnt_v, su_vl_ptbase_v, su_vl_avail_v, su_fl_gnt_v, su_fl_avail_v,
				su_pt_exp_valid_v, su_pt_exp_data_v};
		end

		if (HAS_TU != 0) begin : g_sp_tu
			if (NG == 1) begin : g_tu_l1
				atg_tx_rt #(.K(NSU), .TBIT(14)) u_txrt (
					.clk(clk), .rst_n(core_rst_n),
					.c_tx_valid(su_tx_valid_v), .c_tx_ready(su_tx_ready_v),
					.c_tx_op(su_tx_op_v), .c_tx_slot(su_tx_slot_v), .c_tx_samp_slot(su_tx_samp_slot_v),
					.c_tx_vs(su_tx_vs_v), .c_tx_mask(su_tx_mask_v), .c_tx_coord(su_tx_coord_v),
					.c_tx_off(su_tx_off_v), .c_tx_tag(su_tx_tag_v), .c_tx_last(su_tx_last_v),
					.c_tr_valid(su_tr_valid_v), .c_tr_ready(su_tr_ready_v),
					.c_tr_tag(su_tr_tag_v), .c_tr_data(su_tr_data_v), .c_tr_last(su_tr_last_v),
					.p_tx_valid(tx_valid), .p_tx_ready(tx_ready),
					.p_tx_op(tx_op), .p_tx_slot(tx_slot), .p_tx_samp_slot(tx_samp_slot),
					.p_tx_vs(tx_vs), .p_tx_mask(tx_mask), .p_tx_coord(tx_coord),
					.p_tx_off(tx_off), .p_tx_tag(tx_tag), .p_tx_last(tx_last),
					.p_tr_valid(tr_valid), .p_tr_ready(tr_ready),
					.p_tr_tag(tr_tag), .p_tr_data(tr_data), .p_tr_last(tr_last)
				);
			end else begin : g_tu_l2
				wire [NG-1:0] w_tx_v, w_tx_r, w_tx_vs, w_tx_l;
				wire [NG*8-1:0] w_tx_op; wire [NG*4-1:0] w_tx_slot, w_tx_samp, w_tx_mask;
				wire [NG*640-1:0] w_tx_coord; wire [NG*12-1:0] w_tx_off; wire [NG*16-1:0] w_tx_tag;
				wire [NG-1:0] w_tr_v, w_tr_r, w_tr_l;
				wire [NG*16-1:0] w_tr_tag; wire [NG*512-1:0] w_tr_data;
				atg_tx_rt #(.K(NG), .TBIT(14)) u_txrt_root (
					.clk(clk), .rst_n(core_rst_n),
					.c_tx_valid(w_tx_v), .c_tx_ready(w_tx_r), .c_tx_op(w_tx_op), .c_tx_slot(w_tx_slot),
					.c_tx_samp_slot(w_tx_samp), .c_tx_vs(w_tx_vs), .c_tx_mask(w_tx_mask),
					.c_tx_coord(w_tx_coord), .c_tx_off(w_tx_off), .c_tx_tag(w_tx_tag), .c_tx_last(w_tx_l),
					.c_tr_valid(w_tr_v), .c_tr_ready(w_tr_r), .c_tr_tag(w_tr_tag),
					.c_tr_data(w_tr_data), .c_tr_last(w_tr_l),
					.p_tx_valid(tx_valid), .p_tx_ready(tx_ready), .p_tx_op(tx_op), .p_tx_slot(tx_slot),
					.p_tx_samp_slot(tx_samp_slot), .p_tx_vs(tx_vs), .p_tx_mask(tx_mask),
					.p_tx_coord(tx_coord), .p_tx_off(tx_off), .p_tx_tag(tx_tag), .p_tx_last(tx_last),
					.p_tr_valid(tr_valid), .p_tr_ready(tr_ready), .p_tr_tag(tr_tag),
					.p_tr_data(tr_data), .p_tr_last(tr_last)
				);
				for (gg = 0; gg < NG; gg = gg + 1) begin : g_tu_grp
					localparam GB = gg * 4;
					localparam GS = (GB + 4 <= NSU) ? 4 : (NSU - GB);
					if (GS == 1) begin : g_tgs1
						assign w_tx_v[gg] = su_tx_valid_v[GB];
						assign su_tx_ready_v[GB] = w_tx_r[gg];
						assign w_tx_op[gg*8 +: 8] = su_tx_op_v[GB*8 +: 8];
						assign w_tx_slot[gg*4 +: 4] = su_tx_slot_v[GB*4 +: 4];
						assign w_tx_samp[gg*4 +: 4] = su_tx_samp_slot_v[GB*4 +: 4];
						assign w_tx_vs[gg] = su_tx_vs_v[GB];
						assign w_tx_mask[gg*4 +: 4] = su_tx_mask_v[GB*4 +: 4];
						assign w_tx_coord[gg*640 +: 640] = su_tx_coord_v[GB*640 +: 640];
						assign w_tx_off[gg*12 +: 12] = su_tx_off_v[GB*12 +: 12];
						assign w_tx_tag[gg*16 +: 16] = su_tx_tag_v[GB*16 +: 16];
						assign w_tx_l[gg] = su_tx_last_v[GB];
						assign su_tr_valid_v[GB] = w_tr_v[gg];
						assign w_tr_r[gg] = su_tr_ready_v[GB];
						assign su_tr_tag_v[GB*16 +: 16] = w_tr_tag[gg*16 +: 16];
						assign su_tr_data_v[GB*512 +: 512] = w_tr_data[gg*512 +: 512];
						assign su_tr_last_v[GB] = w_tr_l[gg];
					end else begin : g_tgsn
						atg_tx_rt #(.K(GS), .TBIT(12)) u_txrt_l2 (
							.clk(clk), .rst_n(core_rst_n),
							.c_tx_valid(su_tx_valid_v[GB +: GS]), .c_tx_ready(su_tx_ready_v[GB +: GS]),
							.c_tx_op(su_tx_op_v[GB*8 +: GS*8]), .c_tx_slot(su_tx_slot_v[GB*4 +: GS*4]),
							.c_tx_samp_slot(su_tx_samp_slot_v[GB*4 +: GS*4]), .c_tx_vs(su_tx_vs_v[GB +: GS]),
							.c_tx_mask(su_tx_mask_v[GB*4 +: GS*4]), .c_tx_coord(su_tx_coord_v[GB*640 +: GS*640]),
							.c_tx_off(su_tx_off_v[GB*12 +: GS*12]), .c_tx_tag(su_tx_tag_v[GB*16 +: GS*16]),
							.c_tx_last(su_tx_last_v[GB +: GS]),
							.c_tr_valid(su_tr_valid_v[GB +: GS]), .c_tr_ready(su_tr_ready_v[GB +: GS]),
							.c_tr_tag(su_tr_tag_v[GB*16 +: GS*16]), .c_tr_data(su_tr_data_v[GB*512 +: GS*512]),
							.c_tr_last(su_tr_last_v[GB +: GS]),
							.p_tx_valid(w_tx_v[gg]), .p_tx_ready(w_tx_r[gg]), .p_tx_op(w_tx_op[gg*8 +: 8]),
							.p_tx_slot(w_tx_slot[gg*4 +: 4]), .p_tx_samp_slot(w_tx_samp[gg*4 +: 4]),
							.p_tx_vs(w_tx_vs[gg]), .p_tx_mask(w_tx_mask[gg*4 +: 4]),
							.p_tx_coord(w_tx_coord[gg*640 +: 640]), .p_tx_off(w_tx_off[gg*12 +: 12]),
							.p_tx_tag(w_tx_tag[gg*16 +: 16]), .p_tx_last(w_tx_l[gg]),
							.p_tr_valid(w_tr_v[gg]), .p_tr_ready(w_tr_r[gg]), .p_tr_tag(w_tr_tag[gg*16 +: 16]),
							.p_tr_data(w_tr_data[gg*512 +: 512]), .p_tr_last(w_tr_l[gg])
						);
					end
				end
			end
		end else begin : g_sp_notu
			assign tx_valid = 1'b0;
			assign tx_op = 8'd0;
			assign tx_slot = 4'd0;
			assign tx_samp_slot = 4'd0;
			assign tx_vs = 1'b0;
			assign tx_mask = 4'd0;
			assign tx_coord = 640'd0;
			assign tx_off = 12'd0;
			assign tx_tag = 16'd0;
			assign tx_last = 1'b0;
			assign tr_ready = 1'b1;
			assign su_tx_ready_v = {NSU_V{1'b0}};
			assign su_tr_valid_v = {NSU_V{1'b0}};
			assign su_tr_tag_v = {(NSU_V*16){1'b0}};
			assign su_tr_data_v = {(NSU_V*512){1'b0}};
			assign su_tr_last_v = {NSU_V{1'b0}};
			wire unused_sp_ntu = &{1'b0, tx_ready, tr_valid, tr_tag, tr_data, tr_last,
				su_tx_valid_v, su_tx_op_v, su_tx_slot_v, su_tx_samp_slot_v, su_tx_vs_v,
				su_tx_mask_v, su_tx_coord_v, su_tx_off_v, su_tx_tag_v, su_tx_last_v, su_tr_ready_v};
		end

		if (HAS_ROP != 0) begin : g_sp_rop
			if (NG == 1) begin : g_rop_l1
				wire [15:0] c_ex_next_w;
				atg_ex_rt #(.K(NSU)) u_exrt (
					.clk(clk), .rst_n(core_rst_n),
					.c_ex_valid(su_ex_valid_v), .c_ex_ready(su_ex_ready_v),
					.c_ex_seq(su_ex_seq_v), .c_ex_xy(su_ex_xy_v), .c_ex_mask(su_ex_mask_v),
					.c_ex_color(su_ex_color_v), .c_ex_color1(su_ex_color1_v),
					.c_ex_has_src1(su_ex_has_src1_v), .c_ex_depth(su_ex_depth_v),
					.c_ex_last(su_ex_last_v), .c_ex_aux(su_ex_aux_v), .c_ex_next(c_ex_next_w),
					.p_ex_valid(ex_valid), .p_ex_ready(ex_ready),
					.p_ex_seq(ex_seq), .p_ex_xy(ex_xy), .p_ex_mask(ex_mask),
					.p_ex_color(ex_color), .p_ex_color1(ex_color1),
					.p_ex_has_src1(ex_has_src1), .p_ex_depth(ex_depth),
					.p_ex_last(ex_last), .p_ex_aux(ex_aux), .p_ex_next(ex_next)
				);
				assign su_ex_next_v = {NSU_V{c_ex_next_w}};
			end else begin : g_rop_l2
				wire [NG-1:0] w_ex_v, w_ex_r, w_ex_hs1, w_ex_l;
				wire [NG*16-1:0] w_ex_seq; wire [NG*32-1:0] w_ex_xy; wire [NG*4-1:0] w_ex_mask;
				wire [NG*512-1:0] w_ex_col, w_ex_col1; wire [NG*128-1:0] w_ex_dep; wire [NG*155-1:0] w_ex_aux;
				wire [15:0] w_ex_next;
				atg_ex_rt #(.K(NG)) u_exrt_root (
					.clk(clk), .rst_n(core_rst_n),
					.c_ex_valid(w_ex_v), .c_ex_ready(w_ex_r), .c_ex_seq(w_ex_seq),
					.c_ex_xy(w_ex_xy), .c_ex_mask(w_ex_mask), .c_ex_color(w_ex_col),
					.c_ex_color1(w_ex_col1), .c_ex_has_src1(w_ex_hs1), .c_ex_depth(w_ex_dep),
					.c_ex_last(w_ex_l), .c_ex_aux(w_ex_aux), .c_ex_next(w_ex_next),
					.p_ex_valid(ex_valid), .p_ex_ready(ex_ready), .p_ex_seq(ex_seq),
					.p_ex_xy(ex_xy), .p_ex_mask(ex_mask), .p_ex_color(ex_color),
					.p_ex_color1(ex_color1), .p_ex_has_src1(ex_has_src1), .p_ex_depth(ex_depth),
					.p_ex_last(ex_last), .p_ex_aux(ex_aux), .p_ex_next(ex_next)
				);
				for (gg = 0; gg < NG; gg = gg + 1) begin : g_rop_grp
					localparam GB = gg * 4;
					localparam GS = (GB + 4 <= NSU) ? 4 : (NSU - GB);
					if (GS == 1) begin : g_egs1
						assign w_ex_v[gg] = su_ex_valid_v[GB];
						assign su_ex_ready_v[GB] = w_ex_r[gg];
						assign w_ex_seq[gg*16 +: 16] = su_ex_seq_v[GB*16 +: 16];
						assign w_ex_xy[gg*32 +: 32] = su_ex_xy_v[GB*32 +: 32];
						assign w_ex_mask[gg*4 +: 4] = su_ex_mask_v[GB*4 +: 4];
						assign w_ex_col[gg*512 +: 512] = su_ex_color_v[GB*512 +: 512];
						assign w_ex_col1[gg*512 +: 512] = su_ex_color1_v[GB*512 +: 512];
						assign w_ex_hs1[gg] = su_ex_has_src1_v[GB];
						assign w_ex_dep[gg*128 +: 128] = su_ex_depth_v[GB*128 +: 128];
						assign w_ex_l[gg] = su_ex_last_v[GB];
						assign w_ex_aux[gg*155 +: 155] = su_ex_aux_v[GB*155 +: 155];
						assign su_ex_next_v[GB*16 +: 16] = w_ex_next;
					end else begin : g_egsn
						wire [15:0] g_ex_next;
						atg_ex_rt #(.K(GS)) u_exrt_l2 (
							.clk(clk), .rst_n(core_rst_n),
							.c_ex_valid(su_ex_valid_v[GB +: GS]), .c_ex_ready(su_ex_ready_v[GB +: GS]),
							.c_ex_seq(su_ex_seq_v[GB*16 +: GS*16]), .c_ex_xy(su_ex_xy_v[GB*32 +: GS*32]),
							.c_ex_mask(su_ex_mask_v[GB*4 +: GS*4]), .c_ex_color(su_ex_color_v[GB*512 +: GS*512]),
							.c_ex_color1(su_ex_color1_v[GB*512 +: GS*512]), .c_ex_has_src1(su_ex_has_src1_v[GB +: GS]),
							.c_ex_depth(su_ex_depth_v[GB*128 +: GS*128]), .c_ex_last(su_ex_last_v[GB +: GS]),
							.c_ex_aux(su_ex_aux_v[GB*155 +: GS*155]), .c_ex_next(g_ex_next),
							.p_ex_valid(w_ex_v[gg]), .p_ex_ready(w_ex_r[gg]),
							.p_ex_seq(w_ex_seq[gg*16 +: 16]), .p_ex_xy(w_ex_xy[gg*32 +: 32]),
							.p_ex_mask(w_ex_mask[gg*4 +: 4]), .p_ex_color(w_ex_col[gg*512 +: 512]),
							.p_ex_color1(w_ex_col1[gg*512 +: 512]), .p_ex_has_src1(w_ex_hs1[gg]),
							.p_ex_depth(w_ex_dep[gg*128 +: 128]), .p_ex_last(w_ex_l[gg]),
							.p_ex_aux(w_ex_aux[gg*155 +: 155]), .p_ex_next(w_ex_next)
						);
						for (gl = 0; gl < GS; gl = gl + 1) begin : g_ex_shr
							assign su_ex_next_v[(GB+gl)*16 +: 16] = g_ex_next;
						end
					end
				end
			end
		end else begin : g_sp_norop
			assign ex_valid = 1'b0;
			assign ex_seq = 16'd0;
			assign ex_xy = 32'd0;
			assign ex_mask = 4'd0;
			assign ex_color = 512'd0;
			assign ex_color1 = 512'd0;
			assign ex_has_src1 = 1'b0;
			assign ex_depth = 128'd0;
			assign ex_last = 1'b0;
			assign ex_aux = 155'd0;
			assign su_ex_ready_v = {NSU_V{1'b0}};
			assign su_ex_next_v = {(NSU_V*16){1'b0}};
			wire unused_sp_nrp = &{1'b0, ex_ready, ex_next, su_ex_valid_v, su_ex_seq_v,
				su_ex_xy_v, su_ex_mask_v, su_ex_color_v, su_ex_color1_v,
				su_ex_has_src1_v, su_ex_depth_v, su_ex_last_v, su_ex_aux_v};
		end
	end

	if (NSU > 0) begin : g_atom
		/*
		 * The SUs' ISA fault: the OR, and FAULT_ADDR = the PC of the
		 * lowest-numbered SU that faults in that cycle (ghci §12.6).
		 */
		wire atom_busy;
		reg [31:0] fault_pc;
		reg [3:0] fault_stg;
		integer j;

		always @(*) begin
			fault_pc = 32'd0;
			fault_stg = 4'd0;
			for (j = NSU - 1; j >= 0; j = j - 1)
				if (su_fault_v[j]) begin
					fault_pc = su_fault_addr_v[j*32 +: 32];
					fault_stg = su_fault_stage_v[j*4 +: 4];
				end
		end
		assign su_busy = |su_busy_v || atom_busy;
		assign su_fault = |su_fault_v;
		assign su_fault_addr = fault_pc;
		assign su_fault_stage = fault_stg;

		atg_mc_atom #(
			.ADDR_W(UNIT_ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .NATOM(NSU),
			.AW(NSU > 1 ? $clog2(NSU) : 1)
		) atom (
			.clk(clk), .rst_n(core_rst_n),
			.at_valid(at_valid), .at_ready(at_ready), .at_op(at_op), .at_addr(at_addr),
			.at_a(at_a), .at_b(at_b), .at_stage(su_at_stage), .at_rsp_valid(at_rsp_valid), .at_old(at_old),
			.at_error(at_error), .busy(atom_busy),
			.req_valid(u_req_valid[C_ATOM]), .req_ready(u_req_ready[C_ATOM]),
			.req_write(u_req_write[C_ATOM]), .req_line(u_req_line[C_ATOM*UNIT_LA_W +: UNIT_LA_W]),
			.req_be(u_req_be[C_ATOM*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(u_req_wdata[C_ATOM*LINE_BITS +: LINE_BITS]),
			.req_tag(u_req_tag[C_ATOM*8 +: 8]),
			.rsp_valid(u_rsp_valid[C_ATOM]), .rsp_write(u_rsp_write[C_ATOM]), .rsp_tag(u_rsp_tag[C_ATOM*8 +: 8]),
			.rsp_rdata(u_rsp_rdata[C_ATOM*LINE_BITS +: LINE_BITS]), .rsp_error(u_rsp_error[C_ATOM])
		);
	end else begin : g_no_su
		assign spine_pt_scrub_busy = 1'b0;
		assign su_vl_req_v = 1'b0;
		assign su_vl_we_v = 1'b0;
		assign su_vl_reg_v = 6'd0;
		assign su_vl_lane_v = 5'd0;
		assign su_vl_data_v = 32'd0;
		assign su_vl_go_v = 1'b0;
		assign su_vl_mask_v = 32'd0;
		assign su_vl_go_ptbase_v = 8'd0;
		assign su_fl_req_v = 1'b0;
		assign su_fl_we_v = 1'b0;
		assign su_fl_reg_v = 6'd0;
		assign su_fl_lane_v = 5'd0;
		assign su_fl_data_v = 32'd0;
		assign su_fl_pw_we_v = 1'b0;
		assign su_fl_pw_addr_v = 12'd0;
		assign su_fl_pw_data_v = 32'd0;
		assign su_fl_go_v = 1'b0;
		assign su_fl_mask_v = 32'd0;
		assign su_fl_info_v = 64'd0;
		assign su_pt_rd_v = 1'b0;
		assign su_pt_idx_v = 8'd0;
		assign su_pt_word_v = 7'd0;
		assign su_pt_free_v = 1'b0;
		assign su_pt_free_idx_v = 8'd0;
		assign su_pt_exp_ready_v = 1'b0;
		assign su_tx_ready_v = 1'b0;
		assign su_tr_valid_v = 1'b0;
		assign su_tr_tag_v = 16'd0;
		assign su_tr_data_v = 512'd0;
		assign su_tr_last_v = 1'b0;
		assign su_ex_ready_v = 1'b0;
		assign su_ex_next_v = 16'd0;
		assign su_at_stage = 2'd0;
		assign su_busy = 1'b0;
		assign su_fault = 1'b0;
		assign su_fault_addr = 32'd0;
		assign su_fault_stage = 4'd0;
		assign vl_gnt = 1'b0;
		assign vl_ptbase = 8'd0;
		assign fl_gnt = 1'b0;
		assign pt_rdata = 32'd0;
		assign pt_done = 8'd0;
		assign tx_valid = 1'b0;
		assign tx_op = 8'd0;
		assign tx_slot = 4'd0;
		assign tx_samp_slot = 4'd0;
		assign tx_vs = 1'b0;
		assign tx_mask = 4'd0;
		assign tx_coord = 640'd0;
		assign tx_off = 12'd0;
		assign tx_tag = 16'd0;
		assign tx_last = 1'b0;
		assign tr_ready = 1'b0;
		assign ex_valid = 1'b0;
		assign ex_seq = 16'd0;
		assign ex_xy = 32'd0;
		assign ex_mask = 4'd0;
		assign ex_color = 512'd0;
		assign ex_color1 = 512'd0;
		assign ex_has_src1 = 1'b0;
		assign ex_depth = 128'd0;
		assign ex_last = 1'b0;
		assign ex_aux = 155'd0;
		assign sa_push_valid = 1'b0;
		assign sa_push_data = {DW{1'b0}};
		assign sa_pop_ready = 1'b0;
		assign sa_ctl_valid = 1'b0;
		assign sa_ctl_data = 32'd0;
		assign at_valid = 1'b0;
		assign at_op = 4'd0;
		assign at_addr = 30'd0;
		assign at_a = 32'd0;
		assign at_b = 32'd0;
		assign at_ready = 1'b0;
		assign at_rsp_valid = 1'b0;
		assign at_old = 32'd0;
		assign at_error = 1'b0;
		assign su_busy_v = 1'b0;
		assign su_fault_v = 1'b0;
		assign su_scrub_v = 1'b0;
		assign su_fault_addr_v = 32'd0;
		assign su_fsm_v = 4'd0;
		assign su_mesh_valid = 1'b0;
		assign su_mesh_tri = 702'd0;
		assign su_mesh_last = 1'b0;
		assign su_mesh_id = 16'd0;
		assign su_vl_gnt_v = 1'b0;
		assign su_vl_ptbase_v = 8'd0;
		assign su_vl_avail_v = 1'b0;
		assign su_fl_gnt_v = 1'b0;
		assign su_fl_avail_v = 1'b0;
		assign su_pt_rdata_v = 32'd0;
		assign su_pt_done_v = 8'd0;
		assign su_pt_exp_valid_v = 1'b0;
		assign su_pt_exp_data_v = {SU_PT_W{1'b0}};
		assign su_tx_valid_v = 1'b0;
		assign su_tx_op_v = 8'd0;
		assign su_tx_slot_v = 4'd0;
		assign su_tx_samp_slot_v = 4'd0;
		assign su_tx_vs_v = 1'b0;
		assign su_tx_mask_v = 4'd0;
		assign su_tx_coord_v = 640'd0;
		assign su_tx_off_v = 12'd0;
		assign su_tx_tag_v = 16'd0;
		assign su_tx_last_v = 1'b0;
		assign su_tr_ready_v = 1'b0;
		assign su_ex_valid_v = 1'b0;
		assign su_ex_seq_v = 16'd0;
		assign su_ex_xy_v = 32'd0;
		assign su_ex_mask_v = 4'd0;
		assign su_ex_color_v = 512'd0;
		assign su_ex_color1_v = 512'd0;
		assign su_ex_has_src1_v = 1'b0;
		assign su_ex_depth_v = 128'd0;
		assign su_ex_last_v = 1'b0;
		assign su_ex_aux_v = 155'd0;
		wire unused_su = &{1'b0, cs_kick, lc_kick, inv, vl_req, vl_we, vl_reg, vl_lane, vl_data,
			vl_go, vl_mask, fl_req, fl_we, fl_reg, fl_lane, fl_data, fl_pw_we, fl_pw_addr,
			fl_pw_data, fl_go, fl_mask, fl_info, pt_rd, pt_idx, pt_word, pt_free, pt_free_idx,
			tx_ready, tr_valid, tr_tag, tr_data, tr_last, ex_ready, ex_next, sa_push_ready,
			sa_pop_valid, sa_pop_data, sa_qstat, sa_stat, sa_qtag, at_ready, at_rsp_valid,
			at_old, at_error, su_busy_v, su_fault_v, su_fault_addr_v, at_valid, at_op, at_addr,
			at_a, at_b, su_mesh_ready, su_vl_req_v, su_vl_gnt_v, su_vl_ptbase_v, su_vl_avail_v,
			su_vl_we_v, su_vl_reg_v, su_vl_lane_v, su_vl_data_v, su_vl_go_v, su_vl_mask_v,
			su_vl_go_ptbase_v, su_fl_req_v, su_fl_gnt_v, su_fl_avail_v, su_fl_we_v, su_fl_reg_v,
			su_fl_lane_v, su_fl_data_v, su_fl_pw_we_v, su_fl_pw_addr_v, su_fl_pw_data_v,
			su_fl_go_v, su_fl_mask_v, su_fl_info_v, su_pt_rd_v, su_pt_idx_v, su_pt_word_v,
			su_pt_rdata_v, su_pt_free_v, su_pt_free_idx_v, su_pt_done_v, su_pt_exp_valid_v,
			su_pt_exp_ready_v, su_pt_exp_data_v, su_tx_valid_v, su_tx_ready_v, su_tx_op_v,
			su_tx_slot_v, su_tx_samp_slot_v, su_tx_vs_v, su_tx_mask_v, su_tx_coord_v, su_tx_off_v,
			su_tx_tag_v, su_tx_last_v, su_tr_valid_v, su_tr_ready_v, su_tr_tag_v, su_tr_data_v,
			su_tr_last_v, su_ex_valid_v, su_ex_ready_v, su_ex_seq_v, su_ex_xy_v, su_ex_mask_v,
			su_ex_color_v, su_ex_color1_v, su_ex_has_src1_v, su_ex_depth_v, su_ex_last_v,
			su_ex_next_v, su_ex_aux_v};
	end
	endgenerate

	/* Hardware MMU + per-unit am_mmu_bridge (HAS_HW_WALKER=1) or flat bypass */
	wire [3:0] active_mmu_session = (PROT && prot_unit != 6'd0) ? prot_unit_tag[3:0] : cp_active_session;
	wire [MMU_NCLIENTS-1:0] mmu_req_valid;
	wire [MMU_NCLIENTS*4-1:0] mmu_req_session;
	wire [MMU_NCLIENTS*VA_BITS-1:0] mmu_req_va;
	wire [MMU_NCLIENTS*2-1:0] mmu_req_type;
	wire [MMU_NCLIENTS-1:0] mmu_ack;
	wire [MMU_NCLIENTS*PA_BITS-1:0] mmu_pa;
	wire [MMU_NCLIENTS*6-1:0] mmu_flags;
	wire [MMU_NCLIENTS-1:0] mmu_fault;
	wire [MMU_NCLIENTS*8-1:0] mmu_brg_inflight;
	wire [MMU_NCLIENTS-1:0] mmu_brg_busy;
	wire [MMU_NCLIENTS-1:0] mmu_perm_fv;
	wire [MMU_NCLIENTS*4-1:0] mmu_perm_fs;
	wire [MMU_NCLIENTS*VA_BITS-1:0] mmu_perm_fa;
	wire [MMU_NCLIENTS*8-1:0] mmu_client_mc_map;

	genvar gi;
	generate
	for (gi = 0; gi < NCLIENT; gi = gi + 1) begin : g_mmu_port
		localparam IS_UNIT_CLIENT = (gi == 1 && HAS_BLT != 0) ||
		                            (HAS_VF != 0 && gi == C_VF) ||
		                            (HAS_TU != 0 && gi == C_TU) ||
		                            (HAS_ROP != 0 && gi == C_ROP) ||
		                            (HAS_ATOM != 0 && gi == C_ATOM) ||
		                            (HAS_SA != 0 && gi == C_SA) ||
		                            (gi >= C_SU);
		localparam GI_MMU_IDX = (gi == 1 && HAS_BLT != 0) ? MMU_BLT :
		                        (HAS_VF != 0 && gi == C_VF) ? MMU_VF :
		                        (HAS_TU != 0 && gi == C_TU) ? MMU_TU :
		                        (HAS_ROP != 0 && gi == C_ROP) ? MMU_ROP :
		                        (HAS_ATOM != 0 && gi == C_ATOM) ? MMU_ATOM :
		                        (HAS_SA != 0 && gi == C_SA) ? MMU_SA :
		                        (gi >= C_SU) ? (MMU_SU + (gi - C_SU)) : 0;
		localparam GI_EXEC = (gi >= C_SU) && (((gi - C_SU) & 1) != 0);

		if (IS_UNIT_CLIENT) begin : g_u
			if (HAS_HW_WALKER != 0) begin : g_brg
				wire [7:0] brg_if_cnt;
				assign mmu_brg_inflight[GI_MMU_IDX*8 +: 8] = brg_if_cnt;
				assign mmu_brg_busy[GI_MMU_IDX] = (|brg_if_cnt) || u_req_valid[gi];
				assign mmu_client_mc_map[GI_MMU_IDX*8 +: 8] = gi[7:0];
				am_mmu_bridge #(
					.UNIT_ADDR_W(UNIT_ADDR_W),
					.MC_ADDR_W(MC_ADDR_W),
					.VA_BITS(VA_BITS),
					.PA_BITS(PA_BITS),
					.LINE_BYTES(LINE_BYTES),
					.LINE_SHIFT(LINE_SHIFT),
					.CHECK_PERM(1)
				) u_brg (
					.clk(clk),
					.rst_n(core_rst_n),
					.u_req_valid(u_req_valid[gi]),
					.u_req_ready(u_req_ready[gi]),
					.u_req_write(u_req_write[gi]),
					.u_req_exec(GI_EXEC ? 1'b1 : 1'b0),
					.u_req_line(u_req_line[gi*UNIT_LA_W +: UNIT_LA_W]),
					.u_req_be(u_req_be[gi*LINE_BYTES +: LINE_BYTES]),
					.u_req_wdata(u_req_wdata[gi*LINE_BITS +: LINE_BITS]),
					.u_req_tag(u_req_tag[gi*8 +: 8]),
					.u_req_session(active_mmu_session),
					.u_req_chk(u_req_chk[gi]),
					.u_req_tbl(u_req_tbl[gi]),
					.u_req_slot(u_req_slot[gi*6 +: 6]),
					.u_rsp_valid(u_rsp_valid[gi]),
					.u_rsp_write(u_rsp_write[gi]),
					.u_rsp_tag(u_rsp_tag[gi*8 +: 8]),
					.u_rsp_rdata(u_rsp_rdata[gi*LINE_BITS +: LINE_BITS]),
					.u_rsp_error(u_rsp_error[gi]),
					.mmu_req_valid(mmu_req_valid[GI_MMU_IDX]),
					.mmu_req_session(mmu_req_session[GI_MMU_IDX*4 +: 4]),
					.mmu_req_va(mmu_req_va[GI_MMU_IDX*VA_BITS +: VA_BITS]),
					.mmu_req_type(mmu_req_type[GI_MMU_IDX*2 +: 2]),
					.mmu_ack(mmu_ack[GI_MMU_IDX]),
					.mmu_pa(mmu_pa[GI_MMU_IDX*PA_BITS +: PA_BITS]),
					.mmu_flags(mmu_flags[GI_MMU_IDX*6 +: 6]),
					.mmu_fault(mmu_fault[GI_MMU_IDX]),
					.m_req_valid(c_req_valid[gi]),
					.m_req_ready(c_req_ready[gi]),
					.m_req_write(c_req_write[gi]),
					.m_req_line(c_req_line[gi*LA_W +: LA_W]),
					.m_req_be(c_req_be[gi*LINE_BYTES +: LINE_BYTES]),
					.m_req_wdata(c_req_wdata[gi*LINE_BITS +: LINE_BITS]),
					.m_req_tag(c_req_tag[gi*8 +: 8]),
					.m_req_chk(c_req_chk[gi]),
					.m_req_tbl(c_req_tbl[gi]),
					.m_req_slot(c_req_slot[gi*6 +: 6]),
					.m_req_session(c_req_session[gi*4 +: 4]),
					.m_req_exec_type(c_req_exec_type[gi*2 +: 2]),
					.m_rsp_valid(rsp_valid[gi]),
					.m_rsp_write(rsp_write_v[gi]),
					.m_rsp_tag(rsp_tag_v[gi*8 +: 8]),
					.m_rsp_rdata(rsp_rdata_v[gi*LINE_BITS +: LINE_BITS]),
					.m_rsp_error(rsp_error_v[gi]),
					.perm_fault_valid(mmu_perm_fv[GI_MMU_IDX]),
					.perm_fault_session(mmu_perm_fs[GI_MMU_IDX*4 +: 4]),
					.perm_fault_addr(mmu_perm_fa[GI_MMU_IDX*VA_BITS +: VA_BITS]),
					.inflight_cnt(brg_if_cnt)
				);
			end else begin : g_bypass
				wire [63:0] u_line64 = {{(64-UNIT_LA_W){1'b0}}, u_req_line[gi*UNIT_LA_W +: UNIT_LA_W]};
				assign c_req_valid[gi] = u_req_valid[gi];
				assign u_req_ready[gi] = c_req_ready[gi];
				assign c_req_write[gi] = u_req_write[gi];
				assign c_req_line[gi*LA_W +: LA_W] = u_line64[LA_W-1:0];
				assign c_req_be[gi*LINE_BYTES +: LINE_BYTES] = u_req_be[gi*LINE_BYTES +: LINE_BYTES];
				assign c_req_wdata[gi*LINE_BITS +: LINE_BITS] = u_req_wdata[gi*LINE_BITS +: LINE_BITS];
				assign c_req_tag[gi*8 +: 8] = u_req_tag[gi*8 +: 8];
				assign c_req_chk[gi] = u_req_chk[gi];
				assign c_req_tbl[gi] = u_req_tbl[gi];
				assign c_req_slot[gi*6 +: 6] = u_req_slot[gi*6 +: 6];
				assign c_req_session[gi*4 +: 4] = active_mmu_session;
				assign c_req_exec_type[gi*2 +: 2] = GI_EXEC ? 2'b10 : (u_req_write[gi] ? 2'b01 : 2'b00);
				assign u_rsp_valid[gi] = rsp_valid[gi];
				assign u_rsp_write[gi] = rsp_write_v[gi];
				assign u_rsp_tag[gi*8 +: 8] = rsp_tag_v[gi*8 +: 8];
				assign u_rsp_rdata[gi*LINE_BITS +: LINE_BITS] = rsp_rdata_v[gi*LINE_BITS +: LINE_BITS];
				assign u_rsp_error[gi] = rsp_error_v[gi];
			end
		end else begin : g_phys_unused
			assign u_req_ready[gi] = 1'b0;
			assign u_rsp_valid[gi] = 1'b0;
			assign u_rsp_write[gi] = 1'b0;
			assign u_rsp_tag[gi*8 +: 8] = 8'd0;
			assign u_rsp_rdata[gi*LINE_BITS +: LINE_BITS] = {LINE_BITS{1'b0}};
			assign u_rsp_error[gi] = 1'b0;
			if (gi != 1) begin : g_phys_zero
				assign u_req_valid[gi] = 1'b0;
				assign u_req_write[gi] = 1'b0;
				assign u_req_line[gi*UNIT_LA_W +: UNIT_LA_W] = {UNIT_LA_W{1'b0}};
				assign u_req_be[gi*LINE_BYTES +: LINE_BYTES] = {LINE_BYTES{1'b0}};
				assign u_req_wdata[gi*LINE_BITS +: LINE_BITS] = {LINE_BITS{1'b0}};
				assign u_req_tag[gi*8 +: 8] = 8'd0;
				wire unused_phys_u = &{1'b0, u_req_chk[gi], u_req_tbl[gi], u_req_slot[gi*6 +: 6]};
			end else begin : g_no_blt_sink
				assign c_req_valid[1] = u_req_valid[1];
				assign c_req_write[1] = u_req_write[1];
				assign c_req_line[1*LA_W +: LA_W] = {LA_W{1'b0}};
				assign c_req_be[1*LINE_BYTES +: LINE_BYTES] = u_req_be[1*LINE_BYTES +: LINE_BYTES];
				assign c_req_wdata[1*LINE_BITS +: LINE_BITS] = u_req_wdata[1*LINE_BITS +: LINE_BITS];
				assign c_req_tag[1*8 +: 8] = u_req_tag[1*8 +: 8];
				assign c_req_chk[1] = 1'b0;
				assign c_req_tbl[1] = 1'b0;
				assign c_req_slot[1*6 +: 6] = 6'd0;
				assign c_req_session[1*4 +: 4] = 4'd0;
				assign c_req_exec_type[1*2 +: 2] = 2'd0;
				wire unused_no_blt = &{1'b0, u_req_line[1*UNIT_LA_W +: UNIT_LA_W],
					u_req_chk[1], u_req_tbl[1], u_req_slot[1*6 +: 6]};
			end
		end
	end

	if (HAS_HW_WALKER != 0) begin : g_mmu
		wire mmu_cp_pt_we, mmu_cp_fl_trig, mmu_cp_fl_all;
		wire [3:0] mmu_cp_pt_sess, mmu_cp_fl_sess;
		wire [PA_BITS-13:0] mmu_cp_pt_base;
		wire mmu_f_valid;
		wire [3:0] mmu_f_kind, mmu_f_sess;
		wire [MMU_FC_W-1:0] mmu_f_client;
		wire [VA_BITS-1:0] mmu_f_addr;

		if (MMU_NCLIENTS_RAW == 0) begin : g_mmu_empty_client
			assign mmu_req_valid = 1'b0;
			assign mmu_req_session = 4'd0;
			assign mmu_req_va = {VA_BITS{1'b0}};
			assign mmu_req_type = 2'd0;
			assign mmu_brg_inflight = 8'd0;
			assign mmu_brg_busy = 1'b0;
			assign mmu_perm_fv = 1'b0;
			assign mmu_perm_fs = 4'd0;
			assign mmu_perm_fa = {VA_BITS{1'b0}};
			assign mmu_client_mc_map = 8'd0;
		end

		assign any_brg_inflight = |mmu_brg_busy;

		atg_cp_mmu #(
			.VA_BITS(VA_BITS),
			.PA_BITS(PA_BITS),
			.NUM_CLIENTS(MMU_NCLIENTS),
			.FC_W(MMU_FC_W),
			.USE_MAP_PORT(1)
		) u_cp_mmu (
			.clk(clk),
			.rst_n(core_rst_n),
			.sb_we(sb_we),
			.sb_re(sb_re),
			.sb_idx(sb_idx),
			.sb_wdata(sb_wdata),
			.sb_rdata(mmu_sb_rdata),
			.boot_caps(32'd0),
			.device_caps(32'd0),
			.cp_pt_root_we(mmu_cp_pt_we),
			.cp_pt_root_session(mmu_cp_pt_sess),
			.cp_pt_root_base(mmu_cp_pt_base),
			.cp_flush_trigger(mmu_cp_fl_trig),
			.cp_flush_all(mmu_cp_fl_all),
			.cp_flush_session(mmu_cp_fl_sess),
			.bridge_inflight(mmu_brg_inflight),
			.client_mc_map(mmu_client_mc_map),
			.mmu_fault_valid(mmu_f_valid),
			.mmu_fault_kind(mmu_f_kind),
			.mmu_fault_session(mmu_f_sess),
			.mmu_fault_client(mmu_f_client),
			.mmu_fault_addr(mmu_f_addr),
			.brg_fault_valid(mmu_perm_fv),
			.brg_fault_session(mmu_perm_fs),
			.brg_fault_addr(mmu_perm_fa),
			.ctl_fault_valid(ctl_mmu_fault),
			.ctl_fault_kind(ctl_mmu_fault_kind),
			.ctl_fault_session(ctl_mmu_fault_session),
			.ctl_fault_mc_client(ctl_mmu_fault_client),
			.ctl_fault_addr(ctl_mmu_fault_addr),
			.hcr_ridx(hcr_ridx),
			.hcr_rdata(mmu_hcr_rdata),
			.fault_session_clear(cp_fault_session_clear),
			.fault_session_tag(cp_fault_session_tag)
		);

		atg_mmu #(
			.NUM_CLIENTS(MMU_NCLIENTS),
			.MAX_SESSIONS(16),
			.VA_BITS(VA_BITS),
			.PA_BITS(PA_BITS),
			.FC_W(MMU_FC_W)
		) u_mmu (
			.clk(clk),
			.rst_n(core_rst_n),
			.client_req_valid(mmu_req_valid),
			.client_req_session(mmu_req_session),
			.client_req_va(mmu_req_va),
			.client_req_type(mmu_req_type),
			.client_ack(mmu_ack),
			.client_pa(mmu_pa),
			.client_flags(mmu_flags),
			.client_fault(mmu_fault),
			.mem_req_fire(1'b0),
			.mem_rsp_fire(1'b0),
			.inflight_count(),
			.cp_pt_root_we(mmu_cp_pt_we),
			.cp_pt_root_session(mmu_cp_pt_sess),
			.cp_pt_root_base(mmu_cp_pt_base),
			.cp_flush_trigger(mmu_cp_fl_trig),
			.cp_flush_all(mmu_cp_fl_all),
			.cp_flush_session(mmu_cp_fl_sess),
			.fault_valid(mmu_f_valid),
			.fault_kind(mmu_f_kind),
			.fault_session(mmu_f_sess),
			.fault_client(mmu_f_client),
			.fault_addr(mmu_f_addr),
			.walker_mem_req_valid(mmu_walk_req_valid),
			.walker_mem_req_addr(mmu_walk_req_addr),
			.walker_mem_req_ready(mmu_walk_req_ready),
			.walker_mem_rsp_valid(mmu_walk_rsp_valid),
			.walker_mem_rsp_data(mmu_walk_rsp_data)
		);
	end else begin : g_no_mmu
		assign any_brg_inflight = 1'b0;
		assign mmu_sb_rdata = 32'd0;
		assign mmu_hcr_rdata = 32'd0;
		assign ctl_mmu_fault = 1'b0;
		assign ctl_mmu_fault_kind = 4'd0;
		assign ctl_mmu_fault_session = 4'd0;
		assign ctl_mmu_fault_client = 8'd0;
		assign ctl_mmu_fault_addr = {VA_BITS{1'b0}};
		assign mmu_walk_req_valid = 1'b0;
		assign mmu_walk_req_addr = {PA_BITS{1'b0}};
		assign mmu_req_valid = {MMU_NCLIENTS{1'b0}};
		assign mmu_req_session = {MMU_NCLIENTS*4{1'b0}};
		assign mmu_req_va = {MMU_NCLIENTS*VA_BITS{1'b0}};
		assign mmu_req_type = {MMU_NCLIENTS*2{1'b0}};
		assign mmu_ack = {MMU_NCLIENTS{1'b0}};
		assign mmu_pa = {MMU_NCLIENTS*PA_BITS{1'b0}};
		assign mmu_flags = {MMU_NCLIENTS*6{1'b0}};
		assign mmu_fault = {MMU_NCLIENTS{1'b0}};
		assign mmu_brg_inflight = {MMU_NCLIENTS*8{1'b0}};
		assign mmu_brg_busy = {MMU_NCLIENTS{1'b0}};
		assign mmu_perm_fv = {MMU_NCLIENTS{1'b0}};
		assign mmu_perm_fs = {MMU_NCLIENTS*4{1'b0}};
		assign mmu_perm_fa = {MMU_NCLIENTS*VA_BITS{1'b0}};
		assign mmu_client_mc_map = {MMU_NCLIENTS*8{1'b0}};
		wire unused_no_mmu = &{1'b0, active_mmu_session, mmu_walk_req_ready, mmu_walk_rsp_valid,
			mmu_walk_rsp_data, mmu_req_valid, mmu_req_session, mmu_req_va, mmu_req_type,
			mmu_ack, mmu_pa, mmu_flags, mmu_fault, mmu_brg_inflight, mmu_brg_busy,
			mmu_perm_fv, mmu_perm_fs, mmu_perm_fa, mmu_client_mc_map};
	end
	endgenerate

	wire unused_ok = &{1'b0, blt_done, mmu_walk_rsp_error};
endmodule

`default_nettype wire
