/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The CP firmware's main loop: it polls the window for a class V packet
 * and for a halt request, decodes packets one at a time, and parks the
 * core between packets when the host halts the CP.  The heartbeat (a
 * FW_STATUS write, CPFW_STATUS.ALIVE) beats every HEARTBEAT_POLLS polls.
 *
 * The firmware polls instead of waiting with WFI: the window masks the
 * interrupt causes in IRQ_EN, and an interrupt taken between enabling
 * them and the WFI would return to a WFI that nothing wakes.
 */

#include "fw.h"
#include "hw.h"

/* Polls between two heartbeats. */
#define HEARTBEAT_POLLS 1024u

/*
 * A .data word that the host sees in MBOX3 at every start: boot.S copies
 * .data from the image each time, so the changed value never survives a
 * RESET (design §2.4.7, the restart rule).  It is volatile so that the
 * compiler keeps it a real .data word.
 */
static volatile uint32_t main_data_check = FW_DATA_CHECK;

int main(void);

static void main_state(uint32_t state);

/*
 * Starts the firmware and runs its loop.
 */
int
main(void)
{
	uint32_t info;
	uint32_t irq;
	uint32_t polls;

	/* No heap, no object, no half-written µop packet. */
	main_state(FW_STATE_BOOT);
	fw_heap_init();
	fw_object_init();
	fw_prot_init();
	fw_uop_reset();

	/* Tells the host which firmware runs and that .data is fresh. */
	hw_write(HW_FW_VERSION, FW_VERSION);
	hw_write(HW_MBOX0 + 3u, main_data_check);
	main_data_check = ~FW_DATA_CHECK;
	main_state(FW_STATE_IDLE);

	/* Packets, halts and the heartbeat, for ever. */
	polls = 0;
	for (;;) {
		/* A waiting packet: the read takes it. */
		info = hw_read(HW_PKT_INFO);
		if ((info & HW_PKT_INFO_WAITING) != 0) {
			main_state(FW_STATE_PACKET);
			fw_packet_run(info);
			main_state(FW_STATE_IDLE);
		}

		/*
		 * A halt request between packets: PARK stops the core at the
		 * next instruction, and it runs on here when the halt ends.
		 */
		irq = hw_read(HW_IRQ);
		if ((irq & HW_IRQ_HALT) != 0) {
			hw_write(HW_FW_STATUS, FW_STATE_PARKED << 8 | HW_FW_PARK);
			main_state(FW_STATE_IDLE);
		}

		/* The heartbeat. */
		polls++;
		if (polls == HEARTBEAT_POLLS) {
			polls = 0;
			main_state(FW_STATE_IDLE);
		}
	}

	/* Not reached: the loop never ends. */
	return 0;
}

/* Shows the firmware's state in CPFW_STATUS (and beats the heartbeat). */
static void
main_state(
	uint32_t state)
{
	/* [15:8] the state; PARK stays 0. */
	hw_write(HW_FW_STATUS, state << 8);
}
