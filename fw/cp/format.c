/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The formats: the table of the formats the GPU has (formats.inc,
 * generated from tools/fmtmodel.py) and the packing of a clear value
 * into a format's bits, with Vulkan's conversions (docs/ghci.md section
 * 8.5) done exactly in integers (the core has no FPU): UNORM and SNORM
 * rounded to nearest even, 16-bit and the packed unsigned floats rounded
 * to nearest even, sRGB to the nearest 8-bit code.
 */

#include "fw.h"

#include "formats.inc"

/* The fp32 bits of 1.0, the exponent mask and a quiet NaN. */
#define FMT_ONE 0x3F800000u
#define FMT_EXP_MASK 0x7F800000u
#define FMT_MANT_MASK 0x007FFFFFu

static uint32_t fmt_unorm(uint32_t bits, uint32_t width);
static uint32_t fmt_snorm(uint32_t bits, uint32_t width);
static uint32_t fmt_srgb(uint32_t bits);
static uint32_t fmt_small_float(uint32_t bits, uint32_t mantissa_bits, int sign);
static uint32_t fmt_e5b9g9r9(const uint32_t *color);
static uint32_t fmt_scale(uint32_t bits, uint64_t factor);
static uint32_t fmt_round_pow2(uint32_t bits, int32_t power);
static int fmt_is_nan(uint32_t bits);
static void fmt_put(uint32_t *raw, uint32_t position, uint32_t width, uint32_t value);

/*
 * Finds a format the GPU has.
 *
 * Returns NULL for a format it does not have (and for 0, no format).
 */
const struct fw_format *
fw_format_find(
	uint32_t format)
{
	uint32_t low;
	uint32_t high;
	uint32_t middle;

	/* A binary search of the table, which is in VkFormat order. */
	low = 0;
	high = sizeof(fw_formats) / sizeof(fw_formats[0]);
	while (low < high) {
		middle = (low + high) / 2u;
		if (fw_formats[middle].format == format)
			return &fw_formats[middle];
		if (fw_formats[middle].format < format) {
			low = middle + 1u;
		} else {
			high = middle;
		}
	}

	/* The GPU does not have the format. */
	return NULL;
}

/*
 * Packs a colour clear value (VkClearColorValue's four words: floats for
 * the normalized and float formats, integers for the integer formats)
 * into a texel's bits, raw[0] the lowest word.
 *
 * Returns 0, or -1 for a format without colour (or one the GPU lacks).
 */
int
fw_format_pack_color(
	uint32_t format,
	const uint32_t *color,
	uint32_t *raw)
{
	const struct fw_format *info;
	uint32_t component;
	uint32_t width;
	uint32_t value;

	/* The format's description; depth, stencil and blocks have no colour bits. */
	info = fw_format_find(format);
	if (info == NULL || (info->flags & (FW_FMT_DEPTH | FW_FMT_STENCIL | FW_FMT_BLOCK)) != 0)
		return -1;

	/* Starts from zero bits. */
	raw[0] = 0;
	raw[1] = 0;
	raw[2] = 0;
	raw[3] = 0;

	/* The shared exponent format packs its three components together. */
	if (info->type == FW_FMT_E5) {
		raw[0] = fmt_e5b9g9r9(color);
		return 0;
	}

	/* Each component the format has. */
	for (component = 0; component < info->components; component++) {
		width = info->comp[component].width;
		switch (info->type) {
		case FW_FMT_UNORM:
			value = fmt_unorm(color[component], width);
			break;
		case FW_FMT_SNORM:
			value = fmt_snorm(color[component], width);
			break;
		case FW_FMT_SRGB:
			value = fmt_unorm(color[component], 8);
			if (component < 3u)
				value = fmt_srgb(color[component]);
			break;
		case FW_FMT_SFLOAT:
			value = color[component];
			if (width == 16u)
				value = fmt_small_float(color[component], 10, 1);
			break;
		case FW_FMT_UFLOAT:
			value = fmt_small_float(color[component], width - 5u, 0);
			break;
		default:
			/* UINT and SINT keep the integer's low bits. */
			value = color[component];
			break;
		}
		fmt_put(raw, info->comp[component].position, width, value);
	}

	/* Succeeded: the texel's bits. */
	return 0;
}

