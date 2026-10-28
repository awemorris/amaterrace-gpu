/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci_cmd.c: GHCI 1.0 Structured Command Parser and Immutable PSO Dispatcher.
 */

#include "fw.h"
#include "hw.h"
#include "ghci_cmd.h"
#include "ghci_packets.h"
#include "ghci_regs.h"

/*
 * CMD_BIND_PIPELINE (0x20): [u64 pso_gpu_va]
 * Fetches in-memory immutable GhciPipelineState and dispatches to hardware.
 */
void
fw_cmd_bind_pipeline_pso(
	struct fw_command *command)
{
	GhciPipelineState pso;
	uint64_t pso_gpu_va;
	int error;

	pso_gpu_va = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;

	/* DMA fetch 128-byte GhciPipelineState from shared memory */
	error = fw_copy_in((uint32_t)pso_gpu_va, &pso, sizeof(GhciPipelineState));
	if (error != 0) {
		command->status = FW_VK_ERROR_DEVICE_LOST;
		return;
	}

	fw_emit_begin(NULL, command->tag);

	/* Dispatch shader programs & resource limits */
	if (pso.vs_code_va != 0)
		fw_emit_set(GHCI_S_VS_BASE, (uint32_t)pso.vs_code_va);
	if (pso.fs_code_va != 0)
		fw_emit_set(GHCI_S_FS_BASE, (uint32_t)pso.fs_code_va);
	if (pso.cs_code_va != 0)
		fw_emit_set(GHCI_S_CS_BASE, (uint32_t)pso.cs_code_va);

	fw_emit_set(GHCI_S_VS_WORDS, pso.shader_resource_limits);
	fw_emit_set(GHCI_S_VARYING_COUNT, (pso.shader_resource_limits >> 24) & 0x1Fu);

	/* Dispatch rasterizer & cull state */
	fw_emit_set(GHCI_S_CULL, (pso.raster_state & 3u) | (((pso.raster_state >> 2) & 1u) << 2));
	fw_emit_set(GHCI_S_RAST_MODE, (pso.flags & 7u) | (((pso.raster_state >> 3) & 3u) << 4));
	fw_emit_set(GHCI_S_LINE_WIDTH, (pso.raster_state >> 6) & 0xFFu);

	/* Dispatch depth & stencil state */
	fw_emit_set(GHCI_S_DEPTH, (pso.depth_stencil_state & 3u) | (((pso.depth_stencil_state >> 2) & 7u) << 2));
	fw_emit_set(GHCI_S_DEPTH_CLAMP, (pso.flags >> 4) & 1u);

	/* Dispatch blend state */
	fw_emit_set(GHCI_S_BLEND, pso.blend_state & 0x07FFFFFFu);
	fw_emit_set(GHCI_S_WRITE_MASK, (pso.blend_state >> 27) & 0x0Fu);
	fw_emit_set(GHCI_S_LOGIC_OP, ((pso.flags >> 5) & 1u) | (((pso.flags >> 6) & 0xFu) << 1));

	/* Dispatch topology & vertex input */
	fw_emit_set(GHCI_S_TOPOLOGY, pso.flags & 7u);
	fw_emit_set(GHCI_S_PRIM_RESTART, (pso.flags >> 3) & 1u);

	/* Scan vertex attributes and autonomously configure ATTR_DST (§12.10.3) */
	{
		uint32_t i, base_i = 0;
		for (i = 0; i < 16; i++) {
			uint32_t raw_attr = pso.attributes[i];
			uint32_t fmt_id = raw_attr & 0xFFu;
			if (fmt_id != 0) {
				const struct fw_format *fmt = fw_format_find(fmt_id);
				uint32_t comps = (fmt != NULL && fmt->components >= 1 && fmt->components <= 4) ? fmt->components : 4;
				uint32_t attr_dst = (base_i & 0x3Fu) | (((comps - 1u) & 3u) << 6) | (fmt_id << 24);
				fw_emit_set(GHCI_S_ATTR_DST + i, attr_dst);
				base_i += comps;
			} else {
				fw_emit_set(GHCI_S_ATTR_DST + i, 0);
			}
		}
	}

	/* Compute stage configuration */
	fw_emit_set(GHCI_S_WG_SIZE, pso.compute_local_size);
	fw_emit_set(GHCI_S_LDS_BYTES, pso.compute_lds_and_flags & 0xFFFFu);

	(void)fw_emit_end();
}

/*
 * CMD_SET_VIEWPORT (0x24): Dynamic viewport bounds (X, Y, W, H, MinZ, MaxZ)
 */
void
fw_cmd_set_viewport_packet(
	struct fw_command *command)
{
	uint32_t x = fw_reader_u32(command->reader);
	uint32_t y = fw_reader_u32(command->reader);
	uint32_t w = fw_reader_u32(command->reader);
	uint32_t h = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader); /* min_depth */
	(void)fw_reader_u32(command->reader); /* max_depth */
	if (command->reader->error)
		return;

	fw_emit_begin(NULL, command->tag);
	fw_emit_set(GHCI_S_VIEWPORT + 0u, x);
	fw_emit_set(GHCI_S_VIEWPORT + 1u, y);
	fw_emit_set(GHCI_S_VIEWPORT + 2u, w);
	fw_emit_set(GHCI_S_VIEWPORT + 3u, h);
	(void)fw_emit_end();
}

