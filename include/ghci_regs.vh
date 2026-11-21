/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci_regs.vh: the GHCI 1.0 host control register offsets and fields
 * (docs/ghci.md), for the RTL.  Included inside a module body; every name
 * is a localparam.  include/ghci_regs.h holds the same values for C.
 * A module uses only some of them, so Verilator's unused-parameter
 * warning is off inside this file.
 */

/* verilator lint_off UNUSEDPARAM */

/* Identification. */
localparam [31:0] GHCI_MAGIC_VALUE = 32'h47484349;	/* "GHCI" */
localparam [15:0] GHCI_VERSION_MAJOR = 16'd1;
localparam [15:0] GHCI_VERSION_MINOR = 16'd0;

/*
 * ============================================================================
 * GHCI 1.0 Control-Path MMIO Registers (0x000 - 0x1FF; 0x200 - 0xFFF Reserved)
 * ============================================================================
 */
localparam [16:0] GHCI_REG_MAGIC              = 17'h00000;
localparam [16:0] GHCI_REG_VERSION            = 17'h00004;
localparam [16:0] GHCI_REG_BOOT_CAPS          = 17'h00008;
localparam [16:0] GHCI_REG_RESERVED_00C       = 17'h0000C;
localparam [16:0] GHCI_REG_STATUS             = 17'h00010;
localparam [16:0] GHCI_REG_CTRL               = 17'h00014;
localparam [16:0] GHCI_REG_FAULT_INFO         = 17'h00018;
localparam [16:0] GHCI_REG_FAULT_ADDR_LO      = 17'h0001C;
localparam [16:0] GHCI_REG_FAULT_ADDR_HI      = 17'h00020;
localparam [16:0] GHCI_REG_RING_BASE_LO       = 17'h00024;
localparam [16:0] GHCI_REG_RING_BASE_HI       = 17'h00028;
localparam [16:0] GHCI_REG_RING_SIZE          = 17'h0002C;
localparam [16:0] GHCI_REG_RING_WPTR          = 17'h00030;
localparam [16:0] GHCI_REG_RING_RPTR          = 17'h00034;
localparam [16:0] GHCI_REG_IRQ_STATUS         = 17'h00038;
localparam [16:0] GHCI_REG_IRQ_ENABLE         = 17'h0003C;
localparam [16:0] GHCI_REG_RESERVED_040       = 17'h00040;
localparam [16:0] GHCI_REG_RESERVED_044       = 17'h00044;
localparam [16:0] GHCI_REG_WDT_CYCLES         = 17'h00048;
localparam [16:0] GHCI_REG_RESERVED_04C       = 17'h0004C;
localparam [16:0] GHCI_REG_RESERVED_050       = 17'h00050;
localparam [16:0] GHCI_REG_RESERVED_054       = 17'h00054;
localparam [16:0] GHCI_REG_SESSION_ACTIVE     = 17'h00058;
localparam [16:0] GHCI_REG_RESERVED_05C       = 17'h0005C;
localparam [16:0] GHCI_REG_RESERVED_060       = 17'h00060;
localparam [16:0] GHCI_REG_RESERVED_064       = 17'h00064;
localparam [16:0] GHCI_REG_RESERVED_068       = 17'h00068;
localparam [16:0] GHCI_REG_RESERVED_074       = 17'h00074;
localparam [16:0] GHCI_REG_RESERVED_078       = 17'h00078;
localparam [16:0] GHCI_REG_RESERVED_080       = 17'h00080;
localparam [16:0] GHCI_REG_RESERVED_084       = 17'h00084;

/* MEM Control-Path Window (0x100 - 0x13F) */
localparam [16:0] GHCI_REG_MEM_VRAM_BASE_LO    = 17'h00100;
localparam [16:0] GHCI_REG_MEM_VRAM_BASE_HI    = 17'h00104;
localparam [16:0] GHCI_REG_MEM_VRAM_SIZE_LO    = 17'h00108;
localparam [16:0] GHCI_REG_MEM_VRAM_SIZE_HI    = 17'h0010C;
localparam [16:0] GHCI_REG_MEM_FW_VRAM_BASE_LO = 17'h00110;
localparam [16:0] GHCI_REG_MEM_FW_VRAM_BASE_HI = 17'h00114;
localparam [16:0] GHCI_REG_MEM_FW_VRAM_SIZE_LO = 17'h00118;
localparam [16:0] GHCI_REG_MEM_FW_VRAM_SIZE_HI = 17'h0011C;
localparam [16:0] GHCI_REG_MEM_HOST_LIMIT_LO   = 17'h00120;
localparam [16:0] GHCI_REG_MEM_HOST_LIMIT_HI   = 17'h00124;
localparam [16:0] GHCI_REG_MEM_WINDOW_SIZE_LO  = 17'h00128;
localparam [16:0] GHCI_REG_MEM_WINDOW_SIZE_HI  = 17'h0012C;
localparam [16:0] GHCI_REG_MEM_WINDOW_CTRL     = 17'h00130;

/* BOOT_DISP Read-Only Window (0x140 - 0x15F, PCIe binding only) */
localparam [16:0] GHCI_REG_BOOT_DISP_STATUS       = 17'h00140;
localparam [16:0] GHCI_REG_BOOT_DISP_FORMAT       = 17'h00144;
localparam [16:0] GHCI_REG_BOOT_DISP_WIDTH        = 17'h00148;
localparam [16:0] GHCI_REG_BOOT_DISP_HEIGHT       = 17'h0014C;
localparam [16:0] GHCI_REG_BOOT_DISP_STRIDE       = 17'h00150;
localparam [16:0] GHCI_REG_RESERVED_154           = 17'h00154;
localparam [16:0] GHCI_REG_BOOT_DISP_FB_OFFSET_LO = 17'h00158;
localparam [16:0] GHCI_REG_BOOT_DISP_FB_OFFSET_HI = 17'h0015C;