/*
 * Packs a depth (fp32 bits) and a stencil value into a depth/stencil
 * texel's bits; `aspects` says which are written (VkImageAspectFlags:
 * [1] depth, [2] stencil), and `keep` gets the BLT_OP KEEP mask of the
 * bytes not written (D24_UNORM_S8_UINT only).
 *
 * Returns 0, or -1 for a format that is not depth/stencil.
 */
int
fw_format_pack_depth(
	uint32_t format,
	uint32_t depth,
	uint32_t stencil,
	uint32_t aspects,
	uint32_t *raw,
	uint32_t *keep)
{
	uint32_t value;

	/* Depth is clamped to [0, 1] for the UNORM formats (Vulkan's clear rule). */
	value = 0;
	*keep = 0;
	switch (format) {
	case FW_VK_FORMAT_D16_UNORM:
		value = fmt_unorm(depth, 16);
		break;
	case FW_VK_FORMAT_X8_D24_UNORM_PACK32:
		value = fmt_unorm(depth, 24);
		break;
	case FW_VK_FORMAT_D32_SFLOAT:
		value = depth;
		break;
	case FW_VK_FORMAT_D24_UNORM_S8_UINT:
		value = fmt_unorm(depth, 24) | (stencil & 0xFFu) << 24;
		if ((aspects & FW_ASPECT_DEPTH) == 0)
			*keep |= 0x7u;
		if ((aspects & FW_ASPECT_STENCIL) == 0)
			*keep |= 0x8u;
		break;
	default:
		return -1;
	}

	/* Succeeded: the texel's bits. */
	*raw = value;
	return 0;
}

/* RNE(clamp01(f) x (2^w - 1)); NaN and negative values (and -0) give 0. */
static uint32_t
fmt_unorm(
	uint32_t bits,
	uint32_t width)
{
	uint32_t maximum;

	/* The code of 1.0. */
	maximum = 0xFFFFFFFFu >> (32u - width);

	/* NaN and the negative values. */
	if (fmt_is_nan(bits) || (bits >> 31) != 0)
		return 0;

	/* 1.0 and above saturate. */
	if (bits >= FMT_ONE)
		return maximum;

	/* Succeeded: the scaled value. */
	return fmt_scale(bits, maximum);
}

/* RNE(clamp(f, -1, 1) x (2^(w-1) - 1)) in w bits; NaN gives 0. */
static uint32_t
fmt_snorm(
	uint32_t bits,
	uint32_t width)
{
	uint32_t maximum;
	uint32_t magnitude;
	uint32_t mask;

	/* The code of 1.0 and the field's bits. */
	maximum = 0xFFFFFFFFu >> (33u - width);
	mask = 0xFFFFFFFFu >> (32u - width);

	/* NaN. */
	if (fmt_is_nan(bits))
		return 0;

	/* The magnitude, saturated at 1.0. */
	if ((bits & 0x7FFFFFFFu) >= FMT_ONE) {
		magnitude = maximum;
	} else {
		magnitude = fmt_scale(bits & 0x7FFFFFFFu, maximum);
	}

	/* Negative values in two's complement. */
	if ((bits >> 31) != 0)
		return (0u - magnitude) & mask;

	/* Succeeded: the code. */
	return magnitude;
}

/* The nearest 8-bit sRGB code of a linear value: the thresholds at or below it. */
static uint32_t
fmt_srgb(
	uint32_t bits)
{
	uint32_t low;
	uint32_t high;
	uint32_t middle;

	/* NaN, the negative values and -0 give 0. */
	if (fmt_is_nan(bits) || (bits >> 31) != 0)
		return 0;

	/* The count of thresholds <= x; positive floats order as integers. */
	low = 0;
	high = 255;
	while (low < high) {
		middle = (low + high) / 2u;
		if (fw_srgb_thr[middle] <= bits) {
			low = middle + 1u;
		} else {
			high = middle;
		}
	}

	/* Succeeded: the code. */
	return low;
}

