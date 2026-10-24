/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * gsi1_isa.h: the GHCI standard shader ISA GSI1 for C (docs/ghci.md
 * section 12): the program binary's header and interface table (12.10),
 * the operand numbers (12.3), the instruction fields (12.4), the opcodes
 * (12.5) and the export targets and fragment inputs (12.11, 12.12).  The
 * CP's firmware checks programs with it and an OS driver's compiler
 * writes them with it; both copy this file.  It has no dependency but
 * the C integer constants.  tools/gsi1asm.py holds the same encoding.
 */

#ifndef GSI1_ISA_H
#define GSI1_ISA_H

/*
 * The program binary (section 12.10): a 16-word header, the interface
 * table and the code.  Word numbers of the header.
 */
#define GSI1_MAGIC 0x47534931u		/* "GSI1", word 0 */
#define GSI1_VERSION 1u
#define GSI1_HEADER_WORDS 16u
#define GSI1_H_MAGIC 0u
#define GSI1_H_VERSION 1u
#define GSI1_H_STAGE 2u
#define GSI1_H_FLAGS 3u
#define GSI1_H_CODE_WORDS 4u		/* 2 per instruction */
#define GSI1_H_CODE_OFFSET 5u		/* words from the header's start, even */
#define GSI1_H_NREGS 6u			/* the highest r used + 1 */
#define GSI1_H_LDS_BYTES 7u
#define GSI1_H_WG_SIZE 8u		/* x | y << 8 | z << 16 */
#define GSI1_H_CONST_WORDS 9u		/* constant-bank words the program reads */
#define GSI1_H_IFACE_OFFSET 10u		/* words from the header's start */
#define GSI1_H_IFACE_ENTRIES 11u
#define GSI1_H_ENTRY 12u		/* instruction index */
#define GSI1_H_ISA_MIN_VERSION 13u
#define GSI1_H_PUSH_BYTES 14u
#define GSI1_H_RESERVED 15u		/* 0 */

/* Stages (word 2). */
#define GSI1_STAGE_VERTEX 0u
#define GSI1_STAGE_FRAGMENT 1u
#define GSI1_STAGE_COMPUTE 2u

/*
 * Flags (word 3).  [0]-[4] say what the program needs of the GPU (CAPS);
 * [5]-[9] are what a fragment program asks of the pipeline's state.
 */
#define GSI1_FLAG_PACKED (1u << 0)	/* packed fp16/int16 (CAPS[28]) */
#define GSI1_FLAG_SUBGROUP (1u << 1)	/* shfl, vote, ballot (CAPS[24]) */
#define GSI1_FLAG_LDS (1u << 2)		/* lds, sts, bar */
#define GSI1_FLAG_ATOMIC (1u << 3)	/* atom */
#define GSI1_FLAG_SYSTOLIC (1u << 4)	/* rq, sactl (CAPS[25], reserved) */
#define GSI1_FLAG_CENTROID (1u << 5)	/* reads r7-r9: set MS_CTRL[4] */
#define GSI1_FLAG_DEPTH (1u << 6)	/* exports DEPTH (0x104) */
#define GSI1_FLAG_SAMPLE_MASK (1u << 7)	/* exports a SAMPLE_MASK of its own */
#define GSI1_FLAG_KILL (1u << 8)	/* may discard (kill) */
#define GSI1_FLAG_POINTS (1u << 9)	/* built for points: r0, r1 = PointCoord */
#define GSI1_FLAG_SAMPLE_IN (1u << 10)	/* reads r6 (the sample mask in) */

/*
 * The interface table: entries of 4 words, kind, set, binding or
 * location, and the kind-specific word below.
 */
#define GSI1_IFACE_WORDS 4u
#define GSI1_IF_KIND 0u
#define GSI1_IF_SET 1u
#define GSI1_IF_BINDING 2u
#define GSI1_IF_SPECIFIC 3u

