// SPDX-License-Identifier: Zlib
/*
 * GHCI GPU Driver
 * Copyright (C) 2026 Awe Morris
 */

/*
 * ghci_drm.h: the user interface of the Linux DRM driver for GHCI 1.0
 * GPUs (ghci.md).  The kernel module and the Mesa driver both include
 * this file; Mesa keeps a copy in include/drm-uapi/.
 *
 * Two address models share one interface:
 *
 *  - Flat (BOOT_CAPS.CAP_BOOT_HW_WALKER == 0): the GPU uses bus addresses
 *    (an IOVA when the system has an IOMMU).  The kernel chooses the
 *    address of each buffer object and returns it from
 *    DRM_IOCTL_GHCI_BO_CREATE; user space never chooses one.  Command
 *    chunks are copied by the kernel from user memory.
 *
 *  - MMU (CAP_BOOT_HW_WALKER == 1): every VM is a GHCI session with its
 *    own GPU virtual address space.  User space chooses virtual addresses
 *    and maps buffer objects with DRM_IOCTL_GHCI_VM_BIND; command chunks
 *    are GPU virtual addresses that the CP runs with CMD_EXECUTE_COMMANDS.
 *
 * The rules of the structures follow the usual DRM practice: every field
 * is naturally aligned, padding is explicit and must be zero, reserved
 * flags must be zero, and arrays are passed as struct drm_ghci_obj_array so
 * that an element may grow at its end.  The kernel rejects a stride smaller
 * than the first version of an element and ignores the tail of a larger one
 * only when that tail is zero.
 */

#ifndef GHCI_DRM_H
#define GHCI_DRM_H

#include "drm.h"