/*
 * A float of 5 exponent bits (bias 15) and `mantissa_bits`, rounded to
 * nearest even: binary16 (signed), or the 11- and 10-bit unsigned floats
 * of B10G11R11 (negative values give 0).  Denormals are kept; overflow
 * gives infinity; NaN gives a quiet NaN.
 */
static uint32_t
fmt_small_float(
	uint32_t bits,
	uint32_t mantissa_bits,
	int sign)
{
	uint32_t sign_bit;
	uint32_t exponent;
	uint32_t mantissa;
	uint32_t infinity;
	uint32_t shift;
	uint32_t result;
	uint32_t rest;
	uint32_t half;
	int32_t biased;

	/* The fields of the fp32 and of the result. */
	sign_bit = 0;
	if (sign && (bits >> 31) != 0)
		sign_bit = 1u << (5u + mantissa_bits);
	exponent = (bits >> 23) & 0xFFu;
	mantissa = bits & FMT_MANT_MASK;
	infinity = 0x1Fu << mantissa_bits;

	/* NaN: a quiet NaN of the format. */
	if (exponent == 0xFFu && mantissa != 0)
		return sign_bit | infinity | 1u << (mantissa_bits - 1u);

	/* An unsigned format clamps negative values (and -0) to 0. */
	if (!sign && (bits >> 31) != 0)
		return 0;

	/* Infinity. */
	if (exponent == 0xFFu)
		return sign_bit | infinity;

	/* Zero and the fp32 denormals (far below the result's smallest). */
	if (exponent == 0)
		return sign_bit;

	/* The value is 1.m x 2^(exponent - 127); the result's biased exponent. */
	mantissa |= 1u << 23;
	biased = (int32_t)exponent - 127 + 15;

	/* The bits shifted out: a normal result keeps mantissa_bits, a denormal fewer. */
	shift = 23u - mantissa_bits;
	if (biased <= 0) {
		if (biased < -24)
			return sign_bit;
		shift += (uint32_t)(1 - biased);
		biased = 0;
	}

	/* Below half of the smallest denormal: zero. */
	if (shift >= 25u)
		return sign_bit;

	/* Rounds to nearest even; a carry may reach the next exponent. */
	result = mantissa >> shift;
	rest = mantissa & ((1u << shift) - 1u);
	half = 1u << (shift - 1u);
	if (rest > half || (rest == half && (result & 1u) != 0))
		result++;

	/* A normal result: the hidden bit becomes the exponent's increment. */
	if (biased > 0) {
		result += ((uint32_t)biased - 1u) << mantissa_bits;
	}

	/* Overflow. */
	if (result >= infinity)
		return sign_bit | infinity;

	/* Succeeded: the float's bits. */
	return sign_bit | result;
}

/*
 * E5B9G9R9_UFLOAT_PACK32 from R, G, B (Vulkan's shared exponent
 * conversion: the components clamped to [0, 65408], the exponent from the
 * largest, each mantissa floor(c / 2^(exponent - 24) + 0.5)).
 */
static uint32_t
fmt_e5b9g9r9(
	const uint32_t *color)
{
	uint32_t component[3];
	uint32_t largest;
	uint32_t exponent;
	uint32_t index;
	uint32_t mantissa[3];
	int32_t shared;
	int32_t floor_log2;

	/* Clamps each to [0, 65408] (NaN to 0): 65408 is 0x477F8000. */
	largest = 0;
	for (index = 0; index < 3u; index++) {
		component[index] = color[index];
		if (fmt_is_nan(component[index]) || (component[index] >> 31) != 0)
			component[index] = 0;
		if (component[index] > 0x477F8000u)
			component[index] = 0x477F8000u;
		if (component[index] > largest)
			largest = component[index];
	}

	/* The shared exponent: max(-16, floor(log2(max))) + 16, bias 15, 9 mantissa bits. */
	exponent = (largest >> 23) & 0xFFu;
	floor_log2 = (int32_t)exponent - 127;
	if (largest == 0 || floor_log2 < -16)
		floor_log2 = -16;
	shared = floor_log2 + 1 + 15;

	/* The largest's mantissa at that exponent: 512 means one more exponent. */
	mantissa[0] = fmt_round_pow2(largest, 24 - shared);
	if (mantissa[0] == 512u)
		shared++;

	/* Each component: floor(c / 2^(shared - 15 - 9) + 0.5). */
	for (index = 0; index < 3u; index++)
		mantissa[index] = fmt_round_pow2(component[index], 24 - shared);

	/* Succeeded: R, G, B and the exponent. */
	return mantissa[0] | mantissa[1] << 9 | mantissa[2] << 18 | (uint32_t)shared << 27;
}

