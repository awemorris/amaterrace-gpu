# atg_rop_div255

RTL: `rtl/gpu/rop/atg_rop_div255.v`.  Parent: atg_rop_blend (stage 3: the blend result of each channel, and the 8-bit to 5- and 6-bit conversions).

## 1. Purpose and place

round(x / 255) for x ≤ 2 × 255 × 255 without a wide adder, written with the shared arithmetic (docs/style.md, "Arithmetic"); it replaces the function `div255` of atg_rop_blend.

## 2. Parameters

None.

## 3. Ports

`x` (18) / `q` (9): 2 ports.

## 4. Behaviour

y = x + 128; c = (y[7:0] + y[15:8] + y[18:16]) >> 8; q = (y >> 8) + (y >> 16) + c, equal to (y + (y >> 8) + (y >> 16)) >> 8 and to round(x / 255) over the whole range (checked exhaustively 2026-10-24).  Five am_add.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational: a 19-bit adder, two 10-bit and two 11-bit adders.

## 7. Corner cases and errors

None.

## 8. What the TB checks

`sim/tb/atg_rop_blend_tb.v` (through atg_rop_blend); the former atg_rop_blend and the new one compared on 100,000 random cycles (2026-10-25).

## 9. References

`spec/gpu/rop/atg_rop_blend.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
