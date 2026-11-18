/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci_layout.h: the memory layout of an image (docs/ghci.md sections 8.4,
 * 8.5 and 12.11, draft), which the command processor's firmware and the
 * driver (vkGetImageMemoryRequirements, vkGetImageSubresourceLayout) both
 * compute, so they agree on every byte.  Version 1 lays every image out in
 * linear rows (no 4x4 tiles).
 *
 *   Level l is w_l x h_l (x d_l for 3D) texels, w_l = max(1, width >> l)
 *   (the same for h and d).  A row is w_l texels of ps bytes; an image
 *   that may be a colour or depth/stencil attachment rounds w_l up to even
 *   (the render output writes a quad's row as one run of 2 ps bytes), a
 *   multisampled image (one level) has rows of roundup(w, 2) x S texels.
 *   A compressed format has rows of ceil(w_l / 4) blocks, each four texel
 *   rows high.  A level's plane (one slice) is its rows, rounded up to a
 *   multiple of 64 bytes; a layer holds the levels back to back (a 3D
 *   level's d_l slices one after the other); the layers are a layer
 *   stride apart, the sum of the levels.  The image is 64-byte aligned.
 */

#ifndef GHCI_LAYOUT_H
#define GHCI_LAYOUT_H

#include <stdint.h>

/* The alignment of an image's memory and of each plane. */
#define GHCI_LAYOUT_ALIGN 64u

/*
 * What decides an image's layout: a texel's bytes (or a 4x4 block's,
 * with `block`), the extent, the levels, the layers, the samples and
 * whether the image may be an attachment.
 */
struct ghci_layout_image {
	uint32_t texel_bytes;
	uint32_t block;
	uint32_t width;
	uint32_t height;
	uint32_t depth;
	uint32_t levels;
	uint32_t layers;
	uint32_t samples;
	uint32_t attachment;
};

/* The extent of a level: max(1, size >> level). */
static inline uint32_t
ghci_layout_extent(
	uint32_t size,
	uint32_t level)
{
	uint32_t extent;

	/* Halves per level, down to one. */
	extent = size >> level;
	if (extent == 0)
		extent = 1;

	/* Succeeded: the level's extent. */
	return extent;
}

/* The bytes of one row of a level (a row of blocks for a compressed format). */
static inline uint32_t
ghci_layout_row(
	const struct ghci_layout_image *image,
	uint32_t level)
{
	uint32_t width;

	/* A compressed format: whole 4x4 blocks. */
	width = ghci_layout_extent(image->width, level);
	if (image->block)
		return (width + 3u) / 4u * image->texel_bytes;

	/* A multisampled image: every sample of an even number of texels. */
	if (image->samples > 1u)
		return (width + 1u) / 2u * 2u * image->samples * image->texel_bytes;

	/* An attachment: an even number of texels. */
	if (image->attachment)
		width = (width + 1u) / 2u * 2u;

	/* Succeeded: the row. */
	return width * image->texel_bytes;
}

/* The bytes of one slice of a level, rounded up to the alignment. */
static inline uint32_t
ghci_layout_plane(
	const struct ghci_layout_image *image,
	uint32_t level)
{
	uint32_t rows;
	uint32_t bytes;

	/* The rows: texel rows, or rows of blocks. */
	rows = ghci_layout_extent(image->height, level);
	if (image->block)
		rows = (rows + 3u) / 4u;

	/* The rows, rounded up. */
	bytes = rows * ghci_layout_row(image, level);
	bytes = (bytes + GHCI_LAYOUT_ALIGN - 1u) / GHCI_LAYOUT_ALIGN * GHCI_LAYOUT_ALIGN;

	/* Succeeded: the plane. */
	return bytes;
}

/* The bytes of a whole level of one layer (a 3D level's slices together). */
static inline uint32_t
ghci_layout_level_bytes(
	const struct ghci_layout_image *image,
	uint32_t level)
{
	uint32_t slices;

	/* One slice, or d_l of a 3D image. */
	slices = ghci_layout_extent(image->depth, level);

	/* Succeeded: the level. */
	return ghci_layout_plane(image, level) * slices;
}

/* The offset of a level from its layer's start. */
static inline uint32_t
ghci_layout_level_offset(
	const struct ghci_layout_image *image,
	uint32_t level)
{
	uint32_t offset;
	uint32_t index;

	/* The levels before it. */
	offset = 0;
	for (index = 0; index < level; index++)
		offset += ghci_layout_level_bytes(image, index);

	/* Succeeded: the level's offset. */
	return offset;
}

/* The bytes from one layer to the next. */
static inline uint32_t
ghci_layout_layer_stride(
	const struct ghci_layout_image *image)
{
	/* Every level of the layer. */
	return ghci_layout_level_offset(image, image->levels);
}

/* The bytes of the whole image. */
static inline uint32_t
ghci_layout_size(
	const struct ghci_layout_image *image)
{
	/* Every layer. */
	return ghci_layout_layer_stride(image) * image->layers;
}

#endif /* GHCI_LAYOUT_H */