/*
 * RNE(f x factor) for a finite fp32 f in [0, 1): f is m x 2^(e - 150),
 * so the product is (m x factor) >> (150 - e), rounded.
 */
static uint32_t
fmt_scale(
	uint32_t bits,
	uint64_t factor)
{
	uint64_t product;
	uint64_t rest;
	uint64_t half;
	uint64_t result;
	uint32_t exponent;
	uint32_t mantissa;
	uint32_t shift;

	/* The mantissa with its hidden bit; denormals have none and exponent 1. */
	exponent = (bits >> 23) & 0xFFu;
	mantissa = bits & FMT_MANT_MASK;
	if (exponent == 0) {
		exponent = 1;
	} else {
		mantissa |= 1u << 23;
	}

	/* A value below 2^-64 of the factor rounds to 0. */
	shift = 150u - exponent;
	if (shift >= 64u)
		return 0;

	/* The product, shifted with rounding to nearest even. */
	product = (uint64_t)mantissa * factor;
	result = product >> shift;
	rest = product & (((uint64_t)1 << shift) - 1u);
	half = (uint64_t)1 << (shift - 1u);
	if (rest > half || (rest == half && (result & 1u) != 0))
		result++;

	/* Succeeded: the rounded product. */
	return (uint32_t)result;
}

/*
 * floor(f x 2^power + 0.5) for a finite fp32 f >= 0 (the shared exponent's
 * rounding); f is m x 2^(e - 150).
 */
static uint32_t
fmt_round_pow2(
	uint32_t bits,
	int32_t power)
{
	uint32_t exponent;
	uint32_t mantissa;
	int32_t shift;

	/* The mantissa with its hidden bit; denormals have none and exponent 1. */
	exponent = (bits >> 23) & 0xFFu;
	mantissa = bits & FMT_MANT_MASK;
	if (exponent == 0) {
		exponent = 1;
	} else {
		mantissa |= 1u << 23;
	}

	/* A left shift: the value is an integer already. */
	shift = 150 - (int32_t)exponent - power;
	if (shift <= 0)
		return mantissa << (uint32_t)(-shift);

	/* Far below one half: zero. */
	if (shift >= 26)
		return 0;

	/* Succeeded: half added, then the fraction dropped. */
	return (uint32_t)(((uint64_t)mantissa + ((uint64_t)1 << (shift - 1))) >> shift);
}

/* Reports whether fp32 bits are a NaN. */
static int
fmt_is_nan(
	uint32_t bits)
{
	/* All exponent bits and a mantissa. */
	if ((bits & FMT_EXP_MASK) == FMT_EXP_MASK && (bits & FMT_MANT_MASK) != 0)
		return 1;

	/* A number or an infinity. */
	return 0;
}

/* Puts a component's value into the texel's 128 bits at its position. */
static void
fmt_put(
	uint32_t *raw,
	uint32_t position,
	uint32_t width,
	uint32_t value)
{
	uint32_t word;
	uint32_t shift;

	/* The value's own bits only. */
	if (width < 32u)
		value &= (1u << width) - 1u;

	/* The word and the shift; a component never spans two words. */
	word = position / 32u;
	shift = position % 32u;
	raw[word] |= value << shift;
}
