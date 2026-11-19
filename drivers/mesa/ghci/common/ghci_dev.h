/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci_dev.h: the user-space side of the ghci kernel interface
 * (drm-uapi/ghci_drm.h).  The Vulkan driver, the tools and the tests share
 * it.  Every function returns 0 or a negative errno.
 */

#ifndef GHCI_DEV_H
#define GHCI_DEV_H

#include <stdbool.h>
#include <stdint.h>

#include "drm-uapi/ghci_drm.h"
#include "amaterrace/ghci_cmd.h"
#include "amaterrace/ghci_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Word 0 of the capability block: "GCAP" (ghci.md 3.2.5). */
#define GHCI_CAPS_BLOCK_MAGIC 0x50414347u
/* Word 6 when the GPU runs GSI1 (ghci.md 3.2.5). */
#define GHCI_CAPS_ISA_GSI1 0x47534931u

struct ghci_dev {
   int fd;
   struct drm_ghci_dev_info info;
   uint32_t caps[GHCI_CAPS_TOTAL_DWORDS];
};

/*
 * Checks that fd is a ghci DRM device and reads its description and its
 * capability block.  Returns -ENODEV for a DRM device of another driver.
 * The fd stays the caller's.
 */
int ghci_dev_init(struct ghci_dev *dev, int fd);

static inline uint32_t
ghci_dev_caps(const struct ghci_dev *dev, unsigned word)
{
   return word < GHCI_CAPS_TOTAL_DWORDS ? dev->caps[word] : 0;
}

/* A field of a capability word: bits hi..lo. */
static inline uint32_t
ghci_bits(uint32_t word, unsigned hi, unsigned lo)
{
   return (word >> lo) & ((hi - lo == 31) ? ~0u : ((1u << (hi - lo + 1)) - 1));
}

/*
 * The per-format entry of the capability block (ghci.md 3.2.5) for a
 * VkFormat value below 157, or 0.
 */
uint32_t ghci_dev_format_caps(const struct ghci_dev *dev, unsigned vk_format);

struct ghci_bo {
   uint32_t handle;
   uint32_t flags;
   uint64_t size;
   uint64_t gpu_addr;
   void *map;
};

int ghci_bo_create(struct ghci_dev *dev, uint64_t size, uint32_t flags,
                   struct ghci_bo *bo);
int ghci_bo_map(struct ghci_dev *dev, struct ghci_bo *bo);
void ghci_bo_unmap(struct ghci_bo *bo);
int ghci_bo_close(struct ghci_dev *dev, struct ghci_bo *bo);

int ghci_vm_create(struct ghci_dev *dev, uint32_t *vm_id);
int ghci_vm_destroy(struct ghci_dev *dev, uint32_t vm_id);

#ifdef __cplusplus
}
#endif

#endif /* GHCI_DEV_H */
