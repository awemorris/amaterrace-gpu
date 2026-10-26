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
localparam [15:0] GHCI_VERSION_MINOR = 16'd1;

/*
 * ============================================================================
 * GHCI 2.0 Slim Host MMIO Registers (19 registers, 76 bytes: 17'h00 - 17'h48)
 * ============================================================================
 */
localparam [16:0] GHCI_2_REG_MAGIC          = 17'h00000;
localparam [16:0] GHCI_2_REG_VERSION        = 17'h00004;
localparam [16:0] GHCI_2_REG_DEVICE_CAPS    = 17'h00008;
localparam [16:0] GHCI_2_REG_EXTCAP_PTR     = 17'h0000C;
localparam [16:0] GHCI_2_REG_CTRL           = 17'h00010;
localparam [16:0] GHCI_2_REG_STATUS         = 17'h00014;
localparam [16:0] GHCI_2_REG_IRQ_STATUS     = 17'h00018;
localparam [16:0] GHCI_2_REG_IRQ_ENABLE     = 17'h0001C;
localparam [16:0] GHCI_2_REG_RING_BASE_LO   = 17'h00020;
localparam [16:0] GHCI_2_REG_RING_BASE_HI   = 17'h00024;
localparam [16:0] GHCI_2_REG_RING_SIZE      = 17'h00028;
localparam [16:0] GHCI_2_REG_RING_RPTR      = 17'h0002C;
localparam [16:0] GHCI_2_REG_RING_WPTR      = 17'h00030;
localparam [16:0] GHCI_2_REG_FAULT_INFO     = 17'h00034;
localparam [16:0] GHCI_2_REG_FAULT_ADDR_LO  = 17'h00038;
localparam [16:0] GHCI_2_REG_FAULT_ADDR_HI  = 17'h0003C;
localparam [16:0] GHCI_2_REG_DIAG_CP_PC     = 17'h00040;
localparam [16:0] GHCI_2_REG_DIAG_CP_STATUS = 17'h00044;
localparam [16:0] GHCI_2_REG_SCRATCH        = 17'h00048;

/* Legacy Host control register offsets (bytes in the 128 KiB decode). */
localparam [16:0] GHCI_MAGIC = 17'h00000;
localparam [16:0] GHCI_VERSION = 17'h00004;
localparam [16:0] GHCI_VENDOR_ID = 17'h00008;
localparam [16:0] GHCI_DEVICE_ID = 17'h0000C;
localparam [16:0] GHCI_ISA_ID = 17'h00010;
localparam [16:0] GHCI_DEVICE_VERSION = 17'h00014;
localparam [16:0] GHCI_EXTCAP = 17'h00018;
localparam [16:0] GHCI_GCLK_HZ = 17'h0001C;
localparam [16:0] GHCI_CAPS = 17'h00020;
localparam [16:0] GHCI_CAPS2 = 17'h00024;
localparam [16:0] GHCI_SCRATCH = 17'h00028;
localparam [16:0] GHCI_COUNTER = 17'h0002C;
localparam [16:0] GHCI_CTRL = 17'h00030;
localparam [16:0] GHCI_STATUS = 17'h00034;
localparam [16:0] GHCI_IRQ_STATUS = 17'h00038;
localparam [16:0] GHCI_IRQ_ENABLE = 17'h0003C;
localparam [16:0] GHCI_IRQ_SET = 17'h00040;
localparam [16:0] GHCI_RESIDENT_WARPS = 17'h0004C;	/* R: [15:0] warps the GPU runs at once, [23:16] registers per lane */
localparam [16:0] GHCI_WDT_CYCLES = 17'h00044;
localparam [16:0] GHCI_RING_BASE = 17'h00050;
localparam [16:0] GHCI_RING_SIZE = 17'h00054;
localparam [16:0] GHCI_RING_WPTR = 17'h00058;
localparam [16:0] GHCI_RING_RPTR = 17'h0005C;
localparam [16:0] GHCI_APERTURE_BASE = 17'h00060;
localparam [16:0] GHCI_APERTURE_LIMIT = 17'h00064;
localparam [16:0] GHCI_FAULT_ADDR = 17'h00068;
localparam [16:0] GHCI_FAULT_INFO = 17'h0006C;
localparam [16:0] GHCI_FENCE_LAST = 17'h00070;
localparam [16:0] GHCI_CP_PC = 17'h00074;
localparam [16:0] GHCI_CP_STATUS = 17'h00078;
localparam [16:0] GHCI_PIPE_FSM = 17'h0007C;
localparam [16:0] GHCI_PERF0 = 17'h00080;
localparam [16:0] GHCI_PERF_CTRL = 17'h00090;
localparam [16:0] GHCI_DBG_ADDR = 17'h000A0;
localparam [16:0] GHCI_DBG_DATA = 17'h000A4;
localparam [16:0] GHCI_DBG_STATUS = 17'h000A8;
localparam [16:0] GHCI_EXTCAP_LIST = 17'h00100;	/* where EXTCAP points */
localparam [16:0] GHCI_PERF_SRC0 = 17'h00110;	/* the PERF capability's registers */
localparam [16:0] GHCI_CPFW_CTRL = 17'h00120;	/* the CPFW capability (id 6) */
localparam [16:0] GHCI_CPFW_STATUS = 17'h00124;
localparam [16:0] GHCI_CPFW_IBASE = 17'h00128;
localparam [16:0] GHCI_CPFW_IWORDS = 17'h0012C;
localparam [16:0] GHCI_CPFW_DBASE = 17'h00130;
localparam [16:0] GHCI_CPFW_DWORDS = 17'h00134;
localparam [16:0] GHCI_CPFW_VERSION = 17'h00138;
localparam [16:0] GHCI_CPFW_MBOX0 = 17'h00150;	/* MBOX0-3, after SA's 0x140-0x14F */
localparam [16:0] GHCI_KICK = 17'h00F00;
localparam [16:0] GHCI_STATE_BASE = 17'h01000;	/* STATE[0..511] */
localparam [16:0] GHCI_DISP_KC705 = 17'h10000;	/* the KC705 DC's former window (DISP, before WS288 p035 D4); unused */

