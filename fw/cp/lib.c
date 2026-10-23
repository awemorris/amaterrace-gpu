/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The run-time helpers the compiler may call: the shared LLVM has no
 * compiler-rt builtins for riscv32, so the firmware carries memcpy,
 * memset, memcmp and the 64-bit division of rv32im (the core divides 32
 * bits in hardware).
 */

#include "fw.h"

uint64_t __udivdi3(uint64_t dividend, uint64_t divisor);
uint64_t __umoddi3(uint64_t dividend, uint64_t divisor);

static uint64_t udivmod64(uint64_t dividend, uint64_t divisor, uint64_t *remainder);

/*
 * Copies bytes between objects that do not overlap.
 */
void *
memcpy(
	void *dst,
	const void *src,
	size_t bytes)
{
	uint8_t *to;
	const uint8_t *from;

	/* Copies whole words while both ends are word aligned. */
	to = dst;
	from = src;
	if ((((uintptr_t)to | (uintptr_t)from) & 3u) == 0) {
		while (bytes >= 4) {
			*(uint32_t *)(void *)to = *(const uint32_t *)(const void *)from;
			to += 4;
			from += 4;
			bytes -= 4;
		}
	}

	/* Copies the bytes that are left. */
	while (bytes > 0) {
		*to++ = *from++;
		bytes--;
	}

	/* Succeeded: the destination, as C asks. */
	return dst;
}

/*
 * Fills bytes with one value.
 */
void *
memset(
	void *dst,
	int value,
	size_t bytes)
{
	uint8_t *to;
	uint32_t word;

	/* Whole words while the destination is word aligned. */
	to = dst;
	word = (uint8_t)value * 0x01010101u;
	if (((uintptr_t)to & 3u) == 0) {
		while (bytes >= 4) {
			*(uint32_t *)(void *)to = word;
			to += 4;
			bytes -= 4;
		}
	}

	/* Stores the byte value into each byte that is left. */
	while (bytes > 0) {
		*to++ = (uint8_t)value;
		bytes--;
	}

	/* Succeeded: the destination, as C asks. */
	return dst;
}

/*
 * Compares two byte ranges.
 */
int
memcmp(
	const void *a,
	const void *b,
	size_t bytes)
{
	const uint8_t *left;
	const uint8_t *right;

	/* Finds the first byte that differs. */
	left = a;
	right = b;
	while (bytes > 0) {
		if (*left != *right)
			return *left < *right ? -1 : 1;
		left++;
		right++;
		bytes--;
	}

	/* Succeeded: the ranges are equal. */
	return 0;
}

/*
 * Divides two unsigned 64-bit numbers.
 */
uint64_t
__udivdi3(
	uint64_t dividend,
	uint64_t divisor)
{
	uint64_t remainder;
	uint64_t quotient;

	/* Runs the shift-and-subtract division. */
	quotient = udivmod64(dividend, divisor, &remainder);

	/* Succeeded: the quotient. */
	return quotient;
}

/*
 * Reports the remainder of two unsigned 64-bit numbers.
 */
uint64_t
__umoddi3(
	uint64_t dividend,
	uint64_t divisor)
{
	uint64_t remainder;

	/* Runs the shift-and-subtract division for its remainder. */
	(void)udivmod64(dividend, divisor, &remainder);

	/* Succeeded: the remainder. */
	return remainder;
}

/* Divides by shift and subtract; a zero divisor gives RISC-V's all-ones quotient. */
static uint64_t
udivmod64(
	uint64_t dividend,
	uint64_t divisor,
	uint64_t *remainder)
{
	uint64_t quotient;
	uint64_t rest;
	int bit;

	/* A zero divisor answers as the hardware's 32-bit divide does. */
	if (divisor == 0) {
		*remainder = dividend;
		return ~(uint64_t)0;
	}

	/* Brings down one dividend bit per step, from the top. */
	quotient = 0;
	rest = 0;
	for (bit = 63; bit >= 0; bit--) {
		rest = rest << 1 | ((dividend >> bit) & 1u);
		if (rest >= divisor) {
			rest -= divisor;
			quotient |= (uint64_t)1 << bit;
		}
	}

	/* Succeeded: the quotient, the remainder through the pointer. */
	*remainder = rest;
	return quotient;
}