/* PROT Control-Path Window (0x1D0 - 0x1DF) */
localparam [16:0] GHCI_REG_PROT_CAPS          = 17'h001D0;
localparam [16:0] GHCI_REG_PROT_TABLE_BYTES   = 17'h001D4;
localparam [16:0] GHCI_REG_PROT_TABLE_LO      = 17'h001D8;
localparam [16:0] GHCI_REG_PROT_TABLE_HI      = 17'h001DC;

/*
 * ============================================================================
 * Capability Block Word Indices (accessed via CMD_QUERY_CAPS packet)
 * ============================================================================
 */
localparam [8:0] GHCI_CAP_WORD_BLOCK_ID        = 9'd0;
localparam [8:0] GHCI_CAP_WORD_BLOCK_INFO      = 9'd1;
localparam [8:0] GHCI_CAP_WORD_DEVICE_CAPS     = 9'd2;
localparam [8:0] GHCI_CAP_WORD_EXT_CAP_FEATURE = 9'd3;
localparam [8:0] GHCI_CAP_WORD_EXT_CAP_FMT0    = 9'd4;
localparam [8:0] GHCI_CAP_WORD_RESIDENT_WARPS  = 9'd5;
localparam [8:0] GHCI_CAP_WORD_NATIVE_ISA_ID   = 9'd6;
localparam [8:0] GHCI_CAP_WORD_GCLK_HZ         = 9'd7;
localparam [8:0] GHCI_CAP_WORD_VENDOR_ID       = 9'd8;
localparam [8:0] GHCI_CAP_WORD_DEVICE_ID       = 9'd9;
localparam [8:0] GHCI_CAP_WORD_SUBSYSTEM       = 9'd10;
localparam [8:0] GHCI_CAP_WORD_DEVICE_VERSION  = 9'd11;
localparam [8:0] GHCI_CAP_WORD_MEM_CACHE_CFG   = 9'd12;
localparam [8:0] GHCI_CAP_WORD_PROT_CAPS       = 9'd13;
localparam [8:0] GHCI_CAP_WORD_PERF_SRC        = 9'd14;
localparam [8:0] GHCI_CAP_WORD_FMT_LIMITS      = 9'd15;
localparam [8:0] GHCI_CAP_WORD_FMT_FIRST_REG   = 9'd16;
localparam [8:0] GHCI_CAP_WORD_FMT_COUNT       = 9'd17;
localparam [8:0] GHCI_CAP_WORD_EXTCAP_PRESENT  = 9'd18;
localparam [8:0] GHCI_CAP_WORD_SHADER_STAGES     = 9'd19;
localparam [8:0] GHCI_CAP_WORD_STAGE_LIMITS      = 9'd20;
localparam [8:0] GHCI_CAP_WORD_DISP_PCLK_MIN_KHZ = 9'd21;
localparam [8:0] GHCI_CAP_WORD_DISP_PCLK_MAX_KHZ = 9'd22;
localparam [8:0] GHCI_CAP_WORD_DISP_PCLK_INFO    = 9'd23;
localparam [8:0] GHCI_CAP_WORD_DISP_LIMITS_H     = 9'd24;
localparam [8:0] GHCI_CAP_WORD_DISP_LIMITS_V     = 9'd25;
localparam [8:0] GHCI_CAP_WORD_DISP_MIN_H_BLANK  = 9'd28;
localparam [8:0] GHCI_CAP_WORD_DISP_MIN_V_BLANK  = 9'd29;
localparam [8:0] GHCI_CAP_WORD_TIMESTAMP_HZ      = 9'd30;
localparam [8:0] GHCI_CAP_WORD_FMT_BASE          = 9'd32;

/* Capability word alias */
localparam [8:0] GHCI_CAP_DEVICE_CAPS          = 9'd2;

/*
 * ============================================================================
 * Canonical HCR Register Indices (Control-Path MMIO, 10-bit word offset)
 * ============================================================================
 */