/* CPFW_CTRL and CPFW_STATUS bits. */
localparam GHCI_CPFW_CTRL_LOAD = 0;
localparam GHCI_CPFW_CTRL_RUN = 1;
localparam GHCI_CPFW_CTRL_HALT = 2;
localparam GHCI_CPFW_STATUS_READY = 0;
localparam GHCI_CPFW_STATUS_FAULT = 1;
localparam GHCI_CPFW_STATUS_ALIVE = 2;
localparam GHCI_CPFW_STATUS_STOPPED = 3;	/* the core is stopped or held in reset */
localparam GHCI_CPFW_STATUS_LOADING = 4;

/* CTRL bits. */
localparam GHCI_CTRL_RUN = 0;
localparam GHCI_CTRL_RESET = 1;
localparam GHCI_CTRL_HALT = 2;
localparam GHCI_CTRL_STEP = 3;
localparam GHCI_CTRL_WDT_EN = 4;

/* STATUS bits. */
localparam GHCI_STATUS_CP_BUSY = 0;
localparam GHCI_STATUS_BLT_BUSY = 1;
localparam GHCI_STATUS_VF_BUSY = 2;
localparam GHCI_STATUS_RX_BUSY = 3;
localparam GHCI_STATUS_ROP_BUSY = 4;
localparam GHCI_STATUS_TU_BUSY = 5;
localparam GHCI_STATUS_SU_BUSY = 6;
localparam GHCI_STATUS_AXI_IDLE = 8;
localparam GHCI_STATUS_FAULT = 9;
localparam GHCI_STATUS_HALTED = 10;
localparam GHCI_STATUS_RING_EMPTY = 11;
localparam GHCI_STATUS_MEM_READY = 12;
localparam GHCI_STATUS_AXI_STUCK = 13;
localparam GHCI_STATUS_QUIESCED = 14;
localparam GHCI_STATUS_STATE = 16;	/* [19:16] */

/* CP states (STATUS[19:16]). */
localparam [3:0] GHCI_ST_IDLE = 4'd0;
localparam [3:0] GHCI_ST_RUNNING = 4'd1;
localparam [3:0] GHCI_ST_HALTING = 4'd2;
localparam [3:0] GHCI_ST_HALTED = 4'd3;
localparam [3:0] GHCI_ST_FAULTED = 4'd4;
localparam [3:0] GHCI_ST_RESETTING = 4'd5;

/* IRQ_STATUS / IRQ_ENABLE bits. */
localparam GHCI_IRQ_FENCE = 0;
localparam GHCI_IRQ_FAULT = 1;
localparam GHCI_IRQ_RING_EMPTY = 2;
localparam GHCI_IRQ_WATCHDOG = 3;
localparam GHCI_IRQ_DBG_DONE = 4;
localparam GHCI_IRQ_SOFT = 5;
localparam GHCI_IRQ_HALTED = 6;
localparam GHCI_IRQ_RESULT = 7;
localparam GHCI_IRQ_RETIRE = 8;
localparam GHCI_IRQ_VBLANK = 9;	/* DISP2 (draft) */
localparam GHCI_IRQ_FLIP = 10;
localparam GHCI_IRQ_DISP_ERROR = 11;
localparam GHCI_IRQ_HOTPLUG = 12;