/* Kinds (word 0 of an entry). */
#define GSI1_KIND_ATTRIBUTE 1u		/* location; first register | components << 8 */
#define GSI1_KIND_VARYING_IN 2u		/* location; GSI1_VARY_* */
#define GSI1_KIND_OUTPUT 3u		/* location; GSI1_VARY_* (vertex) or GSI1_OUT_* (fragment) */
#define GSI1_KIND_UNIFORM_BLOCK 4u	/* GSI1_UBO_* */
#define GSI1_KIND_SAMPLED_IMAGE 5u	/* GSI1_TEX_* */
#define GSI1_KIND_STORAGE_BUFFER 6u	/* bank word of {address, bytes} */
#define GSI1_KIND_PUSH_CONSTANT 7u	/* bank word of the first push word */
#define GSI1_KIND_SHARED 8u		/* bytes */
#define GSI1_KIND_INPUT_ATTACHMENT 9u	/* bank word of {base, row bytes, samples | pixel bytes << 8} */
#define GSI1_KIND_STORAGE_IMAGE 10u	/* bank word of {base, row bytes, w | h << 16, layers, layer bytes} */
#define GSI1_KIND_TEXEL_BUFFER 11u	/* bank word of {base, elements}: a storage texel buffer */
#define GSI1_KIND_UNIFORM_MEMORY 12u	/* bank word of {address, bytes}: a uniform buffer read with lw */
#define GSI1_KIND_SYSTEM 13u		/* binding: GSI1_SYSTEM_*; the register it arrives in */

/*
 * The kind-specific word of a varying (kind 2, and kind 3 of a vertex
 * program): the first varying word (export target 0x010 + word, PT word
 * 4 + word), the components, and how a fragment program reads it.
 */
#define GSI1_VARY_WORD_MASK 0x3Fu
#define GSI1_VARY_COMPONENTS_SHIFT 8u	/* 1-4 */
#define GSI1_VARY_FLAT (1u << 16)
#define GSI1_VARY_NOPERSPECTIVE (1u << 17)
#define GSI1_VARY_CENTROID (1u << 18)

/*
 * The kind-specific word of a fragment program's output (kind 3): the
 * colour attachment's first export target and the components written
 * (bit c: component c).  The binding word is the attachment.
 */
#define GSI1_OUT_TARGET_MASK 0xFFFu
#define GSI1_OUT_COMPONENTS_SHIFT 16u

/*
 * The kind-specific word of a uniform block (kind 4): the bank words
 * [7:0] the block's first word goes to, the number of words [16:8] (1 to
 * 256) and the first word of the buffer they are copied from [28:17].
 */
#define GSI1_UBO_BANK_MASK 0xFFu
#define GSI1_UBO_WORDS_SHIFT 8u
#define GSI1_UBO_WORDS_MASK 0x1FFu
#define GSI1_UBO_FIRST_SHIFT 17u
#define GSI1_UBO_FIRST_MASK 0xFFFu

/*
 * The kind-specific word of a sampled image (kind 5): the texture slot;
 * for a uniform texel buffer [8] and the bank word [23:16] that holds its
 * element count (the slot is then a 2D image 256 texels wide).
 */
#define GSI1_TEX_SLOT_MASK 0xFu
#define GSI1_TEX_BUFFER (1u << 8)
#define GSI1_TEX_COUNT_SHIFT 16u
#define GSI1_TEX_COUNT_MASK 0xFFu

/* Texel buffers through a texture slot are 2D images this wide. */
#define GSI1_TEXEL_BUFFER_WIDTH 256u

/* The system inputs (kind 13, the binding word). */
#define GSI1_SYSTEM_VERTEX_INDEX 0u	/* index + vertexOffset, or firstVertex + n */
#define GSI1_SYSTEM_INSTANCE_INDEX 1u	/* firstInstance + i */

/* Operand numbers (section 12.3). */
#define GSI1_R(n) (n)			/* r0-r62 */
#define GSI1_RQ 63u
#define GSI1_C(n) (64u + (n))		/* c0-c31 */
#define GSI1_C_COUNT 32u
#define GSI1_ZERO 96u
#define GSI1_ONE 97u			/* 1.0 */
#define GSI1_ONEI 98u			/* 1 */
#define GSI1_HALF 99u			/* 0.5 */
#define GSI1_TWO 100u			/* 2.0 */
#define GSI1_MONE 101u			/* -1.0 */
#define GSI1_LANE 102u
#define GSI1_WARP 103u
#define GSI1_EXEC 104u
#define GSI1_KILLED 105u
#define GSI1_WGX 106u
#define GSI1_WGY 107u
#define GSI1_WGZ 108u
#define GSI1_LIDX 109u
#define GSI1_LIDY 110u
#define GSI1_LIDZ 111u
#define GSI1_LIDN 112u
#define GSI1_PRIM 113u
#define GSI1_FRONT 114u
#define GSI1_NWGX 115u
#define GSI1_NWGY 116u
#define GSI1_NWGZ 117u
#define GSI1_ONEH2 118u
#define GSI1_MASK 119u
#define GSI1_REGISTERS_MAX 63u		/* r0-r62 */

