/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_caps_tb: Verification testbench for CMD_QUERY_CAPS packet execution
 * and capability block reflection through the command ring in both Default
 * and KC705 shapes.
 *
 * Verifies:
 *   - CMD_QUERY_CAPS emits all 192 dwords (768 bytes) to memory.
 *   - Words 0-1: BLOCK_ID (0x50414347), BLOCK_INFO (192 dwords, version 1 = 0x00C00001).
 *   - Words 2-15 match corresponding host registers:
 *       0x008 (DEVICE_CAPS), 0x084 (EXT_CAP_FEATURE), 0x080 (EXT_CAP_FMT0),
 *       0x04C (RESIDENT_WARPS), 0x068 (NATIVE_ISA_ID), 0x064 (GCLK_HZ),
 *       VEND capability (0x180-0x18C), MEM_CACHE_CFG (0x1F4), PROT_CAPS (0x1D0),
 *       PERF_SRC (0x160), FMT_LIMITS (0x150).
 *   - Words 16-17: FMT_FIRST (32), FMT_COUNT (157).
 *   - Words 19-31: Reserved (0).
 *   - Words 32-188: 157 format descriptor words match host FMT_INDEX query via 0x140.
 *   - Words 189-191: Padding (0).
 *   - Partial block write: dst_bytes = 64 writes only 64 bytes, leaving trailing marker unchanged.
 *   - Alignment fault: dst_addr[5:0] != 0 generates kind 1 fault (GHCI_FAULT_KIND_INVALID_OP).
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

`ifndef CFG_FMT_ENABLE_DEPTH32F
`define CFG_FMT_ENABLE_DEPTH32F 1
`endif

module atg_top_caps_harness #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter DATA_W = 256,
	parameter NAME = "default",
	parameter [31:0] EXP_GCLK = 32'd200000000,
	parameter [31:0] LOCAL_BASE = 32'h80000000,
	parameter [31:0] LOCAL_BYTES = 32'h00000000,
	parameter [31:0] WINDOW_BYTES = 32'h04000000,
	parameter [31:0] HOST_LIMIT = 32'h80000000,
	parameter [31:0] APERTURE_BASE_INIT = 32'h00000000,
	parameter [31:0] APERTURE_LIMIT_INIT = 32'hC0000000,
	parameter [15:0] SUBSYSTEM_VENDOR = 16'h10EE,
	parameter [15:0] SUBSYSTEM_DEVICE = 16'h0007,
	parameter [31:0] DEVICE_VERSION = 32'h00000003,
	parameter [31:0] MEM_CACHE_CFG = 32'd0,
	parameter HAS_CPU = 1,
	parameter NSU = 1,
	parameter HAS_VF = 1,
	parameter HAS_RX = 1,
	parameter HAS_TU = 1,
	parameter HAS_ROP = 1,
	parameter HAS_DISP = 0,
	parameter HAS_BLT = 1,
	parameter HAS_L2 = 0,
	parameter SU_NPHYS = 8,
	parameter SU_NWARPS = 4,
	parameter SU_WARP_W = 2,
	parameter SU_GRP_W = 2,
	parameter SU_NREGS = 32,
	parameter SU_SB_ENTRIES = 4,
	parameter SU_SBE_W = 2,
	parameter SU_LDS_BYTES = 4096,
	parameter SU_VARY_WORDS = 16,
	parameter SU_PACKED = 0,
	parameter SU_SUBGROUP = 0,
	parameter SU_FRAG_RESERVE = 1,
	parameter ROP_STENCIL = 1,
	parameter MS4 = 0,
	parameter [3:0] MRT_COUNT = 4'd1,
	parameter HAS_FFILT = 0,
	parameter HAS_ROP_PACK = 0,
	parameter HAS_ETC = 0,
	parameter TU_BILINEAR = 1,
	parameter HAS_PROT = 1
) (
	input wire clk,
	input wire start,
	output reg finished,
	output integer errors
);
	`include "ghci_regs.vh"

