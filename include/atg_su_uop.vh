/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_uop.vh: the SU's decoded instruction ("uop") and warp-info word,
 * the fields that travel from atg_su_dec through atg_su_sb and atg_su_opd
 * to the execution units (spec/gpu/su/atg_su_dec.md).  Included inside a
 * module body; every name is a localparam.  A module's UOP_W parameter is
 * ATG_UOP_W.
 */

/* verilator lint_off UNUSEDPARAM */

localparam ATG_UOP_W = 104;

/* Field positions (LSB) and widths. */
localparam ATG_UOP_UNIT = 0;	/* [3:0] the unit, below */
localparam ATG_UOP_OP = 4;	/* [11:4] unit-specific operation */
localparam ATG_UOP_RD = 12;	/* [18:12] destination operand number (0-63; 63 = rq) */
localparam ATG_UOP_RS1 = 19;	/* [25:19] source operand numbers (0-127, design §3.2) */
localparam ATG_UOP_RS2 = 26;	/* [32:26] */
localparam ATG_UOP_RS3 = 33;	/* [39:33] */
localparam ATG_UOP_IMM = 40;	/* [71:40] the immediate, sign-extended (22-bit offsets, movi) */
localparam ATG_UOP_MOD = 72;	/* [78:72] {sat, a3, n3, a2, n2, a1, n1} float modifiers */
localparam ATG_UOP_HSEL = 79;	/* [80:79] packed half select */
localparam ATG_UOP_SUB = 81;	/* [85:81] sub field of word1 */
localparam ATG_UOP_RM = 86;	/* [88:86] rounding mode / funct3 */
localparam ATG_UOP_CLS = 89;	/* [91:89] latency class, below */
localparam ATG_UOP_NDST = 92;	/* [94:92] destination registers written (0, 1 or 4) */
localparam ATG_UOP_USE1 = 95;	/* rs1 is read */
localparam ATG_UOP_USE2 = 96;	/* rs2 is read */
localparam ATG_UOP_USE3 = 97;	/* rs3 is read */
localparam ATG_UOP_WRD = 98;	/* rd is written */
localparam ATG_UOP_PAIR = 99;	/* rs1 and rs1+1 are read (texl/texb/texf) */
localparam ATG_UOP_ILL = 100;	/* ISA fault (FAULT kind 8) */
localparam ATG_UOP_RQS = 101;	/* a source is rq (pop) */
localparam ATG_UOP_RQD = 102;	/* rd is rq (push) */
localparam ATG_UOP_SIDE = 103;	/* has side effects: use the side-effect lane mask */

/* Units (ATG_UOP_UNIT). */
localparam [3:0] ATG_UNIT_NONE = 4'd0;	/* nop */
localparam [3:0] ATG_UNIT_ALU = 4'd1;	/* integer, sel, lui/movi */
localparam [3:0] ATG_UNIT_FPU = 4'd2;	/* fp32, mul, fract */
localparam [3:0] ATG_UNIT_PK = 4'd3;	/* 16-bit packed */
localparam [3:0] ATG_UNIT_XU = 4'd4;	/* rcp rsq exp2 log2 sin cos fsqrt */
localparam [3:0] ATG_UNIT_DIV = 4'd5;	/* div divu rem remu */
localparam [3:0] ATG_UNIT_LSU = 4'd6;	/* lw sw atom fence (after atg_su_sb waits for cm = 0) */
localparam [3:0] ATG_UNIT_LDS = 4'd7;	/* lds sts */
localparam [3:0] ATG_UNIT_CBANK = 4'd8;	/* lwc */
localparam [3:0] ATG_UNIT_TEX = 4'd9;	/* texl texb texf texsz */
localparam [3:0] ATG_UNIT_EXP = 4'd10;	/* exp */
localparam [3:0] ATG_UNIT_LDA = 4'd11;	/* lda */
localparam [3:0] ATG_UNIT_LANE = 4'd12;	/* qd shfl vote ballot */
localparam [3:0] ATG_UNIT_EXEC = 4'd13;	/* branches, exec.*, kill, end, bar */
localparam [3:0] ATG_UNIT_CTL = 4'd14;	/* wait (held by atg_su_sb, then issued as a no-op) */
localparam [3:0] ATG_UNIT_RQ = 4'd15;	/* sactl (reserved, design §3.9) */

/* Latency classes (ATG_UOP_CLS, design §3.4.2). */
localparam [2:0] ATG_CLS_A = 3'd0;	/* short, fixed pipeline */
localparam [2:0] ATG_CLS_F = 3'd1;	/* short, fixed pipeline */
localparam [2:0] ATG_CLS_M = 3'd2;	/* memory: scoreboard, counter cm for stores */
localparam [2:0] ATG_CLS_T = 3'd3;	/* texture: scoreboard, counter ct */
localparam [2:0] ATG_CLS_X = 3'd4;	/* transcendental, divide: scoreboard, counter cx */

/* The warp-info word (atg_su_sched's q_info, ATG_WI_W bits). */
localparam ATG_WI_W = 160;
localparam ATG_WI_WGX = 0;	/* [15:0] workgroup id x (y at 16, z at 32) */
localparam ATG_WI_NWGX = 48;	/* [63:48] workgroups x (y at 64, z at 80) */
localparam ATG_WI_LID = 96;	/* [103:96] local index of lane 0 (lidn = LID + lane) */
localparam ATG_WI_KIND = 104;	/* [105:104] 0 vertex, 1 fragment, 2 compute */
localparam ATG_WI_FRONT = 106;	/* front facing (fragment) */
localparam ATG_WI_SEQ = 112;	/* [127:112] fragment warp sequence number (ROP order) */
localparam ATG_WI_MASK = 128;	/* [159:128] coverage / sample mask (operand 119) */

/* verilator lint_on UNUSEDPARAM */