/* The fragment warp's inputs (section 12.11). */
#define GSI1_IN_B0 0u
#define GSI1_IN_B1 1u
#define GSI1_IN_B2 2u
#define GSI1_IN_Z 3u
#define GSI1_IN_X 4u			/* x + 0.5 */
#define GSI1_IN_Y 5u			/* y + 0.5 */
#define GSI1_IN_SAMPLE_MASK 6u
#define GSI1_IN_CENTROID_B0 7u		/* r7-r9 with MS_CTRL[4] */
#define GSI1_IN_POINT_S 0u		/* a point's PointCoord (section 12.12) */
#define GSI1_IN_POINT_T 1u

/* Export targets (S immediate of exp). */
#define GSI1_EXP_POS(c) (0x000u + (c))
#define GSI1_EXP_POINT_SIZE 0x004u
#define GSI1_EXP_VARYING(w) (0x010u + (w))
#define GSI1_EXP_COLOR(k, c) (0x100u + 16u * (k) + (c))
#define GSI1_EXP_DEPTH 0x104u
#define GSI1_EXP_SAMPLE_MASK 0x105u
#define GSI1_COLOR_ATTACHMENTS 4u

/* lda's immediate: the primitive table word (position 0-3, varying w at 4 + w) and the vertex. */
#define GSI1_LDA(word, vertex) ((((word) & 0x3Fu) << 2) | ((vertex) & 3u))
#define GSI1_PT_VARYING(w) (4u + (w))

/*
 * Instruction fields (section 12.4).  word0 is a RISC-V 32-bit layout;
 * word1 carries the high register bits, the modifiers, the sub-operation
 * and the high immediate.
 *
 * Values referenced: The RISC-V Instruction Set Manual, Volume I:
 * Unprivileged ISA, version 20240411, chapter "RV32I Base Integer
 * Instruction Set" (the R, I, S, B and U formats), and chapter "F"
 * (the R4 format).
 */
#define GSI1_W0_OPCODE_SHIFT 0u
#define GSI1_W0_RD_SHIFT 7u
#define GSI1_W0_FUNCT3_SHIFT 12u
#define GSI1_W0_RS1_SHIFT 15u
#define GSI1_W0_RS2_SHIFT 20u
#define GSI1_W0_FUNCT7_SHIFT 25u
#define GSI1_W0_RS3_SHIFT 27u
#define GSI1_W0_IMM_SHIFT 20u		/* I: imm[11:0] */
#define GSI1_W0_UIMM_SHIFT 12u		/* U: imm[31:12] */
#define GSI1_W1_RD_SHIFT 0u		/* rd[6:5] */
#define GSI1_W1_RS1_SHIFT 2u
#define GSI1_W1_RS2_SHIFT 4u
#define GSI1_W1_RS3_SHIFT 6u
#define GSI1_W1_N1 (1u << 8)
#define GSI1_W1_A1 (1u << 9)
#define GSI1_W1_N2 (1u << 10)
#define GSI1_W1_A2 (1u << 11)
#define GSI1_W1_N3 (1u << 12)
#define GSI1_W1_A3 (1u << 13)
#define GSI1_W1_SAT (1u << 14)
#define GSI1_W1_HSEL_SHIFT 15u
#define GSI1_W1_SUB_SHIFT 17u
#define GSI1_W1_IMM_HI_SHIFT 22u	/* I/S/B: + sext(imm_hi) << 12 */
#define GSI1_W1_MOVI_SHIFT 2u		/* U: movi's imm[11:0] */
#define GSI1_W1_TEX_DU_SHIFT 22u	/* texture R forms: texel offsets */
#define GSI1_W1_TEX_DV_SHIFT 26u
#define GSI1_W1_TEX_DW_SHIFT 10u
#define GSI1_IMM_MIN (-(1L << 21))	/* the 22-bit signed offsets of I, S, B */
#define GSI1_IMM_MAX ((1L << 21) - 1)

