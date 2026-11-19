// SPDX-License-Identifier: Zlib
/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 */

/*
 * ghci_drv.c: the PCI driver and the DRM device (ghci.md 15.2).  BAR0 is
 * the 128 KiB register window; the driver identifies GHCI by GHCI_MAGIC
 * and GHCI_VERSION, not by the PCI IDs, but binds only to the IDs in its
 * table (a GHCI function of other IDs can be bound through the PCI
 * driver's new_id file), so that it never touches another vendor's 3D
 * controller.
 */

#include <linux/module.h>
#include <linux/pci.h>
#include <linux/version.h>

#include <drm/drm_drv.h>
#include <drm/drm_gem.h>
#include <drm/drm_gem_shmem_helper.h>
#include <drm/drm_ioctl.h>
#include <drm/drm_prime.h>
#include <drm/drm_print.h>

#include "ghci_drv.h"

static bool ghci_poll;
module_param_named(poll, ghci_poll, bool, 0444);
MODULE_PARM_DESC(poll, "Poll the GPU even when it has an interrupt");

static unsigned int ghci_ring_kib = GHCI_RING_BYTES >> 10;
module_param_named(ring_kib, ghci_ring_kib, uint, 0444);
MODULE_PARM_DESC(ring_kib, "Command ring size in KiB (a power of two, 4..16384)");

static void ghci_debugfs_init(struct drm_minor *minor)
{
	struct ghci_device *gdev = to_ghci(minor->dev);

	/* The capability block, for tools and for Mesa's drm-shim
	 * (GHCI_SHIM_CAPS). */
	debugfs_create_blob("ghci_caps", 0444, minor->debugfs_root,
			    &gdev->caps_blob);
}

DEFINE_DRM_GEM_FOPS(ghci_fops);

static const struct drm_driver ghci_drm_driver = {
	.driver_features = DRIVER_GEM | DRIVER_RENDER | DRIVER_SYNCOBJ |
			   DRIVER_SYNCOBJ_TIMELINE,
	.open = ghci_file_open,
	.postclose = ghci_file_close,
	.ioctls = ghci_ioctls,
	.num_ioctls = ARRAY_SIZE(ghci_ioctls),
	.fops = &ghci_fops,
	.gem_create_object = ghci_gem_create_object,
	DRM_GEM_SHMEM_DRIVER_OPS,
	.debugfs_init = ghci_debugfs_init,
	.name = DRM_GHCI_DRIVER_NAME,
	.desc = GHCI_DRIVER_DESC,
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 14, 0)
	.date = GHCI_DRIVER_DATE,
#endif
	.major = GHCI_DRIVER_MAJOR,
	.minor = GHCI_DRIVER_MINOR,
};

/*
 * MSI or MSI-X, or INTx (ghci.md 15.2); a function that has none of them
 * (the KC705's PCIe IP) is polled.
 */
static void ghci_setup_irq(struct ghci_device *gdev)
{
	struct pci_dev *pdev = gdev->pdev;
	int ret;

	gdev->polled = true;
	if (ghci_poll)
		return;

	ret = pci_alloc_irq_vectors(pdev, 1, 1,
				    PCI_IRQ_MSI | PCI_IRQ_MSIX | PCI_IRQ_INTX);
	if (ret < 0) {
		drm_info(&gdev->drm, "no interrupt (%d); polling\n", ret);
		return;
	}
	gdev->irq = pci_irq_vector(pdev, 0);
	ret = devm_request_irq(&pdev->dev, gdev->irq, ghci_irq_handler,
			       IRQF_SHARED, DRM_GHCI_DRIVER_NAME, gdev);
	if (ret) {
		drm_warn(&gdev->drm, "interrupt %d not taken (%d); polling\n",
			 gdev->irq, ret);
		return;
	}
	gdev->polled = false;
}

static int ghci_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct ghci_device *gdev;
	int ret;

	ret = pcim_enable_device(pdev);
	if (ret)
		return ret;
	if (!(pci_resource_flags(pdev, 0) & IORESOURCE_MEM) ||
	    pci_resource_len(pdev, 0) < GHCI_WINDOW_BYTES)
		return -ENODEV;

	gdev = devm_drm_dev_alloc(&pdev->dev, &ghci_drm_driver,
				  struct ghci_device, drm);
	if (IS_ERR(gdev))
		return PTR_ERR(gdev);
	gdev->pdev = pdev;
	pci_set_drvdata(pdev, gdev);

	ret = pcim_iomap_regions(pdev, BIT(0), DRM_GHCI_DRIVER_NAME);
	if (ret)
		return ret;
	gdev->mmio = pcim_iomap_table(pdev)[0];

	gdev->ring_bytes = ghci_ring_kib << 10;
	if (gdev->ring_bytes < GHCI_RING_BYTES_MIN ||
	    gdev->ring_bytes > GHCI_RING_BYTES_MAX ||
	    !is_power_of_2(gdev->ring_bytes)) {
		drm_err(&gdev->drm, "ring_kib=%u is not a power of two in 4..16384\n",
			ghci_ring_kib);
		return -EINVAL;
	}

	ghci_setup_irq(gdev);

	ret = ghci_hw_init(gdev);
	if (ret)
		return ret;

	ret = drm_dev_register(&gdev->drm, 0);
	if (ret) {
		ghci_hw_fini(gdev);
		return ret;
	}
	return 0;
}

static void ghci_remove(struct pci_dev *pdev)
{
	struct ghci_device *gdev = pci_get_drvdata(pdev);

	drm_dev_unplug(&gdev->drm);
	ghci_hw_fini(gdev);
}

static void ghci_shutdown(struct pci_dev *pdev)
{
	struct ghci_device *gdev = pci_get_drvdata(pdev);

	if (gdev)
		ghci_hw_fini(gdev);
}

/* The KC705 board (boards/kc705/ip.tcl). */
static const struct pci_device_id ghci_pci_ids[] = {
	{ PCI_DEVICE(0x10ee, 0x7024) },
	{ }
};
MODULE_DEVICE_TABLE(pci, ghci_pci_ids);

static struct pci_driver ghci_pci_driver = {
	.name = DRM_GHCI_DRIVER_NAME,
	.id_table = ghci_pci_ids,
	.probe = ghci_probe,
	.remove = ghci_remove,
	.shutdown = ghci_shutdown,
};

module_pci_driver(ghci_pci_driver);

MODULE_AUTHOR("Awe Morris");
MODULE_DESCRIPTION("DRM driver for GHCI 1.0 GPUs");
/*
 * The source is under the Zlib license (see each file's SPDX line), which
 * is compatible with the GPL: the module as a whole is distributed under
 * the GPL v2 with that additional permission.
 */
MODULE_LICENSE("GPL and additional rights");
