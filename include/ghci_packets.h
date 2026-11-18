/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci_packets.h: the GHCI command ring's packet envelope (version 3) and
 * the class N micro-operations (docs/ghci.md section 7).  Class V packets
 * carry zedBSD's GPU command protocol (gpu-op) for the CP's firmware.
 */

#ifndef GHCI_PACKETS_H
#define GHCI_PACKETS_H

/*
 * dword0: [31:30] class, [29:24] op (class N), [23:16] job tag,
 * class N: [15:8] flags, [7:0] payload dwords; class V and padding:
 * [15:0] dwords after the header.
 */
#define GHCI_PKT_CLASS_STD 0u	/* class N, standard micro-ops */
#define GHCI_PKT_CLASS_VENDOR 1u	/* class N, vendor micro-ops */
#define GHCI_PKT_CLASS_V 2u	/* a gpu-op for the firmware */
#define GHCI_PKT_CLASS_PAD 3u	/* padding: skipped */
#define GHCI_PKT_N(cls, op, tag, flags, n) \
	((unsigned)(cls) << 30 | ((unsigned)(op) & 0x3Fu) << 24 | ((unsigned)(tag) & 0xFFu) << 16 | \
	    ((unsigned)(flags) & 0xFFu) << 8 | ((unsigned)(n) & 0xFFu))
#define GHCI_PKT_V(tag, n) (GHCI_PKT_CLASS_V << 30 | ((unsigned)(tag) & 0xFFu) << 16 | \
	((unsigned)(n) & 0xFFFFu))
#define GHCI_PKT_PAD(n) (GHCI_PKT_CLASS_PAD << 30 | ((unsigned)(n) & 0xFFFFu))
#define GHCI_PKT_GET_CLASS(d) ((d) >> 30)
#define GHCI_PKT_GET_TAG(d) (((d) >> 16) & 0xFFu)

/* Standard micro-ops (class 0) and their payload dwords. */
#define GHCI_OP_NOP 0u	/* n: skipped */
#define GHCI_OP_SET_REG 1u	/* (index, value) pairs */
#define GHCI_OP_BLIT 2u	/* 0; flags[0]: wait for the end */
#define GHCI_OP_DRAW 3u	/* 0 */
#define GHCI_OP_DISPATCH 4u	/* 3: gx, gy, gz */
#define GHCI_OP_FENCE 5u	/* 2: addr, value; flags[0]: IRQ */
#define GHCI_OP_WAIT_IDLE 6u	/* 0; flags: STATUS busy-bit mask, 0 = all */
#define GHCI_OP_LOAD_CONST 7u	/* 3: region, addr, words */
#define GHCI_OP_LOAD_PROGRAM 8u	/* 1: stage */
#define GHCI_OP_WAIT_FENCE 9u	/* 2: addr, value */
#define GHCI_OP_PERF_RESET 10u	/* 0 */
#define GHCI_OP_WAIT_VSYNC 11u	/* 0 */
#define GHCI_OP_INVALIDATE 12u	/* 0; flags: [0] D$ [1] T$ [2] constants [3] I$ */
#define GHCI_OP_RESULT 13u	/* 3: addr, status, aux */
#define GHCI_OP_QUERY 14u	/* 1: addr; flags [0] clear only, [1] clear after (CAPS[30], draft) */
#define GHCI_OP_DISP_SET 15u	/* (offset, value) pairs; flags[0]: wait for STATUS.idle (DISP2, draft) */
#define GHCI_OP_FLIP 16u	/* 4: plane, base, record, value; flags[0]: COMPLETE (DISP2, draft) */
#define GHCI_FENCE_IRQ 0x01u	/* FENCE flags */
#define GHCI_BLIT_WAIT 0x01u	/* BLIT flags */
#define GHCI_DISP_SET_WAIT_IDLE 0x01u	/* DISP_SET flags */
#define GHCI_FLIP_COMPLETE 0x01u	/* FLIP flags */
#define GHCI_FLIP_CANCELLED 0x80000000u	/* a flip record's value: taken as cancelled */

/* Amaterrace's vendor micro-ops (class 1). */
#define ATG_VOP_DRAW_RAW 0u	/* 9: three vertices x, y, z */
#define ATG_VOP_DBG_MARK 1u	/* 1: STATE[0x1FF] = payload */

/* Fence values are 32 bits and compare with wrap-around. */
#define GHCI_FENCE_PASSED(mem, value) ((int)((unsigned)(mem) - (unsigned)(value)) >= 0)

#endif /* GHCI_PACKETS_H */
