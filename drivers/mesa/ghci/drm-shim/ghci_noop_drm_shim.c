/*
 * GHCI GPU Driver
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci_noop_drm_shim.c: a ghci DRM device without a GPU, for running the
 * Vulkan driver and the compiler on a machine that has none (Mesa's
 * drm-shim, src/drm-shim/README.md):
 *
 *   LD_PRELOAD=.../libghci_noop_drm_shim.so vulkaninfo
 *
 * Buffer objects are host memory with a made-up flat GPU address; job
 * submissions do nothing.  The capability block is an example of a small
 * GHCI configuration (one shader unit, one colour attachment), or the 768
 * bytes of the file named by GHCI_SHIM_CAPS, for example one written by
 * the kernel driver's debugfs.
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan_core.h>

#include "drm-shim/drm_shim.h"
#include "drm-uapi/ghci_drm.h"
#include "ghci/ghci_cmd.h"
#include "ghci/ghci_regs.h"
#include "util/log.h"
#include "util/u_math.h"

struct ghci_shim_bo {
   struct shim_bo base;
   uint64_t gpu_addr;
   uint32_t flags;
};

static uint32_t ghci_shim_caps[GHCI_CAPS_TOTAL_DWORDS];
static uint64_t ghci_shim_next_addr = 0x100000;
static uint32_t ghci_shim_next_vm = 1;

/* The per-format bits (ghci.md 3.2.5). */
#define FMT_OPT(b)  ((uint32_t)(b))
#define FMT_LIN(b)  ((uint32_t)(b) << 9)
#define FMT_BUF(b)  ((uint32_t)(b) << 18)
#define F_SAMPLED   (1u << 0)
#define F_LINEAR    (1u << 1)
#define F_COLOR     (1u << 2)
#define F_BLEND     (1u << 3)
#define F_DS        (1u << 4)
#define F_VERTEX    (1u << 5)
#define F_BLIT_SRC  (1u << 6)
#define F_BLIT_DST  (1u << 7)
#define F_STORAGE   (1u << 8)
#define B_UNIFORM   (1u << 0)
#define B_STORAGE   (1u << 1)
#define B_VERTEX    (1u << 3)

static void
ghci_shim_example_caps(uint32_t *c)
{
   const uint32_t rt = F_SAMPLED | F_LINEAR | F_COLOR | F_BLEND |
                       F_BLIT_SRC | F_BLIT_DST;

   memset(c, 0, GHCI_CAPS_TOTAL_BYTES);
   c[GHCI_CAPS_WORD_BLOCK_ID] = 0x50414347u; /* "GCAP" */
   c[GHCI_CAPS_WORD_BLOCK_INFO] = (GHCI_CAPS_TOTAL_DWORDS << 16) | 1u;
   c[GHCI_CAPS_WORD_DEVICE_CAPS] = GHCI_DEV_CAP_GSI1 |
                                   GHCI_DEV_CAP_SECONDARY_RING |
                                   GHCI_DEV_CAP_INDIRECT_DRAW |
                                   GHCI_DEV_CAP_DISP |
                                   (8u << 8) | (1u << 16);
   c[GHCI_CAPS_WORD_EXT_CAP_FEATURE] = (1u << 16) | (16u << 20) |
                                       GHCI_EXT_FEAT_HW_CURSOR;
   c[GHCI_CAPS_WORD_EXT_CAP_FMT0] = GHCI_EXT_FMT_TU_BILINEAR | (1u << 9) |
                                    (1u << 12);
   c[GHCI_CAPS_WORD_RESIDENT_WARPS] = (32u << 16) | 16u;
   c[GHCI_CAPS_WORD_NATIVE_ISA_ID] = 0x47534931u; /* "GSI1" */
   c[GHCI_CAPS_WORD_GCLK_HZ] = 100000000u;
   c[GHCI_CAPS_WORD_VENDOR_ID] = 0x10ee;
   c[GHCI_CAPS_WORD_DEVICE_ID] = 0x7024;
   c[GHCI_CAPS_WORD_FMT_LIMITS] = 1;
   c[GHCI_CAPS_WORD_FMT_FIRST_REG] = GHCI_CAPS_WORD_FMT_BASE;
   c[GHCI_CAPS_WORD_FMT_COUNT_REG] = 157;

   uint32_t *f = &c[GHCI_CAPS_WORD_FMT_BASE];
   f[VK_FORMAT_R8G8B8A8_UNORM] = FMT_OPT(rt) | FMT_LIN(rt) |
                                 FMT_BUF(B_VERTEX | B_UNIFORM);
   f[VK_FORMAT_B8G8R8A8_UNORM] = FMT_OPT(rt) | FMT_LIN(rt);
   f[VK_FORMAT_R8G8B8A8_SRGB] = FMT_OPT(rt) | FMT_LIN(rt);
   f[VK_FORMAT_B8G8R8A8_SRGB] = FMT_OPT(rt) | FMT_LIN(rt);
   f[VK_FORMAT_R5G6B5_UNORM_PACK16] = FMT_OPT(rt) | FMT_LIN(rt);
   f[VK_FORMAT_D24_UNORM_S8_UINT] = FMT_OPT(F_DS | F_SAMPLED);
   f[VK_FORMAT_D32_SFLOAT] = FMT_OPT(F_DS | F_SAMPLED);
   f[VK_FORMAT_R32_SFLOAT] = FMT_OPT(F_SAMPLED | F_STORAGE) |
                             FMT_BUF(B_VERTEX | B_UNIFORM | B_STORAGE);
   f[VK_FORMAT_R32G32_SFLOAT] = FMT_BUF(B_VERTEX | B_UNIFORM | B_STORAGE);
   f[VK_FORMAT_R32G32B32_SFLOAT] = FMT_BUF(B_VERTEX);
   f[VK_FORMAT_R32G32B32A32_SFLOAT] = FMT_OPT(F_SAMPLED | F_STORAGE) |
                                      FMT_BUF(B_VERTEX | B_UNIFORM |
                                              B_STORAGE);
   f[VK_FORMAT_R32_UINT] = FMT_OPT(F_STORAGE) |
                           FMT_BUF(B_VERTEX | B_UNIFORM | B_STORAGE);
}

