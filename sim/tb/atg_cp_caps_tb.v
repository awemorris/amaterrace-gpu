/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_caps_tb: unit testbench for atg_cp_caps.
 * Tests capability block dwords 0..191 and direct output ports
 * against authoritative specification across
 * multiple architectural and feature configurations:
 *   - Full default configuration
 *   - HAS_TU = 0 (SAMPLE, FILTER_LINEAR, BLIT_SRC masked; EXT_CAP_FMT0 bits 16, 19..22 masked)
 *   - HAS_ROP = 0 (COLOR, BLEND, DEPTH, BLIT_DST masked; ROP_PACK, DUAL_SRC masked)
 *   - HAS_VF = 0 (VERTEX_BUFFER masked in OPTIMAL, LINEAR, BUFFER)
 *   - HAS_FMT_SRGB = 0 (formats 43, 50, 57, 148, 150, 152 all 0; EXT_CAP_FMT0 bit 9 masked)
 *   - HAS_FMT_RGB565 = 0 (formats 3, 4, 8 all 0)
 *   - HAS_TEX_ARRAY = 0 (EXT_CAP_FMT0 bit 19 masked)
 *   - HAS_TEX_3D_CUBE = 0 (EXT_CAP_FMT0 bits 20..21 masked)
 *   - HAS_TEX_TRILINEAR = 0 (EXT_CAP_FMT0 bit 22 masked)
 *   - LOCAL_BYTES = 0 (UMA=1, MEM capability absent) vs LOCAL_BYTES != 0 (UMA=0, MEM present)
 *   - HAS_PROT = 0 vs HAS_PROT = 1 (PROT_CAPS word, EXTCAP_PRESENT bit 9, DEVICE_CAPS bit 24)
 *   - Format query port (fmt_idx / fmt_val) comparison
 *   - Out of bounds indexing (dw >= 192 returns 0)
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