localparam [9:0] HCR_IDX_MAGIC               = GHCI_REG_MAGIC[11:2];               /* 0   (0x000) */
localparam [9:0] HCR_IDX_VERSION             = GHCI_REG_VERSION[11:2];             /* 1   (0x004) */
localparam [9:0] HCR_IDX_BOOT_CAPS           = GHCI_REG_BOOT_CAPS[11:2];           /* 2   (0x008) */
localparam [9:0] HCR_IDX_STATUS              = GHCI_REG_STATUS[11:2];              /* 4   (0x010) */
localparam [9:0] HCR_IDX_CTRL                = GHCI_REG_CTRL[11:2];                /* 5   (0x014) */
localparam [9:0] HCR_IDX_FAULT_INFO          = GHCI_REG_FAULT_INFO[11:2];          /* 6   (0x018) */
localparam [9:0] HCR_IDX_FAULT_ADDR_LO       = GHCI_REG_FAULT_ADDR_LO[11:2];       /* 7   (0x01C) */
localparam [9:0] HCR_IDX_FAULT_ADDR_HI       = GHCI_REG_FAULT_ADDR_HI[11:2];       /* 8   (0x020) */
localparam [9:0] HCR_IDX_RING_BASE_LO        = GHCI_REG_RING_BASE_LO[11:2];        /* 9   (0x024) */
localparam [9:0] HCR_IDX_RING_BASE_HI        = GHCI_REG_RING_BASE_HI[11:2];        /* 10  (0x028) */
localparam [9:0] HCR_IDX_RING_SIZE           = GHCI_REG_RING_SIZE[11:2];           /* 11  (0x02C) */
localparam [9:0] HCR_IDX_RING_WPTR           = GHCI_REG_RING_WPTR[11:2];           /* 12  (0x030) */
localparam [9:0] HCR_IDX_RING_RPTR           = GHCI_REG_RING_RPTR[11:2];           /* 13  (0x034) */
localparam [9:0] HCR_IDX_IRQ_STATUS          = GHCI_REG_IRQ_STATUS[11:2];          /* 14  (0x038) */
localparam [9:0] HCR_IDX_IRQ_ENABLE          = GHCI_REG_IRQ_ENABLE[11:2];          /* 15  (0x03C) */
localparam [9:0] HCR_IDX_WDT_CYCLES          = GHCI_REG_WDT_CYCLES[11:2];          /* 18  (0x048) */
localparam [9:0] HCR_IDX_SESSION_ACTIVE      = GHCI_REG_SESSION_ACTIVE[11:2];      /* 22  (0x058) */
localparam [9:0] HCR_IDX_MEM_VRAM_BASE_LO    = GHCI_REG_MEM_VRAM_BASE_LO[11:2];    /* 64  (0x100) */
localparam [9:0] HCR_IDX_MEM_VRAM_BASE_HI    = GHCI_REG_MEM_VRAM_BASE_HI[11:2];    /* 65  (0x104) */
localparam [9:0] HCR_IDX_MEM_VRAM_SIZE_LO    = GHCI_REG_MEM_VRAM_SIZE_LO[11:2];    /* 66  (0x108) */
localparam [9:0] HCR_IDX_MEM_VRAM_SIZE_HI    = GHCI_REG_MEM_VRAM_SIZE_HI[11:2];    /* 67  (0x10C) */
localparam [9:0] HCR_IDX_MEM_FW_VRAM_BASE_LO = GHCI_REG_MEM_FW_VRAM_BASE_LO[11:2]; /* 68  (0x110) */
localparam [9:0] HCR_IDX_MEM_FW_VRAM_BASE_HI = GHCI_REG_MEM_FW_VRAM_BASE_HI[11:2]; /* 69  (0x114) */
localparam [9:0] HCR_IDX_MEM_FW_VRAM_SIZE_LO = GHCI_REG_MEM_FW_VRAM_SIZE_LO[11:2]; /* 70  (0x118) */
localparam [9:0] HCR_IDX_MEM_FW_VRAM_SIZE_HI = GHCI_REG_MEM_FW_VRAM_SIZE_HI[11:2]; /* 71  (0x11C) */
localparam [9:0] HCR_IDX_MEM_HOST_LIMIT_LO   = GHCI_REG_MEM_HOST_LIMIT_LO[11:2];   /* 72  (0x120) */
localparam [9:0] HCR_IDX_MEM_HOST_LIMIT_HI   = GHCI_REG_MEM_HOST_LIMIT_HI[11:2];   /* 73  (0x124) */
localparam [9:0] HCR_IDX_MEM_WINDOW_SIZE_LO  = GHCI_REG_MEM_WINDOW_SIZE_LO[11:2];  /* 74  (0x128) */
localparam [9:0] HCR_IDX_MEM_WINDOW_SIZE_HI  = GHCI_REG_MEM_WINDOW_SIZE_HI[11:2];  /* 75  (0x12C) */
localparam [9:0] HCR_IDX_MEM_WINDOW_CTRL     = GHCI_REG_MEM_WINDOW_CTRL[11:2];     /* 76  (0x130) */
localparam [9:0] HCR_IDX_BOOT_DISP_STATUS       = GHCI_REG_BOOT_DISP_STATUS[11:2];       /* 80  (0x140) */
localparam [9:0] HCR_IDX_BOOT_DISP_FORMAT       = GHCI_REG_BOOT_DISP_FORMAT[11:2];       /* 81  (0x144) */
localparam [9:0] HCR_IDX_BOOT_DISP_WIDTH        = GHCI_REG_BOOT_DISP_WIDTH[11:2];        /* 82  (0x148) */
localparam [9:0] HCR_IDX_BOOT_DISP_HEIGHT       = GHCI_REG_BOOT_DISP_HEIGHT[11:2];       /* 83  (0x14C) */
localparam [9:0] HCR_IDX_BOOT_DISP_STRIDE       = GHCI_REG_BOOT_DISP_STRIDE[11:2];       /* 84  (0x150) */
localparam [9:0] HCR_IDX_BOOT_DISP_FB_OFFSET_LO = GHCI_REG_BOOT_DISP_FB_OFFSET_LO[11:2]; /* 86  (0x158) */
localparam [9:0] HCR_IDX_BOOT_DISP_FB_OFFSET_HI = GHCI_REG_BOOT_DISP_FB_OFFSET_HI[11:2]; /* 87  (0x15C) */
localparam [9:0] HCR_IDX_PROT_CAPS           = GHCI_REG_PROT_CAPS[11:2];           /* 116 (0x1D0) */
localparam [9:0] HCR_IDX_PROT_TABLE_BYTES    = GHCI_REG_PROT_TABLE_BYTES[11:2];    /* 117 (0x1D4) */
localparam [9:0] HCR_IDX_PROT_TABLE_LO       = GHCI_REG_PROT_TABLE_LO[11:2];       /* 118 (0x1D8) */
localparam [9:0] HCR_IDX_PROT_TABLE_HI       = GHCI_REG_PROT_TABLE_HI[11:2];       /* 119 (0x1DC) */
localparam [9:0] HCR_IDX_INVALID             = 10'h3FF;

