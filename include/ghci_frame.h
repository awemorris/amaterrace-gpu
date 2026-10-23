/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci_frame.h: the class V packets of GHCI 1.0 (docs/ghci.md section 9,
 * draft): the GHCI gpu-ops, the GHCI_FRAME packet that points at a frame
 * of commands in a staging buffer, and the result records the firmware
 * writes.  The Vulkan gpu-op numbers are those of zedBSD's GPU command
 * protocol (include/uapi/gpu-op.h of zedBSD); only the ones the firmware
 * decodes are named here.  The GHCI numbers from 0x10100 are a draft.
 */

#ifndef GHCI_FRAME_H
#define GHCI_FRAME_H

/* dword2 of a class V packet, and the flags word of a staged command. */
#define GHCI_V_REPLY 0x1u	/* the sender wants a reply (the driver writes it) */
#define GHCI_V_RESULT 0x2u	/* dword3 is the address of the packet's result record */

/*
 * The GHCI gpu-ops (draft numbers).
 *   SESSION_OPEN  [u32 tag][u32 flags][u64 heap limit in bytes]
 *   SESSION_CLOSE [u32 tag]
 *   MEMORY        [u64 memory][u64 GPU address][u64 bytes][u32 flags]
 *   PROGRAM       [u64 pipeline][u32 stage][u32 ISA][u64 address][u32 bytes][u32 flags]
 *   NATIVE        [u32 count][count x class N packet] (the driver unpacks it)
 *   FRAME         [u64 staging address][u32 bytes][u32 result page][u32 records]
 */
#define GHCI_GPU_OP_SESSION_OPEN 0x10100u
#define GHCI_GPU_OP_SESSION_CLOSE 0x10101u
#define GHCI_GPU_OP_MEMORY 0x10102u
#define GHCI_GPU_OP_PROGRAM 0x10103u
#define GHCI_GPU_OP_NATIVE 0x10104u
#define GHCI_GPU_OP_FRAME 0x10105u

/*
 * The GHCI_FRAME packet: dword0 GHCI_PKT_V(tag, 8), dword1 GHCI_GPU_OP_FRAME,
 * dword2 flags (GHCI_V_RESULT), dword3 the frame's result record, dword4-5
 * the staging address (u64, the high word 0), dword6 the frame's bytes,
 * dword7 the result page, dword8 the number of records.
 *
 * A staged record is [u32 number][u32 flags][u32 result index][arguments in
 * the gpu-op wire form].  The firmware writes the record's result
 * {u32 VkResult, u32 aux} at result page + 8 x index when it has decoded
 * it (index GHCI_FRAME_NO_RESULT: none).  At the frame's end it writes the
 * frame's result at dword3: {VkResult, records decoded}; VK_SUCCESS when
 * every record was decoded, else the result of the record that stopped
 * the frame (a number the firmware does not know cannot be skipped, the
 * wire has no lengths).  Then IRQ_STATUS.RESULT, then RING_RPTR moves.
 */
#define GHCI_FRAME_DWORDS 8u
#define GHCI_FRAME_NO_RESULT 0xFFFFFFFFu

/* The Vulkan gpu-ops the Amaterrace firmware decodes (zedBSD gpu-op.h). */
#define GHCI_VK_QUEUE_SUBMIT 18u
#define GHCI_VK_FREE_MEMORY 22u
#define GHCI_VK_BIND_BUFFER_MEMORY 28u
#define GHCI_VK_CREATE_BUFFER 50u
#define GHCI_VK_DESTROY_BUFFER 51u
#define GHCI_VK_CREATE_COMMAND_POOL 85u
#define GHCI_VK_DESTROY_COMMAND_POOL 86u
#define GHCI_VK_ALLOCATE_COMMAND_BUFFERS 88u
#define GHCI_VK_FREE_COMMAND_BUFFERS 89u
#define GHCI_VK_BEGIN_COMMAND_BUFFER 90u
#define GHCI_VK_END_COMMAND_BUFFER 91u
#define GHCI_VK_RESET_COMMAND_BUFFER 92u
#define GHCI_VK_CMD_COPY_BUFFER 112u
#define GHCI_VK_CMD_FILL_BUFFER 118u

/* The VkResult values of the result records. */
#define GHCI_VK_SUCCESS 0
#define GHCI_VK_ERROR_OUT_OF_HOST_MEMORY (-1)
#define GHCI_VK_ERROR_OUT_OF_DEVICE_MEMORY (-2)
#define GHCI_VK_ERROR_INITIALIZATION_FAILED (-3)
#define GHCI_VK_ERROR_DEVICE_LOST (-4)
#define GHCI_VK_ERROR_FEATURE_NOT_PRESENT (-8)
#define GHCI_VK_ERROR_UNKNOWN (-13)

#endif