static void
ghci_shim_load_caps(void)
{
   const char *path = getenv("GHCI_SHIM_CAPS");

   ghci_shim_example_caps(ghci_shim_caps);
   if (!path)
      return;

   FILE *f = fopen(path, "rb");
   if (!f || fread(ghci_shim_caps, 1, GHCI_CAPS_TOTAL_BYTES, f) !=
                GHCI_CAPS_TOTAL_BYTES) {
      mesa_loge("ghci drm-shim: can not read 768 bytes from %s", path);
      abort();
   }
   fclose(f);
}

static int
ghci_shim_fail(int error)
{
   errno = error;
   return -1;
}

static int
ghci_shim_answer(struct drm_ghci_dev_query *q, const void *data, uint32_t size)
{
   if (q->size)
      memcpy((void *)(uintptr_t)q->pointer, data, MIN2(q->size, size));
   q->size = size;
   return 0;
}

static int
ghci_shim_dev_query(int fd, unsigned long request, void *arg)
{
   struct drm_ghci_dev_query *q = arg;

   switch (q->type) {
   case DRM_GHCI_DEV_QUERY_INFO: {
      const struct drm_ghci_dev_info info = {
         .ghci_version = GHCI_VERSION_VALUE,
         .boot_caps = GHCI_BOOT_CAP_CP,
         .device_caps = ghci_shim_caps[GHCI_CAPS_WORD_DEVICE_CAPS],
         .ext_cap_feature = ghci_shim_caps[GHCI_CAPS_WORD_EXT_CAP_FEATURE],
         .address_mode = DRM_GHCI_ADDRESS_FLAT,
         .protection = DRM_GHCI_PROTECTION_IOMMU,
         .pci_vendor = 0x10ee,
         .pci_device = 0x7024,
         .caps_bytes = GHCI_CAPS_TOTAL_BYTES,
         .gclk_hz = ghci_shim_caps[GHCI_CAPS_WORD_GCLK_HZ],
         .max_chunks = 64,
         .max_chunk_dwords = 1u << 20,
         .host_limit = 0x80000000ull,
      };
      return ghci_shim_answer(q, &info, sizeof(info));
   }
   case DRM_GHCI_DEV_QUERY_CAPS:
      return ghci_shim_answer(q, ghci_shim_caps, sizeof(ghci_shim_caps));
   default:
      return ghci_shim_fail(EINVAL);
   }
}

