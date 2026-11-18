# am_fp_i2f

RTL: `rtl/library/fp/am_fp_i2f.v`. Unified integer to float conversion.

## 1. Purpose and place

Integer magnitude `n` with sign `s` to fp32 under `rm`.
Formerly `atg_su_i2f`.

## 2. Parameters

- `LAT` (0): Latency.

## 3. Ports

- `s`: Sign.
- `n` [31:0]: Integer magnitude.
- `rm` [2:0]: Rounding mode.
- `r` [31:0]: FP32 result.
