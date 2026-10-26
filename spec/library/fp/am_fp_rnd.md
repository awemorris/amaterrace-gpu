# am_fp_rnd

RTL: `rtl/library/fp/am_fp_rnd.v`. Unified floating-point rounding.

## 1. Purpose and place

Round a normalized magnitude `m` with guard `g`, sticky `st`, sign `s` and biased exponent `e` under rounding mode `rm`.
Formerly `atg_su_rnd`.

## 2. Parameters

- `LAT` (0): Latency.

## 3. Ports

- `s`: Sign.
- `e` [11:0] signed: Biased exponent.
- `m` [23:0]: Normalized magnitude.
- `g`: Guard bit.
- `st`: Sticky bit.
- `rm` [2:0]: Rounding mode.
- `r` [31:0]: FP32 result.