#if defined(__cplusplus)
extern "C" {
#endif

/* The name the kernel reports through DRM_IOCTL_VERSION. */
#define DRM_GHCI_DRIVER_NAME "ghci"

enum drm_ghci_ioctl_id {
	DRM_GHCI_DEV_QUERY = 0,
	DRM_GHCI_BO_CREATE,
	DRM_GHCI_BO_MMAP_OFFSET,
	DRM_GHCI_BO_INFO,
	DRM_GHCI_VM_CREATE,
	DRM_GHCI_VM_DESTROY,
	DRM_GHCI_VM_BIND,
	DRM_GHCI_SUBMIT,
	DRM_GHCI_VM_GET_STATE,
	DRM_GHCI_BO_WAIT,
};

/**
 * struct drm_ghci_obj_array - an array of objects passed to the kernel
 * @stride: the size of one element in bytes
 * @count: the number of elements
 * @array: a user pointer to the first element
 */
struct drm_ghci_obj_array {
	__u32 stride;
	__u32 count;
	__u64 array;
};

#define DRM_GHCI_OBJ_ARRAY(cnt, ptr) \
	{ .stride = sizeof((ptr)[0]), .count = (cnt), .array = (__u64)(uintptr_t)(ptr) }

/* DRM_IOCTL_GHCI_DEV_QUERY ------------------------------------------- */

enum drm_ghci_dev_query_type {
	/* struct drm_ghci_dev_info */
	DRM_GHCI_DEV_QUERY_INFO = 0,

	/*
	 * The capability block that CMD_QUERY_CAPS wrote at attach
	 * (ghci.md section 3.2.5): GHCI_CAPS_TOTAL_BYTES bytes, little-endian
	 * dwords.
	 */
	DRM_GHCI_DEV_QUERY_CAPS = 1,
};

/* How the GPU's addresses reach memory. */
enum drm_ghci_address_mode {
	/* Bus addresses (IOVA); the kernel chooses buffer addresses. */
	DRM_GHCI_ADDRESS_FLAT = 0,

	/* Per-session GPU virtual addresses; user space chooses them. */
	DRM_GHCI_ADDRESS_MMU = 1,
};

/*
 * What keeps a client from reaching memory that is not its own.  A shader
 * computes raw addresses (GSI1 lw, sw, atom), so without the GPU MMU or the
 * PROT unit no checking of commands isolates one client from another.
 */
enum drm_ghci_protection {
	/* Nothing: the GPU reaches every host address below HOST_LIMIT. */
	DRM_GHCI_PROTECTION_NONE = 0,

	/* The system IOMMU limits the GPU to mapped buffer objects. */
	DRM_GHCI_PROTECTION_IOMMU = 1,

	/* The PROT unit isolates sessions by physical granule. */
	DRM_GHCI_PROTECTION_PROT = 2,

	/* The GPU MMU isolates sessions by page table. */
	DRM_GHCI_PROTECTION_MMU = 3,
};

/* drm_ghci_dev_info.flags */
#define DRM_GHCI_DEV_INFO_IRQ		(1u << 0) /* interrupts, not polling */
#define DRM_GHCI_DEV_INFO_DISPLAY	(1u << 1) /* a DISP2 controller is driven */

/**
 * struct drm_ghci_dev_info - DRM_GHCI_DEV_QUERY_INFO
 * @ghci_version: GHCI_VERSION (0x004)
 * @boot_caps: BOOT_CAPS (0x008)
 * @device_caps: capability block word 2 (DEVICE_CAPS)
 * @ext_cap_feature: capability block word 3
 * @address_mode: enum drm_ghci_address_mode
 * @protection: enum drm_ghci_protection
 * @pci_vendor: PCI vendor ID, 0 for a platform device
 * @pci_device: PCI device ID, 0 for a platform device
 * @flags: DRM_GHCI_DEV_INFO_*
 * @caps_bytes: the size of the DRM_GHCI_DEV_QUERY_CAPS block
 * @gclk_hz: the GPU core clock (capability block word 7), for timestamps
 * @max_chunks: the most command chunks one DRM_IOCTL_GHCI_SUBMIT takes
 * @max_chunk_dwords: the most dwords in one command chunk
 * @va_start: MMU: the first GPU virtual address user space may bind
 * @va_end: MMU: the end (exclusive) of the user GPU virtual addresses
 * @host_limit: MEM HOST_LIMIT, or 0 when the GPU reaches all of PA_BITS
 * @local_base: MEM LOCAL_BASE, 0 when there is no local memory
 * @local_size: MEM LOCAL_SIZE
 */
struct drm_ghci_dev_info {
	__u32 ghci_version;
	__u32 boot_caps;
	__u32 device_caps;
	__u32 ext_cap_feature;
	__u32 address_mode;
	__u32 protection;
	__u16 pci_vendor;
	__u16 pci_device;
	__u32 flags;
	__u32 caps_bytes;
	__u32 gclk_hz;
	__u32 max_chunks;
	__u32 max_chunk_dwords;
	__u64 va_start;
	__u64 va_end;
	__u64 host_limit;
	__u64 local_base;
	__u64 local_size;
};

/**
 * struct drm_ghci_dev_query - DRM_IOCTL_GHCI_DEV_QUERY
 * @type: enum drm_ghci_dev_query_type
 * @size: in: the size of the buffer at @pointer, or 0 to ask for the size;
 *        out: the size of the answer
 * @pointer: a user pointer to the buffer, ignored when @size is 0
 *
 * A buffer smaller than the answer receives its first @size bytes.
 */
struct drm_ghci_dev_query {
	__u32 type;
	__u32 size;
	__u64 pointer;
};

/* DRM_IOCTL_GHCI_BO_CREATE ------------------------------------------- */

/* User space never maps the object with mmap(). */
#define DRM_GHCI_BO_NO_MMAP	(1u << 0)

/* The object may be scanned out by the display controller. */
#define DRM_GHCI_BO_SCANOUT	(1u << 1)

/* Reserved for objects in the GPU's local memory (not yet supported). */
#define DRM_GHCI_BO_LOCAL	(1u << 2)
#define DRM_GHCI_BO_FLAGS	(DRM_GHCI_BO_NO_MMAP | DRM_GHCI_BO_SCANOUT)

/**
 * struct drm_ghci_bo_create - DRM_IOCTL_GHCI_BO_CREATE
 * @size: the size in bytes; the kernel rounds it up to the page size
 * @flags: DRM_GHCI_BO_*
 * @handle: out: the GEM handle
 * @gpu_addr: out: flat: the GPU address of byte 0; MMU: 0
 */
struct drm_ghci_bo_create {
	__u64 size;
	__u32 flags;
	__u32 handle;
	__u64 gpu_addr;
};

/**
 * struct drm_ghci_bo_mmap_offset - DRM_IOCTL_GHCI_BO_MMAP_OFFSET
 * @handle: the GEM handle
 * @pad: zero
 * @offset: out: the offset to pass to mmap() on the DRM file
 */
struct drm_ghci_bo_mmap_offset {
	__u32 handle;
	__u32 pad;
	__u64 offset;
};

/**
 * struct drm_ghci_bo_info - DRM_IOCTL_GHCI_BO_INFO
 * @handle: the GEM handle, also one imported with PRIME
 * @flags: out: DRM_GHCI_BO_* the object was created with
 * @size: out: the size in bytes
 * @gpu_addr: out: flat: the GPU address; MMU: 0
 */
struct drm_ghci_bo_info {
	__u32 handle;
	__u32 flags;
	__u64 size;
	__u64 gpu_addr;
};

/**
 * struct drm_ghci_bo_wait - DRM_IOCTL_GHCI_BO_WAIT
 * @handle: the GEM handle
 * @flags: DRM_GHCI_BO_WAIT_WRITE waits only for writers; zero waits for all
 * @timeout_ns: an absolute CLOCK_MONOTONIC time; the ioctl fails with
 *              ETIMEDOUT when it passes
 */
#define DRM_GHCI_BO_WAIT_WRITE	(1u << 0)

struct drm_ghci_bo_wait {
	__u32 handle;
	__u32 flags;
	__s64 timeout_ns;
};

/* DRM_IOCTL_GHCI_VM_CREATE, _DESTROY, _GET_STATE ------------------------ */

/**
 * struct drm_ghci_vm_create - DRM_IOCTL_GHCI_VM_CREATE
 * @flags: zero
 * @vm_id: out: the VM; flat devices give every VM the one bus address
 *         space, MMU devices give each VM its own session
 */
struct drm_ghci_vm_create {
	__u32 flags;
	__u32 vm_id;
};

struct drm_ghci_vm_destroy {
	__u32 vm_id;
	__u32 pad;
};

enum drm_ghci_vm_state {
	DRM_GHCI_VM_USABLE = 0,

	/* A job of this VM faulted or hung; the VM takes no more jobs. */
	DRM_GHCI_VM_GUILTY = 1,

	/* A reset caused by another VM lost jobs of this VM. */
	DRM_GHCI_VM_INNOCENT = 2,
};

struct drm_ghci_vm_get_state {
	__u32 vm_id;
	__u32 state;
};

/* DRM_IOCTL_GHCI_VM_BIND (MMU devices only) ---------------------------- */

#define DRM_GHCI_VM_BIND_OP_MAP		0
#define DRM_GHCI_VM_BIND_OP_UNMAP	1

#define DRM_GHCI_VM_BIND_READ		(1u << 0)
#define DRM_GHCI_VM_BIND_WRITE		(1u << 1)
#define DRM_GHCI_VM_BIND_EXEC		(1u << 2)

/**
 * struct drm_ghci_vm_bind_op - one mapping change
 * @op: DRM_GHCI_VM_BIND_OP_*
 * @flags: MAP: DRM_GHCI_VM_BIND_READ, _WRITE, _EXEC; UNMAP: zero
 * @handle: MAP: the GEM handle; UNMAP: zero
 * @pad: zero
 * @bo_offset: MAP: the first byte of the object to map (page aligned)
 * @va: the first GPU virtual address (page aligned)
 * @size: the size in bytes (page aligned)
 */
struct drm_ghci_vm_bind_op {
	__u32 op;
	__u32 flags;
	__u32 handle;
	__u32 pad;
	__u64 bo_offset;
	__u64 va;
	__u64 size;
};

/* Do not wait for the binds: signal @out_syncs when they are done. */
#define DRM_GHCI_VM_BIND_ASYNC	(1u << 0)

/**
 * struct drm_ghci_sync - a syncobj to wait on or to signal
 * @handle: the syncobj handle
 * @flags: zero
 * @point: the timeline point, 0 for a binary syncobj
 */
struct drm_ghci_sync {
	__u32 handle;
	__u32 flags;
	__u64 point;
};

/**
 * struct drm_ghci_vm_bind - DRM_IOCTL_GHCI_VM_BIND
 * @vm_id: the VM
 * @flags: DRM_GHCI_VM_BIND_ASYNC
 * @ops: struct drm_ghci_vm_bind_op
 * @in_syncs: struct drm_ghci_sync to wait on first
 * @out_syncs: struct drm_ghci_sync to signal when done
 */
struct drm_ghci_vm_bind {
	__u32 vm_id;
	__u32 flags;
	struct drm_ghci_obj_array ops;
	struct drm_ghci_obj_array in_syncs;
	struct drm_ghci_obj_array out_syncs;
};

/* DRM_IOCTL_GHCI_SUBMIT ------------------------------------------------ */

/**
 * struct drm_ghci_submit_chunk - a run of GHCI command packets
 * @addr: flat: a user pointer that the kernel copies; MMU: the GPU virtual
 *        address of the packets in the VM
 * @dwords: the size in dwords; a chunk holds whole packets
 * @flags: zero
 */
struct drm_ghci_submit_chunk {
	__u64 addr;
	__u32 dwords;
	__u32 flags;
};

/* drm_ghci_submit_bo.flags */
#define DRM_GHCI_SUBMIT_BO_READ		(1u << 0)
#define DRM_GHCI_SUBMIT_BO_WRITE	(1u << 1)

/**
 * struct drm_ghci_submit_bo - a buffer object the job uses
 * @handle: the GEM handle
 * @flags: DRM_GHCI_SUBMIT_BO_READ and/or _WRITE, for implicit
 *         synchronization with other users of a shared object
 */
struct drm_ghci_submit_bo {
	__u32 handle;
	__u32 flags;
};

/**
 * struct drm_ghci_submit - DRM_IOCTL_GHCI_SUBMIT
 * @vm_id: the VM the job runs in
 * @flags: zero
 * @chunks: struct drm_ghci_submit_chunk, run in order
 * @bos: struct drm_ghci_submit_bo; in the flat model every object the
 *       chunks reach must be listed, so that it stays mapped while the job
 *       runs
 * @in_syncs: struct drm_ghci_sync to wait on before the job runs
 * @out_syncs: struct drm_ghci_sync to signal when the job is done
 */
struct drm_ghci_submit {
	__u32 vm_id;
	__u32 flags;
	struct drm_ghci_obj_array chunks;
	struct drm_ghci_obj_array bos;
	struct drm_ghci_obj_array in_syncs;
	struct drm_ghci_obj_array out_syncs;
};

#define DRM_IOCTL_GHCI(dir, name, type) \
	DRM_IO##dir(DRM_COMMAND_BASE + DRM_GHCI_##name, struct drm_ghci_##type)

#define DRM_IOCTL_GHCI_DEV_QUERY	DRM_IOCTL_GHCI(WR, DEV_QUERY, dev_query)
#define DRM_IOCTL_GHCI_BO_CREATE	DRM_IOCTL_GHCI(WR, BO_CREATE, bo_create)
#define DRM_IOCTL_GHCI_BO_MMAP_OFFSET	DRM_IOCTL_GHCI(WR, BO_MMAP_OFFSET, bo_mmap_offset)
#define DRM_IOCTL_GHCI_BO_INFO		DRM_IOCTL_GHCI(WR, BO_INFO, bo_info)
#define DRM_IOCTL_GHCI_VM_CREATE	DRM_IOCTL_GHCI(WR, VM_CREATE, vm_create)
#define DRM_IOCTL_GHCI_VM_DESTROY	DRM_IOCTL_GHCI(W, VM_DESTROY, vm_destroy)
#define DRM_IOCTL_GHCI_VM_BIND		DRM_IOCTL_GHCI(WR, VM_BIND, vm_bind)
#define DRM_IOCTL_GHCI_SUBMIT		DRM_IOCTL_GHCI(WR, SUBMIT, submit)
#define DRM_IOCTL_GHCI_VM_GET_STATE	DRM_IOCTL_GHCI(WR, VM_GET_STATE, vm_get_state)
#define DRM_IOCTL_GHCI_BO_WAIT		DRM_IOCTL_GHCI(W, BO_WAIT, bo_wait)

#if defined(__cplusplus)
}
#endif

#endif /* GHCI_DRM_H */
