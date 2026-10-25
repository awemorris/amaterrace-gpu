# atg_su_i2f

RTL: `rtl/gpu/su/atg_su_i2f.v`.  Parents: atg_su_fpu (one per lane: fround, fract, fcvt.s.w*).

## 1. Purpose and place

An integer magnitude with a sign to fp32; it replaces the function `atg_su_i2f` of include/atg_su_fp.vh (tools/gsi1fp.py).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`s`, `n` (32: the magnitude), `rm` (3) / `r` (32): 4 ports.

## 4. Behaviour

The magnitude is normalised to bit 31 (the highest set bit by am_msb, shifted left by 31 − msb = ~msb, am_shift), the exponent is msb + 127 (am_add), and atg_su_rnd rounds the top 24 bits with the guard and sticky bits below under rm; 0 gives a zero of the sign.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

The module against the former function on 1,000,000 random inputs (magnitudes of every size), 0 errors (2026-10-25).

## 9. References

design §3.1 (precision), tools/gsi1fp.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