/* FAULT_INFO[15:12] kinds. */
localparam [3:0] GHCI_FAULT_APERTURE = 4'd1;
localparam [3:0] GHCI_FAULT_OPCODE = 4'd2;
localparam [3:0] GHCI_FAULT_RING = 4'd3;
localparam [3:0] GHCI_FAULT_WATCHDOG = 4'd4;
localparam [3:0] GHCI_FAULT_AXI = 4'd5;
localparam [3:0] GHCI_FAULT_KICK = 4'd6;
localparam [3:0] GHCI_FAULT_LOCKED = 4'd7;

/* KICK bits. */
localparam GHCI_KICK_BLIT = 0;
localparam GHCI_KICK_DRAW = 1;
localparam GHCI_KICK_DISPATCH = 2;

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
localparam [8:0] GHCI_S_ROP_CTRL = 9'h08D;	/* [0] occlusion count, [1] fp32 blend constants */

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

/* Extended capability IDs. */
localparam [7:0] GHCI_XCAP_DISP = 8'd1;
localparam [7:0] GHCI_XCAP_DBG = 8'd2;
localparam [7:0] GHCI_XCAP_PERF = 8'd3;
localparam [7:0] GHCI_XCAP_VEND = 8'd4;
localparam [7:0] GHCI_XCAP_MMU = 8'd5;
localparam [7:0] GHCI_XCAP_CPFW = 8'd6;
localparam [7:0] GHCI_XCAP_SA = 8'd7;
localparam [7:0] GHCI_XCAP_MEM = 8'd8;
localparam [7:0] GHCI_XCAP_PROT = 8'd9;
localparam [7:0] GHCI_XCAP_FMT = 8'd10;
localparam [7:0] GHCI_XCAP_DISP2 = 8'd11;	/* draft */
/* The FMT capability's registers (from its register offset, section 4; draft). */
localparam [16:0] GHCI_FMT_INDEX = 17'h00000;	/* RW: a VkFormat value */
localparam [16:0] GHCI_FMT_OPTIMAL = 17'h00004;	/* R: VkFormatFeatureFlags, optimal tiling */
localparam [16:0] GHCI_FMT_LINEAR = 17'h00008;	/* R: the same, linear tiling */
localparam [16:0] GHCI_FMT_BUFFER = 17'h0000C;	/* R: the buffer features */
localparam [16:0] GHCI_FMT_LIMITS = 17'h00010;	/* R: [3:0] colour attachments */
/* The MEM capability's registers (from its register offset, section 11.3). */
localparam [16:0] GHCI_MEM_LOCAL_BASE = 17'h00000;
localparam [16:0] GHCI_MEM_LOCAL_SIZE = 17'h00004;	/* 0 = no local memory (unified) */
localparam [16:0] GHCI_MEM_WINDOW_SIZE = 17'h00008;	/* 0 = no local window */
localparam [16:0] GHCI_MEM_HOST_LIMIT = 17'h0000C;	/* host addresses below it, outside local memory; 0 = all */
localparam [16:0] GHCI_MEM_WINDOW_CTRL = 17'h00010;	/* [0] ENABLE: the local window is open (reset 1) */
/* The PROT capability's registers (from its register offset, section 11.6). */
localparam [16:0] GHCI_PROT_CAPS = 17'h00000;
localparam [16:0] GHCI_PROT_TABLE = 17'h00004;	/* RW: the table's address, 4 KiB aligned */
localparam [16:0] GHCI_PROT_TABLE_BYTES = 17'h00008;	/* R: its bytes for the aperture */

/* The display controller's registers (DISP capability, docs/ghci.md
 * section 13): offsets from the capability's register offset. */
