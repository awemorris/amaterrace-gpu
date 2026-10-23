/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci_packets.h: the GHCI command ring's packets.  Placeholder: the
 * command set is being redesigned on zedBSD's GPU command protocol
 * (design v3, pending; docs/ghci.md section 4).  Only what does not depend
 * on it is here.
 */

#ifndef GHCI_PACKETS_H
#define GHCI_PACKETS_H

/* Fence values are 32 bits and compare with wrap-around. */
#define GHCI_FENCE_PASSED(mem, value) ((int)((unsigned)(mem) - (unsigned)(value)) >= 0)

#endif /* GHCI_PACKETS_H */
