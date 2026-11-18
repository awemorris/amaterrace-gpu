/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci2_regs.h: Backward compatibility wrapper forwarding to ghci_regs.h.
 * New code should include "ghci_regs.h" directly.
 */

#ifndef GHCI2_REGS_H
#define GHCI2_REGS_H

#include "ghci_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Backward compatibility aliases */
#define GHCI2_MAGIC_VALUE            GHCI_MAGIC_VALUE
#define GHCI2_VERSION_MAJOR          GHCI_VERSION_MAJOR
#define GHCI2_VERSION_MINOR          GHCI_VERSION_MINOR
#define GHCI2_VERSION_VALUE          GHCI_VERSION_VALUE
#define GHCI2_FOURCC(a, b, c, d)     GHCI_FOURCC(a, b, c, d)

#define GHCI2_CTRL_RUN               GHCI_CTRL_RUN
#define GHCI2_CTRL_HALT              GHCI_CTRL_HALT
#define GHCI2_CTRL_RESET             GHCI_CTRL_RESET
#define GHCI2_CTRL_IRQ_GLOBAL        GHCI_CTRL_IRQ_GLOBAL
#define GHCI2_CTRL_TLB_FLUSH         GHCI_CTRL_TLB_FLUSH

#define GHCI2_STATUS_READY           GHCI_STATUS_READY
#define GHCI2_STATUS_BUSY            GHCI_STATUS_BUSY
#define GHCI2_STATUS_HALTED          GHCI_STATUS_HALTED
#define GHCI2_STATUS_FAULT           GHCI_STATUS_FAULT
#define GHCI2_STATUS_RESETTING       GHCI_STATUS_RESETTING

#define GHCI2_IRQ_FENCE              GHCI_IRQ_FENCE
#define GHCI2_IRQ_FAULT              GHCI_IRQ_FAULT
#define GHCI2_IRQ_WATCHDOG           GHCI_IRQ_WATCHDOG
#define GHCI2_IRQ_DISPLAY            GHCI_IRQ_DISPLAY

#define GHCI2_FAULT_KIND(info)       GHCI_FAULT_KIND(info)
#define GHCI2_FAULT_UNIT(info)       GHCI_FAULT_UNIT(info)
#define GHCI2_FAULT_SYNDROME(info)   GHCI_FAULT_SYNDROME(info)

#define GHCI2_FAULT_KIND_NONE        GHCI_FAULT_KIND_NONE
#define GHCI2_FAULT_KIND_INVALID_OP  GHCI_FAULT_KIND_INVALID_OP
#define GHCI2_FAULT_KIND_RING_OOB    GHCI_FAULT_KIND_RING_OOB
#define GHCI2_FAULT_KIND_PAGE_READ   GHCI_FAULT_KIND_PAGE_READ
#define GHCI2_FAULT_KIND_PAGE_WRITE  GHCI_FAULT_KIND_PAGE_WRITE
#define GHCI2_FAULT_KIND_TLB_ERROR   GHCI_FAULT_KIND_TLB_ERROR
#define GHCI2_FAULT_KIND_ISA_FAULT   GHCI_FAULT_KIND_ISA_FAULT
#define GHCI2_FAULT_KIND_PROT_FAULT  GHCI_FAULT_KIND_PROT_FAULT

#define GHCI2_UNIT_CP                GHCI_UNIT_CP
#define GHCI2_UNIT_VF                GHCI_UNIT_VF
#define GHCI2_UNIT_SU                GHCI_UNIT_SU
#define GHCI2_UNIT_RX                GHCI_UNIT_RX
#define GHCI2_UNIT_TU                GHCI_UNIT_TU
#define GHCI2_UNIT_ROP               GHCI_UNIT_ROP
#define GHCI2_UNIT_BLT               GHCI_UNIT_BLT

#ifdef __cplusplus
}
#endif

#endif /* GHCI2_REGS_H */
