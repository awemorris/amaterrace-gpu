# atg_rop_f2u8

RTL: `rtl/gpu/rop/atg_rop_f2u8.v`.  Parent: atg_rop_blend (the 16 source channels of stage 1, and the fp32 BLEND_CONST_R-A when written).

## 1. Purpose and place

fp32 to unorm8 for the unorm8 blend path, written with the shared arithmetic (docs/style.md, "Arithmetic"); it replaces the function `f2u8` of atg_rop_blend.

## 2. Parameters

None.

## 3. Ports

`f` (32, fp32) / `u` (8): 2 ports.

## 4. Behaviour

NaN, values ≤ 0 (−0 included), denormals and values below 2^−10 give 0; values ≥ 1 and +infinity 255; else RNE(f × 255): m × 255 = (m << 8) − m for m = 1.f (am_sub), shifted right by 126 − e (am_shift), rounded to nearest even (am_add).

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational: a 32-bit subtracter, a 42-bit shifter by 0..9 and an 8-bit incrementer.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

`sim/tb/atg_rop_blend_tb.v` (through atg_rop_blend); the former atg_rop_blend and the new one compared on 100,000 random cycles (2026-10-25).

## 9. References

`spec/gpu/rop/atg_rop_blend.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