/* Short register aliases mapped to GHCI 1.0 canonical registers */
localparam [16:0] GHCI_MAGIC          = GHCI_REG_MAGIC;
localparam [16:0] GHCI_VERSION        = GHCI_REG_VERSION;
localparam [16:0] GHCI_BOOT_CAPS      = GHCI_REG_BOOT_CAPS;
localparam [16:0] GHCI_STATUS         = GHCI_REG_STATUS;
localparam [16:0] GHCI_CTRL           = GHCI_REG_CTRL;
localparam [16:0] GHCI_FAULT_INFO     = GHCI_REG_FAULT_INFO;
localparam [16:0] GHCI_FAULT_ADDR     = GHCI_REG_FAULT_ADDR_LO;
localparam [16:0] GHCI_FAULT_ADDR_LO  = GHCI_REG_FAULT_ADDR_LO;
localparam [16:0] GHCI_FAULT_ADDR_HI  = GHCI_REG_FAULT_ADDR_HI;
localparam [16:0] GHCI_RING_BASE      = GHCI_REG_RING_BASE_LO;
localparam [16:0] GHCI_RING_BASE_LO   = GHCI_REG_RING_BASE_LO;
localparam [16:0] GHCI_RING_BASE_HI   = GHCI_REG_RING_BASE_HI;
localparam [16:0] GHCI_RING_SIZE      = GHCI_REG_RING_SIZE;
localparam [16:0] GHCI_RING_WPTR      = GHCI_REG_RING_WPTR;
localparam [16:0] GHCI_RING_RPTR      = GHCI_REG_RING_RPTR;
localparam [16:0] GHCI_IRQ_STATUS     = GHCI_REG_IRQ_STATUS;
localparam [16:0] GHCI_IRQ_ENABLE     = GHCI_REG_IRQ_ENABLE;
localparam [16:0] GHCI_WDT_CYCLES     = GHCI_REG_WDT_CYCLES;
localparam [16:0] GHCI_SESSION_ACTIVE = GHCI_REG_SESSION_ACTIVE;

/* DEVICE_CAPS bits (0x008, J08) */
localparam GHCI_DEV_CAP_UMA            = 0;
localparam GHCI_DEV_CAP_IOMMU          = 1;
localparam GHCI_DEV_CAP_HW_WALKER      = 2;
localparam GHCI_DEV_CAP_INDIRECT_DRAW  = 3;
localparam GHCI_DEV_CAP_SECONDARY_RING = 4;
localparam GHCI_DEV_CAP_DUAL_SOURCE    = 5;
localparam GHCI_DEV_CAP_FP16           = 6;
localparam GHCI_DEV_CAP_GSI1           = 7;
localparam GHCI_DEV_CAP_PROT           = 24;
localparam GHCI_DEV_CAP_TEX_FFILT      = 25;
localparam GHCI_DEV_CAP_ROP_PACK       = 26;
localparam GHCI_DEV_CAP_TASK_SHADER    = 27;
localparam GHCI_DEV_CAP_MESH_SHADER    = 28;
localparam GHCI_DEV_CAP_BLT            = 29;
localparam GHCI_DEV_CAP_DISP           = 30;
localparam GHCI_DEV_CAP_MSAA           = 31;

/* EXT_CAP_FMT0 bits (0x080) */
localparam GHCI_EXT_FMT_BC1            = 0;
localparam GHCI_EXT_FMT_BC2            = 1;
localparam GHCI_EXT_FMT_BC3            = 2;
localparam GHCI_EXT_FMT_BC4            = 3;
localparam GHCI_EXT_FMT_BC5            = 4;
localparam GHCI_EXT_FMT_BC6H           = 5;
localparam GHCI_EXT_FMT_BC7            = 6;
localparam GHCI_EXT_FMT_TU_BILINEAR     = 16;
localparam GHCI_EXT_FMT_BLT_BLEND       = 17;
localparam GHCI_EXT_FMT_BLT_TILE        = 18;
localparam GHCI_EXT_FMT_TEX_ARRAY       = 19;
localparam GHCI_EXT_FMT_TEX_3D          = 20;
localparam GHCI_EXT_FMT_TEX_CUBE        = 21;
localparam GHCI_EXT_FMT_TEX_TRILINEAR   = 22;

/* BOOT_CAPS bits (0x008, RO) */
localparam GHCI_BOOT_CAP_CP             = 0;
localparam GHCI_BOOT_CAP_HW_WALKER      = 1;
localparam GHCI_BOOT_CAP_PROT           = 2;
localparam GHCI_BOOT_CAP_MEM            = 3;
localparam GHCI_BOOT_CAP_CPFW           = 4;
localparam GHCI_BOOT_CAP_BOOT_DISP      = 5;
localparam GHCI_BOOT_CAP_VA_BITS_SHIFT  = 8;
localparam GHCI_BOOT_CAP_PA_BITS_SHIFT  = 12;

/* EXT_CAP_FEATURE bits (0x084) */
localparam GHCI_EXT_FEAT_VA_BITS_SHIFT  = 0;
localparam GHCI_EXT_FEAT_PA_BITS_SHIFT  = 4;
localparam GHCI_EXT_FEAT_DUAL_SOURCE    = 8;
localparam GHCI_EXT_FEAT_COARSE_SCAN    = 9;
localparam GHCI_EXT_FEAT_FAST_CLEAR     = 10;
localparam GHCI_EXT_FEAT_LOGIC_OP       = 11;
localparam GHCI_EXT_FEAT_EARLY_Z        = 12;
localparam GHCI_EXT_FEAT_HW_CURSOR      = 13;
localparam GHCI_EXT_FEAT_COLOR_LUT      = 14;
localparam GHCI_EXT_FEAT_MRT_BLEND      = 15;
localparam GHCI_EXT_FEAT_MAX_MRT_SHIFT  = 16;
localparam GHCI_EXT_FEAT_LDS_KB_SHIFT   = 20;
localparam GHCI_EXT_FEAT_FP16           = 28;
localparam GHCI_EXT_FEAT_SUBGROUP       = 29;
localparam GHCI_EXT_FEAT_CLIP_POLY      = 30;
localparam GHCI_EXT_FEAT_BLT_SCALE      = 31;

