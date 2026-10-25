# atg_fmt_f2unorm

RTL: `rtl/gpu/fmt/atg_fmt_f2unorm.v`.  Parents: atg_rop_dtest (D16), atg_rop_fblend (one a component, beside atg_fmt_pack).

## 1. Purpose and place

fp32 to a w-bit UNORM code, written with the shared arithmetic (docs/style.md, "Arithmetic"); it replaces the function `atg_fmt_f2unorm` of the former `include/atg_fmt_pack.vh`.

## 2. Parameters

None.

## 3. Ports

`f` (32, fp32), `w` (6, the width, 1..16) / `u` (16, the code in the low w bits): 3 ports.  Combinational.

## 4. Behaviour

RNE(clamp01(f) × (2^w − 1)): NaN, negative values (−0 included) and values below 2^−24 give 0, values ≥ 1 and +infinity 2^w − 1.  The product is (m << w) − m for the mantissa m = 1.f (am_shift, am_sub), shifted right by 150 − e (am_shift) and rounded to nearest even (am_add).  `tools/fmtmodel.py` (pack) is the reference.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational: a 48-bit shifter by w, a 48-bit subtracter, a 48-bit shifter by 0..47 and a 16-bit incrementer.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

`sim/tb/atg_fmt_tb.v` (`PASS atg_fmt.pack`): through atg_fmt_pack, every UNORM format with random components and every code of 5, 6, 8 and 10 bits from its fp32 and the fp32 next to it.

## 9. References

`spec/gpu/fmt/atg_fmt.md`, `spec/gpu/fmt/atg_fmt_pack.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25): the PASS of §8; equal to the former function on 1M random inputs (scratch harness).