/*
 * Major opcodes (word0[6:0]) and their funct values.
 *
 * Values referenced: The RISC-V Instruction Set Manual, Volume I:
 * Unprivileged ISA, version 20240411, chapter "RV32I Base Integer
 * Instruction Set" (the opcode map: OP, OP-IMM, LUI, LOAD, STORE, BRANCH,
 * custom-0 to custom-3), "M" (funct7 0000001), "F" (OP-FP, the fused
 * multiply-add opcodes and their funct7 and rs2 values), "Zfa" (fround),
 * "Zbb" (min, max, minu, maxu, andn, orn, xnor).
 */
#define GSI1_OP_OP 0x33u
#define GSI1_OP_OPIMM 0x13u
#define GSI1_OP_LUI 0x37u
#define GSI1_OP_LOAD 0x03u
#define GSI1_OP_STORE 0x23u
#define GSI1_OP_BRANCH 0x63u
#define GSI1_OP_OPFP 0x53u
#define GSI1_OP_MADD 0x43u
#define GSI1_OP_MSUB 0x47u
#define GSI1_OP_NMSUB 0x4Bu
#define GSI1_OP_NMADD 0x4Fu
#define GSI1_OP_CUSTOM0 0x0Bu		/* memory and synchronization */
#define GSI1_OP_CUSTOM1 0x2Bu		/* texture, input and output, lanes */
#define GSI1_OP_CUSTOM2 0x5Bu		/* packed 16 bit */
#define GSI1_OP_CUSTOM3 0x7Bu		/* control, transcendental, select, vote */

/* OP: funct3 and funct7. */
#define GSI1_F3_ADD 0u			/* sub: funct7 0x20 */
#define GSI1_F3_SLL 1u
#define GSI1_F3_SLT 2u
#define GSI1_F3_SLTU 3u
#define GSI1_F3_XOR 4u
#define GSI1_F3_SRL 5u			/* sra: funct7 0x20 */
#define GSI1_F3_OR 6u
#define GSI1_F3_AND 7u
#define GSI1_F7_BASE 0x00u
#define GSI1_F7_ALT 0x20u		/* sub, sra, andn, orn, xnor */
#define GSI1_F7_MULDIV 0x01u
#define GSI1_F7_MINMAX 0x05u
#define GSI1_F3_MUL 0u
#define GSI1_F3_MULH 1u
#define GSI1_F3_MULHSU 2u
#define GSI1_F3_MULHU 3u
#define GSI1_F3_DIV 4u
#define GSI1_F3_DIVU 5u
#define GSI1_F3_REM 6u
#define GSI1_F3_REMU 7u
#define GSI1_F3_MIN 4u
#define GSI1_F3_MINU 5u
#define GSI1_F3_MAX 6u
#define GSI1_F3_MAXU 7u

/* LOAD and STORE: funct3. */
#define GSI1_F3_LW 2u
#define GSI1_F3_LWC 6u
#define GSI1_F3_SW 2u

/* BRANCH: funct3 (warp branches; the offset counts instructions). */
#define GSI1_F3_BANY 0u
#define GSI1_F3_BNONE 1u
#define GSI1_F3_BALL 2u
#define GSI1_F3_J 3u
#define GSI1_F3_BEXNZ 4u
#define GSI1_F3_BEXZ 5u

/* OP-FP: funct7 (fmt 00, single), and the rs2 of the one-source ones. */
#define GSI1_F7_FADD 0x00u
#define GSI1_F7_FSUB 0x04u
#define GSI1_F7_FMUL 0x08u
#define GSI1_F7_FSGNJ 0x10u		/* funct3 0 */
#define GSI1_F7_FMINMAX 0x14u		/* funct3 0 fmin, 1 fmax */
#define GSI1_F7_FROUND 0x20u		/* rs2 4 */
#define GSI1_F7_FSQRT 0x2Cu		/* rs2 0 */
#define GSI1_F7_FCMP 0x50u		/* funct3 2 feq, 1 flt, 0 fle, 3 fne */
#define GSI1_F7_FCVT_W_S 0x60u		/* rs2 0 fcvt.w.s, 1 fcvt.wu.s */
#define GSI1_F7_FCVT_S_W 0x68u		/* rs2 0 fcvt.s.w, 1 fcvt.s.wu */
#define GSI1_RS2_FROUND 4u
#define GSI1_F3_FEQ 2u
#define GSI1_F3_FLT 1u
#define GSI1_F3_FLE 0u
#define GSI1_F3_FNE 3u

/* Rounding modes (the funct3 of the float instructions). */
#define GSI1_RM_RNE 0u
#define GSI1_RM_RTZ 1u
#define GSI1_RM_RDN 2u
#define GSI1_RM_RUP 3u
#define GSI1_RM_RMM 4u