localparam [16:0] GHCI_CPFW_CTRL    = 17'h00170;	/* CPFW window (vendor-defined) */
localparam [16:0] GHCI_CPFW_STATUS  = 17'h00174;
localparam [16:0] GHCI_CPFW_VERSION = 17'h00178;
localparam [16:0] GHCI_CPFW_IBASE   = 17'h001A0;
localparam [16:0] GHCI_CPFW_IWORDS  = 17'h001A4;
localparam [16:0] GHCI_CPFW_DBASE   = 17'h001A8;
localparam [16:0] GHCI_CPFW_DWORDS  = 17'h001AC;
localparam [16:0] GHCI_CPFW_MBOX0   = 17'h001B0;
localparam [16:0] GHCI_STATE_BASE   = 17'h01000;	/* Internal STATE[0..511] */

/* CPFW_CTRL and CPFW_STATUS bits. */
localparam GHCI_CPFW_CTRL_LOAD = 0;
localparam GHCI_CPFW_CTRL_RUN = 1;
localparam GHCI_CPFW_CTRL_HALT = 2;
localparam GHCI_CPFW_STATUS_READY = 0;
localparam GHCI_CPFW_STATUS_FAULT = 1;
localparam GHCI_CPFW_STATUS_ALIVE = 2;
localparam GHCI_CPFW_STATUS_STOPPED = 3;	/* the core is stopped or held in reset */
localparam GHCI_CPFW_STATUS_LOADING = 4;

/* CTRL bits (0x014). */
localparam GHCI_CTRL_RESET      = 0;
localparam GHCI_CTRL_RUN        = 1;
localparam GHCI_CTRL_HALT       = 2;
localparam GHCI_CTRL_WDT_EN     = 5;
localparam GHCI_CTRL_IRQ_GLOBAL = 6;

/* STATUS bits (0x010). */
localparam GHCI_STATUS_RUNNING    = 0;
localparam GHCI_STATUS_HALTED     = 1;
localparam GHCI_STATUS_FAULTED    = 2;
localparam GHCI_STATUS_MC_IDLE    = 8;
localparam GHCI_STATUS_RING_EMPTY = 11;
localparam GHCI_STATUS_MEM_READY  = 12;
localparam GHCI_STATUS_AXI_STUCK  = 13;
localparam GHCI_STATUS_QUIESCE    = 14;

/* Driver-Visible Lifecycle States (§5). */
localparam [2:0] GHCI_LC_IDLE       = 3'd0;
localparam [2:0] GHCI_LC_RUNNING    = 3'd1;
localparam [2:0] GHCI_LC_HALTING    = 3'd2;
localparam [2:0] GHCI_LC_HALTED     = 3'd3;
localparam [2:0] GHCI_LC_FAULTED    = 3'd4;
localparam [2:0] GHCI_LC_RESETTING  = 3'd5;

/* IRQ_STATUS / IRQ_ENABLE bits (0x038, 0x03C). */
localparam GHCI_IRQ_FENCE      = 0;
localparam GHCI_IRQ_FAULT      = 1;
localparam GHCI_IRQ_WATCHDOG   = 2;
localparam GHCI_IRQ_DISPLAY    = 3;
localparam GHCI_IRQ_HALTED     = 6;

/* FAULT_INFO fields (0x018). */
localparam [3:0] GHCI_FAULT_KIND_NONE          = 4'd0;
localparam [3:0] GHCI_FAULT_KIND_INVALID_OP    = 4'd1;
localparam [3:0] GHCI_FAULT_KIND_KICK_ABSENT   = 4'd2;
localparam [3:0] GHCI_FAULT_KIND_BAD_REG       = 4'd3;
localparam [3:0] GHCI_FAULT_KIND_WATCHDOG      = 4'd4;
localparam [3:0] GHCI_FAULT_KIND_AXI_ERROR     = 4'd5;
localparam [3:0] GHCI_FAULT_KIND_PROT_FAULT    = 4'd6;
localparam [3:0] GHCI_FAULT_KIND_LOCKED_REG    = 4'd7;
/* Kind 8 is reserved in GHCI 1.0 */
localparam [3:0] GHCI_FAULT_KIND_PAGE_FAULT    = 4'd9;
localparam [3:0] GHCI_FAULT_KIND_PERM_FAULT    = 4'd10;

localparam [3:0] GHCI_FAULT_UNIT_CP  = 4'd0;
localparam [3:0] GHCI_FAULT_UNIT_VF  = 4'd1;
localparam [3:0] GHCI_FAULT_UNIT_SU  = 4'd2;
localparam [3:0] GHCI_FAULT_UNIT_RX  = 4'd3;
localparam [3:0] GHCI_FAULT_UNIT_TU  = 4'd4;
localparam [3:0] GHCI_FAULT_UNIT_ROP = 4'd5;
localparam [3:0] GHCI_FAULT_UNIT_BLT = 4'd6;

/* Shader Stages for FAULT_INFO[19:16] */
localparam [3:0] GHCI_STAGE_VS       = 4'd0;
localparam [3:0] GHCI_STAGE_FS       = 4'd1;
localparam [3:0] GHCI_STAGE_CS       = 4'd2;
localparam [3:0] GHCI_STAGE_MS       = 4'd3;
localparam [3:0] GHCI_STAGE_TS       = 4'd4;
localparam [3:0] GHCI_STAGE_TCS      = 4'd5;
localparam [3:0] GHCI_STAGE_TES      = 4'd6;
localparam [3:0] GHCI_STAGE_GS       = 4'd7;

/* MEM, BOOT_DISP, and PROT bit positions */
localparam GHCI_MEM_WINDOW_ENABLE      = 0;
localparam GHCI_BOOT_DISP_STATUS_ACTIVE = 0;
localparam GHCI_BOOT_DISP_STATUS_DONE   = 1;
localparam GHCI_PROT_TABLE_ENABLE      = 0;