static int
ghci_shim_bo_create(int fd, unsigned long request, void *arg)
{
   struct shim_fd *shim_fd = drm_shim_fd_lookup(fd);
   struct drm_ghci_bo_create *create = arg;

   if (!create->size || (create->flags & ~DRM_GHCI_BO_FLAGS))
      return ghci_shim_fail(EINVAL);

   struct ghci_shim_bo *bo = calloc(1, sizeof(*bo));
   if (!bo)
      return ghci_shim_fail(ENOMEM);
   uint64_t size = ALIGN_POT(create->size, 4096);
   drm_shim_bo_init(&bo->base, size);
   bo->gpu_addr = ghci_shim_next_addr;
   bo->flags = create->flags;
   ghci_shim_next_addr += size;

   create->handle = drm_shim_bo_get_handle(shim_fd, &bo->base);
   create->gpu_addr = bo->gpu_addr;
   drm_shim_bo_put(&bo->base);
   return 0;
}

static int
ghci_shim_bo_mmap_offset(int fd, unsigned long request, void *arg)
{
   struct shim_fd *shim_fd = drm_shim_fd_lookup(fd);
   struct drm_ghci_bo_mmap_offset *req = arg;
   struct shim_bo *bo = drm_shim_bo_lookup(shim_fd, req->handle);

   if (!bo)
      return ghci_shim_fail(ENOENT);
   req->offset = drm_shim_bo_get_mmap_offset(shim_fd, bo);
   drm_shim_bo_put(bo);
   return 0;
}

static int
ghci_shim_bo_info(int fd, unsigned long request, void *arg)
{
   struct shim_fd *shim_fd = drm_shim_fd_lookup(fd);
   struct drm_ghci_bo_info *req = arg;
   struct shim_bo *bo = drm_shim_bo_lookup(shim_fd, req->handle);

   if (!bo)
      return ghci_shim_fail(ENOENT);
   req->size = bo->size;
   req->gpu_addr = ((struct ghci_shim_bo *)bo)->gpu_addr;
   req->flags = ((struct ghci_shim_bo *)bo)->flags;
   drm_shim_bo_put(bo);
   return 0;
}

static int
ghci_shim_vm_create(int fd, unsigned long request, void *arg)
{
   struct drm_ghci_vm_create *req = arg;

   if (req->flags)
      return ghci_shim_fail(EINVAL);
   req->vm_id = ghci_shim_next_vm++;
   return 0;
}

static int
ghci_shim_noop(int fd, unsigned long request, void *arg)
{
   return 0;
}

static int
ghci_shim_unsupported(int fd, unsigned long request, void *arg)
{
   /* VM_BIND is for devices with a GPU MMU; the shim is flat. */
   return ghci_shim_fail(EOPNOTSUPP);
}

static ioctl_fn_t ghci_shim_ioctls[] = {
   [DRM_GHCI_DEV_QUERY] = ghci_shim_dev_query,
   [DRM_GHCI_BO_CREATE] = ghci_shim_bo_create,
   [DRM_GHCI_BO_MMAP_OFFSET] = ghci_shim_bo_mmap_offset,
   [DRM_GHCI_BO_INFO] = ghci_shim_bo_info,
   [DRM_GHCI_VM_CREATE] = ghci_shim_vm_create,
   [DRM_GHCI_VM_DESTROY] = ghci_shim_noop,
   [DRM_GHCI_VM_BIND] = ghci_shim_unsupported,
   [DRM_GHCI_SUBMIT] = ghci_shim_noop,
   [DRM_GHCI_VM_GET_STATE] = ghci_shim_noop,
   [DRM_GHCI_BO_WAIT] = ghci_shim_noop,
};

void
drm_shim_driver_init(void)
{
   ghci_shim_load_caps();

   shim_device.driver_name = DRM_GHCI_DRIVER_NAME;
   shim_device.driver_ioctls = ghci_shim_ioctls;
   shim_device.driver_ioctl_count = ARRAY_SIZE(ghci_shim_ioctls);
   shim_device.version_major = 1;
   shim_device.version_minor = 0;

   /* The KC705 board's PCIe IDs (boards/kc705). */
   drm_shim_pci_device_setup(0x10ee, 0x7024, "0000:01:00.0",
                             DRM_GHCI_DRIVER_NAME);
}
