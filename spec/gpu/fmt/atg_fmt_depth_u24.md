# atg_fmt_depth_u24

RTL: `rtl/gpu/fmt/atg_fmt_depth_u24.v`.  Parents: atg_rop_dtest (D24 depth), atg_tu_filter (the D24 compare reference).

## 1. Purpose and place

The fp32 depth to unorm24 conversion of the depth test and the compare samplers, written with the shared arithmetic (docs/style.md, "Arithmetic"); it replaces the function `atg_depth_u24` of `include/atg_depth.vh`.

## 2. Parameters

None.

## 3. Ports

`f` (32, fp32) / `u` (24, unorm24): 2 ports.

## 4. Behaviour

RNE(f × (2^24 − 1)) for f in (0, 1); NaN, negative values (−0 included), denormals and values below 2^−25 give 0; values ≥ 1 and +infinity all ones.  The product is (m << 24) − m for the mantissa m = 1.f (am_sub), shifted right by 126 − e (am_shift), rounded to nearest even at bit 48 (am_add).  tools/rxmodel.py `f2u24` is the reference.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational: a 48-bit subtracter, a 72-bit shifter by 0..24 and a 24-bit incrementer.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

`sim/tb/atg_fmt_depth_tb.v` against its own copy of the former function: every sign and exponent with the mantissas 0, 1, all ones and 4096 random ones, the specials and 200,000 random fp32 (`PASS atg_fmt_depth.u24`).

## 9. References

`spec/gpu/rop/atg_rop_dtest.md`, `spec/gpu/tu/atg_tu_filter.md`, docs/ghci.md (D24_UNORM_S8_UINT).

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25): the PASS of §8.