/* STATE indices of the BLT range (0x000-0x01F). */
localparam [8:0] GHCI_S_BLT_OP = 9'h000;
localparam [8:0] GHCI_S_BLT_DST_BASE = 9'h001;
localparam [8:0] GHCI_S_BLT_DST_STRIDE = 9'h002;
localparam [8:0] GHCI_S_BLT_SRC_BASE = 9'h003;
localparam [8:0] GHCI_S_BLT_SRC_STRIDE = 9'h004;
localparam [8:0] GHCI_S_BLT_DST_XY = 9'h005;
localparam [8:0] GHCI_S_BLT_SRC_XY = 9'h006;
localparam [8:0] GHCI_S_BLT_SIZE = 9'h007;
localparam [8:0] GHCI_S_BLT_COLOR = 9'h008;
localparam [8:0] GHCI_S_BLT_CLIP_MIN = 9'h009;
localparam [8:0] GHCI_S_BLT_CLIP_MAX = 9'h00A;
localparam [8:0] GHCI_S_BLT_RESOLVE = 9'h00B;	/* draft, CAPS[29] */
localparam [8:0] GHCI_S_BLT_COLOR1 = 9'h00C;	/* CAPS[30]: bits 63:32 of a 64- or 128-bit FILL */
localparam [8:0] GHCI_S_BLT_COLOR2 = 9'h00D;	/* bits 95:64 */
localparam [8:0] GHCI_S_BLT_COLOR3 = 9'h00E;	/* bits 127:96 */
localparam [8:0] GHCI_S_BLT_SRC_SLICE = 9'h00F;	/* 3D volume source slice stride in bytes */
localparam [8:0] GHCI_S_BLT_DST_SLICE = 9'h010;	/* 3D volume destination slice stride in bytes */
localparam [8:0] GHCI_S_BLT_DEPTH     = 9'h011;	/* 3D volume slice depth count */

/*
 * The other STATE ranges.  docs/ghci.md section 8.3 defines the program
 * range; the VF, RX, ROP and TU ranges and the vendor words are
 * Amaterrace's layout until the draft defines them (design section 2.3).
 */
localparam [8:0] GHCI_S_BLT = 9'h000;
localparam [8:0] GHCI_S_VF = 9'h020;
localparam [8:0] GHCI_S_RX = 9'h050;
localparam [8:0] GHCI_S_ROP = 9'h070;
localparam [8:0] GHCI_S_TU = 9'h090;	/* 16 slots of 16 words */
localparam [9:0] GHCI_S_TU_VS = 10'h200;	/* CAPS[30]: the vertex stage's 16 slots */
localparam [9:0] GHCI_S_END = 10'h300;	/* CAPS[30]: STATE has 0x000-0x2FF */
localparam [8:0] GHCI_S_PROG = 9'h190;
localparam [8:0] GHCI_S_SA = 9'h1B0;	/* reserved */

/* Extended ROP for MRT 8 attachments (0x1B0-0x1BF, CAPS[30]). */
localparam [8:0] GHCI_S_RT_EXT = 9'h1B0;
localparam [8:0] GHCI_S_RT4_BASE = 9'h1B0;
localparam [8:0] GHCI_S_RT4_STRIDE = 9'h1B1;
localparam [8:0] GHCI_S_RT5_BASE = 9'h1B2;
localparam [8:0] GHCI_S_RT5_STRIDE = 9'h1B3;
localparam [8:0] GHCI_S_RT6_BASE = 9'h1B4;
localparam [8:0] GHCI_S_RT6_STRIDE = 9'h1B5;
localparam [8:0] GHCI_S_RT7_BASE = 9'h1B6;
localparam [8:0] GHCI_S_RT7_STRIDE = 9'h1B7;
localparam [8:0] GHCI_S_BLEND4 = 9'h1B8;
localparam [8:0] GHCI_S_BLEND5 = 9'h1B9;
localparam [8:0] GHCI_S_BLEND6 = 9'h1BA;
localparam [8:0] GHCI_S_BLEND7 = 9'h1BB;
localparam [8:0] GHCI_S_RT_FORMATS1 = 9'h1BC;	/* VkFormats of attachments 4-7 */
localparam [8:0] GHCI_S_WRITE_MASK1 = 9'h1BD;	/* Write masks for attachments 4-7 */
localparam [8:0] GHCI_S_ATTR_DST = 9'h1C0;	/* VF: ATTR_DST[0..15] */
localparam [8:0] GHCI_S_ATTR_LIMIT = 9'h1D0;	/* VF: ATTR_LIMIT[0..15], draft, CAPS[30] */
localparam [8:0] GHCI_S_VENDOR = 9'h1E0;

/* VF (0x020-0x04F). */
localparam [8:0] GHCI_S_TOPOLOGY = 9'h020;
localparam [8:0] GHCI_S_INDEX_BASE = 9'h021;
localparam [8:0] GHCI_S_INDEX_FORMAT = 9'h022;
localparam [8:0] GHCI_S_FIRST = 9'h023;
localparam [8:0] GHCI_S_COUNT = 9'h024;
localparam [8:0] GHCI_S_PRIM_RESTART = 9'h025;
localparam [8:0] GHCI_S_INSTANCE_COUNT = 9'h026;
localparam [8:0] GHCI_S_FIRST_INSTANCE = 9'h027;
localparam [8:0] GHCI_S_VERTEX_OFFSET = 9'h028;
localparam [8:0] GHCI_S_ATTR = 9'h030;	/* ATTR[k]_BASE at +2k, ATTR[k]_DESC at +2k+1 */

