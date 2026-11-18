# am_fp_hrnd

RTL: `rtl/library/fp/am_fp_hrnd.v`. Unified half-precision rounding.

## 1. Purpose and place

Round normalized magnitude `m` to FP16 under `rm`.
Formerly `atg_su_hrnd`.

## 2. Parameters

- `LAT` (0): Latency.

## 3. Ports

- `s`: Sign.
- `e` [9:0] signed: Biased exponent.
- `m` [10:0]: Normalized magnitude.
- `g`: Guard bit.
- `st`: Sticky bit.
- `rm` [2:0]: Rounding mode.
- `h` [15:0]: FP16 result.
