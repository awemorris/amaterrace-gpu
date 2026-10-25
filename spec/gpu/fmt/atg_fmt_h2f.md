# atg_fmt_h2f

RTL: `rtl/gpu/fmt/atg_fmt_h2f.v`.  Parent: atg_blt_favg (two, the two samples of a step).

## 1. Purpose and place

fp16 to fp32, written with the shared arithmetic (docs/style.md, "Arithmetic"); it replaces the function `atg_fmt_h2f` of the former `include/atg_fmt_unpack.vh`.  atg_fmt_comp has the same normalisation for every small float of a texel (a unit that converts texels uses it instead).

## 2. Parameters

None.

## 3. Ports

`h` (16, fp16) / `f` (32, fp32): 2 ports.  Combinational.

## 4. Behaviour

Exact: ±0, ±infinity, NaN to 0x7FC00000; a half denormal normalised (its leading zeros lz, the fraction shifted left by lz + 1 (am_shift), exponent 112 − lz (am_sub)); a normal number exponent e + 112 (am_add).  `tools/fmtmodel.py` (unpack) is the reference.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational: a 10-bit leading-zero count, a 10-bit shifter, a 4-bit incrementer and two 8-bit adders.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

`sim/tb/atg_fmt_tb.v` (`PASS atg_fmt.h2f`): all 65536 fp16 values against atg_fmt_comp of R16_SFLOAT (which `PASS atg_fmt.unpack` checks against the model).

## 9. References

`spec/gpu/fmt/atg_fmt.md`, `spec/gpu/fmt/atg_fmt_comp.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25): the PASS of §8; equal to the former function on all 65536 inputs (scratch harness).