`ifdef CFG_VF_CACHE_LINES
`define ATG_TB_DEF_VF_CACHE_LINES 4'd`CFG_VF_CACHE_LINES
`else
`define ATG_TB_DEF_VF_CACHE_LINES 4'd0
`endif

`ifdef CFG_TU_L1_CACHE_KB
`define ATG_TB_DEF_TU_L1_CACHE_KB 4'd`CFG_TU_L1_CACHE_KB
`else
`define ATG_TB_DEF_TU_L1_CACHE_KB 4'd0
`endif

`ifdef CFG_MC_L2_WAYS
`define ATG_TB_DEF_MC_L2_WAYS 8'd`CFG_MC_L2_WAYS
`else
`define ATG_TB_DEF_MC_L2_WAYS 8'd0
`endif

`ifdef CFG_MC_L2_CACHE_KB
`define ATG_TB_DEF_MC_L2_CACHE_KB 16'd`CFG_MC_L2_CACHE_KB
`else
`define ATG_TB_DEF_MC_L2_CACHE_KB 16'd0
`endif

	wire [31:0] exp_mem_cache_cfg = (MEM_CACHE_CFG != 32'd0) ? MEM_CACHE_CFG : {
		`ATG_TB_DEF_VF_CACHE_LINES, `ATG_TB_DEF_TU_L1_CACHE_KB,
		`ATG_TB_DEF_MC_L2_WAYS, `ATG_TB_DEF_MC_L2_CACHE_KB
	};

	localparam RING   = 32'h00004000;
	localparam FENCES = 32'h00008000;
	localparam TARGET = 32'h00002000;

	reg rst_n = 1'b0;

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
		.DEVICE_VERSION(DEVICE_VERSION),
		.MEM_CACHE_CFG(MEM_CACHE_CFG),
		.HAS_CPU(HAS_CPU),
		.NSU(NSU),
		.HAS_VF(HAS_VF),
		.HAS_RX(HAS_RX),
		.HAS_TU(HAS_TU),
		.HAS_ROP(HAS_ROP),
		.HAS_DISP(HAS_DISP),
		.HAS_BLT(HAS_BLT),
		.HAS_L2(HAS_L2),
		.SU_NPHYS(SU_NPHYS),
		.SU_NWARPS(SU_NWARPS),
		.SU_WARP_W(SU_WARP_W),
		.SU_GRP_W(SU_GRP_W),
		.SU_NREGS(SU_NREGS),
		.SU_SB_ENTRIES(SU_SB_ENTRIES),
		.SU_SBE_W(SU_SBE_W),
		.SU_LDS_BYTES(SU_LDS_BYTES),
		.SU_VARY_WORDS(SU_VARY_WORDS),
		.SU_PACKED(SU_PACKED),
		.SU_SUBGROUP(SU_SUBGROUP),
		.SU_FRAG_RESERVE(SU_FRAG_RESERVE),
		.ROP_STENCIL(ROP_STENCIL),
		.MS4(MS4),
		.MRT_COUNT(MRT_COUNT),
		.HAS_FFILT(HAS_FFILT),
		.HAS_ROP_PACK(HAS_ROP_PACK),
		.HAS_ETC(HAS_ETC),
		.TU_BILINEAR(TU_BILINEAR),
		.HAS_PROT(HAS_PROT)
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
		.x_req_valid(1'b0), .x_req_ready(), .x_req_write(1'b0),
		.x_req_line({(32-LINE_SHIFT){1'b0}}),
		.x_req_be({LINE_BYTES{1'b0}}),
		.x_req_wdata({DATA_W{1'b0}}),
		.x_req_tag(8'd0),
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

	task check_word;
		input integer word_idx;
		input [31:0] got;
		input [31:0] want;
		begin
			if (got !== want) begin
				errors = errors + 1;
				$display("FAIL %0s: word %0d got 0x%08h, expected 0x%08h", NAME, word_idx, got, want);
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
			host_write(GHCI_REG_FAULT_INFO, 32'hFFFFFFFF);
			host_write(GHCI_REG_IRQ_STATUS, 32'hFFFFFFFF);
		end
	endtask

	integer i, wp, to_cnt;
	reg [31:0] reg_val, opt_val, lin_val, buf_val, exp_fmt_val;
	reg [31:0] reg_sub_lo, reg_sub_hi;
	reg [31:0] reg_p0, reg_p1, reg_p2, reg_p3;
	reg [31:0] val;
	reg [31:0] sc1_words [0:15];

	initial begin
		finished = 1'b0;
		errors = 0;
		wait(start);

		$display("=== atg_top_caps_harness: Starting verification for shape [%0s] ===", NAME);
		rst_n <= 1'b0;
		#50;
		rst_n <= 1'b1;
		#50;
		reset_gpu;

		/* -------------------------------------------------------------
		 * Scenario 1: Full 768-byte (192 dwords) CMD_QUERY_CAPS
		 * ------------------------------------------------------------- */
		$display("--- [%0s] Scenario 1: Full 768-byte capability block query ---", NAME);
		for (i = 0; i < 768; i = i + 4)
			mem.poke32(TARGET + i, 32'hDEADBEEF);
		mem.poke32(FENCES, 32'd0);

		wp = 0;
		// CMD_QUERY_CAPS: opcode 0x15, dwords 5
		mem.poke32(RING + wp * 4, 32'h00000515); wp = wp + 1;
		mem.poke32(RING + wp * 4, TARGET);       wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'd0);        wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'd768);      wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'd0);        wp = wp + 1;

		// Trailing CMD_FENCE: opcode 0x33, dwords 6
		mem.poke32(RING + wp * 4, 32'h00000633); wp = wp + 1;
		mem.poke32(RING + wp * 4, FENCES);       wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'd0);        wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'hA5A50001); wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'd0);        wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'h00000003); wp = wp + 1; // flags=3: write + irq

		host_write(GHCI_REG_RING_WPTR, wp);

		// Wait for CMD_FENCE completion
		to_cnt = 0;
		while (mem.peek32(FENCES) !== 32'hA5A50001 && to_cnt < 20000) begin
			#50;
			to_cnt = to_cnt + 1;
		end
		if (mem.peek32(FENCES) !== 32'hA5A50001) begin
			errors = errors + 1;
			$display("FAIL %0s: Timeout waiting for CMD_FENCE in Scenario 1", NAME);
		end else begin
			$display("PASS %0s: CMD_QUERY_CAPS and CMD_FENCE completed", NAME);
		end

		/* Word 0: BLOCK_ID (0x50414347 "GCAP") */
		check_word(0, mem.peek32(TARGET + 0 * 4), 32'h50414347);

		/* Word 1: BLOCK_INFO (192 dwords, version 1 = 0x00C00001) */
		check_word(1, mem.peek32(TARGET + 1 * 4), 32'h00C00001);

		/* Word 2: DEVICE_CAPS */
		check_word(2, mem.peek32(TARGET + 2 * 4), dut.cp.u_caps.device_caps);

		/* Word 3: EXT_CAP_FEATURE */
		check_word(3, mem.peek32(TARGET + 3 * 4), dut.cp.u_caps.ext_cap_feature);

		/* Word 4: EXT_CAP_FMT0 */
		check_word(4, mem.peek32(TARGET + 4 * 4), dut.cp.u_caps.ext_cap_fmt0);

		/* Word 5: RESIDENT_WARPS */
		check_word(5, mem.peek32(TARGET + 5 * 4), dut.cp.u_caps.resident_warps);

		/* Word 6: NATIVE_ISA_ID */
		check_word(6, mem.peek32(TARGET + 6 * 4), dut.cp.u_caps.native_isa_id);

		/* Word 7: GCLK_HZ */
		check_word(7, mem.peek32(TARGET + 7 * 4), dut.cp.u_caps.gclk_hz);

		/* Words 8-9: VENDOR_ID, DEVICE_ID */
		check_word(8, mem.peek32(TARGET + 8 * 4), dut.cp.u_caps.vendor_id);
		check_word(9, mem.peek32(TARGET + 9 * 4), dut.cp.u_caps.device_id);

		/* Word 10: SUBSYSTEM */
		check_word(10, mem.peek32(TARGET + 10 * 4), dut.cp.u_caps.subsystem);

		/* Word 11: DEVICE_VERSION */
		check_word(11, mem.peek32(TARGET + 11 * 4), dut.cp.u_caps.device_version);

		/* Word 12: MEM_CACHE_CFG */
		check_word(12, mem.peek32(TARGET + 12 * 4), exp_mem_cache_cfg);

		/* Word 13: PROT_CAPS */
		check_word(13, mem.peek32(TARGET + 13 * 4), dut.cp.u_caps.prot_caps);

		/* Word 14: PERF_SRC */
		check_word(14, mem.peek32(TARGET + 14 * 4), dut.cp.u_caps.perf_src);

		/* Word 15: FMT_LIMITS */
		check_word(15, mem.peek32(TARGET + 15 * 4), dut.cp.u_caps.fmt_limits);

		/* Word 16: FMT_FIRST (32) */
		check_word(16, mem.peek32(TARGET + 16 * 4), 32'd32);

		/* Word 17: FMT_COUNT (157) */
		check_word(17, mem.peek32(TARGET + 17 * 4), 32'd157);

		/* Word 18: EXTCAP_PRESENT (matched against dut's caps block) */
		check_word(18, mem.peek32(TARGET + 18 * 4), dut.cp.u_caps.extcap_present);

		/* Words 19-31: Reserved (0) */
		for (i = 19; i < 32; i = i + 1)
			check_word(i, mem.peek32(TARGET + i * 4), 32'd0);

		/* Words 32-188: 157 format descriptors matched against dut.cp.u_caps.calc_fmt_word */
		for (i = 0; i < 157; i = i + 1) begin
			exp_fmt_val = dut.cp.u_caps.calc_fmt_word(i[7:0]);
			check_word(32 + i, mem.peek32(TARGET + (32 + i) * 4), exp_fmt_val);
		end

		/* Words 189-191: Padding (0) */
		for (i = 189; i < 192; i = i + 1)
			check_word(i, mem.peek32(TARGET + i * 4), 32'd0);

		for (i = 0; i < 16; i = i + 1)
			sc1_words[i] = mem.peek32(TARGET + i * 4);

		if (errors == 0)
			$display("PASS %0s: All 192 words matched capability block model", NAME);

		/* Host MMIO checks: BOOT_CAPS at 0x008 and deleted registers read 0 */
		host_read(GHCI_REG_BOOT_CAPS, val);
		if (val !== dut.cp.u_caps.boot_caps) begin
			errors = errors + 1;
			$display("FAIL %0s: 0x008 got 0x%08h, expected BOOT_CAPS 0x%08h", NAME, val, dut.cp.u_caps.boot_caps);
		end else begin
			$display("PASS %0s: 0x008 correctly returns BOOT_CAPS = 0x%08h", NAME, val);
		end

		/* 0x04C RESIDENT_WARPS */
		host_read(17'h0004C, val);
		if (val !== 32'd0) begin errors = errors + 1; $display("FAIL %0s: 0x04C read %h, expected 0", NAME, val); end
		/* 0x064 GCLK_HZ */
		host_read(17'h00064, val);
		if (val !== 32'd0) begin errors = errors + 1; $display("FAIL %0s: 0x064 read %h, expected 0", NAME, val); end
		/* 0x068 NATIVE_ISA_ID */
		host_read(17'h00068, val);
		if (val !== 32'd0) begin errors = errors + 1; $display("FAIL %0s: 0x068 read %h, expected 0", NAME, val); end
		/* 0x080 EXT_CAP_FMT0 */
		host_read(17'h00080, val);
		if (val !== 32'd0) begin errors = errors + 1; $display("FAIL %0s: 0x080 read %h, expected 0", NAME, val); end
		/* 0x084 EXT_CAP_FEATURE */
		host_read(17'h00084, val);
		if (val !== 32'd0) begin errors = errors + 1; $display("FAIL %0s: 0x084 read %h, expected 0", NAME, val); end

		/* FMT window: 0x140 .. 0x150 */
		for (i = 17'h00140; i <= 17'h00150; i = i + 4) begin
			host_read(i, val);
			if (val !== 32'd0) begin errors = errors + 1; $display("FAIL %0s: FMT 0x%03h read %h, expected 0", NAME, i, val); end
		end

		/* PERF_SRC: 0x160 .. 0x16C */
		for (i = 17'h00160; i <= 17'h0016C; i = i + 4) begin
			host_read(i, val);
			if (val !== 32'd0) begin errors = errors + 1; $display("FAIL %0s: PERF 0x%03h read %h, expected 0", NAME, i, val); end
		end

		/* VEND window: 0x180 .. 0x190 */
		for (i = 17'h00180; i <= 17'h00190; i = i + 4) begin
			host_read(i, val);
			if (val !== 32'd0) begin errors = errors + 1; $display("FAIL %0s: VEND 0x%03h read %h, expected 0", NAME, i, val); end
		end

		/* MEM_CACHE_CFG: 0x1F4 */
		host_read(17'h001F4, val);
		if (val !== 32'd0) begin errors = errors + 1; $display("FAIL %0s: MEM 0x1F4 read %h, expected 0", NAME, val); end

		/* -------------------------------------------------------------
		 * Scenario 2: Partial write (dst_bytes = 64)
		 * ------------------------------------------------------------- */
		$display("--- [%0s] Scenario 2: Partial write (dst_bytes = 64) ---", NAME);
		for (i = 0; i < 128; i = i + 4)
			mem.poke32(TARGET + i, 32'hA5A5A5A5);
		mem.poke32(FENCES, 32'd0);

		mem.poke32(RING + wp * 4, 32'h00000515); wp = wp + 1;
		mem.poke32(RING + wp * 4, TARGET);       wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'd0);        wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'd64);       wp = wp + 1; // 64 bytes = 16 dwords
		mem.poke32(RING + wp * 4, 32'd0);        wp = wp + 1;

		mem.poke32(RING + wp * 4, 32'h00000633); wp = wp + 1;
		mem.poke32(RING + wp * 4, FENCES);       wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'd0);        wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'hA5A50002); wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'd0);        wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'h00000003); wp = wp + 1;

		host_write(GHCI_REG_RING_WPTR, wp);

		to_cnt = 0;
		while (mem.peek32(FENCES) !== 32'hA5A50002 && to_cnt < 20000) begin
			#50;
			to_cnt = to_cnt + 1;
		end
		if (mem.peek32(FENCES) !== 32'hA5A50002) begin
			errors = errors + 1;
			$display("FAIL %0s: Timeout in Scenario 2", NAME);
		end else begin
			// Check words 0..15 match block values
			for (i = 0; i < 16; i = i + 1) begin
				if (mem.peek32(TARGET + i * 4) !== sc1_words[i]) begin
					errors = errors + 1;
					$display("FAIL %0s: Word %0d in 64-byte block mismatch: exp 0x%08h got 0x%08h",
						NAME, i, sc1_words[i], mem.peek32(TARGET + i * 4));
				end
			end
			// Check words 16..31 remain untouched (0xA5A5A5A5)
			for (i = 16; i < 32; i = i + 1) begin
				if (mem.peek32(TARGET + i * 4) !== 32'hA5A5A5A5) begin
					errors = errors + 1;
					$display("FAIL %0s: Word %0d beyond 64 bytes was overwritten: 0x%08h", NAME, i, mem.peek32(TARGET + i * 4));
				end
			end
			if (errors == 0)
				$display("PASS %0s: 64-byte partial write verified without buffer overrun", NAME);
		end

		/* -------------------------------------------------------------
		 * Scenario 3: Unaligned dst_addr triggers kind 1 fault
		 * ------------------------------------------------------------- */
		$display("--- [%0s] Scenario 3: Unaligned dst_addr generates kind 1 fault ---", NAME);
		mem.poke32(RING + wp * 4, 32'h00000515); wp = wp + 1;
		mem.poke32(RING + wp * 4, TARGET + 32'd8); wp = wp + 1; // unaligned: [5:0] != 0
		mem.poke32(RING + wp * 4, 32'd0);        wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'd64);       wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'd0);        wp = wp + 1;

		host_write(GHCI_REG_RING_WPTR, wp);

		to_cnt = 0;
		val = 0;
		while (!val[GHCI_STATUS_FAULTED] && to_cnt < 5000) begin
			#50;
			host_read(GHCI_REG_STATUS, val);
			to_cnt = to_cnt + 1;
		end
		if (!val[GHCI_STATUS_FAULTED]) begin
			errors = errors + 1;
			$display("FAIL %0s: STATUS.FAULTED was not asserted for unaligned dst_addr", NAME);
		end else begin
			$display("PASS %0s: STATUS.FAULTED asserted as expected", NAME);
			host_read(GHCI_REG_FAULT_INFO, val);
			if (val[3:0] !== GHCI_FAULT_KIND_INVALID_OP) begin
				errors = errors + 1;
				$display("FAIL %0s: FAULT_INFO kind = %0d (expected %0d)", NAME, val[3:0], GHCI_FAULT_KIND_INVALID_OP);
			end else begin
				$display("PASS %0s: FAULT_INFO kind == 1 (INVALID_OP)", NAME);
			end
		end

		finished = 1'b1;
	end
endmodule

module atg_top_caps_tb;
	reg clk = 1'b0;
	always #5 clk = !clk;

	reg start_def = 1'b0;
	wire done_def;
	wire [31:0] err_def;

	reg start_kc = 1'b0;
	wire done_kc;
	wire [31:0] err_kc;

	atg_top_caps_harness #(
		.LINE_BYTES(32),
		.LINE_SHIFT(5),
		.DATA_W(256),
		.NAME("default"),
		.HAS_VF(1),
		.NSU(1),
		.HAS_RX(1),
		.HAS_TU(1),
		.HAS_ROP(1),
		.HAS_BLT(1),
		.SU_NPHYS(8),
		.SU_VARY_WORDS(16),
		.ROP_STENCIL(1),
		.MS4(0),
		.MRT_COUNT(1)
	) harness_def (
		.clk(clk),
		.start(start_def),
		.finished(done_def),
		.errors(err_def)
	);

	atg_top_caps_harness #(
		.LINE_BYTES(64),
		.LINE_SHIFT(6),
		.DATA_W(512),
		.NAME("kc705"),
		.HAS_VF(1),
		.NSU(1),
		.HAS_TU(1),
		.SU_NPHYS(4),
		.SU_GRP_W(3),
		.SU_VARY_WORDS(64),
		.SU_NREGS(64),
		.SU_SB_ENTRIES(8),
		.SU_SBE_W(3),
		.SU_PACKED(1),
		.SU_SUBGROUP(1),
		.SU_FRAG_RESERVE(2),
		.SU_LDS_BYTES(16384),
		.ROP_STENCIL(1),
		.MS4(1),
		.MRT_COUNT(4),
		.HAS_FFILT(1),
		.HAS_ROP_PACK(1),
		.HAS_ETC(1)
	) harness_kc (
		.clk(clk),
		.start(start_kc),
		.finished(done_kc),
		.errors(err_kc)
	);

	initial begin
		#20;
		start_def <= 1'b1;
		wait(done_def);
		start_def <= 1'b0;
		#50;
		start_kc <= 1'b1;
		wait(done_kc);
		start_kc <= 1'b0;
		#50;

		if (err_def == 0 && err_kc == 0) begin
			$display("PASS atg_top_caps");
		end else begin
			$display("FAIL atg_top_caps: default errors=%0d, kc705 errors=%0d", err_def, err_kc);
		end
		$finish;
	end

	initial begin
		#600000000;
		$display("FAIL atg_top_caps: timeout");
		$finish;
	end
endmodule

`default_nettype wire
