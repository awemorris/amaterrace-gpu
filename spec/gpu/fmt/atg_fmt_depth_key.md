# atg_fmt_depth_key

RTL: `rtl/gpu/fmt/atg_fmt_depth_key.v`.  Parents: atg_rop_dtest (D32_SFLOAT depth), atg_tu_filter (the D32F compare).

## 1. Purpose and place

The order key of an fp32 depth value for the depth test and the compare samplers, written with the shared arithmetic (docs/style.md, "Arithmetic"); it replaces the function `atg_depth_key` of `include/atg_depth.vh`.

## 2. Parameters

None.

## 3. Ports

`f` (32, fp32) / `k` (33, a signed key): 2 ports.

## 4. Behaviour

k = 0 when the exponent is 0 (±0 and denormals), else +{00, f[30:0]} for a positive value and −{00, f[30:0]} for a negative one (am_addsub), so that the signed keys order as the values do.  NaN gets a key too; the compare (`atg_depth_pass`) takes NaN apart.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational: a 33-bit adder/subtracter.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

`sim/tb/atg_fmt_depth_tb.v` against its own copy of the former function, the same values as atg_fmt_depth_u24 (`PASS atg_fmt_depth.key`).

## 9. References

`spec/gpu/rop/atg_rop_dtest.md`, `spec/gpu/tu/atg_tu_filter.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25): the PASS of §8.
