/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The few fp32 operations the firmware needs on Vulkan's float arguments
 * (the core has no FPU and the shared LLVM has no soft-float library):
 * conversion to fixed point and from integers, and addition, all rounded
 * to nearest even.  Values are their IEEE bits in a uint32_t.  Denormal
 * inputs are read as zeros of their sign and denormal results flushed, as
 * the GPU's units do (docs/ghci.md section 12.7); a NaN result is
 * 0x7FC00000.
 */

#include "fw.h"

/* The parts of an fp32. */
#define FLT_SIGN 0x80000000u
#define FLT_EXP_MASK 0x7F800000u
#define FLT_MANT_MASK 0x007FFFFFu
#define FLT_NAN 0x7FC00000u
#define FLT_INF 0x7F800000u

static uint32_t flt_pack(uint32_t sign, int32_t exponent, uint64_t mantissa, uint32_t extra_bits);

/*
 * Converts an fp32 to a signed fixed-point number with `fraction` bits,
 * rounded to nearest even and saturated to [minimum, maximum]; NaN gives
 * 0.
 */
int32_t
fw_f32_fixed(
	uint32_t bits,
	uint32_t fraction,
	int32_t minimum,
	int32_t maximum)
{
	uint32_t exponent;
	uint64_t mantissa;
	uint64_t value;
	uint64_t rest;
	uint64_t half;
	int32_t shift;
	int64_t result;

	/* NaN, and zero with the denormals. */
	exponent = (bits >> 23) & 0xFFu;
	if (exponent == 0xFFu && (bits & FLT_MANT_MASK) != 0)
		return 0;
	if (exponent == 0)
		return 0;

	/* The magnitude is m x 2^(exponent - 150 + fraction). */
	mantissa = (bits & FLT_MANT_MASK) | (1u << 23);
	shift = 150 - (int32_t)exponent - (int32_t)fraction;

	/* Too large for any 32-bit fixed point: saturates. */
	if (shift < -8) {
		if ((bits & FLT_SIGN) != 0)
			return minimum;
		return maximum;
	}

	/* Shifted, rounding the bits shifted out to nearest even. */
	if (shift <= 0) {
		value = mantissa << (uint32_t)(-shift);
	} else if (shift >= 26) {
		value = 0;
	} else {
		value = mantissa >> (uint32_t)shift;
		rest = mantissa & (((uint64_t)1 << (uint32_t)shift) - 1u);
		half = (uint64_t)1 << (uint32_t)(shift - 1);
		if (rest > half || (rest == half && (value & 1u) != 0))
			value++;
	}

	/* The sign, then the saturation. */
	result = (int64_t)value;
	if ((bits & FLT_SIGN) != 0)
		result = -result;
	if (result < minimum)
		return minimum;
	if (result > maximum)
		return maximum;

	/* Succeeded: the fixed-point value. */
	return (int32_t)result;
}

/*
 * Converts a signed integer to the nearest fp32 (ties to even).
 */
uint32_t
fw_f32_from_int(
	int32_t value)
{
	uint32_t sign;
	uint32_t magnitude;

	/* Zero is +0. */
	if (value == 0)
		return 0;

	/* The sign and the magnitude (INT_MIN's magnitude fits a uint32_t). */
	sign = 0;
	magnitude = (uint32_t)value;
	if (value < 0) {
		sign = FLT_SIGN;
		magnitude = 0u - (uint32_t)value;
	}

	/* Succeeded: magnitude x 2^0, normalized and rounded. */
	return flt_pack(sign, 127 + 23, magnitude, 0);
}

/*
 * Adds two fp32 values, rounded to nearest even.
 */