/*
 * CMD_SET_SCISSOR (0x25): Dynamic scissor rectangle
 */
void
fw_cmd_set_scissor_packet(
	struct fw_command *command)
{
	uint32_t x = fw_reader_u32(command->reader);
	uint32_t y = fw_reader_u32(command->reader);
	uint32_t w = fw_reader_u32(command->reader);
	uint32_t h = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;

	fw_emit_begin(NULL, command->tag);
	fw_emit_set(GHCI_S_SCISSOR_MIN, (x & 0xFFFFu) | ((y & 0xFFFFu) << 16));
	fw_emit_set(GHCI_S_SCISSOR_MAX, ((x + w) & 0xFFFFu) | (((y + h) & 0xFFFFu) << 16));
	(void)fw_emit_end();
}

/*
 * CMD_DRAW (0x27): Direct non-indexed primitive draw
 */
void
fw_cmd_draw_packet(
	struct fw_command *command)
{
	uint32_t vertex_count = fw_reader_u32(command->reader);
	uint32_t instance_count = fw_reader_u32(command->reader);
	uint32_t first_vertex = fw_reader_u32(command->reader);
	uint32_t first_instance = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;

	fw_emit_begin(NULL, command->tag);
	fw_emit_set(GHCI_S_COUNT, vertex_count);
	fw_emit_set(GHCI_S_INSTANCE_COUNT, instance_count);
	fw_emit_set(GHCI_S_FIRST, first_vertex);
	fw_emit_set(GHCI_S_FIRST_INSTANCE, first_instance);
	fw_emit_op(GHCI_OP_DRAW, 0, NULL, 0);
	(void)fw_emit_end();
}

/*
 * CMD_DRAW_INDEXED (0x28): Indexed primitive draw
 */
void
fw_cmd_draw_indexed_packet(
	struct fw_command *command)
{
	uint32_t index_count = fw_reader_u32(command->reader);
	uint32_t instance_count = fw_reader_u32(command->reader);
	uint32_t first_index = fw_reader_u32(command->reader);
	uint32_t vertex_offset = fw_reader_u32(command->reader);
	uint32_t first_instance = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;

	fw_emit_begin(NULL, command->tag);
	fw_emit_set(GHCI_S_COUNT, index_count);
	fw_emit_set(GHCI_S_INSTANCE_COUNT, instance_count);
	fw_emit_set(GHCI_S_FIRST, first_index);
	fw_emit_set(GHCI_S_VERTEX_OFFSET, vertex_offset);
	fw_emit_set(GHCI_S_FIRST_INSTANCE, first_instance);
	fw_emit_op(GHCI_OP_DRAW, 0, NULL, 0);
	(void)fw_emit_end();
}

/*
 * CMD_DISPATCH (0x30): Compute shader workgroup dispatch
 */
void
fw_cmd_dispatch_packet(
	struct fw_command *command)
{
	uint32_t groups[3];
	groups[0] = fw_reader_u32(command->reader);
	groups[1] = fw_reader_u32(command->reader);
	groups[2] = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;

	fw_emit_begin(NULL, command->tag);
	fw_emit_set(GHCI_S_GRID_X, groups[0]);
	fw_emit_set(GHCI_S_GRID_Y, groups[1]);
	fw_emit_set(GHCI_S_GRID_Z, groups[2]);
	fw_emit_op(GHCI_OP_DISPATCH, 0, groups, 3);
	(void)fw_emit_end();
}

/*
 * CMD_BARRIER (0x31): Pipeline barrier
 */
void
fw_cmd_barrier_packet(
	struct fw_command *command)
{
	(void)fw_reader_u32(command->reader); /* src_stage_mask */
	(void)fw_reader_u32(command->reader); /* dst_stage_mask */
	(void)fw_reader_u32(command->reader); /* flags */
	if (command->reader->error)
		return;

	fw_emit_begin(NULL, command->tag);
	fw_emit_op(GHCI_OP_WAIT_IDLE, 0, NULL, 0);
	fw_emit_op(GHCI_OP_INVALIDATE, 0x0Fu, NULL, 0);
	(void)fw_emit_end();
}

/*
 * CMD_EXECUTE_COMMANDS (0x32): UMA Zero-Copy Secondary Command Stream Fetch
 */
void
fw_cmd_execute_commands_packet(
	struct fw_command *command)
{
	uint64_t secondary_va;
	uint32_t command_dwords;
	struct fw_reader sec_reader;
	struct fw_command sub_cmd;
	uint32_t hdr;
	uint32_t opcode;
	uint32_t dw_count;

	secondary_va = fw_reader_u64(command->reader);
	command_dwords = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;

	fw_reader_init(&sec_reader, (uint32_t)secondary_va, command_dwords * 4u);
	while (!sec_reader.error && (sec_reader.end > sec_reader.addr)) {
		hdr = fw_reader_u32(&sec_reader);
		opcode = GHCI_HEADER_OPCODE(hdr);
		dw_count = GHCI_HEADER_DWORDS(hdr);
		if (dw_count < 1u)
			break;

		sub_cmd.number = opcode;
		sub_cmd.tag = command->tag;
		sub_cmd.reader = &sec_reader;
		sub_cmd.in_frame = 1;
		sub_cmd.reply = 0;
		fw_command_decode(&sub_cmd);
	}
}
