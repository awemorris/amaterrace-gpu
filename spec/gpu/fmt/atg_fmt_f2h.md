# atg_fmt_f2h

RTL: `rtl/gpu/fmt/atg_fmt_f2h.v`.  Parents: atg_rop_fblend (one a component, beside atg_fmt_pack), atg_blt_favg (the fp16 resolve).

## 1. Purpose and place

fp32 to fp16, written with the shared arithmetic (docs/style.md, "Arithmetic"); it replaces the function `atg_fmt_f2h` of the former `include/atg_fmt_pack.vh`.

## 2. Parameters

None.

## 3. Ports

`f` (32, fp32) / `h` (16, fp16): 2 ports.  Combinational.

## 4. Behaviour

To nearest even: overflow to ±infinity, NaN 0x7E00, half denormals exact (the mantissa shifted right by 126 − e and rounded), fp32 values below the half denormals ±0.  Normal results: the mantissa rounded at bit 13 (am_add) and the exponent e − 112 (− 111 on a carry, am_sub).  `tools/fmtmodel.py` (pack) is the reference.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational: a 12-bit incrementer, an 8-bit subtracter, a 24-bit shifter by 0..31 and a 15-bit incrementer.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

`sim/tb/atg_fmt_tb.v` (`PASS atg_fmt.pack`): through atg_fmt_pack, the SFLOAT16 formats with random components and the specials.

## 9. References

`spec/gpu/fmt/atg_fmt.md`, `spec/gpu/fmt/atg_fmt_pack.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25): the PASS of §8; equal to the former function on 1M random inputs (scratch harness).
