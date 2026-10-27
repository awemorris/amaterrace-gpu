/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci_frame.h: the class V packets of GHCI 1.0 (docs/ghci.md section 7,
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
 *   BUFFER_GRANT  [u32 session][u32 access][u64 GPU address][u64 bytes]
 *   BUFFER_REVOKE [u32 session][u64 GPU address][u64 bytes]
 */
#define GHCI_GPU_OP_SESSION_OPEN 0x10100u
#define GHCI_GPU_OP_SESSION_CLOSE 0x10101u
#define GHCI_GPU_OP_MEMORY 0x10102u
#define GHCI_GPU_OP_PROGRAM 0x10103u
#define GHCI_GPU_OP_NATIVE 0x10104u
#define GHCI_GPU_OP_FRAME 0x10105u
#define GHCI_GPU_OP_BUFFER_GRANT 0x10106u
#define GHCI_GPU_OP_BUFFER_REVOKE 0x10107u
#define GHCI_GPU_OP_VM_MAP 0x10110u
#define GHCI_GPU_OP_VM_UNMAP 0x10111u

/* VM_MAP / VM_UNMAP flags (docs/ghci.md section 11.2). */
#define GHCI_VM_FLAG_READ       (1u << 0)
#define GHCI_VM_FLAG_WRITE      (1u << 1)
#define GHCI_VM_FLAG_EXEC       (1u << 2)
#define GHCI_VM_FLAG_COHERENT   (1u << 3)
#define GHCI_VM_FLAG_WC         (1u << 4)

/* SESSION_OPEN flags and BUFFER_GRANT access (docs/ghci.md section 11.6). */
#define GHCI_SESSION_PROTECTED 0x1u
#define GHCI_GRANT_READ 0x1u
#define GHCI_GRANT_WRITE 0x2u

/* MEMORY flags (docs/ghci.md sections 7.2 and 11.6). */
#define GHCI_MEMORY_HOST_VISIBLE 0x1u
#define GHCI_MEMORY_IMPORTED 0x2u
#define GHCI_MEMORY_READ_ONLY 0x4u

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

/*
 * GHCI_HEAP [u64 GPU address][u64 bytes][u32 warps] (draft): the range the
 * driver lends the firmware for its objects and recordings, line aligned,
 * and the warps the GPU runs at once (NSU x NWARPS, for the programs'
 * scratch memory; 0: the firmware's own number); taken only as a packet
 * in the ring while no session is open.
 */
#define GHCI_GPU_OP_HEAP 0x10108u

/*
 * INIT and the diagnostics (draft, docs/ghci.md section 7.2), packets in
 * the ring only, each answered with a reply of GHCI_REPLY_WORDS words at
 * dword3 (with GHCI_V_RESULT): word 0 the VkResult, word 1 the aux, the
 * words the gpu-op does not name 0.
 *   INIT        [u32 token][u32 protocol]
 *   DIAG_ECHO   [u32 count][count words]
 *   DIAG_WRITE  [u64 address][u32 bytes][u32 pattern][u32 step]
 *   DIAG_SUM    [u64 address][u32 bytes]
 */
#define GHCI_GPU_OP_INIT 0x10109u
#define GHCI_GPU_OP_DIAG_ECHO 0x1010Au
#define GHCI_GPU_OP_DIAG_WRITE 0x1010Bu
#define GHCI_GPU_OP_DIAG_SUM 0x1010Cu

/* The words of a reply, and the protocol of INIT ([31:16] major, [15:0] minor). */
#define GHCI_REPLY_WORDS 16u
#define GHCI_INIT_PROTOCOL 0x00010000u

/* INIT's reply: the words after the VkResult and the aux (the token). */
#define GHCI_INIT_NOT_TOKEN 2u
#define GHCI_INIT_VERSION 3u
#define GHCI_INIT_PROTOCOL_WORD 4u
#define GHCI_INIT_FEATURES 5u
#define GHCI_INIT_LINE 6u
#define GHCI_INIT_SESSIONS 7u
#define GHCI_INIT_PACKET 8u
#define GHCI_INIT_COMMIT_HASH 9u

/* Bidirectional INIT handshake acknowledgement struct (4 words). */
struct ghci_init_ack {
	uint32_t seq_no;
	uint32_t fw_version;
	uint32_t fw_commit_hash;
	uint32_t negotiated_features;
};

/* INIT's features. */
#define GHCI_INIT_F_DIAG 0x1u	/* DIAG_ECHO, DIAG_WRITE, DIAG_SUM */
#define GHCI_INIT_F_VULKAN 0x2u	/* HEAP and the sessions' Vulkan objects */
#define GHCI_INIT_F_PROT 0x4u	/* session protection */
#define GHCI_INIT_F_HEAP 0x8u	/* a heap is lent */

/* DIAG_ECHO's most words; DIAG_WRITE's and DIAG_SUM's most bytes. */
#define GHCI_DIAG_ECHO_WORDS 14u
#define GHCI_DIAG_BYTES_MAX 0x100000u

/* DIAG_SUM's reply: the sums, the first words, the last word. */
#define GHCI_DIAG_SUM_PLAIN 2u
#define GHCI_DIAG_SUM_WEIGHTED 3u
#define GHCI_DIAG_SUM_FIRST 4u
#define GHCI_DIAG_SUM_LAST 8u

/* The Vulkan gpu-ops the Amaterrace firmware decodes (zedBSD gpu-op.h). */
#define GHCI_VK_DESTROY_DEVICE 12u
#define GHCI_VK_QUEUE_SUBMIT 18u
#define GHCI_VK_FREE_MEMORY 22u
#define GHCI_VK_BIND_BUFFER_MEMORY 28u
#define GHCI_VK_BIND_IMAGE_MEMORY 29u
#define GHCI_VK_CREATE_SEMAPHORE 40u
#define GHCI_VK_DESTROY_SEMAPHORE 41u
#define GHCI_VK_CREATE_EVENT 42u
#define GHCI_VK_DESTROY_EVENT 43u
#define GHCI_VK_CREATE_QUERY_POOL 47u
#define GHCI_VK_DESTROY_QUERY_POOL 48u
#define GHCI_VK_CREATE_BUFFER 50u
#define GHCI_VK_DESTROY_BUFFER 51u
#define GHCI_VK_CREATE_BUFFER_VIEW 52u
#define GHCI_VK_DESTROY_BUFFER_VIEW 53u
#define GHCI_VK_CREATE_IMAGE 54u
#define GHCI_VK_DESTROY_IMAGE 55u
#define GHCI_VK_CREATE_IMAGE_VIEW 57u
#define GHCI_VK_DESTROY_IMAGE_VIEW 58u
#define GHCI_VK_CREATE_GRAPHICS_PIPELINES 65u
#define GHCI_VK_CREATE_COMPUTE_PIPELINES 66u
#define GHCI_VK_DESTROY_PIPELINE 67u
#define GHCI_VK_CREATE_PIPELINE_LAYOUT 68u
#define GHCI_VK_DESTROY_PIPELINE_LAYOUT 69u
#define GHCI_VK_CREATE_SAMPLER 70u
#define GHCI_VK_DESTROY_SAMPLER 71u
#define GHCI_VK_CREATE_DESCRIPTOR_SET_LAYOUT 72u
#define GHCI_VK_DESTROY_DESCRIPTOR_SET_LAYOUT 73u
#define GHCI_VK_CREATE_DESCRIPTOR_POOL 74u
#define GHCI_VK_DESTROY_DESCRIPTOR_POOL 75u
#define GHCI_VK_RESET_DESCRIPTOR_POOL 76u
#define GHCI_VK_ALLOCATE_DESCRIPTOR_SETS 77u
#define GHCI_VK_FREE_DESCRIPTOR_SETS 78u
#define GHCI_VK_UPDATE_DESCRIPTOR_SETS 79u
#define GHCI_VK_CREATE_FRAMEBUFFER 80u
#define GHCI_VK_DESTROY_FRAMEBUFFER 81u
#define GHCI_VK_CREATE_RENDER_PASS 82u
#define GHCI_VK_DESTROY_RENDER_PASS 83u
#define GHCI_VK_CREATE_COMMAND_POOL 85u
#define GHCI_VK_DESTROY_COMMAND_POOL 86u
#define GHCI_VK_RESET_COMMAND_POOL 87u
#define GHCI_VK_ALLOCATE_COMMAND_BUFFERS 88u
#define GHCI_VK_FREE_COMMAND_BUFFERS 89u
#define GHCI_VK_BEGIN_COMMAND_BUFFER 90u
#define GHCI_VK_END_COMMAND_BUFFER 91u
#define GHCI_VK_RESET_COMMAND_BUFFER 92u
#define GHCI_VK_CMD_BIND_PIPELINE 93u
#define GHCI_VK_CMD_SET_VIEWPORT 94u
#define GHCI_VK_CMD_SET_SCISSOR 95u
#define GHCI_VK_CMD_SET_LINE_WIDTH 96u
#define GHCI_VK_CMD_SET_DEPTH_BIAS 97u
#define GHCI_VK_CMD_SET_BLEND_CONSTANTS 98u
#define GHCI_VK_CMD_SET_DEPTH_BOUNDS 99u
#define GHCI_VK_CMD_SET_STENCIL_COMPARE_MASK 100u
#define GHCI_VK_CMD_SET_STENCIL_WRITE_MASK 101u
#define GHCI_VK_CMD_SET_STENCIL_REFERENCE 102u
#define GHCI_VK_CMD_BIND_DESCRIPTOR_SETS 103u
#define GHCI_VK_CMD_BIND_INDEX_BUFFER 104u
#define GHCI_VK_CMD_BIND_VERTEX_BUFFERS 105u
#define GHCI_VK_CMD_DRAW 106u
#define GHCI_VK_CMD_DRAW_INDEXED 107u
#define GHCI_VK_CMD_DRAW_INDIRECT 108u
#define GHCI_VK_CMD_DRAW_INDEXED_INDIRECT 109u
#define GHCI_VK_CMD_DISPATCH 110u
#define GHCI_VK_CMD_DISPATCH_INDIRECT 111u
#define GHCI_VK_CMD_COPY_BUFFER 112u
#define GHCI_VK_CMD_COPY_IMAGE 113u
#define GHCI_VK_CMD_BLIT_IMAGE 114u
#define GHCI_VK_CMD_COPY_BUFFER_TO_IMAGE 115u
#define GHCI_VK_CMD_COPY_IMAGE_TO_BUFFER 116u
#define GHCI_VK_CMD_UPDATE_BUFFER 117u
#define GHCI_VK_CMD_FILL_BUFFER 118u
#define GHCI_VK_CMD_CLEAR_COLOR_IMAGE 119u
#define GHCI_VK_CMD_CLEAR_DEPTH_STENCIL_IMAGE 120u
#define GHCI_VK_CMD_CLEAR_ATTACHMENTS 121u
#define GHCI_VK_CMD_RESOLVE_IMAGE 122u
#define GHCI_VK_CMD_SET_EVENT 123u
#define GHCI_VK_CMD_RESET_EVENT 124u
#define GHCI_VK_CMD_WAIT_EVENTS 125u
#define GHCI_VK_CMD_PIPELINE_BARRIER 126u
#define GHCI_VK_CMD_BEGIN_QUERY 127u
#define GHCI_VK_CMD_END_QUERY 128u
#define GHCI_VK_CMD_RESET_QUERY_POOL 129u
#define GHCI_VK_CMD_WRITE_TIMESTAMP 130u
#define GHCI_VK_CMD_COPY_QUERY_POOL_RESULTS 131u
#define GHCI_VK_CMD_PUSH_CONSTANTS 132u
#define GHCI_VK_CMD_BEGIN_RENDER_PASS 133u
#define GHCI_VK_CMD_NEXT_SUBPASS 134u
#define GHCI_VK_CMD_END_RENDER_PASS 135u
#define GHCI_VK_CMD_EXECUTE_COMMANDS 136u
#define GHCI_VK_CMD_DRAW_MESH_TASKS 137u

/* The VkResult values of the result records. */
#define GHCI_VK_SUCCESS 0
#define GHCI_VK_ERROR_OUT_OF_HOST_MEMORY (-1)
#define GHCI_VK_ERROR_OUT_OF_DEVICE_MEMORY (-2)
#define GHCI_VK_ERROR_INITIALIZATION_FAILED (-3)
#define GHCI_VK_ERROR_DEVICE_LOST (-4)
#define GHCI_VK_ERROR_FEATURE_NOT_PRESENT (-8)
#define GHCI_VK_ERROR_UNKNOWN (-13)

#endif