/* custom-0: funct3. */
#define GSI1_F3_LDS 0u
#define GSI1_F3_STS 1u
#define GSI1_F3_ATOM 2u			/* R4, sub = GSI1_ATOM_* */
#define GSI1_F3_FENCE 4u		/* I, imm GSI1_FENCE_* */
#define GSI1_F3_BAR 5u
#define GSI1_F3_WAIT 6u			/* I, imm cm | ct << 4 | cx << 8 */
#define GSI1_F3_END 7u
#define GSI1_FENCE_GLOBAL 1u
#define GSI1_FENCE_SHARED 2u
#define GSI1_FENCE_ACQUIRE 4u
#define GSI1_ATOM_AND 0u
#define GSI1_ATOM_OR 1u
#define GSI1_ATOM_XOR 2u
#define GSI1_ATOM_XCHG 3u
#define GSI1_ATOM_ADD 4u
#define GSI1_ATOM_SUB 5u
#define GSI1_ATOM_SMAX 6u
#define GSI1_ATOM_SMIN 7u
#define GSI1_ATOM_UMAX 8u
#define GSI1_ATOM_UMIN 9u
#define GSI1_ATOM_CMPXCHG 10u		/* rs3 is the compare value */

/*
 * custom-1: funct3, the funct7 modifiers of the texture R forms (section
 * 12.9) and the texsz immediates.
 */
#define GSI1_F3_TEXL 0u
#define GSI1_F3_TEXB 1u
#define GSI1_F3_TEXF 2u
#define GSI1_F3_TEXSZ 3u
#define GSI1_F3_EXP 4u			/* S */
#define GSI1_F3_LDA 5u			/* I */
#define GSI1_F3_QD 6u
#define GSI1_F3_SHFL 7u
#define GSI1_TEX_F7_COMPARE (1u << 0)	/* .c: Dref after the coordinates */
#define GSI1_TEX_F7_GATHER (1u << 1)	/* texl: texg */
#define GSI1_TEX_F7_COMPONENT_SHIFT 2u	/* texg's component */
#define GSI1_TEX_F7_QUERY_LOD 0x10u	/* texb: texqlod */
#define GSI1_TEX_F7_THREE (1u << 5)	/* .3: a third coordinate in rs1+2 */
#define GSI1_TEXSZ_SIZE 0u		/* {height, width} of level rs1 */
#define GSI1_TEXSZ_LEVELS 1u		/* texsz.l */
#define GSI1_TEXSZ_DEPTH 2u		/* texsz.d: depth or layers of level rs1 */
#define GSI1_TEXSZ_SAMPLES 3u		/* texsz.s (CAPS[29]) */
#define GSI1_QD_DX 0u			/* fine, lane ^ 1 */
#define GSI1_QD_DY 1u			/* fine, lane ^ 2 */
#define GSI1_QD_SWAP1 2u
#define GSI1_QD_SWAP2 3u
#define GSI1_QD_SWAP3 4u
#define GSI1_QD_BCAST 5u		/* the quad's lane 0 */

/* custom-2: funct3 and funct7 (packh and unpackh are always there). */
#define GSI1_F3_PACK 7u
#define GSI1_F7_PACKH 0u
#define GSI1_F7_UNPACKH 1u		/* sub 0 low, 1 high */
#define GSI1_F7_SWAPH 2u

/* custom-3: funct3 and sub. */
#define GSI1_F3_SEL 0u			/* R4 */
#define GSI1_F3_EXEC 1u
#define GSI1_F3_KILL 2u
#define GSI1_F3_XU 3u
#define GSI1_F3_VOTE 4u
#define GSI1_F3_BALLOT 5u
#define GSI1_F3_SACTL 6u
#define GSI1_F3_NOP 7u
#define GSI1_EXEC_SET 0u
#define GSI1_EXEC_AND 1u
#define GSI1_EXEC_OR 2u
#define GSI1_EXEC_SAVE 3u
#define GSI1_XU_RCP 0u
#define GSI1_XU_RSQ 1u
#define GSI1_XU_EXP2 2u
#define GSI1_XU_LOG2 3u
#define GSI1_XU_SIN 4u
#define GSI1_XU_COS 5u
#define GSI1_XU_FRACT 6u

#endif /* GSI1_ISA_H */
