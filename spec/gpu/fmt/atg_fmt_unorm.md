# atg_fmt_unorm

RTL: `rtl/gpu/fmt/atg_fmt_unorm.v`.  Parents: atg_fmt_comp (UNORM, SNORM's magnitude, sRGB's alpha), atg_rop_dtest (the stored D24 or D16 value, one converter for both).

## 1. Purpose and place

A w-bit UNORM code to fp32, written with the shared arithmetic (docs/style.md, "Arithmetic"); it replaces the function `atg_fmt_unorm` of the former `include/atg_fmt_unpack.vh`.

## 2. Parameters

None.

## 3. Ports

`c` (24, the code), `w` (6, the width: 1, 2, 4-8, 10, 11, 15, 16 or 24) / `f` (32, fp32): 3 ports.  Combinational.

## 4. Behaviour

c / (2^w − 1) to the nearest fp32: the quotient is 0.ccc... in binary, so the leading 72 bits of c repeated (a case on w) give the mantissa after a shift by their leading zeros (am_shift), and the rounding is never a tie (am_add); the exponent is 126 − lz (127 − lz on a carry, am_sub).  0 gives +0.  `tools/fmtmodel.py` (unpack) is the reference.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational: a 24-bit leading-zero count, a 72-bit shifter by 0..23, a 24-bit incrementer and an 8-bit subtracter.

## 7. Corner cases and errors

A width outside the list reads c as 24 bits.

## 8. What the TB checks

`sim/tb/atg_fmt_tb.v` (`PASS atg_fmt.unpack`): through atg_fmt_comp, every UNORM, SNORM and sRGB format, all codes of the single 1- to 11-bit components and random texels; `sim/tb/atg_rop_dtest_tb.v` the D16 and D24 depth bounds.

## 9. References

`spec/gpu/fmt/atg_fmt.md`, `spec/gpu/fmt/atg_fmt_comp.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25): the PASS of §8; equal to the former function on 1M random inputs (scratch harness).