uint32_t
fw_f32_add(
	uint32_t a,
	uint32_t b)
{
	uint32_t a_exp;
	uint32_t b_exp;
	uint32_t swap;
	uint64_t a_mant;
	uint64_t b_mant;
	uint64_t sum;
	uint32_t shift;
	uint32_t sticky;

	/* NaN in, NaN out; infinities add as IEEE says (inf - inf is NaN). */
	a_exp = (a >> 23) & 0xFFu;
	b_exp = (b >> 23) & 0xFFu;
	if ((a_exp == 0xFFu && (a & FLT_MANT_MASK) != 0) || (b_exp == 0xFFu && (b & FLT_MANT_MASK) != 0))
		return FLT_NAN;
	if (a_exp == 0xFFu && b_exp == 0xFFu && ((a ^ b) & FLT_SIGN) != 0)
		return FLT_NAN;
	if (a_exp == 0xFFu)
		return a;
	if (b_exp == 0xFFu)
		return b;

	/* A zero (or a flushed denormal) adds nothing; +0 + -0 is +0. */
	if (b_exp == 0) {
		if (a_exp == 0)
			return (a & b) & FLT_SIGN;
		return a;
	}
	if (a_exp == 0)
		return b;

	/* The larger magnitude first. */
	if ((b & 0x7FFFFFFFu) > (a & 0x7FFFFFFFu)) {
		swap = a;
		a = b;
		b = swap;
		swap = a_exp;
		a_exp = b_exp;
		b_exp = swap;
	}

	/* Mantissas with the hidden bit and 3 guard bits; b aligned with a sticky bit. */
	a_mant = (uint64_t)((a & FLT_MANT_MASK) | (1u << 23)) << 3;
	b_mant = (uint64_t)((b & FLT_MANT_MASK) | (1u << 23)) << 3;
	shift = a_exp - b_exp;
	if (shift > 27) {
		b_mant = 1;
	} else if (shift > 0) {
		sticky = 0;
		if ((b_mant & (((uint64_t)1 << shift) - 1u)) != 0)
			sticky = 1;
		b_mant = (b_mant >> shift) | sticky;
	}

	/* The sum or the difference of the magnitudes, with a's sign. */
	if (((a ^ b) & FLT_SIGN) == 0) {
		sum = a_mant + b_mant;
	} else {
		sum = a_mant - b_mant;
		if (sum == 0)
			return 0;
	}

	/* Succeeded: normalized and rounded (3 extra bits below the mantissa). */
	return flt_pack(a & FLT_SIGN, (int32_t)a_exp, sum, 3);
}

/* Normalizes mantissa x 2^(exponent - 150 - extra_bits) and rounds it to nearest even. */
static uint32_t
flt_pack(
	uint32_t sign,
	int32_t exponent,
	uint64_t mantissa,
	uint32_t extra_bits)
{
	uint64_t rest;
	uint64_t half;
	uint32_t shift;
	uint32_t top;

	/* The position of the top bit: it becomes bit 23 after the shift. */
	top = 63;
	while (((mantissa >> top) & 1u) == 0)
		top--;

	/* Shifts left or right to 24 bits; the exponent follows the shift and the extra bits. */
	shift = 0;
	if (top < 23u) {
		mantissa <<= (23u - top);
		exponent -= (int32_t)(23u - top);
	} else {
		shift = top - 23u;
	}
	exponent += (int32_t)shift - (int32_t)extra_bits;

	/* The bits shifted out round to nearest even; a carry renormalizes. */
	if (shift > 0) {
		rest = mantissa & (((uint64_t)1 << shift) - 1u);
		half = (uint64_t)1 << (shift - 1u);
		mantissa >>= shift;
		if (rest > half || (rest == half && (mantissa & 1u) != 0))
			mantissa++;
		if (mantissa == (1u << 24)) {
			mantissa >>= 1;
			exponent++;
		}
	}

	/* Overflow to infinity; a denormal result flushes to zero. */
	if (exponent >= 255)
		return sign | FLT_INF;
	if (exponent <= 0)
		return sign;

	/* Succeeded: the fp32's bits. */
	return sign | (uint32_t)exponent << 23 | ((uint32_t)mantissa & FLT_MANT_MASK);
}