/* RX (0x050-0x06F). */
localparam [8:0] GHCI_S_VIEWPORT = 9'h050;	/* 6 words: x/y scale, x/y offset, z scale, z offset */
localparam [8:0] GHCI_S_SCISSOR_MIN = 9'h056;
localparam [8:0] GHCI_S_SCISSOR_MAX = 9'h057;
localparam [8:0] GHCI_S_CULL = 9'h058;
localparam [8:0] GHCI_S_DEPTH_CLAMP = 9'h059;
localparam [8:0] GHCI_S_RAST_MODE = 9'h05A;
localparam [8:0] GHCI_S_VARYING_COUNT = 9'h05B;
localparam [8:0] GHCI_S_DEBUG_COLOR = 9'h05C;
localparam [8:0] GHCI_S_PROVOKING = 9'h05D;
localparam [8:0] GHCI_S_MS_CTRL = 9'h05E;	/* draft, CAPS[29] */
localparam [8:0] GHCI_S_SAMPLE_KILL = 9'h05F;	/* draft, CAPS[29] */
localparam [8:0] GHCI_S_DEPTH_BIAS_CONST = 9'h060;	/* draft, CAPS[30] */
localparam [8:0] GHCI_S_DEPTH_BIAS_SLOPE = 9'h061;	/* draft, CAPS[30] */
localparam [8:0] GHCI_S_DEPTH_BIAS_CLAMP = 9'h062;	/* draft, CAPS[30] */
localparam [8:0] GHCI_S_LINE_WIDTH = 9'h063;
localparam [8:0] GHCI_S_POINT_SIZE = 9'h064;
localparam [8:0] GHCI_S_VIEWPORT_IDX = 9'h065;

/* ROP (0x070-0x08F). */
localparam [8:0] GHCI_S_RT_BASE = 9'h070;
localparam [8:0] GHCI_S_RT_STRIDE = 9'h071;
localparam [8:0] GHCI_S_RT_FORMAT = 9'h072;
localparam [8:0] GHCI_S_RT_SIZE = 9'h073;
localparam [8:0] GHCI_S_DS_BASE = 9'h074;
localparam [8:0] GHCI_S_DS_STRIDE = 9'h075;
localparam [8:0] GHCI_S_DEPTH = 9'h076;
localparam [8:0] GHCI_S_STENCIL_FRONT = 9'h077;
localparam [8:0] GHCI_S_STENCIL_OPS = 9'h078;
localparam [8:0] GHCI_S_STENCIL_BACK = 9'h079;
localparam [8:0] GHCI_S_BLEND = 9'h07A;
localparam [8:0] GHCI_S_BLEND_CONST = 9'h07B;
localparam [8:0] GHCI_S_WRITE_MASK = 9'h07C;
localparam [8:0] GHCI_S_RT_FORMATS = 9'h07D;	/* draft, CAPS[30]: the VkFormats of attachments 0-3 */
localparam [8:0] GHCI_S_RT1_BASE = 9'h07E;	/* RTk_BASE at 0x07E + 2(k - 1), RTk_STRIDE at + 1 */
localparam [8:0] GHCI_S_BLEND1 = 9'h084;	/* BLEND1-BLEND3 */
localparam [8:0] GHCI_S_BLEND_CONST_R = 9'h087;	/* BLEND_CONST_R, _G, _B, _A (fp32) */
localparam [8:0] GHCI_S_DEPTH_BOUNDS_MIN = 9'h08B;
localparam [8:0] GHCI_S_DEPTH_BOUNDS_MAX = 9'h08C;
localparam [8:0] GHCI_S_ROP_CTRL = 9'h08D;	/* [0] occlusion count, [1] fp32 blend constants, [2] logic_op_en, [6:3] logic_op */
localparam [8:0] GHCI_S_LOGIC_OP = 9'h08E;	/* [0] logic_op_en, [4:1] logic_op (VkLogicOp 0..15) */

/* TU (0x090-0x18F, docs/ghci.md section 8.4): slot s's words at
 * GHCI_S_TU + 16 s + GHCI_TEX_*: the image words (BASE, SIZE, IMAGE,
 * LAYER_STRIDE), the sampler words (SAMPLER, LOD), +6 TEX_FORMAT
 * (CAPS[30], docs/ghci.md section 8.5), +7 TEX_ROW, +8..+15 reserved. */
localparam [3:0] GHCI_TEX_BASE = 4'd0;	/* level 0 of layer 0, a multiple of 64 */
localparam [3:0] GHCI_TEX_SIZE = 4'd1;	/* [15:0] width, [31:16] height */
localparam [3:0] GHCI_TEX_IMAGE = 4'd2;
localparam [3:0] GHCI_TEX_LAYER_STRIDE = 4'd3;	/* bytes between layers, a multiple of 64 */
localparam [3:0] GHCI_TEX_SAMPLER = 4'd4;
localparam [3:0] GHCI_TEX_LOD = 4'd5;
localparam [3:0] GHCI_TEX_FORMAT = 4'd6;	/* CAPS[30]: [7:0] VkFormat (0: TEX_IMAGE[7:4]) */
localparam [3:0] GHCI_TEX_ROW = 4'd7;	/* [1:0]: rows of w_l rounded up to 2^n texels (0: packed) */
localparam GHCI_TROW_ALIGN = 0;	/* TEX_ROW [1:0] */
localparam GHCI_TFMT_STENCIL = 8;	/* TEX_FORMAT [8]: the stencil aspect of D24_UNORM_S8_UINT */
localparam GHCI_TFMT_SWIZZLE = 9;	/* [20:9]: VkComponentSwizzle of R, G, B, A, 3 bits each */
localparam GHCI_IMG_LEVELS = 0;	/* TEX_IMAGE [3:0]: the level count (0 reads as 1, > 13 as 13) */
localparam GHCI_IMG_FMT = 4;	/* [7:4]: 0 RGBA8, 1 BGRA8, 2 D24, 3 D32_SFLOAT */
localparam GHCI_IMG_TILED = 8;	/* 4x4 tiles (CAPS[11]) */
localparam GHCI_IMG_TYPE = 9;	/* [11:9]: 0 2D, 1 2D array, 2 3D, 3 cube */
localparam GHCI_IMG_SAMPLES = 12;	/* [15:12]: log2(samples), reserved (0) */
localparam GHCI_IMG_COUNT = 16;	/* [31:16]: depth (3D) or layer count (2D array) */
localparam GHCI_SAMP_WRAP_U = 0;	/* [1:0]: 0 repeat, 1 mirrored, 2 edge, 3 border */
localparam GHCI_SAMP_WRAP_V = 2;	/* [3:2] */
localparam GHCI_SAMP_WRAP_W = 4;	/* [5:4] */
localparam GHCI_SAMP_MAG_LINEAR = 6;
localparam GHCI_SAMP_MIN_LINEAR = 7;
localparam GHCI_SAMP_MIP_LINEAR = 8;
localparam GHCI_SAMP_COMPARE = 9;
localparam GHCI_SAMP_COMPARE_OP = 10;	/* [12:10] VkCompareOp */
localparam GHCI_SAMP_BORDER = 13;	/* [15:13] VkBorderColor */
localparam GHCI_SAMP_UNNORM = 16;	/* unnormalizedCoordinates */
localparam GHCI_SAMP_LOD_BIAS = 19;	/* [31:19] mipLodBias, signed 5.8 fixed */
localparam GHCI_TEX_MIN_LOD = 0;	/* TEX_LOD [11:0]: minLod, 4.8 fixed */
localparam GHCI_TEX_MAX_LOD = 12;	/* TEX_LOD [23:12]: 15.996 - maxLod, 4.8 fixed */