localparam [31:0] GHCI_DC_ID_VALUE = 32'h41544443;	/* "ATDC" */
localparam [16:0] GHCI_DC_ID = 17'h00;
localparam [16:0] GHCI_DC_VERSION = 17'h04;
localparam [16:0] GHCI_DC_CAPS = 17'h08;
localparam [16:0] GHCI_DC_CTRL = 17'h10;
localparam [16:0] GHCI_DC_STATUS = 17'h14;
localparam [16:0] GHCI_DC_IRQ_STATUS = 17'h18;
localparam [16:0] GHCI_DC_IRQ_ENABLE = 17'h1C;
localparam [16:0] GHCI_DC_FB_BASE = 17'h20;
localparam [16:0] GHCI_DC_FB_NEXT = 17'h24;
localparam [16:0] GHCI_DC_FB_STRIDE = 17'h28;
localparam [16:0] GHCI_DC_FB_SIZE = 17'h2C;
localparam [16:0] GHCI_DC_TIMING = 17'h30;	/* 0x30..0x50: H_ACTIVE..V_BP, SYNC_POL */
localparam [16:0] GHCI_DC_SYNC_POL = 17'h50;
localparam [16:0] GHCI_DC_FRAME_COUNT = 17'h54;
localparam [16:0] GHCI_DC_PCLK_SEL = 17'h58;
localparam [16:0] GHCI_DC_I2C = 17'h60;	/* 0x60 CTRL, 0x64 DATA, 0x68 STATUS */
localparam [16:0] GHCI_DC_SCAN_SUM = 17'h70;	/* Amaterrace: sum of the last frame's pixel words */
localparam [16:0] GHCI_DC_SCAN_WORDS = 17'h74;	/* Amaterrace: pixel words of the last frame */
localparam GHCI_DC_CTRL_ENABLE = 0;
localparam GHCI_DC_CTRL_RESET = 1;
localparam GHCI_DC_CTRL_TEST_PATTERN = 2;
localparam GHCI_DC_CTRL_FORMAT = 4;	/* [5:4] */
localparam GHCI_DC_CTRL_OUTPUT = 6;
localparam [1:0] GHCI_DC_FMT_BGRA8 = 2'd0;
localparam [1:0] GHCI_DC_FMT_RGBA8 = 2'd1;
localparam [1:0] GHCI_DC_FMT_RGB565 = 2'd2;
localparam GHCI_DC_IRQ_VSYNC = 0;
localparam GHCI_DC_IRQ_UNDERFLOW = 1;
localparam GHCI_DC_IRQ_FLIP_DONE = 2;

/* DISP2 (docs/ghci.md section 13.2, draft): the same offsets up to 0x68
 * (IRQ_STATUS/IRQ_ENABLE are DISP's only), and these.  The window is
 * 256 bytes; Amaterrace puts it at 0x200 of the host registers. */
localparam [16:0] GHCI_DISP2_BASE = 17'h00200;	/* Amaterrace */
localparam [16:0] GHCI_DC_CONNECTED = 17'h6C;
localparam [16:0] GHCI_DC_MODE_INDEX = 17'h80;
localparam [16:0] GHCI_DC_MODE_H0 = 17'h84;
localparam [16:0] GHCI_DC_MODE_H1 = 17'h88;
localparam [16:0] GHCI_DC_MODE_V0 = 17'h8C;
localparam [16:0] GHCI_DC_MODE_V1 = 17'h90;
localparam [16:0] GHCI_DC_MODE_CLOCK = 17'h94;
localparam [16:0] GHCI_DC_MODE_FLAGS = 17'h98;
localparam [16:0] GHCI_DC_CURSOR_BASE = 17'hA0;
localparam [16:0] GHCI_DC_CURSOR_POS = 17'hA4;
localparam [16:0] GHCI_DC_CURSOR_CTRL = 17'hA8;
localparam [16:0] GHCI_DC_TAKEN0 = 17'hB0;
localparam [16:0] GHCI_DC_TAKEN1 = 17'hB4;
localparam GHCI_DC_CAPS_CURSOR = 8;
localparam GHCI_DC_CAPS_MODES = 9;	/* [11:9] */
localparam GHCI_DC_CAPS_SENSE = 12;
localparam GHCI_DC_ST_RUNNING = 0;
localparam GHCI_DC_ST_UNDERFLOW = 1;
localparam GHCI_DC_ST_IDLE = 2;
localparam GHCI_DC_ST_READ_ERROR = 3;
localparam GHCI_DC_ST_RECORD_ERROR = 4;
localparam GHCI_DC_ST_BAD_WRITE = 5;
localparam GHCI_DC_ST_LINE = 16;	/* [27:16] */
localparam GHCI_DC_ST_CONNECTED = 28;
localparam GHCI_DC_ST_PENDING0 = 29;
localparam GHCI_DC_ST_PENDING1 = 30;
localparam GHCI_DC_ST_RECORD = 31;
/* µops 15 and 16 (docs/ghci.md section 7.3, draft). */
localparam [5:0] GHCI_OP_DISP_SET = 6'd15;
localparam [5:0] GHCI_OP_FLIP = 6'd16;

/* verilator lint_on UNUSEDPARAM */
