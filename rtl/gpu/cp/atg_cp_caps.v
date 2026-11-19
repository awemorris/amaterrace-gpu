/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_caps: CP internal capabilities register block.
 * Authoritative capability block: device identification, feature flags,
 * format capabilities, memory/cache limits, and protection capabilities.
 * Read-only from inside CP (sub-bus for firmware, seq for CMD_QUERY_CAPS).
 *
 * Block layout (version 1, 192 dwords = 768 bytes):
 *  dw 0: BLOCK_ID (0x50414347 "GCAP")
 *  dw 1: BLOCK_INFO ([15:0] version 1, [31:16] BLOCK_DWORDS 192)
 *  dw 2: DEVICE_CAPS ([0] UMA = (LOCAL_BYTES == 0))
 *  dw 3: EXT_CAP_FEATURE
 *  dw 4: EXT_CAP_FMT0 ([19] TEX_ARRAY, [20] TEX_3D, [21] TEX_CUBE, [22] TEX_TRILINEAR)
 *  dw 5: RESIDENT_WARPS ({8'd0, NREGS, RESIDENT_WARPS})
 *  dw 6: NATIVE_ISA_ID (0x47534931 "GSI1")
 *  dw 7: GCLK_HZ
 *  dw 8: VENDOR_ID
 *  dw 9: DEVICE_ID
 *  dw 10: SUBSYSTEM ({SUBSYSTEM_DEVICE, SUBSYSTEM_VENDOR})
 *  dw 11: DEVICE_VERSION
 *  dw 12: MEM_CACHE_CFG
 *  dw 13: PROT_CAPS ({GRANTS, 8'd12, SLOTS})
 *  dw 14: PERF_SRC (PERF_SRC0..3)
 *  dw 15: FMT_LIMITS ([3:0] colour attachments = MRT_COUNT)
 *  dw 16: FMT_FIRST (32)
 *  dw 17: FMT_COUNT (157)
 *  dw 18: EXTCAP_PRESENT (bit n = capability ID n present)
 *  dw 19..31: Reserved (0)
 *  dw 32..188: FMT[v] (VkFormat v = 0..156 capabilities:
 *               [8:0] OPTIMAL, [17:9] LINEAR,
 *               [21:18] BUFFER bits 3..6, [31:22] 0)
 *  dw 189..191: Padding (0)
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_caps #(
	parameter GCLK_HZ = 32'd0,
	parameter VENDOR_ID = 32'h414D4154,	/* "AMAT" */
	parameter DEVICE_ID = 32'h41544731,	/* "ATG1" */
	parameter DEVICE_VERSION = 32'h00000002,
	parameter NATIVE_ISA_ID = 32'h47534931,	/* "GSI1" */
	parameter [15:0] RESIDENT_WARPS = 16'd0,
	parameter [7:0] NREGS = 8'd0,
	parameter [31:0] LOCAL_BASE = 32'd0,
	parameter [31:0] LOCAL_BYTES = 32'd0,
	parameter [31:0] WINDOW_BYTES = 32'd0,
	parameter [31:0] HOST_LIMIT = 32'd0,
	parameter [15:0] SUBSYSTEM_VENDOR = 16'h0000,
	parameter [15:0] SUBSYSTEM_DEVICE = 16'h0000,
	parameter [31:0] MEM_CACHE_CFG = 32'd0,
	parameter [3:0] MRT_COUNT = 4'd1,
	parameter VA_BITS = 32,
	parameter PA_BITS = 40,
	parameter NSU = 0,
`ifdef CFG_SU_NPHYS
	parameter SU_NPHYS = `CFG_SU_NPHYS,
`else
	parameter SU_NPHYS = 8,
`endif
	parameter SU_PACKED = 0,
	parameter SU_SUBGROUP = 0,
	parameter SU_LDS_KB = 0,
	parameter HAS_BLT = 0,
	parameter BLT_SCALE = 1,
	parameter BLT_BLEND = 1,
	parameter BLT_TILE = 1,
	parameter HAS_DISP = 0,
	parameter DC_HAS_CURSOR = 0,
	parameter HAS_TU = 0,
	parameter TU_BILINEAR = 0,
	parameter HAS_FFILT = 0,
	parameter HAS_ROP = 0,
	parameter HAS_ROP_PACK = 0,
	parameter HAS_D16 = 0,
	parameter HAS_D24S8 = 0,
	parameter HAS_D32F = 0,
	parameter HAS_STENCIL = 0,
	parameter HAS_FBLEND = 0,
	parameter HAS_VF = 0,
	parameter HAS_TEX_ARRAY = 1,
	parameter HAS_TEX_3D_CUBE = 1,
	parameter HAS_TEX_TRILINEAR = 1,
	parameter HAS_FMT_SRGB = 1,
	parameter HAS_FMT_RGB565 = 1,
	parameter HAS_MESH = 0,
	parameter HAS_ETC = 0,
	parameter MS4 = 0,
	parameter HAS_PROT = 0,
	parameter [7:0] PROT_SLOTS = 8'd31,
	parameter [15:0] PROT_GRANTS = 16'd8,
	parameter HAS_INDIRECT_DRAW = 0,
	parameter HAS_SECONDARY_RING = 0,
	parameter HAS_HW_WALKER = 0,
	parameter HAS_CPU = 0,
	parameter HAS_DBG = 0,
	parameter HAS_SA = 0,
	parameter [10:0] XCAP_MASK = 11'd0,
	parameter [31:0] PERF_SRC = 32'hFFFF0801,
	parameter RX_ENABLE_CPOLY = 1,
	parameter RX_ENABLE_EARLY_Z = 0,
	parameter RX_COARSE_SCAN = 0,
	parameter ROP_FAST_CLEAR = 0,
	parameter ROP_ENABLE_LOGICOP = 0,
	parameter ROP_DUAL_SOURCE = 0
) (
	/* Clock & reset (for future synchronous ports/arbitration) */
	input wire clk,
	input wire rst_n,

	/* Read port for block words (index 0..191) */
	input wire [8:0] r_idx,
	output reg [31:0] r_data,

	/* Constant / direct outputs */
	output wire [31:0] boot_caps,
	output wire [31:0] device_caps,
	output wire [31:0] ext_cap_feature,
	output wire [31:0] ext_cap_fmt0,
	output wire [31:0] resident_warps,
	output wire [31:0] native_isa_id,
	output wire [31:0] gclk_hz,
	output wire [31:0] vendor_id,
	output wire [31:0] device_id,
	output wire [31:0] subsystem,
	output wire [31:0] device_version,
	output wire [31:0] mem_cache_cfg,
	output wire [31:0] prot_caps,
	output wire [31:0] perf_src,
	output wire [31:0] fmt_limits,
	output wire [31:0] extcap_present,

	/* Format capability lookup port (for atg_cp_fmt) */
	input wire [7:0] fmt_idx,
	output wire [31:0] fmt_val
);
	`include "atg_fmt_info.vh"

	/* Address width offset encodings */
	localparam [31:0] RAW_VA_ENC = (VA_BITS >= 30) ? (VA_BITS - 30) : 0;
	localparam [3:0] CALC_VA_ENC = RAW_VA_ENC[3:0];
	localparam [31:0] RAW_PA_ENC = (PA_BITS >= 40) ? (PA_BITS - 40) : 0;
	localparam [3:0] CALC_PA_ENC = RAW_PA_ENC[3:0];

	/* BOOT_CAPS */
	wire [31:0] calc_boot_caps = {
		16'd0,
		CALC_PA_ENC,
		CALC_VA_ENC,
		5'd0,
		(HAS_PROT != 0) ? 1'b1 : 1'b0,
		(HAS_HW_WALKER != 0) ? 1'b1 : 1'b0,
		1'b1
	};

	/* DEVICE_CAPS (device architecture capabilities) */
	wire [31:0] calc_device_caps = {
		(MS4 != 0) ? 1'b1 : 1'b0,                  /* [31] MSAA */
		(HAS_DISP != 0) ? 1'b1 : 1'b0,             /* [30] DISP */
		(HAS_BLT != 0) ? 1'b1 : 1'b0,              /* [29] BLT */
		(HAS_MESH != 0) ? 1'b1 : 1'b0,             /* [28] MESH */
		(HAS_MESH != 0) ? 1'b1 : 1'b0,             /* [27] TASK (mirrors MESH) */
		((HAS_ROP_PACK != 0) && (HAS_ROP != 0)) ? 1'b1 : 1'b0, /* [26] ROP_PACK */
		(HAS_FFILT != 0) ? 1'b1 : 1'b0,             /* [25] FFILT */
		(HAS_PROT != 0) ? 1'b1 : 1'b0,             /* [24] PROT */
		NSU[7:0],                                  /* [23:16] NUM_SU */
		SU_NPHYS[7:0],                             /* [15:8] PHYS_LANES */
		1'b1,                                      /* [7] GSI1 (Fixed 1) */
		((NSU != 0) ? (SU_PACKED != 0) : 1'b0) ? 1'b1 : 1'b0, /* [6] FP16 */
		((HAS_ROP != 0) && (ROP_DUAL_SOURCE != 0)) ? 1'b1 : 1'b0, /* [5] DUAL_SRC */
		(HAS_SECONDARY_RING != 0) ? 1'b1 : 1'b0,   /* [4] SECONDARY_RING */
		(HAS_INDIRECT_DRAW != 0) ? 1'b1 : 1'b0,    /* [3] INDIRECT_DRAW */
		(HAS_HW_WALKER != 0) ? 1'b1 : 1'b0,        /* [2] HW_WALKER */
		1'b0,                                      /* [1] IOMMU */
		(LOCAL_BYTES == 32'd0) ? 1'b1 : 1'b0       /* [0] UMA */
	};

	/* EXT_CAP_FEATURE (extended feature register) */
	wire [31:0] calc_ext_cap_feature = {
		((HAS_BLT != 0) && (BLT_SCALE != 0)) ? 1'b1 : 1'b0, /* [31] BLT_SCALE */
		(RX_ENABLE_CPOLY != 0) ? 1'b1 : 1'b0,      /* [30] CLIP_POLY */
		((NSU != 0) && (SU_SUBGROUP != 0)) ? 1'b1 : 1'b0, /* [29] SUBGROUP */
		((NSU != 0) ? (SU_PACKED != 0) : 1'b0) ? 1'b1 : 1'b0, /* [28] FP16 */
		(NSU != 0) ? SU_LDS_KB[7:0] : 8'd0,        /* [27:20] LDS_KB */
		MRT_COUNT[3:0],                            /* [19:16] MAX_MRT */
		(MRT_COUNT >= 4'd2) ? 1'b1 : 1'b0,         /* [15] MRT_BLEND */
		1'b0,                                      /* [14] COLOR_LUT */
		((HAS_DISP != 0) && (DC_HAS_CURSOR != 0)) ? 1'b1 : 1'b0, /* [13] CURSOR */
		(RX_ENABLE_EARLY_Z != 0) ? 1'b1 : 1'b0,    /* [12] EARLY_Z */
		(ROP_ENABLE_LOGICOP != 0) ? 1'b1 : 1'b0,   /* [11] LOGICOP */
		(ROP_FAST_CLEAR != 0) ? 1'b1 : 1'b0,       /* [10] FAST_CLEAR */
		(RX_COARSE_SCAN != 0) ? 1'b1 : 1'b0,       /* [9] COARSE_SCAN */
		((HAS_ROP != 0) && (ROP_DUAL_SOURCE != 0)) ? 1'b1 : 1'b0, /* [8] DUAL_SRC */
		CALC_PA_ENC,                               /* [7:4] PA_BITS_ENC */
		CALC_VA_ENC                                /* [3:0] VA_BITS_ENC */
	};

	/* EXT_CAP_FMT0 (format feature summary register) */
	wire [31:0] calc_ext_cap_fmt0 = {
		9'd0,                                      /* [31:23] reserved */
		((HAS_TU != 0) && (HAS_TEX_TRILINEAR != 0)) ? 1'b1 : 1'b0, /* [22] TEX_TRILINEAR */
		((HAS_TU != 0) && (HAS_TEX_3D_CUBE != 0)) ? 1'b1 : 1'b0,  /* [21] TEX_CUBE */
		((HAS_TU != 0) && (HAS_TEX_3D_CUBE != 0)) ? 1'b1 : 1'b0,  /* [20] TEX_3D */
		((HAS_TU != 0) && (HAS_TEX_ARRAY != 0)) ? 1'b1 : 1'b0,    /* [19] TEX_ARRAY */
		((HAS_BLT != 0) && (BLT_TILE != 0)) ? 1'b1 : 1'b0,        /* [18] BLT_TILE */
		((HAS_BLT != 0) && (BLT_BLEND != 0)) ? 1'b1 : 1'b0,       /* [17] BLT_BLEND */
		((HAS_TU != 0) && (TU_BILINEAR != 0)) ? 1'b1 : 1'b0,      /* [16] TU_BILINEAR */
		MRT_COUNT[3:0],                            /* [15:12] MAX_MRT */
		1'b0,                                      /* [11] reserved (0 in ATG1) */
		(HAS_FFILT != 0) ? 1'b1 : 1'b0,            /* [10] FFILT_FP16 */
		(HAS_FMT_SRGB != 0) ? 1'b1 : 1'b0,         /* [9] SRGB */
		1'b0,                                      /* [8] ASTC */
		(HAS_ETC != 0) ? 1'b1 : 1'b0,              /* [7] ETC2 */
		7'd0                                       /* [6:0] BC */
	};

	/* Memory cache config */
`ifdef CFG_VF_CACHE_LINES
`define ATG_CAPS_DEF_VF_CACHE_LINES 4'd`CFG_VF_CACHE_LINES
`else
`define ATG_CAPS_DEF_VF_CACHE_LINES 4'd0
`endif

`ifdef CFG_TU_L1_CACHE_KB
`define ATG_CAPS_DEF_TU_L1_CACHE_KB 4'd`CFG_TU_L1_CACHE_KB
`else
`define ATG_CAPS_DEF_TU_L1_CACHE_KB 4'd0
`endif

`ifdef CFG_MC_L2_WAYS
`define ATG_CAPS_DEF_MC_L2_WAYS 8'd`CFG_MC_L2_WAYS
`else
`define ATG_CAPS_DEF_MC_L2_WAYS 8'd0
`endif

`ifdef CFG_MC_L2_CACHE_KB
`define ATG_CAPS_DEF_MC_L2_CACHE_KB 16'd`CFG_MC_L2_CACHE_KB
`else
`define ATG_CAPS_DEF_MC_L2_CACHE_KB 16'd0
`endif

	wire [31:0] eff_mem_cache_cfg = (MEM_CACHE_CFG != 32'd0) ? MEM_CACHE_CFG : {
		`ATG_CAPS_DEF_VF_CACHE_LINES, `ATG_CAPS_DEF_TU_L1_CACHE_KB,
		`ATG_CAPS_DEF_MC_L2_WAYS, `ATG_CAPS_DEF_MC_L2_CACHE_KB
	};
	wire [31:0] calc_mem_cache_cfg = eff_mem_cache_cfg;

	/* Session protection caps */
	wire [31:0] calc_prot_caps = (HAS_PROT != 0) ? {PROT_GRANTS[15:0], 8'd12, PROT_SLOTS[7:0]} : 32'd0;

	/* Capability presence mask (dw 18: bit n = capability ID n present) */
	wire [10:0] eff_xcap = (XCAP_MASK != 11'd0) ? XCAP_MASK : (
		11'h004 | 11'h008 |
		(HAS_CPU != 0 ? 11'h020 : 11'h000) |
		(HAS_DISP != 0 ? 11'h400 : 11'h000) |
		(HAS_DBG != 0 ? 11'h002 : 11'h000) |
		(LOCAL_BYTES != 32'd0 ? 11'h080 : 11'h000) |
		11'h200 |
		(HAS_PROT != 0 ? 11'h100 : 11'h000) |
		(HAS_SA != 0 ? 11'h040 : 11'h000)
	);
	wire [31:0] calc_extcap_present = {20'd0, eff_xcap, 1'b0};

	/* Format capability word function (OPTIMAL, LINEAR, BUFFER features) */
	function [31:0] calc_fmt_word;
		input [7:0] fv;
		reg [25:0] f_feat;
		reg [67:0] f_info;
		reg f_is_fp;
		reg f_is_p2;
		reg f_is_fblend;
		reg f_base_filter_linear;
		reg f_base_color_att;
		reg f_base_blend;
		reg f_base_blit_dst;
		reg f_base_depth_stencil;
		reg f_eff_sample;
		reg f_eff_filter_linear;
		reg f_eff_blit_src;
		reg f_eff_color_att;
		reg f_eff_blend;
		reg f_eff_depth_stencil;
		reg f_eff_blit_dst;
		reg f_eff_vertex_buffer;
		reg [8:0] f_opt_flags;
		reg [3:0] f_buf_flags;
		begin
			if (fv >= 8'd157) begin
				calc_fmt_word = 32'd0;
			end else if ((HAS_FMT_SRGB == 0) &&
			             (fv == 8'd43 || fv == 8'd50 || fv == 8'd57 ||
			              fv == 8'd148 || fv == 8'd150 || fv == 8'd152)) begin
				calc_fmt_word = 32'd0;
			end else if ((HAS_FMT_RGB565 == 0) &&
			             (fv == 8'd3 || fv == 8'd4 || fv == 8'd8)) begin
				calc_fmt_word = 32'd0;
			end else begin
				f_feat = atg_fmt_feat(fv, HAS_ETC != 0);
				f_info = atg_fmt_info(fv);
				f_is_fp = (f_info[11:9] == ATG_FMT_SFLOAT && !f_info[12]);
				f_is_p2 = (f_info[11:9] == ATG_FMT_UINT || f_info[11:9] == ATG_FMT_SINT ||
				           fv == 8'd100 || fv == 8'd103 || fv == 8'd109);
				f_is_fblend = (fv == 8'd43 || fv == 8'd50 || fv == 8'd57 || fv == 8'd64 ||
				               fv == 8'd76 || fv == 8'd83 || fv == 8'd97);

				f_base_filter_linear = f_feat[12] && (TU_BILINEAR != 0) && (!f_is_fp || (HAS_FFILT != 0));
				f_base_color_att = f_feat[7] && (!f_is_p2 || (HAS_ROP_PACK != 0)) && (!f_is_fblend || (HAS_FBLEND != 0));
				f_base_blend = f_feat[8] && (!f_is_p2 || (HAS_ROP_PACK != 0)) && (!f_is_fblend || (HAS_FBLEND != 0));
				f_base_blit_dst = f_feat[11] && (!f_is_p2 || (HAS_ROP_PACK != 0)) && (!f_is_fblend || (HAS_FBLEND != 0));
				f_base_depth_stencil =
					(fv == 8'd124) ? (f_feat[9] && (HAS_D16 != 0)) :
					(fv == 8'd125) ? (f_feat[9] && (HAS_D24S8 != 0)) :
					(fv == 8'd129) ? (f_feat[9] && (HAS_D24S8 != 0) && (HAS_STENCIL != 0)) :
					(fv == 8'd126) ? (f_feat[9] && (HAS_D32F != 0)) :
					f_feat[9];

				f_eff_sample = f_feat[0] && (HAS_TU != 0);
				f_eff_filter_linear = f_base_filter_linear && (HAS_TU != 0);
				f_eff_blit_src = f_feat[10] && (HAS_TU != 0);

				f_eff_color_att = f_base_color_att && (HAS_ROP != 0);
				f_eff_blend = f_base_blend && (HAS_ROP != 0);
				f_eff_depth_stencil = f_base_depth_stencil && (HAS_ROP != 0);
				f_eff_blit_dst = f_base_blit_dst && (HAS_ROP != 0);

				f_eff_vertex_buffer = f_feat[19] && (HAS_VF != 0);

				f_opt_flags = {
					1'b0,
					f_eff_blit_dst,
					f_eff_blit_src,
					f_eff_vertex_buffer,
					f_eff_depth_stencil,
					f_eff_blend,
					f_eff_color_att,
					f_eff_filter_linear,
					f_eff_sample
				};

				f_buf_flags = {
					f_eff_vertex_buffer,
					1'b0,
					1'b0,
					1'b0
				};

				calc_fmt_word = {
					10'd0,
					f_buf_flags,
					f_opt_flags,
					f_opt_flags
				};
			end
		end
	endfunction

	/* Constant outputs */
	assign boot_caps = calc_boot_caps;
	assign device_caps = calc_device_caps;
	assign ext_cap_feature = calc_ext_cap_feature;
	assign ext_cap_fmt0 = calc_ext_cap_fmt0;
	assign resident_warps = {8'd0, NREGS[7:0], RESIDENT_WARPS[15:0]};
	assign native_isa_id = NATIVE_ISA_ID;
	assign gclk_hz = GCLK_HZ;
	assign vendor_id = VENDOR_ID;
	assign device_id = DEVICE_ID;
	assign subsystem = {SUBSYSTEM_DEVICE[15:0], SUBSYSTEM_VENDOR[15:0]};
	assign device_version = DEVICE_VERSION;
	assign mem_cache_cfg = calc_mem_cache_cfg;
	assign prot_caps = calc_prot_caps;
	assign perf_src = PERF_SRC;
	assign fmt_limits = {28'd0, MRT_COUNT[3:0]};
	assign extcap_present = calc_extcap_present;

	/* Format query port */
	assign fmt_val = calc_fmt_word(fmt_idx);

	/* Parameter-constant ROM for format dwords (indexed by r_idx[7:0], valid 32..188) */
	(* rom_style = "distributed" *) reg [31:0] caps_fmt_rom [0:255];
	integer ci;
	initial begin
		for (ci = 0; ci < 256; ci = ci + 1)
			caps_fmt_rom[ci] = 32'd0;
		for (ci = 0; ci < 32; ci = ci + 1) begin
			caps_fmt_rom[{3'd1, ci[4:0]}] = calc_fmt_word({3'd0, ci[4:0]});
			caps_fmt_rom[{3'd2, ci[4:0]}] = calc_fmt_word({3'd1, ci[4:0]});
			caps_fmt_rom[{3'd3, ci[4:0]}] = calc_fmt_word({3'd2, ci[4:0]});
			caps_fmt_rom[{3'd4, ci[4:0]}] = calc_fmt_word({3'd3, ci[4:0]});
			caps_fmt_rom[{3'd5, ci[4:0]}] = calc_fmt_word({3'd4, ci[4:0]});
		end
	end

	wire [31:0] fmt_rom_word = caps_fmt_rom[r_idx[7:0]];

	/* Block dwords multiplexer */
	always @(*) begin
		if (r_idx[8]) begin
			r_data = 32'd0;
		end else if (r_idx[7:5] == 3'd0) begin
			case (r_idx[4:0])
			5'd0:  r_data = 32'h50414347;	/* BLOCK_ID ("GCAP") */
			5'd1:  r_data = {16'd192, 16'd1};	/* BLOCK_INFO: 192 dwords, version 1 */
			5'd2:  r_data = calc_device_caps;
			5'd3:  r_data = calc_ext_cap_feature;
			5'd4:  r_data = calc_ext_cap_fmt0;
			5'd5:  r_data = {8'd0, NREGS[7:0], RESIDENT_WARPS[15:0]};
			5'd6:  r_data = NATIVE_ISA_ID;
			5'd7:  r_data = GCLK_HZ;
			5'd8:  r_data = VENDOR_ID;
			5'd9:  r_data = DEVICE_ID;
			5'd10: r_data = {SUBSYSTEM_DEVICE[15:0], SUBSYSTEM_VENDOR[15:0]};
			5'd11: r_data = DEVICE_VERSION;
			5'd12: r_data = calc_mem_cache_cfg;
			5'd13: r_data = calc_prot_caps;
			5'd14: r_data = PERF_SRC;
			5'd15: r_data = {28'd0, MRT_COUNT[3:0]};
			5'd16: r_data = 32'd32;	/* FMT_FIRST */
			5'd17: r_data = 32'd157;	/* FMT_COUNT */
			5'd18: r_data = calc_extcap_present;
			default: r_data = 32'd0;	/* dw 19..31 reserved */
			endcase
		end else begin
			r_data = fmt_rom_word;	/* dw 32..188 populated, 189..255 zero */
		end
	end

	wire unused_ok = &{1'b0, clk, rst_n};
endmodule

`default_nettype wire