/* The program range (0x190-0x1AF, docs/ghci.md section 8.3). */
localparam [8:0] GHCI_S_VS_BASE = 9'h190;
localparam [8:0] GHCI_S_VS_WORDS = 9'h191;
localparam [8:0] GHCI_S_FS_BASE = 9'h192;
localparam [8:0] GHCI_S_FS_WORDS = 9'h193;
localparam [8:0] GHCI_S_CS_BASE = 9'h194;
localparam [8:0] GHCI_S_CS_WORDS = 9'h195;
localparam [8:0] GHCI_S_CONST_BASE = 9'h196;
localparam [8:0] GHCI_S_CONST_WORDS = 9'h197;
localparam [8:0] GHCI_S_LDS_BYTES = 9'h198;
localparam [8:0] GHCI_S_WG_SIZE = 9'h199;
localparam [8:0] GHCI_S_VS_OUT_WORDS = 9'h19A;

/* Amaterrace's vendor words (0x1E0-0x1FF), written by the µop sequencer. */
localparam [8:0] GHCI_S_RAW = 9'h1E0;	/* DRAW_RAW's 9 words, 0x1E0-0x1E8 */
localparam [8:0] GHCI_S_GRID_X = 9'h1E9;	/* DISPATCH's grid */
localparam [8:0] GHCI_S_GRID_Y = 9'h1EA;
localparam [8:0] GHCI_S_GRID_Z = 9'h1EB;
localparam [8:0] GHCI_S_LC_REGION = 9'h1EC;	/* LOAD_CONST */
localparam [8:0] GHCI_S_LC_ADDR = 9'h1ED;
localparam [8:0] GHCI_S_LC_WORDS = 9'h1EE;
localparam [8:0] GHCI_S_DBG_MARK = 9'h1FF;

/* PERF_SRCn values: what PERFn counts. */
localparam [7:0] GHCI_PERF_SRC_MEM = 8'd8;	/* memory accesses outstanding */
localparam [7:0] GHCI_PERF_SRC_NONE = 8'hFF;

/* BLT_OP[1:0] and the option bits. */
localparam GHCI_BLT_OP_BLEND = 4;
localparam GHCI_BLT_OP_BPP16 = 8;	/* [9:8] = 1 */
localparam GHCI_BLT_OP_REVERSE = 12;
localparam GHCI_BLT_OP_PS128 = 13;	/* CAPS[30]: with [9:8] = 0, 128-bit pixels */
localparam GHCI_BLT_OP_KEEP = 16;	/* CAPS[30]: [19:16] the bytes of a 32-bit pixel not written */
localparam [1:0] GHCI_BLT_FILL = 2'd0;
localparam [1:0] GHCI_BLT_COPY = 2'd1;
localparam [1:0] GHCI_BLT_TILE = 2'd2;
localparam [1:0] GHCI_BLT_UNTILE = 2'd3;
localparam [2:0] GHCI_BLT_RESOLVE = 3'd4;	/* BLT_OP[2:0], draft, CAPS[29] */
/* BLT_RESOLVE[7:4]: the average. */
localparam [3:0] GHCI_RSV_UNORM8 = 4'd0;
localparam [3:0] GHCI_RSV_UNORM565 = 4'd1;
localparam [3:0] GHCI_RSV_SAMPLE0 = 4'd2;
localparam [3:0] GHCI_RSV_SRGB8_A8 = 4'd3;
localparam [3:0] GHCI_RSV_SFLOAT16 = 4'd4;
localparam [3:0] GHCI_RSV_SFLOAT32 = 4'd5;
localparam [3:0] GHCI_RSV_UNORM2_10_10_10 = 4'd6;	/* CAPS[30] */
localparam [3:0] GHCI_RSV_UNORM1555 = 4'd7;	/* CAPS[30] */

/* Display Capability Block Word 23 bit indices */
localparam GHCI_DISP_INFO_ARBITRARY_PCLK_BIT  = 16;
localparam GHCI_DISP_INFO_TMDS_SCRAMBLE_BIT   = 17;
localparam GHCI_DISP_INFO_HAS_CURSOR_BIT      = 18;
localparam GHCI_DISP_INFO_HAS_SENSE_BIT       = 19;
localparam GHCI_DISP_INFO_HAS_I2C_BIT         = 20;
localparam GHCI_DISP_INFO_DISPLAY_COUNT_SHIFT = 21;
localparam GHCI_DISP_INFO_FIXED_MODE_SHIFT    = 24;

/* verilator lint_on UNUSEDPARAM */