module atg_cp_caps_tb;
	reg clk;
	reg rst_n;
	integer errors;

	/* Clock generation */
	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

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

	wire [31:0] exp_mem_cache_cfg = {
		`ATG_TB_DEF_VF_CACHE_LINES, `ATG_TB_DEF_TU_L1_CACHE_KB,
		`ATG_TB_DEF_MC_L2_WAYS, `ATG_TB_DEF_MC_L2_CACHE_KB
	};

	/* Shared read index and query port */
	reg [8:0] r_idx;
	reg [7:0] fmt_idx;

	/* DUT 1: Full / default capabilities */
	wire [31:0] r_data_full;
	wire [31:0] boot_caps_full, dev_caps_full, feat_full, fmt0_full;
	wire [31:0] warps_full, isa_full, gclk_full, vend_full, devid_full, sub_full;
	wire [31:0] ver_full, mem_full, prot_full, perf_full, limits_full, xcap_full;
	wire [31:0] fmt_val_full;

	atg_cp_caps #(
		.GCLK_HZ(32'd200000000),
		.VENDOR_ID(32'h414D4154),
		.DEVICE_ID(32'h41544731),
		.DEVICE_VERSION(32'h00000002),
		.NATIVE_ISA_ID(32'h47534931),
		.RESIDENT_WARPS(16'd64),
		.NREGS(8'd32),
		.LOCAL_BASE(32'd0),
		.LOCAL_BYTES(32'd0),
		.WINDOW_BYTES(32'd0),
		.HOST_LIMIT(32'd0),
		.SUBSYSTEM_VENDOR(16'h1234),
		.SUBSYSTEM_DEVICE(16'h5678),
		.MEM_CACHE_CFG(32'd0),
		.MRT_COUNT(4'd4),
		.VA_BITS(32),
		.PA_BITS(40),
		.NSU(4),
		.SU_NPHYS(8),
		.SU_PACKED(1),
		.SU_SUBGROUP(1),
		.SU_LDS_KB(64),
		.HAS_BLT(1),
		.BLT_SCALE(1),
		.BLT_BLEND(1),
		.BLT_TILE(1),
		.HAS_DISP(1),
		.DC_HAS_CURSOR(1),
		.HAS_TU(1),
		.TU_BILINEAR(1),
		.HAS_FFILT(1),
		.HAS_ROP(1),
		.HAS_ROP_PACK(1),
		.HAS_D16(1),
		.HAS_D24S8(1),
		.HAS_D32F(1),
		.HAS_STENCIL(1),
		.HAS_FBLEND(1),
		.HAS_VF(1),
		.HAS_TEX_ARRAY(1),
		.HAS_TEX_3D_CUBE(1),
		.HAS_TEX_TRILINEAR(1),
		.HAS_FMT_SRGB(1),
		.HAS_FMT_RGB565(1),
		.HAS_MESH(0),
		.HAS_ETC(0),
		.MS4(0),
		.HAS_PROT(0),
		.HAS_INDIRECT_DRAW(0),
		.HAS_SECONDARY_RING(0),
		.HAS_HW_WALKER(0),
		.PERF_SRC(32'hFFFF0801)
	) dut_full (
		.clk(clk), .rst_n(rst_n),
		.r_idx(r_idx), .r_data(r_data_full),
		.boot_caps(boot_caps_full), .device_caps(dev_caps_full),
		.ext_cap_feature(feat_full), .ext_cap_fmt0(fmt0_full),
		.resident_warps(warps_full), .native_isa_id(isa_full),
		.gclk_hz(gclk_full), .vendor_id(vend_full), .device_id(devid_full),
		.subsystem(sub_full), .device_version(ver_full),
		.mem_cache_cfg(mem_full), .prot_caps(prot_full),
		.perf_src(perf_full), .fmt_limits(limits_full),
		.extcap_present(xcap_full),
		.fmt_idx(fmt_idx), .fmt_val(fmt_val_full)
	);

	/* DUT 2: HAS_TU = 0 */
	wire [31:0] r_data_no_tu, fmt0_no_tu, fmt_val_no_tu;
	atg_cp_caps #(
		.HAS_TU(0), .HAS_ROP(1), .HAS_VF(1),
		.HAS_FMT_SRGB(1), .HAS_FMT_RGB565(1),
		.TU_BILINEAR(1), .HAS_FFILT(1), .HAS_ROP_PACK(1),
		.HAS_D16(1), .HAS_D24S8(1), .HAS_D32F(1), .HAS_STENCIL(1), .HAS_FBLEND(1)
	) dut_no_tu (
		.clk(clk), .rst_n(rst_n),
		.r_idx(r_idx), .r_data(r_data_no_tu),
		.boot_caps(), .device_caps(), .ext_cap_feature(),
		.ext_cap_fmt0(fmt0_no_tu), .resident_warps(), .native_isa_id(),
		.gclk_hz(), .vendor_id(), .device_id(), .subsystem(),
		.device_version(), .mem_cache_cfg(), .prot_caps(),
		.perf_src(), .fmt_limits(), .extcap_present(),
		.fmt_idx(fmt_idx), .fmt_val(fmt_val_no_tu)
	);

	/* DUT 3: HAS_ROP = 0 */
	wire [31:0] r_data_no_rop, dev_caps_no_rop, feat_no_rop, fmt_val_no_rop;
	atg_cp_caps #(
		.HAS_TU(1), .HAS_ROP(0), .HAS_VF(1),
		.HAS_FMT_SRGB(1), .HAS_FMT_RGB565(1),
		.TU_BILINEAR(1), .HAS_FFILT(1), .HAS_ROP_PACK(1),
		.HAS_D16(1), .HAS_D24S8(1), .HAS_D32F(1), .HAS_STENCIL(1), .HAS_FBLEND(1),
		.ROP_DUAL_SOURCE(1)
	) dut_no_rop (
		.clk(clk), .rst_n(rst_n),
		.r_idx(r_idx), .r_data(r_data_no_rop),
		.boot_caps(), .device_caps(dev_caps_no_rop), .ext_cap_feature(feat_no_rop),
		.ext_cap_fmt0(), .resident_warps(), .native_isa_id(),
		.gclk_hz(), .vendor_id(), .device_id(), .subsystem(),
		.device_version(), .mem_cache_cfg(), .prot_caps(),
		.perf_src(), .fmt_limits(), .extcap_present(),
		.fmt_idx(fmt_idx), .fmt_val(fmt_val_no_rop)
	);

	/* DUT 4: HAS_VF = 0 */
	wire [31:0] r_data_no_vf, fmt_val_no_vf;
	atg_cp_caps #(
		.HAS_TU(1), .HAS_ROP(1), .HAS_VF(0),
		.HAS_FMT_SRGB(1), .HAS_FMT_RGB565(1),
		.TU_BILINEAR(1), .HAS_FFILT(1), .HAS_ROP_PACK(1),
		.HAS_D16(1), .HAS_D24S8(1), .HAS_D32F(1), .HAS_STENCIL(1), .HAS_FBLEND(1)
	) dut_no_vf (
		.clk(clk), .rst_n(rst_n),
		.r_idx(r_idx), .r_data(r_data_no_vf),
		.boot_caps(), .device_caps(), .ext_cap_feature(),
		.ext_cap_fmt0(), .resident_warps(), .native_isa_id(),
		.gclk_hz(), .vendor_id(), .device_id(), .subsystem(),
		.device_version(), .mem_cache_cfg(), .prot_caps(),
		.perf_src(), .fmt_limits(), .extcap_present(),
		.fmt_idx(fmt_idx), .fmt_val(fmt_val_no_vf)
	);

	/* DUT 5: HAS_FMT_SRGB = 0 */
	wire [31:0] r_data_no_srgb, fmt0_no_srgb, fmt_val_no_srgb;
	atg_cp_caps #(
		.HAS_TU(1), .HAS_ROP(1), .HAS_VF(1),
		.HAS_FMT_SRGB(0), .HAS_FMT_RGB565(1),
		.TU_BILINEAR(1), .HAS_FFILT(1), .HAS_ROP_PACK(1),
		.HAS_D16(1), .HAS_D24S8(1), .HAS_D32F(1), .HAS_STENCIL(1), .HAS_FBLEND(1)
	) dut_no_srgb (
		.clk(clk), .rst_n(rst_n),
		.r_idx(r_idx), .r_data(r_data_no_srgb),
		.boot_caps(), .device_caps(), .ext_cap_feature(),
		.ext_cap_fmt0(fmt0_no_srgb), .resident_warps(), .native_isa_id(),
		.gclk_hz(), .vendor_id(), .device_id(), .subsystem(),
		.device_version(), .mem_cache_cfg(), .prot_caps(),
		.perf_src(), .fmt_limits(), .extcap_present(),
		.fmt_idx(fmt_idx), .fmt_val(fmt_val_no_srgb)
	);

	/* DUT 6: HAS_FMT_RGB565 = 0 */
	wire [31:0] r_data_no_rgb565, fmt_val_no_rgb565;
	atg_cp_caps #(
		.HAS_TU(1), .HAS_ROP(1), .HAS_VF(1),
		.HAS_FMT_SRGB(1), .HAS_FMT_RGB565(0),
		.TU_BILINEAR(1), .HAS_FFILT(1), .HAS_ROP_PACK(1),
		.HAS_D16(1), .HAS_D24S8(1), .HAS_D32F(1), .HAS_STENCIL(1), .HAS_FBLEND(1)
	) dut_no_rgb565 (
		.clk(clk), .rst_n(rst_n),
		.r_idx(r_idx), .r_data(r_data_no_rgb565),
		.boot_caps(), .device_caps(), .ext_cap_feature(),
		.ext_cap_fmt0(), .resident_warps(), .native_isa_id(),
		.gclk_hz(), .vendor_id(), .device_id(), .subsystem(),
		.device_version(), .mem_cache_cfg(), .prot_caps(),
		.perf_src(), .fmt_limits(), .extcap_present(),
		.fmt_idx(fmt_idx), .fmt_val(fmt_val_no_rgb565)
	);

	/* DUT 7: Texture dimensional caps (ARRAY=0, 3D_CUBE=0, TRILINEAR=0) */
	wire [31:0] fmt0_no_array, fmt0_no_3d, fmt0_no_tri;
	atg_cp_caps #(
		.HAS_TU(1), .HAS_TEX_ARRAY(0), .HAS_TEX_3D_CUBE(1), .HAS_TEX_TRILINEAR(1)
	) dut_no_array (
		.clk(clk), .rst_n(rst_n),
		.r_idx(r_idx), .r_data(),
		.boot_caps(), .device_caps(), .ext_cap_feature(),
		.ext_cap_fmt0(fmt0_no_array), .resident_warps(), .native_isa_id(),
		.gclk_hz(), .vendor_id(), .device_id(), .subsystem(),
		.device_version(), .mem_cache_cfg(), .prot_caps(),
		.perf_src(), .fmt_limits(), .extcap_present(),
		.fmt_idx(fmt_idx), .fmt_val()
	);
	atg_cp_caps #(
		.HAS_TU(1), .HAS_TEX_ARRAY(1), .HAS_TEX_3D_CUBE(0), .HAS_TEX_TRILINEAR(1)
	) dut_no_3d (
		.clk(clk), .rst_n(rst_n),
		.r_idx(r_idx), .r_data(),
		.boot_caps(), .device_caps(), .ext_cap_feature(),
		.ext_cap_fmt0(fmt0_no_3d), .resident_warps(), .native_isa_id(),
		.gclk_hz(), .vendor_id(), .device_id(), .subsystem(),
		.device_version(), .mem_cache_cfg(), .prot_caps(),
		.perf_src(), .fmt_limits(), .extcap_present(),
		.fmt_idx(fmt_idx), .fmt_val()
	);
	atg_cp_caps #(
		.HAS_TU(1), .HAS_TEX_ARRAY(1), .HAS_TEX_3D_CUBE(1), .HAS_TEX_TRILINEAR(0)
	) dut_no_tri (
		.clk(clk), .rst_n(rst_n),
		.r_idx(r_idx), .r_data(),
		.boot_caps(), .device_caps(), .ext_cap_feature(),
		.ext_cap_fmt0(fmt0_no_tri), .resident_warps(), .native_isa_id(),
		.gclk_hz(), .vendor_id(), .device_id(), .subsystem(),
		.device_version(), .mem_cache_cfg(), .prot_caps(),
		.perf_src(), .fmt_limits(), .extcap_present(),
		.fmt_idx(fmt_idx), .fmt_val()
	);

	/* DUT 8: Local memory present */
	wire [31:0] r_data_mem, dev_caps_mem, mem_cfg_mem, xcap_mem;
	atg_cp_caps #(
		.LOCAL_BASE(32'h10000000),
		.LOCAL_BYTES(32'h08000000),
		.MEM_CACHE_CFG(32'h12345678)
	) dut_local_mem (
		.clk(clk), .rst_n(rst_n),
		.r_idx(r_idx), .r_data(r_data_mem),
		.boot_caps(), .device_caps(dev_caps_mem), .ext_cap_feature(),
		.ext_cap_fmt0(), .resident_warps(), .native_isa_id(),
		.gclk_hz(), .vendor_id(), .device_id(), .subsystem(),
		.device_version(), .mem_cache_cfg(mem_cfg_mem), .prot_caps(),
		.perf_src(), .fmt_limits(), .extcap_present(xcap_mem),
		.fmt_idx(fmt_idx), .fmt_val()
	);

	/* DUT 9: Session protection present */
	wire [31:0] r_data_prot, dev_caps_prot, prot_caps_prot, xcap_prot;
	atg_cp_caps #(
		.HAS_PROT(1),
		.PROT_SLOTS(8'd31),
		.PROT_GRANTS(16'd8)
	) dut_prot (
		.clk(clk), .rst_n(rst_n),
		.r_idx(r_idx), .r_data(r_data_prot),
		.boot_caps(), .device_caps(dev_caps_prot), .ext_cap_feature(),
		.ext_cap_fmt0(), .resident_warps(), .native_isa_id(),
		.gclk_hz(), .vendor_id(), .device_id(), .subsystem(),
		.device_version(), .mem_cache_cfg(), .prot_caps(prot_caps_prot),
		.perf_src(), .fmt_limits(), .extcap_present(xcap_prot),
		.fmt_idx(fmt_idx), .fmt_val()
	);

	/* Check helper task */
	task check_val;
		input [31:0] act;
		input [31:0] exp;
		input [127:0] desc;
		begin
			if (act !== exp) begin
				$display("FAIL: %0s: expected 0x%08X, got 0x%08X", desc, exp, act);
				errors = errors + 1;
			end
		end
	endtask

	initial begin
		errors = 0;
		rst_n = 1'b0;
		r_idx = 9'd0;
		fmt_idx = 8'd0;
		#20;
		rst_n = 1'b1;
		#10;

		/* ------------------------------------------------------------- */
		/* Test 1: Full configuration headers & registers (dw 0..31)     */
		/* ------------------------------------------------------------- */
		/* dw 0: BLOCK_ID = 0x50414347 ("GCAP") */
		r_idx = 9'd0; #1;
		check_val(r_data_full, 32'h50414347, "dw0 BLOCK_ID");

		/* dw 1: BLOCK_INFO = [15:0] 1, [31:16] 192 */
		r_idx = 9'd1; #1;
		check_val(r_data_full, {16'd192, 16'd1}, "dw1 BLOCK_INFO");

		/* dw 2: DEVICE_CAPS */
		r_idx = 9'd2; #1;
		check_val(r_data_full, dev_caps_full, "dw2 DEVICE_CAPS matches port");
		check_val(boot_caps_full, 32'h00000201, "boot_caps layout [0]=1, [11:8]=VA_ENC");
		check_val(dev_caps_full[0], 1'b1, "dw2 DEVICE_CAPS[0] UMA when LOCAL_BYTES=0");
		check_val(dev_caps_full[29], 1'b1, "dw2 DEVICE_CAPS[29] BLT");
		check_val(dev_caps_full[26], 1'b1, "dw2 DEVICE_CAPS[26] ROP_PACK");
		check_val(dev_caps_full[25], 1'b1, "dw2 DEVICE_CAPS[25] FFILT");
		check_val(dev_caps_full[23:16], 8'd4, "dw2 DEVICE_CAPS[23:16] NUM_SU");
		check_val(dev_caps_full[15:8], 8'd8, "dw2 DEVICE_CAPS[15:8] PHYS_LANES");
		check_val(dev_caps_full[7], 1'b1, "dw2 DEVICE_CAPS[7] GSI1");
		check_val(dev_caps_full[6], 1'b1, "dw2 DEVICE_CAPS[6] FP16");

		/* dw 3: EXT_CAP_FEATURE */
		r_idx = 9'd3; #1;
		check_val(r_data_full, feat_full, "dw3 EXT_CAP_FEATURE matches port");
		check_val(feat_full[31], 1'b1, "dw3 EXT_CAP_FEATURE[31] BLT_SCALE");
		check_val(feat_full[30], 1'b1, "dw3 EXT_CAP_FEATURE[30] CLIP_POLY");
		check_val(feat_full[29], 1'b1, "dw3 EXT_CAP_FEATURE[29] SUBGROUP");
		check_val(feat_full[28], 1'b1, "dw3 EXT_CAP_FEATURE[28] FP16");
		check_val(feat_full[27:20], 8'd64, "dw3 EXT_CAP_FEATURE[27:20] LDS_KB");
		check_val(feat_full[19:16], 4'd4, "dw3 EXT_CAP_FEATURE[19:16] MAX_MRT");
		check_val(feat_full[15], 1'b1, "dw3 EXT_CAP_FEATURE[15] MRT_BLEND");
		check_val(feat_full[13], 1'b1, "dw3 EXT_CAP_FEATURE[13] CURSOR");

		/* dw 4: EXT_CAP_FMT0 (Format capabilities: [19] ARRAY, [20] 3D, [21] CUBE, [22] TRILINEAR, [11]=0) */
		r_idx = 9'd4; #1;
		check_val(r_data_full, fmt0_full, "dw4 EXT_CAP_FMT0 matches port");
		check_val(fmt0_full[22], 1'b1, "dw4 EXT_CAP_FMT0[22] TEX_TRILINEAR");
		check_val(fmt0_full[21], 1'b1, "dw4 EXT_CAP_FMT0[21] TEX_CUBE");
		check_val(fmt0_full[20], 1'b1, "dw4 EXT_CAP_FMT0[20] TEX_3D");
		check_val(fmt0_full[19], 1'b1, "dw4 EXT_CAP_FMT0[19] TEX_ARRAY");
		check_val(fmt0_full[18], 1'b1, "dw4 EXT_CAP_FMT0[18] BLT_TILE");
		check_val(fmt0_full[17], 1'b1, "dw4 EXT_CAP_FMT0[17] BLT_BLEND");
		check_val(fmt0_full[16], 1'b1, "dw4 EXT_CAP_FMT0[16] TU_BILINEAR");
		check_val(fmt0_full[15:12], 4'd4, "dw4 EXT_CAP_FMT0[15:12] MAX_MRT");
		check_val(fmt0_full[11], 1'b0, "dw4 EXT_CAP_FMT0[11] must be 0");
		check_val(fmt0_full[10], 1'b1, "dw4 EXT_CAP_FMT0[10] FFILT_FP16");
		check_val(fmt0_full[9], 1'b1, "dw4 EXT_CAP_FMT0[9] SRGB");
		check_val(fmt0_full[31:23], 9'd0, "dw4 EXT_CAP_FMT0[31:23] must be 0");

		/* dw 5: RESIDENT_WARPS ({8'd0, NREGS, RESIDENT_WARPS}) */
		r_idx = 9'd5; #1;
		check_val(r_data_full, {8'd0, 8'd32, 16'd64}, "dw5 RESIDENT_WARPS");
		check_val(warps_full, {8'd0, 8'd32, 16'd64}, "resident_warps port");

		/* dw 6: NATIVE_ISA_ID (0x47534931) */
		r_idx = 9'd6; #1;
		check_val(r_data_full, 32'h47534931, "dw6 NATIVE_ISA_ID");
		check_val(isa_full, 32'h47534931, "native_isa_id port");

		/* dw 7: GCLK_HZ */
		r_idx = 9'd7; #1;
		check_val(r_data_full, 32'd200000000, "dw7 GCLK_HZ");
		check_val(gclk_full, 32'd200000000, "gclk_hz port");

		/* dw 8: VENDOR_ID */
		r_idx = 9'd8; #1;
		check_val(r_data_full, 32'h414D4154, "dw8 VENDOR_ID");
		check_val(vend_full, 32'h414D4154, "vendor_id port");

		/* dw 9: DEVICE_ID */
		r_idx = 9'd9; #1;
		check_val(r_data_full, 32'h41544731, "dw9 DEVICE_ID");
		check_val(devid_full, 32'h41544731, "device_id port");

		/* dw 10: SUBSYSTEM ({SUBSYSTEM_DEVICE, SUBSYSTEM_VENDOR}) */
		r_idx = 9'd10; #1;
		check_val(r_data_full, {16'h5678, 16'h1234}, "dw10 SUBSYSTEM");
		check_val(sub_full, {16'h5678, 16'h1234}, "subsystem port");

		/* dw 11: DEVICE_VERSION */
		r_idx = 9'd11; #1;
		check_val(r_data_full, 32'h00000002, "dw11 DEVICE_VERSION");
		check_val(ver_full, 32'h00000002, "device_version port");

		/* dw 12: MEM_CACHE_CFG */
		r_idx = 9'd12; #1;
		check_val(r_data_full, exp_mem_cache_cfg, "dw12 MEM_CACHE_CFG");
		check_val(mem_full, exp_mem_cache_cfg, "mem_cache_cfg port");

		/* dw 13: PROT_CAPS (0 when HAS_PROT=0) */
		r_idx = 9'd13; #1;
		check_val(r_data_full, 32'd0, "dw13 PROT_CAPS (HAS_PROT=0)");
		check_val(prot_full, 32'd0, "prot_caps port");

		/* dw 14: PERF_SRC */
		r_idx = 9'd14; #1;
		check_val(r_data_full, 32'hFFFF0801, "dw14 PERF_SRC");
		check_val(perf_full, 32'hFFFF0801, "perf_src port");

		/* dw 15: FMT_LIMITS ([3:0] colour attachments = 4, rest 0) */
		r_idx = 9'd15; #1;
		check_val(r_data_full, {28'd0, 4'd4}, "dw15 FMT_LIMITS");
		check_val(limits_full, {28'd0, 4'd4}, "fmt_limits port");

		/* dw 16: FMT_FIRST (32) */
		r_idx = 9'd16; #1;
		check_val(r_data_full, 32'd32, "dw16 FMT_FIRST");

		/* dw 17: FMT_COUNT (157) */
		r_idx = 9'd17; #1;
		check_val(r_data_full, 32'd157, "dw17 FMT_COUNT");

		/* dw 18: EXTCAP_PRESENT (bit n = capability ID n present) */
		r_idx = 9'd18; #1;
		check_val(r_data_full, xcap_full, "dw18 EXTCAP_PRESENT matches port");
		check_val(xcap_full[3], 1'b1, "dw18 EXTCAP bit 3 PERF");
		check_val(xcap_full[4], 1'b1, "dw18 EXTCAP bit 4 VEND");
		check_val(xcap_full[10], 1'b1, "dw18 EXTCAP bit 10 FMT");
		check_val(xcap_full[8], 1'b0, "dw18 EXTCAP bit 8 MEM (absent when LOCAL_BYTES=0)");
		check_val(xcap_full[9], 1'b0, "dw18 EXTCAP bit 9 PROT (absent when HAS_PROT=0)");

		/* dw 19..31: Reserved (must be 0) */
		r_idx = 9'd19; #1; check_val(r_data_full, 32'd0, "dw19 reserved 0");
		r_idx = 9'd25; #1; check_val(r_data_full, 32'd0, "dw25 reserved 0");
		r_idx = 9'd31; #1; check_val(r_data_full, 32'd0, "dw31 reserved 0");

		/* ------------------------------------------------------------- */
		/* Test 2: Full configuration format table (dw 32..188)          */
		/* ------------------------------------------------------------- */
		/* Format 4 (R5G6B5_UNORM_PACK16, dw 36):
		 * OPTIMAL = 0x0CF, LINEAR = 0x0CF, BUFFER = 0 => 0x00019ECF */
		r_idx = 9'd36; fmt_idx = 8'd4; #1;
		check_val(r_data_full, 32'h00019ECF, "dw36 (FMT 4 R5G6B5)");
		check_val(fmt_val_full, 32'h00019ECF, "fmt_val port for FMT 4");

		/* Format 37 (R8G8B8A8_UNORM, dw 69):
		 * OPTIMAL = 0x0EF, LINEAR = 0x0EF, BUFFER bit 3 (VERTEX) = 1 => 0x0021DEEF */
		r_idx = 9'd69; fmt_idx = 8'd37; #1;
		check_val(r_data_full, 32'h0021DEEF, "dw69 (FMT 37 RGBA8_UNORM)");
		check_val(fmt_val_full, 32'h0021DEEF, "fmt_val port for FMT 37");

		/* Format 43 (R8G8B8A8_SRGB, dw 75):
		 * OPTIMAL = 0x0CF, LINEAR = 0x0CF, BUFFER = 0 => 0x00019ECF */
		r_idx = 9'd75; fmt_idx = 8'd43; #1;
		check_val(r_data_full, 32'h00019ECF, "dw75 (FMT 43 RGBA8_SRGB)");
		check_val(fmt_val_full, 32'h00019ECF, "fmt_val port for FMT 43");

		/* Format 124 (D16_UNORM, dw 156):
		 * OPTIMAL = 0x053, LINEAR = 0x053, BUFFER = 0 => 0x0000A653 */
		r_idx = 9'd156; fmt_idx = 8'd124; #1;
		check_val(r_data_full, 32'h0000A653, "dw156 (FMT 124 D16_UNORM)");
		check_val(fmt_val_full, 32'h0000A653, "fmt_val port for FMT 124");

		/* dw 189..191: Padding (must be 0) */
		r_idx = 9'd189; #1; check_val(r_data_full, 32'd0, "dw189 padding 0");
		r_idx = 9'd190; #1; check_val(r_data_full, 32'd0, "dw190 padding 0");
		r_idx = 9'd191; #1; check_val(r_data_full, 32'd0, "dw191 padding 0");

		/* dw >= 192: Out of bounds (must be 0) */
		r_idx = 9'd192; #1; check_val(r_data_full, 32'd0, "dw192 out of bounds 0");
		r_idx = 9'd255; #1; check_val(r_data_full, 32'd0, "dw255 out of bounds 0");
		r_idx = 9'd511; #1; check_val(r_data_full, 32'd0, "dw511 out of bounds 0");

		/* ------------------------------------------------------------- */
		/* Test 3: HAS_TU = 0 (texture sampling disabled)                */
		/* ------------------------------------------------------------- */
		/* EXT_CAP_FMT0: bits 16, 19, 20, 21, 22 must be 0 */
		check_val(fmt0_no_tu[16], 1'b0, "no_tu FMT0[16] TU_BILINEAR is 0");
		check_val(fmt0_no_tu[19], 1'b0, "no_tu FMT0[19] TEX_ARRAY is 0");
		check_val(fmt0_no_tu[20], 1'b0, "no_tu FMT0[20] TEX_3D is 0");
		check_val(fmt0_no_tu[21], 1'b0, "no_tu FMT0[21] TEX_CUBE is 0");
		check_val(fmt0_no_tu[22], 1'b0, "no_tu FMT0[22] TEX_TRILINEAR is 0");

		/* Formats under HAS_TU=0:
		 * SAMPLE(0), FILTER(1), BLIT_SRC(6) masked to 0, BLIT_DST(7) follows HAS_ROP */
		/* Format 4: flags 0x0CF -> 0x08C => (0x08C << 9) | 0x08C = 0x0001188C */
		r_idx = 9'd36; fmt_idx = 8'd4; #1;
		check_val(r_data_no_tu, 32'h0001188C, "no_tu dw36 (FMT 4)");
		check_val(fmt_val_no_tu, 32'h0001188C, "no_tu fmt_val for FMT 4");

		/* Format 37: flags 0x0EF -> 0x0AC (VERTEX and BLIT_DST preserved),
		 * BUFFER bit 3 (dw bit 21) preserved => (1<<21) | (0x0AC << 9) | 0x0AC = 0x002158AC */
		r_idx = 9'd69; fmt_idx = 8'd37; #1;
		check_val(r_data_no_tu, 32'h002158AC, "no_tu dw69 (FMT 37)");
		check_val(fmt_val_no_tu, 32'h002158AC, "no_tu fmt_val for FMT 37");

		/* ------------------------------------------------------------- */
		/* Test 4: HAS_ROP = 0 (raster operations disabled)               */
		/* ------------------------------------------------------------- */
		/* DEVICE_CAPS: bit 26 ROP_PACK = 0, bit 5 DUAL_SRC = 0 */
		check_val(dev_caps_no_rop[26], 1'b0, "no_rop DEVICE_CAPS[26] ROP_PACK is 0");
		check_val(dev_caps_no_rop[5], 1'b0, "no_rop DEVICE_CAPS[5] DUAL_SRC is 0");
		check_val(feat_no_rop[8], 1'b0, "no_rop EXT_CAP_FEATURE[8] DUAL_SRC is 0");

		/* Formats under HAS_ROP=0:
		 * COLOR(2), BLEND(3), DEPTH(4), BLIT_DST(7) masked to 0 */
		/* Format 4: flags 0x0CF -> 0x043 => (0x043 << 9) | 0x043 = 0x00008643 */
		r_idx = 9'd36; fmt_idx = 8'd4; #1;
		check_val(r_data_no_rop, 32'h00008643, "no_rop dw36 (FMT 4)");
		check_val(fmt_val_no_rop, 32'h00008643, "no_rop fmt_val for FMT 4");

		/* Format 124 (Depth): flags 0x0D3 -> 0x043 => 0x00008643 */
		r_idx = 9'd156; fmt_idx = 8'd124; #1;
		check_val(r_data_no_rop, 32'h00008643, "no_rop dw156 (FMT 124 Depth)");

		/* ------------------------------------------------------------- */
		/* Test 5: HAS_VF = 0 (vertex fetch disabled)                    */
		/* ------------------------------------------------------------- */
		/* Formats under HAS_VF=0:
		 * VERTEX_BUFFER masked in OPTIMAL(bit 5), LINEAR(bit 5), BUFFER(bit 21) */
		/* Format 37: flags 0x0EF -> 0x0CF, BUFFER 0 => 0x00019ECF */
		r_idx = 9'd69; fmt_idx = 8'd37; #1;
		check_val(r_data_no_vf, 32'h00019ECF, "no_vf dw69 (FMT 37 VERTEX masked)");
		check_val(fmt_val_no_vf, 32'h00019ECF, "no_vf fmt_val for FMT 37");

		/* ------------------------------------------------------------- */
		/* Test 6: HAS_FMT_SRGB = 0 (sRGB formats disabled)              */
		/* ------------------------------------------------------------- */
		/* EXT_CAP_FMT0: bit 9 SRGB = 0 */
		check_val(fmt0_no_srgb[9], 1'b0, "no_srgb EXT_CAP_FMT0[9] SRGB is 0");

		/* Formats 43, 50, 57, 148, 150, 152 all bits must be 0 */
		r_idx = 9'd32 + 9'd43; fmt_idx = 8'd43; #1;
		check_val(r_data_no_srgb, 32'd0, "no_srgb FMT 43 is 0");
		check_val(fmt_val_no_srgb, 32'd0, "no_srgb fmt_val 43 is 0");

		r_idx = 9'd32 + 9'd50; fmt_idx = 8'd50; #1;
		check_val(r_data_no_srgb, 32'd0, "no_srgb FMT 50 is 0");
		check_val(fmt_val_no_srgb, 32'd0, "no_srgb fmt_val 50 is 0");

		r_idx = 9'd32 + 9'd57; fmt_idx = 8'd57; #1;
		check_val(r_data_no_srgb, 32'd0, "no_srgb FMT 57 is 0");
		check_val(fmt_val_no_srgb, 32'd0, "no_srgb fmt_val 57 is 0");

		r_idx = 9'd32 + 9'd148; fmt_idx = 8'd148; #1;
		check_val(r_data_no_srgb, 32'd0, "no_srgb FMT 148 is 0");
		check_val(fmt_val_no_srgb, 32'd0, "no_srgb fmt_val 148 is 0");

		r_idx = 9'd32 + 9'd150; fmt_idx = 8'd150; #1;
		check_val(r_data_no_srgb, 32'd0, "no_srgb FMT 150 is 0");
		check_val(fmt_val_no_srgb, 32'd0, "no_srgb fmt_val 150 is 0");

		r_idx = 9'd32 + 9'd152; fmt_idx = 8'd152; #1;
		check_val(r_data_no_srgb, 32'd0, "no_srgb FMT 152 is 0");
		check_val(fmt_val_no_srgb, 32'd0, "no_srgb fmt_val 152 is 0");

		/* Non-SRGB format 37 must still be valid */
		r_idx = 9'd32 + 9'd37; fmt_idx = 8'd37; #1;
		check_val(r_data_no_srgb, 32'h0021DEEF, "no_srgb FMT 37 still non-zero");
		check_val(fmt_val_no_srgb, 32'h0021DEEF, "no_srgb fmt_val 37 still non-zero");

		/* ------------------------------------------------------------- */
		/* Test 7: HAS_FMT_RGB565 = 0 (RGB565 formats disabled)          */
		/* ------------------------------------------------------------- */
		/* Formats 3, 4, 8 all bits must be 0 */
		r_idx = 9'd32 + 9'd3; fmt_idx = 8'd3; #1;
		check_val(r_data_no_rgb565, 32'd0, "no_rgb565 FMT 3 is 0");

		r_idx = 9'd32 + 9'd4; fmt_idx = 8'd4; #1;
		check_val(r_data_no_rgb565, 32'd0, "no_rgb565 FMT 4 is 0");
		check_val(fmt_val_no_rgb565, 32'd0, "no_rgb565 fmt_val 4 is 0");

		r_idx = 9'd32 + 9'd8; fmt_idx = 8'd8; #1;
		check_val(r_data_no_rgb565, 32'd0, "no_rgb565 FMT 8 is 0");

		/* Non-RGB565 format 37 must still be valid */
		r_idx = 9'd32 + 9'd37; #1;
		check_val(r_data_no_rgb565, 32'h0021DEEF, "no_rgb565 FMT 37 still non-zero");

		/* ------------------------------------------------------------- */
		/* Test 8: Texture dimension features (EXT_CAP_FMT0)             */
		/* ------------------------------------------------------------- */
		/* HAS_TEX_ARRAY = 0: bit 19 = 0, bits [22:20] = 1 */
		check_val(fmt0_no_array[19], 1'b0, "no_array FMT0[19] ARRAY is 0");
		check_val(fmt0_no_array[22:20], 3'b111, "no_array FMT0[22:20] remain 1");

		/* HAS_TEX_3D_CUBE = 0: bits 20, 21 = 0, bits 19, 22 = 1 */
		check_val(fmt0_no_3d[20], 1'b0, "no_3d FMT0[20] 3D is 0");
		check_val(fmt0_no_3d[21], 1'b0, "no_3d FMT0[21] CUBE is 0");
		check_val(fmt0_no_3d[19], 1'b1, "no_3d FMT0[19] ARRAY remains 1");
		check_val(fmt0_no_3d[22], 1'b1, "no_3d FMT0[22] TRILINEAR remains 1");

		/* HAS_TEX_TRILINEAR = 0: bit 22 = 0, bits [21:19] = 1 */
		check_val(fmt0_no_tri[22], 1'b0, "no_tri FMT0[22] TRILINEAR is 0");
		check_val(fmt0_no_tri[21:19], 3'b111, "no_tri FMT0[21:19] remain 1");

		/* ------------------------------------------------------------- */
		/* Test 9: Local memory present (LOCAL_BYTES != 0)               */
		/* ------------------------------------------------------------- */
		/* DEVICE_CAPS[0] UMA must be 0 */
		check_val(dev_caps_mem[0], 1'b0, "local_mem DEVICE_CAPS[0] UMA is 0");
		/* dw 12 MEM_CACHE_CFG must be non-zero */
		r_idx = 9'd12; #1;
		check_val(r_data_mem, 32'h12345678, "local_mem dw12 MEM_CACHE_CFG");
		check_val(mem_cfg_mem, 32'h12345678, "local_mem mem_cache_cfg port");
		/* dw 18 EXTCAP_PRESENT bit 8 (MEM) must be 1 */
		check_val(xcap_mem[8], 1'b1, "local_mem EXTCAP bit 8 MEM is 1");

		/* ------------------------------------------------------------- */
		/* Test 10: Session protection present (HAS_PROT = 1)            */
		/* ------------------------------------------------------------- */
		/* DEVICE_CAPS[24] PROT must be 1 */
		check_val(dev_caps_prot[24], 1'b1, "prot DEVICE_CAPS[24] PROT is 1");
		/* dw 13 PROT_CAPS: {16'd8, 8'd12, 8'd31} = 0x00080C1F */
		r_idx = 9'd13; #1;
		check_val(r_data_prot, 32'h00080C1F, "prot dw13 PROT_CAPS");
		check_val(prot_caps_prot, 32'h00080C1F, "prot prot_caps port");
		/* dw 18 EXTCAP_PRESENT bit 9 (PROT) must be 1 */
		check_val(xcap_prot[9], 1'b1, "prot EXTCAP bit 9 PROT is 1");

		/* ------------------------------------------------------------- */
		/* Completion                                                    */
		/* ------------------------------------------------------------- */
		if (errors == 0)
			$display("PASS atg_cp_caps");
		else
			$display("FAIL atg_cp_caps: %0d errors", errors);
		$finish;
	end

	initial begin
		#10000000;
		$display("FAIL atg_cp_caps: timeout");
		$finish;
	end
endmodule

`default_nettype wire
